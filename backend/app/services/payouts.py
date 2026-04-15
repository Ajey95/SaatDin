from __future__ import annotations

import re
from datetime import datetime, timedelta, timezone
from typing import Any, Dict, List, Optional

from ..core.config import settings
from ..core.db import (
    count_settled_claim_days_for_phone_since,
    create_payout_transfer,
    get_payout_transfer,
    get_worker,
    list_payout_transfers,
    list_payout_transfers_for_phone,
    set_claim_payout_transfer,
    upsert_worker_payout_accounts,
)
from ..core.zone_cache import resolve_zone
from ..models.platform import Platform
from .premium import build_plans

_UPI_PATTERN = re.compile(r"^[a-zA-Z0-9.\-_]{2,}@[a-zA-Z]{2,}$")


def validate_upi_id(upi_id: str) -> bool:
    return bool(_UPI_PATTERN.fullmatch(upi_id.strip()))


def mask_upi_id(upi_id: Optional[str]) -> str:
    if not upi_id:
        return ""
    local, _, provider = upi_id.partition("@")
    if len(local) <= 2:
        masked_local = local[0] + "*" if local else ""
    else:
        masked_local = f"{local[:2]}{'*' * max(2, len(local) - 2)}"
    return f"{masked_local}@{provider}"


def _transfer_summary(row: Dict[str, Any]) -> Dict[str, Any]:
    return {
        "id": int(row["id"]),
        "claimId": int(row["claim_id"]) if row.get("claim_id") is not None else None,
        "amount": float(row["amount"]),
        "status": str(row["status"]),
        "providerStatus": str(row["provider_status"]),
        "provider": str(row["provider"]),
        "providerPayoutId": str(row["provider_payout_id"]),
        "upiId": str(row["upi_id"]),
        "maskedUpiId": mask_upi_id(str(row["upi_id"])),
        "note": str(row["note"]) if row.get("note") is not None else None,
        "createdAt": str(row["created_at"]),
        "updatedAt": str(row["updated_at"]),
    }


def _preferred_upi(worker: Dict[str, Any]) -> Optional[str]:
    primary = str(worker.get("payout_primary_upi") or "").strip()
    backup = str(worker.get("payout_backup_upi") or "").strip()
    if primary:
        return primary
    if backup:
        return backup
    return None


def _provider_label() -> str:
    if settings.razorpay_key_id and settings.razorpay_key_secret:
        return "razorpay-sandbox"
    return "razorpay-sandbox-local"


def _current_week_start_utc(value: datetime) -> datetime:
    utc_value = value.astimezone(timezone.utc) if value.tzinfo else value.replace(tzinfo=timezone.utc)
    return (utc_value - timedelta(days=utc_value.weekday())).replace(hour=0, minute=0, second=0, microsecond=0)


def _selected_plan_for_worker(worker: Dict[str, Any]) -> Any:
    platform = Platform.from_input(str(worker.get("platform_name") or "swiggy_instamart"))
    zone_key = str(worker.get("zone_pincode") or worker.get("zone_name") or "560001")
    _, zone_data = resolve_zone(zone_key)
    plans = build_plans(float(zone_data.get("zone_risk_multiplier", 1.0)), platform, zone_data=zone_data)
    selected = next((plan for plan in plans if plan.name.lower() == str(worker.get("plan_name") or "").lower()), None)
    return selected or plans[1]


async def get_worker_payout_dashboard(phone: str) -> Dict[str, Any]:
    worker = await get_worker(phone)
    if not worker:
        raise ValueError(f"Worker {phone} not found")
    transfers = await list_payout_transfers_for_phone(phone, limit=200)
    settled_total = sum(float(item["amount"]) for item in transfers if str(item.get("status")) == "settled")
    pending_total = sum(float(item["amount"]) for item in transfers if str(item.get("status")) != "settled")
    return {
        "primaryUpi": worker.get("payout_primary_upi"),
        "primaryUpiMasked": mask_upi_id(worker.get("payout_primary_upi")),
        "primaryVerified": bool(worker.get("payout_primary_verified")),
        "backupUpi": worker.get("payout_backup_upi"),
        "backupUpiMasked": mask_upi_id(worker.get("payout_backup_upi")),
        "backupVerified": bool(worker.get("payout_backup_verified")),
        "provider": _provider_label(),
        "summary": {
            "settledCount": len([item for item in transfers if str(item.get("status")) == "settled"]),
            "settledTotal": round(settled_total, 2),
            "pendingTotal": round(pending_total, 2),
        },
        "transfers": [_transfer_summary(item) for item in transfers],
    }


async def update_upi_account(phone: str, *, slot: str, upi_id: str) -> Dict[str, Any]:
    normalized = upi_id.strip().lower()
    if not validate_upi_id(normalized):
        raise ValueError("Invalid UPI ID format")

    if slot == "primary":
        worker = await upsert_worker_payout_accounts(
            phone,
            primary_upi=normalized,
            primary_verified=False,
        )
    elif slot == "backup":
        worker = await upsert_worker_payout_accounts(
            phone,
            backup_upi=normalized,
            backup_verified=False,
        )
    else:
        raise ValueError(f"Unsupported slot: {slot}")

    if worker is None:
        raise ValueError("Worker not found")
    return await get_worker_payout_dashboard(phone)


async def verify_upi_account(phone: str, *, slot: str) -> Dict[str, Any]:
    worker = await get_worker(phone)
    if not worker:
        raise ValueError("Worker not found")

    if slot == "primary":
        upi_id = str(worker.get("payout_primary_upi") or "").strip()
        if not validate_upi_id(upi_id):
            raise ValueError("Primary UPI ID is invalid")
        await upsert_worker_payout_accounts(phone, primary_verified=True)
    elif slot == "backup":
        upi_id = str(worker.get("payout_backup_upi") or "").strip()
        if not validate_upi_id(upi_id):
            raise ValueError("Backup UPI ID is invalid")
        await upsert_worker_payout_accounts(phone, backup_verified=True)
    else:
        raise ValueError(f"Unsupported slot: {slot}")

    return await get_worker_payout_dashboard(phone)


async def initiate_claim_payout(
    *,
    claim: Dict[str, Any],
    worker: Dict[str, Any],
    note: Optional[str] = None,
    metadata: Optional[Dict[str, Any]] = None,
) -> Dict[str, Any]:
    existing_transfer_id = claim.get("payout_transfer_id")
    if existing_transfer_id:
        existing = await get_payout_transfer(int(existing_transfer_id))
        if existing:
            return existing

    upi_id = _preferred_upi(worker)
    if not upi_id or not validate_upi_id(upi_id):
        raise ValueError("No valid payout UPI is configured for the worker")

    selected = _selected_plan_for_worker(worker)
    claim_created_at = datetime.fromisoformat(str(claim.get("created_at")))
    if claim_created_at.tzinfo is None:
        claim_created_at = claim_created_at.replace(tzinfo=timezone.utc)
    week_start = _current_week_start_utc(claim_created_at)
    settled_days_this_week = await count_settled_claim_days_for_phone_since(str(worker["phone"]), week_start)
    if settled_days_this_week >= max(1, int(selected.maxDaysPerWeek)):
        raise ValueError(
            f"Weekly coverage cap reached for plan {selected.name} ({selected.maxDaysPerWeek} covered days/week)"
        )

    created_at = datetime.now(timezone.utc)
    provider_payout_id = f"rp_{claim['id']}_{int(created_at.timestamp())}"
    provider = _provider_label()
    transfer = await create_payout_transfer(
        claim_id=int(claim["id"]),
        phone=str(worker["phone"]),
        upi_id=upi_id,
        amount=float(claim["amount"]),
        provider=provider,
        provider_payout_id=provider_payout_id,
        provider_status="processed",
        status="settled",
        note=note or f"Payout for claim #{claim['id']}",
        metadata={
            "mode": settings.payout_provider_mode,
            "sandbox": True,
            **(metadata or {}),
        },
    )
    await set_claim_payout_transfer(int(claim["id"]), int(transfer["id"]))
    return transfer


async def build_statement(phone: str, *, start: datetime, end: datetime) -> Dict[str, Any]:
    transfers = await list_payout_transfers_for_phone(phone, limit=500)
    selected = []
    for item in transfers:
        created_at = datetime.fromisoformat(str(item["created_at"]))
        if start <= created_at <= end:
            selected.append(item)

    total = round(sum(float(item["amount"]) for item in selected), 2)
    csv_lines = ["created_at,claim_id,amount,status,upi_id,provider_payout_id"]
    for item in selected:
        csv_lines.append(
            ",".join(
                [
                    str(item["created_at"]),
                    str(item.get("claim_id") or ""),
                    f"{float(item['amount']):.2f}",
                    str(item["status"]),
                    str(item["upi_id"]),
                    str(item["provider_payout_id"]),
                ]
            )
        )
    return {
        "startDate": start.date().isoformat(),
        "endDate": end.date().isoformat(),
        "transferCount": len(selected),
        "totalAmount": total,
        "csv": "\n".join(csv_lines),
        "transfers": [_transfer_summary(item) for item in selected],
    }


async def list_admin_payouts(limit: int = 200) -> List[Dict[str, Any]]:
    rows = await list_payout_transfers(limit=limit)
    return [_transfer_summary(item) for item in rows]
