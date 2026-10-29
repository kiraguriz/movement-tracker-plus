# Movement Tracker+ — agent guide

Plan of record: `docs/rebuild-brief.md` (decisions, architecture, motion engine, Muse coach, schedule).
Read the section for your task before changing code.

## Rules
- Clean room: do not copy code, names, SQL, strings or assets from the legacy CS440 repo. Never read its `.env`.
- No API keys in the app, Info.plist, xcconfig, fixtures or git. The Muse and USDA keys exist only as
  Cloudflare Worker secrets (`proxy/`).
- Dependencies need the user's approval. Approved: GRDB.swift 7.x (package), wrangler (proxy dev tool).
- Swift 6 language mode, complete concurrency checking. `MotionCore` and `Domain` import Foundation only
  and do not import each other; the app maps between them.
- `Packages/MovementKit` must build and test on macOS with `swift test`. iOS-only code goes behind
  `#if os(iOS)` or into `App/`.
- UI: SwiftUI with system components; UIKit only for the camera preview view. No redundant secondary labels
  or descriptions; let the layout explain. User-facing strings go through `App/Localizable.xcstrings`
  (en, zh-Hans). Tap targets ≥ 44 pt; VoiceOver labels on icon-only controls.
- Muse never counts reps. On-device numbers are the source of truth; Muse explains them.

## Layout
- `MovementTracker.xcodeproj` — app target `MovementTracker` and `MovementTrackerUITests`. Folders are
  synchronized groups, so adding files needs no project edits.
- `App/` — composition root (`AppEnvironment`), design system, feature screens, camera view.
- `Packages/MovementKit/` — `MotionCore`, `Domain`, `PoseCapture`, `Persistence`, `CoachKit`,
  `HealthBridge`, executable `motion-eval`.
- `proxy/` — Cloudflare Worker (TypeScript).
- `docs/` — brief and reports.

## Commands
- Package tests (macOS): `swift test --package-path Packages/MovementKit`
- App build: `xcodebuild -project MovementTracker.xcodeproj -scheme MovementTracker -destination 'generic/platform=iOS Simulator' build`
- Proxy tests: `npm test --prefix proxy`
