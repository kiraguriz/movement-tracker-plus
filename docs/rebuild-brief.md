# Rebuild Brief — Movement Tracker+ (native iOS · Meta hackathon)

Agent-facing working brief. Rewritten 2026-10-29 after the user chose a pure-native iOS app with Meta's
Muse models as the AI coach, for the Meta Global AI Developer Hackathon. Supersedes the earlier
Flutter plan. User-facing reports: `docs/ios-architecture.html` (this design) and
`docs/legacy-analysis.html` (analysis of the CS440 app). Status: **implementation started 2026-10-29**
(solo; repo `github.com/kiraguriz/movement-tracker-plus`, private).

## 0. Ground rules

- **Clean room.** Do not copy legacy code, names, SQL, strings, or assets (including the group logo).
  This brief records behavior, facts, and defects. Implement from it. Open legacy files only to settle a
  behavioral question, then re-derive. Legacy repo (read-only, iCloud, slow; avoid `git`/recursive
  `find`): `/Users/haitianzhu/Library/Mobile Documents/com~apple~CloudDocs/UIC/SP26/CS440/440-Group-6-Spring-2026/Implementation Project/workout_movement_tracker`
- Never read the legacy `.env`. Never put any API key in the app bundle, Info.plist, xcconfig, or git.
- New dependencies, staging, commits, and pushes need the user's explicit OK (global CLAUDE.md).
  Proposed dependencies are listed in §4.
- Items marked **[OPEN]** are the user's decision; use the default until answered.
- Verify drift-prone facts (Muse model IDs, prices, limits, hackathon rules) at the source before relying on them.

## 1. Hackathon context (verified 2026-10-29 unless marked)

- Event: Meta Global AI Developer Hackathon 2026, run by Meta Superintelligence Labs with Cerebral
  Valley. Online, 10-day build window Oct 26 → **Nov 4, 9:00 PM ET submission deadline**
  (= 8:00 PM Chicago). Judging Nov 4–8, winners Nov 9. Source: dev.meta.ai/events/global-hackathon.
- Tracks: Indie (individuals, students; "creativity, technical ambition, and whether it works") and
  Startup (teams; "technical execution and whether it holds up in production"). **[OPEN]** which track.
- Tools named: Muse Spark series, Muse Wonder, Muse Image, SAM 3.1 via Meta Model API; Meta open-weights
  models (Muse Glimmer, Muse Spark Open); Muse Code. Not stated as mandatory, but "creative use of
  Meta's AI tools" is a judging criterion.
- Secondary sources only (verify in the official rules on the participant portal): judging weights
  Impact 30% / Creative use of Meta AI tools 25% / Demo incl. video 25% / Technical depth 20%;
  $150 Model API credits per participant; "entrants must own everything in their project";
  submission = finished project + demo video.
- Consequence of the ownership rule: the CS440 code is co-owned by the group. The rebuild must be a new
  repo, written in the build window, with new assets. Keep a short log of what was built when.
- Meta Model API is a public preview for US developers (user is in Chicago).

## 2. Product

One line: an iPhone coach that watches your set through the camera, counts every rep on-device,
measures depth, tempo, and fatigue per rep, and has Muse turn those numbers into coaching, plans,
and nutrition logging.

Hero loop for the demo: frame yourself → live set with on-device counting and spoken cues → set
review (per-rep strip + Muse review that cites specific reps) → coach chat that reads your data
through tools → meal photo logged by Muse → Today screen and Apple Health updated.

Theme fit: "Build for Your World" — training alone (dorm gym, home) without a coach.

## 3. Legacy facts worth keeping (re-derive, don't copy)

### 3.1 Feature intent from the CS440 app
Onboarding (units, body, goal); goal planner (kcal, macros, aerobic/anaerobic minutes, workouts/week);
Today dashboard; workout lobby with starter templates; active workout (timers, sets, rest, exercise
search, name suggestion); camera rep tracking (squat, bench) with per-rep good/bad and a summary;
nutrition day view (kcal/macros eaten vs left, meals by slot, search, recents, servings vs grams);
health sync (weight, body fat, workouts, steps, active kcal in; weight, workouts, meals out); AI coach
cards (daily tip, workout, meal, macros, weekly goal check, post-workout feedback) and chat; settings
(units, language en/zh, theme, fitness level, AI opt-in).

### 3.2 Goal planner numbers (legacy, to improve)
- BMR: Mifflin–St Jeor `10·kg + 6.25·cm − 5·age` (+5 male, −161 female). Legacy used a Schofield-style
  formula under 19 and a made-up midpoint for "other"; rebuild: adults only (min age **[OPEN]**,
  default 16 with a warning under 18), ask which equation variant to use for "prefer not to say".
- PAL by workouts/week: 1–2 → 1.375, 3–4 → 1.55, 5–6 → 1.725, 7 → 1.9. Clamp TDEE 1400–5000.
- Legacy adjustment was %-of-TDEE by urgency (≤42 d 1.0, ≤84 d 0.7, else 0.4; gain +6–18 %, loss
  −8–18 %). Rebuild: explicit weekly rate (default lose 0.5 %/wk bodyweight, gain 0.25 %/wk, cap 1 %),
  kcal delta = rate_kg × 7700 / 7, same duration model everywhere.
- Floors 1500 (male) / 1200 (female) kcal. Protein g/kg: gain 2.0, loss 2.2, maintain 1.8 (lean mass if
  body fat 5–60 % given). Fat = max(kg × {0.9, 0.75, 0.8}, 45 g, 20 % kcal). Carbs = remainder.
  Rebuild must guarantee macros fit inside kcal and return localized rationale keys.

### 3.3 Legacy motion facts and corrections
- Legacy: ML Kit `accurate`, 720p, no fps cap; tracked squat knee angle (hip–knee–ankle) and bench elbow
  angle; per-frame side switching; median-of-5; "3 consecutive frames" debounce on wall-clock time;
  lockout 160°, descent < 130°, top ≥ 155°; reps valid 400–5000 ms; depth targets squat 80°, bench 100°.
- **Correction (2026-10-29):** the earlier analysis said the squat 80° target was stricter than
  "thighs parallel". It is the opposite. At parallel the included knee angle is ~60–70° with normal
  forward shin lean (≈110–120° knee flexion); 90° only with a vertical shin. So 80° accepts reps above
  parallel. Rebuild measures depth directly as hip height relative to knee (§6.4).
- Other legacy errors not to repeat: knee-cave check and elbow-flare check in a side view (wrong plane);
  torso-lean flag at the bottom of the squat (normal there); 5 s max rep (rejects pauses); 5 s
  auto-finish; per-rep data discarded; pose tables never written.

### 3.4 Legacy defects not to repeat (all platforms)
Keys in the bundle; schema mismatch drops all tables; unsalted SHA-256 passwords; non-transactional
multi-step writes; nothing persisted until "End"; two sources of truth for weight; god views; business
rules in SQL; swallowed errors; stale cross-screen state; hardcoded strings; no accessibility labels;
sub-44 pt targets; tests ignored by `.gitignore`.

## 4. Decisions

Decided by the user: native iOS only; Muse for the AI coach; report-only this round.

Decided in this brief (change only with a reason):
- **UI: SwiftUI-first.** UIKit only for the camera island: one `UIView` hosting
  `AVCaptureVideoPreviewLayer` plus a `CAShapeLayer` skeleton overlay, wrapped once in
  `UIViewRepresentable`. Reason: the overlay must use the preview layer's own coordinate conversion and
  redraw at frame rate without SwiftUI diffing; everything else (navigation, forms, Charts, sheets,
  Live Activities, App Intents) is faster and more current in SwiftUI.
- **Pose estimation: adopt Apple Vision 2D** (`DetectHumanBodyPoseRequest`, iOS 18+ Swift API, 19 joints,
  on-device, no dependency). Do not train a pose model. Day-0 benchmark gate on the user's iPhone.
- **Counting and form: write our own engine (MotionCore)**, adapting newer ideas (salient poses from
  PoseRAC, exemplar-based counting from ESCounts, velocity-based fatigue). Muse never counts reps.
- **Not used:** ARKit body tracking (rear camera only, owns the session, an open iOS 26 bug report on
  `ARBodyAnchor`), YOLO26-pose (AGPL-3.0 or paid licence; ownership rule), end-to-end learned counters
  (no verified on-device code; heavy), QuickPose (commercial), Sapiens2 / SAM 3D Body in the live loop
  (server GPU only).
- **Persistence: GRDB 7.x** (MIT). Explicit migrations, SQL aggregates for nutrition, Sendable value
  records, in-memory DB tests. SwiftData rejected for this app: non-Sendable `ModelContext`, opaque
  Codable attributes, weaker aggregate queries, migration surprises.
- **Swift 6 language mode, strict concurrency complete.** Xcode 27.1 / Swift 6.4 are installed.
- **Backend: a thin proxy** (default Cloudflare Workers, TypeScript) holding `MODEL_API_KEY` and the USDA
  key. Meta's own docs say keys must not ship in mobile code.

Answered by the user 2026-10-29:
1. Track: **Indie** (solo).
2. Test devices: **iPhone 17 Pro Max and iPhone Duo, both iOS 27.2** → deployment target **iOS 27.0**.
   iPhone Duo is the foldable (7.6" inner / 5.4" outer display, resizable scene, Center Stage front
   camera): layouts must adapt to both displays; disable Center Stage on every front camera.
   Simulator runtime installed: iOS 27.0 only.
3. Dependencies: **GRDB approved**. MediaPipe Tasks Vision via SPM only if the Vision gate fails (ask again).
4. Proxy host: **Cloudflare Workers** (user has an account).
7. Muse: Model API key exists; hackathon credits **not yet landed** (10/29). Deploying the Worker and
   setting its secrets is the user's step (`wrangler login`, `wrangler secret put`).

Still defaults: 5. demo exercises bodyweight squat + push-up; 6. only skeleton renders go to Muse;
8. English UI with zh-Hans.

Implementation changes to §5 (2026-10-29): SwiftUI features and the design system live in the app
target, not in package targets — the package must run `swift test` on macOS, and SwiftUI strings in
packages would need `bundle: .module` everywhere. `Domain` and `MotionCore` do not import each other;
the app maps `RepRecord` to the Domain rep type.

## 5. Architecture

### 5.1 Repository layout
```
Workout_movement_tracker+/
  MovementTracker.xcodeproj          app target "MovementTracker" (composition root only)
  App/                               @main, AppEnvironment, RootView, Info.plist, entitlements, Assets, Localizable.xcstrings
  Packages/MovementKit/              one local SwiftPM package, many targets
    Sources/
      Domain/            pure Swift: entities, value types (Mass, Energy, Nutrients, LocalDay), GoalPlanner,
                         WorkoutSession reducer, ports (protocols) for every adapter
      MotionCore/        pure Swift, no Vision/AVFoundation: PoseFrame, filters, features, RepSegmenter,
                         signal sources, ExerciseSpec (Codable), RuleEngine, scoring, ExemplarTemplate
      PoseCapture/       AVFoundation + Vision: CameraPipeline, VisionPoseEstimator, ReplayPoseSource,
                         PoseRecorder (JSONL), FramingCheck, keyframe ring buffer, skeleton renderer
      Persistence/       GRDB: AppDatabase, migrations, records, repositories (implement Domain ports)
      HealthBridge/      HealthKit adapter (workouts, dietary samples, body mass, steps)
      CoachKit/          Muse client via proxy: request builders, JSON schemas, tools, tool executor,
                         SSE streaming, budget + cache, prompt templates (versioned)
      DesignSystem/      tokens, typography, components, chart styles, haptics, speech cues
      TodayFeature/ TrainFeature/ LiveSetFeature/ EatFeature/ CoachFeature/ ProfileFeature/
    Tests/
      DomainTests/ MotionCoreTests/ (Fixtures/*.jsonl) PersistenceTests/ CoachKitTests/
  proxy/                             Cloudflare Worker (TypeScript): routes in §7.2
  tools/                             fixture evaluation script, Muse smoke tests (curl via proxy)
  docs/
```

### 5.2 Dependency rules
- `Domain` and `MotionCore` import Foundation only. They build and test on macOS with `swift test`.
- Features depend on Domain, MotionCore, DesignSystem, and **ports**, never on concrete adapters.
- Adapters (PoseCapture, Persistence, HealthBridge, CoachKit) depend on Domain and implement its ports.
- The app target builds `AppEnvironment` (a struct of port-typed dependencies) and injects it with a
  custom SwiftUI `@Entry` environment value. Previews and tests use fakes. No singletons.

### 5.3 Concurrency model
- `CameraPipeline` (final class, not an actor) owns `AVCaptureSession`. Configuration runs on
  `sessionQueue`; frames arrive on `videoQueue` (`alwaysDiscardsLateVideoFrames = true`, default
  bi-planar 420). Vision runs synchronously on `videoQueue`. `CVPixelBuffer` never leaves that queue.
  Output: `AsyncStream<PoseFrame>` with `.bufferingNewest(1)`.
- `actor MotionSession` consumes `PoseFrame`s, runs MotionCore, emits `AsyncStream<MotionEvent>`.
- `@MainActor @Observable LiveSetModel` consumes events for UI state; the overlay view receives the
  latest `PoseFrame` directly (main-thread hop, ≤ 30 Hz).
- Database: GRDB `DatabasePool` (Sendable). Repositories are Sendable structs; reads exposed as
  `AsyncSequence` via `ValueObservation`. Every multi-row write is one transaction.
- `actor CoachClient` owns URLSession calls to the proxy, retries, budget, and cache.
- Follow WWDC26 camera guidance: start the session off the main thread, observe
  `systemPressureState`, consider deferred start.

### 5.4 Navigation and screens (SwiftUI, iOS 26 design)
- `TabView`: **Today · Train · Eat · Me**, plus an "Ask Coach" bar as the iOS 26 tab-view bottom
  accessory (verify modifier name `tabViewBottomAccessory`), opening the Coach sheet from anywhere.
- Train → choose exercise → **Live Set** (`fullScreenCover`, camera island) → **Set Review** sheet →
  next set / finish → **Session Summary** (Muse debrief) → saved; manual sets supported.
- Eat → day list (date strip, any past day) → add via photo (Muse) or search (USDA via proxy) →
  confirm sheet with editable grams.
- Me → profile, goal (planner), progress (Swift Charts), privacy ("what Muse sees"), settings.
- Per-tab `NavigationStack` with typed route enums; an app `Router` for deep links and App Intents.

## 6. Motion engine (MotionCore)

### 6.1 Layers
1. Pose estimation — adopted: Vision 2D, front camera by default (user can see the screen), 30 fps
   capture, Vision on every frame if the gate passes (target ≤ 20 ms/frame), else every 2nd frame.
2. Counting + assessment — ours: below.
3. Language — Muse: post-set review, debrief, plans, spec authoring. Real-time cues stay on-device.

### 6.2 Types
- `PoseFrame { t: TimeInterval (capture PTS, monotonic), joints: [Joint: Keypoint(x, y, c)] in
  upright, display-mirrored, normalized coords with y up, imageAspect }` — Sendable value.
- `MotionEvent`: `.framing(FramingState)`, `.phase(Phase)`, `.repCompleted(RepRecord)`,
  `.partialRep(RepRecord)`, `.cue(CueKey)`, `.signal(Double)` (for the live gauge).
- `RepRecord { index, tStart, tBottom, tEnd, eccMs, conMs, rom, bottomValue, conVelocity, metrics:
  [MetricKey: Double], issues: [Issue], score: Int }`.

### 6.3 Pipeline
confidence gate (single named threshold, start 0.3) → short-gap fill (≤ 150 ms linear) → One-Euro
filter per coordinate → body normalization (origin at hip center, scale by torso length) → view check
(side vs front from shoulder separation / torso length) → **side lock** (pick the more confident side
during framing; switch only after ≥ 1 s of clearly better confidence) → signal source (§6.4) →
**RepSegmenter** (§6.5) → per-rep metrics and **RuleEngine** (§6.6) → events.

### 6.4 Signal sources (one segmenter, several signals)
- `jointAngle(a, b, c)` — included angle at b, side-locked.
- `relativeHeight(of, to, scale)` — e.g. squat: `(hip.y − knee.y) / thighLength`. ≈ +1 standing,
  **0 at parallel**, < 0 below parallel. Depth rule becomes "bottom ≤ 0.10".
- `exemplar(top, bottom)` — teach mode: distance to two salient poses learned from the user's own
  2–3 demo reps (PoseRAC's salient-pose idea, made training-free and exemplar-based like ESCounts):
  `s = d(bottom) / (d(top) + d(bottom))`.
- `principalComponent` (stretch) — online PCA of the normalized pose vector for unknown exercises.
- MVP specs: squat (side view) uses `relativeHeight`; push-up (side view) uses `jointAngle(shoulder,
  elbow, wrist)` with a body-line rule.

### 6.5 RepSegmenter (adaptive hysteresis, time-based)
- Calibrate from the first full cycle: `top`, `bottom` estimates; thresholds at 70 % / 30 % of the range
  (relative to top); update both with EMA after each counted rep (handles fatigue and depth drift).
- States `top → descending → bottom → ascending → top`. Transitions need the signal past the threshold for
  ≥ `dwellMs` (default 80–120 ms) measured on frame timestamps, never frame counts.
- Valid rep: ROM ≥ `minRom`; duration within `[minPeriodMs 600, maxPeriodMs 12 000]` (allows pauses).
  A dip that never reaches the bottom threshold → `partialRep` (shown, not counted).
- Velocity: mean concentric velocity of the signal (units/s, scale-free). Set-level **velocity loss**
  `1 − v_rep / max(v_first two reps)` as a fatigue proxy (VBT literature; phrase as an estimate).
- No auto-finish. Idle ≥ 20 s shows a prompt; the user ends the set.

### 6.6 ExerciseSpec (data) and RuleEngine
Bundled JSON per exercise, versioned, Codable, validated on load:
```json
{ "id": "squat.bodyweight", "version": 1, "view": "side",
  "signal": { "kind": "relativeHeight", "of": "hip", "to": "knee", "scale": "thigh" },
  "rep": { "minRom": 0.45, "dwellMs": 100, "minPeriodMs": 600, "maxPeriodMs": 12000 },
  "metrics": ["bottomValue", "eccMs", "conMs", "maxTorsoLeanDeg@descent", "conVelocity"],
  "rules": [
    { "id": "depth", "metric": "bottomValue", "op": "<=", "value": 0.10, "severity": "major", "cue": "cue.squat.deeper" },
    { "id": "chest", "metric": "maxTorsoLeanDeg@descent", "op": "<=", "value": 50, "severity": "minor", "cue": "cue.squat.chestUp" },
    { "id": "tempo", "metric": "eccMs", "op": ">=", "value": 700, "severity": "minor", "cue": "cue.controlDown" } ],
  "score": { "depth": 0.5, "chest": 0.25, "tempo": 0.25 } }
```
Values are starting points; tune them with fixtures. Push-up rules: bottom elbow angle ≤ 100°,
body line (shoulder–hip–ankle angle) ≥ 160°, lockout ≥ 155°. Score = 100 − weighted penalties;
"good" = score ≥ 70 and no major issue. One spoken cue per rep at most, highest severity first,
rate-limited (AVSpeechSynthesizer + haptic).

### 6.7 Framing check (before counting starts)
All spec joints confident for 1 s; subject ≥ 1/3 of frame height (Apple's guidance); correct view
(side for MVP specs); prompts: "step back", "turn sideways", "whole body in frame". Disable Center
Stage on iPhone 17-family front cameras.

### 6.8 Validation (this is a judging asset)
- `PoseRecorder` writes JSONL fixtures on device (opt-in debug toggle) with labels: exercise, true rep
  count, partial reps, notes. Target by Nov 2: ≥ 10 squat sets, ≥ 10 push-up sets, idle/noise clips,
  two people, two rooms, front and back camera.
- `ReplayPoseSource` replays fixtures in real time for Simulator UI work, UI tests, and demo backup.
- `swift test` runs every fixture: exact count expected; report MAE and off-by-one accuracy; false
  reps on idle clips must be 0. `tools/eval` prints a table for the README and the video.
- Day-0 gate: Vision latency p50/p95 per frame on the test iPhone, joint stability while still. If it
  fails, switch the `PoseEstimator` adapter to MediaPipe Pose Landmarker (SPM, 33 landmarks + world
  landmarks; needs dependency approval; check its model licence).

### 6.9 Later (not hackathon)
Create ML Action Classifier for auto exercise recognition (≥ 50 clips per class + negative class);
Vision 3D (`DetectHumanBodyPose3DRequest`) on bottom frames for view-invariant checks; Muse-authored
specs for taught exercises (§7.4); SAM 3.1 replay clips.

## 7. Coach (CoachKit + proxy)

### 7.1 Meta Model API facts (dev.meta.ai/docs, read 2026-10-29)
- Base `https://api.meta.ai/v1`; Bearer key (prefix `LLM_`, team-scoped, rate limits per team).
  OpenAI-compatible Responses (`POST /v1/responses`, recommended) and Chat Completions; Anthropic-style
  Messages also accepted. Use a `developer` message for standing instructions.
- Models: `muse-spark-1.3` (recommended; text/image/video/PDF in; audio "not fully supported"),
  `muse-spark-1.2` (use for audio understanding), `muse-spark-1.1`, `muse-wonder-1.0` (preview,
  $4/$20 per M), `*-contributor` variants (cheap, 150 RPM, **data used to improve Meta products —
  never for user data**), `muse-image-1.0`, `muse-voice-transcribe-1.0`, `sam-3.1`. Context 1,048,576.
- Pricing `muse-spark-1.3`: $1.25 / M input, $0.15 cached, $4.25 / M output; reasoning tokens billed as
  output. Limits: 3,000 RPM, 4 M TPM; 429 with `Retry-After`; backoff from 500 ms, doubling, jitter.
- Reasoning: Responses `reasoning.effort` = minimal | low | medium | high | xhigh | max (`max` on 1.3
  standard only); `none` returns 400. Reasoning shares the output budget: set `max_output_tokens`
  ≥ 4000 or answers can come back empty.
- Structured output: Responses `text.format` (`type: json_schema`, `strict` default false). Strict
  subset: root object, `additionalProperties: false`, every property required, no `allOf`/`oneOf`,
  `anyOf` only below root, no recursion, depth ≤ 10.
- Tools: Responses function tools `{type: "function", name, description, parameters}`;
  `tool_choice` only `"auto"`; `parallel_tool_calls` default true; return `function_call_output` with
  `call_id` (+ `previous_response_id`, or keep all calls in the same request). Built-in
  `{"type": "web_search"}` exists. Validate tool arguments ourselves.
- Images: `input_image` with `image_url` (data URL ok) in user messages only; ≤ 50 per request;
  ~1.3–1.5k tokens for a ~1280 px image. Video: `input_video` (`video_url` data URL or `file_id`),
  mp4. Files: `POST /v1/files` (`purpose: user_data`).
- Voice: `POST /v1/asr/transcribe` multipart (`request` + `audio`), WAV mono 16-bit 16/24 kHz,
  ≤ 10 min, ≤ 32 MB; realtime `wss://api.meta.ai/v1/asr/realtime` authenticates in the first JSON frame
  (key in `authorization.accessToken`), so it also needs the proxy. Mandarin supported. $0.18/hour.
- SAM 3.1: Responses API with a noun-phrase prompt plus image or mp4/mov; boxes + masks, tracks across
  frames; $2.50 / 1k images, $0.20 / 1k frames (50-frame minimum).
- Open weights: Muse Glimmer (30B dense, Apache-2.0, text+image) and Muse Spark Open (816B MoE) —
  neither fits on a phone.

### 7.2 Proxy (Cloudflare Worker)
- `POST /v1/install` → issues a random install token (rate-limited by IP); app stores it in Keychain.
- `POST /v1/coach/responses` → forwards to `/v1/responses`. Allowlist models (`muse-spark-1.3`,
  `muse-spark-1.2`), clamp `reasoning.effort` and `max_output_tokens` per feature, cap body size, pass
  SSE through, never log bodies, per-token daily budget (KV / Durable Object), global kill switch.
- `POST /v1/voice/transcribe` → multipart passthrough to `/v1/asr/transcribe` (≤ 60 s).
- `GET /v1/food/search?q=` → USDA FoodData Central with the server key; normalized per-100 g nutrients
  (missing ≠ 0); edge-cached.
- Post-hackathon: App Attest instead of install tokens.

### 7.3 Features (priority order; hackathon cut lines in §11)
1. **Set review** (`muse-spark-1.3`, effort `low`, strict schema `SetReview`). Input: exercise + spec
   version, per-rep metrics and issues, set summary (reps, partials, avg score, velocity loss), user
   level and goal, last comparable set, optional voice note; images: skeleton renders of the best and
   worst rep bottoms (face-blurred photo frames only with opt-in). Output:
   `{headline, wentWell[], fixNext[{cue, why, repRefs[]}] (≤ 2), nextSet{reps, loadChangePct,
   restSec, tempo}, safetyFlag, confidence}`. Show on-device metrics instantly; stream Muse text in;
   speak `headline`.
2. **Session debrief** at finish (effort `medium`): compares sets, suggests the next session.
3. **Coach chat with on-device tools** (effort `medium`). Tools run locally against GRDB and return
   summaries only: `get_sessions(days)`, `get_set_detail(set_id)`, `get_nutrition(day)`,
   `get_body_trend(days)`, `get_goal()`. Write tools return proposals the user must confirm:
   `propose_plan(plan)`, `propose_meal_log(items)`, `propose_goal_change(change)`. The UI shows which
   tools ran ("Coach looked at: 3 sessions"). History trimmed to a token budget; failed sends stay
   retryable.
4. **Meal photo** (effort `low`, schema `MealEstimate {items[{name, gramsEstimate, confidence,
   usdaQuery}], notes}`) → USDA lookup via proxy → editable confirm sheet → save + HealthKit.
5. **Voice note** after a set (Muse Voice Transcribe via proxy) → added to the review context. Stretch.
6. **Spec authoring** for taught exercises: Muse drafts an `ExerciseSpec` (strict schema) from the
   exercise name + salient-pose skeleton renders; the engine accepts it only if it recounts the
   demonstration reps correctly. Stretch.
7. **SAM 3.1 replay** of the worst rep with the body segmented. Post-hackathon.

### 7.4 Prompting, caching, privacy, cost
- Prompts are versioned Swift templates; every stored insight keeps `model`, `promptVersion`,
  `inputHash`, token usage. Cache by `(kind, inputHash)`; daily budget per kind.
- Decode with Codable; on schema failure retry once with the error; then fall back to an on-device
  templated review from the rule engine (demo never shows an empty card).
- Privacy: consent screen listing exactly what leaves the phone; standard tier only; send aggregates and
  skeleton renders by default; no names, no device IDs; a "What Muse saw" view per insight.
- Cost estimate per set review: ~5k input (2 skeleton images ≈ 3k of it) + ~1.5k output incl. reasoning ≈ $0.013. $150 per participant covers >10k reviews.

## 8. Data model (GRDB, migration v1)

- `profile(id, display_name, birth_year, sex, height_cm, unit_system, activity_level, created_at, updated_at)`
- `goal(id, kind, start_day, end_day?, target_weight_kg?, weekly_rate_kg, kcal, protein_g, carbs_g, fat_g,
  workouts_per_week, planner_version, is_active, created_at)` — partial unique index on active.
- `body_measurement(id, kind weight|body_fat, value, measured_at, local_day, tz, source app|health, hk_uuid?)`
- `exercise(id slug, name, category, primary_muscles json, equipment, spec_id?)`
- `exercise_spec(id, exercise_id, version, origin builtin|taught|muse, json, created_at)`
- `workout_session(id, status draft|completed|discarded, title?, started_at, ended_at?, tz, local_day, hk_workout_uuid?)`
- `exercise_entry(id, session_id → cascade, exercise_id, position)` unique(session_id, position)
- `set_entry(id, entry_id → cascade, position, reps?, partial_reps, load_kg?, started_at?, ended_at?,
  rest_s?, tracking manual|camera, avg_score?, velocity_loss?)`
- `rep_record(id, set_id → cascade, idx, t_start, t_bottom, t_end, ecc_ms, con_ms, rom, bottom_value,
  con_velocity, score, issues json, metrics json)`
- `pose_capture(set_id PK → cascade, file_name, frames, fps, spec_version)` — opt-in JSONL on disk.
- `food(id, source usda|custom|muse, external_id?, name, brand?, kcal_100g?, protein_100g?, carbs_100g?,
  fat_100g?, servings json, created_at)`
- `meal_entry(id, local_day, slot, food_id?, label, grams, kcal, protein_g, carbs_g, fat_g,
  source search|photo|manual, photo_file?, logged_at, tz, hk_uuid?)`
- `coach_insight(id, kind, subject_id?, input_hash, model, prompt_version, payload json, input_tokens,
  output_tokens, created_at)`
- `chat_thread(id, title, created_at, updated_at)`; `chat_message(id, thread_id → cascade, role, content,
  tool_calls json?, status sent|pending|failed, created_at)`
- `health_export(entity, entity_id, sync_identifier, sync_version, hk_uuid?, status, attempts, last_error, updated_at)`
- `setting(key, value json)`
Ids are UUIDv7 strings. Times are UTC + IANA zone; `local_day` computed at write time and indexed.
Draft sessions are written after every set event, so a crash loses nothing.

## 9. Health (HealthKit)

- MVP writes: `HKWorkout` for each finished session via `HKWorkoutBuilder` (strength training type,
  MET-based energy marked as an estimate); dietary energy + macros per meal entry (optionally grouped
  in a food `HKCorrelation`). Every sample carries `HKMetadataKeySyncIdentifier` = our id and
  `HKMetadataKeySyncVersion` = revision, so re-saves update instead of duplicating.
- MVP reads: latest body mass, today's steps (statistics query).
- Later: `HKWorkoutSession` on iPhone (iOS 26+) with a Live Activity; anchored queries + background
  delivery for body mass; Apple Watch heart rate.
- HealthKit needs a real device and the HealthKit capability on the signing team.

## 10. Testing

Swift Testing everywhere. `swift test` on macOS for Domain and MotionCore (fixtures, planner tables,
segmenter edge cases: pauses, partials, idle, side switch). GRDB repositories on in-memory databases,
migration test from v1 on. CoachKit: golden request JSON per feature, schema decode tests, tool
executor tests with fakes, proxy contract test. One XCUITest smoke flow using `ReplayPoseSource`
(launch argument). Instruments pass on device for the live set (frame time, main-thread time).

## 11. Hackathon plan (Chicago time; submit by 8 PM CT Nov 4)

| Day | Build | Exit check |
|---|---|---|
| D0 Thu 10/29 | Decisions; repo; Xcode project; package skeleton; GRDB; proxy hello-world calling Muse; camera + Vision spike with on-screen latency | Muse reply through proxy; Vision gate measured |
| D1 Fri 10/30 | PoseCapture, overlay, framing check, PoseRecorder; record fixtures; RepSegmenter + squat/push-up specs; replay tests | Fixture counts exact on recorded sets |
| D2 Sat 10/31 | Metrics, rules, scoring, velocity loss; Live Set UI (counter, gauge, cues, haptics, voice); persistence of sessions/sets/reps; manual sets | Full set saved; crash-safe draft |
| D3 Sun 11/1 | Proxy hardened (tokens, budget, SSE); CoachKit; Set Review with skeleton keyframes; session debrief; consent screen | Review cites specific reps in < 8 s |
| D4 Mon 11/2 | Coach chat with tools; Eat photo → Muse → USDA → confirm; Today screen; minimal onboarding + planner | Chat answers from tool data; meal logged |
| D5 Tue 11/3 | HealthKit writes; accuracy report; polish; bug bash; stretch (voice note or teach mode); demo script dry run | Feature freeze 10 PM |
| D6 Wed 11/4 | Record + edit ≤ 3 min video; README with architecture and accuracy table; submit | Submitted before 7 PM CT |

Cut order when late: spec authoring → teach mode → voice note → HealthKit → chat write-tools →
meal photo (keep search). Never cut: live counting, set review, the replay-based accuracy table.

Demo script (≤ 3 min): hook (training alone) → framing check → live squat set with a spoken cue and a
flagged partial → set review citing reps and velocity loss → coach chat with visible tool chips and a
proposed plan → meal photo → Today + Health app → architecture + accuracy table → close.

## 12. After the hackathon
Progress charts, workout templates, exercise aliases, imports from Health with anchored queries,
Live Activities and App Intents ("Start a squat set"), Apple Watch, Create ML exercise recognition,
Vision 3D checks, SAM 3.1 replay, App Attest, iCloud sync via CKSyncEngine if multi-device is needed,
App Store privacy labels.

## 13. Risks
Muse access/credits unconfirmed (check D0); Vision accuracy/latency unmeasured (D0 gate, MediaPipe
fallback); only one test iPhone and no camera in Simulator (ReplayPoseSource); 6-day schedule (cut
order above); hackathon rules on ownership and prior work only seen in secondary sources (read the
official rules); health data leaving the device (consent, minimization, standard tier); HealthKit
signing on the user's developer account.
