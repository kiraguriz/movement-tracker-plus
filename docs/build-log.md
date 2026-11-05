# Build log

What was built when, generated from `git log main` by `tools/build-log.sh`. Times are author times in Chicago time (CST/CDT); merge commits are left out.

Source: `main` at `aaf44ee`, 99 commits, 2026-10-29 to 2026-11-03.

## 2026-10-29 (Thu)

- 16:10 CDT `eb24806` Start native iOS rewrite: package skeleton, pose frame contract, plan docs
- 21:03 CDT `87f1518` Add Cloudflare Worker proxy for Muse and USDA
- 21:22 CDT `4e5e6c0` Add Domain model, goal planner and GRDB persistence
- 21:48 CDT `e106f3a` Add Xcode project and SwiftUI app shell
- 21:56 CDT `d278540` Add MotionCore rep counting and form engine
- 22:18 CDT `c3b8358` Fix rep tempo measurement and count brisk reps
- 22:53 CDT `339d9c7` Add CoachKit Muse client
- 23:06 CDT `7dec015` Add PoseCapture Vision pipeline and motion-eval

## 2026-10-30 (Fri)

- 00:03 CDT `1bbecd3` Add HealthBridge for Apple Health export and reads
- 00:07 CDT `e8183dd` Add onboarding, Today, Eat and Me screens
- 00:09 CDT `3b19b82` Wire the Muse coach into the app environment
- 00:14 CDT `10da208` Make velocity loss robust to per-rep noise
- 01:57 CDT `573b675` Stop counting noise-carried partials as reps
- 03:50 CDT `50fa6c7` Add the Train flow: live set, set review and session summary
- 04:39 CDT `aa78552` Match offline cue sentences to the push-up spec
- 04:45 CDT `a5506c8` Add coach chat, food search and meal photo
- 05:11 CDT `7806a73` Harden onboarding, Today, Eat and Me
- 06:55 CDT `65353a8` Add the README, accuracy report, device checklist and build log
- 10:59 CDT `42cd84c` Harden Train drafts, profile saves, health exports and timing tests
- 11:18 CDT `a3d7783` Send workouts, meals and weight to Apple Health
- 11:32 CDT `ecdabc4` Describe the Apple Health switch in the README and device checklist

## 2026-11-01 (Sun)

- 02:35 CST `1635d0e` Preserve pose recordings and validate evaluation imports
- 02:43 CST `93d979e` Honor partial Health access and keep incomplete exports queued
- 02:44 CST `e986ab8` Refresh accuracy provenance and build history
- 03:54 CST `2482144` Preserve food quantity units and test the portable meal editor
- 04:11 CST `3aa42d3` Commit Health export intents with business writes and recover them after interruptions
- 04:23 CST `164db88` Recover counted sets and retain workout prescriptions, history and progress
- 04:24 CST `4b1a0d2` Enforce durable proxy budgets and add reproducible delivery checks
- 04:27 CST `4df9c0c` Handle global proxy limits without retrying exhausted daily budgets
- 04:29 CST `3979068` Document verified functionality, delivery evidence and remaining device acceptance
- 04:49 CST `e580503` Bound native CI test execution after hosted Vision concurrency stalled
- 04:58 CST `940e69e` Reject unmeasured evaluation clips and declare Vision hardware integration requirements
- 05:00 CST `fcb102f` Quote the CI hardware diagnostic as a YAML block
- 05:06 CST `65f24d2` Probe actual Vision body-pose availability instead of assuming Metal support
- 05:16 CST `5c36ef6` Record completed local and cloud delivery validation
- 12:33 CST `dea0d6c` Connect the app to the deployed Cloudflare proxy and verify live APIs
- 12:45 CST `569bb57` Count performed exercises consistently and isolate UI tests from live services
- 12:58 CST `5761da3` Align UI assertions with lazy forms and mass-safe photo nutrition
- 13:34 CST `23395a2` Replace UI field text reliably and avoid the predictive keyboard bar
- 14:31 CST `ae9d29d` Clear onboarding field focus when navigating between steps
- 14:40 CST `608a1e9` Record live deployment, simulator coverage, and device acceptance boundaries
- 16:00 CST `cb00e1e` Configure physical-device signing and record install acceptance
- 16:11 CST `6c01dca` Document Device Hub recovery and physical acceptance boundaries
- 16:36 CST `6057636` Record physical HealthKit nutrition acceptance and verified cleanup
- 16:44 CST `d10843d` Correct camera preparation HUD source and record live capture baseline
- 16:47 CST `61f9d10` Record stable real front-camera delivery and remaining human acceptance gate
- 17:33 CST `0d7e006` Verify physical workout recovery and fix rest and summary layout
- 19:27 CST `b3f4402` Implement Trace redesign across the native iOS app
- 23:16 CST `fef5942` Align native UI with redesign reference

## 2026-11-02 (Mon)

- 10:19 CST `5c21cf4` Complete Trace screens, sheets, and workout states

## 2026-11-03 (Tue)

- 00:21 CST `a7e38ac` Refine adaptive Duo layouts and dashboard design
- 01:20 CST `636e9ec` Add shared routes, spec lookup and coach features for parallel work
- 01:26 CST `e184028` Add device-side guard for Muse calorie plans
- 01:28 CST `f912ffb` Add liftFirst spec field so lift-first movements label eccentric and concentric correctly
- 01:29 CST `84ead79` Add readiness engine and Today advisor to Domain
- 01:30 CST `940c862` Add Today plan service and by-id workout plan start
- 01:32 CST `cfe3dc0` Add teach session, joint trimming and replay verification for taught exercises
- 01:33 CST `c2b0866` Notify when a rest ends while the app is in the background
- 01:33 CST `381083e` Add weekly goal row with streak weeks to Today
- 01:33 CST `e566300` Add taught exercise ids, names, spec candidates and saving
- 01:34 CST `2b7104f` Add the Muse goal plan request, prompt and deadline to CoachKit
- 01:36 CST `17daae5` Give the teach session a framing state and explicit takes
- 01:45 CST `445e353` Add Today plan card with one-tap start and readiness
- 01:45 CST `237a19f` Add separate HealthKit reader for sleep, HRV and resting heart rate
- 01:47 CST `1cb7ff2` Resolve stored specs of taught exercises in the spec catalog
- 01:47 CST `96e6e72` Add the teach flow to the exercise picker
- 01:53 CST `15828bf` Add front-view jumping jack as a built-in camera exercise, hidden from the picker until released
- 01:54 CST `a0ed963` Update Health read usage description
- 01:54 CST `051c942` Add Muse daily tip for Today in CoachKit
- 02:03 CST `6ca48b9` Speak cues with the best installed voice for the language
- 02:03 CST `925ca91` Add jumping jack to the synthetic accuracy rows and the recording checklist
- 02:04 CST `e46d6ab` Keep edge-touching joints out of taught specs and blame hidden joints for short counts
- 02:08 CST `736ec30` Cover the Muse step and plan states in the onboarding UI tests
- 02:08 CST `94e2ab9` Ask about Muse first in onboarding and let Muse make the calorie plan
- 02:10 CST `b866aaa` Add a Live Activity for the workout in progress
- 02:14 CST `15c73a2` Add App Shortcuts to start a set and log weight
- 02:19 CST `29d2d8d` Fix teach step labels and add teach UI tests and a recording regression test
- 02:22 CST `926605d` Dismiss the keyboard between the height and weight fields in the onboarding UI tests
- 02:24 CST `54cbcfa` [slice B] Add taught form checks: menu, calibration and replay gate
- 02:28 CST `1f78a94` Show Muse daily tip on Today with a recovery sharing switch
- 02:33 CST `6987b67` [slice B] Add the spec_author client to CoachKit
- 02:36 CST `f50ff77` Record the Muse step results in the onboarding design QA
- 02:50 CST `d236740` Keep the elapsed time on one line and test the Lock Screen and notification flows
- 02:50 CST `e69817d` Fix the crash when a notification tap opens the app
- 02:54 CST `ea9b127` Clear rest alerts on skip and describe the Health data read
- 02:58 CST `1938a25` [slice B] Do not report a rounded threshold as eased
- 03:05 CST `e803309` [slice B] Let Muse propose form checks for a taught exercise
- 03:06 CST `682ba4a` Keep the goal plan stub out of Release builds
- 11:44 CST `c7229a8` Scroll the rulers and unit picker into view on a short landscape window
- 11:44 CST `b85c1e1` Close the set sheet's keyboard with its Done before the reference capture
- 11:44 CST `dc158af` Close the keyboard before scrolling the form to a field it covers
- 11:44 CST `a9034ae` Reveal controls on landscape Today, which has no navigation bar
- 11:44 CST `4fc7391` Measure clearance during setup from the step's action instead of a share of the window
- 11:44 CST `c332984` Scroll Train to the last exercise before checking that a chat plan landed
- 11:44 CST `b36d804` Keep the meal field being typed in clear of the keyboard in a stacked sheet
- 11:44 CST `0a34fe3` Let the meal editor's keyboard Done close the name field
- 11:44 CST `b2a9315` Add a keyboard Done to the manual set sheet and center the card being typed in above it
- 11:44 CST `9b98b5a` Let a tap anywhere on Today's workout card open the history
- 22:45 CST `125fad2` Connect Apple Health once during setup and polish the Muse onboarding
