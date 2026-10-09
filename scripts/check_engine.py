"""Проверка отмены и режима без спикеров на готовой автономной сборке."""
import argparse
import json
from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
parser = argparse.ArgumentParser()
parser.add_argument("audio", type=Path)
args = parser.parse_args()
resources = root / "dist/Голоса.app/Contents/Resources"
engine = resources / "engine/local-engine"
output = root / "build/engine-check-results"


def run(request, cancel=False):
    with tempfile.TemporaryDirectory() as tmp:
        path = Path(tmp) / "request.json"
        path.write_text(json.dumps(request))
        with tempfile.TemporaryFile(mode="w+") as errors:
            p = subprocess.Popen([str(engine), "--request", str(path), "--resources", str(resources)],
                                 stdout=subprocess.PIPE, stderr=errors, text=True)
            events = []
            sent = False
            for line in p.stdout:
                try:
                    event = json.loads(line)
                except ValueError:
                    continue
                events.append(event)
                if cancel and not sent and event.get("type") == "progress" and event.get("progress", 0) >= 10:
                    p.terminate()
                    sent = True
            code = p.wait(timeout=120)
            if code:
                errors.seek(0)
                raise RuntimeError(errors.read()[-3000:])
            return events


base = {"input": str(args.audio.resolve()), "output": str(output), "model": "gigaam", "speakers": 2}
before = {p for p in Path(tempfile.gettempdir()).glob("local-transcriber-*") if p.is_dir()}
events = run({**base, "diarize": True}, cancel=True)
assert any(e["type"] == "cancelled" for e in events)
after = {p for p in Path(tempfile.gettempdir()).glob("local-transcriber-*") if p.is_dir()}
assert after <= before, "После отмены осталось временное аудио"
print("Отмена и очистка временного аудио — OK", flush=True)
events = run({**base, "diarize": False, "block_seconds": 30})
complete = next(e for e in events if e["type"] == "complete")
doc = json.loads(Path(complete["result"]).read_text())
assert not doc["diarized"] and doc["speaker_count"] == 0
assert all(not row.get("speaker") for row in doc["segments"])
assert any(any(symbol in row["text"] for symbol in ".?!,") for row in doc["segments"])
print("Режим без спикеров и пунктуация — OK", flush=True)
