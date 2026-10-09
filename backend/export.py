import json
from pathlib import Path


def timestamp(seconds, subtitle=False):
    millis = max(0, round(seconds * 1000))
    text = f"{millis // 3600000:02d}:{millis // 60000 % 60:02d}:{millis // 1000 % 60:02d}"
    return text + f",{millis % 1000:03d}" if subtitle else text


def merge_turns(rows):
    result = []
    for row in sorted(rows, key=lambda r: (r["start"], r["end"])):
        row = {k: v for k, v in row.items() if k != "embedding"}
        if not row["text"].strip():
            continue
        if (result and result[-1].get("speaker") == row.get("speaker")
                and not row.get("overlap") and not result[-1].get("overlap")
                and 0 <= row["start"] - result[-1]["end"] < .9
                and row["end"] - result[-1]["start"] <= 60):
            result[-1]["text"] += " " + row["text"]
            result[-1]["end"] = row["end"]
            result[-1]["uncertain"] = result[-1].get("uncertain", False) or row.get("uncertain", False)
        else:
            result.append(dict(row))
    return result


def render(document, names=None):
    names = names or document.get("names", {})
    lines = [f"Транскрипция: {document['source']}",
             f"Модель: {document['model']} · Длительность: {timestamp(document['duration'])}",
             "Автоматическая расшифровка. [?] — голос определён неуверенно; [перекрытие] — одновременная речь.", ""]
    subtitles = []
    for index, row in enumerate(document["segments"], 1):
        speaker = row.get("speaker")
        label = names.get(str(speaker), f"Спикер {speaker}") if speaker else ""
        markers = (" [?]" if row.get("uncertain") else "") + (" [перекрытие]" if row.get("overlap") else "")
        text = row["text"].strip()
        text = text[0].upper() + text[1:] if text else text
        label_text = f"{label}{markers}: " if label else ""
        lines.extend([f"[{timestamp(row['start'])}] {label_text}{text}", ""])
        subtitles.append(f"{index}\n{timestamp(row['start'], True)} --> {timestamp(row['end'], True)}\n{label_text}{text}\n")
    return "\n".join(lines), "\n".join(subtitles)


def write_exports(document, folder: Path, names=None):
    folder.mkdir(parents=True, exist_ok=True)
    if names is not None:
        document["names"] = names
    text, subtitles = render(document)
    outputs = {"transcript.txt": text, "transcript.md": "# " + text,
               "transcript.srt": subtitles, "transcript.json": json.dumps(document, ensure_ascii=False, indent=2)}
    for name, content in outputs.items():
        path = folder / name
        temporary = path.with_suffix(path.suffix + ".tmp")
        temporary.write_text(content, encoding="utf-8")
        temporary.replace(path)
    return folder / "transcript.json"
