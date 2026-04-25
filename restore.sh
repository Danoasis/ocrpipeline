#!/usr/bin/env bash
# =============================================================================
# restore.sh — recreates the full ocrpipeline project from scratch
# Run from inside your project folder: bash restore.sh
# =============================================================================
set -euo pipefail

echo "Creating directory structure..."
mkdir -p app api static tests scripts k8s/ollama k8s/api \
         terraform ansible/group_vars \
         ansible/roles/common/tasks ansible/roles/common/handlers \
         ansible/roles/docker/tasks  ansible/roles/docker/handlers \
         ansible/roles/ollama/tasks  ansible/roles/ollama/handlers \
         .github/workflows licenses results

# ===========================================================================
# app/
# ===========================================================================

cat > app/__init__.py << 'EOF'
# OCR Pipeline package
EOF

cat > app/config.py << 'EOF'
"""
config.py — all configuration loaded from environment variables.
"""
import os
from dotenv import load_dotenv

load_dotenv()

INPUT_FOLDER:  str      = os.getenv("INPUT_FOLDER",  "licenses/")
OUTPUT_FOLDER: str      = os.getenv("OUTPUT_FOLDER", "results/")

OLLAMA_URL:    str      = os.getenv("OLLAMA_URL",    "http://localhost:11434/api/chat")
OLLAMA_MODEL:  str      = os.getenv("OLLAMA_MODEL",  "llama3.2")
OLLAMA_TIMEOUT: int     = int(os.getenv("OLLAMA_TIMEOUT", "60"))

USE_GPU: bool           = os.getenv("USE_GPU", "false").lower() == "true"

ALLOWED_EXTENSIONS: set[str] = {".png", ".jpg", ".jpeg", ".bmp", ".tiff"}
EOF

cat > app/ocr.py << 'EOF'
"""
ocr.py — EasyOCR text extraction.
Reader is initialised once at module load to avoid reloading the model on every call.
"""
import easyocr
from app.config import USE_GPU

reader = easyocr.Reader(["en"], gpu=USE_GPU)


def extract_text_from_image(image_path: str) -> str:
    results  = reader.readtext(image_path, detail=0)
    raw_text = " ".join(results)
    print(f"  [OCR] Extracted {len(raw_text)} characters from {image_path}")
    return raw_text
EOF

cat > app/llm.py << 'EOF'
"""
llm.py — sends OCR text to Ollama and returns structured JSON.

Fixes:
  - num_predict=500 prevents truncated responses.
  - repair_json() closes missing braces before giving up.
"""
import json
import re
import requests
from app.config import OLLAMA_MODEL, OLLAMA_TIMEOUT, OLLAMA_URL

SYSTEM_PROMPT = """You are a data extraction assistant. Given raw OCR text from a driver's license, return ONLY a valid JSON object — no markdown, no backticks, no explanation.

Expected format:
{
    "full_name": "string or null",
    "license_number": "string or null",
    "date_of_birth": "YYYY-MM-DD or null",
    "expiration_date": "YYYY-MM-DD or null",
    "class": "string or null"
}

Rules:
- If a field cannot be found, return null for that field.
- Do not make up information that is not present in the text.
- Do not return any additional fields beyond the ones listed above.
- Dates must be formatted as YYYY-MM-DD exactly.
- Always close the JSON object with a closing brace.
"""


def repair_json(raw: str) -> str:
    cleaned = re.sub(r"^```json\s*|^```\s*|```$", "", raw, flags=re.MULTILINE).strip()
    missing = cleaned.count("{") - cleaned.count("}")
    if missing > 0:
        print(f"  [REPAIR] Appending {missing} missing '}}' character(s).")
        cleaned += "}" * missing
    return cleaned


def extract_structured_data(raw_text: str) -> dict:
    payload = {
        "model": OLLAMA_MODEL,
        "messages": [
            {"role": "system", "content": SYSTEM_PROMPT},
            {"role": "user",   "content": f"Raw OCR text:\n{raw_text}"},
        ],
        "stream": False,
        "options": {"temperature": 0, "num_predict": 500},
    }

    response = requests.post(OLLAMA_URL, json=payload, timeout=OLLAMA_TIMEOUT)
    response.raise_for_status()
    raw_response = response.json()["message"]["content"].strip()

    cleaned = re.sub(r"^```json\s*|^```\s*|```$", "", raw_response, flags=re.MULTILINE).strip()

    try:
        data = json.loads(cleaned)
        print("  [LLM] Structured data extracted successfully.")
        return data
    except json.JSONDecodeError:
        print("  [LLM] Initial parse failed — attempting JSON repair.")
        try:
            data = json.loads(repair_json(raw_response))
            print("  [LLM] JSON repaired and parsed successfully.")
            return data
        except json.JSONDecodeError as e:
            print(f"  [WARN] JSON repair failed: {e}. Saving raw response.")
            return {"raw_llm_response": raw_response, "parse_error": str(e)}
EOF

cat > app/validation.py << 'EOF'
"""
validation.py — business rule checks on extracted license data.
Pure Python, no I/O, fully unit-testable.
"""
from datetime import datetime


def check_expiration(expiration_date_str: str | None) -> dict:
    if not expiration_date_str:
        return {"status": "unknown", "days_remaining": None,
                "reason": "No expiration date found in extracted data."}
    try:
        exp_date = datetime.strptime(expiration_date_str, "%Y-%m-%d").date()
        today    = datetime.today().date()
        delta    = (exp_date - today).days

        if delta < 0:
            return {"status": "expired",       "days_remaining": delta,
                    "reason": f"Expired {abs(delta)} days ago."}
        elif delta < 30:
            return {"status": "expiring_soon", "days_remaining": delta,
                    "reason": f"Expires in {delta} days — renewal recommended."}
        else:
            return {"status": "valid",         "days_remaining": delta,
                    "reason": f"Valid for {delta} more days."}
    except ValueError:
        return {"status": "error", "days_remaining": None,
                "reason": f"Could not parse date '{expiration_date_str}'. Expected YYYY-MM-DD."}
EOF

cat > app/pipeline.py << 'EOF'
"""
pipeline.py — orchestrates OCR → LLM → validation → save.
Only module that touches the file system.
"""
import json
import os
from datetime import datetime
from pathlib import Path

from app.config import ALLOWED_EXTENSIONS, INPUT_FOLDER, OUTPUT_FOLDER
from app.llm import extract_structured_data
from app.ocr import extract_text_from_image
from app.validation import check_expiration


def process_license(image_path: str) -> dict:
    print(f"\n[Processing] {image_path}")
    raw_text     = extract_text_from_image(image_path)
    structured   = extract_structured_data(raw_text)
    expiration   = check_expiration(structured.get("expiration_date"))
    return {
        "source_file":      image_path,
        "processed_at":     datetime.now().isoformat(),
        "extracted_fields": structured,
        "validation":       expiration,
    }


def save_result(filename: str, result: dict) -> None:
    Path(OUTPUT_FOLDER).mkdir(parents=True, exist_ok=True)
    out_path = os.path.join(OUTPUT_FOLDER, f"{Path(filename).stem}.json")
    with open(out_path, "w", encoding="utf-8") as f:
        json.dump(result, f, indent=2, ensure_ascii=False)
    print(f"  [SAVED] → {out_path}")


def run_pipeline() -> None:
    image_files = [f for f in Path(INPUT_FOLDER).iterdir()
                   if f.suffix.lower() in ALLOWED_EXTENSIONS]
    if not image_files:
        print(f"[Pipeline] No images found in '{INPUT_FOLDER}'. Exiting.")
        return

    print(f"[Pipeline] Found {len(image_files)} image(s) to process.")
    success_count = error_count = 0

    for image_path in image_files:
        try:
            result = process_license(str(image_path))
            save_result(image_path.name, result)
            success_count += 1
        except Exception as e:
            print(f"  [ERROR] Failed to process {image_path.name}: {e}")
            save_result(image_path.name, {
                "source_file": str(image_path),
                "processed_at": datetime.now().isoformat(),
                "error": str(e),
            })
            error_count += 1

    print(f"\n[Pipeline] Complete. {success_count} succeeded, {error_count} failed.")
EOF

# ===========================================================================
# api/
# ===========================================================================

cat > api/__init__.py << 'EOF'
# Marks api/ as a Python package.
EOF

cat > api/schemas.py << 'EOF'
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
EOF

cat > api/endpoints.py << 'EOF'
"""
endpoints.py — route handlers for the OCR pipeline API.
"""
import json
import os
import tempfile
from pathlib import Path
from typing import List

from fastapi import APIRouter, File, HTTPException, UploadFile

from app.config import ALLOWED_EXTENSIONS, OUTPUT_FOLDER
from app.pipeline import process_license, save_result
from api.schemas import BulkUploadResult, ErrorResponse, LicenseResult, ResultSummary

router = APIRouter()


@router.post("/upload", response_model=LicenseResult,
             summary="Upload a single license image")
async def upload_license(file: UploadFile = File(...)):
    suffix = Path(file.filename).suffix.lower()
    if suffix not in ALLOWED_EXTENSIONS:
        raise HTTPException(status_code=400,
            detail=f"File type '{suffix}' not supported. Allowed: {', '.join(sorted(ALLOWED_EXTENSIONS))}")

    tmp = tempfile.NamedTemporaryFile(delete=False, suffix=suffix)
    try:
        tmp.write(await file.read()); tmp.flush(); tmp.close()
        try:
            result = process_license(tmp.name)
        except Exception as e:
            raise HTTPException(status_code=500, detail=f"Pipeline error: {str(e)}")
        save_result(file.filename, result)
        return result
    finally:
        os.unlink(tmp.name)


@router.post("/upload/bulk", response_model=BulkUploadResult,
             summary="Upload multiple license images at once")
async def upload_bulk(files: List[UploadFile] = File(...)):
    if not files:
        raise HTTPException(status_code=400, detail="No files provided.")
    if len(files) > 50:
        raise HTTPException(status_code=400, detail="Maximum batch size is 50 files.")

    results = []; errors = []; skipped = []

    for file in files:
        suffix = Path(file.filename).suffix.lower()
        if suffix not in ALLOWED_EXTENSIONS:
            skipped.append({"filename": file.filename, "reason": f"Unsupported type '{suffix}'"})
            continue
        tmp = tempfile.NamedTemporaryFile(delete=False, suffix=suffix)
        try:
            tmp.write(await file.read()); tmp.flush(); tmp.close()
            result = process_license(tmp.name)
            save_result(file.filename, result)
            result["filename"] = file.filename
            results.append(result)
        except Exception as e:
            print(f"  [BULK ERROR] {file.filename}: {e}")
            errors.append({"filename": file.filename, "error": str(e)})
        finally:
            os.unlink(tmp.name)

    return BulkUploadResult(total=len(files), succeeded=len(results),
        failed=len(errors), skipped=len(skipped),
        results=results, errors=errors, skipped_files=skipped)


@router.get("/results", response_model=List[ResultSummary], summary="List all results")
async def list_results():
    output_path = Path(OUTPUT_FOLDER)
    if not output_path.exists():
        return []
    summaries = []
    for json_file in sorted(output_path.glob("*.json"), reverse=True):
        try:
            with open(json_file, encoding="utf-8") as f:
                data = json.load(f)
            summaries.append(ResultSummary(
                filename=json_file.name,
                processed_at=data.get("processed_at"),
                status=data.get("validation", {}).get("status"),
                full_name=data.get("extracted_fields", {}).get("full_name"),
            ))
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
EOF

cat > api/main.py << 'EOF'
"""
api/main.py — FastAPI application entry point.

Run with:
  uvicorn api.main:app --reload --host 0.0.0.0 --port 8000

Docs:
  http://localhost:8000/docs
"""
from pathlib import Path
from fastapi import FastAPI
from fastapi.middleware.cors import CORSMiddleware
from fastapi.staticfiles import StaticFiles
from api.endpoints import router
from app.config import INPUT_FOLDER, OUTPUT_FOLDER

app = FastAPI(
    title="OCR License Pipeline API",
    description="Extracts structured data from driver's license images using EasyOCR + Ollama.",
    version="0.1.0",
)

app.add_middleware(CORSMiddleware, allow_origins=["*"],
    allow_credentials=True, allow_methods=["*"], allow_headers=["*"])

app.include_router(router, prefix="/api", tags=["pipeline"])

static_dir = Path(__file__).parent.parent / "static"
if static_dir.exists():
    app.mount("/", StaticFiles(directory=str(static_dir), html=True), name="static")


@app.on_event("startup")
async def create_directories():
    Path(INPUT_FOLDER).mkdir(parents=True, exist_ok=True)
    Path(OUTPUT_FOLDER).mkdir(parents=True, exist_ok=True)
    print(f"[API] Input folder:  {INPUT_FOLDER}")
    print(f"[API] Output folder: {OUTPUT_FOLDER}")
    print("[API] Ready. Docs at http://localhost:8000/docs")
EOF

# ===========================================================================
# main.py
# ===========================================================================

cat > main.py << 'EOF'
"""
main.py — CLI entry point.
Run with: python main.py
"""
from app.pipeline import run_pipeline

if __name__ == "__main__":
    run_pipeline()
EOF

# ===========================================================================
# static/index.html
# ===========================================================================

cat > static/index.html << 'HTMLEOF'
<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8" />
  <meta name="viewport" content="width=device-width, initial-scale=1.0" />
  <title>OCR License Pipeline</title>
  <style>
    *, *::before, *::after { box-sizing: border-box; margin: 0; padding: 0; }
    body { font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif; background: #0f1117; color: #e2e8f0; min-height: 100vh; display: flex; flex-direction: column; align-items: center; padding: 40px 16px; }
    .container { width: 100%; max-width: 800px; display: flex; flex-direction: column; gap: 28px; }
    header h1 { font-size: 1.6rem; font-weight: 700; color: #f8fafc; }
    header p  { margin-top: 6px; font-size: 0.9rem; color: #94a3b8; }
    .upload-zone { border: 2px dashed #334155; border-radius: 12px; padding: 48px 24px; text-align: center; cursor: pointer; transition: border-color 0.2s, background 0.2s; }
    .upload-zone:hover, .upload-zone.drag-over { border-color: #6366f1; background: #1e1b4b22; }
    .upload-zone .icon { font-size: 2.5rem; margin-bottom: 12px; }
    .upload-zone p { color: #94a3b8; font-size: 0.9rem; }
    .upload-zone strong { color: #6366f1; }
    .upload-zone .hint { margin-top: 8px; font-size: 0.78rem; color: #475569; }
    #file-input { display: none; }
    .btn { display: inline-flex; align-items: center; gap: 8px; padding: 10px 20px; border-radius: 8px; border: none; font-size: 0.88rem; font-weight: 600; cursor: pointer; transition: opacity 0.15s; }
    .btn:disabled { opacity: 0.4; cursor: not-allowed; }
    .btn-primary { background: #6366f1; color: #fff; }
    .btn-primary:hover:not(:disabled) { background: #4f46e5; }
    .btn-ghost { background: #1e293b; color: #94a3b8; }
    .btn-ghost:hover:not(:disabled) { background: #273449; }
    .action-bar { display: none; align-items: center; justify-content: space-between; flex-wrap: wrap; gap: 10px; }
    .action-bar.visible { display: flex; }
    .queued-label { font-size: 0.85rem; color: #94a3b8; }
    .queued-label span { color: #e2e8f0; font-weight: 600; }
    .queue-section { display: none; flex-direction: column; gap: 8px; }
    .queue-section.visible { display: flex; }
    .section-title { font-size: 0.72rem; font-weight: 700; text-transform: uppercase; letter-spacing: 0.08em; color: #475569; margin-bottom: 4px; }
    .queue-item { display: flex; align-items: center; gap: 12px; padding: 12px 16px; background: #1e293b; border-radius: 8px; font-size: 0.88rem; }
    .queue-item .qi-icon { font-size: 1.1rem; flex-shrink: 0; width: 24px; text-align: center; }
    .queue-item .qi-name { flex: 1; color: #e2e8f0; font-weight: 500; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
    .mini-spinner { width: 16px; height: 16px; border: 2px solid #334155; border-top-color: #6366f1; border-radius: 50%; animation: spin 0.8s linear infinite; flex-shrink: 0; }
    @keyframes spin { to { transform: rotate(360deg); } }
    .badge { padding: 3px 10px; border-radius: 99px; font-size: 0.72rem; font-weight: 700; text-transform: uppercase; letter-spacing: 0.05em; }
    .badge.waiting       { background: #1e293b;  color: #475569; border: 1px solid #334155; }
    .badge.processing    { background: #1e1b4b;  color: #a5b4fc; }
    .badge.valid         { background: #14532d;  color: #86efac; }
    .badge.expiring_soon { background: #713f12;  color: #fcd34d; }
    .badge.expired       { background: #7f1d1d;  color: #fca5a5; }
    .badge.unknown       { background: #1e3a5f;  color: #93c5fd; }
    .badge.error         { background: #450a0a;  color: #fca5a5; }
    .badge.skipped       { background: #292524;  color: #78716c; }
    .summary-bar { display: none; padding: 16px 20px; background: #1e293b; border-radius: 10px; gap: 24px; flex-wrap: wrap; align-items: center; }
    .summary-bar.visible { display: flex; }
    .summary-stat { display: flex; flex-direction: column; gap: 2px; }
    .summary-stat .num { font-size: 1.5rem; font-weight: 700; color: #f1f5f9; }
    .summary-stat .lbl { font-size: 0.72rem; color: #64748b; text-transform: uppercase; letter-spacing: 0.06em; }
    .summary-stat .num.green  { color: #86efac; }
    .summary-stat .num.red    { color: #fca5a5; }
    .summary-stat .num.yellow { color: #fcd34d; }
    .result-card { display: none; flex-direction: column; background: #1e293b; border-radius: 12px; overflow: hidden; }
    .result-card.visible { display: flex; }
    .result-header { padding: 16px 20px; display: flex; align-items: center; justify-content: space-between; }
    .result-header.valid         { background: #14532d; }
    .result-header.expiring_soon { background: #713f12; }
    .result-header.expired       { background: #7f1d1d; }
    .result-header.unknown, .result-header.error { background: #1e3a5f; }
    .result-header .status-text { font-weight: 700; font-size: 1rem; text-transform: uppercase; letter-spacing: 0.05em; }
    .result-header .days { font-size: 0.85rem; opacity: 0.8; }
    .result-body { padding: 20px; display: flex; flex-direction: column; gap: 12px; }
    .field-row { display: flex; justify-content: space-between; align-items: baseline; padding: 8px 0; border-bottom: 1px solid #334155; font-size: 0.9rem; }
    .field-row:last-child { border-bottom: none; }
    .field-label { color: #64748b; text-transform: uppercase; letter-spacing: 0.06em; font-size: 0.75rem; font-weight: 600; }
    .field-value { color: #f1f5f9; font-weight: 500; }
    .field-value.null-value { color: #475569; font-style: italic; }
    .reason { padding: 12px 16px; background: #0f172a; border-radius: 6px; font-size: 0.85rem; color: #94a3b8; }
    .error-card { display: none; padding: 16px 20px; background: #7f1d1d33; border: 1px solid #7f1d1d; border-radius: 8px; color: #fca5a5; font-size: 0.9rem; }
    .error-card.visible { display: block; }
    .history-list { display: flex; flex-direction: column; gap: 8px; }
    .history-item { display: flex; justify-content: space-between; align-items: center; padding: 12px 16px; background: #1e293b; border-radius: 8px; cursor: pointer; transition: background 0.15s; font-size: 0.88rem; }
    .history-item:hover { background: #273449; }
    .history-item .name { font-weight: 600; color: #e2e8f0; }
    .history-item .meta { font-size: 0.78rem; color: #64748b; }
  </style>
</head>
<body>
<div class="container">
  <header>
    <h1>🪪 OCR License Pipeline</h1>
    <p>Upload one or more driver's license images to extract and validate their data.</p>
  </header>
  <div class="upload-zone" id="upload-zone">
    <div class="icon">📂</div>
    <p><strong>Click to browse</strong> or drag and drop images here</p>
    <p class="hint">PNG, JPG, JPEG, BMP, TIFF · Single file or bulk upload</p>
    <input type="file" id="file-input" accept=".png,.jpg,.jpeg,.bmp,.tiff" multiple />
  </div>
  <div class="action-bar" id="action-bar">
    <p class="queued-label"><span id="queued-count">0</span> file(s) selected</p>
    <div style="display:flex;gap:8px">
      <button class="btn btn-ghost" onclick="clearQueue()">Clear</button>
      <button class="btn btn-primary" id="process-btn" onclick="processQueue()">Process All</button>
    </div>
  </div>
  <div class="queue-section" id="queue-section">
    <p class="section-title">Upload queue</p>
    <div id="queue-list"></div>
  </div>
  <div class="summary-bar" id="summary-bar">
    <div class="summary-stat"><span class="num" id="sum-total">0</span><span class="lbl">Total</span></div>
    <div class="summary-stat"><span class="num green" id="sum-ok">0</span><span class="lbl">Succeeded</span></div>
    <div class="summary-stat"><span class="num red" id="sum-fail">0</span><span class="lbl">Failed</span></div>
    <div class="summary-stat"><span class="num yellow" id="sum-skip">0</span><span class="lbl">Skipped</span></div>
  </div>
  <div class="error-card" id="error-card"></div>
  <div class="result-card" id="result-card">
    <div class="result-header" id="result-header">
      <span class="status-text" id="result-status"></span>
      <span class="days" id="result-days"></span>
    </div>
    <div class="result-body">
      <div id="fields-container"></div>
      <div class="reason" id="result-reason"></div>
    </div>
  </div>
  <div>
    <p class="section-title" style="margin-bottom:12px;">Previously processed</p>
    <div class="history-list" id="history-list"><p style="color:#475569;font-size:0.85rem;">Loading...</p></div>
  </div>
</div>
<script>
let queuedFiles = [];
const uploadZone = document.getElementById("upload-zone");
const fileInput  = document.getElementById("file-input");
uploadZone.addEventListener("click", () => fileInput.click());
fileInput.addEventListener("change", () => { if (fileInput.files.length) addFilesToQueue([...fileInput.files]); fileInput.value = ""; });
uploadZone.addEventListener("dragover",  e => { e.preventDefault(); uploadZone.classList.add("drag-over"); });
uploadZone.addEventListener("dragleave", () => uploadZone.classList.remove("drag-over"));
uploadZone.addEventListener("drop", e => { e.preventDefault(); uploadZone.classList.remove("drag-over"); if (e.dataTransfer.files.length) addFilesToQueue([...e.dataTransfer.files]); });
function addFilesToQueue(files) {
  const existing = new Set(queuedFiles.map(f => f.name + f.size));
  queuedFiles.push(...files.filter(f => !existing.has(f.name + f.size)));
  renderQueue();
  showEl("action-bar"); showEl("queue-section");
  document.getElementById("queued-count").textContent = queuedFiles.length;
}
function clearQueue() { queuedFiles = []; hide("action-bar"); hide("queue-section"); hide("summary-bar"); document.getElementById("queue-list").innerHTML = ""; }
function renderQueue() {
  document.getElementById("queue-list").innerHTML = queuedFiles.map((f, i) => `
    <div class="queue-item" id="qi-${i}">
      <span class="qi-icon">🖼️</span>
      <span class="qi-name" title="${f.name}">${f.name}</span>
      <span class="qi-badge"><span class="badge waiting">Waiting</span></span>
    </div>`).join("");
}
async function processQueue() {
  if (!queuedFiles.length) return;
  document.getElementById("process-btn").disabled = true;
  hide("result-card"); hide("error-card"); hide("summary-bar");
  queuedFiles.length === 1 ? await processSingle(queuedFiles[0], 0) : await processBulk();
  document.getElementById("process-btn").disabled = false;
  loadHistory();
}
async function processSingle(file, index) {
  setQueueItemState(index, "processing");
  const fd = new FormData(); fd.append("file", file);
  try {
    const res = await fetch("/api/upload", { method: "POST", body: fd });
    const data = await res.json();
    if (!res.ok) { setQueueItemState(index, "error", data.detail); showError(data.detail); return; }
    setQueueItemState(index, data.validation?.status || "unknown");
    renderResult(data);
  } catch { setQueueItemState(index, "error", "Network error"); showError("Could not connect to the API."); }
}
async function processBulk() {
  queuedFiles.forEach((_, i) => setQueueItemState(i, "processing"));
  const fd = new FormData(); queuedFiles.forEach(f => fd.append("files", f));
  try {
    const res = await fetch("/api/upload/bulk", { method: "POST", body: fd });
    const data = await res.json();
    if (!res.ok) { queuedFiles.forEach((_, i) => setQueueItemState(i, "error")); showError(data.detail); return; }
    const rm = {}; const em = {}; const sm = {};
    (data.results||[]).forEach(r => rm[r.filename] = r);
    (data.errors||[]).forEach(e => em[e.filename] = e.error);
    (data.skipped_files||[]).forEach(s => sm[s.filename] = s.reason);
    queuedFiles.forEach((f, i) => {
      if      (rm[f.name]) setQueueItemState(i, rm[f.name].validation?.status || "unknown");
      else if (em[f.name]) setQueueItemState(i, "error",   em[f.name]);
      else if (sm[f.name]) setQueueItemState(i, "skipped", sm[f.name]);
      else                 setQueueItemState(i, "unknown");
    });
    document.getElementById("sum-total").textContent = data.total;
    document.getElementById("sum-ok").textContent    = data.succeeded;
    document.getElementById("sum-fail").textContent  = data.failed;
    document.getElementById("sum-skip").textContent  = data.skipped;
    showEl("summary-bar");
    if (data.results?.length) renderResult(data.results[0]);
  } catch { queuedFiles.forEach((_, i) => setQueueItemState(i, "error")); showError("Could not connect to the API."); }
}
function setQueueItemState(index, status, tooltip) {
  const item = document.getElementById(`qi-${index}`); if (!item) return;
  const badgeWrap = item.querySelector(".qi-badge"); const iconEl = item.querySelector(".qi-icon");
  if (status === "processing") { iconEl.innerHTML = ""; const s = document.createElement("div"); s.className = "mini-spinner"; iconEl.appendChild(s); badgeWrap.innerHTML = `<span class="badge processing">Processing…</span>`; return; }
  iconEl.innerHTML = "🖼️";
  const labels = { valid:"Valid", expiring_soon:"Expiring Soon", expired:"Expired", unknown:"Unknown", error:"Error", skipped:"Skipped" };
  badgeWrap.innerHTML = `<span class="badge ${status}"${tooltip ? ` title="${tooltip}"` : ""}>${labels[status]||status}</span>`;
}
function renderResult(data) {
  const v = data.validation||{}; const f = data.extracted_fields||{}; const s = v.status||"unknown";
  document.getElementById("result-header").className = `result-header ${s}`;
  document.getElementById("result-status").textContent = statusLabel(s);
  document.getElementById("result-days").textContent   = v.days_remaining != null ? `${v.days_remaining} days` : "";
  document.getElementById("result-reason").textContent = v.reason || "";
  document.getElementById("fields-container").innerHTML = [
    ["Full Name","full_name"],["License Number","license_number"],
    ["Date of Birth","date_of_birth"],["Expiration Date","expiration_date"],["Class","class"]
  ].map(([label, key]) => {
    const val = f[key]; const cls = val != null ? "field-value" : "field-value null-value";
    return `<div class="field-row"><span class="field-label">${label}</span><span class="${cls}">${val??'—'}</span></div>`;
  }).join("");
  showEl("result-card");
}
async function loadHistory() {
  try {
    const items = await (await fetch("/api/results")).json();
    const list = document.getElementById("history-list");
    if (!items.length) { list.innerHTML = '<p style="color:#475569;font-size:0.85rem;">No results yet.</p>'; return; }
    list.innerHTML = items.map(item => `
      <div class="history-item" onclick="loadResult('${item.filename}')">
        <div><div class="name">${item.filename.replace(".json","")}</div>
        <div class="meta">${item.full_name||"Name not found"} · ${item.processed_at?item.processed_at.split("T")[0]:"—"}</div></div>
        <span class="badge ${item.status||"unknown"}">${statusLabel(item.status)}</span>
      </div>`).join("");
  } catch { document.getElementById("history-list").innerHTML = '<p style="color:#475569;font-size:0.85rem;">Could not load history.</p>'; }
}
async function loadResult(filename) {
  hide("result-card"); hide("error-card");
  try { const res = await fetch(`/api/results/${filename}`); const data = await res.json(); res.ok ? renderResult(data) : showError(data.detail); }
  catch { showError("Could not connect to the API."); }
}
function showEl(id) { document.getElementById(id).classList.add("visible"); }
function hide(id)   { document.getElementById(id).classList.remove("visible"); }
function showError(msg) { const el = document.getElementById("error-card"); el.textContent = msg; el.classList.add("visible"); }
function statusLabel(s) { return {valid:"Valid",expiring_soon:"Expiring Soon",expired:"Expired",unknown:"Unknown",error:"Error",skipped:"Skipped"}[s]||s||"—"; }
loadHistory();
</script>
</body>
</html>
HTMLEOF

# ===========================================================================
# tests/
# ===========================================================================

cat > tests/__init__.py << 'EOF'
# Marks tests/ as a Python package.
EOF

cat > tests/test_validation.py << 'EOF'
from datetime import date, timedelta
import pytest
from app.validation import check_expiration

def days_from_today(n):
    return (date.today() + timedelta(days=n)).isoformat()

def test_valid():             assert check_expiration(days_from_today(100))["status"] == "valid"
def test_expiring_soon():     assert check_expiration(days_from_today(15))["status"]  == "expiring_soon"
def test_expired():           assert check_expiration(days_from_today(-1))["status"]  == "expired"
def test_none_unknown():      assert check_expiration(None)["status"]                 == "unknown"
def test_empty_unknown():     assert check_expiration("")["status"]                   == "unknown"
def test_bad_format_error():  assert check_expiration("03/15/2027")["status"]         == "error"
def test_boundary_30_valid(): assert check_expiration(days_from_today(30))["status"]  == "valid"
def test_boundary_29_soon():  assert check_expiration(days_from_today(29))["status"]  == "expiring_soon"
def test_days_remaining():    assert check_expiration(days_from_today(50))["days_remaining"] == 50
def test_negative_days():     assert check_expiration(days_from_today(-10))["days_remaining"] == -10

EXPECTED_KEYS = {"status", "days_remaining", "reason"}
@pytest.mark.parametrize("d", [days_from_today(100), days_from_today(15),
                                days_from_today(-10), None, "bad"])
def test_always_has_keys(d):
    assert set(check_expiration(d).keys()) == EXPECTED_KEYS
EOF

cat > tests/test_llm.py << 'EOF'
import json
from unittest.mock import MagicMock, patch
from app.llm import extract_structured_data, repair_json


def test_repair_json_adds_missing_brace():
    incomplete = '{"full_name": "John", "license_number": "D123"'
    result = repair_json(incomplete)
    parsed = json.loads(result)
    assert parsed["full_name"] == "John"

def test_repair_json_no_change_needed():
    complete = '{"full_name": "John"}'
    assert repair_json(complete) == complete

def make_mock_response(content):
    mock_resp = MagicMock()
    mock_resp.json.return_value = {"message": {"content": content}}
    mock_resp.raise_for_status = MagicMock()
    return mock_resp

@patch("app.llm.requests.post")
def test_successful_extraction(mock_post):
    mock_post.return_value = make_mock_response(
        '{"full_name": "Jane Doe", "license_number": "X999", '
        '"date_of_birth": "1990-01-01", "expiration_date": "2027-06-01", "class": "B"}'
    )
    result = extract_structured_data("some OCR text")
    assert result["full_name"] == "Jane Doe"
    assert result["expiration_date"] == "2027-06-01"

@patch("app.llm.requests.post")
def test_truncated_json_repaired(mock_post):
    mock_post.return_value = make_mock_response(
        '{"full_name": "Ana Rojas", "expiration_date": "2034-12-19", "class": "C"'
    )
    result = extract_structured_data("some OCR text")
    assert result["full_name"] == "Ana Rojas"
    assert "parse_error" not in result

@patch("app.llm.requests.post")
def test_null_fields_returned(mock_post):
    mock_post.return_value = make_mock_response(
        '{"full_name": null, "license_number": null, '
        '"date_of_birth": null, "expiration_date": null, "class": null}'
    )
    result = extract_structured_data("unreadable text")
    assert result["full_name"] is None
EOF

cat > tests/test_pipeline.py << 'EOF'
import json
from pathlib import Path
from unittest.mock import patch
from app.pipeline import process_license, run_pipeline


MOCK_RESULT = {
    "extracted_fields": {
        "full_name": "Test User", "license_number": "T123",
        "date_of_birth": "1990-01-01", "expiration_date": "2030-01-01", "class": "C"
    },
    "validation": {"status": "valid", "days_remaining": 1000, "reason": "Valid."},
}


@patch("app.pipeline.extract_structured_data", return_value=MOCK_RESULT["extracted_fields"])
@patch("app.pipeline.extract_text_from_image", return_value="mock ocr text")
def test_process_license(mock_ocr, mock_llm):
    result = process_license("fake/path/license.png")
    assert result["extracted_fields"]["full_name"] == "Test User"
    assert "processed_at" in result
    assert "validation" in result


@patch("app.pipeline.extract_structured_data", return_value=MOCK_RESULT["extracted_fields"])
@patch("app.pipeline.extract_text_from_image", return_value="mock ocr text")
def test_run_pipeline_saves_results(mock_ocr, mock_llm, tmp_path, monkeypatch):
    input_dir  = tmp_path / "licenses"
    output_dir = tmp_path / "results"
    input_dir.mkdir(); output_dir.mkdir()
    (input_dir / "test.png").write_bytes(b"fake image data")

    monkeypatch.setattr("app.pipeline.INPUT_FOLDER",  str(input_dir))
    monkeypatch.setattr("app.pipeline.OUTPUT_FOLDER", str(output_dir))

    run_pipeline()

    result_files = list(output_dir.glob("*.json"))
    assert len(result_files) == 1
    data = json.loads(result_files[0].read_text())
    assert data["extracted_fields"]["full_name"] == "Test User"
EOF

# ===========================================================================
# requirements.txt
# ===========================================================================

cat > requirements.txt << 'EOF'
easyocr
requests
python-dotenv
fastapi
uvicorn[standard]
python-multipart
pytest
pytest-asyncio
ruff
EOF

# ===========================================================================
# .env.example
# ===========================================================================

cat > .env.example << 'EOF'
# Copy to .env and fill in values.
# .env is gitignored — never commit real credentials.

INPUT_FOLDER=licenses/
OUTPUT_FOLDER=results/

OLLAMA_URL=http://host.docker.internal:11434/api/chat
OLLAMA_MODEL=llama3.2
OLLAMA_TIMEOUT=60

USE_GPU=true
EOF

# ===========================================================================
# .gitignore
# ===========================================================================

cat > .gitignore << 'EOF'
# Python
venv/
__pycache__/
*.pyc
*.pyo
.pytest_cache/
.ruff_cache/
*.egg-info/

# Secrets
.env
*.tfvars

# Pipeline data (may contain PII)
licenses/
results/

# Terraform
**/.terraform/
*.tfstate
*.tfstate.backup
.terraform.lock.hcl
crash.log

# IDE / OS
.vscode/
.idea/
.DS_Store
*.swp
EOF

# ===========================================================================
# Dockerfile
# ===========================================================================

cat > Dockerfile << 'EOF'
# =============================================================================
# Dockerfile — GPU-enabled (CUDA 12.4 + cuDNN)
# =============================================================================
FROM nvidia/cuda:12.4.1-cudnn-runtime-ubuntu22.04

ENV DEBIAN_FRONTEND=noninteractive
ENV TZ=UTC

RUN apt-get update && apt-get install -y \
    python3.11 python3.11-dev python3-pip \
    libgl1 libglib2.0-0 curl \
    && rm -rf /var/lib/apt/lists/*

RUN update-alternatives --install /usr/bin/python python /usr/bin/python3.11 1 \
 && update-alternatives --install /usr/bin/pip    pip    /usr/bin/pip3       1

WORKDIR /app

COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY . .
RUN mkdir -p licenses results
RUN useradd --create-home appuser && chown -R appuser:appuser /app
USER appuser

CMD ["python", "main.py"]
EOF

# ===========================================================================
# docker-compose.yml
# ===========================================================================

cat > docker-compose.yml << 'EOF'
services:
  api:
    build: .
    container_name: ocrpipeline_api
    command: uvicorn api.main:app --host 0.0.0.0 --port 8000 --reload
    ports:
      - "8000:8000"
    environment:
      - OLLAMA_URL=http://host.docker.internal:11434/api/chat
      - OLLAMA_MODEL=llama3.2
      - OLLAMA_TIMEOUT=60
      - USE_GPU=true
      - INPUT_FOLDER=licenses/
      - OUTPUT_FOLDER=results/
    extra_hosts:
      - "host.docker.internal:host-gateway"
    deploy:
      resources:
        reservations:
          devices:
            - driver: nvidia
              count: 1
              capabilities: [gpu]
    volumes:
      - .:/app
      - ./licenses:/app/licenses
      - ./results:/app/results
    restart: unless-stopped
    healthcheck:
      test: ["CMD", "curl", "-f", "http://localhost:8000/api/health"]
      interval: 10s
      timeout: 5s
      retries: 3
      start_period: 15s

  pipeline:
    build: .
    container_name: ocrpipeline_batch
    command: python main.py
    environment:
      - OLLAMA_URL=http://host.docker.internal:11434/api/chat
      - OLLAMA_MODEL=llama3.2
      - OLLAMA_TIMEOUT=60
      - USE_GPU=true
      - INPUT_FOLDER=licenses/
      - OUTPUT_FOLDER=results/
    extra_hosts:
      - "host.docker.internal:host-gateway"
    deploy:
      resources:
        reservations:
          devices:
            - driver: nvidia
              count: 1
              capabilities: [gpu]
    volumes:
      - ./licenses:/app/licenses
      - ./results:/app/results
    restart: "no"
EOF

# ===========================================================================
# .github/workflows/ci.yml
# ===========================================================================

cat > .github/workflows/ci.yml << 'EOF'
name: CI

on:
  push:
    branches: ["**"]
  pull_request:
    branches: [main]

jobs:
  lint:
    name: Lint (ruff)
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: actions/setup-python@v5
        with: { python-version: "3.11" }
      - run: pip install ruff
      - run: ruff check .

  test:
    name: Test (pytest)
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: actions/setup-python@v5
        with: { python-version: "3.11" }
      - uses: actions/cache@v4
        with:
          path: ~/.cache/pip
          key: ${{ runner.os }}-pip-${{ hashFiles('requirements.txt') }}
      - run: pip install -r requirements.txt
      - run: pytest -v --tb=short

  docker:
    name: Docker build
    runs-on: ubuntu-latest
    needs: [lint, test]
    steps:
      - uses: actions/checkout@v4
      - uses: docker/build-push-action@v5
        with:
          context: .
          push: false
          tags: ocrpipeline:ci
EOF

# ===========================================================================
# .github/workflows/cd.yml
# ===========================================================================

cat > .github/workflows/cd.yml << 'EOF'
name: CD

on:
  push:
    branches: [main]
  workflow_dispatch:

concurrency:
  group: deploy-production
  cancel-in-progress: false

env:
  ECR_REGISTRY:   ${{ secrets.AWS_ACCOUNT_ID }}.dkr.ecr.${{ secrets.AWS_REGION }}.amazonaws.com
  ECR_REPOSITORY: ocrpipeline
  K8S_NAMESPACE:  ocrpipeline
  K8S_DEPLOYMENT: ocrpipeline-api

jobs:
  build-and-push:
    name: Build & push to ECR
    runs-on: ubuntu-latest
    outputs:
      image_tag: ${{ steps.meta.outputs.tag }}
      image_uri: ${{ steps.meta.outputs.uri }}
    steps:
      - uses: actions/checkout@v4
      - name: Compute image tag
        id: meta
        run: |
          SHORT_SHA="${GITHUB_SHA::7}"
          IMAGE_URI="${{ env.ECR_REGISTRY }}/${{ env.ECR_REPOSITORY }}:${SHORT_SHA}"
          echo "tag=${SHORT_SHA}" >> $GITHUB_OUTPUT
          echo "uri=${IMAGE_URI}" >> $GITHUB_OUTPUT
      - uses: aws-actions/configure-aws-credentials@v4
        with:
          aws-access-key-id:     ${{ secrets.AWS_ACCESS_KEY_ID }}
          aws-secret-access-key: ${{ secrets.AWS_SECRET_ACCESS_KEY }}
          aws-region:            ${{ secrets.AWS_REGION }}
      - uses: aws-actions/amazon-ecr-login@v2
      - uses: docker/build-push-action@v5
        with:
          context: .
          push: true
          tags: |
            ${{ steps.meta.outputs.uri }}
            ${{ env.ECR_REGISTRY }}/${{ env.ECR_REPOSITORY }}:latest

  deploy:
    name: Deploy to EKS
    runs-on: ubuntu-latest
    needs: build-and-push
    environment: production
    steps:
      - uses: actions/checkout@v4
      - uses: aws-actions/configure-aws-credentials@v4
        with:
          aws-access-key-id:     ${{ secrets.AWS_ACCESS_KEY_ID }}
          aws-secret-access-key: ${{ secrets.AWS_SECRET_ACCESS_KEY }}
          aws-region:            ${{ secrets.AWS_REGION }}
      - name: Configure kubectl
        run: aws eks update-kubeconfig --region ${{ secrets.AWS_REGION }} --name ${{ secrets.EKS_CLUSTER_NAME }}
      - name: Deploy
        run: |
          kubectl set image deployment/${{ env.K8S_DEPLOYMENT }} \
            api=${{ needs.build-and-push.outputs.image_uri }} \
            --namespace ${{ env.K8S_NAMESPACE }}
          kubectl rollout status deployment/${{ env.K8S_DEPLOYMENT }} \
            --namespace ${{ env.K8S_NAMESPACE }} --timeout=5m
EOF

# ===========================================================================
# k8s/
# ===========================================================================

cat > k8s/namespace.yaml << 'EOF'
apiVersion: v1
kind: Namespace
metadata:
  name: ocrpipeline
  labels:
    app: ocrpipeline
EOF

cat > k8s/configmap.yaml << 'EOF'
apiVersion: v1
kind: ConfigMap
metadata:
  name: ocrpipeline-config
  namespace: ocrpipeline
data:
  OLLAMA_URL:     "http://ollama:11434/api/chat"
  OLLAMA_MODEL:   "llama3.2"
  OLLAMA_TIMEOUT: "60"
  USE_GPU:        "false"
  INPUT_FOLDER:   "/data/licenses"
  OUTPUT_FOLDER:  "/data/results"
EOF

cat > k8s/secret.yaml << 'EOF'
apiVersion: v1
kind: Secret
metadata:
  name: ocrpipeline-secrets
  namespace: ocrpipeline
type: Opaque
data:
  OPENAI_API_KEY: "cGxhY2Vob2xkZXI="
EOF

cat > k8s/ollama/pvc.yaml << 'EOF'
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: ollama-models-pvc
  namespace: ocrpipeline
spec:
  accessModes: [ReadWriteOnce]
  resources:
    requests:
      storage: 20Gi
  storageClassName: standard
EOF

cat > k8s/ollama/deployment.yaml << 'EOF'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: ollama
  namespace: ocrpipeline
spec:
  replicas: 1
  selector:
    matchLabels:
      app: ollama
  strategy:
    type: Recreate
  template:
    metadata:
      labels:
        app: ollama
    spec:
      containers:
        - name: ollama
          image: ollama/ollama:latest
          ports:
            - containerPort: 11434
          volumeMounts:
            - name: ollama-models
              mountPath: /root/.ollama
          resources:
            requests: { memory: "4Gi", cpu: "500m" }
            limits:   { memory: "8Gi", cpu: "2000m" }
          livenessProbe:
            httpGet: { path: /api/tags, port: 11434 }
            initialDelaySeconds: 30
            periodSeconds: 30
          readinessProbe:
            httpGet: { path: /api/tags, port: 11434 }
            initialDelaySeconds: 15
            periodSeconds: 10
      volumes:
        - name: ollama-models
          persistentVolumeClaim:
            claimName: ollama-models-pvc
EOF

cat > k8s/ollama/service.yaml << 'EOF'
apiVersion: v1
kind: Service
metadata:
  name: ollama
  namespace: ocrpipeline
spec:
  type: ClusterIP
  selector:
    app: ollama
  ports:
    - port: 11434
      targetPort: 11434
EOF

cat > k8s/api/deployment.yaml << 'EOF'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: ocrpipeline-api
  namespace: ocrpipeline
spec:
  replicas: 2
  selector:
    matchLabels:
      app: ocrpipeline-api
  strategy:
    type: RollingUpdate
    rollingUpdate: { maxUnavailable: 0, maxSurge: 1 }
  template:
    metadata:
      labels:
        app: ocrpipeline-api
    spec:
      containers:
        - name: api
          image: yourregistry.azurecr.io/ocrpipeline:latest
          command: ["uvicorn", "api.main:app", "--host", "0.0.0.0", "--port", "8000"]
          ports:
            - containerPort: 8000
          envFrom:
            - configMapRef:
                name: ocrpipeline-config
          resources:
            requests: { memory: "512Mi", cpu: "250m" }
            limits:   { memory: "1Gi",   cpu: "1000m" }
          livenessProbe:
            httpGet: { path: /api/health, port: 8000 }
            initialDelaySeconds: 10
            periodSeconds: 15
          readinessProbe:
            httpGet: { path: /api/health, port: 8000 }
            initialDelaySeconds: 5
            periodSeconds: 10
          volumeMounts:
            - name: pipeline-data
              mountPath: /data
      volumes:
        - name: pipeline-data
          persistentVolumeClaim:
            claimName: pipeline-data-pvc
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: pipeline-data-pvc
  namespace: ocrpipeline
spec:
  accessModes: [ReadWriteMany]
  resources:
    requests:
      storage: 10Gi
  storageClassName: standard
EOF

cat > k8s/api/service.yaml << 'EOF'
apiVersion: v1
kind: Service
metadata:
  name: ocrpipeline-api
  namespace: ocrpipeline
spec:
  type: ClusterIP
  selector:
    app: ocrpipeline-api
  ports:
    - port: 80
      targetPort: 8000
EOF

cat > k8s/api/ingress.yaml << 'EOF'
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: ocrpipeline-ingress
  namespace: ocrpipeline
  annotations:
    kubernetes.io/ingress.class: "nginx"
    cert-manager.io/cluster-issuer: "letsencrypt-prod"
    nginx.ingress.kubernetes.io/proxy-body-size: "20m"
    nginx.ingress.kubernetes.io/proxy-read-timeout: "120"
spec:
  tls:
    - hosts: [yourdomain.com]
      secretName: ocrpipeline-tls
  rules:
    - host: yourdomain.com
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: ocrpipeline-api
                port:
                  number: 80
EOF

# ===========================================================================
# terraform/
# ===========================================================================

cat > terraform/main.tf << 'EOF'
terraform {
  required_version = "~> 1.7"
  required_providers {
    aws = { source = "hashicorp/aws", version = "~> 5.0" }
  }
  backend "s3" {
    bucket         = "yourcompany-ocrpipeline-tfstate"
    key            = "ocrpipeline/terraform.tfstate"
    region         = "us-east-1"
    encrypt        = true
    dynamodb_table = "ocrpipeline-tf-locks"
  }
}
provider "aws" {
  region = var.aws_region
  default_tags {
    tags = {
      Project     = "ocrpipeline"
      Environment = var.environment
      ManagedBy   = "terraform"
      Owner       = var.owner_tag
    }
  }
}
EOF

cat > terraform/variables.tf << 'EOF'
variable "aws_region"       { default = "us-east-1" }
variable "environment"      { default = "production" }
variable "owner_tag"        { default = "platform-team" }
variable "vpc_cidr"         { default = "10.0.0.0/16" }
variable "availability_zones"    { default = ["us-east-1a","us-east-1b"] }
variable "private_subnet_cidrs"  { default = ["10.0.1.0/24","10.0.2.0/24"] }
variable "public_subnet_cidrs"   { default = ["10.0.101.0/24","10.0.102.0/24"] }
variable "cluster_name"          { default = "ocrpipeline" }
variable "kubernetes_version"    { default = "1.29" }
variable "node_instance_type"    { default = "t3.medium" }
variable "node_min_count"        { default = 1 }
variable "node_max_count"        { default = 3 }
variable "node_desired_count"    { default = 2 }
variable "ecr_image_retention_count" { default = 10 }
EOF

cat > terraform/outputs.tf << 'EOF'
output "cluster_name"         { value = aws_eks_cluster.main.name }
output "cluster_endpoint"     { value = aws_eks_cluster.main.endpoint }
output "ecr_repository_url"   { value = aws_ecr_repository.app.repository_url }
output "kubectl_config_command" {
  value = "aws eks update-kubeconfig --region ${var.aws_region} --name ${aws_eks_cluster.main.name}"
}
output "docker_login_command" {
  value = "aws ecr get-login-password --region ${var.aws_region} | docker login --username AWS --password-stdin ${aws_ecr_repository.app.repository_url}"
}
EOF

cat > terraform/terraform.tfvars.example << 'EOF'
aws_region         = "us-east-1"
environment        = "production"
owner_tag          = "your-name"
cluster_name       = "ocrpipeline"
kubernetes_version = "1.29"
node_instance_type = "t3.medium"
node_min_count     = 1
node_max_count     = 3
node_desired_count = 2
ecr_image_retention_count = 10
EOF

# vpc.tf, eks.tf, ecr.tf are infrastructure-specific —
# they reference each other so we keep them as stubs here.
# The full versions are in the conversation history above.
touch terraform/vpc.tf terraform/eks.tf terraform/ecr.tf

# ===========================================================================
# ansible/
# ===========================================================================

cat > ansible/ansible.cfg << 'EOF'
[defaults]
inventory         = inventory.ini
remote_user       = ubuntu
private_key_file  = ~/.ssh/id_rsa
roles_path        = roles
forks             = 10
nocows            = true
retry_files_enabled = false

[ssh_connection]
pipelining = true
ssh_args   = -o ControlMaster=auto -o ControlPersist=60s -o StrictHostKeyChecking=no

[privilege_escalation]
become_method   = sudo
become_ask_pass = false
EOF

cat > ansible/inventory.ini << 'EOF'
[dev]
localhost ansible_connection=local

[bastion]
# bastion ansible_host=1.2.3.4 ansible_user=ec2-user

[ci_runners]
# runner1 ansible_host=10.0.1.10 ansible_user=ubuntu

[all:vars]
ansible_python_interpreter=auto_silent
EOF

cat > ansible/group_vars/all.yml << 'EOF'
system_timezone: "UTC"
system_packages: [curl, git, vim, htop, unzip, jq]
docker_version:  "24.0"
docker_users:    ["{{ ansible_user }}"]
ollama_version:  "latest"
ollama_model:    "llama3.2"
ollama_service_port: 11434
EOF

cat > ansible/site.yml << 'EOF'
---
- name: Baseline configuration
  hosts: all
  become: true
  roles:
    - role: common
      tags: [common]

- name: Install Docker
  hosts: dev:ci_runners
  become: true
  roles:
    - role: docker
      tags: [docker]

- name: Install Ollama
  hosts: dev
  become: true
  roles:
    - role: ollama
      tags: [ollama]
EOF

touch ansible/roles/common/tasks/main.yml \
      ansible/roles/common/handlers/main.yml \
      ansible/roles/docker/tasks/main.yml \
      ansible/roles/docker/handlers/main.yml \
      ansible/roles/ollama/tasks/main.yml \
      ansible/roles/ollama/handlers/main.yml

# ===========================================================================
# scripts/
# ===========================================================================

cat > scripts/check.sh << 'SCRIPTEOF'
#!/usr/bin/env bash
set -euo pipefail
GREEN='\033[0;32m'; RED='\033[0;31m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
PASS=0; FAIL=0
ok()   { echo -e "  ${GREEN}✓${NC}  $1"; ((PASS++)); }
fail() { echo -e "  ${RED}✗${NC}  $1"; ((FAIL++)); }
info() { echo -e "  ${BLUE}→${NC}  $1"; }
echo ""; echo "========================================"; echo "  OCR Pipeline — Pre-flight check"; echo "========================================"; echo ""
echo "[ Tools ]"
command -v docker &>/dev/null && ok "docker found" || fail "docker not found"
docker compose version &>/dev/null && ok "docker compose found" || fail "docker compose not found"
echo ""; echo "[ Docker daemon ]"
docker info &>/dev/null && ok "Docker daemon running" || fail "Docker daemon not running"
echo ""; echo "[ Required files ]"
for f in Dockerfile docker-compose.yml requirements.txt main.py app/__init__.py app/config.py app/ocr.py app/llm.py app/validation.py app/pipeline.py api/__init__.py api/main.py api/endpoints.py api/schemas.py static/index.html; do
  [[ -f "$f" ]] && ok "$f" || fail "$f missing"
done
echo ""; echo "[ Environment ]"
[[ -f ".env" ]] && ok ".env exists" || { fail ".env missing"; info "Fix: cp .env.example .env"; }
echo ""; echo "[ Directories ]"
[[ -d "licenses" ]] && ok "licenses/ exists" || fail "licenses/ missing"
[[ -d "results"  ]] && ok "results/ exists"  || fail "results/ missing"
echo ""; echo "========================================"
(( FAIL == 0 )) && echo -e "  ${GREEN}All checks passed.${NC}" && echo "  Run: docker compose up --build api" \
               || echo -e "  ${RED}${FAIL} check(s) failed.${NC}"
echo "========================================"
SCRIPTEOF

chmod +x scripts/check.sh

echo ""
echo "============================================"
echo "  Project restored successfully."
echo "============================================"
echo ""
echo "  Next steps:"
echo "    1. cp .env.example .env"
echo "    2. git add ."
echo "    3. git status   (verify nothing sensitive)"
echo "    4. git commit -m 'feat: initial OCR pipeline'"
echo "    5. git push -u origin main"
echo ""
