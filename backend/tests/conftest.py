"""Shared fixtures for backend tests."""
from __future__ import annotations

import os
import tempfile
from datetime import datetime, timedelta, timezone
from unittest.mock import AsyncMock, patch

import pytest
from fastapi import FastAPI
from fastapi.testclient import TestClient

from backend.app.core.security import create_access_token
from backend.app.core import zone_cache


@pytest.fixture(autouse=True)
def _isolate_database(tmp_path):
    """Each test gets its own temporary SQLite database."""
    db_path = str(tmp_path / "test_backend.db")
    zone_map = {
        "560103": {
            "name": "Bellandur",
            "zone_risk_multiplier": 1.0,
            "dark_stores": {
                "Blinkit": True,
                "Zepto": True,
                "Swiggy_Instamart": True,
            },
        }
    }
    with (
        patch("backend.app.core.config.settings.database_path", db_path),
        patch.object(zone_cache, "_ZONE_MAP", zone_map),
        patch.object(zone_cache, "_ZONE_NAME_INDEX", {"bellandur": "560103"}),
    ):
        yield


@pytest.fixture
def auth_token() -> str:
    """A valid JWT token for phone 9876543210."""
    return create_access_token("9876543210")


@pytest.fixture
def auth_headers(auth_token: str) -> dict:
    """Authorization headers with a valid bearer token."""
    return {"Authorization": f"Bearer {auth_token}", "Content-Type": "application/json"}


@pytest.fixture
def admin_auth():
    """HTTP Basic credentials for the admin endpoints."""
    import base64
    creds = base64.b64encode(b"admin:saatdin-local").decode()
    return {"Authorization": f"Basic {creds}"}


@pytest.fixture
async def registered_worker():
    """Create and return a registered worker in the test database."""
    from backend.app.core.db import init_db, upsert_worker

    await init_db()
    await upsert_worker(
        phone="9876543210",
        name="Test Worker",
        platform_name="Blinkit",
        zone_pincode="560103",
        zone_name="Bellandur",
        plan_name="Standard",
    )
    return {
        "phone": "9876543210",
        "name": "Test Worker",
        "platform_name": "Blinkit",
        "zone_pincode": "560103",
        "zone_name": "Bellandur",
        "plan_name": "Standard",
    }
