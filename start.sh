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

# Download GGUF from HF if not already present
mkdir -p /models
GGUF_PATH=/models/helper-voice-v1.Q5_K_M.gguf
if [ ! -f "$GGUF_PATH" ]; then
    echo "[start] downloading helper-voice-v1 GGUF from HF (this is the slow part of cold start)"
    python3 -c "
from huggingface_hub import hf_hub_download
import os
hf_hub_download(
    repo_id='wolfcraze/helper-voice-v1-gguf',
    filename='helper-voice-v1.Q5_K_M.gguf',
    local_dir='/models',
    token=os.environ['HF_TOKEN']
)
print('[hf-download] complete')
"
else
    echo "[start] GGUF already present (warm start)"
fi

# Register model with Ollama
if ! ollama list 2>&1 | grep -q "helper-voice-v1"; then
    echo "[start] registering model in Ollama"
    ollama create helper-voice-v1 -f /app/Modelfile
fi
echo "[start] model registered"

# Hand off to RunPod handler
echo "[start] starting RunPod handler"
exec python3 -u /app/handler.py
