"""Module for backend\app\core\config.py."""

from __future__ import annotations

from pathlib import Path
from typing import Any, List

from pydantic import field_validator
from pydantic_settings import BaseSettings, SettingsConfigDict


class Settings(BaseSettings):
    app_name: str = "SaatDin API"
    app_version: str = "0.2.0"

    base_rate: float = 45.0
    jwt_secret: str = "replace-me-in-env"
    jwt_algorithm: str = "HS256"
    jwt_expiration_minutes: int = 60 * 24

    otp_ttl_seconds: int = 300
    otp_max_attempts: int = 5
    otp_send_cooldown_seconds: int = 30
    expose_debug_otp: bool = True

    supabase_db_url: str = ""
    db_pool_min_size: int = 1
    db_pool_max_size: int = 10
    zone_data_path: str = ""

    # External API keys (optional; graceful fallback if missing)
    waqi_api_key: str = ""
    tomtom_api_key: str = ""
    news_api_key: str = ""

    cors_origins: List[str] = [
        "http://localhost",
        "http://localhost:3000",
        "http://localhost:8080",
    ]
    cors_allow_origin_regex: str = r"^https?://(localhost|127\.0\.0\.1)(:\d+)?$"

    model_config = SettingsConfigDict(env_file=(".env", "backend/.env"), extra="ignore")

    @field_validator("cors_origins", mode="before")
    @classmethod
    def _parse_cors_origins(cls, value: Any) -> List[str]:
        if isinstance(value, str):
            return [item.strip() for item in value.split(",") if item.strip()]
        return value

    @property
    def zone_file_path(self) -> Path:
        if self.zone_data_path:
            return Path(self.zone_data_path)
        return Path(__file__).resolve().parents[3] / "assets" / "data" / "zone_risk_runtime.json"

    @property
    def database_url(self) -> str:
        if not self.supabase_db_url.strip():
            raise ValueError("SUPABASE_DB_URL is required. Example: postgresql://postgres:<password>@<host>:5432/postgres")
        return self.supabase_db_url.strip()


settings = Settings()
