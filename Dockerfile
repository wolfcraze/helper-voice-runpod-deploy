FROM ollama/ollama:latest

# Install python + runpod handler + hf_hub for model download
RUN apt-get update && apt-get install -y python3 python3-pip curl && rm -rf /var/lib/apt/lists/*
RUN pip install --no-cache-dir --break-system-packages runpod requests huggingface_hub

WORKDIR /app

# Bake the Modelfile into the image (safe — no model weights in here, just the recipe)
COPY Modelfile /app/Modelfile
COPY handler.py /app/handler.py
COPY start.sh /app/start.sh
RUN chmod +x /app/start.sh

# RunPod serverless container entrypoint
# Override the ollama base image's ENTRYPOINT (which is ["/bin/ollama"]).
ENTRYPOINT []
CMD ["/app/start.sh"]
