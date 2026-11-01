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
- HealthKit system authorization and actual write/edit/deduplication/delete evidence. The entitlement alone
  does not prove these behaviors.
- The full real-data target in brief §6.8 (10 squat sets, 10 push-up sets, two people, two rooms) remains open.

The test steps and thresholds are in [device-checklist.md](device-checklist.md).

## Health test authorization

The user explicitly authorized a disposable test meal named `MT Health Acceptance`: 100 g, 200 kcal,
10 g protein, 20 g carbohydrate and 8 g fat; edit it to 50 g and clean up the test record afterward.
Only the four nutrition write permissions are needed for this pass. Existing health history and body-mass
data are outside this test. At this checkpoint the Apple Health switch is still off, the system authorization
step awaits user completion, and no test samples have been written. Permission, write, edit/deduplication and
cleanup must each be verified separately before this test can be marked passed.
