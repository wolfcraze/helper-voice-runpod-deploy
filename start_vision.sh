#!/bin/bash
# Cold-start for the vision worker: fetch GGUF + stock mmproj, run llama-server
# with --mmproj, then hand off to the RunPod handler.
set -e
GGUF_FILE="${HELPER_GGUF_FILE:-helper-voice-v2-q5_k_m.gguf}"
GGUF_REPO="${HELPER_HF_REPO:-wolfcraze/helper-voice-v2-gguf}"
MMPROJ_FILE="${HELPER_MMPROJ_FILE:-mmproj-F16.gguf}"
MMPROJ_REPO="${HELPER_MMPROJ_REPO:-unsloth/Qwen3.6-27B-GGUF}"
PORT="${LLAMA_PORT:-8080}"

if [ -d /runpod-volume ]; then MODEL_DIR=/runpod-volume/models; else MODEL_DIR=/models; fi
mkdir -p "$MODEL_DIR"

# The fine-tuned language GGUF (private repo, needs HF_TOKEN)
if [ ! -f "$MODEL_DIR/$GGUF_FILE" ]; then
  echo "[start] downloading $GGUF_FILE from $GGUF_REPO"
  python3 -c "from huggingface_hub import hf_hub_download; import os; hf_hub_download(repo_id='$GGUF_REPO', filename='$GGUF_FILE', local_dir='$MODEL_DIR', token=os.environ['HF_TOKEN'])"
fi
# The STOCK vision projector (public repo) — valid because we froze vision in training
if [ ! -f "$MODEL_DIR/$MMPROJ_FILE" ]; then
  echo "[start] downloading $MMPROJ_FILE from $MMPROJ_REPO"
  python3 -c "from huggingface_hub import hf_hub_download; import os; hf_hub_download(repo_id='$MMPROJ_REPO', filename='$MMPROJ_FILE', local_dir='$MODEL_DIR', token=os.environ.get('HF_TOKEN'))"
fi

LLAMA_SERVER="$(command -v llama-server || echo /app/llama-server)"
echo "[start] launching llama-server (--mmproj) on :$PORT"
"$LLAMA_SERVER" -m "$MODEL_DIR/$GGUF_FILE" --mmproj "$MODEL_DIR/$MMPROJ_FILE" \
  --host 127.0.0.1 --port "$PORT" -c 16384 -ngl 999 &

until curl -s "http://127.0.0.1:$PORT/health" >/dev/null 2>&1; do echo "[start] waiting for llama-server..."; sleep 2; done
echo "[start] llama-server ready"
exec python3 -u /app/handler_vision.py
