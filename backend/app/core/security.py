from __future__ import annotations

import hashlib
import hmac
import random
import secrets
import logging
from base64 import urlsafe_b64decode, urlsafe_b64encode
from datetime import datetime, timedelta, timezone

import jwt
from fastapi import HTTPException, status
from jwt import InvalidTokenError

from .config import settings

logger = logging.getLogger(__name__)

_PASSWORD_SCHEME = "pbkdf2_sha256"
_PASSWORD_ITERATIONS = 210_000


def generate_otp() -> str:
    return str(random.SystemRandom().randint(100000, 999999))


def hash_otp(phone: str, otp: str) -> str:
    message = f"{phone}:{otp}".encode("utf-8")
    key = settings.jwt_secret.encode("utf-8")
    return hmac.new(key, message, hashlib.sha256).hexdigest()


def hash_password(password: str, *, iterations: int = _PASSWORD_ITERATIONS) -> str:
    salt = secrets.token_bytes(16)
    digest = hashlib.pbkdf2_hmac("sha256", password.encode("utf-8"), salt, int(iterations))
    salt_b64 = urlsafe_b64encode(salt).decode("ascii")
    digest_b64 = urlsafe_b64encode(digest).decode("ascii")
    return f"{_PASSWORD_SCHEME}${int(iterations)}${salt_b64}${digest_b64}"


def verify_password(password: str, stored_value: str) -> bool:
    stored = str(stored_value or "").strip()
    parts = stored.split("$")
    if len(parts) == 4 and parts[0] == _PASSWORD_SCHEME:
        try:
            iterations = int(parts[1])
            salt = urlsafe_b64decode(parts[2].encode("ascii"))
            expected = urlsafe_b64decode(parts[3].encode("ascii"))
        except Exception as exc:
            logger.warning("password_hash_parse_failed fallback=reject reason=%s", str(exc))
            return False
        derived = hashlib.pbkdf2_hmac("sha256", password.encode("utf-8"), salt, max(1, iterations))
        return hmac.compare_digest(derived, expected)

    # Backward-compatible fallback for legacy plaintext admin password config.
    logger.warning("password_verify_legacy_fallback_applied scheme=plaintext")
    return hmac.compare_digest(password, stored)


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
