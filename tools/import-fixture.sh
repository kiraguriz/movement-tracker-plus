#!/usr/bin/env bash
# Labels a pose recording from the iPhone with the true counts and copies it into fixtures/real/, where
# tools/accuracy.sh picks it up.
#
#   tools/import-fixture.sh <recorded>.jsonl --reps 10 [--partials 1] [--tag person-a] [--tag room-1] [--notes "text"]
#
# Why this exists: when the app saves a recording it writes its own count into the header's labels, which is
# the number being tested. A person has to replace it with what they actually counted. This script does that,
# adds the `verified` tag that tools/accuracy.sh requires, and names the copy so that `motion-eval` can read
# the counts from the file name too:
#
#   <exercise>_<reps>_<partials>_<camera>[_<tag>...]_<8 hex digits>.jsonl
#
# Only the first line (the header) changes; the frames are copied byte for byte. The original is not touched.
#
#   --reps N       the true number of full reps (required; 0 for an idle clip)
#   --partials M   dips that should not count (default 0)
#   --tag TAG      lower-case letters, digits and hyphens; repeat for several. Conventions the accuracy
#                  report counts: person-a, person-b ... and room-1, room-2 ... (idle clips: just --reps 0)
#   --notes TEXT   free text kept in the header
#   --dest DIR     where to write (default fixtures/real)
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"

usage() {
  sed -n '2,/^set -euo/p' "$0" | sed '$d' | sed 's/^# \{0,1\}//' >&2
}

command -v python3 >/dev/null 2>&1 || { echo "error: python3 is required" >&2; exit 1; }

source_file=""
reps=""
partials="0"
notes=""
dest="$root/fixtures/real"
tags=()

while [ $# -gt 0 ]; do
  case "$1" in
    --reps) reps="${2:?--reps needs a value}"; shift 2 ;;
    --partials) partials="${2:?--partials needs a value}"; shift 2 ;;
    --tag) tags+=("${2:?--tag needs a value}"); shift 2 ;;
    --notes) notes="${2:?--notes needs a value}"; shift 2 ;;
    --dest) dest="${2:?--dest needs a value}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    -*) echo "error: unknown option $1" >&2; usage; exit 2 ;;
    *) if [ -n "$source_file" ]; then echo "error: one file at a time" >&2; exit 2; fi; source_file="$1"; shift ;;
  esac
done

[ -n "$source_file" ] || { echo "error: no file given" >&2; usage; exit 2; }
[ -n "$reps" ] || { echo "error: --reps is required: the true number of reps, counted by you" >&2; exit 2; }
[ -f "$source_file" ] || { echo "error: $source_file is not a file" >&2; exit 1; }

IMPORT_SOURCE="$source_file" IMPORT_REPS="$reps" IMPORT_PARTIALS="$partials" IMPORT_NOTES="$notes" \
IMPORT_DEST="$dest" IMPORT_TAGS="$(printf '%s\n' ${tags[@]+"${tags[@]}"})" python3 - <<'PY'
import hashlib
import json
import os
import pathlib
import re
import sys


def fail(message):
    sys.stderr.write("error: " + message + "\n")
    sys.exit(1)


source = pathlib.Path(os.environ["IMPORT_SOURCE"])
dest = pathlib.Path(os.environ["IMPORT_DEST"])

for name in ("IMPORT_REPS", "IMPORT_PARTIALS"):
    if not re.fullmatch(r"\d+", os.environ[name]):
        fail("%s must be a whole number, got '%s'" % (name.split("_")[1].lower(), os.environ[name]))
reps, partials = int(os.environ["IMPORT_REPS"]), int(os.environ["IMPORT_PARTIALS"])

tags = []
for tag in filter(None, os.environ["IMPORT_TAGS"].split("\n")):
    if not re.fullmatch(r"[a-z0-9]+(-[a-z0-9]+)*", tag):
        fail("tag '%s' must be lower-case letters, digits and hyphens" % tag)
    if tag in ("synthetic", "replay"):
        fail("the tag '%s' marks generated data and cannot be used for a real set" % tag)
    if tag not in tags:
        tags.append(tag)

data = source.read_bytes()
first, newline, rest = data.partition(b"\n")
try:
    header = json.loads(first)
except ValueError:
    fail("%s: the first line is not a JSON header" % source)
if not isinstance(header, dict) or header.get("format") != "movement-tracker.pose":
    fail("%s is not a movement-tracker.pose recording" % source)

labels = header.get("labels") or {}
existing = [t for t in labels.get("tags") or [] if t != "verified"]
if "synthetic" in existing or header.get("deviceModel") == "synthetic" or "replay" in existing:
    fail("%s is generated or replayed data, not a camera recording" % source.name)
camera = header.get("cameraPosition")
if camera not in ("front", "back"):
    fail("%s has cameraPosition '%s'; only front or back camera recordings count as real" % (source.name, camera))

merged = list(existing)
for tag in tags + ["verified"]:
    if tag not in merged:
        merged.append(tag)
labels["reps"] = reps
labels["partials"] = partials
labels["tags"] = merged
if os.environ["IMPORT_NOTES"]:
    labels["notes"] = os.environ["IMPORT_NOTES"]
header["labels"] = labels

spec = re.sub(r"[^A-Za-z0-9.\-]", "-", str(header.get("exerciseSpecID") or "unknown"))
digest = hashlib.sha1(data).hexdigest()[:8]
name_tags = [t for t in merged if t != "verified"]
name = "_".join([spec, str(reps), str(partials), camera] + name_tags + [digest]) + ".jsonl"
target = dest / name
if target.exists():
    fail("%s already exists; nothing was overwritten" % target)

dest.mkdir(parents=True, exist_ok=True)
text = json.dumps(header, sort_keys=True, separators=(",", ":"), ensure_ascii=False).encode("utf-8")
target.write_bytes(text + newline + rest)
print(target)
PY
