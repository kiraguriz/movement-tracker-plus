#!/bin/sh
# Regenerates App/Resources/ReplayPoses/*.jsonl from SyntheticMotion and checks that the motion engine counts
# exactly what each clip scripts. Run from anywhere; paths are relative to the repository root.
set -eu
root="$(cd "$(dirname "$0")/../.." && pwd)"
exec swift run --package-path "$root/tools/replay-fixtures" -c release replay-fixtures "$root/App/Resources/ReplayPoses"
