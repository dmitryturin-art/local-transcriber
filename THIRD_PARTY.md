# Сторонние компоненты и модели

Аудио и пользовательские транскрипции не входят в распространяемую сборку. Ни один компонент не требует аккаунта, ключа API или скачивания модели при запуске.

## Модели

- **GigaAM v3 E2E RNNT**: [salute-developers/GigaAM](https://github.com/salute-developers/GigaAM), локальная копия checkpoint из [ai-sage/GigaAM-v3](https://huggingface.co/ai-sage/GigaAM-v3), экспортированная в ONNX без изменения весов. Лицензия и авторство: `licenses/GigaAM-LICENSE.txt`.
- **Parakeet TDT 0.6B v3 Q8_0**: модель NVIDIA, квантование [handy-computer/parakeet-tdt-0.6b-v3-gguf](https://huggingface.co/handy-computer/parakeet-tdt-0.6b-v3-gguf). Взята уже скачанная копия из кэша Handy. Карточка модели с авторами, исходной моделью и лицензией CC BY 4.0 сохранена в `licenses/Parakeet-MODEL-CARD.md`; [текст лицензии](https://creativecommons.org/licenses/by/4.0/legalcode.en).
- **Pyannote segmentation 3.0**: [pyannote/segmentation-3.0](https://huggingface.co/pyannote/segmentation-3.0), ONNX-экспорт из [Sherpa-ONNX](https://github.com/k2-fsa/sherpa-onnx/releases/tag/speaker-segmentation-models). Лицензия из архива сохранена в `licenses/Pyannote-LICENSE.txt`.
- **3D-Speaker CAM++**: [modelscope/3D-Speaker](https://github.com/modelscope/3D-Speaker), `3dspeaker_speech_campplus_sv_zh_en_16k-common_advanced.onnx`. Лицензия Apache 2.0 сохранена в `licenses/3D-Speaker-LICENSE.txt`.
- **Silero VAD**: [snakers4/silero-vad](https://github.com/snakers4/silero-vad), ONNX-модель из [Sherpa-ONNX](https://github.com/k2-fsa/sherpa-onnx/releases/tag/asr-models).

## Программные компоненты

ONNX Runtime, Sherpa-ONNX, transcribe.cpp и его ggml backend, NumPy, SciPy, SoundFile/libsndfile, SentencePiece, CFFI, PyInstaller и Python включены вместе с локальным движком. Лицензии, доступные в установленных пакетах, сохранены в подпапках `licenses/`. [transcribe.cpp](https://github.com/handy-computer/transcribe.cpp) — MIT.

FFmpeg 8.0.1 и FFprobe собраны из официальных исходников с отключённой сетью и автоматическим подключением внешних библиотек. Включено распознавание контейнеров и декодирование; единственный нужный приложению выходной кодек — PCM s16le. Сборка без GPL и nonfree-компонентов. Архив исходников, LGPL и точные параметры сборки включены в `licenses/FFmpeg/`, а воспроизводимый сборщик находится в `scripts/build_media.py`.

Версии пакетов зафиксированы в `requirements.txt`. SHA-256 моделей и их источники находятся в `models/manifest.json`.

## Каталог 1.2

Готовый GigaAM E2E ONNX для загрузки: https://huggingface.co/istupakov/gigaam-v3-onnx, ревизия 322c3b29492673eb7d0b434bfa9dfb8653e34d02. Архитектура и веса соответствуют GigaAM v3 E2E; формат экспорта совместим с включённым движком. Локальный экспорт предыдущей версии поддерживается как проверенный вариант импорта. Публичные URL и SHA-256 зафиксированы в model-catalog.json.
