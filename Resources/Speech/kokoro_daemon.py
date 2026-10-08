"""Transcriptaze's reading voice: Kokoro-82M through the official `kokoro`
package (the same pipeline Pendragon runs), as a long-lived helper.

One JSON request per line on stdin:  {"id", "text", "voice", "speed", "output"}
One JSON answer per line on stdout:  {"id", "ok", "path"} or {"id", "ok": false, "error"}
A request with "cmd": "warmup" loads the model and answers {"id", "ok"}.

KOKORO_MODEL_DIR, when set, holds kokoro-v1_0.pth, config.json and voices/*.pt,
so nothing is fetched from the network.
"""
import json, os, sys, types

# misaki imports espeakng_loader even for English; stub it so the GPL package isn't needed.
_stub = types.ModuleType("espeakng_loader")
_stub.get_data_path = lambda: ""
_stub.get_library_path = lambda: ""
sys.modules.setdefault("espeakng_loader", _stub)

_model_dir = os.environ.get("KOKORO_MODEL_DIR", "")
if _model_dir:
    import huggingface_hub as _hf
    _download = _hf.hf_hub_download
    def _local_first(repo_id, filename, **kw):
        local = os.path.join(_model_dir, filename)
        return local if os.path.exists(local) else _download(repo_id=repo_id, filename=filename, **kw)
    _hf.hf_hub_download = _local_first

SAMPLE_RATE = 24000
_pipeline = None

def pipeline():
    global _pipeline
    if _pipeline is None:
        from kokoro import KPipeline
        _pipeline = KPipeline(lang_code="a", repo_id="hexgrad/Kokoro-82M")
    return _pipeline

def generate(req):
    import numpy as np
    import soundfile as sf
    text = req.get("text", "").strip()
    if not text:
        return {"ok": False, "error": "empty text"}
    parts = [r.audio.numpy() for r in pipeline()(text, voice=req.get("voice", "af_heart"), speed=float(req.get("speed", 1.0))) if r.audio is not None]
    if not parts:
        return {"ok": False, "error": "no audio"}
    sf.write(req["output"], np.concatenate(parts), SAMPLE_RATE)
    return {"ok": True, "path": req["output"]}

for line in sys.stdin:
    line = line.strip()
    if not line:
        continue
    try:
        req = json.loads(line)
    except Exception as e:
        print(json.dumps({"id": "", "ok": False, "error": str(e)}), flush=True)
        continue
    try:
        if req.get("cmd") == "warmup":
            pipeline()
            answer = {"ok": True}
        else:
            answer = generate(req)
    except Exception as e:
        answer = {"ok": False, "error": str(e)}
    answer["id"] = req.get("id", "")
    print(json.dumps(answer), flush=True)
