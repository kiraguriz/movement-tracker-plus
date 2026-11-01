#!/usr/bin/env bash
# Repository delivery checks. Builds use generic SDK destinations and never boot a simulator.
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$root"
swift test --package-path Packages/MovementKit
python3 -m unittest discover -s tools/tests -v
npm test --prefix proxy
npm run build --prefix proxy
build_dir="${MOVEMENT_DERIVED_DATA:-${TMPDIR:-/tmp}/movement-tracker-check}"
for config in Debug Release; do
  xcodebuild -project MovementTracker.xcodeproj -scheme MovementTracker \
    -configuration "$config" -destination 'generic/platform=iOS Simulator' \
    -derivedDataPath "$build_dir" -jobs 4 CODE_SIGNING_ALLOWED=NO build
done
xcodebuild -project MovementTracker.xcodeproj -scheme MovementTracker \
  -configuration Release -destination 'generic/platform=iOS' \
  -derivedDataPath "$build_dir" -jobs 4 CODE_SIGNING_ALLOWED=NO build
git diff --check
