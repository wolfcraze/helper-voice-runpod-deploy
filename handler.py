"""
RunPod serverless handler for helper-voice-v1.
Receives chat-format requests, forwards to local Ollama, returns response.
Compatible with Ollama /api/chat schema so Helper Mobile can use it directly.
"""
import os
import json
import requests
import runpod

OLLAMA_URL = "http://127.0.0.1:11434"
MODEL_NAME = "helper-voice-v1"


def handler(event):
    """RunPod serverless handler.

    Expected input formats (any one):
      {"input": {"prompt": "Helper weave."}}                        # simple
      {"input": {"messages": [{"role":"user","content":"..."}]}}    # chat
      {"input": {"messages": [...], "options": {...}}}              # full

    Returns Ollama-style response dict.
    """
    inp = event.get("input", {})

    # Normalize to messages format
    if "messages" in inp:
        messages = inp["messages"]
    elif "prompt" in inp:
        messages = [{"role": "user", "content": inp["prompt"]}]
    else:
        return {"error": "input must contain 'messages' or 'prompt'"}

    options = inp.get("options", {})

    payload = {
        "model": MODEL_NAME,
        "messages": messages,
        "stream": False,
        "options": options,
    }

    try:
        resp = requests.post(
            f"{OLLAMA_URL}/api/chat",
            json=payload,
            timeout=300,
        )
        resp.raise_for_status()
        data = resp.json()
        return {
            "message": data.get("message", {}),
            "model": data.get("model", MODEL_NAME),
            "done": data.get("done", True),
            "total_duration_ns": data.get("total_duration"),
            "eval_count": data.get("eval_count"),
        }
    except requests.exceptions.RequestException as e:
        return {"error": f"ollama request failed: {e}"}


if __name__ == "__main__":
    runpod.serverless.start({"handler": handler})
