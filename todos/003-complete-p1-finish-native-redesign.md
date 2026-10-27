---
status: complete
priority: p1
issue_id: "003"
tags: [sotto, redesign, swiftui]
dependencies: ["002"]
---

# Complete the native redesign through development verification

## Problem Statement

Main-window workflows and live recording/supporting windows still use the previous presentation. Sangam requested all remaining phases through the end of development without further phase review gates.

## Findings

- MainWindowView contains settings, help, vocabulary, transcripts and mode editors in 2,205 lines.
- Floating recording reconstructs its hosting view for every audio update; cursor hide completion has no generation guard.
- Capsule and cursor use decorative continuous pulsing, hardcoded dark colors and long slide animations.
- Existing handlers already cover versions, reprocessing, audio, matching, import/export and note routing.

## Proposed Solutions

1. Extract workflows, reuse their operations, share native design components and generation-safe panel presentation. This preserves behavior while making styling consistent.
2. Rewrite all workflows and services together. This would unnecessarily change storage and dictation behavior.

## Recommended Action

Implement option 1 sequentially in the main thread. Preserve existing changes and the current branch. Finish builds, meaningful tests, local UI evidence and installation. User acceptance is reported separately from development completion.

## Acceptance Criteria

- [x] Main-window workflows extracted and restyled; visible transcript actions and inline retry preserve existing behavior.
- [x] Shared native settings/list/editor/empty-state treatments and validation; import/export and matching remain intact.
- [x] Recording surfaces use native glass controls with readable content and accessibility fallbacks.
- [x] Nonactivating panels, timers, cancellation, live text, mode/context prompts and Undo preserved; stale hide/countdown completions guarded.
- [x] Onboarding and Scratchpad restyled without changing permission sequence or routing.
- [x] Meaningful lifecycle/workflow tests and existing suite pass; review evidence and remaining interactive limitations recorded.
- [x] Final build, stable signing, install and launch succeed; watcher restored and permissions retained.

## Work Log

### 2026-10-27 — Started remaining phases

- User explicitly authorized continuing all remaining phases through development completion, superseding intermediate review gates.
- Paused the watcher and saved the current source baseline under `.context/redesign-final-before/`.
- Extracted workflow source files without changing their handlers as the first step.

### 2026-10-27 — Development complete

- Finished all remaining workflows, recording/supporting windows and bottom/dot listener choices.
- Final suite: 42 passed, one optional real-model benchmark skipped, zero failures. Added real panel/countdown, SQLite workflow, preference and placement checks.
- Removed screen-capture helpers after their hosted test-app privacy attribution caused extra permission prompts. Own-view rendering and service-free synthetic UI review need no new grants.
- Build/install succeeded with the unchanged stable signing requirement. Resumed the original watcher and verified its relaunched installed app shows Microphone and Accessibility Allowed, plus the new listener choices.
- Handoff: `docs/plans/2026-10-27-native-ui-development-completion.md`. Live speech/paste, hardware/display and accessibility acceptance remain explicitly manual. Unrelated prior work was preserved.
