# Privacy

Sotto turns your voice into text on your Mac. It has no accounts, no analytics and no telemetry. Your audio, transcripts, vocabulary and screen contents are not sent to the author or to any service.

## What stays on your Mac

- **Audio** is recorded to a temporary file and deleted after each dictation. If you cancel a recording of 20 seconds or more, it is held for 10 seconds so you can undo the cancel, then deleted. You can opt in to keeping recordings for a day, a week or forever (Settings → General → History & Audio). They are off by default.
- **Transcripts** are saved to a local history so you can search, copy and re-run them. You choose how long they are kept (1 day, 1 week, 1 month or forever). Deleting a transcript also deletes its kept audio.
- **Vocabulary, replacements, snippets, App Modes and Scratchpad notes** are stored locally.
- **Speech recognition** runs on-device with Whisper by default, or with Parakeet or Cohere Transcribe if you install them.
- **Text cleanup** runs on-device: Apple Foundation Models (on macOS 26 or later with Apple Intelligence), an optional local model you download, or a built-in rule-based cleaner. Nothing is sent to a hosted AI service.
- **Screen context** (optional) reads text on your screen with Apple's Vision framework to improve spelling. The screenshot and the text stay on your Mac.
- **Selected and recently copied text** (optional) can be used as spelling context for cleanup. It is not pasted, saved or logged.
- **Voice vs Keyboard** (optional, off by default) records only two numbers per day: how many characters you typed and how long you were typing. It never records which keys you pressed.

Where things are stored is listed in [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md#data-on-disk).

## What goes over the network

Sotto contacts the network only for these two things:

1. **Model downloads from Hugging Face** (`huggingface.co`). This happens when you ask for it: Whisper the first time you use it, and the optional Parakeet, Cohere and cleanup models when you choose Download. Hugging Face sees the usual request details, such as your IP address and which file is requested. The files are checked against pinned SHA-256 hashes. No audio or text is uploaded.
2. **Update checks** through Sparkle. The app fetches an appcast file from this project's GitHub repository (`raw.githubusercontent.com`) and downloads updates from GitHub Releases. GitHub sees the usual request details, and the request identifies the app and its version. Sotto does not enable Sparkle's system profiling, so no hardware profile is sent.

After the models are installed, dictation works with no network connection.

## Permissions

| Permission | What Sotto uses it for |
|---|---|
| Microphone | Recording your voice |
| Accessibility | Pasting into the active app, finding the text caret, reading the browser address bar for App Modes. Password fields are never read. |
| Screen Recording | Optional screen context |
| Apple Events | Optional: pausing Music or Spotify while you dictate |
| Input Monitoring | Optional: the Voice vs Keyboard counts |

You can revoke any of these in System Settings → Privacy & Security. The features that need them stop; the rest keeps working.

## Browser history

When you dictate into a browser, Sotto reads the page address to pick an App Mode. History keeps only the site origin (`https://example.com`), never the path or query string.

## Coding-agent relay

The optional coding-agent relay exchanges short messages with Claude Code or Cursor through private files in `~/Library/Application Support/Sotto/AgentRelay`. It is off by default and local only.

## Removing your data

Quit Sotto and delete `~/Library/Application Support/Sotto/`, the Whisper model folder under `~/Documents/huggingface/models/argmaxinc/whisperkit-coreml/`, and the app's preferences (`defaults delete com.divingsbysangam.sotto`).

## Changes

If this changes, it will be noted in the release notes and in this file's history. Questions about privacy can be asked in a GitHub issue, or privately through the process in [SECURITY.md](SECURITY.md).
