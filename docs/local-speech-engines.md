# Local speech engines

Whisper Large v3 Turbo remains the default. Settings → Transcription offers optional
Parakeet TDT v3 (FluidAudio 0.17.7, Silero VAD) and Cohere Transcribe 03-2026 q4
(MLXAudio 0.1.6). Optional engines currently handle English dictation, scratchpad,
imports, and retries. Automatic language detection and chosen languages use Whisper;
Settings displays this fallback. Translation
keeps the existing on-device cleanup / Whisper fallback. Live preview is Whisper-only;
its saved preference is not cleared when another engine is selected.

## Models and offline operation

Selecting an optional engine does not download it. Choose Download, then Load Model.
The app checks every required file against `speech-model-manifest.json` before loading.
Downloads use immutable public Hugging Face revisions, byte counts, and SHA-256 hashes.
Completed, verified assets survive cancellation and are reused on Retry. An incomplete
or mismatched asset cannot be loaded. Repair fetches just missing or invalid assets.

Optional models live under `~/Library/Application Support/Sotto/SpeechModels/`.
Whisper retains its existing location and manifest. Recognition calls FluidAudio's
`loadLocal` / direct VAD initializer and Cohere's `fromDirectory`, never their automatic
download helpers. No audio, transcript, vocabulary, or screen context is uploaded.

The pinned Parakeet assets are the int8 Encoder, Preprocessor, Decoder,
JointDecisionv3, vocabulary, and Silero v6.2.1. Cohere uses
`davidalarrea/cohere-transcribe-03-2026-mlx-4bit` revision
`fedd1c83571341374f34525096e5ef67ebcdcfcc` (~1.5 GB download). It is a community
conversion of the Apache-2.0 Cohere model. “Max accuracy” describes its intended use,
not a guarantee that it beats Whisper or Parakeet on every recording.

Maintain the manifest with `python3 scripts/update-speech-model-manifest.py`; review
the diff. Never resolve model revisions dynamically in the shipping app.

## Lifecycle

Each recording, import, and retry reserves its starting engine. Settings changes affect
the next operation. Model removal waits until all reserved operations finish.
A shared work gate serializes speech preparation, recognition, preview,
and local MLX cleanup. Unused speech models unload before switching;
Cohere releases cached cleanup weights before loading. First ANE specialization is
cached by CoreML. Cohere shows a memory warning; allow about 2.5 GB while loaded.

ESC cancellation is checked before inference and again before returning results.
Native decoders may finish a chunk before cancellation returns; cancelled text is not
sent to cleanup, history, or paste. Optional runtimes process at most 30 seconds per
chunk to bound this delay and memory.

## Verification and benchmarking

Building requires Xcode 26+ / Swift 6.2+ and Xcode's Metal toolchain, on macOS 14+.
The runtime dependencies share MLX 0.32.3; mlx-swift-lm is pinned to 3.32.3.

```sh
xcodegen generate
xcodebuild -project Sotto.xcodeproj -scheme Sotto -configuration Release \
  -destination 'platform=macOS,arch=arm64' -skipPackagePluginValidation \
  -skipMacroValidation SOTTO_ENABLE_TESTABILITY=YES ENABLE_HARDENED_RUNTIME=NO test

python3 scripts/prepare-asr-benchmark.py
xcodebuild -project Sotto.xcodeproj -scheme Sotto -configuration Release \
  -destination 'platform=macOS,arch=arm64' -skipPackagePluginValidation \
  -skipMacroValidation \
  SOTTO_ENABLE_TESTABILITY=YES \
  ENABLE_HARDENED_RUNTIME=NO \
  SOTTO_ASR_BENCHMARK_DIR="$PWD/build/asr-benchmark" \
  -only-testing:SottoTests/SpeechEngineBenchmarkTests test

./scripts/build-and-install.sh
```

Set `SOTTO_DERIVED_DATA_PATH` on the install command to reuse a verified build cache.
Installation fails if this project's exact products directory cannot be resolved.
The test-only hardening override avoids XCTest host bootstrap restrictions. Normal
builds and installation retain hardened runtime; the install script re-signs Sparkle,
explicitly preserves the app's entitlements, checks the runtime flag, and removes any
leftover XCTest bundle. Local self-signed certificates have no Apple Team ID, so the
app uses the explicit `disable-library-validation` entitlement to load bundled Sparkle.
This exception is defined in `project.yml`; it does not grant TCC permissions.

For a strict offline check, build the `SottoSpeechProbe` scheme. This verification-only
tool compiles the production download verifier, audio reader, and both optional runtimes;
it is not bundled in Sotto. Run it with an installed model and a public fixture:

```sh
sandbox-exec -p '(version 1)(allow default)(deny network*)' \
  /path/to/Release/SottoSpeechProbe parakeet \
  "$PWD/build/asr-benchmark/1272-128104-0000.flac" \
  "$PWD/Sotto/Resources/speech-model-manifest.json"
```

Repeat with `cohere`. Both must return nonempty transcripts with exit code zero.
A `curl https://huggingface.co` invocation under the same policy must fail as a negative
control. This denies networking only for those probe processes; it does not change the
Mac's network settings.

The opt-in benchmark downloads optional models using the production verified downloader.
It measures load time (including verification), three warm passes per clip, raw ASR
word errors, and sampled process memory (20 ms interval). It also checks two seconds
of silence, a one-second recording, and a multi-chunk file import. Normal regression
tests skip downloads and isolate settings from personal preferences.

The 20 clips are from the [LibriSpeech dev-clean subset](https://huggingface.co/datasets/hf-internal-testing/librispeech_asr_dummy),
revision `5be91486e11a2d616f4ec5db8d3fd248585ac07a`, validation rows 0–19.
They cover one speaker/chapter, not a representative multilingual or conversational
evaluation. The corpus manifest records references and audio hashes. WER lowercases
and splits on non-alphanumeric characters. Report aggregate errors / reference words;
report the median of each clip's three warm times. Model load times are process-cold,
not necessarily cold CoreML disk/ANE caches. Memory is total process footprint, with
a baseline, not model size. Whisper may use the user's configured vocabulary hints.

A successful compile alone does not establish microphone capture or Accessibility paste.
Record those desktop checks separately.

## M4 verification, 2026-10-25

The final acceptance run passed **15/15 tests**, including the opt-in benchmark,
digital silence, short audio, multi-chunk imports, clipboard output, Whisper live
preview after switching back, and Whisper timestamped segments. Both optional engines
also transcribed a fixture under a sandbox denying all network operations; the network
negative control failed as expected.

| Engine | WER (453 reference words) | Median warm clip | Load incl. verification | Peak process footprint |
|---|---:|---:|---:|---:|
| Whisper Turbo | 4.42% | 0.771 s | 2.299 s | 1,918 MiB |
| Parakeet TDT v3 | 2.43% | 0.065 s | 0.449 s | 911 MiB |
| Cohere Transcribe q4 | 1.77% | 0.704 s | 0.922 s | 2,290 MiB |

These are the small single-speaker corpus results described above, not general quality
claims. CoreML specialization and MLX kernels were cached; initial Parakeet preparation
in an earlier run took roughly 15 seconds. Process baselines differed between engines
because native caches can outlive model references. Baselines and per-clip timings are
recorded in `build/asr-benchmark/summary.json` and the engine reports.

The acceptance work also fixed two reproduced issues: Whisper invented “Thank you” on
digital silence, and packet-aligned AVAudioFile reads produced a 96 ms trailing chunk
from an exact 60-second import that Parakeet rejected. Signal preflight and accumulated
sample reads now cover these cases with regression tests. Actual microphone speech,
Accessibility paste into another app still require
desktop acceptance; fixture transcription and timestamp tests do not establish those.
