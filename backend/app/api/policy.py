from __future__ import annotations

import logging
from datetime import date, datetime, timedelta, timezone

from fastapi import APIRouter, Depends, HTTPException

from ..core.db import (
    _coerce_dt,
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
    current = now.astimezone(timezone.utc)
    current_cycle_start = current.replace(hour=0, minute=1, second=0, microsecond=0) - timedelta(days=current.weekday())
    if current < current_cycle_start:
        return current_cycle_start

    days_until_next_monday = 7 - current.weekday()
    if days_until_next_monday <= 0:
        days_until_next_monday = 7
    return (current + timedelta(days=days_until_next_monday)).replace(
        hour=0,
        minute=1,
        second=0,
        microsecond=0,
    )


def _current_cycle_start_utc(now: datetime | None = None) -> datetime:
    current = (now or datetime.now(timezone.utc)).astimezone(timezone.utc)
    return current.replace(hour=0, minute=1, second=0, microsecond=0) - timedelta(days=current.weekday())


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
    minimum_week_start = _next_week_start_utc(datetime.now(timezone.utc)).date()
    if not raw_week_start:
        logger.info("policy_week_start_fallback_applied reason=missing_input week_start=%s", minimum_week_start.isoformat())
        return minimum_week_start
    try:
        parsed = date.fromisoformat(str(raw_week_start)[:10])
    except ValueError as exc:
        raise HTTPException(status_code=400, detail="Invalid weekStartDate") from exc
    normalized = parsed - timedelta(days=parsed.weekday())
    if normalized < minimum_week_start:
        logger.info(
            "policy_week_start_fallback_applied reason=past_cycle requested=%s normalized=%s fallback=%s",
            str(raw_week_start),
            normalized.isoformat(),
            minimum_week_start.isoformat(),
        )
        return minimum_week_start
    return normalized


def _apply_loyalty_discount(weekly_premium: int, loyalty_discount_percent: float) -> int:
    ratio = max(0.0, min(100.0, float(loyalty_discount_percent))) / 100.0
    discounted = float(weekly_premium) * (1.0 - ratio)
    return max(0, int(round(discounted)))


def _policy_cycle_context(worker: dict, now: datetime, paid_weeks: set[date]) -> tuple[str, date, date, date, int]:
    pending_effective_at = _coerce_dt(worker.get("pending_plan_effective_at"))
    current_cycle_start = _current_cycle_start_utc(now).date()

    future_candidates: list[date] = []
    if pending_effective_at is not None and pending_effective_at > now:
        future_candidates.append(pending_effective_at.date())

    future_paid_weeks = sorted(week for week in paid_weeks if week > current_cycle_start)
    if future_paid_weeks:
        future_candidates.extend(future_paid_weeks)

    if future_candidates:
        cycle_start_date = min(future_candidates)
        cycle_end_date = cycle_start_date + timedelta(days=6)
        next_billing_date = cycle_start_date
        days_left = max(0, (cycle_start_date - now.date()).days)
        return "scheduled", cycle_start_date, cycle_end_date, next_billing_date, days_left

    cycle_start_date = current_cycle_start
    cycle_end_date = cycle_start_date + timedelta(days=6)
    next_billing_date = cycle_start_date + timedelta(days=7)
    days_left = max(0, (cycle_end_date - now.date()).days)
    return "current", cycle_start_date, cycle_end_date, next_billing_date, days_left



def _build_policy(worker: dict, settled_total: float, payment_rows: list[dict]) -> PolicyOut:
    try:
        platform = Platform.from_input(str(worker.get("platform_name") or "swiggy_instamart"))
    except HTTPException as exc:
        logger.warning(
            "policy_platform_fallback_applied phone=%s raw_platform=%s fallback_platform=%s reason=%s",
            str(worker.get("phone") or "unknown"),
            str(worker.get("platform_name") or ""),
            Platform.swiggy_instamart.value,
            str(exc.detail) if hasattr(exc, "detail") else str(exc),
        )
        platform = Platform.swiggy_instamart

    zone_key = str(worker.get("zone_pincode") or worker.get("zone_name") or "560001")
    try:
        pincode, zone_data = resolve_zone(zone_key)
    except HTTPException as exc:
        logger.warning(
            "policy_zone_fallback_applied phone=%s requested_zone=%s fallback_zone=%s reason=%s",
            str(worker.get("phone") or "unknown"),
            zone_key,
            "560001",
            str(exc.detail) if hasattr(exc, "detail") else str(exc),
        )
        pincode, zone_data = resolve_zone("560001")

    plans = build_plans(float(zone_data.get("zone_risk_multiplier", 1.0)), platform, zone_data=zone_data)
    selected = next((plan for plan in plans if plan.name.lower() == str(worker.get("plan_name") or "").lower()), None)
    if not selected:
        logger.warning(
            "policy_plan_fallback_applied phone=%s requested_plan=%s fallback_plan=%s",
            str(worker.get("phone") or "unknown"),
            str(worker.get("plan_name") or ""),
            plans[1].name,
        )
        selected = plans[1]

    now = datetime.now(timezone.utc)
    paid_weeks = _paid_week_starts(payment_rows)
    cycle_state, cycle_start_date, cycle_end_date, next_billing_date, days_left = _policy_cycle_context(
        worker,
        now,
        paid_weeks,
    )
    paid_for_cycle = cycle_start_date in paid_weeks

    if cycle_state == "scheduled":
        status = "scheduled"
        amount_paid_this_week = 0.0
    else:
        status = "active" if paid_for_cycle else "inactive"
        amount_paid_this_week = float(selected.weeklyPremium) if paid_for_cycle else 0.0

    pending_effective_at = worker.get("pending_plan_effective_at")
    pending_effective_date = None
    if pending_effective_at:
        pending_effective_date = str(pending_effective_at)[:10]

    return PolicyOut(
        status=status,
        plan=selected.name,
        pendingPlan=worker.get("pending_plan_name"),
        pendingEffectiveDate=pending_effective_date,
        zone=str(worker.get("zone_name") or zone_data.get("name") or "Unknown"),
        zonePincode=str(worker.get("zone_pincode") or pincode),
        weeklyPremium=selected.weeklyPremium,
        amountPaidThisWeek=amount_paid_this_week,
        earningsProtected=round(settled_total, 2),
        parametricCoverageOn=True,
        perTriggerPayout=selected.perTriggerPayout,
        maxDaysPerWeek=selected.maxDaysPerWeek,
        nextBillingDate=next_billing_date.isoformat(),
        cycleStartDate=cycle_start_date.isoformat(),
        cycleEndDate=cycle_end_date.isoformat(),
        paidOnDate=now.date().isoformat(),
        daysLeft=days_left,
    )


@router.get("/me", response_model=ApiResponse)
async def get_my_policy(worker: dict = Depends(get_current_worker)) -> ApiResponse:
    settled_total = await total_settled_amount_for_phone(str(worker["phone"]))
    payment_rows = await list_paid_premium_weeks_for_phone(str(worker["phone"]))
    clean_streak_weeks = _clean_streak_weeks_from_paid_rows(payment_rows)
    loyalty_discount_percent = _loyalty_discount_percent(clean_streak_weeks)
    policy = _build_policy(worker, settled_total, payment_rows)
    policy.cleanStreakWeeks = clean_streak_weeks
    policy.loyaltyDiscountPercent = loyalty_discount_percent
    policy.weeklyPremium = _apply_loyalty_discount(policy.weeklyPremium, loyalty_discount_percent)
    policy.amountPaidThisWeek = float(policy.weeklyPremium) if policy.status == "active" else 0.0
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
        policy = _build_policy(worker, settled_total, payment_rows)
        policy.cleanStreakWeeks = clean_streak_weeks
        policy.loyaltyDiscountPercent = loyalty_discount_percent
        policy.weeklyPremium = _apply_loyalty_discount(policy.weeklyPremium, loyalty_discount_percent)
        policy.amountPaidThisWeek = float(policy.weeklyPremium) if policy.status == "active" else 0.0
        return ApiResponse(success=True, data=policy, message="Selected plan is already active")

    next_week_effective_at = _next_week_start_utc(datetime.now(timezone.utc))
    await set_pending_worker_plan(str(worker["phone"]), selected.name, next_week_effective_at)
    worker["pending_plan_name"] = selected.name
    worker["pending_plan_effective_at"] = next_week_effective_at.isoformat()

    settled_total = await total_settled_amount_for_phone(str(worker["phone"]))
    payment_rows = await list_paid_premium_weeks_for_phone(str(worker["phone"]))
    clean_streak_weeks = _clean_streak_weeks_from_paid_rows(payment_rows)
    loyalty_discount_percent = _loyalty_discount_percent(clean_streak_weeks)
    policy = _build_policy(worker, settled_total, payment_rows)
    policy.cleanStreakWeeks = clean_streak_weeks
    policy.loyaltyDiscountPercent = loyalty_discount_percent
    policy.weeklyPremium = _apply_loyalty_discount(policy.weeklyPremium, loyalty_discount_percent)
    policy.amountPaidThisWeek = float(policy.weeklyPremium) if policy.status == "active" else 0.0
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

    # A successful payment always schedules coverage for the upcoming paid cycle,
    # never for the already-running week.
    if status == "paid":
        effective_at = datetime(
            week_start.year,
            week_start.month,
            week_start.day,
            0,
            1,
            tzinfo=timezone.utc,
        )
        await set_pending_worker_plan(
            str(worker["phone"]),
            str(worker.get("plan_name") or ""),
            effective_at,
        )
        worker["pending_plan_name"] = str(worker.get("plan_name") or "")
        worker["pending_plan_effective_at"] = effective_at.isoformat()

    settled_total = await total_settled_amount_for_phone(str(worker["phone"]))
    payment_rows = await list_paid_premium_weeks_for_phone(str(worker["phone"]))
    clean_streak_weeks = _clean_streak_weeks_from_paid_rows(payment_rows)
    loyalty_discount_percent = _loyalty_discount_percent(clean_streak_weeks)
    policy = _build_policy(worker, settled_total, payment_rows)
    policy.cleanStreakWeeks = clean_streak_weeks
    policy.loyaltyDiscountPercent = loyalty_discount_percent
    policy.weeklyPremium = _apply_loyalty_discount(policy.weeklyPremium, loyalty_discount_percent)
    policy.amountPaidThisWeek = float(policy.weeklyPremium) if policy.status == "active" else 0.0

    logger.info(
        "premium_payment_recorded phone=%s status=%s week_start=%s amount=%s",
        worker["phone"],
        status,
        week_start.isoformat(),
        amount,
    )
    return ApiResponse(success=True, data=policy, message="Premium payment recorded")
