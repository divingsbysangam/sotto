# Contributing to Sotto

Thanks for helping. Sotto is a small macOS app maintained by one person, so a short conversation before a big change saves everyone time.

By taking part you agree to follow the [Code of Conduct](CODE_OF_CONDUCT.md). Security problems go through [SECURITY.md](SECURITY.md), not public issues.

## What fits

Sotto is local-first, and that is a design rule, not a preference. Changes that add accounts, hosted inference, API keys, analytics or telemetry won't be merged. Bug fixes, accuracy and reliability improvements, accessibility, tests, documentation and new on-device capabilities are all welcome.

For anything larger than a small fix, please open an issue first and describe the problem you want to solve.

## Set up

Follow [SETUP.md](SETUP.md). You need an Apple silicon Mac on macOS 14 or later, Xcode 26 with its Metal toolchain, and XcodeGen.

```bash
git clone https://github.com/divingsbysangam/sotto.git
cd sotto
xcodegen generate
./scripts/build.sh
```

Read [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) for how the pieces fit together.

## Before you open a pull request

1. Branch from `main` and keep the change focused. One concern per pull request.
2. Build and run the tests (commands are in [SETUP.md](SETUP.md)). Add or update tests for the logic you change. Text rules, hotkey classification, vocabulary handling, cleanup validation and history migration are all pure or nearly pure and should be covered.
3. Don't edit `Sotto.xcodeproj` by hand. Change `project.yml` and run `xcodegen generate`. Info.plist keys, version numbers and Sparkle settings live in `project.yml`.
4. If you add or upgrade a dependency or a model, update [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md). Models are pinned by revision and SHA-256 in `Sotto/Resources/*manifest.json`; use `scripts/update-speech-model-manifest.py` and include the diff.
5. Don't log or store transcript text, audio, vocabulary, clipboard contents or on-screen text beyond what the feature needs. Log lengths, not content.
6. User-facing text says "transcript", not "transcription".
7. Describe what changed and why in the pull request, and say how you tested it. For UI changes, add a screenshot. Remove any personal text from screenshots first.

Maintainers may ask for changes or decline a pull request that doesn't fit the project's direction. That's not a judgement on the work.

## Reporting bugs

Use the bug report form. Include your Sotto and macOS versions and which speech engine you use. Please don't paste real transcripts or attach audio you wouldn't want public.

## Permissions while developing

Sotto needs Microphone, Accessibility and, optionally, Screen Recording. macOS ties these grants to the app's code signature. If you build with ad-hoc signing, the grants reset on every rebuild. `scripts/create-signing-cert.sh` creates a stable self-signed identity so they persist. See [SETUP.md](SETUP.md).

## License

By contributing you agree that your contribution is licensed under the [MIT License](LICENSE).
