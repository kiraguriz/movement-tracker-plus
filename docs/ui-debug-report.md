# Simulator UI verification — 2026-11-01

- Final product fix: `ae9d29d`, iPhone 18 Pro, iOS 27.0, in-memory data. The complete functional run at `23395a2` was **56 passed, 1 failed** (`ProfileFlowUITests.testChangingUnitsConvertsTheBodyValues`), `/tmp/mt-functional-final.log`. After the fix, the same landscape-then-unit-change pair passed **2/2** and the affected onboarding/profile regression passed **13/13**. The complete 57-case run was not repeated after this scoped fix.
- Screenshot suite: **25/25 passed** on iPhone 18 Pro Max, iOS 27.0: 19 light, large-text and landscape cases (`/tmp/mt-screens-light.log`), 6 dark cases (`/tmp/mt-screens-dark.log`). Representative screenshots were visually inspected; they use synthetic data and local stubs.
- No physical-device camera, HealthKit authorization, real-motion accuracy, real meal-photo quality, real-device layout, or full VoiceOver audit was verified here.

## Initial baseline and follow-up

The initial Pro suite ran 82 tests: 49 passed, 8 failed, and 25 screenshot tests skipped because their output directories were unset (`/tmp/mt-full-ui.log`). The screenshot tests were subsequently executed as above.

| Baseline failure | Evidence and follow-up |
| --- | --- |
| Largest-text meal editor: protein row missing | Form creates the row lazily; scrolling to it allowed the ≥44 pt check to pass on both Pro and Pro Max. |
| Stub meal photo: expected 427 kcal, got 337 | The photo estimates juice in grams and the stub result is per mL. Without density, nutrition remains unknown; corrected the test to check 200 g, unknown kcal and 337 known kcal. Retested on both simulators. |
| Health denied alert missing | The same Health stub case passed twice on Pro and once on Pro Max; baseline failure was not reproduced. No real HealthKit permission claim. |
| Profile weight save did not close | Synthetic `81` had become `8180` because the helper deleted at the wrong cursor position; the invalid value disabled Save. Select-and-replace plus value/Save assertions passed on Pro. |
| Three meal protein input tests could not focus | Failure screenshot showed the keyboard prediction bar covered the field despite XCTest's reported keyboard frame. The helper now scrolls from visible form content with a margin above that frame. All three targeted cases passed on Pro. |
| Unit conversion onboarding did not return to Body | After returning from Body, the keyboard remained visible over Continue (`hittable=false`); a form drag did not dismiss it in the reproduced flow. Onboarding now owns the fields’ SwiftUI focus and clears it when the navigation path changes. The same landscape-then-unit-change sequence passed after this app fix (`/tmp/mt-rotation-parent.log`); the Profile group, Chinese and largest-text onboarding, and Health profile-weight regression passed 13/13 (`/tmp/mt-onboarding-regression.log`). |

Targeted logs: `/tmp/mt-affected-pro.log`, `/tmp/mt-focused-ui-2.log`, `/tmp/mt-input-fixed.log`, `/tmp/mt-rotation-parent.log`, `/tmp/mt-onboarding-regression.log`. [Machine-readable results](ui-evidence/results.json) preserve the failed runs and confirm that the unaffected passing cases plus post-fix reruns cover all **82 distinct cases** in the discovery matrix. This is combined coverage, not a claim that the original complete run passed in one invocation.

## Live service and runtime evidence

- With synthetic sample data and AI opt-in, the deployed endpoint answered one Coach question about squat form and displayed a `1 session` tool chip. The answer correctly stated that the seeded manually logged sets had no motion-tracked scores.
- With no stub, a synthetic squat replay produced on-device 10 reps, 1 partial and score 90. Live Muse returned rep-specific set review and session debrief, including 24.4% velocity loss. [Set review screenshot](ui-evidence/live-set-review.jpg).
- The debug-generated sample meal illustration was sent to the deployed service. Muse identified egg and toast and warned the picture was stylized; a USDA fried-egg match appeared. After confirmation Eat showed 98 + 78 = 176 kcal. [Photo review screenshot](ui-evidence/live-meal-photo.jpg).
- An empty Bench Press plus one performed Squat set produced `1 exercise, 1 set, 10 reps`; completed history showed one exercise and its detail showed the logged set. Empty entries remain stored for draft editing. Focused package tests passed: WorkoutRepository 22/22 and DebriefService 6/6.
- Today in landscape initially places lower content behind the bottom accessory. Dragging from the visible workout card exposes all workout metrics and the weight chart, and the History button opens. Evidence: [scrolled landscape screenshot](ui-evidence/today-landscape-scrolled.png), `/tmp/mt-landscape-bottom-3.log`.

## Subsequent physical-device fixes

These checks are separate from the Simulator matrix above. On iPhone 17 Pro Max, iOS 27.2:

- Expired rest originally left an empty List cell. The TimelineView now wraps the List so the expiry
  condition removes the entire row. The installed fix passed both an expired relaunch and live countdown
  through zero; both saved sets remained present.
- The first manual-workout Summary truncated its duration as `18m 3...`. Increasing its StatTileGrid minimum
  from 100 to 140 points gave the tiles more width; the installed update displayed `23m 53s` completely.
  The observed phone still used three columns. Other locales, very long durations and accessibility sizes
  are not proved by this one screenshot.
- Each change compiled in Debug Simulator, signed physical Debug and Release Simulator configurations.
  `WorkoutExecutionTests` passed 5/5. No package or proxy behavior changed.

The user paused human camera counting. Manual draft/completed recovery, real Health nutrition results,
test-data cleanup and the acceptance-fixture transfer caveat are documented in
[physical-device-acceptance.md](physical-device-acceptance.md). No private phone screenshots or raw poses
were added to repository evidence.
