# =============================================================================
# Dockerfile
# =============================================================================
#
# Local GPU:  docker compose up --build api
#             → uses nvidia/cuda base (has no Python, installs it)
#
# CI:         --build-arg BASE_IMAGE=python:3.11-slim
#             → python:3.11-slim already has Python 3.11 baked in
#             → we only install system libs, skip the Python apt step
#
# =============================================================================

ARG BASE_IMAGE=nvidia/cuda:12.4.1-cudnn-runtime-ubuntu22.04
FROM ${BASE_IMAGE}

ENV DEBIAN_FRONTEND=noninteractive
ENV TZ=UTC

# -----------------------------------------------------------------------
# For python:3.11-slim (CI): only system deps needed — Python is baked in
# -----------------------------------------------------------------------
# We detect which base we're on by checking if python3.11 already exists.
# If it does: skip the Python apt install entirely.
# If it doesn't (CUDA base): install Python 3.11 from Ubuntu 22.04 repos.
#
# This avoids the build-arg if/else pattern which has escaping issues
# inside Docker RUN shell conditionals.
# -----------------------------------------------------------------------
RUN apt-get update && apt-get install -y \
    libgl1 \
    libglib2.0-0 \
    curl \
    && rm -rf /var/lib/apt/lists/*

RUN if ! command -v python3.11 > /dev/null 2>&1; then \
        apt-get update && \
        apt-get install -y python3.11 python3.11-dev python3-pip && \
        rm -rf /var/lib/apt/lists/*; \
    fi

# Ensure python3/pip3 point to 3.11 on both base images
RUN ln -sf /usr/bin/python3.11 /usr/local/bin/python3 2>/dev/null || true && \
    ln -sf /usr/bin/python3.11 /usr/local/bin/python  2>/dev/null || true

WORKDIR /app

COPY requirements.txt .
RUN python3.11 -m pip install --no-cache-dir -r requirements.txt

COPY . .
RUN mkdir -p licenses results
RUN useradd --create-home appuser \
 && chown -R appuser:appuser /app
USER appuser

CMD ["python3.11", "main.py"]