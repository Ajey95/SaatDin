"""Module for backend\app\models\schemas.py."""

from __future__ import annotations

from typing import Any, Dict, List, Optional

from pydantic import BaseModel, Field


class ApiResponse(BaseModel):
    success: bool = True
    data: Any = None
    message: Optional[str] = None


class OtpRequest(BaseModel):
    phoneNumber: str = Field(min_length=10)


class OtpVerifyRequest(BaseModel):
    phoneNumber: str = Field(min_length=10)
    otp: str = Field(min_length=4, max_length=6)


class RegisterRequest(BaseModel):
    phone: str
    platformName: str
    zone: str
    planName: str
    name: Optional[str] = None


class ZoneOut(BaseModel):
    pincode: str
    name: str
    zoneRiskMultiplier: float
    riskTier: str
    customRainLockThresholdMm3hr: int
    supports: Dict[str, bool]


class PlanOut(BaseModel):
    name: str
    weeklyPremium: int
    perTriggerPayout: int
    maxDaysPerWeek: int
    isPopular: bool = False


class AuthTokenOut(BaseModel):
    token: str
    tokenType: str = "bearer"


class WorkerOut(BaseModel):
    name: str
    phone: str
    platform: str
    zone: str
    zonePincode: str
    plan: str
    policyId: str
    totalEarnings: int = 0
    earningsProtected: int = 0
    isVerified: bool = True
    language: str = "English"


class WorkerStatusOut(BaseModel):
    phone: str
    exists: bool
    worker: Optional[WorkerOut] = None


class TriggerOut(BaseModel):
    hasActiveAlert: bool
    alertType: str
    alertTitle: str
    alertDescription: str
    confidence: float
    source: str


class TriggerForceRequest(BaseModel):
    zone: str = Field(min_length=2)
    claimType: str = Field(min_length=3)
    alertTitle: str = Field(min_length=3)
    alertDescription: str = Field(min_length=5, max_length=500)
    confidence: float = Field(default=0.9, ge=0.0, le=1.0)


class TriggerForceOut(BaseModel):
    zone: str
    pincode: str
    claimType: str
    alertTitle: str
    hasActiveAlert: bool
    autoClaimsCreated: int
    source: str


class HealthOut(BaseModel):
    status: str
    checks: Dict[str, bool]
    version: str


class PolicyOut(BaseModel):
    status: str
    plan: str
    pendingPlan: Optional[str] = None
    pendingEffectiveDate: Optional[str] = None
    zone: str
    zonePincode: str
    weeklyPremium: int
    earningsProtected: float
    parametricCoverageOn: bool
    perTriggerPayout: int
    maxDaysPerWeek: int
    nextBillingDate: str


class PolicyUpdateRequest(BaseModel):
    planName: str


class ClaimSubmitRequest(BaseModel):
    claimType: str
    description: str = Field(min_length=3, max_length=300)


class ClaimOut(BaseModel):
    id: str
    claimType: str
    status: str
    amount: float
    date: str
    description: str
    source: str


class ZoneLockReportRequest(BaseModel):
    description: str = Field(min_length=5, max_length=500)


class ZoneLockReportOut(BaseModel):
    id: int
    zonePincode: str
    zoneName: str
    description: str
    status: str
    confidence: float
    verifiedCount: int
    createdAt: str


class ZoneLockReportVerifyRequest(BaseModel):
    reportId: int


class ClaimEscalateRequest(BaseModel):
    reason: str = Field(min_length=5, max_length=500)


class ClaimEscalationOut(BaseModel):
    id: int
    claimId: int
    phone: str
    reason: str
    status: str
    reviewNotes: Optional[str] = None
    createdAt: str
