"""Module for backend\app\api\zones.py."""

from __future__ import annotations

from fastapi import APIRouter, Depends, HTTPException, Query

from ..core.dependencies import get_current_phone
from ..core.zone_cache import load_zone_map, supports_platform, to_zone_out
from ..models.platform import Platform
from ..models.schemas import ApiResponse

router = APIRouter(tags=["zones"])


@router.get("", response_model=ApiResponse)
async def get_zones(
    platform: str | None = Query(default=None),
    _phone: str = Depends(get_current_phone),
) -> ApiResponse:
    zones = load_zone_map()
    normalized_platform = Platform.from_input(platform) if platform else None
    items = []

    for pincode, zone in zones.items():
        if normalized_platform and not supports_platform(zone, normalized_platform):
            continue
        items.append(to_zone_out(pincode, zone))

    items.sort(key=lambda item: item.name)
    return ApiResponse(success=True, data=items)


@router.get("/{pincode}", response_model=ApiResponse)
async def get_zone_by_pincode(pincode: str, _phone: str = Depends(get_current_phone)) -> ApiResponse:
    zones = load_zone_map()
    zone = zones.get(pincode)
    if zone is None:
        raise HTTPException(status_code=404, detail=f"Unknown pincode: {pincode}")
    return ApiResponse(success=True, data=to_zone_out(pincode, zone))
