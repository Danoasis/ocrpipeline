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
