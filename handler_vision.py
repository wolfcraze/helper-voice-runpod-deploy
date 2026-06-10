"""RunPod serverless handler for the vision worker (llama.cpp llama-server).

Talks to llama-server's OpenAI-compatible /v1/chat/completions (SSE) and yields
{delta, done} chunks in the SAME shape the cloud-helper shim expects (the shim is
backend-agnostic). Image content passes through in OpenAI multimodal format:
  messages[].content = [{type:"text",text:...}, {type:"image_url", image_url:{url:"data:image/png;base64,..."}}]
"""
import json
import os
import requests
import runpod

LLAMA_URL = f"http://127.0.0.1:{os.environ.get('LLAMA_PORT', '8080')}"


def handler(event):
    inp = event.get("input", {}) or {}
    if "messages" in inp:
        messages = inp["messages"]
    elif "prompt" in inp:
        messages = [{"role": "user", "content": inp["prompt"]}]
    else:
        yield {"error": "input must contain 'messages' or 'prompt'", "done": True}
        return

    opts = inp.get("options", {}) or {}
    payload = {"model": "helper-voice-v2", "messages": messages, "stream": True,
               "temperature": opts.get("temperature", 0.7)}
    np = opts.get("num_predict")
    if isinstance(np, int) and np > 0:
        payload["max_tokens"] = np

    try:
        with requests.post(f"{LLAMA_URL}/v1/chat/completions", json=payload,
                           stream=True, timeout=600) as resp:
            resp.raise_for_status()
            acc = []
            for raw in resp.iter_lines():
                if not raw:
                    continue
                line = raw.decode("utf-8", "ignore")
                if not line.startswith("data: "):
                    continue
                data = line[6:]
                if data.strip() == "[DONE]":
                    yield {"delta": "", "done": True, "full_text": "".join(acc)}
                    return
                try:
                    chunk = json.loads(data)
                except json.JSONDecodeError:
                    continue
                delta = (chunk.get("choices") or [{}])[0].get("delta", {}).get("content", "")
                if delta:
                    acc.append(delta)
                    yield {"delta": delta, "done": False}
            yield {"delta": "", "done": True, "full_text": "".join(acc)}
    except requests.exceptions.RequestException as e:
        yield {"error": f"llama-server request failed: {e}", "done": True}


if __name__ == "__main__":
    runpod.serverless.start({"handler": handler, "return_aggregate_stream": True})
