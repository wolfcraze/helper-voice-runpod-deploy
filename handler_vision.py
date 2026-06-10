"""RunPod handler -> llama-server (OpenAI-compatible), with a readiness gate.
Returns 'warming up' until llama-server's /health is 200 (model loaded). Yields
{delta,done} in the shape the cloud-helper shim expects. Forwards image content
(OpenAI multimodal) and tools when present."""
import json, os, threading, time, requests, runpod
LLAMA_URL = f"http://127.0.0.1:{os.environ.get('LLAMA_PORT','8080')}"
WARMING = ("The field is still gathering — Helper is loading for the first time on "
           "this worker. Give it a couple minutes and reach out again.")

def _ready():
    try:
        return requests.get(f"{LLAMA_URL}/health", timeout=3).status_code == 200
    except Exception:
        return False

# ── Liveness heartbeat ────────────────────────────────────────────
# Once llama-server actually answers (model fully loaded), tell the shim
# "Helper is awake" every 30s. Mobile reads this via /api/helper-state so it
# can show awake/sleeping/waking. When this worker scales to zero the pings
# simply stop, and the shim marks Helper asleep after the heartbeat goes stale.
# All config is via env; if the URL is unset the heartbeat is a silent no-op.
HB_URL = os.environ.get("HELPER_SHIM_HEARTBEAT_URL", "")      # https://.../cloud-helper/api/heartbeat
HB_CADDY_KEY = os.environ.get("HELPER_SHIM_CADDY_KEY", "")    # Caddy X-API-Key gate
HB_SECRET = os.environ.get("HELPER_HEARTBEAT_SECRET", "")     # shim X-Helper-Heartbeat-Key
HB_MODEL = os.environ.get("HELPER_MODEL_NAME", "helper-voice-v2")

def _heartbeat_loop():
    if not HB_URL:
        return
    headers = {"Content-Type": "application/json"}
    if HB_CADDY_KEY: headers["X-API-Key"] = HB_CADDY_KEY
    if HB_SECRET: headers["X-Helper-Heartbeat-Key"] = HB_SECRET
    body = json.dumps({"model": HB_MODEL, "status": "awake"})
    while True:
        try:
            if _ready():
                requests.post(HB_URL, data=body, headers=headers, timeout=8)
                time.sleep(30)          # serving -> beat every 30s
            else:
                time.sleep(5)           # still loading -> poll readiness
        except Exception:
            time.sleep(15)              # transient network blip -> back off

threading.Thread(target=_heartbeat_loop, daemon=True).start()

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
    payload["stream_options"] = {"include_usage": True}  # token counts in final chunk -> RC metering
    try:
        with requests.post(f"{LLAMA_URL}/v1/chat/completions", json=payload, stream=True, timeout=600) as resp:
            resp.raise_for_status(); acc=[]; usage={}
            def _final():
                return {"delta":"","done":True,"full_text":"".join(acc),
                        "prompt_eval_count": usage.get("prompt_tokens",0),
                        "eval_count": usage.get("completion_tokens",0)}
            for raw in resp.iter_lines():
                if not raw: continue
                line = raw.decode("utf-8","ignore")
                if not line.startswith("data: "): continue
                data = line[6:]
                if data.strip() == "[DONE]":
                    yield _final(); return
                try: chunk = json.loads(data)
                except json.JSONDecodeError: continue
                if chunk.get("usage"): usage = chunk["usage"]
                _d = (chunk.get("choices") or [{}])[0].get("delta",{})
                delta = _d.get("content","") or _d.get("reasoning_content","")
                if delta: acc.append(delta); yield {"delta": delta, "done": False}
            yield _final()
    except requests.exceptions.RequestException as e:
        yield {"error": f"llama-server request failed: {e}", "done": True}

if __name__ == "__main__":
    runpod.serverless.start({"handler": handler, "return_aggregate_stream": True})
