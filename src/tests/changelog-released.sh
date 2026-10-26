#!/bin/bash
# A pull request adds nothing to a version that is already out: every line
# it adds to CHANGELOG.md sits in a section whose heading was not a released
# one ("## X.Y.Z" without "(unreleased)") at BASE. A release pull request
# turns "## X.Y.Z (unreleased)" into "## X.Y.Z": that heading is new, fine.
# (#556 was cut against 3.2.4 (unreleased); after 3.2.4's release it would
# have landed in the released 3.2.4 section.)
#   src/tests/changelog-released.sh [BASE]   (default origin/main)
set -uo pipefail
R=$(cd "$(dirname "$0")/../.." && pwd)
base=${1:-origin/main}
released=$(git -C "$R" show "$base:CHANGELOG.md" | grep -E '^## ' | grep -v '(unreleased)') || {
  echo "FAIL no CHANGELOG.md at $base"; exit 1; }
added=$(git -C "$R" diff -U0 "$base" -- CHANGELOG.md | awk '/^@@/ {
  split($3, a, ","); n = substr(a[1], 2); c = (a[2] == "" ? 1 : a[2]); for (i = 0; i < c; i++) print n + i }')
if [[ -z $added ]]; then echo "ok   CHANGELOG.md: no lines added against $base"; exit 0; fi
rf=$(mktemp "${TMPDIR:-/tmp}/changelog-released.XXXXXX"); trap 'rm -f "$rf"' EXIT
printf '%s\n' "$released" > "$rf"
bad=$(awk -v add="$(echo $added)" -v relf="$rf" '
  BEGIN { while ((getline l < relf) > 0) rel[l] = 1; split(add, a, " "); for (i in a) want[a[i]] = 1 }
  /^## / { sec = $0 }
  (NR in want) && !/^## / && (sec in rel) { print NR ": " sec ": " $0 }' "$R/CHANGELOG.md")
if [[ -n $bad ]]; then
  printf 'FAIL lines added to a released version (move them to the next "## X.Y.Z (unreleased)"):\n%s\n' "$bad"
  exit 1
fi
echo "ok   CHANGELOG.md: $(echo $added | wc -w | tr -d ' ') added lines, none in a released version"
