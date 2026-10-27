#!/usr/bin/env python3
"""Fetch 20 referenced LibriSpeech dev-clean clips for the opt-in XCTest benchmark."""
import concurrent.futures
import hashlib
import json
from pathlib import Path
import sys
import urllib.request

ROOT = Path(sys.argv[1] if len(sys.argv) > 1 else "build/asr-benchmark").resolve()
ROOT.mkdir(parents=True, exist_ok=True)
DATASET = "hf-internal-testing/librispeech_asr_dummy"
REVISION = "5be91486e11a2d616f4ec5db8d3fd248585ac07a"
URL = f"https://datasets-server.huggingface.co/rows?dataset={DATASET}&config=clean&split=validation&offset=0&length=20"


def fetch(entry):
    row = entry["row"]
    filename = row["id"] + ".flac"
    target = ROOT / filename
    source = row["audio"][0]["src"]
    if REVISION not in source:
        raise RuntimeError("Dataset revision changed; review references before updating the benchmark")
    if not target.exists():
        with urllib.request.urlopen(source, timeout=120) as response:
            target.write_bytes(response.read())
    return dict(id=row["id"], file=filename, text=row["text"], sha256=hashlib.sha256(target.read_bytes()).hexdigest())


if __name__ == "__main__":
    with urllib.request.urlopen(URL, timeout=60) as response:
        rows = json.load(response)["rows"]
    with concurrent.futures.ThreadPoolExecutor(max_workers=5) as pool:
        clips = list(pool.map(fetch, rows))
    if len(clips) != 20:
        raise RuntimeError("Expected exactly 20 clips")
    (ROOT / "corpus.json").write_text(json.dumps(clips, indent=2) + "\n")
    print(f"Saved {len(clips)} clips and references under {ROOT}")
