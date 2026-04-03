"""Module for backend\app\api\platforms.py."""

from __future__ import annotations

from fastapi import APIRouter, Depends

from ..core.dependencies import get_current_phone
from ..models.platform import Platform
from ..models.schemas import ApiResponse
from ..services.premium import PLATFORM_FACTORS

router = APIRouter(tags=["platforms"])


@router.get("", response_model=ApiResponse)
async def get_platforms(_phone: str = Depends(get_current_phone)) -> ApiResponse:
    items = [
        {"name": Platform.blinkit.display_name(), "factor": PLATFORM_FACTORS[Platform.blinkit]},
        {"name": Platform.zepto.display_name(), "factor": PLATFORM_FACTORS[Platform.zepto]},
        {
            "name": Platform.swiggy_instamart.display_name(),
            "factor": PLATFORM_FACTORS[Platform.swiggy_instamart],
        },
    ]
    return ApiResponse(success=True, data=items)
