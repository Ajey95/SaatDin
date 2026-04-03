"""Module for backend\app\core\dependencies.py."""

from __future__ import annotations

from fastapi import Depends, HTTPException, status
from fastapi.security import OAuth2PasswordBearer

from .db import apply_due_pending_worker_plan, get_worker
from .phone import normalize_phone_number
from .security import decode_access_token

oauth2_scheme = OAuth2PasswordBearer(tokenUrl="/api/v1/auth/verify-otp")


async def get_current_phone(token: str = Depends(oauth2_scheme)) -> str:
    return normalize_phone_number(decode_access_token(token))


async def get_current_worker(phone: str = Depends(get_current_phone)) -> dict:
    await apply_due_pending_worker_plan(phone)
    worker = await get_worker(phone)
    if not worker:
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED,
            detail="Worker not found for token subject",
        )
    return worker
