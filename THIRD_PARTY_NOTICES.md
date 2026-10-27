# Third-party notices

Sotto's own code is released under the [MIT License](LICENSE). Sotto builds on the open-source packages and downloads the speech and language models listed below. Each keeps its own license, which applies to that component and not to Sotto's code.

Sotto does not bundle any model weights. Models are downloaded on your Mac when you choose to install an engine, from the repositories named here, at a pinned revision and with SHA-256 verification (see `Sotto/Resources/model-manifest.json` and `Sotto/Resources/speech-model-manifest.json`).

## Models

### Required attribution

**NVIDIA Parakeet TDT 0.6B v3** is licensed under [Creative Commons Attribution 4.0 International (CC BY 4.0)](https://creativecommons.org/licenses/by/4.0/).

- Original model: [nvidia/parakeet-tdt-0.6b-v3](https://huggingface.co/nvidia/parakeet-tdt-0.6b-v3), © NVIDIA
- Core ML conversion used by Sotto: [FluidInference/parakeet-tdt-0.6b-v3-coreml](https://huggingface.co/FluidInference/parakeet-tdt-0.6b-v3-coreml)
- Changes: the original model was converted to Core ML format by FluidInference. Sotto downloads that conversion unmodified.
- NVIDIA does not endorse Sotto.

### All models

| Model | Used for | Downloaded from | License |
|---|---|---|---|
| Whisper Large v3 Turbo (`openai_whisper-large-v3-v20240930_turbo`), Core ML conversion | Default speech engine, language detection, translation | [argmaxinc/whisperkit-coreml](https://huggingface.co/argmaxinc/whisperkit-coreml). Original: [openai/whisper-large-v3-turbo](https://huggingface.co/openai/whisper-large-v3-turbo) | MIT |
| Parakeet TDT 0.6B v3, Core ML conversion | Optional English dictation and import engine | [FluidInference/parakeet-tdt-0.6b-v3-coreml](https://huggingface.co/FluidInference/parakeet-tdt-0.6b-v3-coreml). Original: [nvidia/parakeet-tdt-0.6b-v3](https://huggingface.co/nvidia/parakeet-tdt-0.6b-v3) | CC BY 4.0 (attribution above) |
| Silero VAD, Core ML conversion | Voice-activity detection for the Parakeet engine | [FluidInference/silero-vad-coreml](https://huggingface.co/FluidInference/silero-vad-coreml). Based on [snakers4/silero-vad](https://github.com/snakers4/silero-vad) | MIT |
| Cohere Transcribe (03-2026), MLX 4-bit | Optional English dictation and import engine | [davidalarrea/cohere-transcribe-03-2026-mlx-4bit](https://huggingface.co/davidalarrea/cohere-transcribe-03-2026-mlx-4bit) | Apache-2.0 (see below) |
| Qwen2.5 1.5B Instruct, MLX 4-bit | Optional on-device text cleanup | [mlx-community/Qwen2.5-1.5B-Instruct-4bit](https://huggingface.co/mlx-community/Qwen2.5-1.5B-Instruct-4bit). Original: [Qwen/Qwen2.5-1.5B-Instruct](https://huggingface.co/Qwen/Qwen2.5-1.5B-Instruct) | Apache-2.0 |

**Cohere Transcribe credits.** The model is [CohereLabs/cohere-transcribe-03-2026](https://huggingface.co/CohereLabs/cohere-transcribe-03-2026) by Cohere, licensed Apache-2.0. Sotto downloads a third-party conversion chain: an MLX fp16 conversion by [beshkenadze](https://huggingface.co/beshkenadze/cohere-transcribe-03-2026-mlx-fp16), then a 4-bit quantization by [davidalarrea](https://huggingface.co/davidalarrea/cohere-transcribe-03-2026-mlx-4bit). The 4-bit repository declares Apache-2.0. The intermediate fp16 repository declares its license as "other" and refers to the upstream model card for terms. The upstream original is also gated on Hugging Face behind a terms acceptance. Sotto relies on the Apache-2.0 declarations of the upstream model and the 4-bit conversion, and does not host or redistribute the weights.

The original OpenAI Whisper model is copyright OpenAI, released under the MIT License.

## Swift packages

Versions are the ones pinned in `Sotto.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved`. License text is in each project's repository.

| Package | Version | License | Source |
|---|---|---|---|
| HotKey | 0.2.1 | MIT | <https://github.com/soffes/HotKey> |
| WhisperKit | 1.1.1 | MIT | <https://github.com/argmaxinc/WhisperKit> |
| Sparkle | 2.10.1 | MIT, with bundled components under their own permissive licenses (see Sparkle's `LICENSE`) | <https://github.com/sparkle-project/Sparkle> |
| mlx-swift | 0.32.3 | MIT | <https://github.com/ml-explore/mlx-swift> |
| mlx-swift-lm | 3.32.3 | MIT | <https://github.com/ml-explore/mlx-swift-lm> |
| mlx-audio-swift | 0.1.6 | MIT | <https://github.com/Blaizzy/mlx-audio-swift> |
| FluidAudio | 0.17.7 | Apache-2.0 | <https://github.com/FluidInference/FluidAudio> |
| swift-transformers | 1.3.5 | Apache-2.0 | <https://github.com/huggingface/swift-transformers> |

### Transitive dependencies

| Package | Version | License | Source |
|---|---|---|---|
| EventSource | 1.5.1 | MIT | <https://github.com/mattt/EventSource> |
| yyjson | 0.12.0 | MIT | <https://github.com/ibireme/yyjson> |
| swift-argument-parser | 1.8.2 | Apache-2.0 | <https://github.com/apple/swift-argument-parser> |
| swift-asn1 | 1.7.3 | Apache-2.0 | <https://github.com/apple/swift-asn1> |
| swift-collections | 1.7.5 | Apache-2.0 | <https://github.com/apple/swift-collections> |
| swift-crypto | 4.5.2 | Apache-2.0 | <https://github.com/apple/swift-crypto> |
| swift-huggingface | 0.13.0 | Apache-2.0 | <https://github.com/huggingface/swift-huggingface> |
| swift-jinja | 2.5.2 | Apache-2.0 | <https://github.com/huggingface/swift-jinja> |
| swift-numerics | 1.1.1 | Apache-2.0 | <https://github.com/apple/swift-numerics> |
| swift-syntax | 603.0.2 | Apache-2.0 | <https://github.com/swiftlang/swift-syntax> (build-time macro support, not shipped) |

## Keeping this file current

When you add or upgrade a package or model, update the matching row and confirm the license in the project's own `LICENSE` or model card. CI does not check this file.
