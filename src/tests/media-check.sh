#!/bin/bash
# omacvm check's "media controls" line (src/guest/check.sh, media_line): AirPods
# and media controls in an OmacVM.app VM. skip without the port (an older app),
# FAIL when the agent does not run or says an error, else the app's switch and
# what plays, never a title; WARN when a player did not take the last command. The function is taken from check.sh as it is.
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd -P)
check="$here/../guest/check.sh"
T=$(mktemp -d "${TMPDIR:-/tmp}/omacvm-media-check.XXXXXX")
trap 'rm -rf "$T"' EXIT
awk '/^media_line\(\) \{/ {on=1} on {print} on && /^}$/ {exit}' "$check" > "$T/fn.sh"
[[ -s $T/fn.sh ]] || { echo "FAIL: no media_line in check.sh"; exit 1; }
# shellcheck disable=SC1091
source "$T/fn.sh"
fail=0
expect() {   # what, port (1/0), running (1/0), status JSON, want status, want text in the detail
  local got; got=$(media_line "$2" "$3" "$4")
  if [[ ${got%%$'\t'*} == "$5" && $got == *"$6"* ]]; then echo "ok   $1"
  else echo "FAIL $1: got '$got', want '$5' with '$6'"; fail=1; fi
}
expect "no port (an app from before): skip" 0 0 "" skip "from before AirPods and media controls"
expect "port, agent not running: FAIL with omacvm apply" 1 0 "" fail "not running: omacvm apply"
expect "agent stopped with python-gobject missing: FAIL says so" 1 0 '{"mac":"silent","error":"python-gobject is missing: omacvm apply"}' fail "python-gobject is missing"
expect "a player did not take the last command: WARN" 1 1 '{"mac":"on","error":"Play: timeout"}' warn "the last command failed: Play: timeout"
expect "switch on, a player plays: ok with the player" 1 1 '{"mac":"on","player":"Chromium","state":"playing","error":""}' ok "on: Chromium playing"
expect "switch on, paused" 1 1 '{"mac":"on","player":"mpv Media Player","state":"paused","error":""}' ok "on: mpv Media Player paused"
expect "switch on, nothing plays" 1 1 '{"mac":"on","player":"","state":"none","error":""}' ok "on: nothing plays now"
expect "switch on, no state yet" 1 1 '{"mac":"on","error":""}' ok "on: nothing plays now"
expect "switch off" 1 1 '{"mac":"off","error":""}' ok "off (the app's switch"
expect "the app has not answered" 1 1 '{"mac":"silent","error":""}' ok "waiting for the app"
expect "no status file yet" 1 1 '{}' ok "waiting for the app"
grep -q 'ok "media controls"' "$check" && grep -q 'media_line "$mport" "$mrun"' "$check" ||
  { echo "FAIL: check.sh does not use media_line for its \"media controls\" line"; fail=1; }
(( fail == 0 )) && echo "media-check: all passed"
exit $fail
