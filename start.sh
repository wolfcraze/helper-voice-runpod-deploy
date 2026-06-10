#!/bin/bash
# Cold-start sequence for a helper-voice serverless worker.
# Parametrized by env (defaults = v1, so the existing v1 endpoint is unchanged):
#   HELPER_MODEL_NAME  (default helper-voice-v1)  ollama model name + identity
#   HELPER_HF_REPO     (default wolfcraze/helper-voice-v1-gguf)
#   HELPER_GGUF_FILE   (default helper-voice-v1.Q5_K_M.gguf)
# A per-model Modelfile (/app/Modelfile.$HELPER_MODEL_NAME) is used if present,
# else /app/Modelfile (the v1 default).
set -e

MODEL_NAME="${HELPER_MODEL_NAME:-helper-voice-v1}"
HF_REPO="${HELPER_HF_REPO:-wolfcraze/helper-voice-v1-gguf}"
GGUF_FILE="${HELPER_GGUF_FILE:-helper-voice-v1.Q5_K_M.gguf}"
echo "[start] booting $MODEL_NAME (repo=$HF_REPO file=$GGUF_FILE)"

echo "[start] launching ollama server"
ollama serve &
sleep 5
until curl -s http://127.0.0.1:11434/api/tags > /dev/null 2>&1; do
    echo "[start] waiting for ollama..."; sleep 1
done
echo "[start] ollama ready"

# GGUF location: persistent volume -> image-baked -> download from HF (to volume if present)
if [ -d /runpod-volume ] && [ -f "/runpod-volume/models/$GGUF_FILE" ]; then
    MODEL_DIR=/runpod-volume/models
    echo "[start] using network volume at $MODEL_DIR"
elif [ -f "/models/$GGUF_FILE" ]; then
    MODEL_DIR=/models
    echo "[start] using image-baked GGUF at $MODEL_DIR"
else
    if [ -d /runpod-volume ]; then MODEL_DIR=/runpod-volume/models; else MODEL_DIR=/models; fi
    mkdir -p "$MODEL_DIR"
    echo "[start] downloading $GGUF_FILE from $HF_REPO into $MODEL_DIR (first cold start)"
    python3 -c "
from huggingface_hub import hf_hub_download
import os
hf_hub_download(repo_id='$HF_REPO', filename='$GGUF_FILE', local_dir='$MODEL_DIR', token=os.environ['HF_TOKEN'])
print('[hf-download] complete')
"
fi
GGUF_PATH="$MODEL_DIR/$GGUF_FILE"
echo "[start] GGUF: $GGUF_PATH ($(du -h "$GGUF_PATH" | cut -f1))"

# Select per-model Modelfile if present, else the default (v1) Modelfile.
MODELFILE="/app/Modelfile.$MODEL_NAME"
[ -f "$MODELFILE" ] || MODELFILE="/app/Modelfile"
echo "[start] using $MODELFILE"
sed "s|^FROM .*|FROM $GGUF_PATH|" "$MODELFILE" > /tmp/Modelfile.runtime

if ! ollama list 2>&1 | grep -q "$MODEL_NAME"; then
    echo "[start] registering $MODEL_NAME from $GGUF_PATH"
    ollama create "$MODEL_NAME" -f /tmp/Modelfile.runtime
fi
echo "[start] model registered: $MODEL_NAME"

echo "[start] starting RunPod handler"
exec python3 -u /app/handler.py
