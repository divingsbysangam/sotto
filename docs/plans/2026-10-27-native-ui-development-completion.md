# Native macOS redesign — development completion

All four implementation phases are complete. Sangam authorized proceeding through development without additional phase review gates. Installed-app acceptance remains a separate human review.

## Result

- Dashboard, Transcripts, App Modes, Vocabulary, Settings and Help share system appearance, semantic colors, native controls and readable content surfaces. MainWindowView now contains navigation rather than all workflow implementations.
- Dashboard and menu bar share recording, processing, readiness, recovery and actual output feedback. Navigation opens the requested destination/settings section. Recent transcripts and statistics observe underlying changes; narrow recent rows keep text above metadata.
- Transcripts expose Copy, Details and More for the selected entry, plus inline Retry for failed entries with retained audio. Existing raw/cleaned text, versions, audio playback, reprocessing and deletion handlers remain in use.
- App Modes retain matching/import/export behavior. Vocabulary rejects case-insensitive duplicates while preserving spelling/order. Settings retains General, Transcription and System. Help reflects local speech engines and the configured shortcut.
- Scratchpad retains note selection, dictation routing and persistence, and reports pending/saved/failed writes. Failed writes retain the draft in memory and can be retried by flushing.
- Onboarding retains its microphone → Accessibility → shortcut → practice → optional Screen Context sequence.

## Listener

Settings → General → Recording Indicator Style now offers:

1. **Bottom capsule + dot**: centered above the Dock on the recording screen, with live text when enabled.
2. **Dot near writing**: a small teal dot that tracks the caret or falls back to the pointer during recording/processing. Per-app dot exclusions fall back to the bottom listener when recording starts.
3. **Floating window**: the larger alternative with Cancel, transcript preview and the existing paste countdown.

Stored `minimal` and `floating` values are unchanged; the new dot choice is additive. Existing preferences were not overwritten. Every recorder is a nonactivating panel. Generation guards prevent old hide/countdown/notice completions from affecting newer work. Audio meter updates do not rebuild the floating panel or reset its countdown. Undo, context/mode indicators and correction prompts are retained.

The design uses macOS 26+ `glassEffect(.regular)`, `GlassEffectContainer` and native glass primary buttons for floating controls. Reading/editing content stays opaque. Older systems use native material/bordered controls; Reduce Motion, Reduce Transparency and increased contrast have custom fallbacks. This follows Apple's [adoption guidance](https://developer.apple.com/documentation/technologyoverviews/adopting-liquid-glass) and [custom-view guidance](https://developer.apple.com/documentation/swiftui/applying-liquid-glass-to-custom-views), checked on October 27, 2026. The caret-adjacent dot reference was verified against Monologue's public [Meet the Dot release notes](https://www.monologue.to/changelog?platform=macos); no Monologue app or private data was inspected.

## Repeated permission prompts

The installed app retained its existing microphone and Accessibility grants. An earlier direct executable launch had different privacy attribution, and a later screenshot helper ran from Xcode's temporary hosted test app. TCC logs attributed those screen-capture requests to the DerivedData test app and its `screencapture` helper, rather than the installed signed application. That screenshot route was removed from both test and standalone preview tools.

Automated layout images now render only their own NSView tree. Synthetic test settings/history/audio are isolated; test recording/startup/launch-at-login paths are disabled. Native glass was separately inspected through the existing computer-use connection in a service-free synthetic preview. No TCC reset, permission grant, signing-certificate replacement, or security-settings change was performed.

The installed designated requirement remains:

```
identifier "com.sotto.app" and certificate root = H"e75c25efa5e5e5bbf2bde3126f2ceb40dcb49c45"
```

`com.apple.security.device.audio-input` is generated from project.yml and checked by the install script. Launch the installed `/Applications/Sotto.app` normally; development test binaries are not a substitute for checking its privacy status.

## Verification evidence

- Final Release XCTest run: **42 passed, one opt-in real-model benchmark skipped, zero failures** (43 total). Log/result bundle: `.context/redesign-completed-tests.log` and `.context/redesign-completed-tests.xcresult`.
- Coverage includes presentation priority, effective fallback readiness, navigation, stale output rejection, real named-pasteboard writes, actual SQLite transcript versions/note persistence/failure, vocabulary deduplication, panel nonactivation, hide/show races, countdown continuity/exactly-once delivery, stale countdown cancellation, preference compatibility and negative-display/Dock placement.
- Actual product-view fixtures rendered in 21 light/dark/narrow/error/supporting-window cases under `.context/redesign-rendered-ui/`. These verify layout only: native glass/vibrancy and some system selections are not fully composited in NSView bitmap caching. They do not prove permission state or live speech behavior.
- Native compositor screenshots of the real shared listener views with synthetic inputs: `.context/redesign-listener-glass.png` and `.context/redesign-dot-glass.png`. No private transcript/note content was captured or publicly uploaded.
- `./scripts/build-and-install.sh` succeeded, installed to `/Applications/Sotto.app`, and launched normally. Log: `.context/redesign-development-install.log`. Deep/strict signature verification passed; stable certificate requirement and Audio Input entitlement inspected on the installed artifact. The original watcher was resumed.
- After the watcher's rebuild/relaunch, the installed Dashboard reported Whisper ready; General displayed all three listener choices with the existing bottom preference retained. System explicitly reported **Microphone: Allowed** and **Accessibility: Allowed**, without any grant action. Evidence: `.context/redesign-final-permissions.png`. The installed bundle contains no hosted XCTest plugin.
- `git diff --check` and shell syntax checks passed. The current branch and unrelated prior working-tree changes, including meeting removal and speech-engine work, were preserved. No commit, push or PR bundled those changes.

## Remaining human acceptance

Live spoken dictation with hold/double-tap/Escape, actual paste insertion and focus, clipboard fallback, Scratchpad voice input, caret tracking across real apps/displays, import/cancel/retry with a real model, full keyboard traversal, VoiceOver and system-level accessibility display settings remain interactive acceptance checks. Older macOS runtime checks were unavailable. Automated callback/panel tests and synthetic renders do not replace these checks.

## Post-Deploy Monitoring & Validation

Owner: Sangam during the next installed-app dictation session. Inspect local Console subsystem `com.sotto.app`, categories AppState/Transcription/Notes, for model readiness, output failure and note-save errors. Healthy behavior is correct destination routing, truthful completion, preserved focus, no stale panel/countdown callbacks, and saved notes surviving reopen. Wrong-app paste, false success, lost drafts, or recurring normal-app permission prompts are mitigation triggers: recover text through Transcripts/open notes, stop the affected flow, and revert only redesign changes using the baselines in `.context/redesign-phase2-before/` and `.context/redesign-final-before/`. No telemetry or hosted monitoring was added.
