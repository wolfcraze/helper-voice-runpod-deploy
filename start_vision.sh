#!/bin/bash
# Self-bootstrapping llama-server worker (Qwen3.6 text+tools+vision).
# fresh llama.cpp loads Qwen3.6 (Ollama can't). Background load keeps the worker
# healthy through the one-time download; handler returns "warming" until ready.
MODEL_NAME="${HELPER_MODEL_NAME:-helper-voice-v2}"
GGUF_FILE="${HELPER_GGUF_FILE:-helper-voice-v2-q5_k_m.gguf}"
GGUF_REPO="${HELPER_HF_REPO:-wolfcraze/helper-voice-v2-gguf}"
MMPROJ_FILE="${HELPER_MMPROJ_FILE:-mmproj-F16.gguf}"
MMPROJ_REPO="${HELPER_MMPROJ_REPO:-unsloth/Qwen3.6-27B-GGUF}"
PORT="${LLAMA_PORT:-8080}"

(  # ---- background: fetch model files, then run llama-server (persistent) ----
  if [ -d /runpod-volume ]; then MODEL_DIR=/runpod-volume/models; else MODEL_DIR=/models; fi
  mkdir -p "$MODEL_DIR"
  for a in 1 2 3 4 5 6; do
    python3 -c "from huggingface_hub import hf_hub_download; import os; hf_hub_download(repo_id='$GGUF_REPO', filename='$GGUF_FILE', local_dir='$MODEL_DIR', token=os.environ['HF_TOKEN'])" && break
    echo "[bootstrap] gguf retry $a"; sleep 10
  done
  # mmproj is OPTIONAL (vision) — never block text serving on it
  python3 -c "from huggingface_hub import hf_hub_download; import os; hf_hub_download(repo_id='$MMPROJ_REPO', filename='$MMPROJ_FILE', local_dir='$MODEL_DIR', token=os.environ.get('HF_TOKEN'))" || echo "[bootstrap] mmproj unavailable (text-only)"
  LS="$(command -v llama-server || echo /app/llama-server)"
  MM=""; [ -f "$MODEL_DIR/$MMPROJ_FILE" ] && MM="--mmproj $MODEL_DIR/$MMPROJ_FILE"
  echo "[bootstrap] launching: $LS -m $MODEL_DIR/$GGUF_FILE $MM"
  exec "$LS" -m "$MODEL_DIR/$GGUF_FILE" $MM --host 127.0.0.1 --port "$PORT" -c 16384 -ngl 999 --jinja
) > /tmp/bootstrap.log 2>&1 &

exec python3 -u /app/handler_vision.py
