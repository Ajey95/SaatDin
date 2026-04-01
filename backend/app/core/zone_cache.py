from __future__ import annotations

import json
from functools import lru_cache
from typing import Any, Dict, Tuple

from fastapi import HTTPException

from .config import settings
from ..models.platform import Platform
from ..models.schemas import ZoneOut


@lru_cache(maxsize=1)
def load_zone_map() -> Dict[str, Dict[str, Any]]:
    path = settings.zone_file_path
    if not path.exists():
        raise RuntimeError("zone_risk_runtime.json not found")
    raw = json.loads(path.read_text(encoding="utf-8"))
    return raw.get("pincodes", {})


@lru_cache(maxsize=1)
def zone_name_index() -> Dict[str, str]:
    return {
        str(zone.get("name", "")).strip().lower(): pincode
        for pincode, zone in load_zone_map().items()
    }


def clear_zone_cache() -> None:
    load_zone_map.cache_clear()
    zone_name_index.cache_clear()


def resolve_zone(zone_key: str) -> Tuple[str, Dict[str, Any]]:
    zones = load_zone_map()
    stripped = zone_key.strip()
    if stripped in zones:
        return stripped, zones[stripped]

    by_name = zone_name_index().get(stripped.lower())
    if by_name and by_name in zones:
        return by_name, zones[by_name]

    raise HTTPException(status_code=404, detail=f"Unknown zone: {zone_key}")


def supports_platform(zone: Dict[str, Any], platform: Platform) -> bool:
    stores = zone.get("dark_stores", {})
    if platform is Platform.blinkit:
        return stores.get("Blinkit") is True
    if platform is Platform.zepto:
        return stores.get("Zepto") is True
    if platform is Platform.swiggy_instamart:
        return stores.get("Swiggy_Instamart") is True
    return False


def to_zone_out(pincode: str, zone: Dict[str, Any]) -> ZoneOut:
    stores = zone.get("dark_stores", {})
    return ZoneOut(
        pincode=pincode,
        name=zone.get("name", ""),
        zoneRiskMultiplier=float(zone.get("zone_risk_multiplier", 1.0)),
        riskTier=str(zone.get("risk_tier", "MEDIUM")),
        customRainLockThresholdMm3hr=int(zone.get("custom_rainlock_threshold_mm_3hr", 35)),
        supports={
            "blinkit": stores.get("Blinkit") is True,
            "zepto": stores.get("Zepto") is True,
            "swiggyInstamart": stores.get("Swiggy_Instamart") is True,
        },
    )
