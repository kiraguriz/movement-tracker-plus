# Onboarding design QA

Date: 2026-11-02. Scope: implement the selected direction in the existing native SwiftUI app and carry it through the complete first-run flow.

**Source and implementation evidence**

- Selected visual: [onboarding-reference.png](docs/onboarding-reference.png), the first displayed design option.
- Implementation: Welcome → Muse (when the coach is available; added 2026-11-03, see the last section) → About you → Body → Goal → Your plan → Today. The existing profile draft, validation, goal planner and persistence remain the source of the actual plan.
- Simulator: iPhone 17 Pro Max, iOS 27.0, 440 × 956 points, screenshots at 1320 × 2868 pixels (@3x). No iPhone Duo result is claimed.
- Reference: 852 × 1846 pixels, approximately a 390 × 845 content-only artboard. It omits system chrome. The native implementation uses the real status bar, safe areas, navigation and home indicator. This is a style implementation on the user's chosen simulator, not a claim of pixel identity across different viewport sizes.
- Full-view comparison: initial and revised (local Codex visualization files).
- Focused comparison: hero typography, count, trace and legend (a local Codex visualization file).
- Native welcome capture: welcome-zh-final.png (a local Codex visualization file).
- Final five-page captures: light and dark (local Codex visualization files). Individual full-resolution captures are in the adjacent `light-screens/` and `dark-screens/` directories. Both sets were opened and visually reviewed.

The comparison images contain both artifacts in the same input. Copies were normalized to 390 pixels wide without vertical stretching. Native status/home regions were cropped by 186/102 physical pixels; its remaining 440 × 860 point content becomes 390 × 762 pixels. The reference remains 390 × 845. The unused bottom area in the comparison is explicitly a viewport difference, not missing app content. The hero crop comparison separately normalizes each actual hero to 500 pixels wide.

**Findings and comparison history**

1. [P2, resolved] The initial sample counter lacked the reference's visual weight. The native display size increased from 136 to 180 points; hero spacing changed from 18 to 10 points and trace height from 64 to 48 points. The revised full-view and focused comparisons confirm the large counter and readable legend fit together without clipping.
2. The five-page flow preserves the reference's surface, color, numeral, control and spacing language. Existing native form controls and the plan summary were reused; the example trace uses the project's existing `TraceRepWave`. The trace is a labelled illustration and never enters workout data.
3. Final light/dark review passed: the welcome, empty About you, filled Body, selected Goal and plan preview all retain readable text, consistent grouping, reachable actions and correct appearance tokens. The Body capture uses the expected collapsed native title after scrolling to enter measurements. The plan's calculation continues below the fold and scrolls above the fixed confirmation action.

**Required fidelity surfaces**

- Fonts and typography: Chinese/English system text, bold two-line welcome title, compressed heavy monospaced numerals, readable metric labels. Content remains editable/localized text. The same explicit headline line break is localized. Native glyph shapes and safe-area spacing intentionally take precedence over rasterizing generated text.
- Spacing and layout: 20-point horizontal page margins; 32-point hero/card corners; one prominent blue example; 58-point minimum ink capsule actions; four-segment setup progress. The footer stays reachable while forms scroll and while the numeric keyboard is present. Large-text selections reflow using the existing layouts.
- Colors and tokens: existing `TracePaper`, `TraceInk`, `TraceCard`, `TraceSky`, `TraceLine`, accent and cobalt tokens. The example keeps white content on cobalt in either appearance; paper/ink actions adapt to system appearance.
- Imagery and icons: this target consists of text, controls and a motion graph, so no raster hero asset is substituted for the native UI. The source graph is represented with the existing chart shape, dashed guide and rep markers. Arrow and lock icons use SF Symbols; decorative symbols are hidden from accessibility.
- Copy and content: all 11 new catalog keys have English and Simplified Chinese values. The demo explicitly says it is an example; the privacy statement is limited to training video. Nothing suggests Muse counts reps or that all app data stays on the device.
- Accessibility and interaction: labelled icon actions, semantic selected choices, localized progress and demo description, disabled invalid forms, loading/save protection, working back navigation, editable goals and real recalculation. The main action grows with text rather than imposing a clipped fixed height.

**Validation**

- `swift test --package-path Packages/MovementKit`: 1,185 tests passed across seven targets.
- Repository tooling: eight Python checks passed.
- Proxy: 146 tests passed; dry-run build passed, with no deployment.
- Debug simulator build passed. Release simulator and unsigned Release device builds passed. A device build is compile evidence, not a physical-device acceptance test.
- iPhone 17 Pro Max: ten onboarding UI regressions passed with zero failures, including English and Chinese, the complete plan save, goal revision, preserved answers, unit conversion, age rejection/under-18 warnings, the optional equation selection, weight nudges, largest text and landscape welcome reachability.
- Full UI result: onboarding-ui-final.xcresult (a local Codex result bundle). The command exited successfully. Xcode's verbose simulator diagnostic subprocess stalled after all tests passed; stopping that subprocess allowed the result bundle to close. Subsequent screenshot checks disable verbose diagnostic collection.
- Final light/dark Chinese completion and stable screenshot captures each passed on a fresh iPhone 17 Pro Max instance, `B6F75570-FEA0-4998-8940-30E47C8D888A`, named `iPhone 17 Pro Max — Onboarding`. Both modes complete goal revision and save the reviewed target to Today. The fresh instance was necessary because the original simulator stopped responding and the existing Duo's data directory was missing; neither original device was erased. Final capture dimensions remain 1320 × 2868 pixels. Results: light and dark (local Codex result bundles).
- `git diff --check` passed. `AGENTS.md` and `CLAUDE.md` remain byte-identical. No dependency was added.

**Open questions and follow-up polish**

- [P3 / runtime diagnostic] On iOS 27, XCTest reports `Invalid frame dimension (negative or non-finite)` during numeric keyboard presentation. Its origin has not been isolated. Default and largest-text flows complete, and the reviewed captures show no corresponding overlap or unreachable controls. This diagnostic is not claimed fixed or proven to be an OS issue.
- Physical-device acceptance and iPhone Duo layout verification were not performed in this pass.
- The verified fresh 17 Pro Max instance is left running the Chinese welcome in light appearance. A separate Simulator window could not be opened: both Launch Services and the explicit Xcode `Simulator.app` path reported that the application is absent. This does not invalidate the captured native runtime or XCTest results; the report does not claim a visible Simulator window was opened.

**Implementation checklist**

- [x] Selected welcome direction implemented in native SwiftUI.
- [x] Four setup steps share the selected visual language and a single draft.
- [x] Confirmation recalculates and saves the reviewed plan.
- [x] Localization, form validation, navigation, package checks and delivery builds pass.
- [x] Final light/dark screenshots reviewed and collected for handoff; no actionable P0/P1/P2 visual differences remain within the native style implementation scope.

final result: passed

## Muse step and Muse calorie plan (2026-11-03)

Scope: the Muse choice screen after Welcome, and the Your plan page states (waiting, from Muse, adjusted, standard fallback). Run on the shared iPhone 18 Pro simulator, iOS 27.2, with the Debug canned coach (`-MTCoachStub`, `-MTCoachStubPlan`, `-MTCoachStubFail`). No live proxy or Meta call was made.

**Reviewed captures (looked at)**

- Muse step, English portrait and largest accessibility text in landscape: both actions reachable, the two cards (what Muse sees, what stays on the phone) readable, no clipping.
- Your plan, waiting: cobalt card with spinner and one line, "Use standard plan" below it, Start disabled.
- Your plan, from Muse: "From Muse" card with the stub badge and rationale above the kcal card; Start enabled.
- Your plan, offline fallback: amber notice with "Try Again" above the standard numbers; Start enabled.

**Not looked at**

- The adjusted-plan state was captured, but the adjustment notices sit below the visible area of the capture. Their presence is asserted by `testGuardAdjustmentsAreShownOnTheMusePlan`; their layout was not reviewed visually.
- The Chinese Muse screenshot was exported and its test passes, but it was not reviewed here.
- Physical device and the Pro Max size were not checked.

**Environment note**: on this simulator and runtime the keyboard does not take focus when the weight field is entered straight after the height field. The unmodified main baseline fails the same way. The onboarding UI tests dismiss the keyboard between the two fields. Not a regression from this change.

**Results**: `OnboardingUITests` 11 of 11 pass (`-parallel-testing-enabled NO`).
