import json
from pathlib import Path


def timestamp(seconds, subtitle=False):
    millis = max(0, round(seconds * 1000))
    text = f"{millis // 3600000:02d}:{millis // 60000 % 60:02d}:{millis // 1000 % 60:02d}"
    return text + f",{millis % 1000:03d}" if subtitle else text


def merge_turns(rows, keep_embeddings=False):
    result = []
    for row in sorted(rows, key=lambda r: (r["start"], r["end"])):
        row = {k: v for k, v in row.items() if k != "embedding" or keep_embeddings}
        if not row["text"].strip():
            continue
        if (result and result[-1].get("speaker") == row.get("speaker")
                and not row.get("overlap") and not result[-1].get("overlap")
                and 0 <= row["start"] - result[-1]["end"] < .9
                and row["end"] - result[-1]["start"] <= 60):
            result[-1]["text"] += " " + row["text"]
            result[-1]["end"] = row["end"]
            result[-1]["uncertain"] = result[-1].get("uncertain", False) or row.get("uncertain", False)
            if keep_embeddings and row.get('embedding') is not None:
                import numpy as np
                old = result[-1].get('embedding')
                weight = result[-1].get('_weight', 0)
                current = min(8, max(.1, row['end']-row['start']))
                result[-1]['embedding'] = ((np.asarray(old)*weight+np.asarray(row['embedding'])*current)/(weight+current)).tolist() if old is not None else row['embedding']
                result[-1]['_weight'] = weight+current
        else:
            item = dict(row)
            if keep_embeddings: item['_weight'] = min(8, max(.1, row['end']-row['start'])) if row.get('embedding') is not None else 0
            result.append(item)
    return result


def render(document, names=None, include_speakers=True):
    names = names or document.get("names", {})
    title = (document.get('title') or '').strip() or Path(document['source']).stem
    lines = [f"Транскрипция: {title}", f"Исходный файл: {document['source']}",
             f"Модель: {document['model']} · Длительность: {timestamp(document['duration'])}",
             ""]
    if include_speakers: lines.insert(-1, "Автоматическая расшифровка. [?] — проверьте спикера; [перекрытие] — одновременная речь.")
    subtitles = []
    for index, row in enumerate(document["segments"], 1):
        speaker = row.get("speaker") if include_speakers else None
        label = names.get(str(speaker), f"Спикер {speaker}") if speaker else ("Спикер не определён" if include_speakers and document.get('diarized') else "")
        markers = (" [?]" if row.get("uncertain") else "") + (" [перекрытие]" if row.get("overlap") else "")
        text = row["text"].strip()
        text = text[0].upper() + text[1:] if text else text
        label_text = f"{label}{markers}: " if label else ""
        lines.extend([f"[{timestamp(row['start'])}] {label_text}{text}", ""])
        subtitles.append(f"{index}\n{timestamp(row['start'], True)} --> {timestamp(row['end'], True)}\n{label_text}{text}\n")
    return "\n".join(lines), "\n".join(subtitles)


def service_folder(folder: Path):
    service = folder / "Служебные данные"
    service.mkdir(parents=True, exist_ok=True)
    return service


def write_exports(document, folder: Path, names=None):
    folder.mkdir(parents=True, exist_ok=True)
    if names is not None:
        document["names"] = names
    text, subtitles = render(document)
    outputs = {"transcript.txt": text, "transcript.md": "# " + text,
               "transcript.srt": subtitles, "transcript.json": json.dumps(document, ensure_ascii=False, indent=2)}
    plain, plain_srt = render(document, include_speakers=False)
    outputs.update({'transcript.no-speakers.txt': plain, 'transcript.no-speakers.md': '# '+plain,
                    'transcript.no-speakers.srt': plain_srt})
    for name, content in outputs.items():
        path = (service_folder(folder) if name == "transcript.json" else folder) / name
        temporary = path.with_suffix(path.suffix + ".tmp")
        temporary.write_text(content, encoding="utf-8")
        temporary.replace(path)
    return service_folder(folder) / "transcript.json"
