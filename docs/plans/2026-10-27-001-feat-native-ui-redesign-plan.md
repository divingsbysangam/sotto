# Sotto: native macOS redesign for clearer dictation

## Summary

Redesign the whole app in phases using quiet native macOS styling, system light/dark appearance, restrained teal accents, consistent SF Symbols, and purposeful motion.

Prioritize understanding whether Sotto is ready, recording, processing, finished, or needs attention. Preserve the six main destinations and existing functionality. Begin with a SwiftUI preview prototype using synthetic data.

Source: [Todoist redesign task](https://app.todoist.com/app/task/6hqjJ7HGxp5RG9VW). The task contains no additional requirements. Repository inspection found inconsistent styling, an inactive Dashboard “View All” button, and a menu-bar “Ready” label that considers recording state without checking model readiness.

## Design and behavior

- **Visual system:** Use semantic system backgrounds and text colors, system typography, 4/8/12/16/24-point spacing, and consistent 12-point rounded content surfaces. Reserve teal for emphasis and primary actions. Use native controls and selection treatments.
- **Icons:** Centralize interface symbols and their accessible labels. Use consistent outline symbols for navigation/actions and filled variants for status emphasis. Retain the existing app icon, name, and menu-bar identity. Follow Apple’s [SF Symbols guidance](https://developer.apple.com/design/human-interface-guidelines/sf-symbols).
- **Motion:** Use approximately 150 ms feedback transitions and 200 ms panel/content transitions. Animate actual state changes; remove decorative continuous pulsing. Keep audio meters local to their views. Reduce Motion disables movement and pulsing; Reduce Transparency uses opaque surfaces. Follow Apple’s [motion guidance](https://developer.apple.com/design/human-interface-guidelines/motion).
- **Materials:** Let standard controls adopt their platform appearance. Avoid custom glass behind reading/editing content; retain macOS 14 compatibility. Apple’s [adoption guidance](https://developer.apple.com/documentation/TechnologyOverviews/adopting-liquid-glass) supports using standard components across platform versions.
- **Accessibility:** Provide keyboard access, visible focus, tooltips and VoiceOver labels for icon buttons. Pair status colors with text and symbols. Announce meaningful phase changes without announcing every audio-level update.

## Implementation phases

Execution tracking (2026-10-27):

Sangam subsequently authorized all remaining phases through development completion. Intermediate review gates below are superseded by that instruction; final human acceptance and unavailable interactive checks will be reported separately.

- [x] Phase 1: reusable foundation and synthetic prototype, captures and local verification.
- [x] Continue to live integration requested with ce:work after prototype handoff.
- [x] Phase 2: navigation, shared status, live Dashboard and actual output feedback.
- [x] Phase 2: developer integration verified; intermediate human gate superseded by Sangam's instruction.
- [x] Phase 3: main-window workflow redesign, extraction and developer verification.
- [x] Phase 4: recording/supporting windows, bottom/dot listener options and developer verification.
- [x] Final Release tests, stable-signed installation and local review evidence. See [development completion](2026-10-27-native-ui-development-completion.md).
- [ ] Final installed-app acceptance and remaining interactive checks.

### 1. Design foundation and preview review

Create reusable status, section, empty-state, shortcut, and transcript-row components. Separate their rendering inputs and action closures from service access.

Build SwiftUI previews for Dashboard, Transcripts, speech settings, menu-bar content, both recording overlays, onboarding, and Scratchpad. Include light/dark, narrow layouts, errors, and accessibility variants.

Use synthetic fixtures only: previews must not initialize live recording, model downloads, history stores, permissions, or startup services. Capture review images under `.context/`. Review the prototype with Sangam before connecting the redesigned surfaces to live services.

### 2. Navigation and dictation clarity

- Retain Dashboard, Transcripts, App Modes, Vocabulary, Settings, and Help.
- Add internal destination-aware navigation so Dashboard “View All,” menu-bar Transcripts, and recovery links open the correct destination and settings subsection.
- Reorganize Dashboard into readiness and shortcut guidance, recent transcripts, then usage statistics. Retain existing metrics but remove motivational banners from the primary hierarchy.
- Make recent transcripts and statistics refresh when their underlying data changes.
- Introduce a shared presentation model derived from existing recording, engine, permission, and output states. Show recording/processing first; otherwise show the current outcome or actionable failure, followed by readiness.
- Distinguish missing microphone permission, model not installed, downloading, verifying, loading, model failure, and ready. Accessibility denial remains a clipboard fallback with guidance.
- Report “Copied,” “Pasted,” or “Saved to Scratchpad” only from actual output results. Clear stale outcomes when a new operation begins.
- Keep the Dashboard’s primary instruction shortcut-based so opening Sotto does not accidentally change the intended paste destination.

### 3. Main-window workflows

- **Transcripts:** Keep the searchable list and existing detail sheet. Add visible Copy, Details, and More actions for selection, plus inline Retry for failed entries with retained audio. Reuse existing handlers for versions, raw/cleaned text, playback, reprocessing, and deletion. Normalize user-facing “transcript” wording.
- **App Modes and Vocabulary:** Apply shared list, editor, toolbar, empty-state, and validation treatments. Preserve matching rules, replacements, snippets, and import/export behavior.
- **Settings:** Keep General, Transcription, and System sections; group related controls with concise explanations. Make engine readiness, effective fallback engine, download progress, and recovery actions easy to scan.
- **Help:** Use the same layout system, retain setup replay, and align instructions with current local-only behavior.

Extract the corresponding views from the oversized `MainWindowView.swift` as each surface is redesigned.

### 4. Recording and supporting windows

Apply shared status language and controls to the menu bar, minimal capsule, floating recording window, and cursor indicator.

Preserve nonactivating panels, paste focus, cancellation, countdown timing, live text, mode switching, correction prompts, and Undo. Animation completion must never dismiss a newer recording or notice.

Restyle onboarding without changing its permission sequence or optional Screen Context step. Restyle Scratchpad while preserving note selection, saving, and dictation routing.

## Interfaces and verification

**Internal changes:** Introduce shared design tokens, symbol mappings, presentation inputs, and destination routing. Pass navigation and action closures into reusable views. Add lightweight output-state reporting where existing booleans cannot accurately describe completion.

**Public compatibility:** No changes to URL commands, CLI, App Intents, stored preferences, history schemas, speech-engine selection, or model-download policy.

Verification must cover:

- Presentation-state mapping, fallback-engine readiness, stale outcome clearing, and destination routing.
- Empty/populated/search-no-results transcripts; failed retries; raw/cleaned versions; import progress and cancellation.
- Light/dark appearance, Reduce Motion, Reduce Transparency, increased contrast, keyboard navigation, and VoiceOver.
- Main-window layouts at 500×400, 700×500, and 1100×750; long labels and transcript content.
- Interactive dictation: hold/double-tap shortcuts, Escape cancellation, both overlay styles, clipboard fallback, auto-paste focus, Scratchpad, and rapid stop/start transitions.
- Existing XCTest coverage and macOS builds. Run `./scripts/build-and-install.sh` after implementation changes and report its result. Record unavailable older-macOS or permission-dependent checks explicitly.

## Assumptions and completion criteria

- Use the current working tree as the baseline, preserving unrelated changes and the removal of meetings.
- Keep Sotto local/offline, its current features, macOS 14 minimum, and existing app identity.
- Complete phases sequentially, with visual review after the prototype and integrated review after each functional phase.
- Completion requires working navigation and recovery actions, consistent truthful status across surfaces, preserved dictation behavior, and Sangam’s installed-app review.
- This planning turn changes no files or Todoist items. When implementation begins, save the approved plan as `docs/plans/2026-10-27-001-feat-native-ui-redesign-plan.md`.
