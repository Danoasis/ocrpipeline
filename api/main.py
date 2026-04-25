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
