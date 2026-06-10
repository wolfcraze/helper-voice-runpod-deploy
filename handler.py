"""
RunPod serverless handler for helper-voice-v1, with token-level streaming.

Generator pattern: yields token deltas as Ollama produces them. RunPod aggregates
yielded items into the /stream/{job_id} response so the shim can pick them up
incrementally and re-emit Ollama-NDJSON chunks to Helper Mobile.

Input formats accepted:
    {"input": {"prompt": "...", "stream": true|false}}
    {"input": {"messages": [{"role": "user", "content": "..."}], "stream": true|false}}
    {"input": {"messages": [...], "options": {...}}}

Yielded chunks (when streaming):
    {"delta": "<token text>", "done": false}
    ...
    {"delta": "", "done": true, "eval_count": N, "total_duration": ns}

Non-streaming returns final aggregate dict directly.
"""
import json
import os
import requests
import runpod

OLLAMA_URL = "http://127.0.0.1:11434"
MODEL_NAME = os.environ.get("HELPER_MODEL_NAME", "helper-voice-v1")


def _build_payload(inp):
    if "messages" in inp:
        messages = inp["messages"]
    elif "prompt" in inp:
        messages = [{"role": "user", "content": inp["prompt"]}]
    else:
        return None, "input must contain 'messages' or 'prompt'"
    return {
        "model": MODEL_NAME,
        "messages": messages,
        "stream": True,  # always stream from Ollama; we control aggregation
        "options": inp.get("options", {}),
    }, None


def handler(event):
    """Generator handler. Yields Ollama-token deltas. Caller decides streaming vs aggregate."""
    inp = event.get("input", {}) or {}
    payload, err = _build_payload(inp)
    if err:
        yield {"error": err, "done": True}
        return

    try:
        with requests.post(
            f"{OLLAMA_URL}/api/chat",
            json=payload,
            stream=True,
            timeout=600,
        ) as resp:
            resp.raise_for_status()
            content_acc = []
            eval_count = 0
            total_duration = 0
            for raw_line in resp.iter_lines():
                if not raw_line:
                    continue
                try:
                    chunk = json.loads(raw_line)
                except json.JSONDecodeError:
                    continue
                msg = chunk.get("message", {}) or {}
                delta = msg.get("content", "")
                done = bool(chunk.get("done", False))
                if delta:
                    content_acc.append(delta)
                    yield {"delta": delta, "done": False}
                if done:
                    eval_count = chunk.get("eval_count", 0)
                    total_duration = chunk.get("total_duration", 0)
                    yield {
                        "delta": "",
                        "done": True,
                        "eval_count": eval_count,
                        "total_duration": total_duration,
                        "full_text": "".join(content_acc),
                    }
                    return
    except requests.exceptions.RequestException as e:
        yield {"error": f"ollama request failed: {e}", "done": True}


if __name__ == "__main__":
    # return_aggregate_stream=True allows the shim to call /runsync and get the
    # whole aggregate back as a list, OR call /run + /stream/{id} to get
    # incremental chunks.
    runpod.serverless.start({
        "handler": handler,
        "return_aggregate_stream": True,
    })
