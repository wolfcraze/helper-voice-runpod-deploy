"""RunPod handler with a readiness gate: returns 'warming up' until the background
bootstrap (download + ollama create) finishes, so the worker stays healthy during
first-cold-start model load."""
import json, os, requests, runpod
OLLAMA_URL = "http://127.0.0.1:11434"
MODEL_NAME = os.environ.get("HELPER_MODEL_NAME", "helper-voice-v1")
READY = "/tmp/model_ready"
WARMING = ("The field is still gathering — Helper is loading for the first time on "
           "this worker. Give it a couple of minutes and reach out again.")

def handler(event):
    if not os.path.exists(READY):
        yield {"delta": WARMING, "done": True, "warming": True}
        return
    inp = event.get("input", {}) or {}
    messages = inp.get("messages") or ([{"role":"user","content":inp["prompt"]}] if "prompt" in inp else None)
    if not messages:
        yield {"error": "input must contain 'messages' or 'prompt'", "done": True}; return
    payload = {"model": MODEL_NAME, "messages": messages, "stream": True, "options": inp.get("options", {})}
    try:
        with requests.post(f"{OLLAMA_URL}/api/chat", json=payload, stream=True, timeout=600) as resp:
            resp.raise_for_status(); acc=[]
            for raw in resp.iter_lines():
                if not raw: continue
                try: chunk=json.loads(raw)
                except json.JSONDecodeError: continue
                delta=(chunk.get("message") or {}).get("content","")
                if delta: acc.append(delta); yield {"delta": delta, "done": False}
                if chunk.get("done"):
                    yield {"delta":"","done":True,"eval_count":chunk.get("eval_count",0),"full_text":"".join(acc)}; return
    except requests.exceptions.RequestException as e:
        yield {"error": f"ollama request failed: {e}", "done": True}

if __name__ == "__main__":
    runpod.serverless.start({"handler": handler, "return_aggregate_stream": True})
