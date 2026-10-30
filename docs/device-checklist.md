# Device checklist

Everything that needs your iPhone or a live Muse call, in the order to do it. Each step says what to do and
what you should see. Tick a box only when you saw the expected result. Written against `main` at `a5506c8`.
Apple Health is not connected in the app there, so section 6 and the HealthKit step in section 1 only apply once
it is.

Nothing here needs a key typed anywhere except at the `wrangler secret put` prompts in section 4.

## 1. Signing and install

- [ ] Open `MovementTracker.xcodeproj`. Select target `MovementTracker`, then Signing & Capabilities. Leave
  "Automatically manage signing" on and choose your Team. Expected: no red signing error.
  The bundle ID is `io.github.kiraguriz.MovementTracker`; if your team cannot register it, change it, and use the
  new one in the `devicectl` command in section 3.
- [ ] HealthKit capability, only once the app calls `HealthBridge` (at `a5506c8` it has no HealthKit entitlement
  or usage string). In the same pane, check that HealthKit is listed; if it is missing, press + Capability and add
  it. With automatic signing Xcode enables it on the App ID. Expected: the build signs. In the developer portal
  (Certificates, Identifiers & Profiles, Identifiers) the App ID shows HealthKit enabled. A provisioning error
  naming the HealthKit entitlement means the App ID does not have it yet.
- [ ] iPhone: Settings, Privacy & Security, Developer Mode on. Connect it, pick it as the run destination.
- [ ] Run (Debug). If asked, trust the developer certificate in Settings, General, VPN & Device Management.
  Expected: the app opens (onboarding on a fresh install).
- [ ] Finish onboarding. Open Train, Start workout, Add exercise, Squat, Live set, and allow the camera.
  Expected: live preview with a skeleton overlay.

## 2. Day-0 Vision gate

Brief §6.8. The numbers come from the debug HUD, which exists only in Debug builds.

- [ ] Edit Scheme, Run, Arguments, add `-MTDebugHUD`. (Without it, a long press on the rep counter in a live set
  toggles the HUD.) For the readings you keep, also untick Info, "Debug executable", so the debugger does not
  slow the app; the Debug configuration, and with it the HUD, stays. Do not pass `-MTReplayPoses`: a replay
  has no camera numbers.
- [ ] Open a squat Live set. Stand sideways to the camera so you fill at least a third of the frame height. Expected:
  the framing prompts ("Step back", "Turn sideways to the camera", "Get your whole body in view") go away and
  counting starts.
- [ ] Do 10 squats, then stand still for 30 s. Read the HUD (it refreshes four times a second) and write the
  values in the table below.

| HUD line | Pass | Where the threshold comes from |
| --- | --- | --- |
| `vision p50 ... ms` | 20 ms or less | Brief §6.1: "target ≤ 20 ms/frame". |
| `vision p95 ... ms` | under about 33 ms | One frame at 30 fps. The brief gives no p95 number; this is a judgement call. |
| `fps` against `target 30`, `dropped` | at the target, `dropped` not climbing | Brief §6.1: 30 fps capture. Late frames are discarded, not queued. |
| `person` and `failed` | `person` near 100% while you are in frame, `failed 0` | A judgement call; the brief has no number. |
| `center stage` and `stabilization` | both `off` | Brief §6.7 disables Center Stage; the HUD's own note says neither may crop the picture. |

- [ ] Joint stability while still. The brief names this check but gives no number, and the HUD shows no jitter
  figure. Standing still for 30 s: the rep counter stays 0, no partial appears, the depth gauge stays flat and
  the skeleton does not visibly shake.
- [ ] Repeat with the back camera (Switch camera button) and write down the numbers.
- [ ] Verdict. Pass: p50 and p95 within the table and the still check clean on both cameras. Fail: the brief's
  plan is MediaPipe Pose Landmarker, which needs your approval as a new dependency. The brief's other fallback,
  running Vision on every second frame, is not implemented; the pipeline drops late frames instead.

Results (fill in):

| Camera | p50 ms | p95 ms | fps | dropped | still check | verdict |
| --- | --- | --- | --- | --- | --- | --- |
| Front | | | | | | |
| Back | | | | | | |

## 3. Recording fixtures

Brief §6.8 targets: at least 10 squat sets, at least 10 push-up sets, idle or noise clips, two people, two
rooms, front and back camera. Real sets are what turn the accuracy table from synthetic into evidence.

How recording works in this build:

- Recording is on only when the app is launched with `-MTRecordPoses` from Xcode. A setting for it exists in the
  database but no screen sets it, so a launch from the Home Screen does not record. A red record icon (VoiceOver
  label "Recording poses") shows in the live set while it is on.
- A recording is kept only for a set that counted at least one rep and was logged. A set with zero counted
  reps is deleted, so the app cannot record an idle clip; the idle-clip step below uses a video instead.
- The file is `Library/Application Support/MovementTracker/PoseCaptures/<set id>.jsonl` in the app container.
  It is not visible in the Files app. Files named `pending-*.jsonl` are left over from a set that did not finish saving (a crash, for example);
  ignore them.
- Skeleton coordinates only, no video. The first line is a JSON header with `exerciseSpecID`, `cameraPosition`,
  `created`, the frame count and labels.
- The app writes its own counted reps and partials into the header labels. That is the number under test, not the
  truth. You replace it in the labelling step below.

Steps:

- [ ] Edit Scheme, Run, Arguments, add `-MTRecordPoses`. Run on the phone.
- [ ] Keep a log. For every set write down: time, exercise, camera, person, room, the reps you counted yourself,
  and the dips you did on purpose that should not count (partial reps). Count out loud or on paper; do not read
  the true count off the screen.
- [ ] Record the sets. Do not switch cameras during a set: the header keeps the camera the set started on.
  Mix in slow reps, pauses at the bottom and a few partial reps.

| What | Target | Done |
| --- | --- | --- |
| Squat sets | at least 10 | |
| Push-up sets | at least 10 | |
| Person A and person B | both | |
| Room 1 and room 2 | both | |
| Front camera and back camera | both | |

- [ ] Copy the folder to the Mac (the syntax was checked against `devicectl --help`; it has not been run against
  a phone):

  ```sh
  xcrun devicectl list devices
  xcrun devicectl device copy from --device "<your iPhone name>" \
    --domain-type appDataContainer --domain-identifier io.github.kiraguriz.MovementTracker \
    --source "Library/Application Support/MovementTracker/PoseCaptures" --destination ~/Desktop/pose-captures
  ```

  Or in Xcode: Window, Devices and Simulators, select the iPhone, Installed Apps, Movement Tracker+, the
  ellipsis, Download Container. Right-click the `.xcappdata` file, Show Package Contents, then
  `AppData/Library/Application Support/MovementTracker/PoseCaptures/`.
- [ ] Match each file to your log. `head -c 400 <file>.jsonl` shows `created` (the start time) and the camera.
- [ ] Label and import each file with the truth from your log:

  ```sh
  tools/import-fixture.sh ~/Desktop/pose-captures/<set id>.jsonl --reps 10 --partials 1 --tag person-a --tag room-1
  ```

  Expected: it prints the full path of the new file, `<repo>/fixtures/real/squat.bodyweight_10_1_front_person-a_room-1_<8 hex digits>.jsonl`
  (the camera comes from the recording). It replaces the app's counts with yours, adds the `verified` tag, keeps the frames byte for byte and refuses to
  overwrite. Tags: `person-a`, `person-b`, `room-1`, `room-2`; the accuracy report counts these. `--partials`
  defaults to 0.
- [ ] Idle and noise clips, as videos. With the Camera app record about 30 s of standing still in frame, and a
  clip of walking into and out of frame. Copy them to `fixtures/real/` named
  `squat.bodyweight_0_idle-front.mov` (the exercise, then the true reps, 0). They run through Vision on the Mac,
  not through the on-device pipeline, and are listed as "Real videos". Git ignores videos in that folder.
- [ ] Regenerate the table:

  ```sh
  tools/accuracy.sh
  ```

  Expected: `docs/accuracy.md` and the table in `README.md` now have a "Real sets recorded on iPhone" row, and the
  coverage table moves toward the targets above. Files it cannot count are listed under "Skipped" with the
  reason (not verified, not a camera recording, tagged synthetic or replay).
- [ ] Commit `fixtures/real/*.jsonl`, `docs/accuracy.md` and `README.md`.

Do not change a label to make a number look better. A set the engine miscounted is the result. Keep it: it is
also a regression case for the engine.

## 4. Proxy deploy

Full detail: [`proxy/README.md`](../proxy/README.md), section "Deploy (your steps)". Needs a Cloudflare account and
Node 24 or newer. Type the two keys only at the prompts; do not paste them into a file, a chat or the shell.

- [ ] From `proxy/`:

  ```sh
  npm install
  npx wrangler login
  npx wrangler kv namespace create movement-tracker-proxy
  ```

  Paste the printed id into `proxy/wrangler.jsonc` as `kv_namespaces[0].id`, replacing
  `REPLACE_WITH_KV_NAMESPACE_ID`. A KV id is not a secret.
- [ ] Set the secrets. Each command asks for the value:

  ```sh
  npx wrangler secret put MODEL_API_KEY
  npx wrangler secret put USDA_API_KEY
  ```

  If it offers to create the Worker first, answer yes. `MODEL_API_KEY` is the Meta Model API key;
  `USDA_API_KEY` is the free key from api.data.gov. Both live only as Worker secrets.
- [ ] `npx wrangler deploy`. Expected: it prints `https://movement-tracker-proxy.<subdomain>.workers.dev`.
- [ ] Put that address in `App/Support/CoachEndpoint.swift`:
  `static let deployed: URL? = URL(string: "https://movement-tracker-proxy.<subdomain>.workers.dev")`. The address
  is not a secret. Without it the app has no coach.
- [ ] From the repo root:

  ```sh
  PROXY_URL=https://movement-tracker-proxy.<subdomain>.workers.dev tools/muse-smoke.sh
  ```

  Expected: `1/3 health` with `{"ok":true,"killSwitch":false}`, `2/3 install token` ("token issued", 43
  characters, not printed), then `3/3 coach request` ending in `model:`, `tokens:` and `reply:` lines.
  Fail: `502 upstream_unauthorized` means the Meta key or its credit is the problem. Check that the hackathon
  credit has landed.
- [ ] To pause everything: `npx wrangler deploy --var KILL_SWITCH:1`; `npx wrangler deploy` resumes it.

KV on the free Cloudflare plan allows 1,000 writes a day. Each coach request writes a counter, so use the paid
plan if you will run more than a rehearsal.

## 5. Live Muse checks

Needs section 4 done and the app rebuilt with the Worker address. In the app: Me, Coach on, Turn On. Then Me,
What Muse sees, and read the list.

- [ ] Set review cites reps. Do a Live set of at least 6 squats with one clearly shallow rep, then End set.
  Expected: the on-device numbers (Reps, Partial, Score, Velocity loss, one chip per rep) appear at once; the
  Muse card then streams in; it finishes in under 8 s (brief §11, D3). Each fix shows "Reps n, m" and every
  number matches a chip. Nothing in the Muse text contradicts the on-device counts. The card has no
  "written on your device" notice, and a "What Muse saw" section lists the data and the skeleton drawings. With
  Voice cues on, the headline is spoken.
- [ ] Session debrief. Do two sets of one exercise, then Finish. Expected: the summary screen shows a Muse
  debrief that mentions the session you just did.
- [ ] Chat uses tools. Ask Coach (the bar above the tabs): "How did my last session go?". Expected: a chip
  "Coach looked at ..." for each read tool that ran, and an answer that matches your data. Then ask for a
  week plan. Expected: a proposal card; nothing is saved until you confirm. Ask for a goal change: expected: a
  preview from the planner, applied only on your tap.
- [ ] Meal photo. Eat, +, Meal photo, Take Photo of a real meal. Expected: items with grams, each matched in USDA;
  an editable confirm sheet; saving adds the meal to the day and updates the Eat totals.
- [ ] Food search. Eat, +, Search food, "chicken breast". Expected: results with calories and macros that you can
  pick and save. Search also works with Coach off.
- [ ] Offline. Turn on Airplane Mode and end a set. Expected: the on-device numbers, then the notice "Muse could
  not be reached. This was written on your device." with Try again; the review and debrief still have text.
  Chat and meal photo show "You're offline" and offer a retry. Turn Airplane Mode off and tap Try again;
  expected: a Muse answer.
- [ ] Budget. The daily limits are per install and reset at 00:00 UTC: set review 120, debrief 20, chat 100,
  meal photo 40, food search 300 (`proxy/README.md`). To see the exhausted state without spending them, run the
  Debug stub: launch with `-MTCoachStub -MTCoachStubFail budget` and `-MTAIOptIn`. Expected: chat says "You've
  reached today's coach limit. Try again tomorrow." and the photo flow says "You've reached today's photo limit.
  You can still add meals by hand." The stub is canned and labelled; it is not a Muse test.
- [ ] Pause. `-MTCoachStubFail paused` should show "The coach is paused right now. Try again later."

## 6. Apple Health

Applies only once the app calls `HealthBridge`; at `a5506c8` nothing does, so there is nothing to check yet. It also
needs the HealthKit capability from section 1. The package writes these types:
Workouts and Active Energy (an estimate from MET values, marked as one), Dietary Energy, Protein, Carbohydrates,
Total Fat, and Weight. It reads the latest Weight and today's Steps. Every sample carries a sync identifier and
version so a re-save replaces instead of duplicating.

- [ ] Authorization. The first write opens the Health sheet. Expected: it lists the types above to write and
  Weight and Steps to read. Allow all.
- [ ] Workout. Finish a workout of at least one set. In Health: Browse, Activity, Workouts. Expected: one
  Traditional Strength Training workout with the right start time and duration, source Movement Tracker+. Active Energy has
  one sample for it.
- [ ] Meal. Save a meal of 200 g. In Health: Browse, Nutrition, Dietary Energy, Protein, Carbohydrates, Total
  Fat, Show All Data. Expected: one sample of each at the meal's time, matching the app's numbers.
- [ ] Weight. Log a weight on Today. In Health: Browse, Body Measurements, Weight. Expected: one sample with that
  value.
- [ ] No duplicates after an edit. Edit that meal (change 200 g to 100 g) and save. Expected: Health still shows
  one sample per nutrient for that meal, now with the new values. Edit the weight, if the app offers it:
  expected the same.
- [ ] Removal after a delete. Delete that meal in Eat. Expected: its Dietary Energy, Protein, Carbohydrate and Fat
  samples are gone from Health.
- [ ] Read. Add a weight in the Health app. Expected: the app picks it up as the latest weight, and a weight this app
  exported is not imported a second time. Skip if the app does not surface reads.
- [ ] Denied access. Revoke write access in Settings, Health, Data Access & Devices, Movement Tracker+, then save a
  meal. Expected: the app still saves it and does not crash. Re-enable access; expected: the meal reaches
  Health on the next sync (the exporter keeps the entry queued; when the app next syncs depends on how Health is
  wired in). Samples written before the revoke stay in Health until you delete them there.

## 7. Demo dry run

Brief §11. Aim for 3 minutes or less. Run it start to finish on the phone, screen-recording the first pass, with
Coach on and the Worker deployed. Optional, for a populated Today without onboarding: launch from Xcode with
`-MTInMemoryDatabase -MTSeed sample -MTAIOptIn` (the data is gone when the app quits).

Before the pass: volume up, Voice cues on in Me, Do Not Disturb on, battery above 50%, no Airplane Mode.

| Step | Expected on screen | Done |
| --- | --- | --- |
| Hook: training alone, no coach | Say it over the Today tab. | |
| Framing check | Prompts appear, then clear once you are sideways and fully in frame. | |
| Live squat set | Counter and depth gauge move; one spoken cue; a shallow dip shows "1 partial" and is not counted. | |
| End set, set review | Numbers at once; Muse card streams in citing reps; velocity loss shown. | |
| Coach chat | Tool chips ("Coach looked at ..."); a proposed plan you confirm. | |
| Meal photo | Foods and grams, USDA match, editable sheet, saved. | |
| Today and Health | Today shows the day's nutrition and the latest workout. With Health connected, Health shows the same workout and meal; skip that half otherwise. | |
| Architecture and accuracy | The diagram and the table from the README, with the synthetic rows labelled generated motion. The real row is filled in only if real sets were imported (section 3). | |
| Close | | |

Total time: ____ . Whatever failed or ran long: ____

Backups if the room has no network or the camera misbehaves: launch from Xcode with `-MTReplayPoses squat` (the
live set then replays the bundled clip on the phone) and `-MTCoachStub` (canned coach, labelled as such). Say so
in the video; do not present stub or replay output as Muse or as a camera.
