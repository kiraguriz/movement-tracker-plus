#!/usr/bin/env bash
# Regenerates docs/build-log.md: one line per commit on a branch (default: main), grouped by day, with the
# author date and time in Chicago time. The hackathon asks for proof of what was built when; this file is
# generated from git so nothing in it is typed by hand.
#
#   tools/build-log.sh            # log of main
#   tools/build-log.sh <ref>      # log of another branch, tag or commit
#
# Merge commits are left out (they carry no work). Commits are ordered by author time, which is when the work
# was written, not by the order in which a rebase or merge put them on the branch.
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
ref="${1:-main}"
out="$root/docs/build-log.md"
zone="America/Chicago"

cd "$root"
git rev-parse --verify --quiet "$ref^{commit}" >/dev/null || { echo "error: '$ref' is not a branch, tag or commit" >&2; exit 1; }
head_sha="$(git rev-parse --short "$ref")"

# epoch <TAB> "YYYY-MM-DD|Www|HH:MM ZZZ" <TAB> short hash <TAB> subject. format-local renders in $TZ.
raw="$(TZ="$zone" git log "$ref" --no-merges --format='%at%x09%ad%x09%h%x09%s' \
  --date='format-local:%Y-%m-%d|%a|%H:%M %Z' | LC_ALL=C sort -n -s -t "$(printf '\t')" -k1,1)"

count="$(printf '%s\n' "$raw" | grep -c . || true)"
if [ "$count" -eq 0 ]; then echo "error: no commits found on '$ref'" >&2; exit 1; fi

{
  echo "# Build log"
  echo
  echo "What was built when, generated from \`git log $ref\` by \`tools/build-log.sh\`. Times are author times in Chicago time (CST/CDT); merge commits are left out."
  echo
  printf '%s\n' "$raw" | awk -F '\t' -v ref="$ref" -v sha="$head_sha" '
    { n = split($2, d, "|"); days[NR] = d[1]; wd[NR] = d[2]; tm[NR] = d[3]; hash[NR] = $3; subject[NR] = $4 }
    END {
      printf "Source: `%s` at `%s`, %d commits, %s to %s.\n", ref, sha, NR, days[1], days[NR]
      last = ""
      for (i = 1; i <= NR; i++) {
        if (days[i] != last) { printf "\n## %s (%s)\n\n", days[i], wd[i]; last = days[i] }
        printf "- %s `%s` %s\n", tm[i], hash[i], subject[i]
      }
    }'
} > "$out"

echo "wrote ${out#"$root"/} ($count commits)"
