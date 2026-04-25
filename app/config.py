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
