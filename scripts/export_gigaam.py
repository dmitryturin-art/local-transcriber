"""Экспорт уже скачанной GigaAM E2E из локального каталога, без сети."""
import argparse
import importlib.util
import json
from pathlib import Path
import shutil
import sys

import torch
from omegaconf import OmegaConf


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--source", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    args.output.mkdir(parents=True, exist_ok=True)
    spec = importlib.util.spec_from_file_location("modeling_gigaam", args.source / "modeling_gigaam.py")
    module = importlib.util.module_from_spec(spec)
    sys.modules["modeling_gigaam"] = module
    spec.loader.exec_module(module)
    config = json.loads((args.source / "config.json").read_text())["cfg"]["model"]["cfg"]
    config["decoding"]["model_path"] = str((args.source / "tokenizer.model").resolve())
    model = module.GigaAMASR(OmegaConf.create(config))
    state = torch.load(args.source / "pytorch_model.bin", map_location="cpu", weights_only=True)
    state = {k.removeprefix("model."): v for k, v in state.items()}
    model.load_state_dict(state, strict=True)
    model.float().eval()
    torch.set_num_threads(4)
    with torch.inference_mode():
        print("Экспорт энкодера", flush=True)
        torch.onnx.export(model.encoder, (torch.randn(1, 64, 200), torch.tensor([200], dtype=torch.int64)),
            str(args.output / "v3_rnnt_encoder.onnx"), input_names=["audio_signal", "length"],
            output_names=["encoded", "encoded_len"],
            dynamic_axes={"audio_signal": {0: "batch", 2: "time"}, "length": {0: "batch"},
                          "encoded": {0: "batch", 2: "encoded_time"}, "encoded_len": {0: "batch"}},
            opset_version=17, dynamo=False)
        print("Экспорт декодера", flush=True)
        torch.onnx.export(model.head.decoder, model.head.decoder.input_example(),
            str(args.output / "v3_rnnt_decoder.onnx"), input_names=["x", "h_in", "c_in"],
            output_names=["dec", "h_out", "c_out"], opset_version=17, dynamo=False)
        print("Экспорт совместной сети", flush=True)
        torch.onnx.export(model.head.joint, model.head.joint.input_example(),
            str(args.output / "v3_rnnt_joint.onnx"), input_names=["enc", "dec"],
            output_names=["joint"], opset_version=17, dynamo=False)
    shutil.copy2(args.source / "tokenizer.model", args.output / "tokenizer.model")
    features = config["preprocessor"]
    (args.output / "features.json").write_text(json.dumps({
        "n_fft": features["n_fft"], "win_length": features["win_length"],
        "hop_length": features["hop_length"], "center": features["center"],
        "features": features["features"], "blank_id": config["head"]["decoder"]["num_classes"] - 1,
        "model_name": config["model_name"]}, indent=2))
    print("Экспорт завершён", flush=True)


if __name__ == "__main__":
    main()
