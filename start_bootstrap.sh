#!/bin/bash
# Self-bootstrapping worker. Handler comes up immediately (worker healthy) while a
# background loop downloads the GGUF + ollama-creates, RETRYING until `ollama list`
# confirms the model. Only then is /tmp/model_ready set, so the handler never serves
# a half-loaded model.
MODEL_NAME="${HELPER_MODEL_NAME:-helper-voice-v1}"
HF_REPO="${HELPER_HF_REPO:-wolfcraze/helper-voice-v1-gguf}"
GGUF_FILE="${HELPER_GGUF_FILE:-helper-voice-v1.Q5_K_M.gguf}"
rm -f /tmp/model_ready

ollama serve &
until curl -s http://127.0.0.1:11434/api/tags > /dev/null 2>&1; do sleep 1; done

(
  if [ -d /runpod-volume ]; then MODEL_DIR=/runpod-volume/models; else MODEL_DIR=/models; fi
  mkdir -p "$MODEL_DIR"
  MODELFILE="/app/Modelfile.$MODEL_NAME"; [ -f "$MODELFILE" ] || MODELFILE="/app/Modelfile"
  for attempt in 1 2 3 4 5 6; do
    echo "[bootstrap] attempt $attempt: ensuring GGUF"
    python3 -c "from huggingface_hub import hf_hub_download; import os; hf_hub_download(repo_id='$HF_REPO', filename='$GGUF_FILE', local_dir='$MODEL_DIR', token=os.environ['HF_TOKEN'])" || { echo '[bootstrap] download error'; sleep 10; continue; }
    sed "s|^FROM .*|FROM $MODEL_DIR/$GGUF_FILE|" "$MODELFILE" > /tmp/Modelfile.runtime
    echo "[bootstrap] ollama create $MODEL_NAME"
    ollama create "$MODEL_NAME" -f /tmp/Modelfile.runtime
    if ollama list 2>&1 | grep -q "$MODEL_NAME"; then
      touch /tmp/model_ready; echo "[bootstrap] $MODEL_NAME READY"; break
    fi
    echo "[bootstrap] model not registered, retrying"; sleep 10
  done
) > /tmp/bootstrap.log 2>&1 &

exec python3 -u /app/handler_bootstrap.py
