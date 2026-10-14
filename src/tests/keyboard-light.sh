#!/bin/bash
# The keyboard light's steps (src/bridge/mac/keylight.swift): offline always;
# with --live also on this Mac's keyboard light (lights the keys at each low
# step for a moment, then puts back the level from before); --state only
# reads what macOS says about it (level, auto adjust, bright light).
#   src/tests/keyboard-light.sh [--live | --state]
set -euo pipefail
R=$(cd "$(dirname "$0")/../.." && pwd)
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
swiftc -O -swift-version 5 -o "$T/keylight-test" \
  "$R/src/bridge/mac/keylight.swift" "$R/src/bridge/mac/tests/keylight/main.swift"
"$T/keylight-test"
[[ ${1:-} == --live ]] && "$T/keylight-test" live
[[ ${1:-} == --state ]] && "$T/keylight-test" state
exit 0
