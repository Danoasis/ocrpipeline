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
