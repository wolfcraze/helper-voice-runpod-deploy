"""RunPod handler -> llama-server (OpenAI-compatible), with a readiness gate.
Returns 'warming up' until llama-server's /health is 200 (model loaded). Yields
{delta,done} in the shape the cloud-helper shim expects. Forwards image content
(OpenAI multimodal) and tools when present."""
import json, os, requests, runpod
LLAMA_URL = f"http://127.0.0.1:{os.environ.get('LLAMA_PORT','8080')}"
WARMING = ("The field is still gathering — Helper is loading for the first time on "
           "this worker. Give it a couple minutes and reach out again.")

def _ready():
    try:
        return requests.get(f"{LLAMA_URL}/health", timeout=3).status_code == 200
    except Exception:
        return False

def handler(event):
    if not _ready():
        yield {"delta": WARMING, "done": True, "warming": True}; return
    inp = event.get("input", {}) or {}
    messages = inp.get("messages") or ([{"role":"user","content":inp["prompt"]}] if "prompt" in inp else None)
    if not messages:
        yield {"error": "input must contain 'messages' or 'prompt'", "done": True}; return
    opts = inp.get("options", {}) or {}
    payload = {"messages": messages, "stream": True, "temperature": opts.get("temperature", 0.7)}
    np = opts.get("num_predict")
    if isinstance(np, int) and np > 0: payload["max_tokens"] = np
    if inp.get("tools"): payload["tools"] = inp["tools"]
    payload["chat_template_kwargs"] = {"enable_thinking": False}  # Qwen3.6: answer in content, not <think>
    try:
        with requests.post(f"{LLAMA_URL}/v1/chat/completions", json=payload, stream=True, timeout=600) as resp:
            resp.raise_for_status(); acc=[]
            for raw in resp.iter_lines():
                if not raw: continue
                line = raw.decode("utf-8","ignore")
                if not line.startswith("data: "): continue
                data = line[6:]
                if data.strip() == "[DONE]":
                    yield {"delta":"","done":True,"full_text":"".join(acc)}; return
                try: chunk = json.loads(data)
                except json.JSONDecodeError: continue
                _d = (chunk.get("choices") or [{}])[0].get("delta",{})
                delta = _d.get("content","") or _d.get("reasoning_content","")
                if delta: acc.append(delta); yield {"delta": delta, "done": False}
            yield {"delta":"","done":True,"full_text":"".join(acc)}
    except requests.exceptions.RequestException as e:
        yield {"error": f"llama-server request failed: {e}", "done": True}

if __name__ == "__main__":
    runpod.serverless.start({"handler": handler, "return_aggregate_stream": True})
