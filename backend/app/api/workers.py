"""Module for backend\app\api\workers.py."""

from __future__ import annotations
import logging

from fastapi import APIRouter, Depends, HTTPException, status

from ..core.db import get_worker, upsert_worker
from ..core.dependencies import get_current_phone, get_current_worker
from ..core.phone import normalize_phone_number
from ..core.zone_cache import resolve_zone, supports_platform
from ..models.platform import Platform
from ..models.schemas import ApiResponse, RegisterRequest, WorkerOut, WorkerStatusOut
from ..services.premium import build_plans
from ..core.db import total_settled_amount_for_phone

router = APIRouter(tags=["workers"])
logger = logging.getLogger(__name__)


@router.post("/register", response_model=ApiResponse, status_code=status.HTTP_201_CREATED)
async def register(payload: RegisterRequest, current_phone: str = Depends(get_current_phone)) -> ApiResponse:
    try:
        normalized_phone = normalize_phone_number(payload.phone)
    except ValueError as exc:
        raise HTTPException(status_code=status.HTTP_400_BAD_REQUEST, detail=str(exc)) from exc

    logger.info("register_requested phone=%s platform=%s zone=%s", normalized_phone, payload.platformName, payload.zone)
    if normalized_phone != current_phone:
        raise HTTPException(status_code=403, detail="Token subject does not match payload.phone")

    pincode, zone_data = resolve_zone(payload.zone)
    platform = Platform.from_input(payload.platformName)

    if not supports_platform(zone_data, platform):
        raise HTTPException(status_code=400, detail=f"Platform {payload.platformName} not supported")

    plans = build_plans(float(zone_data.get("zone_risk_multiplier", 1.0)), platform, zone_data=zone_data)
    selected = next((p for p in plans if p.name.lower() == payload.planName.strip().lower()), None)
    if not selected:
        raise HTTPException(status_code=400, detail=f"Unknown plan: {payload.planName}")

    worker_name = (payload.name or "Worker").strip() or "Worker"
    zone_name = str(zone_data.get("name", payload.zone))

    await upsert_worker(
        phone=normalized_phone,
        name=worker_name,
        platform_name=platform.display_name(),
        zone_pincode=pincode,
        zone_name=zone_name,
        plan_name=selected.name,
    )

    record = await get_worker(normalized_phone)
    if not record:
        raise HTTPException(status_code=500, detail="Failed to persist worker")

    out = WorkerOut(
        name=record["name"],
        phone=record["phone"],
        platform=record["platform_name"],
        zone=record["zone_name"],
        zonePincode=record["zone_pincode"],
        plan=record["plan_name"],
        policyId=f"SR-{record['zone_pincode'][-4:]}",
        totalEarnings=0,
        earningsProtected=0,
    )
    logger.info("register_succeeded phone=%s policy_id=%s", out.phone, out.policyId)
    return ApiResponse(success=True, data=out, message="Worker registered")


@router.get("/workers/status", response_model=ApiResponse)
async def get_worker_status(current_phone: str = Depends(get_current_phone)) -> ApiResponse:
    worker = await get_worker(current_phone)
    if not worker:
        return ApiResponse(
            success=True,
            data=WorkerStatusOut(phone=current_phone, exists=False, worker=None),
            message="No worker profile found",
        )

    out = WorkerOut(
        name=worker["name"],
        phone=worker["phone"],
        platform=worker["platform_name"],
        zone=worker["zone_name"],
        zonePincode=worker["zone_pincode"],
        plan=worker["plan_name"],
        policyId=f"SR-{worker['zone_pincode'][-4:]}",
        totalEarnings=0,
        earningsProtected=0,
    )
    return ApiResponse(
        success=True,
        data=WorkerStatusOut(phone=current_phone, exists=True, worker=out),
        message="Worker profile found",
    )


@router.get("/workers/me", response_model=ApiResponse)
async def get_my_worker(worker: dict = Depends(get_current_worker)) -> ApiResponse:
    logger.info("worker_profile_requested phone=%s", worker["phone"])
    settled_total = await total_settled_amount_for_phone(str(worker["phone"]))
    out = WorkerOut(
        name=worker["name"],
        phone=worker["phone"],
        platform=worker["platform_name"],
        zone=worker["zone_name"],
        zonePincode=worker["zone_pincode"],
        plan=worker["plan_name"],
        policyId=f"SR-{worker['zone_pincode'][-4:]}",
        totalEarnings=round(settled_total),
        earningsProtected=round(settled_total),
    )
    return ApiResponse(success=True, data=out)
