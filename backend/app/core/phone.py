"""Module for backend\app\core\phone.py."""

from __future__ import annotations


def normalize_phone_number(raw: str) -> str:
    """Normalize Indian phone numbers to a canonical 10-digit format."""
    digits = "".join(ch for ch in raw if ch.isdigit())

    if len(digits) == 10:
        return digits
    if len(digits) == 11 and digits.startswith("0"):
        return digits[1:]
    if len(digits) == 12 and digits.startswith("91"):
        return digits[2:]

    raise ValueError("Phone number must be a valid 10-digit Indian number")
