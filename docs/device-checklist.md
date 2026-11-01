# Device checklist

Everything that needs your iPhone or a live Muse call, in the order to do it. Each step says what to do and
what you should see. Tick a box only when you saw the expected result.

Nothing here needs a key typed anywhere except at the `wrangler secret put` prompts in section 4.

## 1. Signing and install

- [ ] Open `MovementTracker.xcodeproj`. Select target `MovementTracker`, then Signing & Capabilities. Leave
  "Automatically manage signing" on and choose your Team. Expected: no red signing error.
  The bundle ID is `io.github.kiraguriz.MovementTracker`; if your team cannot register it, change it, and use the
  new one in the `devicectl` command in section 3.
- [ ] HealthKit capability. The project already carries the entitlement (`Config/MovementTracker.entitlements`). In
  the same pane, check that HealthKit is listed. With automatic signing Xcode enables it on the App ID. Expected:
  the build signs. In the developer portal
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

- In Me, turn on **Save pose recordings**. It is off by default and persists across launches, including from
  the Home Screen. `-MTRecordPoses` still forces it on in Debug builds. The setting applies to the next live set.
  A red record icon (VoiceOver label "Recording poses") shows in the live set while it is on.
- **End set** keeps any recording with frames, including zero counted reps, partial-only sets and missed reps.
  Zero-rep recordings do not add an empty workout set. Discarding a live set drops its unfinished recording.
- An export copy is in **Files > On My iPhone > Movement Tracker+ > PoseCaptures**, named `<capture id>.jsonl`.
  Share or copy it to the Mac from Files. An app-owned original stays in
  `Library/Application Support/MovementTracker/PoseCaptures/`; changing or deleting an export does not change
  that original. Files named `pending-*.jsonl` there are interrupted recordings, not completed captures.
- Skeleton coordinates only, no video. The first line is a JSON header with `exerciseSpecID`, `cameraPosition`,
  `created`, the frame count and labels.
- Rep and partial labels are left empty. Give the true counts in the labelling step below. Older recordings
  may contain the algorithm's own counts; those must also be replaced by your independent count.

Steps:

- [ ] In Me, turn on Save pose recordings. Run a live set on the phone.
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

- [ ] After End set, open Files > On My iPhone > Movement Tracker+ > PoseCaptures. Copy the recordings to the Mac.
  Files visibility and sharing still need a real-device check. The `devicectl` fallback below also retrieves
  older captures and private originals (the syntax was checked against `devicectl --help`; it has not been run
  against a phone):

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
  tools/import-fixture.sh ~/Desktop/pose-captures/<capture id>.jsonl --reps 10 --partials 1 --tag person-a --tag room-1
  ```

  Expected: it prints the full path of the new file, `<repo>/fixtures/real/squat.bodyweight_10_1_front_person-a_room-1_<8 hex digits>.jsonl`
  (the camera comes from the recording). It fills in your counts, adds the `verified` tag, keeps the frames byte for byte and refuses to
  overwrite. Tags: `person-a`, `person-b`, `room-1`, `room-2`; the accuracy report counts these. `--partials`
  defaults to 0. Unfinished captures, empty captures, inconsistent frame counts and malformed frames are
  refused before they can be marked verified.
- [ ] Idle and noise clips. In a live set, stand still for about 30 s, then End set. Repeat with walking into and
  out of frame. Export and label each with `--reps 0 --tag idle`, plus the person and room tags. Keep the true
  count at zero even if the app reports false reps. These JSONL clips exercise the same on-device pose stream
  as workout sets. Camera videos remain an alternative: name them `squat.bodyweight_0_idle-front.mov` and put
  them in `fixtures/real/`. Videos run through Vision on the Mac and are listed separately as "Real videos".
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

Completed for this project on 2026-11-01: the proxy is deployed, both secrets are configured, and real
Muse/SSE/USDA checks passed. See [cloudflare-deployment.md](cloudflare-deployment.md). The checklist below
is retained for a fresh account or redeployment; do not create replacement resources for the existing deployment.

Full detail: [`proxy/README.md`](../proxy/README.md), section "Deploy (your steps)". Needs a Cloudflare account and
Node 24 or newer. Type the two keys only at the prompts; do not paste them into a file, a chat or the shell.

- [ ] From `proxy/`:

  ```sh
  npm ci
  npx wrangler login
  npx wrangler kv namespace create movement-tracker-proxy
  ```

  For a fresh account, paste the printed id into `proxy/wrangler.jsonc` as `kv_namespaces[0].id`, replacing
  the existing deployment's id. A KV id is not a secret.
- [ ] Set the secrets. Each command asks for the value:

  ```sh
  npx wrangler secret put MODEL_API_KEY
  npx wrangler secret put USDA_API_KEY
  ```

  If it offers to create the Worker first, answer yes. `MODEL_API_KEY` is the Meta Model API key;
  `USDA_API_KEY` is the free key from api.data.gov. Both live only as Worker secrets.
- [ ] `npx wrangler deploy`. Expected: it prints `https://movement-tracker-proxy.<subdomain>.workers.dev`.
- [ ] For a different deployment, set that public HTTPS address as `COACH_PROXY_URL` in both Debug and
  Release app build settings. `Config/Info.plist` expands it into `CoachProxyURL`; no Swift source edit is
  needed. This checkout already configures the current deployment. Keep credentials in Worker secrets.
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

Additional recovery checks after the 2026-11-01 changes:

- [ ] With Health on, save a meal and immediately terminate/relaunch. The business row and export intent
  are committed together; foreground drain retries the same sync identifier/version.
- [ ] Delete an exported meal while Health is temporarily unavailable, then switch exports off. On the
  next foreground drain with deletion access, its samples are removed and no live meals are exported.
- [ ] Interrupt a camera set after a counted rep has checkpointed. Relaunch: the draft contains one
  interrupted set with its saved reps. Finish/retry must not duplicate it. Calibration starts fresh for
  a subsequent set; the app does not resume a camera pipeline from a crash.
- [ ] Switch cameras while recording. Its exported header is `cameraPosition: unknown` and has the
  `mixed-camera` tag, so it cannot be labeled as a single-camera real fixture. The next set starts with
  the preferred camera and can yield a valid single-camera fixture.
- [ ] Confirm a coach plan. The draft retains each known exercise's targets and notes but no completed
  sets. Log sets, check the rest countdown across background/relaunch, and inspect history/progress.

Needs the HealthKit capability from section 1. Health is off until you turn on the Apple Health switch in Me.
Only what you save while it is on is sent; turning it on does not send older data. The app writes Workouts and
Active Energy (an estimate from MET values, marked as one), Dietary Energy, Protein, Carbohydrates, Total Fat, and
Weight. Every sample carries a sync identifier and version so a re-save replaces instead of duplicating.

- [ ] Authorization. In Me, turn on Apple Health. Expected: the Health sheet lists the types above to write and
  does not request Weight or Steps read access. Allow all; the switch stays on. Upgrading does not revoke
  any read access the user granted an older build; that can be removed in Health settings.
- [ ] Partial workout access. Allow Workouts but deny Active Energy, then finish a workout. Expected: one
  workout, no energy sample. Grant Active Energy in Health and return to the app: the queued export completes,
  with one workout and one estimated energy sample. Also test the reverse: energy allowed, workouts denied;
  only the energy sample is written until workout access is granted.
- [ ] Partial meal access. Allow Dietary Energy but deny the macros, then save a meal. Expected: its calories
  appear and the meal stays queued without consuming failure attempts. Edit the meal, grant the macros, and
  return to the app: the latest calories and macros appear once each. An allowed weight entry must still sync
  even while older meals are waiting for macro access.
- [ ] Denied. On a second install or after resetting, deny the sheet. Expected: an alert, and the switch stays off.
- [ ] Workout. Finish a workout of at least one set. In Health: Browse, Activity, Workouts. Expected: one
  Traditional Strength Training workout with the right start time and duration, source Movement Tracker+. Active Energy has
  one sample for it.
- [ ] Meal. Save a meal of 200 g. In Health: Browse, Nutrition, Dietary Energy, Protein, Carbohydrates, Total
  Fat, Show All Data. Expected: one sample of each at the meal's time, matching the app's numbers.
- [ ] Weight. Log a weight on Today. In Health: Browse, Body Measurements, Weight. Expected: one sample with that
  value. Then change the weight in Me, edit profile, and save. Expected: a second sample with the new value.
- [ ] No duplicates after an edit. Edit that meal (change 200 g to 100 g) and save. Expected: Health still shows
  one sample per nutrient for that meal, now with the new values.
- [ ] Removal after a delete. Delete that meal in Eat. Expected: its Dietary Energy, Protein, Carbohydrate and Fat
  samples are gone from Health.
- [ ] Revoked access. Revoke all write access in Settings, Health, Data Access & Devices, Movement Tracker+, then
  return to the app. Expected: the Apple Health switch in Me is off, and saving a meal still works. Samples
  written before the revoke stay in Health until you delete them there.
- [ ] Switch off. Turn the switch off in Me and save a meal. Expected: it does not appear in Health.

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
| Today and Health | Today shows the day's nutrition and the latest workout. With the Apple Health switch on, Health shows the same workout and meal. | |
| Architecture and accuracy | The diagram and the table from the README, with the synthetic rows labelled generated motion. The real row is filled in only if real sets were imported (section 3). | |
| Close | | |

Total time: ____ . Whatever failed or ran long: ____

Backups if the room has no network or the camera misbehaves: launch from Xcode with `-MTReplayPoses squat` (the
live set then replays the bundled clip on the phone) and `-MTCoachStub` (canned coach, labelled as such). Say so
in the video; do not present stub or replay output as Muse or as a camera.
