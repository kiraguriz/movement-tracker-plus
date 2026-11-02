# Additional Trace screens — 2026-11-02

Scope: the **“Every other screen · sheets, first run, states”** group in the user's redesign screenshot and
the nine appended boards in `Movement Tracker+ Redesign.html`: About you, Your body, Your goal, Train start,
Add exercise, Add set by hand, Log weight, Add meal by hand, and Live set with camera access off.

The checkout already contained uncommitted implementations of these screens. This work preserves and
completes them. The separate Trace 1.1 proposal is not the scope of this change.

## Implementation

| Responsibility | Result |
| --- | --- |
| Onboarding worker | Editable birth year and actual age, sex tiles, measurement rulers and inline nudges, goal curves, pace and level choices, frequency bars; existing draft validation and unit conversion retained. |
| Training sheets worker | Adaptive manual-set cards with large numerals and existing repeat-set chips; native empty-search state. |
| Meal worker | Bounded editable numerals, 44 pt inputs, and accessible layouts for macros, amount and meal slot; missing nutrition remains unknown. |
| Integration | Compact white recent-workout card on Train; scrollable weight and camera-off states; flexible shared numeric inputs; localized age and plan action; domain-derived weight nudge bounds and safe ruler rendering for invalid pasted numbers. |

All values come from the existing draft or saved records. Decorative entry-screen traces are illustrations;
they do not represent measured workout history. No new dependencies or release actions.
The user authorized committing and pushing this UI delivery on 2026-11-02.

## Validation

- Package tests: 1,185 passed.
- Proxy tests: 146 passed.
- Debug iPhone 17 Pro Max Simulator build and launch: passed.
- UI: 25 distinct cases have passing results across the initial run and scoped retakes; this is not a claim that the full UI suite is green.
- English / Simplified Chinese additional screens, dark first run, largest-text manual entry, and landscape camera-off / weight entry: passed and visually inspected.
- Long invalid pasted weight stays editable without crashing; a valid replacement saves. Nudging 350 kg preserves the domain's accepted range.
- The manual meal's add / edit / delete flow, unknown nutrition and invalid values passed. Focused fields now have one input view each; keyboard-aware test scrolling respects the native floating Done toolbar.
- Native toolbar actions use their system hit padding; custom nudges and camera fallback actions retain the 44 pt checks.

One additional, out-of-scope check failed: `ProfileFlowUITests/testPrivacyScreenStatesWhatLeavesThePhone` could not scroll “Camera video” fully above the bottom bars. Me and Privacy were not changed in this task. This failure remains recorded rather than counted as a pass.

[Machine-readable results and log locations](ui-evidence/other-screens/results.json).

## Screenshots

| Reference screen | Raw Simulator capture |
| --- | --- |
| About you | [Chinese](ui-evidence/other-screens/pte-onboarding-about-light-zh.png) · [dark](ui-evidence/other-screens/pte-onboarding-about-dark-en.png) |
| Your body | [English](ui-evidence/other-screens/pte-onboarding-body-light-en.png) · [dark](ui-evidence/other-screens/pte-onboarding-body-dark-en.png) |
| Your goal | [English](ui-evidence/other-screens/pte-onboarding-goal-light-en.png) · [dark](ui-evidence/other-screens/pte-onboarding-goal-dark-en.png) |
| Train start | [Chinese](ui-evidence/other-screens/pte-other-train-start-zh-portrait.png) |
| Add exercise | [Chinese](ui-evidence/other-screens/pte-other-exercise-picker-zh-portrait.png) · [empty search](ui-evidence/other-screens/pte-other-exercise-search-empty.png) |
| Add set by hand | [Chinese](ui-evidence/other-screens/pte-other-manual-set-zh-portrait.png) · [largest text](ui-evidence/other-screens/pte-other-manual-set-ax5-portrait.png) |
| Log weight | [Chinese](ui-evidence/other-screens/pte-other-weight-zh-portrait.png) · [landscape, largest text](ui-evidence/other-screens/pte-other-weight-ax5-landscape.png) |
| Add meal by hand | [Chinese](ui-evidence/other-screens/pte-other-manual-meal-zh-portrait.png) |
| Camera access off | [landscape, largest text](ui-evidence/other-screens/pte-other-camera-denied-ax5-landscape.png) |

The simulator uses seeded in-memory records, local service stubs and simulated camera permissions.
This work does not establish physical-device camera accuracy or live-service behavior.
