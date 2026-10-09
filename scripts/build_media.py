"""Переносимая сборка FFmpeg из включённого архива; сеть не используется."""
import os
from pathlib import Path
import subprocess

root = Path(__file__).resolve().parents[1]
archive = root / "licenses/FFmpeg/ffmpeg-8.0.1.tar.xz"
build = root / "build"
build.mkdir(exist_ok=True)
if not archive.is_file():
    raise SystemExit("Нет архива исходников FFmpeg в licenses/FFmpeg/")
subprocess.run(["tar", "-xf", str(archive), "-C", str(build)], check=True)
source = build / "ffmpeg-8.0.1"
prefix = root / "vendor/media-tools"
command = ["./configure", f"--prefix={prefix}", "--disable-network", "--disable-autodetect",
           "--disable-doc", "--disable-debug", "--disable-ffplay", "--disable-encoders",
           "--enable-encoder=pcm_s16le", "--disable-shared", "--enable-static", "--disable-gpl",
           "--disable-nonfree", "--extra-cflags=-mmacosx-version-min=14.0",
           "--extra-ldflags=-mmacosx-version-min=14.0", "--cc=/usr/bin/clang"]
subprocess.run(command, cwd=source, check=True)
subprocess.run(["make", f"-j{min(6, os.cpu_count() or 4)}"], cwd=source, check=True)
destination = prefix / "bin"
destination.mkdir(parents=True, exist_ok=True)
for name in ("ffmpeg", "ffprobe"):
    subprocess.run(["cp", "-c", str(source / name), str(destination / name)], check=True)
print("Готово:", destination)
