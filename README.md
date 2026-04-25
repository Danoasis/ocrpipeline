# OCR License Pipeline

A document processing pipeline that extracts structured data from driver's license
images using OCR and a local LLM, then applies business rule validation in Python.

---

## How it works

```
Image file  (upload via browser or CLI)
    │
    ▼
[EasyOCR]            → extracts raw text from the image
    │
    ▼
[Ollama / llama3.2]  → parses raw text into structured JSON fields
    │
    ▼
[Python Validation]  → applies business rules (expiration check)
    │
    ▼
JSON result file  +  browser UI response
```

The key design decision: **the LLM only does data extraction**.
Business logic (is this license expired?) is handled by Python — not the model.
This makes the logic testable, deterministic, and auditable.

---

## Project structure

```
ocrpipeline/
├── app/                    # core pipeline (OCR → LLM → validation)
│   ├── config.py
│   ├── ocr.py
│   ├── llm.py
│   ├── validation.py
│   └── pipeline.py
├── api/                    # FastAPI web layer
│   ├── main.py
│   ├── endpoints.py
│   └── schemas.py
├── static/index.html       # browser UI with drag-and-drop queue
├── tests/                  # pytest suite
├── k8s/                    # Kubernetes manifests
├── terraform/              # AWS infrastructure as code
├── ansible/                # server configuration automation
├── .github/workflows/      # CI (lint+test+build) + CD (ECR+EKS)
├── scripts/check.sh        # pre-flight checks
├── main.py                 # CLI batch entry point
├── Dockerfile              # GPU-enabled (CUDA 12.4 + cuDNN)
├── docker-compose.yml      # local stack with GPU passthrough
└── ruff.toml               # linter configuration
```

---

## Requirements

- Docker with NVIDIA Container Toolkit
- Ollama running natively with `llama3.2` pulled

---

## Quick start

```bash
git clone https://github.com/Danoasis/ocrpipeline.git
cd ocrpipeline
cp .env.example .env
docker compose up --build api
# Open: http://localhost:8000
```

> **Linux only:** Ollama must listen on all interfaces so Docker can reach it:
> ```bash
> sudo mkdir -p /etc/systemd/system/ollama.service.d
> echo -e '[Service]\nEnvironment="OLLAMA_HOST=0.0.0.0:11434"' \
>   | sudo tee /etc/systemd/system/ollama.service.d/override.conf
> sudo systemctl daemon-reload && sudo systemctl restart ollama
> ```

---

## API endpoints

| Method | Path                | Description                      |
|--------|---------------------|----------------------------------|
| `POST` | `/api/upload`       | Upload one image, returns result |
| `POST` | `/api/upload/bulk`  | Upload up to 50 images at once   |
| `GET`  | `/api/results`      | List all processed results       |
| `GET`  | `/api/results/{id}` | Get full result for one file     |
| `GET`  | `/docs`             | Interactive Swagger UI           |

---

## Output format

```json
{
  "source_file": "licenses/license_01.png",
  "processed_at": "2026-04-24T02:54:07.177040",
  "extracted_fields": {
    "full_name": "Ana Rojas Gomez",
    "license_number": "EXA-9380422",
    "date_of_birth": "1975-11-10",
    "expiration_date": "2034-12-19",
    "class": "C"
  },
  "validation": {
    "status": "valid",
    "days_remaining": 3161,
    "reason": "Valid for 3161 more days."
  }
}
```

| Status           | Meaning                               |
|------------------|---------------------------------------|
| `valid`          | Expires in 30+ days                   |
| `expiring_soon`  | Expires within 30 days                |
| `expired`        | Expiration date is in the past        |
| `unknown`        | No expiration date found              |
| `error`          | Date found but could not be parsed    |

---

## Running tests

```bash
pytest -v
```

---

## Tech stack

| Layer          | Technology                          |
|----------------|-------------------------------------|
| OCR            | EasyOCR (GPU-accelerated)           |
| LLM            | Ollama / llama3.2 (local)           |
| API            | FastAPI + uvicorn                   |
| Language       | Python 3.11                         |
| Tests          | pytest                              |
| Linting        | ruff                                |
| Container      | Docker + NVIDIA Container Toolkit   |
| Orchestration  | Kubernetes (EKS / AKS)              |
| Infrastructure | Terraform                           |
| Config mgmt    | Ansible                             |
| CI/CD          | GitHub Actions                      |
