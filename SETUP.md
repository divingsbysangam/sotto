# Building Sotto from source

Sotto is a fully local, offline dictation app for macOS. No account, no API keys and no Apple Developer account are needed to build or run it.

This page takes a fresh clone to a running app. For how the code is organised, see [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md).

## What you need

| | Requirement |
|---|---|
| Mac | Apple silicon. The MLX packages Sotto uses don't support Intel. |
| macOS to **build** | macOS Sequoia 15.6 or later (Xcode 26 won't run on older macOS) |
| macOS to **run** Sotto | macOS 14 or later |
| Xcode | Xcode 26 or later, with the command-line tools selected |
| Metal toolchain | Downloaded separately by Xcode 26 (see below) |
| XcodeGen | `brew install xcodegen` |
| Disk space | A few GB for Xcode's package builds, plus 1.6 GB for the Whisper model when you first run the app |

Apple Intelligence is optional. With it (macOS 26 or later), text cleanup uses Apple's on-device model. Without it, Sotto uses a built-in rule-based cleaner.

## Build from a fresh clone

```bash
git clone https://github.com/divingsbysangam/sotto.git
cd sotto

brew install xcodegen
xcodebuild -downloadComponent MetalToolchain   # once; mlx-swift compiles Metal kernels

./scripts/build.sh          # generates the project, builds Debug into build/DerivedData
./scripts/build.sh test     # builds and runs the unit tests
```

The first build downloads the Swift packages and compiles the MLX Metal kernels, so it takes several minutes. Later builds are much faster.

`./scripts/build.sh` needs no signing identity and installs nothing. The result is `build/DerivedData/Build/Products/Debug/Sotto.app`. Set `CONFIGURATION=Release` for a Release build.

### Why XcodeGen

`project.yml` is the source of truth for targets, packages, Info.plist keys, entitlements and the version number. `Sotto.xcodeproj` is generated from it (and committed so Xcode users can open it straight away). Edit `project.yml`, not the `.xcodeproj`, then run `xcodegen generate` or any script above, which does it for you.

### Opening it in Xcode

Run `xcodegen generate`, open `Sotto.xcodeproj`, and press ⌘R. On the first build Xcode asks you to trust build plugins and macros from some packages (for example mlx-swift and swift-transformers). Choose **Trust & Enable**. The command-line scripts pass `-skipPackagePluginValidation -skipMacroValidation` for the same reason: `xcodebuild` can't show that prompt.

### Swift versions

You need Xcode 26 or later, and its Swift 6.2 compiler builds the project. The project itself still compiles in **Swift 5 language mode** (`SWIFT_VERSION` is `5.9` in `project.yml`). The compiler version and the language mode are separate settings: a Swift 6.2 compiler builds Swift 5 mode code without changes. Moving the code to Swift 6 mode (strict concurrency) hasn't been done.

## Run it with permissions that stick

macOS ties the Microphone, Accessibility and Screen Recording grants to the app's code signature. A build signed ad-hoc gets a new signature each time, so macOS asks again after every rebuild. A free self-signed certificate fixes that. You can skip this if you only want to build.

```bash
./scripts/create-signing-cert.sh     # once; creates the "Sotto Self-Signed" identity
./scripts/build-and-install.sh       # build, sign, install to /Applications, launch
```

If a previous run left a broken identity, run `./scripts/create-signing-cert.sh --force`.

`build-and-install.sh` refuses to install with an ad-hoc signature unless you set `ALLOW_ADHOC_SIGN=1`. To keep rebuilding and relaunching while you work, run `./scripts/dev-watch.sh`.

Check the installed signature:

```bash
codesign -dv --verbose=4 /Applications/Sotto.app 2>&1 | grep -E 'Authority|Signature|Identifier'
```

You should see `Authority=Sotto Self-Signed` and the identifier `com.divingsbysangam.sotto`, and not `Signature=adhoc`. Do not run `tccutil reset`; it clears your grants.

## First launch

Grant these when prompted, or later in System Settings → Privacy & Security:

- **Microphone** to capture your voice.
- **Accessibility** to paste into the focused app.
- **Screen Recording** only if you turn on Settings → General → Screen Context.

Sotto then downloads the Whisper Large v3 Turbo model (about 1.6 GB, once) into `~/Documents/huggingface/models/argmaxinc/whisperkit-coreml/`. After that, dictation works offline. Settings → Transcription shows progress, "Model ready", or an error with a **Retry** button.

Parakeet TDT v3 (about 0.5 GB) and Cohere Transcribe (about 1.5 GB) are optional English engines. Choose **Download**, then **Load Model**, in Settings → Transcription. Details, pinning and benchmarks are in [docs/local-speech-engines.md](docs/local-speech-engines.md).

## Tests

```bash
./scripts/build.sh test
```

This runs the unit tests in `SottoTests/` unsigned and offline. The speech-engine benchmark is skipped unless you opt in (see [docs/local-speech-engines.md](docs/local-speech-engines.md)). The same command runs in CI on every pull request.

Microphone capture, Accessibility paste and screen context need an interactive desktop session with permissions granted, so they aren't covered by the automated tests.

## Always on (optional)

"Launch at Login" is on by default (Settings → System). For an extra LaunchAgent that also relaunches Sotto after a crash:

```bash
./scripts/install-launch-agent.sh              # install
./scripts/install-launch-agent.sh --uninstall  # remove
```

If you use it, turn off "Launch at Login" inside Sotto to avoid starting twice.

## Troubleshooting

### `xcodegen: command not found`
Run `brew install xcodegen`.

### The build fails with a Metal error
The Metal toolchain is missing or outdated. Run `xcodebuild -downloadComponent MetalToolchain`, then build again. Check with `xcrun metal --version`.

### `xcodebuild` says Xcode isn't selected
Run `sudo xcode-select -s /Applications/Xcode.app/Contents/Developer`.

### Packages won't resolve or the build is stuck
Delete `build/DerivedData` and build again. If it still fails, remove Xcode's package cache: `rm -rf ~/Library/Caches/org.swift.swiftpm`.

### Auto-paste isn't working
Enable Sotto in System Settings → Privacy & Security → Accessibility. Without it, Sotto copies the text and the capsule says so.

### Permissions reset after a rebuild
You're signing ad-hoc. Run `./scripts/create-signing-cert.sh`, then `./scripts/build-and-install.sh`, and check that it reports signing with `Sotto Self-Signed`.

### `create-signing-cert.sh` fails, or the identity is missing
The script imports the certificate and key separately with the stock macOS `openssl`, then trusts the certificate for code signing. If `security find-identity -v -p codesigning | grep "Sotto Self-Signed"` finds nothing, try `./scripts/create-signing-cert.sh --force`. To do it by hand:

1. Open **Keychain Access**, then **Certificate Assistant → Create a Certificate…**
2. Name: `Sotto Self-Signed`. Identity Type: Self Signed Root. Certificate Type: Code Signing.
3. Select the new certificate, **Get Info → Trust → Code Signing → Always Trust**.
4. Check with the `security find-identity` command above.

### "Loading model…" never finishes
Open Settings → Transcription. If it shows an error, click **Retry**. Downloads resume where they stopped, and corrupt or empty model files are deleted before retrying.

### Sotto isn't in the menu bar
Check that it's running (Activity Monitor, search "Sotto").

## License

MIT. See [LICENSE](LICENSE). Third-party components and downloaded models keep their own terms; see [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).
