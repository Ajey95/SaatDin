from __future__ import annotations

import logging
from datetime import date, datetime, timedelta, timezone

from fastapi import APIRouter, Depends, HTTPException

from ..core.db import (
    list_paid_premium_weeks_for_phone,
    set_pending_worker_plan,
    total_settled_amount_for_phone,
    upsert_premium_payment_week,
)
from ..core.dependencies import get_current_worker
from ..core.zone_cache import resolve_zone
from ..models.platform import Platform
from ..models.schemas import ApiResponse, PolicyOut, PolicyUpdateRequest, PremiumPaymentRecordRequest
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


def _current_week_start_utc(today: date | None = None) -> date:
    today = today or datetime.now(timezone.utc).date()
    return today - timedelta(days=today.weekday())


def _paid_week_starts(payment_rows: list[dict]) -> set[date]:
    paid_weeks: set[date] = set()
    for row in payment_rows:
        raw = row.get("week_start_date")
        if raw is None:
            continue
        try:
            if isinstance(raw, date):
                paid_weeks.add(raw)
                continue
            parsed = date.fromisoformat(str(raw)[:10])
            paid_weeks.add(parsed)
        except (TypeError, ValueError):
            continue
    return paid_weeks


def _clean_streak_weeks_from_paid_rows(payment_rows: list[dict]) -> int:
    paid_weeks = _paid_week_starts(payment_rows)
    if not paid_weeks:
        return 0

    cursor = _current_week_start_utc()
    streak = 0
    for _ in range(104):
        if cursor not in paid_weeks:
            break
        streak += 1
        cursor -= timedelta(days=7)
    return streak


def _effective_cycle_week(clean_streak_weeks: int) -> int:
    if clean_streak_weeks <= 0:
        return 0
    # 9-week loyalty cycle: 6-week build-up + 3-week carry-forward at max tier.
    return ((clean_streak_weeks - 1) % 9) + 1


def _loyalty_discount_percent(clean_streak_weeks: int) -> float:
    cycle_week = _effective_cycle_week(clean_streak_weeks)
    if cycle_week >= 6:
        return 10.0
    if cycle_week >= 4:
        return 5.0
    return 0.0


def _coerce_week_start(raw_week_start: str | None) -> date:
    if not raw_week_start:
        return _current_week_start_utc()
    try:
        parsed = date.fromisoformat(str(raw_week_start)[:10])
    except ValueError as exc:
        raise HTTPException(status_code=400, detail="Invalid weekStartDate") from exc
    return parsed - timedelta(days=parsed.weekday())


def _apply_loyalty_discount(weekly_premium: int, loyalty_discount_percent: float) -> int:
    ratio = max(0.0, min(100.0, float(loyalty_discount_percent))) / 100.0
    discounted = float(weekly_premium) * (1.0 - ratio)
    return max(0, int(round(discounted)))



def _build_policy(worker: dict, settled_total: float) -> PolicyOut:
    try:
        platform = Platform.from_input(str(worker.get("platform_name") or "swiggy_instamart"))
    except HTTPException:
        platform = Platform.swiggy_instamart

    zone_key = str(worker.get("zone_pincode") or worker.get("zone_name") or "560001")
    try:
        pincode, zone_data = resolve_zone(zone_key)
    except HTTPException:
        pincode, zone_data = resolve_zone("560001")

    plans = build_plans(float(zone_data.get("zone_risk_multiplier", 1.0)), platform, zone_data=zone_data)
    selected = next((plan for plan in plans if plan.name.lower() == str(worker.get("plan_name") or "").lower()), None)
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
        zone=str(worker.get("zone_name") or zone_data.get("name") or "Unknown"),
        zonePincode=str(worker.get("zone_pincode") or pincode),
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
    payment_rows = await list_paid_premium_weeks_for_phone(str(worker["phone"]))
    clean_streak_weeks = _clean_streak_weeks_from_paid_rows(payment_rows)
    loyalty_discount_percent = _loyalty_discount_percent(clean_streak_weeks)
    policy = _build_policy(worker, settled_total)
    policy.cleanStreakWeeks = clean_streak_weeks
    policy.loyaltyDiscountPercent = loyalty_discount_percent
    policy.weeklyPremium = _apply_loyalty_discount(policy.weeklyPremium, loyalty_discount_percent)
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
        payment_rows = await list_paid_premium_weeks_for_phone(str(worker["phone"]))
        clean_streak_weeks = _clean_streak_weeks_from_paid_rows(payment_rows)
        loyalty_discount_percent = _loyalty_discount_percent(clean_streak_weeks)
        policy = _build_policy(worker, settled_total)
        policy.cleanStreakWeeks = clean_streak_weeks
        policy.loyaltyDiscountPercent = loyalty_discount_percent
        policy.weeklyPremium = _apply_loyalty_discount(policy.weeklyPremium, loyalty_discount_percent)
        return ApiResponse(success=True, data=policy, message="Selected plan is already active")

    next_week_effective_at = _next_week_start_utc(datetime.now(timezone.utc))
    await set_pending_worker_plan(str(worker["phone"]), selected.name, next_week_effective_at)
    worker["pending_plan_name"] = selected.name
    worker["pending_plan_effective_at"] = next_week_effective_at.isoformat()

    settled_total = await total_settled_amount_for_phone(str(worker["phone"]))
    payment_rows = await list_paid_premium_weeks_for_phone(str(worker["phone"]))
    clean_streak_weeks = _clean_streak_weeks_from_paid_rows(payment_rows)
    loyalty_discount_percent = _loyalty_discount_percent(clean_streak_weeks)
    policy = _build_policy(worker, settled_total)
    policy.cleanStreakWeeks = clean_streak_weeks
    policy.loyaltyDiscountPercent = loyalty_discount_percent
    policy.weeklyPremium = _apply_loyalty_discount(policy.weeklyPremium, loyalty_discount_percent)
    logger.info(
        "policy_change_queued phone=%s current_plan=%s pending_plan=%s effective_at=%s",
        worker["phone"],
        worker["plan_name"],
        selected.name,
        next_week_effective_at.isoformat(),
    )
    return ApiResponse(success=True, data=policy, message="Plan change queued for next week")


@router.post("/premium-payment", response_model=ApiResponse)
async def record_premium_payment(
    payload: PremiumPaymentRecordRequest,
    worker: dict = Depends(get_current_worker),
) -> ApiResponse:
    status = payload.status.strip().lower()
    if status not in {"paid", "missed", "failed"}:
        raise HTTPException(status_code=400, detail="Invalid status. Use paid, missed, or failed")

    amount = float(payload.amount)
    if amount < 0:
        raise HTTPException(status_code=400, detail="Amount must be non-negative")

    week_start = _coerce_week_start(payload.weekStartDate)
    await upsert_premium_payment_week(
        phone=str(worker["phone"]),
        week_start_date=week_start,
        amount=amount,
        status=status,
        provider_ref=payload.providerRef,
        metadata=payload.metadata,
    )

    settled_total = await total_settled_amount_for_phone(str(worker["phone"]))
    payment_rows = await list_paid_premium_weeks_for_phone(str(worker["phone"]))
    clean_streak_weeks = _clean_streak_weeks_from_paid_rows(payment_rows)
    loyalty_discount_percent = _loyalty_discount_percent(clean_streak_weeks)
    policy = _build_policy(worker, settled_total)
    policy.cleanStreakWeeks = clean_streak_weeks
    policy.loyaltyDiscountPercent = loyalty_discount_percent
    policy.weeklyPremium = _apply_loyalty_discount(policy.weeklyPremium, loyalty_discount_percent)

    logger.info(
        "premium_payment_recorded phone=%s status=%s week_start=%s amount=%s",
        worker["phone"],
        status,
        week_start.isoformat(),
        amount,
    )
    return ApiResponse(success=True, data=policy, message="Premium payment recorded")
