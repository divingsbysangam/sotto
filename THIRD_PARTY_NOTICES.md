# Third-party notices

Sotto's own code is released under the [MIT License](LICENSE). Sotto builds on the open-source packages and downloads the speech and language models listed below. Each keeps its own license, which applies to that component and not to Sotto's code.

Sotto does not bundle model weights. Whisper is downloaded on your Mac on first use at a pinned revision with SHA-256 verification (see `Sotto/Resources/model-manifest.json`).

## Models

| Model | Used for | Downloaded from | License |
|---|---|---|---|
| Whisper Large v3 Turbo (`openai_whisper-large-v3-v20240930_turbo`), Core ML conversion | Speech recognition, language detection, translation | [argmaxinc/whisperkit-coreml](https://huggingface.co/argmaxinc/whisperkit-coreml). Original: [openai/whisper-large-v3-turbo](https://huggingface.co/openai/whisper-large-v3-turbo) | MIT |

The original OpenAI Whisper model is copyright OpenAI, released under the MIT License.

## Swift packages

Versions are the ones pinned in `Sotto.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved`. License text is in each project's repository.

| Package | Version | License | Source |
|---|---|---|---|
| HotKey | 0.2.1 | MIT | <https://github.com/soffes/HotKey> |
| WhisperKit | 1.1.1 | MIT | <https://github.com/argmaxinc/WhisperKit> |
| Sparkle | 2.10.1 | MIT, with bundled components under their own permissive licenses (see Sparkle's `LICENSE`) | <https://github.com/sparkle-project/Sparkle> |

### Transitive dependencies

| Package | Version | License | Source |
|---|---|---|---|
| swift-argument-parser | 1.8.2 | Apache-2.0 | <https://github.com/apple/swift-argument-parser> |

## Keeping this file current

When you add or upgrade a package or model, update the matching row and confirm the license in the project's own `LICENSE` or model card. CI does not check this file.
