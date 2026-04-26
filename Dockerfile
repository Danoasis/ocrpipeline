# =============================================================================
# Dockerfile — GPU-enabled (CUDA 12.4 + cuDNN)
# =============================================================================

ARG BASE_IMAGE=nvidia/cuda:12.4.1-cudnn-runtime-ubuntu22.04
FROM ${BASE_IMAGE}

# Re-declare ARG after FROM so it's available in RUN steps
ARG INSTALL_PYTHON=true

ENV DEBIAN_FRONTEND=noninteractive
ENV TZ=UTC

RUN apt-get update && apt-get install -y \
    libglib2.0-0 \
    curl \
    && rm -rf /var/lib/apt/lists/*

RUN if [ "$INSTALL_PYTHON" = "true" ]; then \
    apt-get update && \
    apt-get install -y python3.10 python3.10-dev python3-pip && \
    rm -rf /var/lib/apt/lists/* && \
    update-alternatives --install /usr/bin/python python /usr/bin/python3.10 1 && \
    update-alternatives --install /usr/bin/pip    pip    /usr/bin/pip3       1; \
fi

WORKDIR /app

COPY requirements.txt .
RUN python3 -m pip install --no-cache-dir -r requirements.txt

COPY . .
RUN mkdir -p licenses results
RUN useradd --create-home appuser && chown -R appuser:appuser /app
USER appuser

CMD ["python", "main.py"]
