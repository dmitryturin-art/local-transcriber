"""Сборка переносимого .app и DMG; модели берутся только из папки проекта."""
import argparse
import json
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import struct
import sys

ROOT = Path(__file__).resolve().parents[1]


def run(command, **kwargs):
    print("Сборка:", command[0], flush=True)
    subprocess.run([str(x) for x in command], check=True, **kwargs)


def clone(source, destination):
    destination.parent.mkdir(parents=True, exist_ok=True)
    subprocess.run(["cp", "-c", str(source), str(destination)], check=True)


def dependencies(path):
    lines = subprocess.check_output(["otool", "-L", str(path)], text=True).splitlines()[1:]
    return [line.strip().split(" (", 1)[0] for line in lines]


def bundle_ffmpeg(resources):
    binaries = resources / "bin"
    libraries = resources / "lib"
    binaries.mkdir(parents=True, exist_ok=True)
    libraries.mkdir(parents=True, exist_ok=True)
    queue = []
    mapping = {}
    for name in ("ffmpeg", "ffprobe"):
        source = ROOT / "vendor/media-tools/bin" / name
        if not source.is_file():
            raise RuntimeError("Сначала соберите FFmpeg: python scripts/build_media.py")
        if not source:
            raise RuntimeError(f"Для сборки нужен {name}")
        target = binaries / name
        clone(Path(source).resolve(), target)
        queue.append((Path(source).resolve(), target))
    visited = set()
    while queue:
        original, target = queue.pop(0)
        if target in visited:
            continue
        visited.add(target)
        changes = []
        for dependency in dependencies(original):
            if not dependency.startswith(("/opt/homebrew/", "/usr/local/")):
                continue
            source = Path(dependency).resolve()
            name = Path(dependency).name
            library = libraries / name
            if name in mapping and mapping[name] != source:
                raise RuntimeError(f"Конфликт библиотек: {name}")
            if name not in mapping:
                mapping[name] = source
                clone(source, library)
                queue.append((source, library))
            replacement = ("@loader_path/../lib/" if target.parent == binaries else "@loader_path/") + name
            changes += ["-change", dependency, replacement]
        target.chmod(target.stat().st_mode | 0o200)
        command = ["install_name_tool", *changes]
        if target.parent == libraries:
            command += ["-id", "@rpath/" + target.name]
        if len(command) > 1:
            run([*command, target], stdout=subprocess.DEVNULL)
        run(["codesign", "--force", "--sign", "-", target], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    print(f"FFmpeg: включено библиотек — {len(mapping)}", flush=True)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--python", default=sys.executable)
    parser.add_argument("--skip-engine", action="store_true")
    parser.add_argument("--dmg", action="store_true")
    args = parser.parse_args()
    build = ROOT / "build"
    dist = ROOT / "dist"
    build.mkdir(exist_ok=True)
    dist.mkdir(exist_ok=True)
    os.environ["PYINSTALLER_CONFIG_DIR"] = str(build / "pyinstaller-cache")
    app = dist / "Голоса.app"
    resources = app / "Contents/Resources"
    executable = app / "Contents/MacOS/LocalTranscriber"
    resources.mkdir(parents=True, exist_ok=True)
    executable.parent.mkdir(parents=True, exist_ok=True)
    if not args.skip_engine:
        run([args.python, "-m", "PyInstaller", "--noconfirm", "--clean", "--name", "local-engine",
             "--distpath", build / "engine-dist", "--workpath", build / "pyinstaller", "--specpath", build,
             "--paths", ROOT, "--collect-all", "sherpa_onnx", "--collect-all", "sherpa_onnx_core",
             "--collect-all", "onnxruntime", "--collect-all", "transcribe_cpp",
             "--collect-all", "transcribe_cpp_native", "--collect-all", "_soundfile_data",
             "--collect-all", "sentencepiece",
             "--exclude-module", "onnx", "--exclude-module", "torch", "--exclude-module", "matplotlib",
             "--exclude-module", "pandas", "--exclude-module", "tkinter", ROOT / "backend/worker.py"], cwd=ROOT)
        engine = resources / "engine"
        if engine.exists():
            shutil.rmtree(engine)
        shutil.copytree(build / "engine-dist/local-engine", engine)
    if (resources / "models").exists():
        shutil.rmtree(resources / "models")
    run(["cp", "-cR", ROOT / "models", resources / "models"])
    for directory in (resources / "bin", resources / "lib"):
        if directory.exists():
            shutil.rmtree(directory)
    bundle_ffmpeg(resources)
    run(["swiftc", "-swift-version", "5", "-O", "-parse-as-library", "-target", "arm64-apple-macos14.0",
         "-module-cache-path", build / "swift-cache", ROOT / "macos/LocalTranscriber.swift", "-o", executable])
    info = {"CFBundleName": "Голоса", "CFBundleDisplayName": "Голоса", "CFBundleExecutable": "LocalTranscriber",
            "CFBundleIdentifier": "local.voices.transcriber", "CFBundleVersion": "1", "CFBundleShortVersionString": "1.0.0",
            "CFBundlePackageType": "APPL", "LSMinimumSystemVersion": "14.0", "NSHighResolutionCapable": True,
            "CFBundleIconFile": "AppIcon", "NSHumanReadableCopyright": "Локальный транскрибатор · 2026"}
    (app / "Contents/Info.plist").write_bytes(plistlib.dumps(info))
    iconset = build / "AppIcon.iconset"
    iconset.mkdir(exist_ok=True)
    run(["swift", "-module-cache-path", build / "swift-cache", ROOT / "scripts/icon.swift", iconset])
    # PNG-элементы в стандартном ICNS-контейнере не требуют сервиса iconutil.
    elements = []
    for code, name in [(b"icp4", "icon_16x16.png"), (b"icp5", "icon_32x32.png"),
                       (b"ic07", "icon_128x128.png"), (b"ic08", "icon_256x256.png"),
                       (b"ic09", "icon_512x512.png"), (b"ic10", "icon_512x512@2x.png"),
                       (b"ic11", "icon_16x16@2x.png"), (b"ic12", "icon_32x32@2x.png"),
                       (b"ic13", "icon_128x128@2x.png"), (b"ic14", "icon_256x256@2x.png")]:
        data = (iconset / name).read_bytes()
        elements.append(code + struct.pack(">I", len(data) + 8) + data)
    data = b"".join(elements)
    (resources / "AppIcon.icns").write_bytes(b"icns" + struct.pack(">I", len(data) + 8) + data)
    for name in ("README.md", "THIRD_PARTY.md"):
        if (ROOT / name).exists():
            shutil.copy2(ROOT / name, resources / name)
    if (ROOT / "licenses").exists():
        shutil.copytree(ROOT / "licenses", resources / "licenses", dirs_exist_ok=True)
    run(["codesign", "--force", "--deep", "--sign", "-", app])
    run(["codesign", "--verify", "--deep", "--strict", app])
    if args.dmg:
        installer = build / "installer"
        if installer.exists():
            shutil.rmtree(installer)
        installer.mkdir()
        run(["cp", "-cR", app, installer / app.name])
        (installer / "Applications").symlink_to("/Applications")
        shutil.copy2(ROOT / "INSTALL.txt", installer / "Как установить.txt")
        dmg = dist / "Голоса-1.0.0-AppleSilicon.dmg"
        if dmg.exists():
            dmg.unlink()
        run(["hdiutil", "create", "-volname", "Голоса", "-srcfolder", installer,
             "-format", "UDZO", "-ov", dmg])
        shutil.rmtree(installer)
    print("Готово:", app, flush=True)


if __name__ == "__main__":
    main()
