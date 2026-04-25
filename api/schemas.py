"""
schemas.py — Pydantic models for request/response shapes.
"""
from typing import Any, Dict, List, Optional
from pydantic import BaseModel, Field


class ExtractedFields(BaseModel):
    full_name:       Optional[str] = Field(None, example="JOHN DOE")
    license_number:  Optional[str] = Field(None, example="D1234567")
    date_of_birth:   Optional[str] = Field(None, example="1990-05-15")
    expiration_date: Optional[str] = Field(None, example="2027-05-15")
    license_class:   Optional[str] = Field(None, example="C", alias="class")

    class Config:
        populate_by_name = True


class ValidationResult(BaseModel):
    status:         str           = Field(..., example="valid")
    days_remaining: Optional[int] = Field(None, example=418)
    reason:         str           = Field(..., example="Valid for 418 more days.")


class LicenseResult(BaseModel):
    source_file:      str              = Field(..., example="license_01.png")
    processed_at:     str              = Field(..., example="2025-03-23T21:00:00")
    extracted_fields: ExtractedFields
    validation:       ValidationResult


class ResultSummary(BaseModel):
    filename:     str           = Field(..., example="license_01.json")
    processed_at: Optional[str] = Field(None)
    status:       Optional[str] = Field(None, example="valid")
    full_name:    Optional[str] = Field(None, example="JOHN DOE")


class BulkFileError(BaseModel):
    filename: str = Field(..., example="license_bad.png")
    error:    str = Field(..., example="Pipeline error: ...")


class BulkSkipped(BaseModel):
    filename: str = Field(..., example="document.pdf")
    reason:   str = Field(..., example="Unsupported type '.pdf'")


class BulkUploadResult(BaseModel):
    total:         int                  = Field(..., example=10)
    succeeded:     int                  = Field(..., example=8)
    failed:        int                  = Field(..., example=1)
    skipped:       int                  = Field(..., example=1)
    results:       List[Dict[str, Any]] = Field(default_factory=list)
    errors:        List[BulkFileError]  = Field(default_factory=list)
    skipped_files: List[BulkSkipped]    = Field(default_factory=list)


class ErrorResponse(BaseModel):
    detail: str = Field(..., example="No valid image file provided.")
