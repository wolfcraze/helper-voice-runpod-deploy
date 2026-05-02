#!/bin/bash
# Cold-start sequence for helper-voice-v1 serverless worker.
# 1. Start Ollama daemon in background
# 2. Pull GGUF from HF (cached on warm starts via volume or worker reuse)
# 3. Register the model with Ollama via Modelfile
# 4. Hand off to RunPod handler
set -e

echo "[start] booting helper-voice-v1 worker"

# Start Ollama daemon
echo "[start] launching ollama server"
ollama serve &
OLLAMA_PID=$!
sleep 5

# Wait for Ollama to be ready
until curl -s http://127.0.0.1:11434/api/tags > /dev/null 2>&1; do
    echo "[start] waiting for ollama..."
    sleep 1
done
echo "[start] ollama ready"

# GGUF location: prefer Network Volume (persistent across cold starts) if mounted.
# Falls back to ephemeral container disk if no volume (also useful for local testing).
if [ -d /runpod-volume ]; then
    MODEL_DIR=/runpod-volume/models
    echo "[start] using network volume at $MODEL_DIR (persistent — fast subsequent cold starts)"
else
    MODEL_DIR=/models
    echo "[start] using ephemeral container disk at $MODEL_DIR (will re-download every cold start)"
fi
mkdir -p "$MODEL_DIR"
GGUF_PATH=$MODEL_DIR/helper-voice-v1.Q5_K_M.gguf

if [ ! -f "$GGUF_PATH" ] || [ "$(stat -c%s "$GGUF_PATH" 2>/dev/null)" -lt 19000000000 ]; then
    echo "[start] downloading helper-voice-v1 GGUF from HF (one-time on volume init)"
    python3 -c "
from huggingface_hub import hf_hub_download
import os
hf_hub_download(
    repo_id='wolfcraze/helper-voice-v1-gguf',
    filename='helper-voice-v1.Q5_K_M.gguf',
    local_dir='$MODEL_DIR',
    token=os.environ['HF_TOKEN']
)
print('[hf-download] complete')
"
else
    echo "[start] GGUF already present at $GGUF_PATH ($(du -h $GGUF_PATH | cut -f1)) — skipping download"
fi

# Build a per-worker Modelfile that points at the actual GGUF location
sed "s|FROM /models/helper-voice-v1.Q5_K_M.gguf|FROM $GGUF_PATH|" /app/Modelfile > /tmp/Modelfile.runtime

# Register model with Ollama (idempotent — re-create if already exists from prev cold start)
if ! ollama list 2>&1 | grep -q "helper-voice-v1"; then
    echo "[start] registering model in Ollama from $GGUF_PATH"
    ollama create helper-voice-v1 -f /tmp/Modelfile.runtime
fi
echo "[start] model registered"

# Hand off to RunPod handler
echo "[start] starting RunPod handler"
exec python3 -u /app/handler.py
