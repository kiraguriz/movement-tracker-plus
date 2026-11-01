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

The camera and nutrition passes used this temporary Debug launch:

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

The subsequent manual-workout recovery pass uses:

```text
-MTPersistentTestDatabase -MTSeed profile -MTStartTab train -MTNoCoach
```

This Debug-only mode uses `Library/Application Support/MovementTracker/Acceptance/movement-tracker.sqlite`,
separate from the normal database. It seeds only while no profile exists and preserves subsequent edits across
process termination. In-memory mode wins if both database flags are supplied. The ordinary database did not
exist before this pass and was not created by it. Health export stays off and no Health stub or pose replay is used.

## Remaining runtime evidence

- Fully framed skeleton alignment and framing gate. Camera permission and live preview were observed below.
- Independently counted reps, partials and an idle clip, with separate front/back recordings.
- Framed-human and rear-camera Vision p50/p95, frame rate and dropped frames. Initial front-camera readings are below.
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

## Camera runtime — initial front-camera observation

After the Health cleanup, the app's Apple Health export switch was turned off for the temporary seeded
profile. The real camera permission sheet appeared, Device Hub screen sharing was stopped, and the user
allowed camera access. A `devicectl device capture screenshot` then captured the live camera/HUD without
reopening continuous screen sharing. Camera images remain in a private temporary directory outside git.

Initial snapshot (Nov 1, about 4:43 PM CST):

| Reading | Observed |
| --- | --- |
| Source | Front Camera, mirrored; live preview visible; recording indicator on |
| Delivery | 30.0 fps, target 30 |
| Vision | p50 14.5 ms, p95 15.8 ms, max 18.3 ms |
| Frames / failures | 2,953 processed, 0 Vision failures |
| Drops | 18 cumulative; a later snapshot is needed to assess whether this grows |
| Format | 1280×720 binned |
| Cropping features | Center Stage off, stabilization off |
| Rotation / pressure | Capture 0°, preview 0°, overlay 0 quarter turns; nominal pressure |
| Person / reps | 0% / 0, with Step into view shown; no fully framed subject yet |

This confirms actual camera capture, an initial latency reading and the no-person gate. It does not yet
establish framed-human latency, skeleton alignment, stillness stability, rep accuracy or back-camera acceptance.

A second single-shot capture at about 4:46 PM CST showed 8,757 processed frames, 30.0 fps, p50 15.0 ms,
p95 16.1 ms, 0 failures and the same 18 cumulative drops. Across the additional 5,804 frames the drop count
did not increase; the pressure remained nominal and both cropping features stayed off. The view still had
no framed subject, Step into view and zero reps. This is continued no-person operation, not a human idle or
accuracy fixture.

A later single-shot snapshot at about 4:54 PM CST detected an upper-body skeleton but still requested the
whole body: 0 reps, 30 fps, Vision p50 20.3 ms / p95 23.6 ms / max 25.0 ms, 23,302 processed frames,
109 cumulative drops, 0 failures and nominal pressure. Center Stage and stabilization remained off.
These values must not be replaced by the faster no-person snapshots when judging human performance.

The user then paused the human framing/counting test. The live set was ended without logging an empty set.
Its local front-camera recording contains 29,882 valid JSON frames and an empty tag list, without ground-truth
counts. The completed JSONL and its Documents/PoseCaptures export copy were retrieved through `devicectl`;
their byte sizes match. Files.app visibility has not been checked. The raw file remains private outside git
and was not imported as verified accuracy evidence. Human count/idle and rear-camera acceptance remain paused.

The permission-sheet screenshot also exposed a Debug HUD label bug: before camera statistics existed, it
said `replay` regardless of the selected source. `LiveDebugHUD` now selects `camera` or `replay` from
`model.source`; the normal camera statistics branch is unchanged. Debug Simulator compilation and a signed
physical-device build passed. The update was subsequently installed with the isolated acceptance database
and rest-row fix after the camera session ended.

## Manual workout recovery

The isolated durable database was seeded with one profile, goal and synthetic weight. A manually entered
10-rep / 20 kg set was saved, then the app process was terminated with SIGKILL. A stopped-process copy of
the SQLite directory (including WAL/SHM) contained one draft session, one exercise and exactly one manual
set with those values, no rep rows and no Health export intents. Relaunch restored the same set. Profile,
goal and weight counts remained one each, rather than duplicating the seed.

This pass exposed an empty List row after the rest timer expired. Moving the TimelineView around the List
lets expiry remove the entire row. Debug Simulator, signed physical Debug and Release Simulator builds passed;
the installed fix removed the expired row on the physical phone while preserving the saved set.

A second manually entered set, 8 reps / 25 kg, was saved. The phone showed both sets and 1:27 remaining rest.
After another SIGKILL and relaunch, both sets were present and rest showed 1:15, continuing from its original
deadline instead of resetting to 1:30. This proves actual process-termination recovery of the draft and timer;
it does not prove recovery of a Health export or an interrupted camera set.

With the app left open, the rest row disappeared automatically at expiry, without leaving the original blank
card. Finish showed 2 sets and 18 reps, with the original two loads. Save returned Train to its idle state.
A third SIGKILL, stopped-process SQLite copy and relaunch confirmed one completed session with an end time,
exactly two manual sets, 18 total reps and 400 kg total volume. Profile, goal and synthetic weight counts were
still one each; Health export intents remained zero. The relaunched history showed one exercise, 2 sets,
18 reps and 400 kg; its detail view showed 10 reps / 20 kg and 8 reps / 25 kg.

The first summary also exposed truncation of its duration tile (`18m 3...`). The summary grid minimum width
was increased from 100 to 140 points. Debug Simulator, signed physical Debug and Release Simulator compilation
passed. For the installed layout check, the earlier isolated one-set draft snapshot was restored; the new
Summary displayed `23m 53s` completely. This layout-only fixture restore is
separate from the preceding two-set persistence proof. The phone still showed three columns with the wider
cards, so this result does not claim that the device switched to two columns or that every locale/duration fits.

Deleting the original synthetic workout through history removed its record and both trend charts. A
stopped-process SQLite copy confirmed zero sessions, exercise entries, sets, reps and Health export rows.
After the layout check, that clean acceptance snapshot was restored and read back from the phone: the same
zero counts, with only the one seeded profile, goal and synthetic weight retained in the isolated database.
No normal app SQLite database existed before or after this pass.

After the layout-fixture transfers, a final inventory found the phone's earlier pose archive and Documents
export directories missing. The transfer/reinstall sequence does not establish which operation removed them.
Both copies were restored from the private recording retrieved before the database tests; each was then read
back from the phone and compared byte-for-byte with the 2,652,857-byte backup (29,882 valid frames). They match.
Do not use `devicectl copy to --remove-existing-content` during future acceptance-fixture restores without a
complete disposable-container backup. This observation is an acceptance tooling caveat, not an established
app deletion defect. The raw capture is still private and unlabeled.

The user authorized temporary Do Not Disturb to prevent notification banners from intercepting navigation.
It was visibly off again at the end. The acceptance process was stopped after cleanup. Five targeted
`WorkoutExecutionTests` also passed, including the persisted absolute rest deadline and history/deletion tests.
