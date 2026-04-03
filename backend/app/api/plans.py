"""Module for backend\app\api\plans.py."""

from __future__ import annotations

from fastapi import APIRouter, Depends, HTTPException, Query

from ..core.dependencies import get_current_phone
from ..core.zone_cache import resolve_zone, supports_platform
from ..models.platform import Platform
from ..models.schemas import ApiResponse
from ..services.premium import build_plans

router = APIRouter(tags=["plans"])


@router.get("", response_model=ApiResponse)
async def get_plans(
    zone: str = Query(...),
    platform: str = Query(...),
    _phone: str = Depends(get_current_phone),
) -> ApiResponse:
    _, zone_data = resolve_zone(zone)
    normalized = Platform.from_input(platform)

    if not supports_platform(zone_data, normalized):
        raise HTTPException(status_code=400, detail=f"Platform {platform} not supported in zone {zone}")

    zone_multiplier = float(zone_data.get("zone_risk_multiplier", 1.0))
    return ApiResponse(success=True, data=build_plans(zone_multiplier, normalized, zone_data=zone_data))
