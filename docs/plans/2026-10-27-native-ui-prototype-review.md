# Native UI prototype review

Historical phase 1 handoff for [the redesign plan](2026-10-27-001-feat-native-ui-redesign-plan.md). Sangam subsequently requested ce:work and phase 2 is now integrated. See the [phase 2 handoff](2026-10-27-native-ui-phase2-review.md) for current implementation and review status; the notes below record the prototype-only state at the end of phase 1.

## Review the prototype

Run from the repository root:

```bash
./scripts/preview-redesign.sh
./scripts/preview-redesign.sh --dark
./scripts/preview-redesign.sh --surface 'Minimal Overlay' --dark
./scripts/preview-redesign.sh --surface 'Floating Overlay'
./scripts/preview-redesign.sh --surface 'Menu Bar'
./scripts/preview-redesign.sh --surface 'Onboarding'
./scripts/preview-redesign.sh --surface 'Scratchpad'
```

The main preview provides six destinations, a sample state picker, empty-history switch, transcript search and details, and recovery navigation. Every action is either navigation, an in-memory edit, or a message describing a simulated action. Copy, paste, retry, dictation, permissions and downloads never run. Supporting windows are rendering prototypes; they do not exercise live panel focus, countdowns or output behavior.

The standalone host compiles only `NativeDesign.swift` and the three files in `Sotto/Views/Redesign`, plus `scripts/RedesignPreview.swift`. It cannot reference AppState, settings, history, model managers, recording or startup services. The fixture files are guarded by `#if DEBUG` and do not appear in the installed Release app. Shared design components are compiled into the app but have no live call sites yet.

## Apple design guidance, checked October 27, 2026

- [Adopting Liquid Glass](https://developer.apple.com/documentation/TechnologyOverviews/adopting-liquid-glass): native split views, toolbars, sheets and controls adopt the platform appearance. Avoid custom navigation backgrounds that obscure system effects.
- [Materials](https://developer.apple.com/design/human-interface-guidelines/materials): reserve Liquid Glass for controls and navigation; keep content readable using standard backgrounds.
- [Applying Liquid Glass to custom views](https://developer.apple.com/documentation/SwiftUI/Applying-Liquid-Glass-to-custom-views): use `.regular` glass on custom floating controls and `GlassEffectContainer` for related effects. Use the native `.glassProminent` button style for primary setup actions.

The preview uses a native sidebar and toolbar, glass dictation/Undo controls, opaque transcript and editor surfaces, semantic colors, teal emphasis, SF Symbols, and system typography. Glass APIs have macOS 26 availability checks; macOS 14–15 use standard material and bordered buttons. Reduce Transparency and increased contrast replace custom glass with opaque surfaces. Reduce Motion disables custom animations; meters use fixed sample levels without pulsing or timers.

## Captures and verification

Regenerate screenshots of only the standalone preview's own window:

```bash
./scripts/preview-redesign.sh --snapshots .context/redesign-preview
```

The matrix includes light/dark Dashboard, 500×400, 700×500 and 1100×750 content sizes, denied microphone, failed/downloading speech model, fallback engine explanation, populated/empty/no-results transcripts, retry affordance, menu-bar readiness, glass and opaque overlays, onboarding and Scratchpad. Screenshots live under `.context/redesign-preview/` and remain untracked.

The accessibility screenshots simulate **custom component** opaque backgrounds, stronger borders and disabled animations using a preview-only environment input. They do not change or verify the operating system's accessibility settings or native-control behavior. Real system Reduce Motion/Transparency, contrast, keyboard traversal and VoiceOver require interactive acceptance.

The standalone compiler targets macOS 14 using the installed Xcode SDK. Older macOS runtime behavior has not been tested. These captures show synthetic states, not evidence of live model readiness or successful output.

Live-state mapping, accurate output reporting, history refresh, full workflow extraction, permission-gated dictation/paste and installed-app acceptance remain for the subsequent phases.

## Local verification results

- Standalone prototype compilation and capture succeeded using Xcode 27.1 on macOS 27.0.1 with a macOS 14 deployment target. Capture log: `.context/redesign-preview/capture.log`.
- Existing Release XCTest suite: 22 passed, one opt-in real-model benchmark skipped, zero failures. Log: `.context/redesign-tests.log`; results: `.context/redesign-tests.xcresult`.
- Required `./scripts/build-and-install.sh` succeeded after the final app-source changes: Release build, stable self-signing, installation to `/Applications/Sotto.app`, signature verification and launch. Log: `.context/redesign-install-final.log`.
- `git diff --check` passed. Existing working-tree changes, including meeting removal, remain in place. The original dev watcher was resumed after verification.
- Live microphone, auto-paste, Screen Context, VoiceOver, real system accessibility settings and older-macOS runtime checks were not exercised by this prototype pass.
