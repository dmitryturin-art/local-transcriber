"""Процесс обработки. Общение с окном приложения — JSON-строками, без сервера."""
import argparse
import json
import math
import os
from pathlib import Path
import signal
import subprocess
import sys
import tempfile
import time
import traceback
import uuid
import re
from datetime import datetime

import numpy as np
import soundfile as sf
import sherpa_onnx as sh

from backend.asr import GigaAM, Parakeet
from backend.export import merge_turns, write_exports
from backend.speakers import assign_speakers, normalize, uncovered
from backend.alignment import union_intervals, assign_words

SR = 16000
cancelled = False
child = None
recognizer = None


class Cancelled(Exception):
    pass


def emit(kind, **values):
    print(json.dumps({"type": kind, **values}, ensure_ascii=False), flush=True)


def check_cancel():
    if cancelled:
        raise Cancelled()


def cancel_handler(_signum, _frame):
    global cancelled
    cancelled = True
    if child is not None and child.poll() is None:
        child.terminate()
    # ctypes-вызов Parakeet отменяет отдельный поток: обработчик Python
    # может выполниться только после возврата из нативного вызова.


def split_interval(start, end, samples, offset):
    """Ограничение 25 секунд; разрез по тихому месту около конца фрагмента."""
    while end - start > 25:
        a = max(0, round((start + 21 - offset) * SR))
        b = min(len(samples), round((start + 25 - offset) * SR))
        block = samples[a:b]
        frames = len(block) // 320
        if frames:
            energy = np.mean(block[:frames * 320].reshape(frames, 320) ** 2, axis=1)
            stop = offset + (a + int(np.argmin(energy)) * 320 + 160) / SR
        else:
            stop = start + 25
        yield start, stop
        start = stop
    if end - start >= .15:
        yield start, end


def validate_resources(resources, model, diarize, models=None):
    models = models or resources/'models'
    required = ["bin/ffmpeg", "bin/ffprobe", "models/silero_vad.onnx"]
    if model == "gigaam":
        folder = "gigaam-e2e" if (models / "gigaam-e2e").exists() else "gigaam"
        required += [f"models/{folder}/tokenizer.model" if folder == "gigaam-e2e" else f"models/{folder}/v3_vocab.txt"]
        if folder == "gigaam-e2e":
            required += [f"models/{folder}/features.json"]
        required += [f"models/{folder}/v3_rnnt_{n}.onnx" for n in ("encoder", "decoder", "joint")]
    elif model == "parakeet":
        required += ["models/parakeet/parakeet-tdt-0.6b-v3-Q8_0.gguf"]
    else:
        raise ValueError("Неизвестная модель распознавания")
    if diarize:
        required += ["models/segmentation.onnx", "models/speaker.onnx"]
    missing = [name for name in required if not ((models/name.removeprefix('models/')) if name.startswith('models/') else resources/name).is_file()]
    if missing:
        raise RuntimeError("В приложении не хватает файлов: " + ", ".join(missing))


def convert(source, wav, resources):
    global child
    probe = subprocess.run([str(resources / "bin/ffprobe"), "-v", "error", "-show_entries",
                            "format=duration", "-of", "json", str(source)],
                           capture_output=True, text=True)
    check_cancel()
    duration = 0.0
    if probe.returncode == 0:
        try:
            duration = float(json.loads(probe.stdout)["format"]["duration"])
        except (ValueError, KeyError):
            pass
    # RF64 автоматически снимает ограничение WAV в 4 ГБ.
    with tempfile.TemporaryFile(mode="w+b") as errors:
        child = subprocess.Popen([str(resources / "bin/ffmpeg"), "-nostdin", "-v", "error",
                                  "-i", str(source), "-vn", "-ac", "1", "-ar", str(SR),
                                  "-c:a", "pcm_s16le", "-rf64", "auto", "-progress", "pipe:1",
                                  "-y", str(wav)], stdout=subprocess.PIPE, stderr=errors, text=True)
        try:
            for line in child.stdout:
                check_cancel()
                if line.startswith("out_time_us=") and duration > 0:
                    try:
                        ratio = float(line.split("=", 1)[1]) / 1e6 / duration
                        emit("progress", progress=min(10, ratio * 10), status="Подготовка записи…")
                    except ValueError:
                        pass
            code = child.wait()
            check_cancel()
            if code:
                errors.seek(0)
                message = errors.read().decode("utf-8", errors="replace")[-2000:]
                raise RuntimeError("Не удалось прочитать запись. " + message)
        finally:
            if child.poll() is None:
                child.terminate()
                child.wait()
            child = None


def make_vad(resources, threads, models=None):
    models = models or resources/'models'
    return sh.VoiceActivityDetector(sh.VadModelConfig(
        silero_vad=sh.SileroVadModelConfig(model=str(models / "silero_vad.onnx"),
            threshold=.30, min_silence_duration=.35, min_speech_duration=.15,
            max_speech_duration=25), sample_rate=SR, num_threads=threads),
        buffer_size_in_seconds=60)


def vad_intervals(vad, samples):
    vad.reset()
    segments = []
    def drain():
        while not vad.empty():
            z = vad.front
            segments.append((z.start / SR, (z.start + len(z.samples)) / SR))
            vad.pop()
    for start in range(0, len(samples), 512):
        check_cancel()
        data = samples[start:start + 512]
        if len(data) < 512:
            data = np.pad(data, (0, 512 - len(data)))
        vad.accept_waveform(data)
        drain()
    vad.flush()
    drain()
    return [(max(0, a - .1), min(len(samples) / SR, b + .1)) for a, b in segments]


def run(request, resources):
    global recognizer
    source = Path(request["input"]).expanduser().resolve()
    destination = Path(request["output"]).expanduser().resolve()
    model = request.get("model", "gigaam")
    models = Path(request.get('models', resources/'models')).expanduser().resolve()
    language = request.get('language', 'ru')
    if language not in ('ru','en','auto'): raise ValueError('Неизвестный ожидаемый язык')
    if model == 'gigaam' and language == 'en': raise ValueError('Для английской речи выберите Parakeet')
    diarize = bool(request.get("diarize", True))
    count = int(request.get("speakers", 0))
    if count not in range(0, 9):
        raise ValueError("Число спикеров должно быть от 1 до 8, либо 0 для автоопределения")
    if not source.is_file():
        raise ValueError("Файл записи не найден")
    destination.mkdir(parents=True, exist_ok=True)
    validate_resources(resources, model, diarize, models)
    threads = min(4, max(1, (os.cpu_count() or 4) // 2))
    # Параметр блока вынесен для проверки длинных файлов на коротких фикстурах.
    block_seconds = float(request.get("block_seconds", 300))
    if not 15 <= block_seconds <= 600:
        raise ValueError("Недопустимая длительность блока")
    begin = time.monotonic()
    with tempfile.TemporaryDirectory(prefix="local-transcriber-") as temporary:
        wav = Path(temporary) / "audio.wav"
        emit("progress", progress=0, status="Подготовка записи…")
        convert(source, wav, resources)
        info = sf.info(str(wav))
        duration = info.frames / SR
        if not info.frames:
            raise ValueError("В записи нет аудиоданных")
        emit("progress", progress=10, status="Загрузка локальной модели…", duration=duration)
        if model == "gigaam":
            folder = "gigaam-e2e" if (models / "gigaam-e2e").exists() else "gigaam"
            recognizer = GigaAM(models / folder, threads, check_cancel)
        else:
            recognizer = Parakeet(models / "parakeet", resources / "native", check_cancel, language=None if language=='auto' else language)
        vad = make_vad(resources, threads, models)
        diarizer = extractor = None
        if diarize:
            config = sh.OfflineSpeakerDiarizationConfig(
                segmentation=sh.OfflineSpeakerSegmentationModelConfig(
                    pyannote=sh.OfflineSpeakerSegmentationPyannoteModelConfig(
                        model=str(models / "segmentation.onnx")), num_threads=threads),
                embedding=sh.SpeakerEmbeddingExtractorConfig(
                    model=str(models / "speaker.onnx"), num_threads=threads),
                # Здесь выделяются локальные смены голосов; итоговое число
                # спикеров задаётся только при общей кластеризации ниже.
                clustering=sh.FastClusteringConfig(num_clusters=-1, threshold=.5),
                min_duration_on=.2, min_duration_off=.3)
            diarizer = sh.OfflineSpeakerDiarization(config)
            extractor = sh.SpeakerEmbeddingExtractor(config.embedding)
        rows = []
        block_count = math.ceil(duration / block_seconds)
        with sf.SoundFile(str(wav)) as audio:
            for index in range(block_count):
                check_cancel()
                core_start = index * block_seconds
                core_end = min(duration, core_start + block_seconds)
                offset = max(0, core_start - 5)
                end = min(duration, core_end + 5)
                audio.seek(round(offset * SR))
                samples = audio.read(round((end - offset) * SR), dtype="float32")
                def progress(processed, total):
                    emit("progress", progress=15 + 75 * (index + .2 * processed / max(1, total)) / block_count,
                         status=f"Разделение голосов · часть {index + 1} из {block_count}")
                    return int(cancelled)
                if diarizer:
                    result = diarizer.process(samples, progress)
                    check_cancel()
                    local = [{"start": offset + z.start, "end": offset + z.end,
                              "local_speaker": z.speaker, "recovered": False}
                             for z in result.sort_by_start_time()]
                else:
                    local = [{"start": offset + a, "end": offset + b, "recovered": False}
                             for a, b in vad_intervals(vad, samples)]
                # Тихий телефонный голос часто отсутствует в сегментации:
                # проверяем остаток записи распознаванием, как в исходной встрече.
                gaps = uncovered([(z["start"] - offset, z["end"] - offset) for z in local], len(samples) / SR)
                local += [{"start": offset + a, "end": offset + b, "recovered": True} for a, b in gaps]
                local.sort(key=lambda z: z["start"])
                pieces = []
                for z in local:
                    a, b = max(core_start, z["start"]), min(core_end, z["end"])
                    if b - a < .15:
                        continue
                    overlap = any(other is not z and not other.get("recovered")
                                  and min(b, other["end"]) - max(a, other["start"]) > .25
                                  for other in local)
                    for first, last in split_interval(a, b, samples, offset):
                        pieces.append({"start": first, "end": last, "recovered": z["recovered"],
                                       "overlap": overlap})
                for number, z in enumerate(pieces):
                    check_cancel()
                    a = max(0, round((z["start"] - offset) * SR))
                    b = min(len(samples), round((z["end"] - offset) * SR))
                    sample = samples[a:b]
                    # Только практически цифровая тишина отсекается по уровню.
                    if not len(sample) or float(np.sqrt(np.mean(sample ** 2))) < .00002:
                        continue
                    text = recognizer.transcribe(sample)
                    if not text:
                        continue
                    row = {**z, "text": text, "embedding": None, 'language_warning': language_warning(text, language)}
                    if extractor:
                        stream = extractor.create_stream()
                        # У длинной реплики центральные 8 секунд достаточно
                        # описывают голос и не раздувают вычисления.
                        middle = len(sample) // 2
                        example = sample[max(0, middle - 4 * SR):middle + 4 * SR]
                        stream.accept_waveform(SR, example)
                        stream.input_finished()
                        if extractor.is_ready(stream):
                            row["embedding"] = normalize(extractor.compute(stream)).tolist()
                    rows.append(row)
                    percent = 15 + 75 * (index + .2 + .8 * (number + 1) / max(1, len(pieces))) / block_count
                    emit("segment", text=text, start=z["start"], segments=len(rows))
                    elapsed = time.monotonic() - begin
                    processed_audio = core_start + (core_end - core_start) * (number + 1) / max(1, len(pieces))
                    remaining = elapsed * max(0, duration - processed_audio) / max(1, processed_audio)
                    emit("progress", progress=percent, status=f"Распознавание · часть {index + 1} из {block_count}",
                         eta=round(remaining) if processed_audio > 30 else None)
                # Контрольная точка на диске, без хранения аудио целиком в памяти.
                Path(temporary, "checkpoint.json").write_text(json.dumps(rows, ensure_ascii=False))
        check_cancel()
        if not rows:
            raise ValueError("Речь не обнаружена. Проверьте выбранную запись и её громкость.")
        rows.sort(key=lambda z: z["start"])
        speaker_count = 0
        speaker_diagnostics = {}
        if diarize:
            emit("progress", progress=92, status="Объединение голосов по всей записи…")
            speaker_count = assign_speakers(rows, count, diagnostics=speaker_diagnostics)
        segments = merge_turns(rows, keep_embeddings=diarize)
        emit("progress", progress=97, status="Сохранение транскрипции…")
        document = {"version": 1, "source": source.name, "model": recognizer.model_name if model == "gigaam" else "Parakeet v3 Q8_0",
                    "duration": duration, "diarized": diarize, "speaker_count": speaker_count,
                    "requested_speakers": count, "names": {}, "segments": segments,
                    'expected_language': language, 'speaker_diagnostics': speaker_diagnostics,
                    "processing_seconds": round(time.monotonic() - begin, 1)}
        safe_name = source.stem[:80]
        folder = destination / f"{safe_name} — {datetime.now().strftime('%Y-%m-%d %H-%M')} — {uuid.uuid4().hex[:6]}"
        check_cancel()
        folder.mkdir(parents=True, exist_ok=True)
        if diarize:
            dim = extractor.dim
            vectors = np.asarray([z.pop('embedding', None) or [0.0]*dim for z in segments], dtype=np.float32)
            np.savez_compressed(folder/'voiceprints.npz', vectors=vectors, starts=[z['start'] for z in segments], ends=[z['end'] for z in segments])
        for z in segments: z.pop('_weight', None)
        output = write_exports(document, folder)
        emit("complete", progress=100, result=str(output), folder=str(folder), speaker_count=speaker_count,
             uncertain=sum(bool(z.get("uncertain")) for z in segments), seconds=document["processing_seconds"])


def language_warning(text, language):
    if language == 'auto': return False
    latin = re.findall(r'[A-Za-z]+', text)
    cyrillic = re.findall(r'[А-Яа-яЁё]+', text)
    if language == 'en': return bool(cyrillic) and len(cyrillic)>len(latin)
    odd = re.search(r'\b(?:yeah|yeeh|hmm|uh|no|okay)\b', text, re.I)
    return bool(odd) or (len(latin)>0 and len(latin)>2*len(cyrillic))


def run_aligned(request, resources):
    """ASR выполняется один раз; слова связываются с временными участками голосов."""
    global recognizer
    source=Path(request['input']).expanduser().resolve()
    destination=Path(request['output']).expanduser().resolve()
    models=Path(request.get('models', resources/'models')).expanduser().resolve()
    model=request.get('model','gigaam');language=request.get('language','ru');count=int(request.get('speakers',0))
    if language not in ('ru','en','auto') or count not in range(9):raise ValueError('Неверные параметры языка или спикеров')
    if model=='gigaam' and language=='en':raise ValueError('Для английской речи выберите Parakeet')
    validate_resources(resources,model,True,models)
    destination.mkdir(parents=True,exist_ok=True)
    threads=4;block=float(request.get('block_seconds',300));begin=time.monotonic()
    if not 15<=block<=600:raise ValueError('Неверная длительность блока')
    with tempfile.TemporaryDirectory(prefix='local-transcriber-') as tmp:
        wav=Path(tmp)/'audio.wav';emit('progress',progress=0,status='Подготовка записи…');convert(source,wav,resources)
        duration=sf.info(wav).duration
        emit('progress',progress=10,status='Загрузка модели и точная привязка слов…')
        if model=='gigaam':recognizer=GigaAM(models/'gigaam-e2e',threads,check_cancel)
        else:recognizer=Parakeet(models/'parakeet',resources/'native',check_cancel,language=None if language=='auto' else language)
        vad=make_vad(resources,threads,models)
        config=sh.OfflineSpeakerDiarizationConfig(
            segmentation=sh.OfflineSpeakerSegmentationModelConfig(pyannote=sh.OfflineSpeakerSegmentationPyannoteModelConfig(model=str(models/'segmentation.onnx')),num_threads=threads),
            embedding=sh.SpeakerEmbeddingExtractorConfig(model=str(models/'speaker.onnx'),num_threads=threads),
            clustering=sh.FastClusteringConfig(num_clusters=count if count else -1,threshold=.5),min_duration_on=.2,min_duration_off=.3)
        diarizer=sh.OfflineSpeakerDiarization(config);extractor=sh.SpeakerEmbeddingExtractor(config.embedding)
        turns=[];words=[];blocks=math.ceil(duration/block)
        with sf.SoundFile(wav) as audio:
            for index in range(blocks):
                check_cancel();core_start=index*block;core_end=min(duration,core_start+block)
                offset=max(0,core_start-5);stop=min(duration,core_end+5)
                audio.seek(round(offset*SR));samples=audio.read(round((stop-offset)*SR),dtype='float32')
                def progress(n,total):
                    emit('progress',progress=15+75*(index+.2*n/max(1,total))/blocks,status=f'Границы голосов · часть {index+1} из {blocks}')
                    return int(cancelled)
                local=[dict(start=offset+z.start,end=offset+z.end,local_key=f'{index}:{z.speaker}',recovered=False)
                    for z in diarizer.process(samples,progress).sort_by_start_time()]
                check_cancel()
                speech=vad_intervals(vad,samples)
                # Нормализуем тихие пропуски только для VAD, аудио ASR оставляем исходным.
                gaps=uncovered([(z['start']-offset,z['end']-offset) for z in local],len(samples)/SR)
                for a,b in gaps:
                    if b-a<.7:continue
                    sample=samples[round(a*SR):round(b*SR)]
                    if len(sample)<512:continue
                    peak=float(np.quantile(np.abs(sample),.99))
                    if peak<.0001:continue
                    normalized=np.clip(sample*min(6,.15/max(peak,.0001)),-1,1)
                    quiet=vad_intervals(vad,normalized)
                    for first,last in quiet:
                        speech.append((a+first,a+last))
                        local.append(dict(start=offset+a+first,end=offset+a+last,recovered=True))
                for turn in local:
                    a=max(core_start,turn['start']);b=min(core_end,turn['end'])
                    if b-a<.15:continue
                    turn=dict(turn,start=a,end=b,text='')
                    turn['overlap']=any(other is not turn and other.get('local_key')!=turn.get('local_key')
                        and not other.get('recovered') and min(b,other['end'])-max(a,other['start'])>.25 for other in local)
                    mid=(a+b)/2;first=max(a,mid-4);last=min(b,mid+4)
                    sample=samples[round((first-offset)*SR):round((last-offset)*SR)]
                    stream=extractor.create_stream();stream.accept_waveform(SR,sample);stream.input_finished()
                    turn['embedding']=normalize(extractor.compute(stream)).tolist() if extractor.is_ready(stream) else None
                    turns.append(turn)
                regions=union_intervals([(offset+a,offset+b) for a,b in speech]+[(z['start'],z['end']) for z in local])
                pieces=[]
                for a,b in regions:pieces.extend(split_interval(max(core_start,a),min(core_end,b),samples,offset))
                for part,(a,b) in enumerate(pieces):
                    check_cancel()
                    first=max(offset,a-.25);last=min(stop,b+.25)
                    sample=samples[round((first-offset)*SR):round((last-offset)*SR)]
                    if len(sample)<320:continue
                    text=recognizer.transcribe(sample)
                    timed=getattr(recognizer,'last_words',[])
                    if not timed and text:timed=[dict(start=a-first,end=b-first,text=text)]
                    for word in timed:
                        start=first+word['start'];end=first+word['end'];mid=(start+end)/2
                        if not a<=mid<b:continue
                        words.append(dict(start=max(0,start),end=min(duration,end),text=word['text'],language_warning=language_warning(word['text'],language)))
                    emit('segment',text=text,start=a,segments=len(words))
                    emit('progress',progress=15+75*(index+.2+.8*(part+1)/max(1,len(pieces)))/blocks,status=f'Текст и времена слов · часть {index+1} из {blocks}')
        check_cancel()
        if not words:raise ValueError('Речь не обнаружена')
        turns.sort(key=lambda z:z['start']);diagnostics={}
        emit('progress',progress=92,status='Сопоставление голосов с целостными репликами…')
        actual=assign_speakers(turns,count,diagnostics=diagnostics)
        rows=assign_words(words,turns)
        folder=destination/f"{source.stem[:80]} — {datetime.now().strftime('%Y-%m-%d %H-%M')} — {uuid.uuid4().hex[:6]}"
        folder.mkdir(parents=True,exist_ok=True)
        vectors=np.asarray([z.pop('embedding',None) or [0.0]*extractor.dim for z in rows],dtype=np.float32)
        np.savez_compressed(folder/'voiceprints.npz',vectors=vectors,starts=[z['start'] for z in rows],ends=[z['end'] for z in rows])
        document=dict(version=2,source=source.name,model=recognizer.model_name if model=='gigaam' else 'Parakeet v3 Q8_0',
            duration=duration,diarized=True,speaker_count=actual,requested_speakers=count,names={},segments=rows,
            expected_language=language,speaker_diagnostics=diagnostics,processing_seconds=round(time.monotonic()-begin,1),
            diarization_method='word-aligned-single-ASR-pass',unassigned_segments=sum(z.get('speaker') is None for z in rows))
        output=write_exports(document,folder)
        emit('complete',progress=100,result=str(output),folder=str(folder),speaker_count=actual,
            uncertain=sum(bool(z.get('uncertain')) for z in rows),seconds=document['processing_seconds'])


def recluster(request, resources):
    models = Path(request.get('models', resources/'models'))
    document = json.loads(Path(request['document']).read_text())
    cache = Path(request.get('voiceprints', ''))
    rows = [dict(z, embedding=None) for z in document['segments']]
    cached = False
    if cache.is_file():
        with np.load(cache, allow_pickle=False) as data:
            if len(data['vectors']) == len(rows) and np.allclose(data['starts'], [z['start'] for z in rows]) and np.allclose(data['ends'], [z['end'] for z in rows]):
                for row, vector in zip(rows, data['vectors']): row['embedding'] = vector.tolist() if np.linalg.norm(vector)>1e-6 else None
                cached = True
    if not cached:
        if not request.get('input'): raise ValueError('Для старой транскрипции укажите исходную запись')
        if not (models/'speaker.onnx').is_file(): raise ValueError('Загрузите компоненты диаризации')
        emit('progress',progress=0,status='Подготовка голосов без повторного распознавания…')
        with tempfile.TemporaryDirectory(prefix='local-transcriber-voices-') as tmp:
            wav=Path(tmp)/'audio.wav'; convert(Path(request['input']), wav, resources)
            extractor=sh.SpeakerEmbeddingExtractor(sh.SpeakerEmbeddingExtractorConfig(model=str(models/'speaker.onnx'),num_threads=4))
            with sf.SoundFile(wav) as audio:
                for i,row in enumerate(rows):
                    check_cancel();a,b=row['start'],row['end'];mid=(a+b)/2;a=max(a,mid-4);b=min(b,mid+4)
                    audio.seek(round(a*SR)); sample=audio.read(max(1,round((b-a)*SR)),dtype='float32')
                    stream=extractor.create_stream();stream.accept_waveform(SR,sample);stream.input_finished()
                    if extractor.is_ready(stream): row['embedding']=normalize(extractor.compute(stream)).tolist()
                    if i%10==0: emit('progress',progress=10+80*(i+1)/len(rows),status='Сравнение голосов…')
    diagnostics={};count=assign_speakers(rows,int(request.get('speakers',0)),diagnostics=diagnostics)
    for row in rows: row.pop('embedding',None)
    document.update(segments=rows,speaker_count=count,names={},requested_speakers=int(request.get('speakers',0)),speaker_diagnostics=diagnostics)
    result=Path(request['result']);result.write_text(json.dumps(document,ensure_ascii=False))
    emit('recluster_complete',result=str(result),speaker_count=count,progress=100)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--request", type=Path, required=True)
    parser.add_argument("--resources", type=Path, required=True)
    args = parser.parse_args()
    signal.signal(signal.SIGTERM, cancel_handler)
    signal.signal(signal.SIGINT, cancel_handler)
    try:
        request = json.loads(args.request.read_text())
        if request.get('action') == 'recluster': recluster(request, args.resources.resolve())
        elif request.get('diarize',True):run_aligned(request,args.resources.resolve())
        else: run(request, args.resources.resolve())
    except Cancelled:
        emit("cancelled", status="Обработка отменена")
        return 0
    except Exception as exc:
        traceback.print_exc(file=sys.stderr)
        emit("error", message=str(exc) or type(exc).__name__)
        return 1
    finally:
        if recognizer is not None and hasattr(recognizer, "close"):
            recognizer.close()
    return 0


if __name__ == "__main__":
    sys.exit(main())
