"""Module for backend\app\api\claims.py."""

from __future__ import annotations

import logging
from datetime import datetime

from fastapi import APIRouter, Depends, HTTPException, status, Path

from ..core.db import create_claim, list_claims_for_phone, escalate_claim, get_claim_escalation
from ..core.dependencies import get_current_worker
from ..models.schemas import ApiResponse, ClaimOut, ClaimSubmitRequest, ClaimEscalateRequest, ClaimEscalationOut

router = APIRouter(tags=["claims"])
logger = logging.getLogger(__name__)

_ALLOWED_CLAIM_TYPES = {
    "rainlock": "RainLock",
    "aqi_guard": "AQI Guard",
    "aqiguard": "AQI Guard",
    "trafficblock": "TrafficBlock",
    "zonelock": "ZoneLock",
    "heatblock": "HeatBlock",
}

_MANUAL_PAYOUT = {
    "RainLock": 400.0,
    "AQI Guard": 320.0,
    "TrafficBlock": 280.0,
    "ZoneLock": 400.0,
    "HeatBlock": 240.0,
}


def _normalize_claim_type(raw: str) -> str:
    key = raw.strip().lower().replace(" ", "").replace("_", "")
    if key not in _ALLOWED_CLAIM_TYPES:
        raise HTTPException(status_code=400, detail=f"Unknown claim type: {raw}")
    return _ALLOWED_CLAIM_TYPES[key]


def _to_claim_out(row: dict) -> ClaimOut:
    return ClaimOut(
        id=f"#C{int(row['id']):05d}",
        claimType=str(row["claim_type"]),
        status=str(row["status"]),
        amount=float(row["amount"]),
        date=str(row["created_at"]),
        description=str(row["description"]),
        source=str(row["source"]),
    )


@router.get("", response_model=ApiResponse)
async def get_my_claims(worker: dict = Depends(get_current_worker)) -> ApiResponse:
    rows = await list_claims_for_phone(str(worker["phone"]))
    items = [_to_claim_out(row) for row in rows]
    logger.info("claims_list_requested phone=%s count=%s", worker["phone"], len(items))
    return ApiResponse(success=True, data=items)


@router.post("/submit", response_model=ApiResponse, status_code=status.HTTP_201_CREATED)
async def submit_claim(payload: ClaimSubmitRequest, worker: dict = Depends(get_current_worker)) -> ApiResponse:
    claim_type = _normalize_claim_type(payload.claimType)
    amount = _MANUAL_PAYOUT.get(claim_type, 250.0)

    row = await create_claim(
        phone=str(worker["phone"]),
        claim_type=claim_type,
        status="in_review",
        amount=amount,
        description=payload.description.strip(),
        zone_pincode=str(worker["zone_pincode"]),
        source="manual",
    )
    out = _to_claim_out(row)
    logger.info("claim_submitted phone=%s claim_id=%s claim_type=%s", worker["phone"], out.id, claim_type)

    return ApiResponse(
        success=True,
        data=out,
        message="Claim submitted for review",
    )


@router.post("/{claim_id}/escalate", response_model=ApiResponse, status_code=status.HTTP_201_CREATED)
async def escalate_claim_endpoint(
    claim_id: int = Path(..., ge=1),
    payload: ClaimEscalateRequest = None,
    worker: dict = Depends(get_current_worker),
) -> ApiResponse:
    """
    Worker escalates a claim for manual review (e.g., disputes auto-settlement).
    Claim is marked and queued for human review with target SLA of 2 hours.
    """
    if payload is None:
        raise HTTPException(status_code=400, detail="Escalation reason required")

    phone = str(worker["phone"])
    
    # TODO: Verify that claim_id belongs to this phone (add check)
    # For now, we'll allow escalation

    escalation = await escalate_claim(
        claim_id=claim_id,
        phone=phone,
        reason=payload.reason.strip(),
    )

    logger.info(
        f"claim_escalated claim_id={claim_id} phone={phone} reason={payload.reason[:50]}..."
    )

    return ApiResponse(
        success=True,
        data=ClaimEscalationOut(
            id=escalation["id"],
            claimId=escalation["claim_id"],
            phone=escalation["phone"],
            reason=escalation["reason"],
            status=escalation["status"],
            reviewNotes=None,
            createdAt=escalation["created_at"],
        ),
        message="Claim escalated for manual review. Review SLA: 2 hours.",
    )
