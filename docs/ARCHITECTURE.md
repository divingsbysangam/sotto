# Sotto architecture

Sotto is a macOS app for voice dictation. You hold a key, speak, and the text appears in the app you were using. The name comes from "sotto voce", speaking softly.

Everything runs on your Mac. There are no accounts, no API keys, no cloud services and no telemetry. The only network traffic is model downloads you ask for, and Sparkle update checks. Please keep it that way: do not add hosted inference, auth gating or analytics.

This page is the map for contributors. Build instructions are in [SETUP.md](../SETUP.md).

## Stack

| Piece | Choice |
|---|---|
| Language / UI | Swift 5 language mode (built by Xcode 26's Swift 6.2 compiler), SwiftUI with some AppKit |
| App shape | Dock and menu-bar app, state in `@Observable` objects |
| Project generation | XcodeGen (`project.yml` generates `Sotto.xcodeproj`) |
| Audio | AVFoundation (`AVAudioEngine`) |
| Speech | WhisperKit |
| Text cleanup | Apple Foundation Models on macOS 26+, or a rule-based cleaner |
| Screen context | Apple Vision OCR on a ScreenCaptureKit capture |
| Hotkeys | HotKey package plus a CGEventTap for modifier-only keys |
| Updates | Sparkle |

## The dictation pipeline

```
hotkey down ─► RecordingService (mic → WAV)
hotkey up   ─► short audio tail, then stop
            ─► TranscriptionEngineManager.transcribe
                 engine: Whisper Turbo
                 → vocabulary spelling → replacements
            ─► snippets (placeholders) → voice commands
            ─► LLMService cleanup (Foundation Models → rule-based)
            ─► snippet blocks expanded
            ─► OutputService: caret-aware casing/spacing, then paste or copy
            ─► HistoryManager / HistoryStore
```

`AppState` orchestrates this. It owns the services, the recording state machine and the capsule UI. Most behaviour changes start there.

The deterministic text steps (vocabulary, replacements, snippets, voice commands, caret adaptation, spoken file names) are pure functions in `DictationTextRules`. They read no settings and do no I/O, so they are the easiest code to test.

## Source layout

```
Sotto/
  SottoApp.swift             @main, windows, menu bar, launch setup
  AppState.swift             central state and pipeline orchestration
  Intents/                   App Intents (start/stop dictation, switch mode, ...)
  Models/
    AppSettings.swift        all user settings (UserDefaults)
    AppMode.swift            App Modes: per-app/site cleanup prompts
    TranscriptionHistory.swift, HistoryStore.swift   history + SQLite store
    VocabularyRules.swift    replacements and snippets models
    NotesManager.swift       Scratchpad notes
  Services/
    RecordingService.swift, AudioInputDevices.swift, AudioArchive.swift
    TranscriptionEngine.swift, TranscriptionEngineManager.swift
    LocalTranscriptionService.swift        WhisperKit
    LLMService.swift                       cleanup (Foundation Models / rules)
    DictationTextRules.swift               pure text rules
    HotkeyManager.swift, HotkeyGestureClassifier.swift, ModifierKeyMonitor.swift
    OutputService.swift, CursorPositionService.swift, CorrectionWatcher.swift
    ScreenCaptureService.swift, ClipboardWatcher.swift, BrowserURLService.swift
    AppCatalog.swift, WorkspaceIndexService.swift
    FileTranscriber.swift                  audio/video import
    AgentRelayService.swift, AgentRelayProtocol.swift
    SpeechService.swift                    read aloud
  Views/                     SwiftUI views and the capsule / caret-dot windows
  Resources/                 app-catalog.json, Whisper model manifest
SottoCLI/                    `sotto` command-line helper (history, agent hook)
SottoTests/                  unit tests
scripts/                     build, signing, release and maintenance scripts
```

## Speech engine

`TranscriptionEngine` is the shared interface. `TranscriptionEngineManager` routes dictation and imports to Whisper and applies vocabulary corrections.

- **Whisper Large v3 Turbo** handles dictation, imports, language detection, translation, and live preview.
- Transcriptions run one at a time.

Model files are pinned. `Resources/model-manifest.json` records the upstream revision, byte count and SHA-256 of every file. The app verifies them before loading, and a mismatch triggers a repair download instead of loading the file. Never resolve model revisions dynamically in the shipping app.

## Hotkeys

One dictation key and one gesture classifier (`HotkeyGestureClassifier`):

- **Hold** (0.6 s or more): push-to-talk, release to stop.
- **Double-tap** (second press within 1 s): hands-free; tap once to stop.
- **Hold + Space**: switch to hands-free mid-hold.
- **Tap under 0.4 s**: silently discarded.
- **Esc**: cancel without transcribing.

Fn, right Option and right Command can be the dictation key; `ModifierKeyMonitor` is an event tap on its own thread that always passes events through. A mouse button can also trigger dictation.

## App Modes

An `AppMode` selects cleanup instructions by the frontmost app, the website (read from the browser's address bar over Accessibility, so any browser works) or a category from `Resources/app-catalog.json`. Resolution order: exact app name, website, loose app name, catalog category. Modes can be imported and exported as JSON (`ModeTransferService`). Per mode you can skip cleanup, press Return after pasting, or translate to English.

## Cleanup

`LLMService` tries Apple Foundation Models, then `RuleBasedCleaner`. Model output passes `LLMService.validate`, which rejects outputs that drop snippet placeholders, repeat Sotto's own prompt wording, copy a prompt example, come back empty, or rewrite more than a light edit allows. Rejected output falls back to the rule-based cleaner. Selected or recently copied text can be given to the cleaner as spelling context only. It is never pasted, saved or logged.

## Paste safety

A dictation is pasted only into the app that was frontmost when recording started. If you switched apps, the text stays on the clipboard and the capsule says so. Without Accessibility permission, Sotto copies the text and says how to enable auto-paste, instead of showing a modal alert.

## Data on disk

| Data | Location |
|---|---|
| Settings | `UserDefaults` for the app's bundle ID |
| History | `~/Library/Application Support/Sotto/history.sqlite` (SQLite with FTS5; Scratchpad notes live in the same file) |
| Kept audio (opt-in) | `~/Library/Application Support/Sotto/Audio/` |
| Optional speech models | `~/Library/Application Support/Sotto/SpeechModels/` |
| Whisper model | `~/Documents/huggingface/models/argmaxinc/whisperkit-coreml/` |
| Local cleanup model | `~/Library/Application Support/Sotto/LLM/` |
| Coding-agent relay (opt-in) | `~/Library/Application Support/Sotto/AgentRelay/` (0700 folder, 0600 files) |
| Temporary recordings | `$TMPDIR/recording_<timestamp>.wav`, deleted after each dictation |

## Permissions

| Permission | Why |
|---|---|
| Microphone | Capture speech |
| Accessibility | Auto-paste, caret position, reading the browser URL |
| Screen Recording | Optional screen context (OCR) |
| Apple Events | Optional pause of Music/Spotify while dictating |
| Input Monitoring | Optional keyboard counts for the Voice vs Keyboard card |

Usage descriptions and Sparkle keys live in `project.yml` under `targets.Sotto.info.properties`, so regenerating the project keeps them. Add new Info.plist keys there, not by hand.

## Conventions

- User-facing text says "transcript", not "transcription".
- Tab names are Dashboard, Transcripts, App Modes, Vocabulary, Settings and Help.
- Accent colour is teal `#4FD1C5` on a dark background.
- Keep the deterministic text logic in `DictationTextRules` and cover it with tests.
- Do not log transcript text, vocabulary or surrounding on-screen text.
