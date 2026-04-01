from __future__ import annotations

from enum import Enum

from fastapi import HTTPException


class Platform(str, Enum):
    blinkit = "blinkit"
    zepto = "zepto"
    swiggy_instamart = "swiggy_instamart"

    @classmethod
    def from_input(cls, raw: str) -> "Platform":
        normalized = raw.strip().lower().replace(" ", "_")
        aliases = {
            "instamart": "swiggy_instamart",
            "swiggy": "swiggy_instamart",
        }
        normalized = aliases.get(normalized, normalized)
        try:
            return cls(normalized)
        except ValueError as exc:
            raise HTTPException(status_code=400, detail=f"Unknown platform: {raw}") from exc

    def display_name(self) -> str:
        if self is Platform.swiggy_instamart:
            return "Swiggy Instamart"
        return self.value.capitalize()
