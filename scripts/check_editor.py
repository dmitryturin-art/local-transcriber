"""Проверка редактора без открытия окна и управления пользовательским вводом."""
from pathlib import Path
import plistlib
import subprocess
import argparse

parser = argparse.ArgumentParser()
parser.add_argument("--transcript", type=Path)
args = parser.parse_args()
root = Path(__file__).resolve().parents[1] if Path(__file__).parent.name == "scripts" else Path(__file__).parent
build = root / "build"
build.mkdir(exist_ok=True)
source = (root / "macos/LocalTranscriber.swift").read_text()
generated = build / "EditorController.swift"
generated.write_text(source[:source.index("@main\nstruct LocalTranscriberApp")])
app = build / "EditorTests.app"
binary = app / "Contents/MacOS/EditorTests"
binary.parent.mkdir(parents=True, exist_ok=True)
(app / "Contents/Info.plist").write_bytes(plistlib.dumps({"CFBundleIdentifier": "local.voices.editor-tests",
    "CFBundleExecutable": "EditorTests", "CFBundlePackageType": "APPL"}))
subprocess.run(["swiftc", "-swift-version", "5", "-parse-as-library", "-target", "arm64-apple-macos14.0",
    "-module-cache-path", str(build / "swift-cache"), str(generated), str(root / "tests/EditorTests.swift"), *[str(p) for p in (root/"macos").glob("*.swift") if p.name != "LocalTranscriber.swift"], "-o", str(binary)], check=True)
command = [str(binary)]
if args.transcript:
    command.append(str(args.transcript.resolve()))
subprocess.run(command, check=True)
