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
