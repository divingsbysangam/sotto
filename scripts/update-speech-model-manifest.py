#!/usr/bin/env python3
"""Regenerate the optional-engine manifest from immutable Hugging Face revisions.

Only small metadata files are fetched. LFS weights use the publisher's SHA-256.
Review the diff before shipping a new revision; this script is never run by the app.
"""
import concurrent.futures
import hashlib
import json
from pathlib import Path
import urllib.request

PARAKEET = ("FluidInference/parakeet-tdt-0.6b-v3-coreml", "7dd20fe6b1797d35f5e3307e8b1732d9a178edfe")
VAD = ("FluidInference/silero-vad-coreml", "b419383c55c110e2c9271fa6ee0ea83d03c70d96")
COHERE = ("davidalarrea/cohere-transcribe-03-2026-mlx-4bit", "fedd1c83571341374f34525096e5ef67ebcdcfcc")
VAD_NAME = "silero-vad-unified-256ms-v6.2.1.mlmodelc"


def assets(repository, revision, include, prefix=""):
    url = f"https://huggingface.co/api/models/{repository}/revision/{revision}?blobs=true"
    with urllib.request.urlopen(url, timeout=60) as response:
        files = json.load(response)["siblings"]

    def describe(item):
        name = item["rfilename"]
        digest = item.get("lfs", {}).get("sha256")
        if not digest:
            with urllib.request.urlopen(f"https://huggingface.co/{repository}/resolve/{revision}/{name}", timeout=60) as response:
                digest = hashlib.sha256(response.read()).hexdigest()
        return dict(repository=repository, revision=revision, remotePath=name,
                    path=prefix + name, size=item["size"], sha256=digest)

    with concurrent.futures.ThreadPoolExecutor(max_workers=6) as pool:
        return list(pool.map(describe, [item for item in files if include(item["rfilename"])]))


if __name__ == "__main__":
    components = {"Preprocessor.mlmodelc", "Encoder.mlmodelc", "Decoder.mlmodelc", "JointDecisionv3.mlmodelc"}
    parakeet = assets(*PARAKEET, lambda path: path.split("/")[0] in components or path == "parakeet_vocab.json")
    parakeet += assets(*VAD, lambda path: path.startswith(VAD_NAME + "/"), "VAD/")
    cohere = assets(*COHERE, lambda path: path in {
        "config.json", "model.safetensors", "preprocessor_config.json", "special_tokens_map.json",
        "tokenizer.model", "tokenizer_config.json",
    })
    destination = Path(__file__).resolve().parent.parent / "Sotto/Resources/speech-model-manifest.json"
    destination.write_text(json.dumps({"engines": {"parakeet": parakeet, "cohere": cohere}}, indent=2) + "\n")
    for engine, files in [("parakeet", parakeet), ("cohere", cohere)]:
        print(engine, len(files), sum(item["size"] for item in files), "bytes")
