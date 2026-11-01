# Completion work — 2026-11-01

Initial scope: finish the locally executable MVP without Simulator/UI debug. The user subsequently authorized
Cloudflare deployment, secret configuration and UI debugging by a gpt-6.1-terra/high subagent. Keep secrets
outside the app/repository, preserve unrelated edits, and commit/push validated batches. No new app/runtime dependencies.

| Work | Acceptance | Status |
| --- | --- | --- |
| Nutrition quantity and editing | Persist g/ml; retain unknown nutrients; editing/reusing a saved amount rescales correctly; v1 data survives migration | Passed feature, repository and migration tests; Debug app compiled |
| Durable Health outbox | Business data and sync intent commit together; deletes retry while export is off; service tests run on macOS | Passed 128 repository tests, 133 Health tests and portable feature regressions; Debug app compiled |
| Recording and recovery | Mixed cameras cannot masquerade as one camera; interrupted live sets retain counted work; valid captures remain exportable | Passed recorder/reopen/retry tests; stable set and rep IDs; camera preference persists |
| Workout execution | Coach prescriptions retain sets/reps/rest; workout history and exercise progress are accessible | Feature-tested; simulator manual/replay/save and history/filter/charts checked; completed counts exclude empty exercise entries |
| Feature-level regression coverage | Exercise application logic through portable tests and real repositories; do not rely on UI tests for data correctness | 17 portable feature tests including real SQLite saves, reopen, plan application, history and deletion |
| Proxy and configuration | Deployed endpoint; bounded service usage; offline tests and real service checks pass | 146 tests; SQLite durable limits, Worker deploy, Muse/SSE/USDA live checks and seeded Coach UI turn passed; npm audit zero findings |
| Simulator UI | Exercise the functional matrix and inspect rendered layouts; preserve failures and scoped retests | Complete functional run 56/57 before onboarding fix; post-fix affected group 13/13 and ordered reproduction 2/2; screenshots 25/25; combined coverage of 82 distinct cases |
| Delivery | Original app icon, compatible CI/check scripts, safe migrations, reproducible reports and handoff instructions | Full local check passed; GitHub native + proxy jobs passed, including all three builds; eight hardware-only CI skips are explicit |

Required checks: affected package tests, full `swift test`, import-tool tests, proxy tests, Debug/Release builds, and an unsigned device-SDK compile where available. Report the actual proof layer for each result.

Physical signing, installation and launch now passed on the user's iPhone 17 Pro Max (iOS 27.2), including
HealthKit in both the signed entitlements and the provisioning profile. See
[physical-device-acceptance.md](physical-device-acceptance.md) for the saved team configuration and evidence.
External acceptance remains separate: real human pose recordings and Vision latency, actual HealthKit writes,
and full device/accessibility acceptance. Cloudflare deployment and both secrets
are now configured; real Muse non-streaming/SSE, USDA and one simulator live Coach call passed.

Deployment: [cloudflare-deployment.md](cloudflare-deployment.md). UI observations and scoped test evidence:
[ui-debug-report.md](ui-debug-report.md). The public endpoint is configured in both app build configurations.

Detailed Chinese functionality inventory, fixes, evidence and next steps: [completion-report.md](completion-report.md).

Latest deployment configuration: `dea0d6c`; app/package/UI-test fixes: `569bb57`, both pushed to `origin/main`.
UI assertion fixes: `5761da3`; text replacement/predictive-keyboard handling: `23395a2`, also pushed.
Onboarding focus ownership fix: `ae9d29d`, pushed after the ordered reproduction and affected regression
passed. All three app configurations were recompiled locally. Core package and proxy source were unchanged.
[Final Validate run 41347266853](https://github.com/kiraguriz/movement-tracker-plus/actions/runs/41347266853)
at `ae9d29d` succeeded in native and proxy jobs. Its raw native log confirms seven modules, 1,184 declared
tests, eight explicit Vision hardware skips and three successful app builds. UI test results are separate:
[82-case combined coverage](ui-evidence/results.json), including the preserved pre-fix failure and successful scoped retests.

Earlier [Validate run 41342464322](https://github.com/kiraguriz/movement-tracker-plus/actions/runs/41342464322)
at `23395a2` succeeded in native and proxy jobs. Its raw native log confirms the same seven modules,
1,184 declared tests, eight explicit Vision hardware skips and three successful builds.
Local full `tools/check.sh` at `569bb57` passed 1,184 Swift tests without Vision skips, 146 proxy tests, eight
import-tool tests, proxy dry-run and all three app builds. Local checks now use the same `--no-parallel`
test mode as CI after one concurrent Vision initialization failure; the subsequent full run passed.

[Validate run 41338272179](https://github.com/kiraguriz/movement-tracker-plus/actions/runs/41338272179)
at `569bb57` succeeded in both native and proxy jobs. The native job's raw log confirms all seven modules
(1,184 declared tests), eight explicit Vision hardware skips, and all three builds. The local full run
enabled those eight integration cases. At that earlier checkpoint only the two booted simulators were connected
and the project had no selected signing team. The subsequent physical signing/install result above supersedes
that environment snapshot; actual HealthKit writes remain open.

Previous backend baseline: implementation `940e69e`; test capability probe/workflow `65f24d2`. GitHub verification:
[Validate run 41300391099](https://github.com/kiraguriz/movement-tracker-plus/actions/runs/41300391099) — **success**, both jobs completed.
The hosted VM has no body-pose main-stage compute device; eight integration cases use an actual request
probe and skip only that known unavailable-device error. Other probe failures still fail the tests.
Deterministic failure-path tests and all core tests stay enabled. Local hardware runs all cases.

Previous baseline evidence: local `tools/check.sh` passed 1,181 Swift tests (no Vision skips), 146 proxy tests, eight
import-tool tests, proxy dry-run and Debug/Release Simulator SDK plus unsigned Release iPhone SDK builds.
The cloud run reported the same seven test modules, eight explicit hardware skips, and successful builds.

Post-hackathon features in `rebuild-brief.md` §12 remain outside the MVP: Watch, cloud sync, learned pose recognition, 3D/SAM replay and App Attest. Reassess only if needed to make the requested MVP work.
