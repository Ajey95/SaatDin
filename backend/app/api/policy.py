"""Module for backend\app\api\policy.py."""

from __future__ import annotations

import logging
from datetime import datetime, timedelta, timezone

from fastapi import APIRouter, Depends, HTTPException

from ..core.db import set_pending_worker_plan, total_settled_amount_for_phone
from ..core.dependencies import get_current_worker
from ..core.zone_cache import resolve_zone
from ..models.platform import Platform
from ..models.schemas import ApiResponse, PolicyOut, PolicyUpdateRequest
from ..services.premium import build_plans

router = APIRouter(tags=["policy"])
logger = logging.getLogger(__name__)


def _next_week_start_utc(now: datetime) -> datetime:
    days_until_next_monday = (7 - now.weekday()) % 7
    if days_until_next_monday == 0:
        days_until_next_monday = 7
    next_monday = (now + timedelta(days=days_until_next_monday)).replace(
        hour=0,
        minute=0,
        second=0,
        microsecond=0,
    )
    return next_monday


def _build_policy(worker: dict, settled_total: float) -> PolicyOut:
    platform = Platform.from_input(str(worker["platform_name"]))
    pincode, zone_data = resolve_zone(str(worker["zone_pincode"]))
    plans = build_plans(float(zone_data.get("zone_risk_multiplier", 1.0)), platform, zone_data=zone_data)
    selected = next((plan for plan in plans if plan.name.lower() == str(worker["plan_name"]).lower()), None)
    if not selected:
        selected = plans[1]

    now = datetime.now(timezone.utc)
    next_billing = _next_week_start_utc(now).date().isoformat()
    pending_effective_at = worker.get("pending_plan_effective_at")
    pending_effective_date = None
    if pending_effective_at:
        pending_effective_date = str(pending_effective_at)[:10]

    return PolicyOut(
        status="active",
        plan=selected.name,
        pendingPlan=worker.get("pending_plan_name"),
        pendingEffectiveDate=pending_effective_date,
        zone=str(worker["zone_name"]),
        zonePincode=str(worker["zone_pincode"]),
        weeklyPremium=selected.weeklyPremium,
        earningsProtected=round(settled_total, 2),
        parametricCoverageOn=True,
        perTriggerPayout=selected.perTriggerPayout,
        maxDaysPerWeek=selected.maxDaysPerWeek,
        nextBillingDate=next_billing,
    )


@router.get("/me", response_model=ApiResponse)
async def get_my_policy(worker: dict = Depends(get_current_worker)) -> ApiResponse:
    settled_total = await total_settled_amount_for_phone(str(worker["phone"]))
    policy = _build_policy(worker, settled_total)
    logger.info("policy_requested phone=%s", worker["phone"])
    return ApiResponse(success=True, data=policy)


@router.put("/plan", response_model=ApiResponse)
async def update_policy_plan(payload: PolicyUpdateRequest, worker: dict = Depends(get_current_worker)) -> ApiResponse:
    platform = Platform.from_input(str(worker["platform_name"]))
    _, zone_data = resolve_zone(str(worker["zone_pincode"]))
    plans = build_plans(float(zone_data.get("zone_risk_multiplier", 1.0)), platform, zone_data=zone_data)
    selected = next((plan for plan in plans if plan.name.lower() == payload.planName.strip().lower()), None)
    if not selected:
        raise HTTPException(status_code=400, detail=f"Unknown plan: {payload.planName}")

    current_plan = str(worker["plan_name"]).strip().lower()
    if selected.name.strip().lower() == current_plan:
        settled_total = await total_settled_amount_for_phone(str(worker["phone"]))
        policy = _build_policy(worker, settled_total)
        return ApiResponse(success=True, data=policy, message="Selected plan is already active")

    next_week_effective_at = _next_week_start_utc(datetime.now(timezone.utc))
    await set_pending_worker_plan(str(worker["phone"]), selected.name, next_week_effective_at)
    worker["pending_plan_name"] = selected.name
    worker["pending_plan_effective_at"] = next_week_effective_at.isoformat()

    settled_total = await total_settled_amount_for_phone(str(worker["phone"]))
    policy = _build_policy(worker, settled_total)
    logger.info(
        "policy_change_queued phone=%s current_plan=%s pending_plan=%s effective_at=%s",
        worker["phone"],
        worker["plan_name"],
        selected.name,
        next_week_effective_at.isoformat(),
    )
    return ApiResponse(success=True, data=policy, message="Plan change queued for next week")
