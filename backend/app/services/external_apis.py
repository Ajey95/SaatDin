"""External API clients for real trigger data fetching."""

from __future__ import annotations

import asyncio
import logging
from datetime import datetime, timezone, timedelta
from typing import Any, Dict, Optional

from ..core.config import settings
from .zonelock_nlp import classify_disruption_text

try:
    from zoneinfo import ZoneInfo
except ImportError:
    ZoneInfo = None  # type: ignore

try:
    import aiohttp
except ImportError:
    aiohttp = None  # type: ignore

logger = logging.getLogger(__name__)

# API endpoints and configurations
OPEN_METEO_BASE = "https://api.open-meteo.com/v1/forecast"
WAQI_BASE = "https://api.waqi.info"
TOMTOM_BASE = "https://api.tomtom.com/traffic/services/4/flowSegmentData/absolute/10/json"
NEWS_API_BASE = "https://newsapi.org/v2/everything"

# Configuration for trigger thresholds
TRIGGER_THRESHOLDS = {
    "rainfall_mm": 35.0,  # > 35mm in 3 hours
    "rainfall_window_hours": 3,
    "aqi_dangerous": 250,
    "aqi_window_hours": 4,
    "traffic_speed_kmph": 5,
    "traffic_duration_hours": 2,
    "heat_temp_celsius": 39,
    "heat_humidity_percent": 70,
    "heat_window_hours": 4,
}


class ExternalAPIClient:
    """Client for fetching real-time disruption data from public APIs."""

    def __init__(self):
        self._session: Optional[Any] = None
        self._aiohttp_available = aiohttp is not None

    async def initialize(self):
        """Initialize aiohttp session if available."""
        if self._aiohttp_available:
            self._session = aiohttp.ClientSession()

    async def close(self):
        """Close aiohttp session."""
        if self._session:
            await self._session.close()

    async def _fetch_json(self, url: str, params: Optional[Dict[str, Any]] = None, timeout: int = 5) -> Optional[Dict[str, Any]]:
        """Fetch JSON from URL with timeout handling."""
        if not self._aiohttp_available or not self._session:
            return None

        try:
            async with self._session.get(url, params=params, timeout=timeout) as resp:
                if resp.status == 200:
                    return await resp.json()
                logger.warning(f"API response status {resp.status} for {url}")
                return None
        except asyncio.TimeoutError:
            logger.warning(f"API timeout for {url}")
            return None
        except Exception as e:
            logger.warning(f"API fetch error for {url}: {e}")
            return None

    def _resolve_response_timezone(self, data: Dict[str, Any]) -> timezone:
        tz_name = str(data.get("timezone") or "").strip()
        if tz_name and ZoneInfo is not None:
            try:
                return ZoneInfo(tz_name)  # type: ignore[return-value]
            except Exception as exc:
                logger.warning("api_timezone_fallback_applied reason=invalid_zoneinfo timezone=%s error=%s", tz_name, str(exc))

        offset_seconds = data.get("utc_offset_seconds")
        if isinstance(offset_seconds, (int, float)):
            try:
                return timezone(timedelta(seconds=int(offset_seconds)))
            except Exception as exc:
                logger.warning(
                    "api_timezone_fallback_applied reason=invalid_offset offset_seconds=%s error=%s",
                    str(offset_seconds),
                    str(exc),
                )

        if tz_name or offset_seconds is not None:
            logger.info("api_timezone_fallback_applied reason=default_utc timezone=%s offset_seconds=%s", tz_name, str(offset_seconds))
        return timezone.utc

    def _parse_open_meteo_time(self, raw_time: Any, response_tz: timezone) -> Optional[datetime]:
        if not isinstance(raw_time, str) or not raw_time.strip():
            return None

        value = raw_time.strip()
        try:
            parsed = datetime.fromisoformat(value.replace("Z", "+00:00"))
        except ValueError:
            # Open-Meteo usually returns ISO timestamps, but keep a strict fallback for unexpected formats.
            for fmt in ("%Y-%m-%dT%H:%M", "%Y-%m-%d %H:%M:%S", "%Y-%m-%d %H:%M"):
                try:
                    parsed = datetime.strptime(value, fmt)
                    break
                except ValueError:
                    continue
            else:
                return None

        if parsed.tzinfo is None:
            parsed = parsed.replace(tzinfo=response_tz)
        return parsed

    async def get_rainfall_data(self, latitude: float, longitude: float) -> Optional[float]:
        """
        Fetch rainfall data from Open-Meteo.
        Returns: mm of rainfall in the past 3 hours, or None if API fails.
        """
        try:
            params = {
                "latitude": latitude,
                "longitude": longitude,
                "hourly": "precipitation",
                "precipitation_unit": "mm",
                "timezone": "Asia/Kolkata",
                "past_days": 1,
                "forecast_hours": 0,
            }
            data = await self._fetch_json(OPEN_METEO_BASE, params)
            if not data or "hourly" not in data:
                return None

            hourly = data["hourly"]
            if "precipitation" not in hourly or "time" not in hourly:
                return None

            times = hourly["time"]
            precip = hourly["precipitation"]
            response_tz = self._resolve_response_timezone(data)

            # Find current time and sum last 3 hours
            now = datetime.now(response_tz)
            three_hours_ago = now - timedelta(hours=3)

            total_rainfall = 0.0
            for i, time_str in enumerate(times):
                try:
                    time_obj = self._parse_open_meteo_time(time_str, response_tz)
                    if time_obj is None:
                        continue
                    if three_hours_ago <= time_obj <= now:
                        total_rainfall += float(precip[i]) if precip[i] else 0.0
                except (ValueError, IndexError):
                    continue

            return total_rainfall
        except Exception as e:
            logger.warning(f"Error fetching rainfall data: {e}")
            return None

    async def get_aqi_data(self, latitude: float, longitude: float) -> Optional[float]:
        """
        Fetch AQI data from WAQI (World Air Quality Index).
        Returns: AQI value, or None if API fails or key not available.
        Note: Requires API key. Falls back gracefully.
        """
        try:
            if not settings.waqi_api_key:
                logger.debug("WAQI_API_KEY not configured, skipping AQI fetch")
                return None

            params = {
                "token": settings.waqi_api_key,
            }
            url = f"{WAQI_BASE}/feed/geo:{latitude};{longitude}/index.json"
            data = await self._fetch_json(url, params)

            if not data or data.get("status") != "ok":
                return None

            aqi_value = data.get("data", {}).get("aqi")
            return float(aqi_value) if aqi_value else None
        except Exception as e:
            logger.warning(f"Error fetching AQI data: {e}")
            return None

    async def get_traffic_speed(self, latitude: float, longitude: float) -> Optional[float]:
        """
        Fetch average speed from TomTom Traffic API.
        Returns: average speed in kmph, or None if API fails.
        Note: Requires API key. Falls back gracefully.
        """
        try:
            if not settings.tomtom_api_key:
                logger.debug("TOMTOM_API_KEY not configured, skipping traffic fetch")
                return None

            params = {
                "key": settings.tomtom_api_key,
                "point": f"{latitude},{longitude}",
            }
            data = await self._fetch_json(TOMTOM_BASE, params)

            if not data or "flowSegmentData" not in data:
                return None

            current_speed = data["flowSegmentData"].get("currentSpeed")
            return float(current_speed) if current_speed else None
        except Exception as e:
            logger.warning(f"Error fetching traffic speed: {e}")
            return None

    async def get_heat_humidity_data(self, latitude: float, longitude: float) -> Optional[Dict[str, float]]:
        """
        Fetch temperature and humidity from Open-Meteo.
        Returns: dict with 'temperature' and 'humidity' keys, or None if API fails.
        """
        try:
            params = {
                "latitude": latitude,
                "longitude": longitude,
                "current": "temperature_2m,relative_humidity_2m",
                "timezone": "Asia/Kolkata",
            }
            data = await self._fetch_json(OPEN_METEO_BASE, params)
            if not data or "current" not in data:
                return None

            current = data["current"]
            return {
                "temperature": float(current.get("temperature_2m", 25)),
                "humidity": float(current.get("relative_humidity_2m", 60)),
            }
        except Exception as e:
            logger.warning(f"Error fetching heat/humidity data: {e}")
            return None

    async def get_zone_disruption_news(self, zone_name: str, pincode: str) -> Optional[str]:
        """
        Fetch recent news about disruptions (curfew, bandh, strike) in zone.
        Returns: disruption keyword if found, or None.
        Note: Requires NewsAPI key. Falls back gracefully.
        """
        try:
            if not settings.news_api_key:
                logger.debug("NEWS_API_KEY not configured, skipping disruption news fetch")
                return None

            query_candidates = [
                # Location-first query: let NLP decide disruption semantics.
                f'"{zone_name}" OR "{pincode}"',
                # Broader fallback in case OR parsing is inconsistent.
                f"{zone_name} {pincode}",
            ]

            articles = []
            for query in query_candidates:
                params = {
                    "q": query,
                    "sortBy": "publishedAt",
                    "language": "en",
                    "apiKey": settings.news_api_key,
                }
                data = await self._fetch_json(NEWS_API_BASE, params)
                candidate_articles = data.get("articles") if data else None
                if isinstance(candidate_articles, list) and candidate_articles:
                    articles = candidate_articles
                    break

            if not articles:
                return None

            best_match = None
            best_confidence = 0.0
            for article in articles[:8]:
                title = str(article.get("title", "")).strip()
                description = str(article.get("description", "")).strip()
                content = f"{zone_name} {pincode} {title} {description}"
                classified = classify_disruption_text(content)
                if not classified:
                    continue
                confidence = float(classified.get("confidence", 0.0))
                if confidence > best_confidence:
                    best_confidence = confidence
                    best_match = str(classified.get("category"))

            if best_match:
                return best_match

            return None
        except Exception as e:
            logger.warning(f"Error fetching zone disruption news: {e}")
            return None


# Global client instance
_api_client: Optional[ExternalAPIClient] = None


async def initialize_api_client():
    """Initialize the global API client."""
    global _api_client
    _api_client = ExternalAPIClient()
    await _api_client.initialize()


async def close_api_client():
    """Close the global API client."""
    global _api_client
    if _api_client:
        await _api_client.close()


def get_api_client() -> ExternalAPIClient:
    """Get the global API client."""
    global _api_client
    if _api_client is None:
        _api_client = ExternalAPIClient()
    return _api_client
