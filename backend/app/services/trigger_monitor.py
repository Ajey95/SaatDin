from __future__ import annotations

import asyncio
import hashlib
import logging
from collections import defaultdict
from datetime import datetime, timedelta, timezone
from typing import Any, Dict, Optional

from apscheduler.schedulers.asyncio import AsyncIOScheduler

from ..core.config import settings
from ..core.db import (
    count_claims_for_phone_since,
    count_recent_zone_claims_window,
    count_settled_claim_days_for_phone_since,
    create_claim,
    create_trigger_signal_reading,
    get_worker_location_signal,
    get_worker_created_at,
    has_recent_auto_claim,
    list_trigger_signal_readings,
    list_workers_by_zone,
    upsert_worker_location_signal,
    update_claim_status,
)
from ..core.zone_cache import load_zone_map, resolve_zone
from ..models.platform import Platform
from .external_apis import TRIGGER_THRESHOLDS, get_api_client
from .fraud_isolation import score_claim
from .gps_validation import evaluate_worker_gps_signal, gps_features_from_validation
from .motion_validation import evaluate_worker_motion_signal, motion_features_from_validation
from .payouts import initiate_claim_payout
from .premium import build_plans
from .tower_validation import evaluate_worker_tower_signal, tower_features_from_validation

logger = logging.getLogger(__name__)

_live_trigger_state: Dict[str, Dict[str, Any]] = {}
_device_fingerprints: Dict[str, str] = {}
_fraud_ring_clusters: Dict[str, set[str]] = defaultdict(set)

_TRIGGER_PAYOUT_FACTORS = {
    "rain": 1.00,
    "aqi": 0.80,
    "traffic": 0.70,
    "zonelock": 1.00,
    "heat": 0.60,
}


def _current_week_start_utc() -> datetime:
    now = datetime.now(timezone.utc)
    return (now - timedelta(days=now.weekday())).replace(hour=0, minute=0, second=0, microsecond=0)


def _claim_type_to_alert_key(claim_type: str) -> str:
    normalized = claim_type.strip().lower().replace(" ", "").replace("_", "")
    mapping = {
        "rain": "rain",
        "rainlock": "rain",
        "aqi": "aqi",
        "aqiguard": "aqi",
        "traffic": "traffic",
        "trafficblock": "traffic",
        "zonelock": "zonelock",
        "heat": "heat",
        "heatblock": "heat",
    }
    return mapping.get(normalized, normalized)


def _platform_from_display(name: str) -> Platform:
    lowered = name.strip().lower()
    if lowered == "blinkit":
        return Platform.blinkit
    if lowered == "zepto":
        return Platform.zepto
    return Platform.swiggy_instamart


def _zone_center_coordinates(zone: Dict[str, Any]) -> tuple[float, float]:
    coords = zone.get("coordinates_approx", {})
    zone_lat = float(zone.get("latitude", coords.get("lat", 12.97)))
    zone_lon = float(zone.get("longitude", coords.get("lon", 77.59)))
    return zone_lat, zone_lon


def _required_samples(window_hours: int) -> int:
    poll_minutes = max(1, int(settings.trigger_poll_minutes))
    expected = max(1, int((window_hours * 60) / poll_minutes))
    slack = max(0, int(settings.trigger_window_sample_slack))
    return max(1, expected - slack)


def _select_worker_plan(plans: list[Any], worker_plan_name: str) -> Optional[Any]:
    if not plans:
        return None
    selected = next(
        (plan for plan in plans if str(plan.name).lower() == worker_plan_name.lower()),
        None,
    )
    if selected is not None:
        return selected
    # Prefer standard/default middle tier when available.
    return plans[1] if len(plans) > 1 else plans[0]


async def _store_and_window_readings(
    *,
    zone_pincode: str,
    signal_type: str,
    reading_value: float,
    secondary_value: Optional[float],
    meets_threshold: bool,
    metadata: Optional[Dict[str, Any]],
    source: str,
    window_hours: int,
) -> list[Dict[str, Any]]:
    await create_trigger_signal_reading(
        zone_pincode=zone_pincode,
        signal_type=signal_type,
        reading_value=reading_value,
        secondary_value=secondary_value,
        meets_threshold=meets_threshold,
        metadata=metadata,
        observed_at=datetime.now(timezone.utc),
        source=source,
    )
    return await list_trigger_signal_readings(
        zone_pincode=zone_pincode,
        signal_type=signal_type,
        since=datetime.now(timezone.utc) - timedelta(hours=window_hours),
    )


async def _tower_features_for_worker(phone: str, pincode: str, zone_lat: float, zone_lon: float) -> Dict[str, Any]:
    validation = await evaluate_worker_tower_signal(
        phone=phone,
        claimed_zone_pincode=pincode,
        zone_lat=zone_lat,
        zone_lon=zone_lon,
    )
    return tower_features_from_validation(validation)


async def _motion_features_for_worker(phone: str) -> Dict[str, Any]:
    validation = await evaluate_worker_motion_signal(phone=phone)
    return motion_features_from_validation(validation)


async def _gps_features_for_worker(phone: str) -> Dict[str, Any]:
    validation = await evaluate_worker_gps_signal(phone=phone)
    return gps_features_from_validation(validation)


async def _build_anomaly_features(
    *,
    phone: str,
    pincode: str,
    zone: Dict[str, Any],
    payout: float,
    trigger_confidence: float,
    source: str,
    zone_affinity: Optional[float] = None,
    fraud_ring: Optional[set[str]] = None,
) -> Dict[str, Any]:
    zone_lat, zone_lon = _zone_center_coordinates(zone)
    zone_affinity_score = (
        zone_affinity
        if zone_affinity is not None
        else await calculate_zone_affinity_score(phone, zone_lat, zone_lon)
    )
    fraud_ring_members = fraud_ring if fraud_ring is not None else get_fraud_ring_members(phone)
    recent_claims_24h = await count_claims_for_phone_since(
        phone,
        datetime.now(timezone.utc) - timedelta(hours=24),
    )
    features = {
        "zone_affinity_score": zone_affinity_score,
        "fraud_ring_size": float(len(fraud_ring_members)),
        "recent_claims_24h": float(recent_claims_24h),
        "claim_amount": float(round(payout, 2)),
        "trigger_confidence": float(trigger_confidence),
        "is_manual_source": 1.0 if source == "manual" else 0.0,
        "is_auto_source": 0.0 if source == "manual" else 1.0,
        "flood_risk_score": float(zone.get("flood_risk_score", 0.5)),
        "aqi_risk_score": float(zone.get("aqi_risk_score", 0.5)),
        "traffic_congestion_score": float(zone.get("traffic_congestion_score", 0.5)),
    }
    features.update(await _tower_features_for_worker(phone, pincode, zone_lat, zone_lon))
    features.update(await _motion_features_for_worker(phone))
    features.update(await _gps_features_for_worker(phone))
    return features


async def force_trigger_for_zone(
    zone_key: str,
    claim_type: str,
    alert_title: str,
    alert_description: str,
    confidence: float = 0.9,
    source: str = "manual",
) -> Dict[str, Any]:
    pincode, zone = resolve_zone(zone_key)
    alert_type = _claim_type_to_alert_key(claim_type)
    state = {
        "hasActiveAlert": True,
        "alertType": alert_type,
        "claimType": claim_type,
        "alertTitle": alert_title,
        "alertDescription": alert_description,
        "confidence": confidence,
        "dataSource": source,
        "source": source,
    }
    _live_trigger_state[pincode] = state

    workers = await list_workers_by_zone(pincode)
    created = 0
    flagged_for_review = 0
    zone_lat, zone_lon = _zone_center_coordinates(zone)
    for worker in workers:
        phone = str(worker["phone"])
        if await has_recent_auto_claim(phone, claim_type, within_minutes=360):
            continue

        platform = _platform_from_display(str(worker["platform_name"]))
        zone_multiplier = float(zone.get("zone_risk_multiplier", 1.0))
        plans = build_plans(zone_multiplier, platform, zone_data=zone)
        selected = _select_worker_plan(plans, str(worker["plan_name"]))
        if selected is None:
            logger.warning("auto_claim_skipped_no_plans phone=%s claim_type=%s", phone, claim_type)
            continue
        payout = float(selected.perTriggerPayout) * _TRIGGER_PAYOUT_FACTORS.get(alert_type, 0.7)
        zone_affinity = await calculate_zone_affinity_score(phone, zone_lat, zone_lon)
        fraud_ring = get_fraud_ring_members(phone)
        anomaly_features = await _build_anomaly_features(
            phone=phone,
            pincode=pincode,
            zone=zone,
            payout=payout,
            trigger_confidence=float(state.get("confidence", 0.55)),
            source=source,
            zone_affinity=zone_affinity,
            fraud_ring=fraud_ring,
        )
        anomaly = score_claim(
            anomaly_features,
            context={"phone": phone, "claim_type": claim_type, "source": source},
        )
        claim_status = "in_review" if bool(anomaly["anomaly_flagged"]) else "settled"
        if claim_status == "in_review":
            flagged_for_review += 1
        claim_row = await create_claim(
            phone=phone,
            claim_type=claim_type,
            status=claim_status,
            amount=round(payout, 2),
            description=f"Auto-settled: {alert_title}. Data source: {source}.",
            zone_pincode=pincode,
            source=source,
            anomaly_score=float(anomaly["anomaly_score"]),
            anomaly_threshold=float(anomaly["anomaly_threshold"]),
            anomaly_flagged=bool(anomaly["anomaly_flagged"]),
            anomaly_model_version=str(anomaly["anomaly_model_version"]),
            anomaly_features=dict(anomaly["anomaly_features"]),
            anomaly_scored_at=str(anomaly["anomaly_scored_at"]),
            llm_review_used=bool(anomaly["llm_review_used"]) if anomaly.get("llm_review_used") is not None else None,
            llm_review_status=str(anomaly["llm_review_status"]) if anomaly.get("llm_review_status") is not None else None,
            llm_provider=str(anomaly["llm_provider"]) if anomaly.get("llm_provider") is not None else None,
            llm_model=str(anomaly["llm_model"]) if anomaly.get("llm_model") is not None else None,
            llm_fallback_used=bool(anomaly["llm_fallback_used"]) if anomaly.get("llm_fallback_used") is not None else None,
            llm_decision_confidence=float(anomaly["llm_decision_confidence"])
            if anomaly.get("llm_decision_confidence") is not None
            else None,
            llm_decision_json=anomaly.get("llm_decision_json"),
            llm_attempts=anomaly.get("llm_attempts"),
            llm_validation_error=str(anomaly["llm_validation_error"])
            if anomaly.get("llm_validation_error") is not None
            else None,
            llm_scored_at=str(anomaly["llm_scored_at"]) if anomaly.get("llm_scored_at") is not None else None,
        )
        if claim_status == "settled":
            try:
                await initiate_claim_payout(
                    claim=claim_row,
                    worker=worker,
                    note=f"Auto payout for {claim_type}",
                    metadata={"source": source},
                )
            except ValueError as exc:
                await update_claim_status(
                    int(claim_row["id"]),
                    status="in_review",
                    review_notes=f"Auto payout blocked: {exc}",
                    reviewed_by="system",
                )
                claim_status = "in_review"
                flagged_for_review += 1
                logger.warning(
                    "auto_payout_blocked phone=%s claim_id=%s claim_type=%s reason=%s",
                    phone,
                    claim_row.get("id"),
                    claim_type,
                    str(exc),
                )
        created += 1

    logger.info(
        "trigger_forced pincode=%s claim_type=%s created=%s flagged_for_review=%s source=%s",
        pincode,
        claim_type,
        created,
        flagged_for_review,
        source,
    )
    return {
        "zone": zone.get("name", zone_key),
        "pincode": pincode,
        "claimType": claim_type,
        "alertTitle": alert_title,
        "hasActiveAlert": True,
        "autoClaimsCreated": created,
        "source": source,
    }


def get_live_trigger_state() -> Dict[str, Dict[str, Any]]:
    return _live_trigger_state


def register_device_fingerprint(phone: str, device_id: str, app_version: str, os_type: str) -> str:
    fingerprint = f"{device_id}|{app_version}|{os_type}"
    fingerprint_hash = hashlib.sha256(fingerprint.encode()).hexdigest()[:12]
    _device_fingerprints[phone] = fingerprint_hash
    _fraud_ring_clusters[fingerprint_hash].add(phone)
    logger.info("device_fingerprint_registered phone=%s hash=%s", phone, fingerprint_hash)
    return fingerprint_hash


def update_worker_gps(phone: str, latitude: float, longitude: float) -> None:
    # Keep a sync API for existing call sites while persisting data asynchronously.
    try:
        loop = asyncio.get_running_loop()
    except RuntimeError:
        return
    loop.create_task(
        upsert_worker_location_signal(
            phone=phone,
            latitude=latitude,
            longitude=longitude,
            captured_at=datetime.now(timezone.utc),
        )
    )


async def calculate_zone_affinity_score(phone: str, zone_center_lat: float, zone_center_lon: float) -> float:
    gps = await get_worker_location_signal(phone)
    if not gps:
        return 0.5
    lat_raw = gps.get("latitude")
    lon_raw = gps.get("longitude")
    if lat_raw is None or lon_raw is None:
        return 0.5
    lat1, lon1 = float(lat_raw), float(lon_raw)
    lat2, lon2 = zone_center_lat, zone_center_lon
    dx = (lon2 - lon1) * 111 * 1000 * 0.9
    dy = (lat2 - lat1) * 111 * 1000
    distance_meters = (dx**2 + dy**2) ** 0.5
    if distance_meters < 2000:
        return 0.95
    if distance_meters < 5000:
        return 0.7
    if distance_meters < 10000:
        return 0.4
    return 0.2


def get_fraud_ring_members(phone: str) -> set[str]:
    if phone not in _device_fingerprints:
        return set()
    fingerprint_hash = _device_fingerprints[phone]
    return _fraud_ring_clusters.get(fingerprint_hash, set())


async def _determine_trigger(zone: Dict[str, Any]) -> Dict[str, Any]:
    api_client = get_api_client()
    zone_lat, zone_lon = _zone_center_coordinates(zone)
    pincode = str(zone.get("pincode", ""))
    zone_name = str(zone.get("name", zone.get("zone_name", pincode)))
    now = datetime.now(timezone.utc)

    flood = float(zone.get("flood_risk_score", 0.0))
    aqi = float(zone.get("aqi_risk_score", 0.0))
    traffic = float(zone.get("traffic_congestion_score", 0.0))

    rainfall_real = await api_client.get_rainfall_data(zone_lat, zone_lon)
    if rainfall_real is not None:
        await _store_and_window_readings(
            zone_pincode=pincode,
            signal_type="rain",
            reading_value=rainfall_real,
            secondary_value=None,
            meets_threshold=rainfall_real > TRIGGER_THRESHOLDS["rainfall_mm"],
            metadata={"windowHours": TRIGGER_THRESHOLDS["rainfall_window_hours"]},
            source="open-meteo",
            window_hours=int(TRIGGER_THRESHOLDS["rainfall_window_hours"]),
        )
    if rainfall_real is not None and rainfall_real > TRIGGER_THRESHOLDS["rainfall_mm"]:
        return {
            "hasActiveAlert": True,
            "alertType": "rain",
            "claimType": "RainLock",
            "alertTitle": "RainLock: Heavy rainfall detected",
            "alertDescription": f"Rainfall {rainfall_real:.1f}mm exceeds threshold ({TRIGGER_THRESHOLDS['rainfall_mm']}mm).",
            "confidence": min(0.99, 0.85 + (rainfall_real / 100) * 0.14),
            "dataSource": "open-meteo",
        }

    aqi_real = await api_client.get_aqi_data(zone_lat, zone_lon)
    if aqi_real is not None:
        readings = await _store_and_window_readings(
            zone_pincode=pincode,
            signal_type="aqi",
            reading_value=aqi_real,
            secondary_value=None,
            meets_threshold=aqi_real >= TRIGGER_THRESHOLDS["aqi_dangerous"],
            metadata={"threshold": TRIGGER_THRESHOLDS["aqi_dangerous"]},
            source="waqi",
            window_hours=int(TRIGGER_THRESHOLDS["aqi_window_hours"]),
        )
        required = _required_samples(int(TRIGGER_THRESHOLDS["aqi_window_hours"]))
        window = readings[-required:]
        sustained = len(window) >= required and all(
            float(row.get("reading_value", 0.0)) >= TRIGGER_THRESHOLDS["aqi_dangerous"]
            for row in window
        )
        if sustained and 12 <= now.hour <= 22:
            avg_aqi = sum(float(row.get("reading_value", 0.0)) for row in window) / len(window)
            return {
                "hasActiveAlert": True,
                "alertType": "aqi",
                "claimType": "AQI Guard",
                "alertTitle": "AQI Guard: Hazardous air quality",
                "alertDescription": (
                    f"AQI stayed above {TRIGGER_THRESHOLDS['aqi_dangerous']} "
                    f"for {TRIGGER_THRESHOLDS['aqi_window_hours']} hours in {zone_name}."
                ),
                "confidence": min(0.98, 0.80 + (avg_aqi / 300) * 0.18),
                "dataSource": "waqi-window",
            }

    traffic_real = await api_client.get_traffic_speed(zone_lat, zone_lon)
    if traffic_real is not None:
        readings = await _store_and_window_readings(
            zone_pincode=pincode,
            signal_type="traffic",
            reading_value=traffic_real,
            secondary_value=None,
            meets_threshold=traffic_real <= TRIGGER_THRESHOLDS["traffic_speed_kmph"],
            metadata={"threshold": TRIGGER_THRESHOLDS["traffic_speed_kmph"]},
            source="tomtom",
            window_hours=int(TRIGGER_THRESHOLDS["traffic_duration_hours"]),
        )
        required = _required_samples(int(TRIGGER_THRESHOLDS["traffic_duration_hours"]))
        window = readings[-required:]
        sustained = len(window) >= required and all(
            float(row.get("reading_value", 99.0)) <= TRIGGER_THRESHOLDS["traffic_speed_kmph"]
            for row in window
        )
        if sustained:
            avg_speed = sum(float(row.get("reading_value", 0.0)) for row in window) / len(window)
            return {
                "hasActiveAlert": True,
                "alertType": "traffic",
                "claimType": "TrafficBlock",
                "alertTitle": "TrafficBlock: Severe congestion",
                "alertDescription": (
                    f"Average speed stayed below {TRIGGER_THRESHOLDS['traffic_speed_kmph']} kmph "
                    f"for {TRIGGER_THRESHOLDS['traffic_duration_hours']} hours in {zone_name}."
                ),
                "confidence": min(0.98, 0.75 + (1 - max(avg_speed, 0.1) / 10) * 0.23),
                "dataSource": "tomtom-window",
            }

    heat_data = await api_client.get_heat_humidity_data(zone_lat, zone_lon)
    if heat_data:
        temperature = float(heat_data.get("temperature", 0.0))
        humidity = float(heat_data.get("humidity", 0.0))
        readings = await _store_and_window_readings(
            zone_pincode=pincode,
            signal_type="heat",
            reading_value=temperature,
            secondary_value=humidity,
            meets_threshold=(
                temperature >= TRIGGER_THRESHOLDS["heat_temp_celsius"]
                and humidity >= TRIGGER_THRESHOLDS["heat_humidity_percent"]
            ),
            metadata={
                "temperatureThreshold": TRIGGER_THRESHOLDS["heat_temp_celsius"],
                "humidityThreshold": TRIGGER_THRESHOLDS["heat_humidity_percent"],
            },
            source="open-meteo",
            window_hours=int(TRIGGER_THRESHOLDS["heat_window_hours"]),
        )
        required = _required_samples(int(TRIGGER_THRESHOLDS["heat_window_hours"]))
        window = readings[-required:]
        sustained = len(window) >= required and all(
            float(row.get("reading_value", 0.0)) >= TRIGGER_THRESHOLDS["heat_temp_celsius"]
            and float(row.get("secondary_value", 0.0)) >= TRIGGER_THRESHOLDS["heat_humidity_percent"]
            for row in window
        )
        if sustained and 13 <= now.hour <= 17:
            avg_temp = sum(float(row.get("reading_value", 0.0)) for row in window) / len(window)
            avg_humidity = sum(float(row.get("secondary_value", 0.0)) for row in window) / len(window)
            return {
                "hasActiveAlert": True,
                "alertType": "heat",
                "claimType": "HeatBlock",
                "alertTitle": "HeatBlock: Extreme heat + humidity",
                "alertDescription": (
                    f"Heat index stayed above policy thresholds for "
                    f"{TRIGGER_THRESHOLDS['heat_window_hours']} hours in {zone_name}."
                ),
                "confidence": min(0.95, 0.78 + ((avg_temp - 35) / 20) * 0.08 + ((avg_humidity - 60) / 50) * 0.07),
                "dataSource": "open-meteo-window",
            }

    disruption = await api_client.get_zone_disruption_news(zone_name, pincode)
    if disruption:
        return {
            "hasActiveAlert": True,
            "alertType": "zonelock",
            "claimType": "ZoneLock",
            "alertTitle": f"ZoneLock: {disruption.title()} detected",
            "alertDescription": f"Civic disruption ({disruption}) detected in {zone_name}.",
            "confidence": 0.80,
            "dataSource": "newsapi",
        }

    if flood >= 0.75:
        return {
            "hasActiveAlert": True,
            "alertType": "rain",
            "claimType": "RainLock",
            "alertTitle": "RainLock: High flood risk zone",
            "alertDescription": "Zone has elevated historical flood risk.",
            "confidence": 0.72,
            "dataSource": "zone-risk-score",
        }

    if aqi >= 0.70:
        return {
            "hasActiveAlert": True,
            "alertType": "aqi",
            "claimType": "AQI Guard",
            "alertTitle": "AQI Guard: High AQI history",
            "alertDescription": "Zone has elevated AQI risk history.",
            "confidence": 0.68,
            "dataSource": "zone-risk-score",
        }

    if traffic >= 0.80:
        return {
            "hasActiveAlert": True,
            "alertType": "traffic",
            "claimType": "TrafficBlock",
            "alertTitle": "TrafficBlock: High congestion risk",
            "alertDescription": "Zone has elevated traffic congestion history.",
            "confidence": 0.70,
            "dataSource": "zone-risk-score",
        }

    return {
        "hasActiveAlert": False,
        "alertType": "none",
        "claimType": "none",
        "alertTitle": "No active trigger",
        "alertDescription": "No active disruption trigger detected.",
        "confidence": 0.55,
        "dataSource": "none",
    }


async def refresh_live_trigger_state() -> None:
    zones = load_zone_map()
    for pincode, zone in zones.items():
        state = await _determine_trigger(zone)
        state["source"] = "live"
        _live_trigger_state[pincode] = state

        if not state.get("hasActiveAlert"):
            continue

        claim_type = str(state.get("claimType", "none"))
        alert_type = str(state.get("alertType", "none"))
        if claim_type == "none" or alert_type == "none":
            continue

        zone_lat, zone_lon = _zone_center_coordinates(zone)
        workers = await list_workers_by_zone(pincode)
        worker_phones = {str(worker["phone"]) for worker in workers}

        # ── Adversarial Defense: Claim Velocity Spike Detection ──────────
        # If >N claims in the same zone within M minutes, hold the batch.
        velocity_window = timedelta(minutes=max(1, int(settings.claim_velocity_spike_window_minutes)))
        velocity_cutoff = datetime.now(timezone.utc) - velocity_window
        recent_zone_claim_count = await count_recent_zone_claims_window(pincode, velocity_cutoff)
        velocity_spike = recent_zone_claim_count >= int(settings.claim_velocity_spike_threshold)
        if velocity_spike:
            logger.warning(
                "velocity_spike_detected zone=%s recent_claims=%s threshold=%s — batch held for review",
                pincode,
                recent_zone_claim_count,
                settings.claim_velocity_spike_threshold,
            )

        for worker in workers:
            phone = str(worker["phone"])
            zone_affinity = await calculate_zone_affinity_score(phone, zone_lat, zone_lon)
            fraud_ring = get_fraud_ring_members(phone)
            if zone_affinity < 0.25:
                logger.info(
                    "auto_claim_rejected phone=%s claim_type=%s reason=low_zone_affinity score=%.2f",
                    phone,
                    claim_type,
                    zone_affinity,
                )
                continue

            same_event_ring_claims = sum(1 for member in fraud_ring if member != phone and member in worker_phones)
            if same_event_ring_claims > 2:
                logger.warning(
                    "auto_claim_rejected phone=%s claim_type=%s reason=fraud_ring_detected count=%s",
                    phone,
                    claim_type,
                    same_event_ring_claims + 1,
                )
                continue

            # ── Adversarial Defense: New Account Velocity Hold ───────────
            # Accounts created within N days of a red-alert → held for review.
            new_account_held = False
            worker_created_at_str = await get_worker_created_at(phone)
            if worker_created_at_str:
                try:
                    worker_created_dt = datetime.fromisoformat(worker_created_at_str)
                    if not worker_created_dt.tzinfo:
                        worker_created_dt = worker_created_dt.replace(tzinfo=timezone.utc)
                    account_age_days = (datetime.now(timezone.utc) - worker_created_dt).days
                    if account_age_days < int(settings.new_account_hold_days):
                        new_account_held = True
                        logger.info(
                            "new_account_hold phone=%s claim_type=%s account_age_days=%s",
                            phone,
                            claim_type,
                            account_age_days,
                        )
                except (ValueError, TypeError):
                    pass

            if await has_recent_auto_claim(phone, claim_type, within_minutes=360):
                continue

            platform = _platform_from_display(str(worker["platform_name"]))
            zone_multiplier = float(zone.get("zone_risk_multiplier", 1.0))
            plans = build_plans(zone_multiplier, platform, zone_data=zone)
            selected = _select_worker_plan(plans, str(worker["plan_name"]))
            if selected is None:
                logger.warning("auto_claim_skipped_no_plans phone=%s claim_type=%s", phone, claim_type)
                continue
            weekly_cap_start = _current_week_start_utc()
            settled_days_this_week = await count_settled_claim_days_for_phone_since(phone, weekly_cap_start)
            weekly_cap_reached = settled_days_this_week >= max(1, int(selected.maxDaysPerWeek))
            payout = float(selected.perTriggerPayout) * _TRIGGER_PAYOUT_FACTORS.get(alert_type, 0.7)
            anomaly_features = await _build_anomaly_features(
                phone=phone,
                pincode=pincode,
                zone=zone,
                payout=payout,
                trigger_confidence=float(state.get("confidence", 0.55)),
                source="auto",
                zone_affinity=zone_affinity,
                fraud_ring=fraud_ring,
            )
            anomaly = score_claim(
                anomaly_features,
                context={"phone": phone, "claim_type": claim_type, "source": "auto"},
            )
            review_notes = None
            # Hold rather than settle when the weekly coverage cap or other risk controls apply.
            if weekly_cap_reached or velocity_spike or new_account_held:
                claim_status = "in_review"
                if weekly_cap_reached:
                    review_notes = (
                        f"Weekly coverage cap reached for plan {selected.name} "
                        f"({selected.maxDaysPerWeek} covered days/week)."
                    )
                elif velocity_spike:
                    review_notes = (
                        f"Auto claims held for review due to recent zone velocity spike: "
                        f"{recent_zone_claim_count} claims in {settings.claim_velocity_spike_window_minutes} minutes."
                    )
                elif new_account_held:
                    review_notes = (
                        f"Auto claims held for review due to new account hold: age < {settings.new_account_hold_days} days."
                    )
            else:
                claim_status = "in_review" if bool(anomaly["anomaly_flagged"]) else "settled"
            claim_row = await create_claim(
                phone=phone,
                claim_type=claim_type,
                status=claim_status,
                amount=round(payout, 2),
                description=f"Auto-settled: {state['alertTitle']}. Data source: {state.get('dataSource', 'unknown')}.",
                zone_pincode=pincode,
                source="auto",
                review_notes=review_notes,
                reviewed_by="system" if review_notes else None,
                anomaly_score=float(anomaly["anomaly_score"]),
                anomaly_threshold=float(anomaly["anomaly_threshold"]),
                anomaly_flagged=bool(anomaly["anomaly_flagged"]),
                anomaly_model_version=str(anomaly["anomaly_model_version"]),
                anomaly_features=dict(anomaly["anomaly_features"]),
                anomaly_scored_at=str(anomaly["anomaly_scored_at"]),
                llm_review_used=bool(anomaly["llm_review_used"]) if anomaly.get("llm_review_used") is not None else None,
                llm_review_status=str(anomaly["llm_review_status"]) if anomaly.get("llm_review_status") is not None else None,
                llm_provider=str(anomaly["llm_provider"]) if anomaly.get("llm_provider") is not None else None,
                llm_model=str(anomaly["llm_model"]) if anomaly.get("llm_model") is not None else None,
                llm_fallback_used=bool(anomaly["llm_fallback_used"]) if anomaly.get("llm_fallback_used") is not None else None,
                llm_decision_confidence=float(anomaly["llm_decision_confidence"])
                if anomaly.get("llm_decision_confidence") is not None
                else None,
                llm_decision_json=anomaly.get("llm_decision_json"),
                llm_attempts=anomaly.get("llm_attempts"),
                llm_validation_error=str(anomaly["llm_validation_error"])
                if anomaly.get("llm_validation_error") is not None
                else None,
                llm_scored_at=str(anomaly["llm_scored_at"]) if anomaly.get("llm_scored_at") is not None else None,
            )
            if claim_status == "settled":
                try:
                    await initiate_claim_payout(
                        claim=claim_row,
                        worker=worker,
                        note=f"Auto payout for {claim_type}",
                        metadata={"source": "auto"},
                    )
                except ValueError as exc:
                    await update_claim_status(
                        int(claim_row["id"]),
                        status="in_review",
                        review_notes=f"Auto payout blocked: {exc}",
                        reviewed_by="system",
                    )
                    claim_status = "in_review"
                    logger.warning(
                        "auto_payout_blocked phone=%s claim_id=%s claim_type=%s reason=%s",
                        phone,
                        claim_row.get("id"),
                        claim_type,
                        str(exc),
                    )
            logger.info(
                "auto_claim_created phone=%s claim_type=%s payout=%s status=%s anomaly_score=%.6f anomaly_flagged=%s zone_affinity=%.2f data_source=%s",
                phone,
                claim_type,
                payout,
                claim_status,
                float(anomaly["anomaly_score"]),
                bool(anomaly["anomaly_flagged"]),
                zone_affinity,
                state.get("dataSource"),
            )


class TriggerMonitor:
    def __init__(self) -> None:
        self._scheduler = AsyncIOScheduler(timezone="UTC")
        self._started = False

    async def start(self) -> None:
        if self._started:
            return
        self._scheduler.add_job(
            refresh_live_trigger_state,
            "interval",
            minutes=max(1, int(settings.trigger_poll_minutes)),
            id="trigger_refresh",
            replace_existing=True,
        )
        try:
            await refresh_live_trigger_state()
        except Exception:
            # Do not block API startup if one refresh cycle fails.
            logger.exception("trigger_initial_refresh_failed")
        self._scheduler.start()
        self._started = True
        logger.info("trigger_monitor_started interval_minutes=%s", settings.trigger_poll_minutes)

    async def stop(self) -> None:
        if not self._started:
            return
        self._scheduler.shutdown(wait=False)
        self._started = False
        logger.info("trigger_monitor_stopped")


trigger_monitor = TriggerMonitor()
