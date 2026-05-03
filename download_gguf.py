"""Download helper-voice-v1.Q5_K_M.gguf from HF into /models/.
Used at Docker build time so the GGUF is baked into the image.
Reads HF_TOKEN from environment (mounted as a buildkit secret)."""
import os
from huggingface_hub import hf_hub_download

token = os.environ.get("HF_TOKEN")
if not token:
    raise SystemExit("HF_TOKEN not set")

path = hf_hub_download(
    repo_id="wolfcraze/helper-voice-v1-gguf",
    filename="helper-voice-v1.Q5_K_M.gguf",
    local_dir="/models",
    token=token,
)
print(f"Downloaded to: {path}")
