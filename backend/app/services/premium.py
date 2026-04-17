from __future__ import annotations

import logging
from typing import List, Dict, Any

from ..core.config import settings
from ..models.platform import Platform
from ..models.schemas import PlanOut

logger = logging.getLogger(__name__)

PLATFORM_FACTORS = {
    Platform.blinkit: 1.10,
    Platform.zepto: 1.10,
    Platform.swiggy_instamart: 1.00,
}

TIER_FACTORS = {
    "basic": 0.72,
    "standard": 0.95,
    "premium": 1.25,
}


def calculate_premium(zone_multiplier: float, platform: Platform, tier: str) -> int:
    """Calculate premium using formula-based method (fallback)."""
    premium = settings.base_rate * zone_multiplier * PLATFORM_FACTORS[platform] * TIER_FACTORS[tier]
    return int(round(premium))


def calculate_premium_ml(
    zone_data: Dict[str, Any],
    platform: Platform,
    tier: str,
    zone_multiplier: float = 1.0,
) -> int:
    """Calculate premium with hybrid approach: static multiplier + dynamic ML factor.
    
    Formula: Base × StaticMultiplier × DynamicMLFactor × PlatformFactor × TierFactor
    """
    from .ml_premium import get_dynamic_adjustment_with_fallback
    
    platform_factor = PLATFORM_FACTORS[platform]
    tier_factor = TIER_FACTORS[tier]
    
    # Get dynamic adjustment factor from ML model (0.7–1.3)
    dynamic_factor = get_dynamic_adjustment_with_fallback(zone_data)
    
    # Hybrid calculation: apply both static and dynamic factors
    premium = (
        settings.base_rate
        * zone_multiplier  # Static zone risk factor
        * dynamic_factor    # Dynamic ML-based adjustment
        * platform_factor
        * tier_factor
    )
    
    return int(round(premium))


def build_plans(zone_multiplier: float, platform: Platform, zone_data: Dict[str, Any] = None) -> List[PlanOut]:
    """Build insurance plans with ML-driven dynamic pricing if zone_data provided."""
    
    # Use ML-driven pricing if zone data available, else fall back to formula
    if zone_data is not None:
        basic_premium = calculate_premium_ml(zone_data, platform, "basic", zone_multiplier)
        standard_premium = calculate_premium_ml(zone_data, platform, "standard", zone_multiplier)
        premium_premium = calculate_premium_ml(zone_data, platform, "premium", zone_multiplier)
    else:
        logger.warning(
            "premium_formula_fallback_applied reason=missing_zone_data platform=%s zone_multiplier=%.3f",
            platform.value,
            float(zone_multiplier),
        )
        basic_premium = calculate_premium(zone_multiplier, platform, "basic")
        standard_premium = calculate_premium(zone_multiplier, platform, "standard")
        premium_premium = calculate_premium(zone_multiplier, platform, "premium")
    
    return [
        PlanOut(
            name="Basic",
            weeklyPremium=basic_premium,
            perTriggerPayout=250,
            maxDaysPerWeek=2,
            isPopular=False,
        ),
        PlanOut(
            name="Standard",
            weeklyPremium=standard_premium,
            perTriggerPayout=400,
            maxDaysPerWeek=3,
            isPopular=True,
        ),
        PlanOut(
            name="Premium",
            weeklyPremium=premium_premium,
            perTriggerPayout=550,
            maxDaysPerWeek=4,
            isPopular=False,
        ),
    ]
