# syntax=docker/dockerfile:1.6
FROM ollama/ollama:latest

# Install python + runpod handler + hf_hub for model download (build-time only)
RUN apt-get update && apt-get install -y python3 python3-pip curl && rm -rf /var/lib/apt/lists/*
RUN pip install --no-cache-dir --break-system-packages runpod requests huggingface_hub

WORKDIR /app

# Bake handler + Modelfile
COPY Modelfile /app/Modelfile
COPY handler.py /app/handler.py
COPY start.sh /app/start.sh
RUN chmod +x /app/start.sh

# Bake the GGUF into the image at build time. Pulls from the private HF repo
# using the HF_TOKEN secret mounted only during this RUN step (not in any layer).
# Result: cold-starts skip the 19GB HF download. RunPod caches the image per
# physical worker, so subsequent cold starts on a hot machine are 6-12s.
COPY download_gguf.py /app/download_gguf.py
RUN --mount=type=secret,id=HF_TOKEN \
    HF_TOKEN=$(cat /run/secrets/HF_TOKEN) python3 /app/download_gguf.py && \
    ls -lah /models/

# RunPod serverless container entrypoint
# Override the ollama base image's ENTRYPOINT (which is ["/bin/ollama"]).
ENTRYPOINT []
CMD ["/app/start.sh"]
