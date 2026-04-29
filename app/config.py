"""
config.py — all configuration loaded from environment variables.

OLLAMA_URL is set automatically based on the runtime environment:
    - Inside docker: uses host.docker.internal (set via docker-compose env)
    - Plain Python: uses localhost

You can always override by setting OLLAMA_URL explicitly in your .env file.
"""

import os

from dotenv import load_dotenv

load_dotenv()

def _default_ollama_url() -> str:
    """
    Detect whether we're running inside a Docker container and return
    the correct Ollama URL automatically.

    Detection method: Docker injects a file called /.dockerenv into every
    container. If it exists, we're in Docker, if not we're on the host.

    This means:
    - venv / plain Python -> /.dockerenv absent -> use localhost
    - docker compose      -> /.dockerenv present -> use host.docker.internal
    """
    in_docker = os.path.exists("/.dockerenv")
    if in_docker:
        return "http://host.docker.internal:11434/api/chat"
    return "http://localhost:11434/api/chat"



INPUT_FOLDER:  str      = os.getenv("INPUT_FOLDER",  "licenses/")
OUTPUT_FOLDER: str      = os.getenv("OUTPUT_FOLDER", "results/")

OLLAMA_URL:    str      = os.getenv("OLLAMA_URL",    _default_ollama_url())
OLLAMA_MODEL:  str      = os.getenv("OLLAMA_MODEL",  "llama3.2")
OLLAMA_TIMEOUT: int     = int(os.getenv("OLLAMA_TIMEOUT", "60"))

USE_GPU: bool           = os.getenv("USE_GPU", "false").lower() == "true"

ALLOWED_EXTENSIONS: set[str] = {".png", ".jpg", ".jpeg", ".bmp", ".tiff"}
