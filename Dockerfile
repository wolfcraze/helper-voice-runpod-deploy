# syntax=docker/dockerfile:1.6
FROM ollama/ollama:latest

# Install python + runpod handler + hf_hub for model download (build-time only)
RUN apt-get update && apt-get install -y python3 python3-pip curl && rm -rf /var/lib/apt/lists/*
RUN pip install --no-cache-dir --break-system-packages runpod requests huggingface_hub

WORKDIR /app

# Bake handler + Modelfiles (v1 default + per-model variants)
COPY Modelfile /app/Modelfile
COPY Modelfile.helper-voice-v2 /app/Modelfile.helper-voice-v2
COPY handler.py /app/handler.py
COPY start.sh /app/start.sh
RUN chmod +x /app/start.sh

# NOTE: We tried baking the 19GB GGUF into the image, but RunPod workers
# couldn't reliably spin up with a 22GB image (throttle storms, slow pulls).
# Reverted to small-image + HF-download-on-cold-start (start.sh handles it).
# The download takes ~2-3 min on cold start but workers actually spawn.

# RunPod serverless container entrypoint
# Override the ollama base image's ENTRYPOINT (which is ["/bin/ollama"]).
ENTRYPOINT []
CMD ["/app/start.sh"]
