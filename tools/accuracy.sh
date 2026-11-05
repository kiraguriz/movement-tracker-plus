#!/usr/bin/env bash
# Regenerates docs/accuracy.md, and the summary table between the accuracy markers in README.md, from
# `motion-eval`. Every number in both comes from motion-eval's output; nothing is typed by hand.
#
#   tools/accuracy.sh
#
# Inputs, in this order of trust:
#   1. Real sets: fixtures/real/*.jsonl recorded on the iPhone, labelled with tools/import-fixture.sh. A file
#      counts only if it is a camera recording (front or back), is not tagged synthetic or replay, and carries
#      the `verified` tag, which import-fixture.sh adds when a person gives the true counts. Anything else in
#      that folder is listed as skipped, with the reason. Videos (.mov, .mp4, .m4v) in the same folder are run
#      through Vision on this Mac and labelled by file name (see `motion-eval --help`).
#   2. The synthetic benchmark built into motion-eval (`motion-eval --synthetic`).
#   3. The bundled replay clips in App/Resources/ReplayPoses (generated, not recorded).
#
# Environment overrides (used to test the script; normally unset):
#   REAL_FIXTURES=<dir>   where the real sets live (default fixtures/real)
#   ACCURACY_MD=<file>    where the report goes (default docs/accuracy.md)
#   ACCURACY_README=<file>  the README to update; empty skips it (default README.md)
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$root"

command -v python3 >/dev/null 2>&1 || { echo "error: python3 is required" >&2; exit 1; }

package="$root/Packages/MovementKit"
build_log="$(mktemp)"
trap 'rm -f "$build_log"' EXIT
echo "building motion-eval (release)..." >&2
if ! swift build --package-path "$package" -c release --product motion-eval >"$build_log" 2>&1; then
  cat "$build_log" >&2
  echo "error: motion-eval did not build" >&2
  exit 1
fi
bin="$(swift build --package-path "$package" -c release --show-bin-path)/motion-eval"

# The commit named in the report is the last one that changed anything the numbers depend on (the engine and
# its tool, the bundled clips, the real sets), not HEAD, so a documentation-only commit does not make it stale.
inputs=(Packages/MovementKit App/Resources/ReplayPoses 'fixtures/real/*.jsonl')
commit="$(git log -1 --format=%h -- "${inputs[@]}" 2>/dev/null || true)"
commit="${commit:-unknown}"
if [ -n "$(git status --porcelain -- "${inputs[@]}" 2>/dev/null)" ]; then
  commit="$commit plus uncommitted changes"
fi

MT_ROOT="$root" MT_BIN="$bin" MT_COMMIT="$commit" python3 - <<'PY'
import datetime
import json
import os
import pathlib
import re
import subprocess
import sys

root = pathlib.Path(os.environ["MT_ROOT"])
binary = os.environ["MT_BIN"]
commit = os.environ["MT_COMMIT"]
real_dir = pathlib.Path(os.environ.get("REAL_FIXTURES") or root / "fixtures" / "real")
md_path = pathlib.Path(os.environ.get("ACCURACY_MD") or root / "docs" / "accuracy.md")
readme_value = os.environ.get("ACCURACY_README", str(root / "README.md"))
readme_path = pathlib.Path(readme_value) if readme_value else None

VIDEO_SUFFIXES = {".mov", ".mp4", ".m4v"}
BEGIN, END = "<!-- accuracy:begin -->", "<!-- accuracy:end -->"


def fail(message):
    sys.stderr.write("error: " + message + "\n")
    sys.exit(1)


def show(path):
    """A path as the report should print it: relative to the repository when it is inside it."""
    try:
        return str(pathlib.Path(path).resolve().relative_to(root.resolve()))
    except ValueError:
        return str(path)


def run_eval(args, what):
    proc = subprocess.run([binary, *args], capture_output=True, text=True)
    if proc.returncode != 0:
        sys.stderr.write(proc.stderr)
        fail("motion-eval failed for %s (exit %d)" % (what, proc.returncode))
    return proc.stdout


def pick(pattern, text, what, required=True):
    match = re.search(pattern, text, re.M)
    if not match:
        if required:
            fail("motion-eval's output changed: no %s line. Update tools/accuracy.sh." % what)
        return None
    return match.group(1).strip()


def parse(output):
    """Splits motion-eval's Markdown into the table rows, the report text and the summary figures."""
    lines = [line for line in output.splitlines() if not line.startswith("## ")]
    text = "\n".join(lines).strip()
    rows = []
    table = [line for line in lines if line.startswith("|")]
    for line in table[2:]:
        rows.append([cell.strip() for cell in line.strip()[1:-1].split(" | ")])
    summary = {
        "clips": pick(r"\*\*Summary\*\* — (\d+) clip", text, "summary"),
        "exact": pick(r"^- Exact count: (.+)$", text, "exact count"),
        "within": pick(r"^- Off-by-one accuracy \(within ±1 rep\): (.+)$", text, "off-by-one"),
        "mae": pick(r"^- Mean absolute error: (.+)$", text, "mean absolute error"),
        "idle": pick(r"^- False reps on idle clips: (.+)$", text, "idle clips"),
        "partials": pick(r"^- Partial reps exact: (.+)$", text, "partial reps", required=False) or "–",
    }
    return {"text": text, "rows": rows, "summary": summary}


# Check the README first, so a missing marker block stops the run before anything is written.
if readme_path is not None:
    readme_text = readme_path.read_text(encoding="utf-8")
    if BEGIN not in readme_text or END not in readme_text:
        fail("%s has no %s ... %s block to update" % (show(readme_path), BEGIN, END))

# --- Inputs -------------------------------------------------------------------------------------------

synthetic = parse(run_eval(["--synthetic"], "the synthetic benchmark"))

replay_dir = root / "App" / "Resources" / "ReplayPoses"
if not any(replay_dir.glob("*.jsonl")):
    fail("no bundled replay clips in %s" % show(replay_dir))
replay = parse(run_eval([str(replay_dir)], "the bundled replay clips"))

verified, skipped = [], []
if real_dir.is_dir():
    for path in sorted(real_dir.rglob("*.jsonl")):
        if any(part.startswith(".") for part in path.relative_to(real_dir).parts):
            continue
        try:
            with open(path, "rb") as handle:
                header = json.loads(handle.readline())
        except (OSError, ValueError):
            skipped.append((path, "the first line is not a JSON header"))
            continue
        if not isinstance(header, dict) or header.get("format") != "movement-tracker.pose":
            skipped.append((path, "not a movement-tracker.pose file"))
            continue
        labels = header.get("labels") or {}
        tags = labels.get("tags") or []
        if header.get("deviceModel") == "synthetic" or "synthetic" in tags:
            reason = "synthetic data does not belong in the real set"
        elif "replay" in tags or header.get("cameraPosition") not in ("front", "back"):
            reason = "not recorded by a camera (replay or generated)"
        elif "verified" not in tags:
            reason = "labels not verified: run tools/import-fixture.sh with the true counts"
        elif not isinstance(labels.get("reps"), int):
            reason = "no rep count in the labels"
        else:
            verified.append((path, header))
            continue
        skipped.append((path, reason))

videos = []
if real_dir.is_dir():
    for path in sorted(real_dir.rglob("*")):
        relative = path.relative_to(real_dir)
        if path.is_file() and path.suffix.lower() in VIDEO_SUFFIXES and not any(p.startswith(".") for p in relative.parts):
            videos.append(path)

real = parse(run_eval([str(p) for p, _ in verified], "the real recordings")) if verified else None
real_videos = parse(run_eval([str(p) for p in videos], "the real videos")) if videos else None

# --- Summary table ------------------------------------------------------------------------------------

SUMMARY_HEAD = ["Data", "Clips", "Exact count", "Within ±1 rep", "Mean abs. error", "False reps on idle clips", "Partial reps exact"]


def summary_row(name, result):
    s = result["summary"]
    return [name, s["clips"], s["exact"], s["within"], s["mae"], s["idle"], s["partials"]]


rows = []
if real:
    rows.append(summary_row("Real sets recorded on iPhone", real))
else:
    rows.append(["Real sets recorded on iPhone", "none yet", "–", "–", "–", "–", "–"])
if real_videos:
    rows.append(summary_row("Real videos, Vision on a Mac", real_videos))
rows.append(summary_row("Synthetic benchmark (generated motion)", synthetic))
rows.append(summary_row("Bundled replay clips (generated motion)", replay))


def markdown_table(head, body):
    def line(cells):
        return "| " + " | ".join(cells) + " |"
    return "\n".join([line(head), line(["---"] * len(head))] + [line(r) for r in body])


summary_table = markdown_table(SUMMARY_HEAD, rows)
if real:
    status = (
        "The first row is real sets recorded on an iPhone, with the true counts given by a person. "
        "Rows marked generated motion are scripted, not people, and the engine was tuned against that generator, "
        "so they are a regression check, not a measure of accuracy on people."
    )
else:
    status = (
        "No real recordings are counted yet. Every number here comes from generated motion, not people, and the "
        "engine was tuned against that generator, so these rows are a regression check, not a measure of accuracy "
        "on people."
    )

# --- Report -------------------------------------------------------------------------------------------

out = []
out.append("# Accuracy of the rep counter")
out.append("")
out.append(
    "Generated by `tools/accuracy.sh` from `motion-eval` at commit `%s` on %s. Do not edit by hand: rerun the script."
    % (commit, datetime.date.today().isoformat())
)
out.append("")
out.append("## Summary")
out.append("")
out.append(summary_table)
out.append("")
out.append(status)
out.append("")
if not real:
    out.append(
        "Generated motion shows that the engine handles the cases its generator can produce. It says nothing yet about "
        "how well the engine counts a real person on an iPhone. The next section says how real sets get in."
    )
    out.append("")
out.append("How the columns are computed (`EvalReport.swift`):")
out.append("")
out.append("- Exact count: clips whose counted reps equal the labelled reps.")
out.append("- Within ±1 rep: clips whose counted reps differ from the label by at most one.")
out.append("- Mean abs. error: the mean of |counted − labelled| over the labelled clips, in reps.")
out.append("- False reps on idle clips: reps counted in clips labelled 0 reps (standing, walking away, holding a plank). It must be 0.")
out.append("- Partial reps exact: clips whose counted partial reps (dips shown but not counted) equal the labelled number, among clips that have a partial label.")
out.append("")

# Real sets
out.append("## Real recordings")
out.append("")
if real:
    def count(predicate):
        return sum(1 for _, h in verified if predicate(h))

    def tag_values(prefix):
        values = set()
        for _, h in verified:
            for t in (h.get("labels") or {}).get("tags") or []:
                if t.startswith(prefix):
                    values.add(t)
        return values

    squat = count(lambda h: (h.get("exerciseSpecID") or "").startswith("squat") and (h["labels"].get("reps") or 0) > 0)
    pushup = count(lambda h: (h.get("exerciseSpecID") or "").startswith("pushup") and (h["labels"].get("reps") or 0) > 0)
    idle = count(lambda h: h["labels"].get("reps") == 0)
    out.append("Verified sets recorded on an iPhone, counted by `motion-eval` with `fixtures/real` as its input. Coverage against the targets in the brief (§6.8):")
    out.append("")
    out.append(
        markdown_table(
            ["Coverage", "Sets", "Target"],
            [
                ["Squat sets", str(squat), "at least 10"],
                ["Push-up sets", str(pushup), "at least 10"],
                ["Idle or noise clips", str(idle), "some (no number in the brief)"],
                ["People (tags `person-*`)", str(len(tag_values("person-"))), "2"],
                ["Rooms (tags `room-*`)", str(len(tag_values("room-"))), "2"],
                ["Front camera", str(count(lambda h: h.get("cameraPosition") == "front")), "front and back"],
                ["Back camera", str(count(lambda h: h.get("cameraPosition") == "back")), "front and back"],
            ],
        )
    )
    out.append("")
    out.append(real["text"])
    out.append("")
else:
    out.append("> **No real recordings yet.** This section is filled in by `tools/accuracy.sh` once `fixtures/real/` holds labelled sets recorded on an iPhone. The targets are in `docs/device-checklist.md` (section 3).")
    out.append("")
    out.append("To add one: record it on the device, copy the `.jsonl` file to the Mac, and label it with the true counts:")
    out.append("")
    out.append("```sh")
    out.append("tools/import-fixture.sh <recorded>.jsonl --reps 10 --partials 1 --tag person-a --tag room-1")
    out.append("tools/accuracy.sh")
    out.append("```")
    out.append("")
    out.append("The full recording procedure is in `docs/device-checklist.md`.")
    out.append("")
if skipped:
    out.append("Skipped files in `%s` (not counted):" % show(real_dir))
    out.append("")
    for path, reason in skipped:
        out.append("- `%s`: %s" % (path.name, reason))
        sys.stderr.write("warning: skipped %s: %s\n" % (show(path), reason))
    out.append("")
if real_videos:
    out.append("### Real videos")
    out.append("")
    out.append("Videos in `%s`, run through Vision on this Mac and labelled by file name (`squat.bodyweight_10.mov`, `pushup_8_2.mp4`, `squat.bodyweight_0.mov` for an idle clip). The videos are not committed (git ignores them), so this row cannot be reproduced from a clone." % show(real_dir))
    out.append("")
    out.append(real_videos["text"])
    out.append("")

out.append("### What counts as a real set")
out.append("")
out.append("`motion-eval` reads the expected counts from the fixture header (`labels.reps`, `labels.partials`) first and from the file name second (`<exercise>_<reps>[_<partials>]`, for example `squat.bodyweight_10_1_front.jsonl`). New iPhone recordings leave truth labels empty; older builds wrote the engine's own count, which is not ground truth. `tools/accuracy.sh` takes a file only after `tools/import-fixture.sh` has set the counts a person gave and added the `verified` tag. Files tagged `synthetic` or `replay`, or without a front or back camera position, are never counted as real.")
out.append("")

# Synthetic benchmark
out.append("## Synthetic benchmark")
out.append("")
out.append("`motion-eval --synthetic`. **Generated motion, not people.** A scripted stick figure (`SyntheticMotion` in MotionCore) performs each clip with seeded random noise on the joints (`Noise.visionLike`: white noise plus a slower wander, sized to look like Vision on a still person) and the engine counts it. The clips cover different tempos, pauses at the bottom, fatigue, partial reps, joint dropouts, both facings and idle clips (standing, walking out of frame and back, holding a plank). Everything is seeded, so every run prints this table. It tests the counting logic against known truth. It does not test how well Vision tracks a real body, and the noise model has not been compared with recorded Vision output. The engine's thresholds were tuned against this generator and its noise (`docs/rebuild-brief.md` §6.5), so this is not a held-out test.")
out.append("")
out.append(synthetic["text"])
out.append("")

# Replay clips
out.append("## Bundled replay clips")
out.append("")
out.append("`motion-eval App/Resources/ReplayPoses`. **Generated motion, not people.** The three clips the app replays on the Simulator, made by `tools/replay-fixtures` from `SyntheticMotion` with the same noise model. Their labels are the truth the generator scripted. They are not recordings.")
out.append("")
out.append(replay["text"])
out.append("")

md_path.parent.mkdir(parents=True, exist_ok=True)
md_path.write_text("\n".join(out), encoding="utf-8")
print("wrote %s" % show(md_path))

# --- README -------------------------------------------------------------------------------------------

if readme_path is not None:
    text = readme_path.read_text(encoding="utf-8")
    block = BEGIN + "\n" + summary_table + "\n\n" + status + "\n" + END
    text = re.sub(re.escape(BEGIN) + r".*?" + re.escape(END), lambda _: block, text, flags=re.S)
    readme_path.write_text(text, encoding="utf-8")
    print("updated the accuracy table in %s" % show(readme_path))
PY
