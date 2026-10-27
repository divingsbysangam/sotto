---
status: complete
priority: p1
issue_id: "002"
tags: [sotto, redesign, swiftui]
dependencies: []
---

# Integrate navigation and truthful dictation status (phase 2)

## Problem Statement

The reviewed prototype is separate from the live app. Dashboard navigation is inactive and menu-bar readiness does not reflect models or permissions.

## Findings

- Speech engines and history already use Observation; Dashboard caches stale snapshots.
- OutputService returns outcomes but ignores clipboard write and paste-dispatch failure.
- Scratchpad append ignores the SQLite save result.
- The current branch contains pre-existing meeting removal and speech changes to preserve.

## Proposed Solutions

1. Shared pure presentation mapping, explicit destination routing, generation-scoped output feedback, and service-free rendering components. Reuses existing operations and supports deterministic tests.
2. Separate UI-specific state and notifications per surface. Smaller initial changes, but duplicates readiness logic and can diverge.

## Recommended Action

Implement option 1 on the current branch. Keep public commands, preferences, schemas, download policy and dictation gestures intact. Capture only synthetic content for review. Continue later functional phases after the plan's integrated review.

## Acceptance Criteria

- [x] Destination and settings-subsection routing works from Dashboard/menu/recovery actions.
- [x] Dashboard observes history changes and retains all existing metrics.
- [x] Shared status prioritizes recording/processing and reports effective-engine readiness.
- [x] Output messages reflect actual copy/paste dispatch/note persistence results; new operations clear stale feedback and late completions are ignored.
- [x] Meaningful phase changes have accessible announcements; meters remain local.
- [x] Mapping, routing, output lifecycle and real SQLite/observation integration tests pass.
- [x] Build/install succeeds, screenshots and manual acceptance handoff recorded.

## Work Log

### 2026-10-27 — Implementation started

- User invoked ce:work after the prototype handoff; continuing on the existing branch.
- Read the plan, ce:work and file-todos instructions; inspected output, model, history and navigation chains.
- Paused the workspace watcher and saved the pre-edit baseline under `.context/redesign-phase2-before/`.

### 2026-10-27 — Verified and handed off for integrated review

- Added shared presentation/routing, actual-result feedback, generation guards, reactive Dashboard updates and effective-engine recovery.
- Final suite: 32 tests passed, one benchmark skipped, zero failures; ten new state/storage/output tests.
- Release build, stable signing, install and launch succeeded. Captured empty-history navigation and non-content settings under `.context/redesign-phase2/`.
- Investigated Sangam's Accessibility question: no TCC reset or grant, unchanged signing requirement, normal launch visibly confirms both permissions Allowed. Updated the page to label existing grants and hide unnecessary actions. Added missing hardened-runtime Audio Input capability and build guard based on concrete local TCC diagnostics.
- Restored the original dev watcher. Full acceptance and later phases remain in the original plan; detailed limitations and local monitoring/validation are in `docs/plans/2026-10-27-native-ui-phase2-review.md`.
- Commit/PR deferred to the phased review; pre-existing changes remain separate.
