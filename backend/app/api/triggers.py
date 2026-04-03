from __future__ import annotations

import logging
from typing import Any, Dict

from fastapi import APIRouter, Depends, Query

from ..core.dependencies import get_current_worker
from ..core.zone_cache import resolve_zone
from ..models.schemas import (
    ApiResponse,
    TriggerOut,
    TriggerForceRequest,
    TriggerForceOut,
    ZoneLockReportRequest,
    ZoneLockReportOut,
)
from ..services.trigger_monitor import get_live_trigger_state, force_trigger_for_zone
from ..core.db import create_zonelock_report, list_zonelock_reports_for_zone, increment_zonelock_report_verification

router = APIRouter(tags=["triggers"])
logger = logging.getLogger(__name__)

@router.get("/active", response_model=ApiResponse)
async def get_active_triggers(
    zone: str = Query(...),
    _worker: dict = Depends(get_current_worker),
) -> ApiResponse:
    pincode, zone_data = resolve_zone(zone)
    logger.info("triggers_requested zone=%s pincode=%s", zone, pincode)
    live_trigger_state: Dict[str, Dict[str, Any]] = get_live_trigger_state()

    if pincode in live_trigger_state:
        state = live_trigger_state[pincode]
        logger.info("triggers_served source=live pincode=%s", pincode)
        return ApiResponse(
            success=True,
            data=TriggerOut(
                hasActiveAlert=bool(state.get("hasActiveAlert", False)),
                alertType=str(state.get("alertType", "none")),
                alertTitle=str(state.get("alertTitle", "No active trigger")),
                alertDescription=str(state.get("alertDescription", "No active disruption trigger in your zone.")),
                confidence=float(state.get("confidence", 0.55)),
                source="live",
            ),
        )

    flood_score = float(zone_data.get("flood_risk_score", 0.0))
    traffic_score = float(zone_data.get("traffic_congestion_score", 0.0))

    if flood_score >= 0.75:
        logger.info("triggers_served source=static-risk alert=rain pincode=%s", pincode)
        return ApiResponse(
            success=True,
            data=TriggerOut(
                hasActiveAlert=True,
                alertType="rain",
                alertTitle="RainLock risk elevated",
                alertDescription="Static risk indicates high rainfall vulnerability in this zone.",
                confidence=min(0.99, 0.75 + (flood_score - 0.75)),
                source="static-risk",
            ),
        )

    if traffic_score >= 0.80:
        logger.info("triggers_served source=static-risk alert=traffic pincode=%s", pincode)
        return ApiResponse(
            success=True,
            data=TriggerOut(
                hasActiveAlert=True,
                alertType="traffic",
                alertTitle="TrafficBlock risk elevated",
                alertDescription="Static risk indicates high congestion vulnerability in this zone.",
                confidence=min(0.97, 0.70 + (traffic_score - 0.70)),
                source="static-risk",
            ),
        )

    return ApiResponse(
        success=True,
        data=TriggerOut(
            hasActiveAlert=False,
            alertType="none",
            alertTitle="No active trigger",
            alertDescription="No active disruption trigger in your zone.",
            confidence=0.55,
            source="static-risk",
        ),
    )


@router.post("/force", response_model=ApiResponse)
async def force_trigger(
    payload: TriggerForceRequest,
    _worker: dict = Depends(get_current_worker),
) -> ApiResponse:
    result = await force_trigger_for_zone(
        zone_key=payload.zone,
        claim_type=payload.claimType,
        alert_title=payload.alertTitle,
        alert_description=payload.alertDescription,
        confidence=payload.confidence,
        source="manual",
    )
    return ApiResponse(
        success=True,
        data=TriggerForceOut(**result),
        message="Trigger created and auto payouts processed",
    )


@router.post("/zonelock/report", response_model=ApiResponse)
async def report_zonelock(
    req: ZoneLockReportRequest,
    worker: dict = Depends(get_current_worker),
) -> ApiResponse:
    """
    Worker reports a suspected ZoneLock event (curfew, bandh, strike).
    Auto-confirms if 2+ workers report same event within 30 minutes.
    """
    phone = str(worker.get("phone"))
    zone_pincode = str(worker.get("zone_pincode"))
    zone_name = str(worker.get("zone_name"))

    # Create report
    report = await create_zonelock_report(
        phone=phone,
        zone_pincode=zone_pincode,
        zone_name=zone_name,
        description=str(req.description),
    )

    # Check if similar reports exist in past 30 minutes
    recent_reports = await list_zonelock_reports_for_zone(zone_pincode)
    from datetime import datetime, timezone, timedelta
    now = datetime.now(timezone.utc)
    cutoff = (now - timedelta(minutes=30)).isoformat()

    similar_count = sum(
        1 for r in recent_reports
        if r["id"] != report["id"] and r["created_at"] >= cutoff
    )

    if similar_count >= 1:
        # Auto-confirm: 2 or more independent reports
        await increment_zonelock_report_verification(report["id"])
        logger.info(
            f"zonelock_auto_confirmed report_id={report['id']} phone={phone} zone={zone_pincode} similar_reports={similar_count + 1}"
        )
        # TODO: Trigger auto-claims for all workers in zone
    else:
        logger.info(
            f"zonelock_report_created report_id={report['id']} phone={phone} zone={zone_pincode} status=pending_review"
        )

    return ApiResponse(
        success=True,
        data=ZoneLockReportOut(
            id=report["id"],
            zonePincode=report["zone_pincode"],
            zoneName=report["zone_name"],
            description=report["description"],
            status=report["status"],
            confidence=report["confidence"],
            verifiedCount=report["verified_count"],
            createdAt=report["created_at"],
        ),
    )
