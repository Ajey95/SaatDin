from __future__ import annotations

import asyncio
import json
import logging
import re
from datetime import datetime, timedelta, timezone
from pathlib import Path
from typing import Any, Dict, Iterable, List, Optional

import asyncpg

from .config import settings

logger = logging.getLogger(__name__)

_POOL: Optional[asyncpg.Pool] = None

_SCHEMA_BOOTSTRAP_SQL: List[str] = [
    """
    CREATE TABLE IF NOT EXISTS otp_codes (
        phone TEXT PRIMARY KEY,
        otp_hash TEXT NOT NULL,
        expires_at TIMESTAMPTZ NOT NULL,
        attempts INTEGER NOT NULL DEFAULT 0,
        last_sent_at TIMESTAMPTZ
    )
    """,
    """
    CREATE TABLE IF NOT EXISTS workers (
        phone TEXT PRIMARY KEY,
        name TEXT NOT NULL,
        platform_name TEXT NOT NULL,
        zone_pincode TEXT NOT NULL,
        zone_name TEXT NOT NULL,
        plan_name TEXT NOT NULL,
        pending_plan_name TEXT,
        pending_plan_effective_at TIMESTAMPTZ,
        payout_primary_upi TEXT,
        payout_primary_verified INTEGER NOT NULL DEFAULT 0,
        payout_backup_upi TEXT,
        payout_backup_verified INTEGER NOT NULL DEFAULT 0,
        payout_provider_contact TEXT,
        created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
        updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
    )
    """,
    """
    CREATE TABLE IF NOT EXISTS worker_location_signals (
        phone TEXT PRIMARY KEY,
        latitude DOUBLE PRECISION,
        longitude DOUBLE PRECISION,
        accuracy_meters DOUBLE PRECISION,
        captured_at TIMESTAMPTZ,
        tower_metadata_json JSONB,
        motion_metadata_json JSONB,
        gps_variance_score DOUBLE PRECISION,
        gps_variance_meters DOUBLE PRECISION,
        gps_jump_ratio DOUBLE PRECISION,
        received_at TIMESTAMPTZ
    )
    """,
    """
    CREATE TABLE IF NOT EXISTS worker_location_signal_events (
        id BIGSERIAL PRIMARY KEY,
        phone TEXT NOT NULL,
        latitude DOUBLE PRECISION,
        longitude DOUBLE PRECISION,
        accuracy_meters DOUBLE PRECISION,
        captured_at TIMESTAMPTZ,
        tower_metadata_json JSONB,
        motion_metadata_json JSONB,
        received_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
    )
    """,
    """
    CREATE TABLE IF NOT EXISTS claims (
        id BIGSERIAL PRIMARY KEY,
        phone TEXT NOT NULL,
        claim_type TEXT NOT NULL,
        status TEXT NOT NULL,
        amount DOUBLE PRECISION NOT NULL,
        description TEXT NOT NULL,
        zone_pincode TEXT NOT NULL,
        source TEXT NOT NULL,
        payout_transfer_id BIGINT,
        trigger_signal_id BIGINT,
        reviewed_by TEXT,
        review_notes TEXT,
        reviewed_at TIMESTAMPTZ,
        anomaly_score DOUBLE PRECISION,
        anomaly_threshold DOUBLE PRECISION,
        anomaly_flagged INTEGER,
        anomaly_model_version TEXT,
        anomaly_features_json JSONB,
        anomaly_scored_at TIMESTAMPTZ,
        llm_review_used INTEGER,
        llm_review_status TEXT,
        llm_provider TEXT,
        llm_model TEXT,
        llm_fallback_used INTEGER,
        llm_decision_confidence DOUBLE PRECISION,
        llm_decision_json JSONB,
        llm_attempts_json JSONB,
        llm_validation_error TEXT,
        llm_scored_at TIMESTAMPTZ,
        created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
    )
    """,
    """
    CREATE TABLE IF NOT EXISTS claim_escalations (
        id BIGSERIAL PRIMARY KEY,
        claim_id BIGINT NOT NULL,
        phone TEXT NOT NULL,
        reason TEXT NOT NULL,
        status TEXT NOT NULL,
        review_notes TEXT,
        created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
        updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
    )
    """,
    """
    CREATE TABLE IF NOT EXISTS zonelock_reports (
        id BIGSERIAL PRIMARY KEY,
        phone TEXT NOT NULL,
        zone_pincode TEXT NOT NULL,
        zone_name TEXT NOT NULL,
        description TEXT NOT NULL,
        normalized_keywords JSONB,
        status TEXT NOT NULL,
        confidence DOUBLE PRECISION NOT NULL DEFAULT 0.0,
        verified_count INTEGER NOT NULL DEFAULT 1,
        review_notes TEXT,
        auto_claim_run INTEGER NOT NULL DEFAULT 0,
        created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
        updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
    )
    """,
    """
    CREATE TABLE IF NOT EXISTS trigger_signal_readings (
        id BIGSERIAL PRIMARY KEY,
        zone_pincode TEXT NOT NULL,
        signal_type TEXT NOT NULL,
        reading_value DOUBLE PRECISION NOT NULL,
        secondary_value DOUBLE PRECISION,
        meets_threshold INTEGER NOT NULL,
        metadata_json JSONB,
        observed_at TIMESTAMPTZ NOT NULL,
        source TEXT NOT NULL
    )
    """,
    """
    CREATE TABLE IF NOT EXISTS payout_transfers (
        id BIGSERIAL PRIMARY KEY,
        claim_id BIGINT,
        phone TEXT NOT NULL,
        upi_id TEXT NOT NULL,
        amount DOUBLE PRECISION NOT NULL,
        provider TEXT NOT NULL,
        provider_payout_id TEXT NOT NULL,
        provider_status TEXT NOT NULL,
        status TEXT NOT NULL,
        note TEXT,
        metadata_json JSONB,
        created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
        updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
    )
    """,
    """
    CREATE TABLE IF NOT EXISTS premium_payments (
        id BIGSERIAL PRIMARY KEY,
        phone TEXT NOT NULL,
        week_start_date DATE NOT NULL,
        amount DOUBLE PRECISION NOT NULL,
        status TEXT NOT NULL,
        provider_ref TEXT,
        metadata_json JSONB,
        created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
        updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
        UNIQUE(phone, week_start_date)
    )
    """,
    """
    CREATE TABLE IF NOT EXISTS admin_actions (
        id BIGSERIAL PRIMARY KEY,
        actor TEXT NOT NULL,
        action_type TEXT NOT NULL,
        claim_id BIGINT,
        escalation_id BIGINT,
        details_json JSONB,
        created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
    )
    """,
    """
    CREATE TABLE IF NOT EXISTS fraud_cluster_runs (
        id BIGSERIAL PRIMARY KEY,
        started_at TIMESTAMPTZ NOT NULL,
        finished_at TIMESTAMPTZ,
        status TEXT NOT NULL,
        error_message TEXT,
        lookback_days INTEGER NOT NULL,
        time_bucket_minutes INTEGER NOT NULL,
        min_edge_support INTEGER NOT NULL,
        medium_risk_threshold DOUBLE PRECISION NOT NULL,
        high_risk_threshold DOUBLE PRECISION NOT NULL,
        claims_scanned INTEGER NOT NULL DEFAULT 0,
        edge_count INTEGER NOT NULL DEFAULT 0,
        cluster_count INTEGER NOT NULL DEFAULT 0,
        flagged_cluster_count INTEGER NOT NULL DEFAULT 0,
        created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
    )
    """,
    """
    CREATE TABLE IF NOT EXISTS fraud_co_claim_clusters (
        id BIGSERIAL PRIMARY KEY,
        run_id BIGINT NOT NULL,
        cluster_key TEXT NOT NULL,
        risk_score DOUBLE PRECISION NOT NULL,
        risk_level TEXT NOT NULL,
        member_count INTEGER NOT NULL,
        edge_count INTEGER NOT NULL,
        event_count INTEGER NOT NULL,
        frequency_score DOUBLE PRECISION NOT NULL,
        recency_score DOUBLE PRECISION NOT NULL,
        supporting_metadata_json JSONB,
        created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
    )
    """,
    """
    CREATE TABLE IF NOT EXISTS fraud_co_claim_cluster_members (
        id BIGSERIAL PRIMARY KEY,
        cluster_id BIGINT NOT NULL,
        phone TEXT NOT NULL,
        claim_count INTEGER NOT NULL,
        first_claim_at TIMESTAMPTZ,
        last_claim_at TIMESTAMPTZ,
        created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
    )
    """,
    """
    CREATE TABLE IF NOT EXISTS fraud_co_claim_cluster_edges (
        id BIGSERIAL PRIMARY KEY,
        cluster_id BIGINT NOT NULL,
        phone_a TEXT NOT NULL,
        phone_b TEXT NOT NULL,
        co_claim_count INTEGER NOT NULL,
        recency_weight DOUBLE PRECISION NOT NULL,
        edge_weight DOUBLE PRECISION NOT NULL,
        last_co_claim_at TIMESTAMPTZ,
        supporting_metadata_json JSONB,
        created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
    )
    """,
    """
    CREATE TABLE IF NOT EXISTS zone_risk (
        pincode TEXT PRIMARY KEY,
        zone_json JSONB NOT NULL
    )
    """,
]

_REQUIRED_COLUMNS: Dict[str, Dict[str, str]] = {
    "workers": {
        "pending_plan_name": "TEXT",
        "pending_plan_effective_at": "TIMESTAMPTZ",
        "payout_primary_upi": "TEXT",
        "payout_primary_verified": "INTEGER",
        "payout_backup_upi": "TEXT",
        "payout_backup_verified": "INTEGER",
        "payout_provider_contact": "TEXT",
        "created_at": "TIMESTAMPTZ",
        "updated_at": "TIMESTAMPTZ",
    },
    "worker_location_signals": {
        "captured_at": "TIMESTAMPTZ",
        "tower_metadata_json": "JSONB",
        "motion_metadata_json": "JSONB",
        "gps_variance_score": "DOUBLE PRECISION",
        "gps_variance_meters": "DOUBLE PRECISION",
        "gps_jump_ratio": "DOUBLE PRECISION",
        "received_at": "TIMESTAMPTZ",
    },
    "worker_location_signal_events": {
        "captured_at": "TIMESTAMPTZ",
        "tower_metadata_json": "JSONB",
        "motion_metadata_json": "JSONB",
        "received_at": "TIMESTAMPTZ",
    },
    "claims": {
        "payout_transfer_id": "BIGINT",
        "trigger_signal_id": "BIGINT",
        "reviewed_by": "TEXT",
        "review_notes": "TEXT",
        "reviewed_at": "TIMESTAMPTZ",
        "anomaly_score": "DOUBLE PRECISION",
        "anomaly_threshold": "DOUBLE PRECISION",
        "anomaly_flagged": "INTEGER",
        "anomaly_model_version": "TEXT",
        "anomaly_features_json": "JSONB",
        "anomaly_scored_at": "TIMESTAMPTZ",
        "llm_decision_json": "JSONB",
        "llm_attempts_json": "JSONB",
        "llm_review_used": "INTEGER",
        "llm_review_status": "TEXT",
        "llm_provider": "TEXT",
        "llm_model": "TEXT",
        "llm_fallback_used": "INTEGER",
        "llm_decision_confidence": "DOUBLE PRECISION",
        "llm_validation_error": "TEXT",
        "llm_scored_at": "TIMESTAMPTZ",
        "created_at": "TIMESTAMPTZ",
    },
    "claim_escalations": {
        "review_notes": "TEXT",
        "created_at": "TIMESTAMPTZ",
        "updated_at": "TIMESTAMPTZ",
    },
    "zonelock_reports": {
        "normalized_keywords": "JSONB",
        "status": "TEXT",
        "confidence": "DOUBLE PRECISION",
        "verified_count": "INTEGER",
        "review_notes": "TEXT",
        "auto_claim_run": "INTEGER",
        "created_at": "TIMESTAMPTZ",
        "updated_at": "TIMESTAMPTZ",
    },
    "trigger_signal_readings": {
        "secondary_value": "DOUBLE PRECISION",
        "meets_threshold": "INTEGER",
        "metadata_json": "JSONB",
        "observed_at": "TIMESTAMPTZ",
        "source": "TEXT",
    },
    "payout_transfers": {
        "note": "TEXT",
        "metadata_json": "JSONB",
        "created_at": "TIMESTAMPTZ",
        "updated_at": "TIMESTAMPTZ",
    },
    "admin_actions": {
        "details_json": "JSONB",
        "created_at": "TIMESTAMPTZ",
    },
    "fraud_cluster_runs": {
        "finished_at": "TIMESTAMPTZ",
        "status": "TEXT",
        "error_message": "TEXT",
        "lookback_days": "INTEGER",
        "time_bucket_minutes": "INTEGER",
        "min_edge_support": "INTEGER",
        "medium_risk_threshold": "DOUBLE PRECISION",
        "high_risk_threshold": "DOUBLE PRECISION",
        "claims_scanned": "INTEGER",
        "edge_count": "INTEGER",
        "cluster_count": "INTEGER",
        "flagged_cluster_count": "INTEGER",
        "created_at": "TIMESTAMPTZ",
    },
    "fraud_co_claim_clusters": {
        "supporting_metadata_json": "JSONB",
        "created_at": "TIMESTAMPTZ",
    },
    "fraud_co_claim_cluster_members": {
        "first_claim_at": "TIMESTAMPTZ",
        "last_claim_at": "TIMESTAMPTZ",
        "created_at": "TIMESTAMPTZ",
    },
    "fraud_co_claim_cluster_edges": {
        "last_co_claim_at": "TIMESTAMPTZ",
        "supporting_metadata_json": "JSONB",
        "created_at": "TIMESTAMPTZ",
    },
    "zone_risk": {
        "pincode": "TEXT",
        "zone_json": "JSONB",
    },
}


def _repo_root() -> Path:
    return Path(__file__).resolve().parents[3]


def _zone_seed_asset() -> Path:
    return _repo_root() / "assets" / "data" / "zone_risk_runtime.json"


def _utc_now() -> datetime:
    return datetime.now(timezone.utc)


def _supabase_dsn() -> str:
    dsn = str(settings.supabase_db_url or "").strip()
    if not dsn:
        raise RuntimeError("SUPABASE_DB_URL is not configured")
    return dsn


async def _pool() -> asyncpg.Pool:
    global _POOL
    if _POOL is None:
        logger.info("supabase_pool_initializing")
        _POOL = await asyncpg.create_pool(
            dsn=_supabase_dsn(),
            min_size=1,
            max_size=5,
            command_timeout=30,
        )
        logger.info("supabase_pool_ready")
    return _POOL


_PARAM_MARKER = re.compile(r"\?")


def _adapt_query(query: str) -> str:
    index = 0

    def replace(_: re.Match[str]) -> str:
        nonlocal index
        index += 1
        return f"${index}"

    return _PARAM_MARKER.sub(replace, query)


def _to_storage(value: Any) -> Any:
    if isinstance(value, datetime):
        if value.tzinfo is None:
            value = value.replace(tzinfo=timezone.utc)
        return value.astimezone(timezone.utc)
    if isinstance(value, bool):
        return value
    if isinstance(value, (dict, list)):
        return json.dumps(value)
    return value


def _to_iso(value: Any) -> Optional[str]:
    if value is None:
        return None
    if isinstance(value, datetime):
        if value.tzinfo is None:
            value = value.replace(tzinfo=timezone.utc)
        return value.astimezone(timezone.utc).isoformat()
    text = str(value).strip()
    return text or None


def _decode_json_value(key: str, value: Any) -> Any:
    if value is None:
        return None
    if isinstance(value, (dict, list, int, float, bool)):
        return value
    if isinstance(value, str) and key.endswith("_json"):
        try:
            return json.loads(value)
        except json.JSONDecodeError:
            return value
    return value


def _row_to_dict(row: Optional[asyncpg.Record]) -> Optional[Dict[str, Any]]:
    if row is None:
        return None
    return {key: _decode_json_value(key, row[key]) for key in row.keys()}


def _rows_to_dicts(rows: Iterable[asyncpg.Record]) -> List[Dict[str, Any]]:
    return [_row_to_dict(row) for row in rows if row is not None]  # type: ignore[list-item]


def _coerce_dt(value: str | datetime | None) -> Optional[datetime]:
    if value is None:
        return None
    if isinstance(value, datetime):
        if value.tzinfo is None:
            return value.replace(tzinfo=timezone.utc)
        return value.astimezone(timezone.utc)
    parsed = datetime.fromisoformat(value)
    if parsed.tzinfo is None:
        parsed = parsed.replace(tzinfo=timezone.utc)
    return parsed.astimezone(timezone.utc)


async def _run_write(query: str, params: Iterable[Any] = ()) -> int:
    pool = await _pool()
    adapted_query = _adapt_query(query)
    values = tuple(_to_storage(value) for value in params)
    async with pool.acquire() as conn:
        try:
            result = await conn.execute(adapted_query, *values)
            # asyncpg returns strings like "UPDATE 3" or "DELETE 1"
            parts = result.split()
            return int(parts[-1]) if parts and parts[-1].isdigit() else 0
        except Exception:
            logger.exception("supabase_write_failed query=%s", adapted_query)
            raise


async def _fetchone(query: str, params: Iterable[Any] = ()) -> Optional[Dict[str, Any]]:
    pool = await _pool()
    adapted_query = _adapt_query(query)
    values = tuple(_to_storage(value) for value in params)
    async with pool.acquire() as conn:
        try:
            row = await conn.fetchrow(adapted_query, *values)
            return _row_to_dict(row)
        except Exception:
            logger.exception("supabase_fetchone_failed query=%s", adapted_query)
            raise


async def _fetchall(query: str, params: Iterable[Any] = ()) -> List[Dict[str, Any]]:
    pool = await _pool()
    adapted_query = _adapt_query(query)
    values = tuple(_to_storage(value) for value in params)
    async with pool.acquire() as conn:
        try:
            rows = await conn.fetch(adapted_query, *values)
            return _rows_to_dicts(rows)
        except Exception:
            logger.exception("supabase_fetchall_failed query=%s", adapted_query)
            raise


async def _fetchval(query: str, params: Iterable[Any] = (), default: Any = None) -> Any:
    row = await _fetchone(query, params)
    if not row:
        return default
    return next(iter(row.values()), default)


async def _ensure_schema(conn: asyncpg.Connection) -> None:
    for ddl in _SCHEMA_BOOTSTRAP_SQL:
        await conn.execute(ddl)

    for table_name, columns in _REQUIRED_COLUMNS.items():
        for column_name, column_type in columns.items():
            await conn.execute(
                f'ALTER TABLE "{table_name}" ADD COLUMN IF NOT EXISTS "{column_name}" {column_type}'
            )


async def _seed_zone_risk_if_empty(conn: asyncpg.Connection) -> None:
    count = int(await conn.fetchval("SELECT COUNT(*) FROM zone_risk") or 0)
    if count > 0:
        return

    asset_path = _zone_seed_asset()
    if not asset_path.exists():
        logger.warning("zone_seed_asset_missing path=%s", asset_path)
        return

    try:
        raw = json.loads(asset_path.read_text(encoding="utf-8"))
    except Exception:
        logger.exception("zone_seed_asset_invalid path=%s", asset_path)
        return

    pincodes = raw.get("pincodes") if isinstance(raw, dict) else None
    if not isinstance(pincodes, dict) or not pincodes:
        logger.warning("zone_seed_asset_no_rows path=%s", asset_path)
        return

    query = (
        "INSERT INTO zone_risk (pincode, zone_json) VALUES ($1, $2::jsonb) "
        "ON CONFLICT (pincode) DO UPDATE SET zone_json = EXCLUDED.zone_json"
    )
    for pincode, zone_payload in pincodes.items():
        await conn.execute(query, str(pincode), json.dumps(zone_payload))
    logger.info("zone_seeded_from_asset rows=%s", len(pincodes))


async def init_db() -> None:
    pool = await _pool()
    required_tables = (
        "otp_codes",
        "workers",
        "worker_location_signals",
        "worker_location_signal_events",
        "claims",
        "zonelock_reports",
        "claim_escalations",
        "trigger_signal_readings",
        "payout_transfers",
        "admin_actions",
        "fraud_cluster_runs",
        "fraud_co_claim_clusters",
        "fraud_co_claim_cluster_members",
        "fraud_co_claim_cluster_edges",
        "zone_risk",
    )
    async with pool.acquire() as conn:
        await _ensure_schema(conn)
        await _seed_zone_risk_if_empty(conn)

        for table_name in required_tables:
            exists = await conn.fetchval("SELECT to_regclass($1) IS NOT NULL", table_name)
            if not exists:
                raise RuntimeError(f"Supabase table not found: {table_name}")

        for table_name, columns in _REQUIRED_COLUMNS.items():
            rows = await conn.fetch(
                "SELECT column_name FROM information_schema.columns WHERE table_name = $1",
                table_name,
            )
            present = {str(row["column_name"]) for row in rows}
            missing = [column for column in columns if column not in present]
            if missing:
                raise RuntimeError(f"Supabase table {table_name} missing columns: {', '.join(missing)}")

    logger.info("supabase_schema_verified tables=%s", len(required_tables))


async def close_db() -> None:
    global _POOL
    if _POOL is not None:
        await _POOL.close()
        _POOL = None


async def healthcheck_db() -> bool:
    try:
        await _fetchval("SELECT 1", ())
        return True
    except Exception:
        logger.exception("supabase_healthcheck_failed")
        return False


async def save_otp(phone: str, otp_hash: str, expires_at: str | datetime) -> None:
    now = _utc_now()
    await _run_write(
        """
        INSERT INTO otp_codes (phone, otp_hash, expires_at, attempts, last_sent_at)
        VALUES (?, ?, ?, 0, ?)
        ON CONFLICT(phone) DO UPDATE SET
            otp_hash = excluded.otp_hash,
            expires_at = excluded.expires_at,
            attempts = 0,
            last_sent_at = excluded.last_sent_at
        """,
        (phone, otp_hash, _coerce_dt(expires_at), now),
    )


async def get_otp(phone: str) -> Optional[Dict[str, Any]]:
    return await _fetchone("SELECT * FROM otp_codes WHERE phone = ?", (phone,))


async def increment_otp_attempts(phone: str) -> None:
    await _run_write("UPDATE otp_codes SET attempts = attempts + 1 WHERE phone = ?", (phone,))


async def delete_otp(phone: str) -> None:
    await _run_write("DELETE FROM otp_codes WHERE phone = ?", (phone,))


async def upsert_worker(
    *,
    phone: str,
    name: str,
    platform_name: str,
    zone_pincode: str,
    zone_name: str,
    plan_name: str,
) -> None:
    now = _utc_now()
    default_upi = f"{phone}@saatdin"
    await _run_write(
        """
        INSERT INTO workers (
            phone,
            name,
            platform_name,
            zone_pincode,
            zone_name,
            plan_name,
            pending_plan_name,
            pending_plan_effective_at,
            payout_primary_upi,
            payout_primary_verified,
            payout_backup_upi,
            payout_backup_verified,
            payout_provider_contact,
            created_at,
            updated_at
        )
        VALUES (?, ?, ?, ?, ?, ?, NULL, NULL, ?, 1, NULL, 0, ?, ?, ?)
        ON CONFLICT(phone) DO UPDATE SET
            name = excluded.name,
            platform_name = excluded.platform_name,
            zone_pincode = excluded.zone_pincode,
            zone_name = excluded.zone_name,
            plan_name = excluded.plan_name,
            pending_plan_name = NULL,
            pending_plan_effective_at = NULL,
            payout_primary_upi = COALESCE(workers.payout_primary_upi, excluded.payout_primary_upi),
            payout_provider_contact = excluded.payout_provider_contact,
            updated_at = excluded.updated_at
        """,
        (phone, name, platform_name, zone_pincode, zone_name, plan_name, default_upi, phone, now, now),
    )


async def get_worker(phone: str) -> Optional[Dict[str, Any]]:
    return await _fetchone("SELECT * FROM workers WHERE phone = ?", (phone,))


async def update_worker_plan(phone: str, plan_name: str) -> None:
    await _run_write(
        """
        UPDATE workers
        SET plan_name = ?, pending_plan_name = NULL, pending_plan_effective_at = NULL, updated_at = ?
        WHERE phone = ?
        """,
        (plan_name, _utc_now(), phone),
    )


async def set_pending_worker_plan(phone: str, plan_name: str, effective_at: datetime) -> None:
    await _run_write(
        """
        UPDATE workers
        SET pending_plan_name = ?, pending_plan_effective_at = ?, updated_at = ?
        WHERE phone = ?
        """,
        (plan_name, effective_at, _utc_now(), phone),
    )


async def apply_due_pending_worker_plan(phone: str, now: Optional[datetime] = None) -> bool:
    worker = await get_worker(phone)
    if not worker:
        return False
    effective_at = _coerce_dt(worker.get("pending_plan_effective_at"))
    if not worker.get("pending_plan_name") or effective_at is None:
        return False
    if effective_at <= (now or _utc_now()):
        await update_worker_plan(phone, str(worker["pending_plan_name"]))
        return True
    return False


async def list_workers_by_zone(zone_pincode: str) -> List[Dict[str, Any]]:
    return await _fetchall(
        "SELECT * FROM workers WHERE zone_pincode = ? ORDER BY created_at ASC",
        (zone_pincode,),
    )


def _calculate_gps_variance(rows: List[Dict[str, Any]]) -> Dict[str, float]:
    points = []
    for row in rows:
        lat = row.get("latitude")
        lon = row.get("longitude")
        if lat is None or lon is None:
            continue
        points.append((float(lat), float(lon), row))
    if len(points) < 3:
        return {"variance_meters": 0.0, "jump_ratio": 0.0, "score": 0.5}

    avg_lat = sum(point[0] for point in points) / len(points)
    avg_lon = sum(point[1] for point in points) / len(points)

    def distance_meters(lat1: float, lon1: float, lat2: float, lon2: float) -> float:
        dx = (lon2 - lon1) * 111_000 * 0.9
        dy = (lat2 - lat1) * 111_000
        return (dx * dx + dy * dy) ** 0.5

    deviations = [distance_meters(lat, lon, avg_lat, avg_lon) for lat, lon, _ in points]
    variance_meters = sum(deviations) / len(deviations)

    jumps = 0
    total_pairs = 0
    sorted_points = sorted(
        points,
        key=lambda point: _to_iso(point[2].get("captured_at") or point[2].get("received_at")) or "",
    )
    for index in range(1, len(sorted_points)):
        previous = sorted_points[index - 1]
        current = sorted_points[index]
        total_pairs += 1
        jump_distance = distance_meters(previous[0], previous[1], current[0], current[1])
        previous_at = _coerce_dt(previous[2].get("captured_at") or previous[2].get("received_at"))
        current_at = _coerce_dt(current[2].get("captured_at") or current[2].get("received_at"))
        if previous_at is None or current_at is None:
            continue
        elapsed_minutes = max(1.0, (current_at - previous_at).total_seconds() / 60.0)
        if jump_distance > 5000 and elapsed_minutes <= 15:
            jumps += 1
    jump_ratio = float(jumps) / float(max(1, total_pairs))

    score = 0.85
    if variance_meters > 6000:
        score = 0.2
    elif variance_meters > 3000:
        score = 0.45
    elif variance_meters > 1200:
        score = 0.65
    if jump_ratio >= 0.5:
        score = min(score, 0.15)
    elif jump_ratio > 0:
        score = min(score, 0.4)
    return {
        "variance_meters": round(variance_meters, 3),
        "jump_ratio": round(jump_ratio, 3),
        "score": round(score, 3),
    }


async def list_worker_location_signal_events(
    phone: str,
    *,
    since: Optional[datetime] = None,
    limit: int = 24,
) -> List[Dict[str, Any]]:
    if since is not None:
        return await _fetchall(
            """
            SELECT *
            FROM worker_location_signal_events
            WHERE phone = ? AND received_at >= ?
            ORDER BY received_at DESC
            LIMIT ?
            """,
            (phone, since, max(1, int(limit))),
        )
    return await _fetchall(
        """
        SELECT *
        FROM worker_location_signal_events
        WHERE phone = ?
        ORDER BY received_at DESC
        LIMIT ?
        """,
        (phone, max(1, int(limit))),
    )


async def upsert_worker_location_signal(
    *,
    phone: str,
    latitude: Optional[float] = None,
    longitude: Optional[float] = None,
    accuracy_meters: Optional[float] = None,
    captured_at: Optional[str | datetime] = None,
    tower_metadata: Optional[Dict[str, Any]] = None,
    motion_metadata: Optional[Dict[str, Any]] = None,
) -> Dict[str, Any]:
    now = _utc_now()
    captured_value = _coerce_dt(captured_at) if captured_at is not None else None
    pool = await _pool()
    async with pool.acquire() as conn:
        await conn.execute(
            _adapt_query(
                """
                INSERT INTO worker_location_signal_events (
                    phone,
                    latitude,
                    longitude,
                    accuracy_meters,
                    captured_at,
                    tower_metadata_json,
                    motion_metadata_json,
                    received_at
                )
                VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                """
            ),
            phone,
            latitude,
            longitude,
            accuracy_meters,
            _to_storage(captured_value),
            _to_storage(tower_metadata),
            _to_storage(motion_metadata),
            _to_storage(now),
        )

        recent_rows = await conn.fetch(
            _adapt_query(
                """
                SELECT *
                FROM worker_location_signal_events
                WHERE phone = ?
                ORDER BY received_at DESC
                LIMIT 24
                """
            ),
            phone,
        )
        variance = _calculate_gps_variance(_rows_to_dicts(recent_rows))

        await conn.execute(
            _adapt_query(
                """
                INSERT INTO worker_location_signals (
                    phone,
                    latitude,
                    longitude,
                    accuracy_meters,
                    captured_at,
                    tower_metadata_json,
                    motion_metadata_json,
                    gps_variance_score,
                    gps_variance_meters,
                    gps_jump_ratio,
                    received_at
                )
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(phone) DO UPDATE SET
                    latitude = excluded.latitude,
                    longitude = excluded.longitude,
                    accuracy_meters = excluded.accuracy_meters,
                    captured_at = excluded.captured_at,
                    tower_metadata_json = excluded.tower_metadata_json,
                    motion_metadata_json = excluded.motion_metadata_json,
                    gps_variance_score = excluded.gps_variance_score,
                    gps_variance_meters = excluded.gps_variance_meters,
                    gps_jump_ratio = excluded.gps_jump_ratio,
                    received_at = excluded.received_at
                """
            ),
            phone,
            latitude,
            longitude,
            accuracy_meters,
            _to_storage(captured_value),
            _to_storage(tower_metadata),
            _to_storage(motion_metadata),
            variance["score"],
            variance["variance_meters"],
            variance["jump_ratio"],
            _to_storage(now),
        )

    return {
        "phone": phone,
        "latitude": latitude,
        "longitude": longitude,
        "accuracy_meters": accuracy_meters,
        "captured_at": _to_iso(captured_value),
        "tower_metadata_json": tower_metadata,
        "motion_metadata_json": motion_metadata,
        "gps_variance_score": variance["score"],
        "gps_variance_meters": variance["variance_meters"],
        "gps_jump_ratio": variance["jump_ratio"],
        "received_at": _to_iso(now),
    }


async def get_worker_location_signal(phone: str) -> Optional[Dict[str, Any]]:
    return await _fetchone("SELECT * FROM worker_location_signals WHERE phone = ?", (phone,))


async def purge_stale_worker_location_signals(*, retention_days: int) -> int:
    cutoff = _utc_now() - timedelta(days=max(1, int(retention_days)))
    return await _run_write(
        "DELETE FROM worker_location_signal_events WHERE received_at < ?",
        (_to_storage(cutoff),),
    )


async def create_claim(
    *,
    phone: str,
    claim_type: str,
    status: str,
    amount: float,
    description: str,
    zone_pincode: str,
    source: str,
    payout_transfer_id: Optional[int] = None,
    trigger_signal_id: Optional[int] = None,
    reviewed_by: Optional[str] = None,
    review_notes: Optional[str] = None,
    reviewed_at: Optional[str | datetime] = None,
    anomaly_score: Optional[float] = None,
    anomaly_threshold: Optional[float] = None,
    anomaly_flagged: Optional[bool] = None,
    anomaly_model_version: Optional[str] = None,
    anomaly_features: Optional[Dict[str, Any]] = None,
    anomaly_scored_at: Optional[str | datetime] = None,
    llm_review_used: Optional[bool] = None,
    llm_review_status: Optional[str] = None,
    llm_provider: Optional[str] = None,
    llm_model: Optional[str] = None,
    llm_fallback_used: Optional[bool] = None,
    llm_decision_confidence: Optional[float] = None,
    llm_decision_json: Optional[Dict[str, Any]] = None,
    llm_attempts: Optional[List[Dict[str, Any]]] = None,
    llm_validation_error: Optional[str] = None,
    llm_scored_at: Optional[str | datetime] = None,
) -> Dict[str, Any]:
    now = _utc_now()
    row = await _fetchone(
        """
        INSERT INTO claims (
            phone,
            claim_type,
            status,
            amount,
            description,
            zone_pincode,
            source,
            payout_transfer_id,
            trigger_signal_id,
            reviewed_by,
            review_notes,
            reviewed_at,
            anomaly_score,
            anomaly_threshold,
            anomaly_flagged,
            anomaly_model_version,
            anomaly_features_json,
            anomaly_scored_at,
            llm_review_used,
            llm_review_status,
            llm_provider,
            llm_model,
            llm_fallback_used,
            llm_decision_confidence,
            llm_decision_json,
            llm_attempts_json,
            llm_validation_error,
            llm_scored_at,
            created_at
        )
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        RETURNING *
        """,
        (
            phone,
            claim_type,
            status,
            amount,
            description,
            zone_pincode,
            source,
            payout_transfer_id,
            trigger_signal_id,
            reviewed_by,
            review_notes,
            _to_storage(_coerce_dt(reviewed_at)),
            anomaly_score,
            anomaly_threshold,
            anomaly_flagged,
            anomaly_model_version,
            _to_storage(anomaly_features),
            _to_storage(_coerce_dt(anomaly_scored_at)),
            llm_review_used,
            llm_review_status,
            llm_provider,
            llm_model,
            llm_fallback_used,
            llm_decision_confidence,
            _to_storage(llm_decision_json),
            _to_storage(llm_attempts),
            llm_validation_error,
            _to_storage(_coerce_dt(llm_scored_at)),
            _to_storage(now),
        ),
    )
    return row or {}


async def get_claim(claim_id: int) -> Optional[Dict[str, Any]]:
    return await _fetchone("SELECT * FROM claims WHERE id = ?", (int(claim_id),))


async def set_claim_payout_transfer(claim_id: int, payout_transfer_id: int) -> None:
    await _run_write(
        "UPDATE claims SET payout_transfer_id = ? WHERE id = ?",
        (int(payout_transfer_id), int(claim_id)),
    )


async def update_claim_status(
    claim_id: int,
    *,
    status: str,
    review_notes: Optional[str] = None,
    reviewed_by: Optional[str] = None,
    reviewed_at: Optional[str | datetime] = None,
) -> Optional[Dict[str, Any]]:
    reviewed_value = _coerce_dt(reviewed_at) if reviewed_at is not None else _utc_now()
    await _run_write(
        """
        UPDATE claims
        SET status = ?, review_notes = ?, reviewed_by = ?, reviewed_at = ?
        WHERE id = ?
        """,
        (status, review_notes, reviewed_by, reviewed_value, int(claim_id)),
    )
    return await get_claim(int(claim_id))


async def list_claims_for_phone(phone: str) -> List[Dict[str, Any]]:
    return await _fetchall(
        "SELECT * FROM claims WHERE phone = ? ORDER BY created_at DESC, id DESC",
        (phone,),
    )


async def list_claims(*, status: Optional[str] = None, limit: int = 200) -> List[Dict[str, Any]]:
    if status:
        return await _fetchall(
            """
            SELECT *
            FROM claims
            WHERE status = ?
            ORDER BY created_at DESC, id DESC
            LIMIT ?
            """,
            (status, max(1, int(limit))),
        )
    return await _fetchall(
        """
        SELECT *
        FROM claims
        ORDER BY created_at DESC, id DESC
        LIMIT ?
        """,
        (max(1, int(limit)),),
    )


async def total_settled_amount_for_phone(phone: str) -> float:
    value = await _fetchval(
        "SELECT COALESCE(SUM(amount), 0) AS total FROM claims WHERE phone = ? AND status = 'settled'",
        (phone,),
        0.0,
    )
    return float(value or 0.0)


async def count_claims_for_phone_since(phone: str, since: datetime) -> int:
    value = await _fetchval(
        "SELECT COUNT(*) AS count FROM claims WHERE phone = ? AND created_at >= ?",
        (phone, since),
        0,
    )
    return int(value or 0)


async def has_recent_auto_claim(phone: str, claim_type: str, within_minutes: int = 360) -> bool:
    cutoff = _utc_now() - timedelta(minutes=max(1, int(within_minutes)))
    row = await _fetchone(
        """
        SELECT created_at
        FROM claims
        WHERE phone = ? AND claim_type = ? AND source = 'auto'
        ORDER BY created_at DESC
        LIMIT 1
        """,
        (phone, claim_type),
    )
    if not row:
        return False
    created_at = _coerce_dt(row.get("created_at"))
    return created_at is not None and created_at >= cutoff


async def count_settled_auto_claim_days_for_phone_since(phone: str, since: datetime) -> int:
    value = await _fetchval(
        """
        SELECT COUNT(DISTINCT DATE(created_at AT TIME ZONE 'UTC')) AS count
        FROM claims
        WHERE phone = ? AND source = 'auto' AND status = 'settled' AND created_at >= ?
        """,
        (phone, since),
        0,
    )
    return int(value or 0)


async def count_settled_claim_days_for_phone_since(phone: str, since: datetime) -> int:
    value = await _fetchval(
        """
        SELECT COUNT(DISTINCT DATE(created_at AT TIME ZONE 'UTC')) AS count
        FROM claims
        WHERE phone = ? AND status = 'settled' AND created_at >= ?
        """,
        (phone, since),
        0,
    )
    return int(value or 0)


async def create_zonelock_report(
    *,
    phone: str,
    zone_pincode: str,
    zone_name: str,
    description: str,
    normalized_keywords: Optional[List[str]] = None,
) -> Dict[str, Any]:
    now = _utc_now()
    row = await _fetchone(
        """
        INSERT INTO zonelock_reports (
            phone,
            zone_pincode,
            zone_name,
            description,
            normalized_keywords,
            status,
            confidence,
            verified_count,
            review_notes,
            auto_claim_run,
            created_at,
            updated_at
        )
        VALUES (?, ?, ?, ?, ?, 'pending', 0.4, 1, NULL, 0, ?, ?)
        RETURNING *
        """,
        (
            phone,
            zone_pincode,
            zone_name,
            description,
            _to_storage(normalized_keywords or []),
            _to_storage(now),
            _to_storage(now),
        ),
    )
    return row or {}


async def get_zonelock_report(report_id: int) -> Optional[Dict[str, Any]]:
    return await _fetchone("SELECT * FROM zonelock_reports WHERE id = ?", (int(report_id),))


async def list_zonelock_reports_for_zone(zone_pincode: str, status: Optional[str] = None) -> List[Dict[str, Any]]:
    if status:
        return await _fetchall(
            """
            SELECT *
            FROM zonelock_reports
            WHERE zone_pincode = ? AND status = ?
            ORDER BY created_at DESC, id DESC
            """,
            (zone_pincode, status),
        )
    return await _fetchall(
        """
        SELECT *
        FROM zonelock_reports
        WHERE zone_pincode = ?
        ORDER BY created_at DESC, id DESC
        """,
        (zone_pincode,),
    )


async def increment_zonelock_report_verification(report_id: int) -> None:
    report = await get_zonelock_report(report_id)
    if not report:
        return
    verified_count = int(report.get("verified_count", 1)) + 1
    confidence = min(0.95, 0.4 + (verified_count * 0.2))
    status = "auto_confirmed" if verified_count >= 2 else str(report.get("status", "pending"))
    await _run_write(
        """
        UPDATE zonelock_reports
        SET verified_count = ?, confidence = ?, status = ?, updated_at = ?
        WHERE id = ?
        """,
        (verified_count, confidence, status, _utc_now(), int(report_id)),
    )


async def update_zonelock_report_status(report_id: int, status: str, review_notes: Optional[str] = None) -> None:
    await _run_write(
        """
        UPDATE zonelock_reports
        SET status = ?, review_notes = ?, updated_at = ?
        WHERE id = ?
        """,
        (status, review_notes, _utc_now(), int(report_id)),
    )


async def mark_zonelock_reports_auto_claimed(report_ids: Iterable[int]) -> None:
    ids = [int(report_id) for report_id in report_ids]
    if not ids:
        return
    placeholders = ", ".join("?" for _ in ids)
    await _run_write(
        f"""
        UPDATE zonelock_reports
        SET auto_claim_run = 1, updated_at = ?, status = 'auto_confirmed'
        WHERE id IN ({placeholders})
        """,
        [_utc_now(), *ids],
    )


async def escalate_claim(
    *,
    claim_id: int,
    phone: str,
    reason: str,
) -> Dict[str, Any]:
    now = _utc_now()
    claim = await get_claim(int(claim_id))
    if claim is None:
        raise ValueError(f"Claim {claim_id} not found")
    if str(claim["phone"]) != phone:
        raise PermissionError("Claim does not belong to requesting worker")

    existing = await _fetchone(
        """
        SELECT *
        FROM claim_escalations
        WHERE claim_id = ? AND status IN ('pending_review', 'under_review')
        ORDER BY created_at DESC
        LIMIT 1
        """,
        (int(claim_id),),
    )
    if existing is not None:
        return existing

    await _run_write(
        """
        UPDATE claims
        SET status = 'escalated', reviewed_by = NULL, review_notes = NULL, reviewed_at = NULL
        WHERE id = ?
        """,
        (int(claim_id),),
    )
    row = await _fetchone(
        """
        INSERT INTO claim_escalations (
            claim_id,
            phone,
            reason,
            status,
            review_notes,
            created_at,
            updated_at
        )
        VALUES (?, ?, ?, 'pending_review', NULL, ?, ?)
        RETURNING *
        """,
        (int(claim_id), phone, reason, _to_storage(now), _to_storage(now)),
    )
    return row or {}


async def get_claim_escalation(escalation_id: int) -> Optional[Dict[str, Any]]:
    return await _fetchone("SELECT * FROM claim_escalations WHERE id = ?", (int(escalation_id),))


async def list_claim_escalations_for_phone(phone: str) -> List[Dict[str, Any]]:
    return await _fetchall(
        """
        SELECT *
        FROM claim_escalations
        WHERE phone = ?
        ORDER BY created_at DESC, id DESC
        """,
        (phone,),
    )


async def list_claim_escalations(*, status: Optional[str] = None, limit: int = 200) -> List[Dict[str, Any]]:
    if status:
        return await _fetchall(
            """
            SELECT *
            FROM claim_escalations
            WHERE status = ?
            ORDER BY created_at DESC, id DESC
            LIMIT ?
            """,
            (status, max(1, int(limit))),
        )
    return await _fetchall(
        """
        SELECT *
        FROM claim_escalations
        ORDER BY created_at DESC, id DESC
        LIMIT ?
        """,
        (max(1, int(limit)),),
    )


async def update_escalation_status(escalation_id: int, status: str, review_notes: Optional[str] = None) -> None:
    await _run_write(
        """
        UPDATE claim_escalations
        SET status = ?, review_notes = ?, updated_at = ?
        WHERE id = ?
        """,
        (status, review_notes, _utc_now(), int(escalation_id)),
    )


async def list_claim_events_since(since: datetime) -> List[Dict[str, Any]]:
    return await _fetchall(
        """
        SELECT id, phone, claim_type, status, amount, zone_pincode, source, created_at
        FROM claims
        WHERE created_at >= ?
        ORDER BY created_at ASC, id ASC
        """,
        (since,),
    )


async def create_trigger_signal_reading(
    *,
    zone_pincode: str,
    signal_type: str,
    reading_value: float,
    secondary_value: Optional[float],
    meets_threshold: bool,
    metadata: Optional[Dict[str, Any]],
    observed_at: Optional[str | datetime] = None,
    source: str = "unknown",
) -> Dict[str, Any]:
    observed = _coerce_dt(observed_at) if observed_at is not None else _utc_now()
    row = await _fetchone(
        """
        INSERT INTO trigger_signal_readings (
            zone_pincode,
            signal_type,
            reading_value,
            secondary_value,
            meets_threshold,
            metadata_json,
            observed_at,
            source
        )
        VALUES (?, ?, ?, ?, ?, ?, ?, ?)
        RETURNING *
        """,
        (
            zone_pincode,
            signal_type,
            float(reading_value),
            float(secondary_value) if secondary_value is not None else None,
            1 if meets_threshold else 0,
            _to_storage(metadata),
            _to_storage(observed),
            source,
        ),
    )
    return row or {}


async def list_trigger_signal_readings(
    *,
    zone_pincode: str,
    signal_type: str,
    since: datetime,
) -> List[Dict[str, Any]]:
    return await _fetchall(
        """
        SELECT *
        FROM trigger_signal_readings
        WHERE zone_pincode = ? AND signal_type = ? AND observed_at >= ?
        ORDER BY observed_at ASC, id ASC
        """,
        (zone_pincode, signal_type, since),
    )


async def create_payout_transfer(
    *,
    claim_id: Optional[int],
    phone: str,
    upi_id: str,
    amount: float,
    provider: str,
    provider_payout_id: str,
    provider_status: str,
    status: str,
    note: Optional[str] = None,
    metadata: Optional[Dict[str, Any]] = None,
) -> Dict[str, Any]:
    now = _utc_now()
    row = await _fetchone(
        """
        INSERT INTO payout_transfers (
            claim_id,
            phone,
            upi_id,
            amount,
            provider,
            provider_payout_id,
            provider_status,
            status,
            note,
            metadata_json,
            created_at,
            updated_at
        )
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        RETURNING *
        """,
        (
            claim_id,
            phone,
            upi_id,
            float(amount),
            provider,
            provider_payout_id,
            provider_status,
            status,
            note,
            _to_storage(metadata),
            _to_storage(now),
            _to_storage(now),
        ),
    )
    return row or {}


async def update_payout_transfer(
    transfer_id: int,
    *,
    provider_status: str,
    status: str,
    note: Optional[str] = None,
    metadata: Optional[Dict[str, Any]] = None,
) -> Optional[Dict[str, Any]]:
    existing = await get_payout_transfer(transfer_id)
    merged_metadata: Optional[Dict[str, Any]]
    if existing and existing.get("metadata_json"):
        try:
            parsed = json.loads(str(existing["metadata_json"]))
        except json.JSONDecodeError:
            parsed = {}
        merged_metadata = parsed if isinstance(parsed, dict) else {}
    else:
        merged_metadata = {}
    if metadata:
        merged_metadata.update(metadata)
    await _run_write(
        """
        UPDATE payout_transfers
        SET provider_status = ?, status = ?, note = ?, metadata_json = ?, updated_at = ?
        WHERE id = ?
        """,
        (provider_status, status, note, merged_metadata, _utc_now(), int(transfer_id)),
    )
    return await get_payout_transfer(int(transfer_id))


async def get_payout_transfer(transfer_id: int) -> Optional[Dict[str, Any]]:
    return await _fetchone("SELECT * FROM payout_transfers WHERE id = ?", (int(transfer_id),))


async def list_payout_transfers_for_phone(phone: str, *, limit: int = 100) -> List[Dict[str, Any]]:
    return await _fetchall(
        """
        SELECT *
        FROM payout_transfers
        WHERE phone = ?
        ORDER BY created_at DESC, id DESC
        LIMIT ?
        """,
        (phone, max(1, int(limit))),
    )


async def list_payout_transfers(*, limit: int = 200) -> List[Dict[str, Any]]:
    return await _fetchall(
        """
        SELECT *
        FROM payout_transfers
        ORDER BY created_at DESC, id DESC
        LIMIT ?
        """,
        (max(1, int(limit)),),
    )


async def list_paid_premium_weeks_for_phone(phone: str, *, limit: int = 52) -> List[Dict[str, Any]]:
    return await _fetchall(
        """
        SELECT week_start_date, amount, status, provider_ref, metadata_json, created_at, updated_at
        FROM premium_payments
        WHERE phone = ? AND status = 'paid'
        ORDER BY week_start_date DESC
        LIMIT ?
        """,
        (phone, max(1, int(limit))),
    )


async def upsert_premium_payment_week(
    *,
    phone: str,
    week_start_date: datetime | str,
    amount: float,
    status: str,
    provider_ref: Optional[str] = None,
    metadata: Optional[Dict[str, Any]] = None,
) -> Dict[str, Any]:
    now = _utc_now()
    row = await _fetchone(
        """
        INSERT INTO premium_payments (
            phone,
            week_start_date,
            amount,
            status,
            provider_ref,
            metadata_json,
            created_at,
            updated_at
        )
        VALUES (?, ?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT (phone, week_start_date)
        DO UPDATE SET
            amount = excluded.amount,
            status = excluded.status,
            provider_ref = excluded.provider_ref,
            metadata_json = excluded.metadata_json,
            updated_at = excluded.updated_at
        RETURNING *
        """,
        (
            phone,
            _to_storage(week_start_date),
            float(amount),
            status,
            provider_ref,
            _to_storage(metadata),
            _to_storage(now),
            _to_storage(now),
        ),
    )
    return row or {}


async def upsert_worker_payout_accounts(
    phone: str,
    *,
    primary_upi: Optional[str] = None,
    primary_verified: Optional[bool] = None,
    backup_upi: Optional[str] = None,
    backup_verified: Optional[bool] = None,
) -> Optional[Dict[str, Any]]:
    worker = await get_worker(phone)
    if not worker:
        return None
    await _run_write(
        """
        UPDATE workers
        SET
            payout_primary_upi = COALESCE(?, payout_primary_upi),
            payout_primary_verified = COALESCE(?, payout_primary_verified),
            payout_backup_upi = ?,
            payout_backup_verified = COALESCE(?, payout_backup_verified),
            updated_at = ?
        WHERE phone = ?
        """,
        (
            primary_upi,
            None if primary_verified is None else (1 if primary_verified else 0),
            backup_upi,
            None if backup_verified is None else (1 if backup_verified else 0),
            _utc_now(),
            phone,
        ),
    )
    return await get_worker(phone)


async def create_admin_action(
    *,
    actor: str,
    action_type: str,
    claim_id: Optional[int] = None,
    escalation_id: Optional[int] = None,
    details: Optional[Dict[str, Any]] = None,
) -> None:
    await _run_write(
        """
        INSERT INTO admin_actions (actor, action_type, claim_id, escalation_id, details_json, created_at)
        VALUES (?, ?, ?, ?, ?, ?)
        """,
        (actor, action_type, claim_id, escalation_id, details, _utc_now()),
    )


async def create_fraud_cluster_run(
    *,
    lookback_days: int,
    time_bucket_minutes: int,
    min_edge_support: int,
    medium_risk_threshold: float,
    high_risk_threshold: float,
) -> Dict[str, Any]:
    now = _utc_now()
    row = await _fetchone(
        """
        INSERT INTO fraud_cluster_runs (
            started_at,
            finished_at,
            status,
            error_message,
            lookback_days,
            time_bucket_minutes,
            min_edge_support,
            medium_risk_threshold,
            high_risk_threshold,
            claims_scanned,
            edge_count,
            cluster_count,
            flagged_cluster_count,
            created_at
        )
        VALUES (?, NULL, 'running', NULL, ?, ?, ?, ?, ?, 0, 0, 0, 0, ?)
        RETURNING *
        """,
        (
            _to_storage(now),
            int(lookback_days),
            int(time_bucket_minutes),
            int(min_edge_support),
            float(medium_risk_threshold),
            float(high_risk_threshold),
            _to_storage(now),
        ),
    )
    return row or {}


async def finalize_fraud_cluster_run(
    run_id: int,
    *,
    status: str,
    claims_scanned: int,
    edge_count: int,
    cluster_count: int,
    flagged_cluster_count: int,
    error_message: Optional[str] = None,
) -> None:
    await _run_write(
        """
        UPDATE fraud_cluster_runs
        SET finished_at = ?,
            status = ?,
            claims_scanned = ?,
            edge_count = ?,
            cluster_count = ?,
            flagged_cluster_count = ?,
            error_message = ?
        WHERE id = ?
        """,
        (
            _utc_now(),
            status,
            int(claims_scanned),
            int(edge_count),
            int(cluster_count),
            int(flagged_cluster_count),
            error_message,
            int(run_id),
        ),
    )


async def list_existing_fraud_co_claim_cluster_keys(cluster_keys: List[str]) -> set[str]:
    existing: set[str] = set()
    unique_keys = {str(key).strip() for key in cluster_keys if str(key).strip()}
    for key in unique_keys:
        row = await _fetchone(
            "SELECT cluster_key FROM fraud_co_claim_clusters WHERE cluster_key = ? LIMIT 1",
            (key,),
        )
        if row and row.get("cluster_key") is not None:
            existing.add(str(row["cluster_key"]))
    return existing


async def save_fraud_co_claim_clusters(run_id: int, clusters: List[Dict[str, Any]]) -> int:
    now = _utc_now()
    persisted = 0
    pool = await _pool()
    async with pool.acquire() as conn:
        async with conn.transaction():
            for cluster in clusters:
                cluster_row = await conn.fetchrow(
                    _adapt_query(
                        """
                        INSERT INTO fraud_co_claim_clusters (
                            run_id,
                            cluster_key,
                            risk_score,
                            risk_level,
                            member_count,
                            edge_count,
                            event_count,
                            frequency_score,
                            recency_score,
                            supporting_metadata_json,
                            created_at
                        )
                        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                        RETURNING id
                        """
                    ),
                    int(run_id),
                    str(cluster.get("cluster_key", "")),
                    float(cluster.get("risk_score", 0.0)),
                    str(cluster.get("risk_level", "low")),
                    int(cluster.get("member_count", 0)),
                    int(cluster.get("edge_count", 0)),
                    int(cluster.get("event_count", 0)),
                    float(cluster.get("frequency_score", 0.0)),
                    float(cluster.get("recency_score", 0.0)),
                    _to_storage(cluster.get("supporting_metadata", {})),
                    _to_storage(now),
                )
                cluster_id = int(cluster_row["id"])
                for member in cluster.get("members", []):
                    await conn.execute(
                        _adapt_query(
                            """
                            INSERT INTO fraud_co_claim_cluster_members (
                                cluster_id,
                                phone,
                                claim_count,
                                first_claim_at,
                                last_claim_at,
                                created_at
                            )
                            VALUES (?, ?, ?, ?, ?, ?)
                            """
                        ),
                        cluster_id,
                        str(member.get("phone", "")),
                        int(member.get("claim_count", 0)),
                        member.get("first_claim_at"),
                        member.get("last_claim_at"),
                        _to_storage(now),
                    )
                for edge in cluster.get("edges", []):
                    await conn.execute(
                        _adapt_query(
                            """
                            INSERT INTO fraud_co_claim_cluster_edges (
                                cluster_id,
                                phone_a,
                                phone_b,
                                co_claim_count,
                                recency_weight,
                                edge_weight,
                                last_co_claim_at,
                                supporting_metadata_json,
                                created_at
                            )
                            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                            """
                        ),
                        cluster_id,
                        str(edge.get("phone_a", "")),
                        str(edge.get("phone_b", "")),
                        int(edge.get("co_claim_count", 0)),
                        float(edge.get("recency_weight", 0.0)),
                        float(edge.get("edge_weight", 0.0)),
                        edge.get("last_co_claim_at"),
                        _to_storage(edge.get("supporting_metadata", {})),
                        _to_storage(now),
                    )
                persisted += 1
    return persisted


async def list_fraud_cluster_runs(limit: int = 20) -> List[Dict[str, Any]]:
    return await _fetchall(
        """
        SELECT *
        FROM fraud_cluster_runs
        ORDER BY created_at DESC, id DESC
        LIMIT ?
        """,
        (max(1, int(limit)),),
    )


async def get_latest_fraud_cluster_run() -> Optional[Dict[str, Any]]:
    rows = await list_fraud_cluster_runs(limit=1)
    return rows[0] if rows else None


async def list_fraud_clusters(
    *,
    run_id: Optional[int] = None,
    risk_level: Optional[str] = None,
    flagged_only: bool = False,
    limit: int = 50,
    offset: int = 0,
) -> List[Dict[str, Any]]:
    query = """
        SELECT *
        FROM fraud_co_claim_clusters
        WHERE 1 = 1
    """
    params: List[Any] = []
    if run_id is not None:
        query += " AND run_id = ?"
        params.append(int(run_id))
    if risk_level:
        query += " AND LOWER(risk_level) = ?"
        params.append(str(risk_level).strip().lower())
    if flagged_only:
        query += " AND LOWER(risk_level) IN ('medium', 'high')"
    query += " ORDER BY risk_score DESC, id DESC LIMIT ? OFFSET ?"
    params.extend([max(1, int(limit)), max(0, int(offset))])
    return await _fetchall(query, params)


async def get_fraud_cluster(cluster_id: int) -> Optional[Dict[str, Any]]:
    return await _fetchone("SELECT * FROM fraud_co_claim_clusters WHERE id = ?", (int(cluster_id),))


async def list_fraud_cluster_members(cluster_id: int) -> List[Dict[str, Any]]:
    return await _fetchall(
        """
        SELECT *
        FROM fraud_co_claim_cluster_members
        WHERE cluster_id = ?
        ORDER BY claim_count DESC, phone ASC
        """,
        (int(cluster_id),),
    )


async def list_fraud_cluster_edges(cluster_id: int, limit: int = 200) -> List[Dict[str, Any]]:
    return await _fetchall(
        """
        SELECT *
        FROM fraud_co_claim_cluster_edges
        WHERE cluster_id = ?
        ORDER BY edge_weight DESC, co_claim_count DESC
        LIMIT ?
        """,
        (int(cluster_id), max(1, int(limit))),
    )


# ── Adversarial Defense: Claim Velocity Spike Detection ─────────────────────


async def count_recent_zone_claims_window(
    zone_pincode: str,
    since: datetime,
) -> int:
    """Count claims submitted in a zone since a cutoff timestamp."""
    row = await _fetchone(
        """
        SELECT COUNT(*) AS cnt
        FROM claims
        WHERE zone_pincode = ? AND created_at >= ?
        """,
        (zone_pincode, _to_storage(since)),
    )
    return int(row["cnt"]) if row else 0


# ── Adversarial Defense: New Account Age Check ──────────────────────────────


async def get_worker_created_at(phone: str) -> Optional[str]:
    """Return the created_at timestamp for a worker, or None."""
    row = await _fetchone(
        "SELECT created_at FROM workers WHERE phone = ?",
        (phone,),
    )
    return str(row["created_at"]) if row else None


async def list_zone_risk_rows() -> List[Dict[str, Any]]:
    return await _fetchall(
        """
        SELECT pincode, zone_json
        FROM zone_risk
        ORDER BY pincode ASC
        """
    )

