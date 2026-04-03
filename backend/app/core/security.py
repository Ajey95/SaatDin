"""Module for backend\app\core\security.py."""

from __future__ import annotations

import hashlib
import hmac
import random
from datetime import datetime, timedelta, timezone

import jwt
from fastapi import HTTPException, status
from jwt import InvalidTokenError

from .config import settings


def generate_otp() -> str:
    return str(random.SystemRandom().randint(100000, 999999))


def hash_otp(phone: str, otp: str) -> str:
    message = f"{phone}:{otp}".encode("utf-8")
    key = settings.jwt_secret.encode("utf-8")
    return hmac.new(key, message, hashlib.sha256).hexdigest()


def create_access_token(phone_number: str) -> str:
    now = datetime.now(timezone.utc)
    exp = now + timedelta(minutes=settings.jwt_expiration_minutes)
    payload = {
        "sub": phone_number,
        "iat": int(now.timestamp()),
        "exp": int(exp.timestamp()),
    }
    return jwt.encode(payload, settings.jwt_secret, algorithm=settings.jwt_algorithm)


def decode_access_token(token: str) -> str:
    credentials_error = HTTPException(
        status_code=status.HTTP_401_UNAUTHORIZED,
        detail="Invalid authentication token",
    )

    try:
        payload = jwt.decode(token, settings.jwt_secret, algorithms=[settings.jwt_algorithm])
        phone = payload.get("sub")
        if not phone:
            raise credentials_error
        return phone
    except InvalidTokenError as exc:
        raise credentials_error from exc
