# AGENTS.md

Guidance for AI coding agents (and people) working in the Sotto repository. The architecture is in [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md); build setup is in [SETUP.md](SETUP.md).

## What this is

Sotto is a native macOS dictation app written in Swift and SwiftUI. It builds with XcodeGen and Xcode, and uses Apple-only frameworks (SwiftUI, AppKit, AVFoundation, Vision, ScreenCaptureKit, Carbon, ServiceManagement) plus WhisperKit, FluidAudio, MLX, Sparkle and HotKey.

It needs macOS 14 or later, Xcode 26 with its Metal toolchain, and an Apple silicon Mac. It cannot be built on Linux or in a Linux container.

## Local-only design

Sotto is fully local. Do not add accounts, authentication, hosted inference, API keys or telemetry. Speech recognition and text cleanup run on the device. The only network use is model downloads that the user requests, and Sparkle update checks.

## Build and test

```bash
xcodegen generate          # after editing project.yml
./scripts/build.sh         # build only, no signing or install
./scripts/build-and-install.sh   # build, sign, install to /Applications, launch
```

Run the unit tests with the `Sotto` scheme (`xcodebuild ... test`; see [SETUP.md](SETUP.md)). Permission-gated flows (microphone, Accessibility paste, screen context) need an interactive desktop session and can't be exercised in headless CI.

After changing app code (`Sotto/**`, `project.yml`), build before calling the change done, and say whether the build passed.

## Conventions

- User-facing text says "transcript", not "transcription". Tabs are Dashboard, Transcripts, App Modes, Vocabulary, Settings and Help.
- Privacy usage descriptions, Sparkle keys and version numbers live in `project.yml` under `targets.Sotto.info.properties`. Don't add Info.plist keys by hand.
- Put deterministic text logic in `DictationTextRules` (pure functions) and test it.
- Never log or store transcript text, vocabulary, clipboard contents or on-screen text beyond what the feature needs. Log lengths, not content.
- Model files are pinned by revision and SHA-256 in `Sotto/Resources/*manifest.json`. Don't resolve model revisions dynamically.
