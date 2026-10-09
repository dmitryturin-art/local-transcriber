from pathlib import Path
import json
import numpy as np
import onnxruntime as ort


class GigaAM:
    """Прямой запуск локального RNNT-экспорта GigaAM v3 без PyTorch."""

    def __init__(self, models: Path, threads: int, check_cancel):
        ort.disable_telemetry_events()
        options = ort.SessionOptions()
        options.intra_op_num_threads = threads
        self.encoder, self.decoder, self.joint = [
            ort.InferenceSession(str(models / f"v3_rnnt_{name}.onnx"),
                                 sess_options=options, providers=["CPUExecutionProvider"])
            for name in ("encoder", "decoder", "joint")
        ]
        config = json.loads((models / "features.json").read_text()) if (models / "features.json").exists() else {}
        self.e2e = (models / "tokenizer.model").exists()
        self.tokenizer = None
        if self.e2e:
            import sentencepiece as sp
            self.tokenizer = sp.SentencePieceProcessor(model_file=str(models / "tokenizer.model"))
            self.blank = self.tokenizer.get_piece_size()
            self.model_name = "GigaAM v3 E2E"
        else:
            self.vocab = [line.split()[0] for line in (models / "v3_vocab.txt").read_text().splitlines()]
            self.blank = 33
            self.model_name = "GigaAM v3 RNNT"
        self.decoder_inputs = [item.name for item in self.decoder.get_inputs()]
        self.n_fft = config.get("n_fft", 400)
        self.hop = config.get("hop_length", 160)
        self.center = config.get("center", True)
        self.check_cancel = check_cancel
        # Совпадает с torchaudio MelSpectrogram в оригинальном GigaAM.
        points = 700 * (10 ** (np.linspace(0, 2595 * np.log10(1 + 8000 / 700), 66) / 2595) - 1)
        frequencies = np.linspace(0, 8000, self.n_fft // 2 + 1)[:, None]
        slopes = points[None, :] - frequencies
        widths = np.diff(points)
        self.filters = np.maximum(0, np.minimum(-slopes[:, :-2] / widths[:-1],
                                                slopes[:, 2:] / widths[1:])).astype(np.float32)
        self.window = np.hanning(self.n_fft + 1)[:-1].astype(np.float32)

    def transcribe(self, audio):
        self.check_cancel()
        if self.center:
            audio = np.pad(audio, (self.n_fft // 2, self.n_fft // 2), mode="reflect")
        if len(audio) < self.n_fft:
            audio = np.pad(audio, (0, self.n_fft - len(audio)))
        frames = np.lib.stride_tricks.sliding_window_view(audio, self.n_fft)[::self.hop]
        spectrum = np.abs(np.fft.rfft(frames * self.window, axis=1)) ** 2
        features = np.log(np.clip(spectrum @ self.filters, 1e-9, 1e9)).T.astype(np.float32)[None]
        encoded, length = self.encoder.run(None, {
            "audio_signal": features, "length": np.array([features.shape[-1]], dtype=np.int64)})
        h = np.zeros((1, 1, 320), dtype=np.float32)
        c = h.copy()
        def decode(label, h, c):
            return self.decoder.run(None, dict(zip(self.decoder_inputs,
                [np.array([[label]], dtype=np.int64), h, c])))
        d, h, c = decode(self.blank, h, c)
        tokens = []
        token_times = []
        duration = len(audio)/16000
        for t in range(int(length[0])):
            if t % 16 == 0:
                self.check_cancel()
            for _ in range(10):
                logits = self.joint.run(None, {"enc": encoded[:, :, t:t + 1],
                                               "dec": d.transpose(0, 2, 1)})[0]
                token = int(logits.argmax())
                if token == self.blank:
                    break
                tokens.append(token)
                token_times.append(min(duration, t * .04))
                d, h, c = decode(token, h, c)
        if self.tokenizer is not None:
            text = self.tokenizer.decode(tokens).strip()
            pieces = [self.tokenizer.id_to_piece(token) for token in tokens]
            decoder = self.tokenizer.decode
        else:
            text = "".join(self.vocab[token] for token in tokens).replace("▁", " ").strip()
            pieces = [self.vocab[token] for token in tokens]
            decoder = lambda ids: ''.join(self.vocab[i] for i in ids).replace('▁',' ').strip()
        self.last_words = []
        ids=[]; first=last=0.0
        for token,piece,when in zip(tokens,pieces,token_times):
            if piece.startswith('▁') and ids:
                word=decoder(ids).strip()
                if word: self.last_words.append(dict(text=word,start=max(0,first-.08),end=min(duration,max(first+.04,last+.10))))
                ids=[]
            if not ids: first=when
            ids.append(token);last=when
        if ids:
            word=decoder(ids).strip()
            if word:self.last_words.append(dict(text=word,start=max(0,first-.08),end=min(duration,max(first+.04,last+.10))))
        return text


class Parakeet:
    def __init__(self, models: Path, native: Path, check_cancel, language=None):
        import os
        # Явный путь исключает зависимость от установки Handy и поиска в интернете.
        if (native / "libtranscribe.dylib").exists():
            os.environ["TRANSCRIBE_LIBRARY"] = str(native / "libtranscribe.dylib")
        import transcribe_cpp
        self.model = transcribe_cpp.Model(str(models / "parakeet-tdt-0.6b-v3-Q8_0.gguf"))
        self.session = self.model.session()
        self.check_cancel = check_cancel
        self.language = language

    def transcribe(self, audio):
        self.check_cancel()
        result = self.session.run(np.ascontiguousarray(audio, dtype=np.float32), language=self.language, timestamps='word')
        self.last_words = [dict(text=w.text,start=w.t0_ms/1000,end=w.t1_ms/1000) for w in result.words]
        self.check_cancel()
        return result.text.strip()

    def cancel(self):
        self.session.cancel()

    def close(self):
        # Освобождаем Metal-ресурсы до завершения Python, а не через деструктор.
        self.session.close()
        self.model.close()
