#!/bin/bash
# Self-bootstrapping worker: starts the handler IMMEDIATELY so RunPod sees a healthy
# worker, while the heavy init (download GGUF + ollama create) runs in the BACKGROUND.
# Lets a serverless worker populate its own (empty) volume without exceeding the
# health-check window — no pre-populate pod needed. Handler returns "warming up"
# until /tmp/model_ready exists.
MODEL_NAME="${HELPER_MODEL_NAME:-helper-voice-v1}"
HF_REPO="${HELPER_HF_REPO:-wolfcraze/helper-voice-v1-gguf}"
GGUF_FILE="${HELPER_GGUF_FILE:-helper-voice-v1.Q5_K_M.gguf}"
rm -f /tmp/model_ready

ollama serve &
until curl -s http://127.0.0.1:11434/api/tags > /dev/null 2>&1; do sleep 1; done

( # ---- background bootstrap ----
  if [ -d /runpod-volume ]; then MODEL_DIR=/runpod-volume/models; else MODEL_DIR=/models; fi
  mkdir -p "$MODEL_DIR"
  if [ ! -f "$MODEL_DIR/$GGUF_FILE" ]; then
    echo "[bootstrap] downloading $GGUF_FILE from $HF_REPO"
    HF_HUB_ENABLE_HF_TRANSFER=1 python3 -c "from huggingface_hub import hf_hub_download; import os; hf_hub_download(repo_id='$HF_REPO', filename='$GGUF_FILE', local_dir='$MODEL_DIR', token=os.environ['HF_TOKEN'])"
  fi
  MODELFILE="/app/Modelfile.$MODEL_NAME"; [ -f "$MODELFILE" ] || MODELFILE="/app/Modelfile"
  sed "s|^FROM .*|FROM $MODEL_DIR/$GGUF_FILE|" "$MODELFILE" > /tmp/Modelfile.runtime
  ollama list 2>&1 | grep -q "$MODEL_NAME" || ollama create "$MODEL_NAME" -f /tmp/Modelfile.runtime
  touch /tmp/model_ready
  echo "[bootstrap] $MODEL_NAME READY"
) > /tmp/bootstrap.log 2>&1 &

exec python3 -u /app/handler_bootstrap.py
