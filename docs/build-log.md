# Build log

What was built when, generated from `git log main` by `tools/build-log.sh`. Times are author times in Chicago time (CST/CDT); merge commits are left out.

Source: `main` at `ae9d29d`, 40 commits, 2026-10-29 to 2026-11-01.

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
