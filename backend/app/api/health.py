from __future__ import annotations
import logging

from fastapi import APIRouter, status
from fastapi.responses import JSONResponse

from ..core.config import settings
from ..core.db import healthcheck_db
from ..core.zone_cache import load_zone_map
from ..models.schemas import HealthOut

router = APIRouter(tags=["health"])
logger = logging.getLogger(__name__)


@router.get("", response_model=HealthOut)
async def health() -> JSONResponse:
    checks = {
        "zone_data": bool(load_zone_map()),
        "database": await healthcheck_db(),
    }
    all_ok = all(checks.values())
    logger.info("health_checked status=%s checks=%s", "ok" if all_ok else "degraded", checks)
    body = HealthOut(
        status="ok" if all_ok else "degraded",
        checks=checks,
        version=settings.app_version,
    )
    return JSONResponse(
        status_code=status.HTTP_200_OK if all_ok else status.HTTP_503_SERVICE_UNAVAILABLE,
        content=body.model_dump(),
    )
