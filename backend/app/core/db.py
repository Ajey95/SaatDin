"""Module for backend\app\core\db.py."""

from __future__ import annotations

from datetime import datetime, timezone
from typing import Any, Dict, Optional

import asyncpg

from .config import settings


_pool: Optional[asyncpg.Pool] = None


def _utc_now_iso() -> datetime:
    return datetime.now(timezone.utc)


def _row_to_dict(row: Optional[asyncpg.Record]) -> Optional[Dict[str, Any]]:
    if row is None:
        return None
    return dict(row)


def _rows_to_dicts(rows: list[asyncpg.Record]) -> list[Dict[str, Any]]:
    return [dict(row) for row in rows]


def _to_iso(value: Any) -> str:
    if isinstance(value, datetime):
        return value.astimezone(timezone.utc).isoformat()
    return str(value)


async def _get_pool() -> asyncpg.Pool:
    global _pool
    if _pool is None:
        _pool = await asyncpg.create_pool(
            dsn=settings.database_url,
            min_size=settings.db_pool_min_size,
            max_size=settings.db_pool_max_size,
            command_timeout=30,
        )
    return _pool


async def init_db() -> None:
    pool = await _get_pool()
    async with pool.acquire() as conn:
        await conn.execute(
            """
            CREATE TABLE IF NOT EXISTS otp_codes (
                phone TEXT PRIMARY KEY,
                otp_hash TEXT NOT NULL,
                expires_at TIMESTAMPTZ NOT NULL,
                attempts INTEGER NOT NULL DEFAULT 0,
                last_sent_at TIMESTAMPTZ NOT NULL
            )
            """
        )
        await conn.execute(
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
                created_at TIMESTAMPTZ NOT NULL
            )
            """
        )
        await conn.execute("ALTER TABLE workers ADD COLUMN IF NOT EXISTS pending_plan_name TEXT")
        await conn.execute("ALTER TABLE workers ADD COLUMN IF NOT EXISTS pending_plan_effective_at TIMESTAMPTZ")
        await conn.execute(
            """
            CREATE TABLE IF NOT EXISTS claims (
                id BIGSERIAL PRIMARY KEY,
                phone TEXT NOT NULL,
                claim_type TEXT NOT NULL,
                status TEXT NOT NULL,
                amount REAL NOT NULL,
                description TEXT NOT NULL,
                zone_pincode TEXT NOT NULL,
                source TEXT NOT NULL,
                created_at TIMESTAMPTZ NOT NULL
            )
            """
        )
        await conn.execute(
            """
            CREATE TABLE IF NOT EXISTS zonelock_reports (
                id BIGSERIAL PRIMARY KEY,
                phone TEXT NOT NULL,
                zone_pincode TEXT NOT NULL,
                zone_name TEXT NOT NULL,
                description TEXT NOT NULL,
                status TEXT NOT NULL,
                confidence REAL NOT NULL,
                verified_count INTEGER NOT NULL DEFAULT 1,
                created_at TIMESTAMPTZ NOT NULL
            )
            """
        )
        await conn.execute(
            """
            CREATE TABLE IF NOT EXISTS claim_escalations (
                id BIGSERIAL PRIMARY KEY,
                claim_id INTEGER NOT NULL,
                phone TEXT NOT NULL,
                reason TEXT NOT NULL,
                status TEXT NOT NULL,
                review_notes TEXT,
                created_at TIMESTAMPTZ NOT NULL
            )
            """
        )


async def close_db() -> None:
    global _pool
    if _pool is not None:
        await _pool.close()
        _pool = None


async def healthcheck_db() -> bool:
    try:
        pool = await _get_pool()
        async with pool.acquire() as conn:
            await conn.execute("SELECT 1")
        return True
    except Exception:
        return False


async def save_otp(phone: str, otp_hash: str, expires_at: str | datetime) -> None:
    now = _utc_now_iso()
    expires_value: datetime
    if isinstance(expires_at, str):
        expires_value = datetime.fromisoformat(expires_at)
    else:
        expires_value = expires_at
    pool = await _get_pool()
    async with pool.acquire() as conn:
        await conn.execute(
            """
            INSERT INTO otp_codes (phone, otp_hash, expires_at, attempts, last_sent_at)
            VALUES ($1, $2, $3, 0, $4)
            ON CONFLICT(phone) DO UPDATE SET
                otp_hash=excluded.otp_hash,
                expires_at=excluded.expires_at,
                attempts=0,
                last_sent_at=excluded.last_sent_at
            """,
            phone,
            otp_hash,
            expires_value,
            now,
        )


async def get_otp(phone: str) -> Optional[Dict[str, Any]]:
    pool = await _get_pool()
    async with pool.acquire() as conn:
        row = await conn.fetchrow("SELECT * FROM otp_codes WHERE phone = $1", phone)
    out = _row_to_dict(row)
    if out is None:
        return None
    out["expires_at"] = _to_iso(out["expires_at"])
    out["last_sent_at"] = _to_iso(out["last_sent_at"])
    return out


async def increment_otp_attempts(phone: str) -> None:
    pool = await _get_pool()
    async with pool.acquire() as conn:
        await conn.execute("UPDATE otp_codes SET attempts = attempts + 1 WHERE phone = $1", phone)


async def delete_otp(phone: str) -> None:
    pool = await _get_pool()
    async with pool.acquire() as conn:
        await conn.execute("DELETE FROM otp_codes WHERE phone = $1", phone)


async def upsert_worker(
    *,
    phone: str,
    name: str,
    platform_name: str,
    zone_pincode: str,
    zone_name: str,
    plan_name: str,
) -> None:
    pool = await _get_pool()
    async with pool.acquire() as conn:
        await conn.execute(
            """
            INSERT INTO workers (phone, name, platform_name, zone_pincode, zone_name, plan_name, pending_plan_name, pending_plan_effective_at, created_at)
            VALUES ($1, $2, $3, $4, $5, $6, NULL, NULL, $7)
            ON CONFLICT(phone) DO UPDATE SET
                name=excluded.name,
                platform_name=excluded.platform_name,
                zone_pincode=excluded.zone_pincode,
                zone_name=excluded.zone_name,
                plan_name=excluded.plan_name,
                pending_plan_name=NULL,
                pending_plan_effective_at=NULL
            """,
            phone,
            name,
            platform_name,
            zone_pincode,
            zone_name,
            plan_name,
            _utc_now_iso(),
        )


async def get_worker(phone: str) -> Optional[Dict[str, Any]]:
    pool = await _get_pool()
    async with pool.acquire() as conn:
        row = await conn.fetchrow("SELECT * FROM workers WHERE phone = $1", phone)
    out = _row_to_dict(row)
    if out is None:
        return None
    out["created_at"] = _to_iso(out["created_at"])
    if out.get("pending_plan_effective_at") is not None:
        out["pending_plan_effective_at"] = _to_iso(out["pending_plan_effective_at"])
    return out


async def update_worker_plan(phone: str, plan_name: str) -> None:
    pool = await _get_pool()
    async with pool.acquire() as conn:
        await conn.execute(
            "UPDATE workers SET plan_name = $1, pending_plan_name = NULL, pending_plan_effective_at = NULL WHERE phone = $2",
            plan_name,
            phone,
        )


async def set_pending_worker_plan(phone: str, plan_name: str, effective_at: datetime) -> None:
    pool = await _get_pool()
    async with pool.acquire() as conn:
        await conn.execute(
            "UPDATE workers SET pending_plan_name = $1, pending_plan_effective_at = $2 WHERE phone = $3",
            plan_name,
            effective_at,
            phone,
        )


async def apply_due_pending_worker_plan(phone: str, now: Optional[datetime] = None) -> bool:
    now_utc = now or _utc_now_iso()
    pool = await _get_pool()
    async with pool.acquire() as conn:
        row = await conn.fetchrow(
            "SELECT pending_plan_name, pending_plan_effective_at FROM workers WHERE phone = $1",
            phone,
        )
        if not row:
            return False

        pending_name = row["pending_plan_name"]
        pending_effective_at = row["pending_plan_effective_at"]
        if not pending_name or pending_effective_at is None:
            return False

        if pending_effective_at <= now_utc:
            await conn.execute(
                """
                UPDATE workers
                SET plan_name = pending_plan_name,
                    pending_plan_name = NULL,
                    pending_plan_effective_at = NULL
                WHERE phone = $1
                """,
                phone,
            )
            return True

    return False


async def list_workers_by_zone(zone_pincode: str) -> list[Dict[str, Any]]:
    pool = await _get_pool()
    async with pool.acquire() as conn:
        rows = await conn.fetch("SELECT * FROM workers WHERE zone_pincode = $1", zone_pincode)
    out = _rows_to_dicts(rows)
    for item in out:
        item["created_at"] = _to_iso(item["created_at"])
    return out


async def create_claim(
    *,
    phone: str,
    claim_type: str,
    status: str,
    amount: float,
    description: str,
    zone_pincode: str,
    source: str,
) -> Dict[str, Any]:
    now = _utc_now_iso()
    pool = await _get_pool()
    async with pool.acquire() as conn:
        claim_id = await conn.fetchval(
            """
            INSERT INTO claims (phone, claim_type, status, amount, description, zone_pincode, source, created_at)
            VALUES ($1, $2, $3, $4, $5, $6, $7, $8)
            RETURNING id
            """,
            phone,
            claim_type,
            status,
            amount,
            description,
            zone_pincode,
            source,
            now,
        )

    return {
        "id": int(claim_id),
        "phone": phone,
        "claim_type": claim_type,
        "status": status,
        "amount": float(amount),
        "description": description,
        "zone_pincode": zone_pincode,
        "source": source,
        "created_at": _to_iso(now),
    }


async def list_claims_for_phone(phone: str) -> list[Dict[str, Any]]:
    pool = await _get_pool()
    async with pool.acquire() as conn:
        rows = await conn.fetch(
            "SELECT * FROM claims WHERE phone = $1 ORDER BY created_at DESC",
            phone,
        )
    out = _rows_to_dicts(rows)
    for item in out:
        item["created_at"] = _to_iso(item["created_at"])
    return out


async def total_settled_amount_for_phone(phone: str) -> float:
    pool = await _get_pool()
    async with pool.acquire() as conn:
        value = await conn.fetchval(
            "SELECT COALESCE(SUM(amount), 0) FROM claims WHERE phone = $1 AND status = 'settled'",
            phone,
        )
    return float(value or 0)


async def has_recent_auto_claim(phone: str, claim_type: str, within_minutes: int = 360) -> bool:
    cutoff = datetime.now(timezone.utc).timestamp() - (within_minutes * 60)
    pool = await _get_pool()
    async with pool.acquire() as conn:
        row = await conn.fetchrow(
            """
            SELECT created_at
            FROM claims
            WHERE phone = $1 AND claim_type = $2 AND source = 'auto'
            ORDER BY created_at DESC
            LIMIT 1
            """,
            phone,
            claim_type,
        )

    if not row:
        return False
    created_at = row["created_at"]
    if isinstance(created_at, str):
        created_at = datetime.fromisoformat(created_at)
    return created_at.timestamp() >= cutoff


async def create_zonelock_report(
    *,
    phone: str,
    zone_pincode: str,
    zone_name: str,
    description: str,
) -> Dict[str, Any]:
    """Create a ZoneLock manual report from worker."""
    now = _utc_now_iso()
    pool = await _get_pool()
    async with pool.acquire() as conn:
        report_id = await conn.fetchval(
            """
            INSERT INTO zonelock_reports (phone, zone_pincode, zone_name, description, status, confidence, verified_count, created_at)
            VALUES ($1, $2, $3, $4, 'pending', 0.4, 1, $5)
            RETURNING id
            """,
            phone,
            zone_pincode,
            zone_name,
            description,
            now,
        )

    return {
        "id": int(report_id),
        "phone": phone,
        "zone_pincode": zone_pincode,
        "zone_name": zone_name,
        "description": description,
        "status": "pending",
        "confidence": 0.4,
        "verified_count": 1,
        "created_at": _to_iso(now),
    }


async def get_zonelock_report(report_id: int) -> Optional[Dict[str, Any]]:
    """Get a ZoneLock report by ID."""
    pool = await _get_pool()
    async with pool.acquire() as conn:
        row = await conn.fetchrow("SELECT * FROM zonelock_reports WHERE id = $1", report_id)
    out = _row_to_dict(row)
    if out is None:
        return None
    out["created_at"] = _to_iso(out["created_at"])
    return out


async def list_zonelock_reports_for_zone(zone_pincode: str, status: Optional[str] = None) -> list[Dict[str, Any]]:
    """List ZoneLock reports for a zone."""
    pool = await _get_pool()
    async with pool.acquire() as conn:
        if status:
            rows = await conn.fetch(
                """
                SELECT * FROM zonelock_reports
                WHERE zone_pincode = $1 AND status = $2
                ORDER BY created_at DESC
                """,
                zone_pincode,
                status,
            )
        else:
            rows = await conn.fetch(
                """
                SELECT * FROM zonelock_reports
                WHERE zone_pincode = $1
                ORDER BY created_at DESC
                """,
                zone_pincode,
            )
    out = _rows_to_dicts(rows)
    for item in out:
        item["created_at"] = _to_iso(item["created_at"])
    return out


async def increment_zonelock_report_verification(report_id: int) -> None:
    """Increment verification count for a ZoneLock report."""
    pool = await _get_pool()
    async with pool.acquire() as conn:
        await conn.execute(
            """
            UPDATE zonelock_reports
            SET verified_count = verified_count + 1,
                confidence = MIN(0.95, 0.4 + (verified_count + 1) * 0.2),
                status = CASE WHEN (verified_count + 1) >= 2 THEN 'auto_confirmed' ELSE status END
            WHERE id = $1
            """,
            report_id,
        )


async def update_zonelock_report_status(report_id: int, status: str, review_notes: Optional[str] = None) -> None:
    """Update ZoneLock report status after manual review."""
    pool = await _get_pool()
    async with pool.acquire() as conn:
        await conn.execute("UPDATE zonelock_reports SET status = $1 WHERE id = $2", status, report_id)


async def escalate_claim(
    *,
    claim_id: int,
    phone: str,
    reason: str,
) -> Dict[str, Any]:
    """Create a claim escalation record."""
    now = _utc_now_iso()
    pool = await _get_pool()
    async with pool.acquire() as conn:
        async with conn.transaction():
            escalation_id = await conn.fetchval(
                """
                INSERT INTO claim_escalations (claim_id, phone, reason, status, created_at)
                VALUES ($1, $2, $3, 'pending_review', $4)
                RETURNING id
                """,
                claim_id,
                phone,
                reason,
                now,
            )
            # Update claim status to reflect escalation
            await conn.execute(
                "UPDATE claims SET status = 'escalated' WHERE id = $1",
                claim_id,
            )

    return {
        "id": int(escalation_id),
        "claim_id": claim_id,
        "phone": phone,
        "reason": reason,
        "status": "pending_review",
        "created_at": _to_iso(now),
    }


async def get_claim_escalation(escalation_id: int) -> Optional[Dict[str, Any]]:
    """Get a claim escalation by ID."""
    pool = await _get_pool()
    async with pool.acquire() as conn:
        row = await conn.fetchrow("SELECT * FROM claim_escalations WHERE id = $1", escalation_id)
    out = _row_to_dict(row)
    if out is None:
        return None
    out["created_at"] = _to_iso(out["created_at"])
    return out


async def list_claim_escalations_for_phone(phone: str) -> list[Dict[str, Any]]:
    """List claim escalations for a phone."""
    pool = await _get_pool()
    async with pool.acquire() as conn:
        rows = await conn.fetch(
            """
            SELECT * FROM claim_escalations
            WHERE phone = $1
            ORDER BY created_at DESC
            """,
            phone,
        )
    out = _rows_to_dicts(rows)
    for item in out:
        item["created_at"] = _to_iso(item["created_at"])
    return out


async def update_escalation_status(escalation_id: int, status: str, review_notes: Optional[str] = None) -> None:
    """Update claim escalation status after human review."""
    pool = await _get_pool()
    async with pool.acquire() as conn:
        await conn.execute(
            """
            UPDATE claim_escalations
            SET status = $1, review_notes = $2
            WHERE id = $3
            """,
            status,
            review_notes,
            escalation_id,
        )
