# Completion work — 2026-11-01

Scope: finish the locally executable MVP work identified in the repository review. Do not boot simulators or run UI debugging. Keep secrets outside the app and repository. Reuse the current checkout, preserve unrelated edits, and commit/push validated batches. No new app/runtime dependencies.

| Work | Acceptance | Status |
| --- | --- | --- |
| Nutrition quantity and editing | Persist g/ml; retain unknown nutrients; editing/reusing a saved amount rescales correctly; v1 data survives migration | Passed feature, repository and migration tests; Debug app compiled |
| Durable Health outbox | Business data and sync intent commit together; deletes retry while export is off; service tests run on macOS | Passed 127 repository tests, 133 Health tests, 10 feature tests; Debug app compiled |
| Recording and recovery | Mixed cameras cannot masquerade as one camera; interrupted live sets retain counted work; valid captures remain exportable | Passed recorder/reopen/retry tests; stable set and rep IDs; camera preference persists |
| Workout execution | Coach prescriptions retain sets/reps/rest; workout history and exercise progress are accessible | Implemented and feature-tested; Debug app compiled; no UI runtime claim |
| Feature-level regression coverage | Exercise application logic through portable tests and real repositories; do not rely on UI tests for data correctness | 17 portable feature tests including real SQLite saves, reopen, plan application, history and deletion |
| Proxy and configuration | Prepare a real endpoint configuration path; bounded service usage; offline tests and dry-run build pass | 146 tests; SQLite durable limits, local Worker burst test, dry-run bundle, TypeScript check, npm audit zero findings |
| Delivery | Original app icon, compatible CI/check scripts, safe migrations, reproducible reports and handoff instructions | Pending |

Required checks: affected package tests, full `swift test`, import-tool tests, proxy tests, Debug/Release builds, and an unsigned device-SDK compile where available. Report the actual proof layer for each result.

External acceptance remains separate: real human pose recordings and Vision latency, actual HealthKit authorization/writes, signing on the user's team, Cloudflare login/provisioning/deploy, Meta/USDA secrets and live contract checks, and later UI/device acceptance. Do not mark these passed without evidence.

Post-hackathon features in `rebuild-brief.md` §12 remain outside the MVP: Watch, cloud sync, learned pose recognition, 3D/SAM replay and App Attest. Reassess only if needed to make the requested MVP work.
