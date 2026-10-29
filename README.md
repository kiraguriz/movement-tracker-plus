# Movement Tracker+

An iPhone coach that watches your set through the camera, counts every rep on-device, measures depth,
tempo and fatigue per rep, and uses Meta Muse to turn those numbers into coaching.

Built solo for the Meta Global AI Developer Hackathon 2026 (Indie track) during the Oct 26 – Nov 4, 2026
build window. It is a from-scratch native rewrite of a CS440 class project; no code or assets carried over.

## Layout
- `App/` — SwiftUI app: composition root, screens, camera view
- `Packages/MovementKit/` — Swift package: `MotionCore` (rep counting and form rules), `Domain`,
  `PoseCapture` (Apple Vision), `Persistence` (GRDB), `CoachKit` (Muse), `HealthBridge`
- `proxy/` — Cloudflare Worker that holds the Muse and USDA keys
- `docs/` — design brief and reports

## Build and test
- Requires Xcode 27.1+, iOS 27.0+.
- `swift test --package-path Packages/MovementKit`
- `xcodebuild -project MovementTracker.xcodeproj -scheme MovementTracker -destination 'generic/platform=iOS Simulator' build`
- `npm test --prefix proxy`
