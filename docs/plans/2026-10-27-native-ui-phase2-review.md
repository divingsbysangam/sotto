# Phase 2: navigation and dictation clarity

Phase 2 is implemented and installed. The [original plan](2026-10-27-001-feat-native-ui-redesign-plan.md) requires integrated review after each functional phase. Main-window workflow extraction/restyling (phase 3), recording/supporting-window integration (phase 4), and final acceptance remain pending that review.

## Changes

- Shared destination routing carries Dashboard View All, menu-bar Transcripts and status recovery actions to the correct destination and Settings subsection, including requests made before the main window opens.
- Dashboard places live status and shortcut instructions before recent transcripts and usage. Words, lifetime words, time saved, transcript count, average speed, streak, activity, top sources and the opt-in voice/keyboard comparison remain available. History mutation and typing-setting changes refresh the data; typing counts refresh every 30 seconds and date changes refresh statistics.
- Dashboard and menu bar share status mapping for recording, processing, microphone access, model installation/download/verification/loading/failure/readiness, effective Whisper fallback and actual output results. Audio levels remain in a local menu subview; accessible announcements follow primary status titles rather than meter updates.
- Copy feedback checks the clipboard write result. Paste feedback checks command dispatch and exposes copy-only fallbacks; `Pasted` describes a dispatched paste command, not independently observed insertion into another app. Scratchpad reports saved only after SQLite success and preserves the open note in memory after failure.
- New-operation generations clear prior outcomes and reject late callbacks. Cancelled or superseded output is checked before paste dispatch; old output callbacks and delayed notices cannot reset a newer operation's visible state. History retains completed text for recovery.

## Accessibility permission question

No TCC reset or permission grant was performed. Installed signatures before and after the redesign have the same designated requirement: bundle identifier `com.sotto.app` and certificate root fingerprint `e75c25efa5e5e5bbf2bde3126f2ceb40dcb49c45`.

The direct verification launch was attributed to Conductor in local TCC logs and showed a different microphone status from a normal application launch. Separately, the initial Permissions section always displayed an Open Accessibility Settings button even when permission was already allowed. The section now polls permission status, explicitly displays Microphone/Accessibility Allowed, and only shows each recovery action when the corresponding permission is missing.

After a normal launch of the final installed build, the app visibly reported **Microphone: Allowed** and **Accessibility: Allowed**, without changing either grant. The normal Dashboard also reported Whisper ready. Evidence: `.context/redesign-phase2/permissions-allowed.png`.

Local TCC logs also identified a missing hardened-runtime Audio Input entitlement. Added `com.apple.security.device.audio-input` to `project.yml` (the source of generated entitlements), plus a pre-install script guard against losing it again. The installed signature contains the entitlement and retains the same signing requirement. See Apple's [Audio Input entitlement documentation](https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.security.device.audio-input).

## Verification

- Final XCTest run: **32 passed, one opt-in real-model benchmark skipped, zero failures**. Ten new tests cover status priority/model phases, fallback readiness, destination routing, stale feedback, actual named-pasteboard writes, observed history mutations and real SQLite note success/failure. Tests use isolated stores/pasteboards, never the general clipboard or personal history. The history test updates existing synthetic rows to avoid invoking the live audio-retention job.
- Final suite: `.context/redesign-phase2-tests-final.log` and `.context/redesign-phase2-tests-final.xcresult`.
- Release build, stable self-signing, installation, signature verification and normal launch succeeded. Log: `.context/redesign-phase2-install-final.log`.
- Installed artifact verified with `codesign --verify --deep --strict`; Audio Input entitlement and the unchanged designated requirement inspected in the actual `/Applications/Sotto.app` signature.
- Installed UI: Dashboard View All selected Transcripts. Dashboard speech recovery selected Settings → Transcription. System settings displayed both existing grants as Allowed. No permission buttons or grants were activated during verification.
- Safe UI evidence used `open -n --env SOTTO_TESTING=1 /Applications/Sotto.app`: Launch Services preserves normal privacy attribution while test mode isolates history and disables startup services. That run appropriately reports the engine not loaded because auto-loading is disabled. Normal runtime was separately checked for permissions and model readiness.
- Captures: `.context/redesign-phase2/dashboard-700-light.png`, `view-all-transcripts.png`, `speech-recovery.png`, and `permissions-allowed.png`. Only empty test history and non-content settings were captured. No public image uploads or PR publication occurred.
- `git diff --check` and shell syntax checks passed. Original branch and pre-existing changes were retained. The original dev watcher was resumed after controlled verification.

## Remaining acceptance checks

Live microphone input, hold/double-tap/Escape, auto-paste focus, actual clipboard fallback, both recording overlays, Scratchpad dictation, rapid stop/start, menu popover navigation, full keyboard traversal and VoiceOver require interactive review. Runtime checks with real Reduce Motion/Transparency/contrast settings and older macOS versions remain unperformed.

The integrated UI was inspected at its current 700×500 window size. Native edge resizing through automation did not change the window, so live 500×400 and 1100×750 acceptance remains manual. The prior standalone prototype covers those sizes and light/dark/custom-accessibility fixtures; that evidence is not a substitute for live runtime acceptance. A process-only dark appearance override did not change the installed app's appearance, so live dark-mode acceptance is also pending.

## Post-Deploy Monitoring & Validation

Owner: Sangam during installed-app review and the next local dictation session. Search local Console for subsystem `com.sotto.app`, categories AppState/Transcription/Notes, and outcome/model-load/save-failure messages. Healthy behavior is correct routing, readiness for the effective engine, actual-result completion text, and a cleared outcome when work begins. Treat wrong-app paste, false success, stale notices or lost note persistence as a rollback/mitigation trigger: retain text in Transcripts or the open note and revert only redesign changes using the baseline in `.context/redesign-phase2-before/`.

No telemetry, hosted monitoring or deployment was added. A local PR-description draft with the validation plan is saved in `.context/redesign-phase2-pr-draft.md`. Commits/PR publication are deferred until the phased review is complete; the working tree also contains unrelated prior work that must remain separate.
