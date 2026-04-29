# OCR License Pipeline

A document processing pipeline that extracts structured data from driver's license
images using OCR and a local LLM, then applies business rule validation in Python.

[![CI](https://github.com/Danoasis/ocrpipeline/actions/workflows/ci.yml/badge.svg)](https://github.com/Danoasis/ocrpipeline/actions/workflows/ci.yml)
[![CD](https://github.com/Danoasis/ocrpipeline/actions/workflows/cd.yml/badge.svg)](https://github.com/Danoasis/ocrpipeline/actions/workflows/cd.yml)

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
│   ├── config.py           # all config loaded from environment variables
│   ├── ocr.py              # image → raw text  (EasyOCR)
│   ├── llm.py              # raw text → structured JSON  (Ollama)
│   ├── validation.py       # business rules  (pure Python, fully tested)
│   └── pipeline.py         # orchestrates the flow, handles file I/O
├── api/                    # FastAPI web layer
│   ├── main.py             # app factory, CORS, static files
│   ├── endpoints.py        # route handlers (single + bulk upload)
│   └── schemas.py          # Pydantic request/response models
├── static/index.html       # browser UI with drag-and-drop queue
├── tests/                  # pytest suite
│   ├── test_validation.py  # 11 unit tests, no mocking needed
│   ├── test_llm.py         # mocked Ollama calls + JSON repair tests
│   └── test_pipeline.py    # end-to-end with tmp_path fixtures
├── k8s/                    # Kubernetes manifests (EKS-ready)
│   ├── namespace.yaml
│   ├── configmap.yaml
│   ├── secret.yaml
│   ├── ollama/             # Deployment, Service, PVC
│   └── api/                # Deployment, Service, Ingress
├── terraform/              # AWS infrastructure as code
│   ├── vpc.tf              # VPC, subnets, NAT gateway
│   ├── eks.tf              # EKS cluster + node group
│   ├── ecr.tf              # container registry + lifecycle policy
│   ├── variables.tf
│   └── outputs.tf
├── ansible/                # server configuration automation
│   ├── site.yml            # master playbook
│   └── roles/
│       ├── common/         # OS baseline, firewall, SSH hardening
│       ├── docker/         # Docker CE install + daemon config
│       └── ollama/         # Ollama as a systemd service
├── .github/workflows/
│   ├── ci.yml              # lint + test + docker build on every push
│   └── cd.yml              # ECR push + EKS deploy on merge to main
├── scripts/check.sh        # pre-flight checks before running
├── main.py                 # CLI batch entry point
├── Dockerfile              # GPU-enabled by default, CPU fallback via build arg
├── docker-compose.yml      # local stack
├── requirements.txt
├── ruff.toml               # linter configuration
└── .env.example
```

---

## Option 1 — Run locally with Python (venv)

The simplest way to run the pipeline. No Docker required.

### Prerequisites
- Python 3.11+
- [Ollama](https://ollama.com) installed and running

### Steps

```bash
# 1. Clone the repo
git clone https://github.com/Danoasis/ocrpipeline.git
cd ocrpipeline

# 2. Create and activate a virtual environment
python3 -m venv venv
source venv/bin/activate          # Windows: venv\Scripts\activate

# 3. Install dependencies
pip install -r requirements.txt

# 4. Set up config
cp .env.example .env
# Edit .env if needed — OLLAMA_URL is set automatically for local Python

# 5. Pull the model
ollama pull llama3.2

# 6. Create required folders and add license images
mkdir -p licenses results
# Copy your .png / .jpg images into licenses/

# 7a. Run the CLI batch processor (processes all images in licenses/)
python main.py

# 7b. OR start the web API
uvicorn api.main:app --reload --host 0.0.0.0 --port 8000
# Open: http://localhost:8000
```

> **Note:** `OLLAMA_URL` is set automatically. When running with plain Python,
> `config.py` detects the environment and uses `http://localhost:11434/api/chat`.
> You do not need to edit `.env` for this.

---

## Option 2 — Run with Docker Compose

Runs the API in a container while Ollama runs natively on your machine.

### Prerequisites
- [Docker](https://docs.docker.com/get-docker/)
- [Ollama](https://ollama.com) installed and running natively
- NVIDIA GPU + [NVIDIA Container Toolkit](https://docs.nvidia.com/datacenter/cloud-native/container-toolkit/install-guide.html) *(optional — CPU works too)*

### Steps

```bash
# 1. Clone the repo
git clone https://github.com/Danoasis/ocrpipeline.git
cd ocrpipeline

# 2. Run the pre-flight check
chmod +x scripts/check.sh && ./scripts/check.sh

# 3. Set up config
cp .env.example .env
# Set USE_GPU=false in .env if you don't have an NVIDIA GPU

# 4. Pull the model
ollama pull llama3.2

# 5. Linux only: expose Ollama on all interfaces so Docker can reach it
sudo mkdir -p /etc/systemd/system/ollama.service.d
echo -e '[Service]\nEnvironment="OLLAMA_HOST=0.0.0.0:11434"' \
  | sudo tee /etc/systemd/system/ollama.service.d/override.conf
sudo systemctl daemon-reload && sudo systemctl restart ollama

# Verify Ollama is reachable
curl http://localhost:11434/api/tags

# 6. Start the API
docker compose up --build api

# 7. Open the web UI
# http://localhost:8000
# http://localhost:8000/docs  ← interactive API docs
```

> **macOS / Windows:** Step 5 is not needed. Docker Desktop handles
> `host.docker.internal` automatically.

### Useful commands

```bash
# Follow API logs
docker compose logs -f api

# Rebuild after code changes
docker compose up --build api

# Stop everything
docker compose down

# Run the CLI batch processor instead of the API
docker compose run --rm pipeline
```

---

## Option 3 — Deploy to AWS EKS (Kubernetes)

Full cloud deployment on AWS. Requires an AWS account.

### Prerequisites
- AWS CLI configured (`aws configure`)
- `terraform` installed
- `kubectl` installed
- `eksctl` installed

### Step 1 — Provision AWS infrastructure with Terraform

```bash
cd terraform

# Create S3 bucket for Terraform state (one-time setup)
aws s3 mb s3://yourname-ocrpipeline-tfstate --region us-east-1
aws s3api put-bucket-versioning \
  --bucket yourname-ocrpipeline-tfstate \
  --versioning-configuration Status=Enabled

# Update bucket name in terraform/main.tf, then:
terraform init
terraform plan    # preview what will be created
terraform apply   # takes ~15 minutes
```

This creates: VPC, public/private subnets, NAT gateway, EKS cluster,
node group (2x t3.medium), ECR repository, IAM roles.

### Step 2 — Configure kubectl

```bash
# Get the command from Terraform output
terraform output kubectl_config_command

# Run it (example):
aws eks update-kubeconfig --region us-east-1 --name ocrpipeline

# Verify nodes are ready
kubectl get nodes
```

### Step 3 — Install the EBS CSI driver

Required for persistent volumes on EKS. Not included by default.

```bash
# Install the addon
aws eks create-addon \
  --cluster-name ocrpipeline \
  --addon-name aws-ebs-csi-driver \
  --region us-east-1

# Grant the node role permission to create EBS volumes
aws iam attach-role-policy \
  --role-name ocrpipeline-node-role \
  --policy-arn arn:aws:iam::aws:policy/service-role/AmazonEBSCSIDriverPolicy

# Wait for the addon to be active (~2 minutes)
aws eks describe-addon \
  --cluster-name ocrpipeline \
  --addon-name aws-ebs-csi-driver \
  --region us-east-1 \
  --query 'addon.status'
```

### Step 4 — Update the API deployment image

In `k8s/api/deployment.yaml`, update the image to your ECR URL:

```yaml
# Get your ECR URL from:
terraform output ecr_repository_url

# Update this line in k8s/api/deployment.yaml:
image: YOUR_ACCOUNT_ID.dkr.ecr.us-east-1.amazonaws.com/ocrpipeline:latest
```

### Step 5 — Deploy to Kubernetes

```bash
cd ~/ocrpipeline

kubectl apply -f k8s/namespace.yaml
kubectl apply -f k8s/configmap.yaml
kubectl apply -f k8s/secret.yaml

# Ollama (requires nodes with 8GB+ RAM — see note below)
kubectl apply -f k8s/ollama/pvc.yaml
kubectl apply -f k8s/ollama/deployment.yaml
kubectl apply -f k8s/ollama/service.yaml

# Wait for Ollama
kubectl rollout status deployment/ollama -n ocrpipeline --timeout=5m

# API
kubectl apply -f k8s/api/deployment.yaml
kubectl apply -f k8s/api/service.yaml
kubectl apply -f k8s/api/ingress.yaml

# Verify everything is running
kubectl get pods -n ocrpipeline
kubectl get svc -n ocrpipeline
```

> **RAM requirement:** Ollama needs at least 8GB RAM per node.
> The default `t3.medium` nodes (4GB) are too small to run Ollama.
> Either upgrade to `t3.large`+ in `terraform/variables.tf`, or
> skip the Ollama deployment and point `OLLAMA_URL` in `k8s/configmap.yaml`
> at an external Ollama instance.

### Step 6 — Enable automatic CD deployments

Once the cluster is running, activate auto-deploy on every merge to `main`:

1. Add `EKS_CLUSTER_NAME=ocrpipeline` to GitHub Secrets
2. In `.github/workflows/cd.yml`, change `if: false` to `if: true` in the deploy job
3. Push — every merge to `main` will now build, push to ECR, and deploy to EKS

### Tear down (stop AWS billing)

```bash
cd terraform
terraform destroy
# Type "yes" — takes ~15 minutes
# This destroys EKS, VPC, NAT gateway, and IAM resources
# Your ECR images and S3 state bucket are preserved
```

---

## Configuration

Copy `.env.example` to `.env`. Most values have sensible defaults.

| Variable         | Default          | Description                              |
|------------------|------------------|------------------------------------------|
| `INPUT_FOLDER`   | `licenses/`      | Folder scanned for images                |
| `OUTPUT_FOLDER`  | `results/`       | Folder for JSON result files             |
| `OLLAMA_URL`     | *auto-detected*  | Set automatically (localhost or Docker)  |
| `OLLAMA_MODEL`   | `llama3.2`       | Model used for extraction                |
| `OLLAMA_TIMEOUT` | `60`             | Request timeout in seconds               |
| `USE_GPU`        | `false`          | GPU acceleration for EasyOCR             |

`OLLAMA_URL` is auto-detected based on the runtime environment. Override it
only if connecting to a remote Ollama instance.

---

## API endpoints

| Method | Path                | Description                        |
|--------|---------------------|------------------------------------|
| `POST` | `/api/upload`       | Upload one image, returns result   |
| `POST` | `/api/upload/bulk`  | Upload up to 50 images at once     |
| `GET`  | `/api/results`      | List all processed results         |
| `GET`  | `/api/results/{id}` | Get full result for one file       |
| `GET`  | `/api/health`       | Health check (used by k8s probes)  |
| `GET`  | `/docs`             | Interactive Swagger UI             |

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

Tests do not require Ollama or a GPU — all external calls are mocked.

---

## Troubleshooting

**`Connection refused` to Ollama from Docker:**
Ollama is bound to `127.0.0.1` by default on Linux. Follow Step 5 in
Option 2 above to expose it on all interfaces.

**`Using CPU` in logs instead of GPU:**
Set `USE_GPU=true` in `.env` and ensure the NVIDIA Container Toolkit is installed.
Verify with: `docker run --rm --gpus all nvidia/cuda:12.1.0-base-ubuntu22.04 nvidia-smi`

**`could not select device driver "nvidia"`:**
The Docker nvidia runtime needs to be reconfigured:
```bash
sudo nvidia-ctk runtime configure --runtime=docker
sudo systemctl restart docker
```

**LLM returns truncated or malformed JSON:**
The pipeline includes automatic JSON repair. If you see frequent parse errors,
increase `OLLAMA_TIMEOUT` in `.env` or try a different model.

**PVCs stuck in Pending on EKS:**
The EBS CSI driver is not installed or lacks IAM permissions.
Follow Step 3 in Option 3 above.

**Ollama pods Pending on EKS (Insufficient memory):**
Your nodes don't have enough RAM. Upgrade to `t3.large` or larger in
`terraform/variables.tf` and run `terraform apply`.

---

## Tech stack

| Layer          | Technology                              |
|----------------|-----------------------------------------|
| OCR            | EasyOCR (GPU-accelerated, CPU fallback) |
| LLM            | Ollama / llama3.2 (local)               |
| API            | FastAPI + uvicorn                       |
| Language       | Python 3.11                             |
| Tests          | pytest                                  |
| Linting        | ruff                                    |
| Container      | Docker + NVIDIA Container Toolkit       |
| Orchestration  | Kubernetes (EKS)                        |
| Infrastructure | Terraform (AWS)                         |
| Config mgmt    | Ansible                                 |
| CI/CD          | GitHub Actions                          |