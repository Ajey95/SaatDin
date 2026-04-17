"""ML-driven dynamic premium calculation using scikit-learn."""

from __future__ import annotations

import logging
from typing import Dict, Any, Optional

try:
    from sklearn.ensemble import RandomForestRegressor
    from sklearn.preprocessing import StandardScaler
    import numpy as np
except ImportError:
    RandomForestRegressor = None  # type: ignore
    StandardScaler = None  # type: ignore
    np = None  # type: ignore

logger = logging.getLogger(__name__)

# Global model instance
_premium_model: Optional[RandomForestRegressor] = None
_feature_scaler: Optional[StandardScaler] = None
_model_trained = False


def _generate_synthetic_training_data() -> tuple[list[list[float]], list[float]]:
    """
    Generate synthetic training data for premium modeling.
    Features: [flood_risk, aqi_risk, traffic_risk, zone_crime_rate, platform_factor]
    Target: weekly_premium
    """
    import random
    
    X = []
    y = []
    
    for _ in range(200):  # 200 synthetic samples
        flood = random.uniform(0.0, 1.0)
        aqi = random.uniform(0.0, 1.0)
        traffic = random.uniform(0.0, 1.0)
        crime = random.uniform(0.0, 0.5)
        platform = random.choice([0.8, 1.0, 1.1])  # Swiggy, standard, Blinkit/Zepto
        
        # Premium formula (empirical basis)
        # Base: ₹45, with adjustments for risk factors
        base_premium = 45.0
        flood_adj = flood * 20
        aqi_adj = aqi * 15
        traffic_adj = traffic * 12
        crime_adj = crime * 25
        platform_adj = (platform - 1.0) * 10
        loyalty_discount = random.uniform(0, 5)
        
        premium = (base_premium + flood_adj + aqi_adj + traffic_adj + crime_adj + platform_adj) * 1.2 - loyalty_discount
        premium = max(35, min(90, premium))  # Clamp to tier range
        
        X.append([flood, aqi, traffic, crime, platform])
        y.append(premium)
    
    return X, y


def initialize_premium_model():
    """Initialize and train the premium model on synthetic data."""
    global _premium_model, _feature_scaler, _model_trained
    
    if RandomForestRegressor is None or np is None or StandardScaler is None:
        logger.warning("scikit-learn not available, disabling ML premium model")
        return
    
    try:
        # Generate training data
        X_train, y_train = _generate_synthetic_training_data()
        X_array = np.array(X_train)
        y_array = np.array(y_train)
        
        # Normalize features
        _feature_scaler = StandardScaler()
        X_scaled = _feature_scaler.fit_transform(X_array)
        
        # Train Random Forest model
        _premium_model = RandomForestRegressor(
            n_estimators=50,
            max_depth=8,
            min_samples_split=5,
            random_state=42,
            n_jobs=-1,
        )
        _premium_model.fit(X_scaled, y_array)
        _model_trained = True
        
        logger.info("premium_ml_model_trained n_estimators=50 max_depth=8")
    except Exception as e:
        logger.warning(f"Failed to initialize premium model: {e}")
        _model_trained = False


def predict_dynamic_factor(
    zone_data: Dict[str, Any],
) -> float:
    """
    Predict dynamic adjustment factor using ML model.
    
    This factor (0.7 to 1.3) is applied ON TOP of the static zone multiplier,
    allowing real-time risk data to adjust premiums without overriding base coverage.
    
    Args:
        zone_data: Zone info with risk scores (flood, aqi, traffic, crime)
    
    Returns:
        Dynamic adjustment factor (0.7 to 1.3)
    """
    if not _model_trained or _premium_model is None or _feature_scaler is None or np is None:
        # Fallback: no dynamic adjustment
        logger.warning("dynamic_pricing_factor_fallback_applied reason=model_unavailable factor=1.0")
        return 1.0
    
    try:
        # Extract features from zone data
        flood_risk = float(zone_data.get("flood_risk_score", 0.5))
        aqi_risk = float(zone_data.get("aqi_risk_score", 0.5))
        traffic_risk = float(zone_data.get("traffic_congestion_score", 0.5))
        crime_rate = float(zone_data.get("crime_incident_rate", 0.2))
        platform_factor = 1.0  # Neutral for factor calculation
        
        # Prepare features for prediction
        features = np.array([[flood_risk, aqi_risk, traffic_risk, crime_rate, platform_factor]])
        features_scaled = _feature_scaler.transform(features)
        
        # Predict base premium from model
        base_premium_pred = _premium_model.predict(features_scaled)[0]
        
        # Convert to dynamic factor (relative to ₹45 base)
        # Factor tells us: "premiums should be X times higher than the base ₹45"
        dynamic_factor = base_premium_pred / 45.0
        
        # Clamp factor to 0.7–1.3 range (±30% adjustment)
        dynamic_factor = max(0.7, min(1.3, dynamic_factor))
        
        logger.info(
            f"dynamic_pricing_factor flood={flood_risk:.2f} aqi={aqi_risk:.2f} "
            f"traffic={traffic_risk:.2f} factor={dynamic_factor:.2f}"
        )
        return dynamic_factor
        
    except Exception as e:
        logger.warning(f"ML factor prediction error, using neutral (1.0): {e}")
        return 1.0


def get_dynamic_adjustment_with_fallback(
    zone_data: Dict[str, Any],
) -> float:
    """Get dynamic factor, with fallback to 1.0 (no adjustment) if ML unavailable."""
    if _model_trained:
        return predict_dynamic_factor(zone_data)
    logger.warning("dynamic_pricing_factor_fallback_applied reason=model_not_trained factor=1.0")
    return 1.0


def get_premium_insights(
    zone_data: Dict[str, Any],
    premium_value: float,
) -> Dict[str, Any]:
    """Generate insights about why premium is at current level."""
    flood = float(zone_data.get("flood_risk_score", 0.5))
    aqi = float(zone_data.get("aqi_risk_score", 0.5))
    traffic = float(zone_data.get("traffic_congestion_score", 0.5))
    
    insights = []
    
    if flood > 0.7:
        insights.append("High flood risk during monsoon months (+10-15%)")
    if aqi > 0.7:
        insights.append("Frequent air quality warnings (Dec-Jan) (+8-12%)")
    if traffic > 0.8:
        insights.append("Chronic traffic congestion on key corridors (+12-18%)")
    
    if not insights:
        insights.append("Low disruption risk in this zone (Base rate applied)")
    
    return {
        "premium": round(premium_value, 2),
        "factors": insights,
        "nextReviewDate": "On next pricing refresh",
    }
