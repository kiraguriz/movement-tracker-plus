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

## Trace redesign — 2026-11-01 working tree

Implemented from the user's `Movement Tracker+ Redesign.html`, statically extracted as 17 design
screens/size variants. The reference's example values and generated motion curves were not copied as
application data. Shared Trace colors, native compressed numerals, expanded metric labels, rep shapes,
glass actions and three icon appearances now cover Today, Train, Live Set, Review, Summary, Eat,
Meal Photo, Coach, Me, the onboarding plan and Workout History.

Implementation ownership was split by shared shell/Today, Train/history, live/review/summary,
Eat/photo, Coach/Me/plan, and independent validation. Acceptance requires existing save/edit/delete,
consent and checkpoint flows to remain usable, individual nutrition values to remain accessible,
English/Chinese support, and layouts that adapt to short and wide windows.

- Live curves use timestamped MotionCore output. Rep markers match the actual rep interval and bottom
  timestamp, including when setup or rejected attempts precede a counted rep. The buffer retains at most
  3,600 samples in memory; saved history shows persisted rep metrics without inventing a saved waveform
  or issuing a new Muse request.
- Today cards navigate to Eat/history. History filtering uses the selected exercise's actual sets;
  unavailable/truncated older set snapshots show an unknown value. Closing a live set accurately says
  Close, and keeps its already-saved checkpoint.
- Nutrient unknowns and partial totals retain `–` and `≥`; VoiceOver reads quantities, units and set
  numbers. Onboarding has four-step progress. Navigation uses the native automatic tab/rail presentation;
  Today selects columns from its available width, and nutrition targets keep their full value.

Validation: `tools/check.sh` passed (1,185 Swift package tests, 8 Python tests, 146 proxy tests,
proxy dry-run bundle, Debug/Release simulator builds, Release device SDK build, diff check).
Log: `/tmp/mt-redesign-gate.log`. These device SDK builds are unsigned compile evidence.
The final three app builds passed after all layout and contrast corrections:
`/tmp/mt-trace-layout-gate.log`. Earlier affected-build logs remain available for the trace-selection
and Coach contrast changes.

UI coverage is **59 distinct functional/accessibility cases plus 2 screenshot cases**, all with passing
results after scoped retests. This is combined coverage, not a single clean full-suite invocation:

| Run | Result | Evidence |
| --- | --- | --- |
| Tabs, Chinese, landscape, touch sizes, largest text | 8/8 passed | Xcode MCP `test_sim_2026-11-02T00-28-14-240Z` |
| Train, Coach and Today card navigation | 25 passed, 2 failed | Xcode MCP `test_sim_2026-11-02T00-33-39-339Z` |
| Health, meals and profile | 22 passed, 2 failed | `/tmp/mt-redesign-ui-max.log` |
| Isolated photo diagnosis | 1/1 passed | `/tmp/mt-trace-photo-diagnostic.log` |
| Final affected flows, landscape and train screenshots | 8 passed, 1 failed | `/tmp/mt-trace-final-focused.log` |
| Final largest-text onboarding | 1/1 passed | `/tmp/mt-trace-ax-final.log` |
| Coach button contrast | 1/1 passed | `/tmp/mt-trace-contrast-final.log` |
| Final width-aware landscape | 1/1 passed | `/tmp/mt-trace-layout-fixed.log` |
| Final width/localization/accessibility | 3/3 passed | `/tmp/mt-trace-layout-regression.log` |

All failures were resolved and their original attempts remain in the
[machine-readable results](ui-evidence/trace/results.json):

- Photo editing: the test's rapid triple-tap hit the Log meal button as the keyboard moved it upward.
  The failure recording/hierarchy showed Eat with the unedited 120 g / 50 g items already saved. The
  helper now waits for the focused field to settle above the keyboard and raised action, keeping exact
  value and saved-total assertions. The final photo flow passed with the permanent helper.
- Close confirmation: the system exposes the same native button as nested accessibility nodes. The
  test now selects the first matching node and verifies the three-rep checkpoint remains saved.
- Coach consent cancellation: the old fixed outside-tap landed inside the newly positioned popover.
  Dismissal now uses the actual dialog bounds; cancel/off, confirm/on and turn-off assertions passed.
- Weight units: the check now reads the numeric accessibility value, which includes pounds, while
  its label identifies Weight. The conversion and privacy navigation passed.
- Largest-text onboarding: the original scroll gesture started inside the floating Continue action.
  It now starts in the form's visible area above that action; the complete flow passed on Pro Max.
- A landscape probe exposed a TabBar-only test assumption; the helper now also recognizes native
  sidebar cells. Visual inspection then caught a truncated calorie target in the narrow content area.
  The final UI preserves automatic native tab/rail navigation, uses available width for Today columns,
  and keeps the target text at its full width. Final Today/Eat landscape screenshots show `/ 2,317`
  without ellipsis. The extra probe and its retest are also preserved in the results ledger.
- Coach primary actions now use the native button foreground instead of inheriting the chat's ink
  foreground. The final screenshot confirms white text on the blue action and its meal flow passed.

Xcode stalled while finalizing the nine-case focused batch after all test bodies had logged their
results. That postprocessing process was stopped; its complete text log and direct screenshot outputs
are retained. The later isolated result bundles finalized normally.

Representative raw, unedited screenshots were inspected: [Today](ui-evidence/trace/today-en.png),
[Chinese Today](ui-evidence/trace/today-zh.png), [dark Today](ui-evidence/trace/today-dark.png),
[Eat](ui-evidence/trace/eat-en.png), [Me](ui-evidence/trace/me-en.png),
[Coach](ui-evidence/trace/coach.png), [meal photo](ui-evidence/trace/meal-photo.png),
[wide Today](ui-evidence/trace/today-landscape.png), [live portrait](ui-evidence/trace/live-portrait.png),
[live landscape](ui-evidence/trace/live-landscape.png), [Review](ui-evidence/trace/review.png) and
[Summary](ui-evidence/trace/summary.png). The live and review views show measured replay traces;
the selected review rep is centered in the chip strip. Lower scroll content may initially sit behind
the native glass bars and remains scrollable.

Runtime data is synthetic, the Coach/USDA/Health services are local stubs, and motion is fixture replay.
This redesign does not establish new physical-device motion accuracy, real-photo inference quality,
live-service availability or iPhone Duo hardware acceptance.
