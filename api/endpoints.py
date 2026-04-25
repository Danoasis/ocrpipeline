# api/endpoints.py
import json
import os
import tempfile
from pathlib import Path

from fastapi import APIRouter, File, HTTPException, UploadFile

from api.schemas import BulkUploadResult, ErrorResponse, LicenseResult, ResultSummary
from app.config import ALLOWED_EXTENSIONS, OUTPUT_FOLDER
from app.pipeline import process_license, save_result

router = APIRouter()


@router.post("/upload", response_model=LicenseResult, summary="Upload a single license image",
    responses={400: {"model": ErrorResponse}, 500: {"model": ErrorResponse}})
async def upload_license(file: UploadFile = File(...)):
    suffix = Path(file.filename).suffix.lower()
    if suffix not in ALLOWED_EXTENSIONS:
        raise HTTPException(status_code=400,
            detail=f"File type '{suffix}' not supported. Allowed: {', '.join(sorted(ALLOWED_EXTENSIONS))}")
    tmp = tempfile.NamedTemporaryFile(delete=False, suffix=suffix)
    try:
        tmp.write(await file.read())
        tmp.flush()
        tmp.close()
        try:
            result = process_license(tmp.name)
        except Exception as e:
            raise HTTPException(status_code=500, detail=f"Pipeline error: {str(e)}") from e
        save_result(file.filename, result)
        return result
    finally:
        os.unlink(tmp.name)


@router.post("/upload/bulk", response_model=BulkUploadResult, summary="Upload multiple images")
async def upload_bulk(files: list[UploadFile] = File(...)):
    if not files:
        raise HTTPException(status_code=400, detail="No files provided.")
    if len(files) > 50:
        raise HTTPException(status_code=400, detail="Maximum batch size is 50 files.")
    results: list[dict] = []
    errors:  list[dict] = []
    skipped: list[dict] = []
    for file in files:
        suffix = Path(file.filename).suffix.lower()
        if suffix not in ALLOWED_EXTENSIONS:
            skipped.append({"filename": file.filename, "reason": f"Unsupported type '{suffix}'"})
            continue
        tmp = tempfile.NamedTemporaryFile(delete=False, suffix=suffix)
        try:
            tmp.write(await file.read())
            tmp.flush()
            tmp.close()
            result = process_license(tmp.name)
            save_result(file.filename, result)
            result["filename"] = file.filename
            results.append(result)
        except Exception as e:
            print(f"  [BULK ERROR] {file.filename}: {e}")
            errors.append({"filename": file.filename, "error": str(e)})
        finally:
            os.unlink(tmp.name)
    return BulkUploadResult(total=len(files), succeeded=len(results), failed=len(errors),
        skipped=len(skipped), results=results, errors=errors, skipped_files=skipped)


@router.get("/results", response_model=list[ResultSummary])
async def list_results():
    output_path = Path(OUTPUT_FOLDER)
    if not output_path.exists():
        return []
    summaries = []
    for json_file in sorted(output_path.glob("*.json"), reverse=True):
        try:
            with open(json_file, encoding="utf-8") as f:
                data = json.load(f)
            summaries.append(ResultSummary(filename=json_file.name,
                processed_at=data.get("processed_at"),
                status=data.get("validation", {}).get("status"),
                full_name=data.get("extracted_fields", {}).get("full_name")))
        except (json.JSONDecodeError, KeyError):
            summaries.append(ResultSummary(filename=json_file.name,
                processed_at=None, status="error", full_name=None))
    return summaries


@router.get("/results/{filename}", response_model=LicenseResult)
async def get_result(filename: str):
    if "/" in filename or "\\" in filename or ".." in filename:
        raise HTTPException(status_code=400, detail="Invalid filename.")
    result_path = Path(OUTPUT_FOLDER) / filename
    if not result_path.exists():
        raise HTTPException(status_code=404, detail=f"Result '{filename}' not found.")
    with open(result_path, encoding="utf-8") as f:
        return json.load(f)


@router.get("/health", include_in_schema=False)
async def health():
    return {"status": "ok"}
