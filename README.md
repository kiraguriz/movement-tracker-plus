# Movement Tracker+

An iPhone coach that watches your set through the camera, counts every rep on-device, measures depth, tempo
and fatigue per rep, and has Meta's Muse model turn those numbers into coaching, plans and nutrition logging.

Built solo for the Meta Global AI Developer Hackathon 2026 (Indie track). It is a from-scratch native rewrite
of a CS440 class project; no code or assets carried over. `docs/build-log.md` lists what was committed when.

Native iOS, SwiftUI, Swift 6 strict concurrency. Deployment target iOS 27.0. Built-in exercises with rep
counting: bodyweight squat and push-up, both filmed from the side. You can also teach the app your own exercise.

## Try it in 5 minutes

1. Open `MovementTracker.xcodeproj` in Xcode 27.1, pick the `MovementTracker` scheme and an iOS 27 iPhone
   simulator, and run it in the Debug configuration.
2. Go through setup. Coach uses the deployed proxy and needs no keys; turn it on there, or later with the
   Coach switch in Me.
3. In Train: Start workout, Add exercise, Squat, Live set. The Simulator has no camera, so the set replays a
   bundled clip of that exercise. End the set to read its review.

More launch arguments are listed under "Run in the Simulator with the replay fixtures".

## The loop

1. Frame yourself, with the front or back camera. Counting starts once the joints the exercise needs are
   confident and clear of the frame edge, your body fills at least a third of the frame height, and, for squat
   and push-up, you are side-on to the camera; all of it has to hold for a second.
2. Do a live set. Reps, partial reps and a depth gauge update on-device from the camera, with at most one
   spoken cue per rep.
3. Read the set review. Per-rep measurements first, then Muse's review, which cites reps by number.
4. Ask the coach. Chat answers from your own data through on-device tools; plans and meals come back as
   proposals you confirm.
5. Log a meal from a photo. Muse names the foods and estimates grams, USDA supplies the nutrients, you edit
   and save.
6. Today shows the day's nutrition, your latest workout and a weight trend. With the Apple Health switch in Me on,
   finished workouts, meals and weight are written to Health, and deleting them in the app removes them there.
   With partial Health access, the allowed types are written and the rest stay queued for a later grant.
7. Teach a new exercise by demonstration. You do a few reps and say how many; the app saves it as a counted
   exercise only when a replay of the demonstration through the engine reproduces that count. Otherwise it
   can be kept for logging by hand.

Apple Health is connected once, during setup. The app writes workouts, meals and weight. It reads sex, date of
birth, height and body mass to fill in the profile, and sleep, heart rate variability, resting heart rate and
breathing rate for Today's readiness. Raw sleep and heart readings never leave the phone.

Also shipped:

- **Today.** A readiness estimate from those recovery readings, and what to do today (train, go easy, rest),
  with the suggested exercises, sets and reps and a one-tap start.
- **Weekly streak.** Progress against your workouts-per-week goal and how many weeks in a row met it.
- **Live Activity.** The workout in progress on the Lock Screen and in the Dynamic Island: exercise, set,
  reps and the rest countdown.
- **App Shortcuts and Siri.** "Start a set" opens Train with that exercise's set started; "Log weight" saves a
  weight without opening the app.
- **Rest alerts.** A local notification says the rest is over while the app is in the background.
- **Voice cues.** Spoken with the best installed voice for the app's language: premium, then enhanced, then
  standard.

Training drafts checkpoint each processed counted rep, and an interrupted set survives relaunch. Confirmed
coach plans retain sets/reps/rest and notes without counting targets as completed work. Today and Train open
workout history, per-set measurements and exercise-specific progress; saved sets can be corrected or deleted.
Meal entries retain grams or millilitres and their corrected nutrient basis when edited or reused.

## How it uses Muse

Muse never counts reps. Reps, partial reps, depth, tempo, velocity loss and form scores are measured on the
phone by `MotionCore`. The set review, debrief and chat prompts tell the model these are facts it must not recount,
and a review that cites a rep that does not exist is rejected. On-device numbers are the truth; Muse explains them.

| Feature | Model | Reasoning effort | What comes back |
| --- | --- | --- | --- |
| Set review | `muse-spark-1.3` | low | Strict JSON schema `SetReview`: headline, what went well, up to two fixes that cite rep numbers, next set, safety flag, confidence. Input is the per-rep numbers plus up to two skeleton drawings (best and worst rep at the bottom). Streamed. |
| Session debrief | `muse-spark-1.3` | medium | Strict schema `SessionDebrief`: summary, per-exercise verdicts, concerns, next session. Numbers only, no images. Streamed. |
| Coach chat | `muse-spark-1.3` | medium | Streamed text with function calls. Five read tools (`get_sessions`, `get_set_detail`, `get_nutrition`, `get_body_trend`, `get_goal`) run on the device against the local database. Three propose tools (`propose_plan`, `propose_meal_log`, `propose_goal_change`) only return a proposal; nothing is saved until you confirm. |
| Meal photo | `muse-spark-1.3` | low | Strict schema `MealEstimate`: foods, grams, confidence and a USDA search phrase each. One photo, not streamed. |
| Goal plan (`goal_plan`) | `muse-spark-1.3` | low | Strict schema `GoalPlan`: daily calories, macros, workouts per week and a short rationale. Input is age, sex, height, weight, training level, the goal and the ranges the phone computed. `GoalPlanGuard` on the device keeps the numbers inside those ranges; on any failure setup shows the phone's standard plan. Streamed. |
| Daily tip (sent as `debrief`) | `muse-spark-1.3` | low | Strict schema `DailyTip`: one sentence explaining Today's suggestion. Input is the on-device suggestion (kind, exercises, sets, reps, reasons), plus the coarse recovery summary only when that switch is on. Not streamed. |
| Teach form checks (`spec_author`) | `muse-spark-1.3` | low | Strict schema `SpecDraft`: up to three form checks from a menu the phone offers, with thresholds inside its ranges. Input is the exercise name, joint angles, pace and range of the demonstration, and two skeleton drawings (start and middle pose). Streamed. |

- **Proxy.** The app never talks to Meta directly. It calls a Cloudflare Worker (`proxy/`) that holds the Muse and
  USDA keys as Worker secrets, forwards to the Meta Responses API, allows only `muse-spark-1.3` and
  `muse-spark-1.2`, limits reasoning effort, output tokens and body size per feature, forces `store: false`,
  and uses a SQLite Durable Object for atomic per-install and global request budgets, plus a kill switch.
- **Strict schemas.** Set review, debrief and meal photo are requested with `strict: true` JSON schemas and
  decoded with Codable. A bad answer is retried once with the error. If Muse still cannot answer (bad output,
  no network, daily budget spent, service paused), the set review and debrief fall back to an on-device review
  written from the rule engine, marked as such on screen. A meal photo has no fallback and shows the error.
- **Cache.** Answers are cached by a hash of the input, prompt version, model and effort, and stored with the
  model, token usage and a "What Muse saw" record.
- **Teach form checks.** When Muse picks a check that needs extra joints, those joints become required for
  counting. The demonstration is replayed with the checks in place, and the exercise is saved with them only
  if every rep still counts and the checks find no fault in it; otherwise it is saved without checks.
- **Not in the app yet.** The proxy and `CoachKit` have a voice-transcription route; no screen uses it.

## Architecture

```mermaid
flowchart LR
  subgraph app["App target (SwiftUI)"]
    ui["Features and design system"] --> env["AppEnvironment<br/>composition root"]
  end
  subgraph pkg["Packages/MovementKit"]
    mc["MotionCore"]
    dom["Domain"]
    pc["PoseCapture"] --> mc
    per["Persistence (GRDB)"] --> dom
    ck["CoachKit"] --> dom
    hb["HealthBridge"] --> dom
    ev["motion-eval"] --> mc
    ev --> pc
  end
  ui --> mc & pc & ck & dom
  ui --> al["AppLogic<br/>meal editor, workout application, history"]
  al --> dom
  env --> per & ck & hb & dom
  ck -- "HTTPS, install token" --> w["Cloudflare Worker<br/>proxy/"]
  w -- "server-held keys" --> muse["Meta Model API (Muse)"]
  w --> usda["USDA FoodData Central"]
```

- `MotionCore` and `Domain` import only Foundation and do not import each other; the app maps between them.
  `swift test` builds and runs the whole package on macOS. Camera capture and HealthKit are behind
  `#if os(iOS)`.
- Each adapter depends on one core module: `PoseCapture` (AVFoundation, Apple Vision 2D body pose) on
  `MotionCore`; `Persistence`, `CoachKit` and `HealthBridge` on `Domain`. Adapters do not import each other.
- `MotionCore` is the engine: confidence gate, short-gap hold, One-Euro filter, body normalization, side lock, a
  time-based adaptive-hysteresis rep segmenter, and a rule engine driven by bundled JSON exercise specs
  (`squat.bodyweight`, `pushup`).
- The app target holds the screens and `AppEnvironment`, which builds every store from one database and passes
  them to the screens as protocols through a SwiftUI environment value. `Persistence` is imported there and
  nowhere else in the app. `Persistence` commits Health sync intent with eligible business writes;
  `App/Health/` wrappers wake the worker, and foreground drains recover after interruptions. Health write
  failures leave durable retry work and do not fail the original save.
- `AppLogic` holds the actual meal editor, localized number parser, confirmed plan application, absolute-date
  rest periods and workout history/progress logic, exercised by portable tests against real repositories.
- `motion-eval` is the accuracy tool described below.

## Privacy

- **Consent.** Coach is off until you turn it on: during setup, in Me with the Coach switch (it asks first), or with the
  Share with Muse switch on the card that the Coach sheet and the meal photo flow show while it is off.
  `Me > What Muse sees` lists the data. With Coach off nothing goes to Muse and the set review stays on-device.
- **What can leave the phone with Coach on:** your chat messages; workout numbers (sets, reps, load, depth,
  tempo, fatigue, form scores); meals (names, calories, macros); weight and body fat history, calorie targets,
  age, sex, height and training level; up to two skeleton drawings per set review; for an exercise you teach,
  its name, two skeleton drawings and the joint angles of the demonstration; a meal photo, only when you log a
  meal with one. Photo metadata is removed before sending.
- **Recovery summary.** A separate switch in `Me > What Muse sees`, shown once readiness is on. With it on,
  Today's daily tip also gets the readiness band (ready, steady, easy) and whether sleep, HRV and resting heart
  rate are below, near or above your usual. Never the readings.
- **Food search** sends what you type to USDA FoodData Central through the proxy, with Coach on or off.
- **Never leaves the phone:** camera video, your name, sleep, HRV and heart rate values.
- **Pose recordings.** Opt in with Me > Save pose recordings. End set keeps skeleton coordinates, including
  idle and missed-rep clips, with an export copy in Files > On My iPhone > Movement Tracker+ > PoseCaptures.
  No video is recorded or uploaded. Fill in the true rep counts when importing a capture for evaluation.
- **No keys in the app.** The Muse and USDA keys exist only as Cloudflare Worker secrets. The app holds an
  anonymous install token in the Keychain. The Worker logs route, status and duration only, never bodies, tokens
  or IPs, and does not allow Meta's `*-contributor` models, whose data Meta uses to improve its products.
- Launch flags are ignored in Release builds, and the canned coach stub and the debug HUD are not compiled into
  them.

## Build and test

Requires Xcode 27.1 and Node 24 or newer (proxy tests only).

```sh
swift test --package-path Packages/MovementKit
python3 -B -m unittest discover -s tools/tests -v
xcodebuild -project MovementTracker.xcodeproj -scheme MovementTracker -destination 'generic/platform=iOS Simulator' build
npm test --prefix proxy
```

Run `npm ci --prefix proxy` once for the approved proxy dev tool. `tools/check.sh` runs the complete local
delivery checks, including Debug/Release and unsigned device SDK builds, without booting a Simulator.
GitHub Actions runs the native and proxy checks on every push/PR. See `docs/completion-status.md` for the
last verified results and outstanding device/service acceptance.

This checkout already configures the deployed proxy in both Debug and Release. For a different deployment,
follow `proxy/README.md` and set its public HTTPS address with the `COACH_PROXY_URL` Xcode build setting;
credentials stay in Worker secrets. With no URL configured, the Coach sheet is unavailable, set review
uses on-device fallback, and Eat offers manual entry only.

## Run in the Simulator with the replay fixtures

The Simulator has no camera, so a live set replays a recorded pose stream instead. The three bundled clips in
`App/Resources/ReplayPoses/` are generated (a scripted stick figure with simulated Vision noise; see
Accuracy), not recordings of a person. Regenerate them with `tools/replay-fixtures/generate.sh`.

In Xcode, pick the `MovementTracker` scheme and an iPhone simulator, then add launch arguments under Product,
Scheme, Edit Scheme, Run, Arguments. They apply to Debug builds only; a Release build ignores all of them.

| Argument | Effect |
| --- | --- |
| `-MTInMemoryDatabase` | Use a throwaway database. |
| `-MTPersistentTestDatabase` | Use a separate, durable Debug database; `-MTSeed` fills it only while it has no profile. |
| `-MTFailDatabase` | Behave as if the database could not be opened. |
| `-MTSeed profile` or `sample` | With the in-memory database: a finished profile, or a profile with weights, meals and a workout. |
| `-MTStartTab today\|train\|eat\|me` | The tab shown first. |
| `-MTReplayPoses squat\|pushup` | A live set replays that clip. Without it the Simulator replays on its own because there is no camera. |
| `-MTReplaySpeed 3` | Replay three times faster; counts do not change because the engine runs on recorded time. |
| `-MTReplayHoldReps 8` | Stop the replay after the 8th counted rep and leave the screen as it is. |
| `-MTExperimentalExercises` | Show camera exercises not yet checked on a person (the jumping jack) in the picker, the Train list and coach plans. |
| `-MTCoachStub` | Canned in-process coach, no network. Screens show a stub badge. |
| `-MTCoachStubFail offline\|budget\|paused` | With the stub, every coach call fails that way. |
| `-MTCoachStubPlan ok\|adjusted\|unsafe\|slow` | The stub's setup calorie plan: valid, moved by the guard, thrown away, or two minutes late. |
| `-MTNoCoach` | Show the unconfigured-coach state even with the deployed URL present. |
| `-MTAIOptIn` | With the in-memory database, start with Coach consent already given. |
| `-MTCoachURL <url>` | Use a proxy at this address, for example `wrangler dev`, instead of the deployed one. |
| `-MTDebugHUD` | Show camera and engine numbers over the live set (a long press on the rep counter toggles it). |
| `-MTRecordPoses` | Record the poses of every live set to a JSONL file. |
| `-MTMealPhotoSample` | Offer a generated sample photo in the meal photo sheet. |
| `-MTCameraState denied\|restricted` | Show that camera-permission state. |
| `-MTNotificationPrompt` | With the in-memory database, let the first workout ask for notification permission, and ask when a workout is already open at launch. |
| `-MTDraftWorkout working\|rest\|ready` | With a seed, start with an unfinished squat and push-up workout: no set yet, two sets with the rest running, or two sets with the rest over. |
| `-MTHealthStub` | Apple Health runs over an in-process fake that records writes and removals; Me shows its counters. `-MTHealthStub denied` denies access. |
| `-MTReadiness high\|normal\|low\|limited\|denied\|none\|unavailable` | Today's readiness reads a fake recovery source instead of Health. |

A walkthrough that needs no key and no network: `-MTInMemoryDatabase -MTSeed profile -MTStartTab train
-MTReplayPoses squat -MTCoachStub -MTAIOptIn`, then Start workout, Add exercise, Squat, Live set. With the stub
the set review shows its on-device fallback, marked as written on the device; chat and meal photo answer from
canned data and carry a stub badge. None of it is Muse.

## Accuracy

Generated by `tools/accuracy.sh` from `motion-eval`; per-clip results and definitions are in
`docs/accuracy.md`. Rows marked generated motion are scripted clips, not people.

<!-- accuracy:begin -->
| Data | Clips | Exact count | Within ±1 rep | Mean abs. error | False reps on idle clips | Partial reps exact |
| --- | --- | --- | --- | --- | --- | --- |
| Real sets recorded on iPhone | none yet | – | – | – | – | – |
| Synthetic benchmark (generated motion) | 24 | 24/24 (100%) | 24/24 (100%) | 0.00 reps | 0 over 5 idle clips | 24/24 (100%) |
| Bundled replay clips (generated motion) | 3 | 3/3 (100%) | 3/3 (100%) | 0.00 reps | no idle clips | 3/3 (100%) |

No real recordings are counted yet. Every number here comes from generated motion, not people, and the engine was tuned against that generator, so these rows are a regression check, not a measure of accuracy on people.
<!-- accuracy:end -->

Run the evaluation yourself:

```sh
swift run --package-path Packages/MovementKit -c release motion-eval --synthetic
swift run --package-path Packages/MovementKit -c release motion-eval App/Resources/ReplayPoses
swift run --package-path Packages/MovementKit -c release motion-eval --help
tools/accuracy.sh        # rebuilds docs/accuracy.md and the table above
```

`motion-eval` also reads real recordings (`.jsonl` from the app's recorder) and videos (`.mov`, `.mp4`). Real
sets recorded on an iPhone go in `fixtures/real/` through `tools/import-fixture.sh`, which labels the recording
with the counts you gave. The procedure is in `docs/device-checklist.md`.

## Real device checks

Physical-device acceptance steps and criteria are in [`docs/device-checklist.md`](docs/device-checklist.md).
Verified on an iPhone 17 Pro Max with the front camera: 30 fps with Vision p50 14.5–15.0 ms and p95 about
16 ms, and real Health nutrition writes, edits and app-driven deletion. Still unverified: real-person rep-count
accuracy (`fixtures/real/` is empty), device Health writes for workouts and weight, and the Live Activity on a
device. The proxy is now deployed; real Muse non-streaming/SSE, USDA search, seeded Coach conversation, set review,
session debrief and illustrated meal-photo logging passed. See [`docs/cloudflare-deployment.md`](docs/cloudflare-deployment.md) and
[`docs/ui-debug-report.md`](docs/ui-debug-report.md) for the exact evidence and remaining UI coverage.

## More

- `docs/rebuild-brief.md`: decisions, architecture, motion engine, schedule.
- `docs/accuracy.md`, `docs/build-log.md`: generated by `tools/accuracy.sh` and `tools/build-log.sh`.
- `proxy/README.md`: routes, policy table, limits, deploy.
- `docs/ios-architecture.html`: design report.
