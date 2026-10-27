# Sotto

[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)

Sotto is a native macOS app for voice dictation. Press a shortcut, speak, and paste a transcript into the app where you are working. Speech recognition and text cleanup run on your Mac. Sotto has no account, hosted inference, API keys, analytics, or telemetry.

The only network requests are for model files you choose to download and Sparkle update checks. Your audio, transcripts, vocabulary, clipboard contents, and screen context are not uploaded. Read the [privacy details](PRIVACY.md).

![Sotto's recording indicator choices in Settings: Bottom capsule + dot, Dot near writing, and Floating window](docs/media/recording-indicator-options.jpg)

In **Settings → General → Recording Indicator Style**, choose the bottom capsule with a caret dot, a dot beside your writing, or a floating window. The dot-only style follows the active caret or pointer while you dictate.

![The bottom capsule animating between listening and processing states](docs/media/capsule-demo.gif)

The capsule demo renders Sotto's SwiftUI view with synthetic audio levels. It contains no recording or personal text.

## Get started

Sotto runs on an Apple silicon Mac with **macOS 14 or later**. To build it, use **macOS 15.6 or later** with Xcode 26, its Metal toolchain, and XcodeGen. The build does not require an Apple Developer account.

For the first public release, download `Sotto.zip` from [GitHub Releases](https://github.com/divingsbysangam/sotto/releases), unzip it, and move `Sotto.app` to `/Applications`. The self-signed app has not been notarized by Apple. On first launch, Control-click the app and choose **Open**, then confirm **Open**. Later launches work normally. The release notes will include its SHA-256 checksum.

To build from source:

```bash
git clone https://github.com/divingsbysangam/sotto.git
cd sotto
brew install xcodegen
xcodebuild -downloadComponent MetalToolchain
./scripts/build.sh
./scripts/build.sh test
```

The build-only script generates the Xcode project, then builds without signing or installing. For a stable local signature that preserves macOS permission grants across rebuilds, run `./scripts/create-signing-cert.sh` once and then `./scripts/build-and-install.sh`. See [SETUP.md](SETUP.md) for the full setup and troubleshooting guide.

## Dictation and local models

Whisper Large v3 Turbo is the default speech engine. It supports language detection, non-English speech, translation fallback, and live preview. Parakeet TDT v3 and Cohere Transcribe q4 are optional engines for English dictation and file imports. You choose when to download and load them. Text cleanup uses Apple Foundation Models on supported Macs, an optional local Qwen model, or built-in rules.

| Model | Download | Use |
|---|---:|---|
| Whisper Large v3 Turbo | About 1.6 GB | Default speech engine |
| Parakeet TDT v3 | About 0.5 GB | Optional English dictation and imports |
| Cohere Transcribe q4 | About 1.5 GB | Optional English dictation and imports |
| Qwen2.5 1.5B Instruct, 4-bit | About 0.9 GB | Optional text cleanup |

Model downloads are pinned by revision and SHA-256. After installation, dictation works offline. See [local speech engines](docs/local-speech-engines.md) and [third-party notices](THIRD_PARTY_NOTICES.md) for model sources and licenses.

## Permissions

Sotto asks only for permissions needed by features you use:

| macOS permission | Why Sotto needs it |
|---|---|
| Microphone | Record your voice for dictation |
| Accessibility | Paste into the focused app and find the text caret |
| Screen Recording | Read optional on-screen context with local OCR |
| Input Monitoring | Count typing activity for the optional Voice vs Keyboard statistic; key contents are never recorded |
| Apple Events | Optionally pause Music or Spotify while recording |

You can review or revoke these in **System Settings → Privacy & Security**. Permission-gated features stop when their permission is unavailable; other features keep working. [PRIVACY.md](PRIVACY.md) explains storage, retention, and network behavior.

## Frequently asked questions

**Does Sotto send recordings to a server?** No. Recognition and cleanup run on your Mac. Model downloads and update checks are the only network uses.

**Why is the first download large?** Whisper is a local model, so Sotto downloads its files once instead of sending speech to a hosted service. Optional models download only when you request them.

**Why does macOS ask for permissions again after a rebuild?** macOS associates grants with the app's signature and bundle ID. Use the stable self-signed identity and install script in [SETUP.md](SETUP.md). The first public build uses a new bundle ID, so existing private builds need fresh grants once.

**Can I build without installing?** Yes. `./scripts/build.sh` builds without signing or touching `/Applications`.

**Does Sotto work on Intel Macs?** No. The local MLX dependencies require Apple silicon.

## Project and credits

Sotto is built with SwiftUI, WhisperKit, FluidAudio, MLX, Sparkle, and HotKey. The model authors and converters are credited in [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md). See [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) for the code structure, [CONTRIBUTING.md](CONTRIBUTING.md) to help, and [SECURITY.md](SECURITY.md) to report a vulnerability privately.

Sotto's own source is [MIT licensed](LICENSE). Dependencies and downloaded models retain their own licenses.
