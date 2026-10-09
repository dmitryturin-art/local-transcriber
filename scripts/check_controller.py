"""Проверяет настоящий контроллер SwiftUI без действий с пользовательским UI."""
import argparse
from pathlib import Path
import plistlib
import shutil
import subprocess

root = Path(__file__).resolve().parents[1]
parser = argparse.ArgumentParser()
parser.add_argument("audio", type=Path)
parser.add_argument("--model", default="gigaam")
parser.add_argument("--cancel", action="store_true")
args = parser.parse_args()
app = root / "build/controller-check.app"
if app.exists():
    shutil.rmtree(app)
subprocess.run(["cp", "-cR", str(root / "dist/release-1.4/Голоса.app"), str(app)], check=True)
source = (root / "macos/LocalTranscriber.swift").read_text()
prefix = source[:source.index("@main\nstruct LocalTranscriberApp")]
generated = root / "build/Controller.swift"
generated.write_text(prefix)
info_path = app / "Contents/Info.plist"
info = plistlib.loads(info_path.read_bytes())
info["CFBundleExecutable"] = "ControllerCheck"
info["CFBundleIdentifier"] = "local.voices.controller-check"
info_path.write_bytes(plistlib.dumps(info))
binary = app / "Contents/MacOS/ControllerCheck"
subprocess.run(["swiftc", "-swift-version", "5", "-parse-as-library", "-target", "arm64-apple-macos14.0",
                "-module-cache-path", str(root / "build/swift-cache"), str(generated),
                str(root / "tests/ControllerSmokeTest.swift"), *[str(p) for p in (root/"macos").glob("*.swift") if p.name != "LocalTranscriber.swift"], "-o", str(binary)], check=True)
subprocess.run(["codesign", "--force", "--deep", "--sign", "-", str(app)], check=True)
subprocess.run([str(binary), str(args.audio.resolve()), str(root / "build/controller-results"), args.model] + (["--cancel"] if args.cancel else []), check=True)
