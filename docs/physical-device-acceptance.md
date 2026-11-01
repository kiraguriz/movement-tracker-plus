# Physical device acceptance — 2026-11-01

This report separates signed installation from camera counting and HealthKit runtime acceptance.
Simulator, generated poses and Health stubs are not physical-device evidence.

## Confirmed

- The user's iPhone 17 Pro Max, iOS 27.2, was connected and paired, with Developer Mode enabled.
- The app target now saves `DEVELOPMENT_TEAM = WL6JGN2HMU` in Debug and Release. Xcode selected
  **Haitian Zhu (Personal Team)**, with automatic signing enabled.
- A Debug build targeting this physical device succeeded. A second build using the saved project configuration,
  without a command-line team override, also succeeded.
- `codesign --verify --deep --strict` passed. Both the signed entitlements and embedded provisioning profile
  include `com.apple.developer.healthkit = true`; the profile includes the connected physical device.
- The current development profile expires **2026-11-08 21:44:52 UTC**. This is a development installation,
  with renewal needed after that date; it is not an App Store or TestFlight release.
- `devicectl device install app` installed `io.github.kiraguriz.MovementTracker` successfully.
- The user trusted their own Apple Development identity and unlocked the device. A subsequent launch succeeded;
  Device Hub's physical-device screenshot showed the app's Train screen.
- The signing/configuration commit `cb00e1e` was pushed to `origin/main`.
  [GitHub Validate 41354912120](https://github.com/kiraguriz/movement-tracker-plus/actions/runs/41354912120)
  completed successfully. CI does not replace the physical-device runtime checks below.

Local build and install logs are under `/tmp/mt-physical-*`, `/tmp/mt-signing-device-build.log` and
`/tmp/mt-device-install.*`. Device identifiers, provisioning profiles and account credentials are not copied
into this report.

## Runtime setup

The current Debug launch uses:

```text
-MTInMemoryDatabase -MTSeed profile -MTStartTab train -MTDebugHUD -MTRecordPoses -MTNoCoach
```

There is no pose replay or Health stub argument. The seeded app database is temporary; this run cannot prove
SQLite recovery across process termination. Coach is disabled so the user's camera session is not sent to Muse.
Pose captures contain skeleton coordinates rather than video and remain local pending the user's explicit
approval of any external sharing.

[Apple documents direct physical-device interaction in Device Hub](https://developer.apple.com/documentation/xcode/device-hub).
Initial automation clicks did not navigate the app; a subsequent `devicectl` lock-state check confirmed
`passcodeRequired: true`. Input verification resumed after the user unlocked the device. This is not
evidence that Device Hub lacks physical-device control, nor an observed app defect.

After unlocking, Device Hub still failed to deliver input. Its host log identified a separate environment
failure: `CoreDeviceError 15004` from the HID remote call, caused by `XPCError 1001` (invalidated connection).
Stopping/restarting screen sharing alone did not clear the cached service. Quitting Device Hub while keeping
simulators running, relaunching it and choosing View Screen created a new Universal HID service connection.
The log then listed connected touchscreen/button descriptors; remote navigation and adding Bodyweight Squat
were observed. The user also confirmed that a Mac mouse click could enter the workout flow. Remote screen
updates lag the input, so subsequent actions must wait for the visible result rather than repeat the click.

Apple's [interaction guide](https://developer.apple.com/documentation/xcode/interacting-with-your-app-in-device-hub)
also documents a camera/microphone conflict during physical-device interaction. Camera acceptance must account
for that restriction: stop the Device Hub interaction before judging real sensor capture. A camera failure while
screen sharing is active cannot establish that the app's normal camera path fails.

## Awaiting runtime evidence

- Camera permission, live preview, skeleton alignment and framing gate.
- Independently counted reps, partials and an idle clip, with separate front/back recordings.
- Actual Vision p50/p95, frame rate, dropped frames, Center Stage and stabilization readings.
- Additional HealthKit coverage: workout/estimated energy, body mass, partial or revoked permission and
  process-termination recovery. The nutrition save/edit/deduplication/delete pass below succeeded.
- The full real-data target in brief §6.8 (10 squat sets, 10 push-up sets, two people, two rooms) remains open.

The test steps and thresholds are in [device-checklist.md](device-checklist.md).

## Health test authorization

The user explicitly authorized a disposable test meal named `MT Health Acceptance`: 100 g, 200 kcal,
10 g protein, 20 g carbohydrate and 8 g fat; edit it to 50 g and clean up the test record afterward.
Only the four nutrition write permissions are needed for this pass. Existing health history and body-mass
data are outside this test. The user completed the system permission step; the app's Apple Health switch was
then visibly on. The exact test meal was entered and saved through Device Hub, and the Eat screen showed
the expected 100 g / 200 kcal / 10 g / 20 g / 8 g values. Health's own samples, editing/deduplication and cleanup
remain separate checks; the app row alone does not prove an OS write.

Health > profile > Apps > Movement Tracker+ > Data from Movement Tracker+ listed exactly the four nutrition
types. Dietary Energy's source-filtered All Recorded Data screen showed one 200 kcal entry on Nov 1 at
4:23 PM, confirming an actual OS write. No body-mass or workout category appeared in this source's data list.
The energy sample's Details screen confirmed the source name, sync version `1` and a meal-specific sync
identifier. Editing only the amount to 50 g automatically changed the app form to 100 kcal / 5 g protein /
10 g carbohydrate / 4 g fat; after saving, the Eat screen showed those exact values and one meal row.
After returning to the source-filtered Health list, it contained one 100 kcal entry, not the original 200 kcal
plus a new entry. Opening that entry showed sync version `2`, the same meal sync identifier and original
sample time, with a new Date Added timestamp. The open Details view had cached the old object until navigation
back to the list, so the fresh list and reopened details are the edit/deduplication evidence.

The four source-filtered All Recorded Data lists were checked individually after the edit:

| Type | Value | Number of records |
| --- | --- | --- |
| Dietary Energy | 100 kcal | 1 |
| Protein | 5 g | 1 |
| Carbohydrates | 10 g | 1 |
| Total Fat | 4 g | 1 |

These are synthetic acceptance values, not the user's diet. The test meal was then deleted through the app's
own confirmation flow. Eat returned to No meals with zero totals. Each of the four source-filtered Health
lists was opened again and showed **No Data**, verifying that all four test samples were removed. The source
overview still listed the historical nutrient categories; that list alone is not evidence of residual samples.

**Nutrition result: passed** — real system authorization, actual writes, proportional editing, one sample per
type after editing, stable sync identifier/version advancement, and app-driven removal. No Health stub or
replay was used, and no personal Health history or body-mass values are retained in repository evidence.
The app database was in memory, so this pass does not validate process-termination recovery.

Device Hub's clipboard paste produced stale content in an unsaved field. It was cleared and never saved;
the verified test name and numbers were then entered with individual hardware-key events. Verify the final
form before Save rather than treating a paste command as proof of input.
