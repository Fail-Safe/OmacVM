#!/bin/bash
# Omarchy's bar clock like the Mac's menu bar: at the far right, in the Mac's
# format (from ../mac-clock.swift). Run as root inside the VM:
#   clock.sh USER on FORMAT    move it there; the clock as it was is kept
#   clock.sh USER off          put that clock back where it was
# Edits ~/.config/omarchy/shell.json in one step (Omarchy's shell reloads it).
set -euo pipefail
U=${1:?usage: clock.sh USER on FORMAT | off}; MODE=${2:?on or off}
H=$(getent passwd "$U" | cut -d: -f6)
# shellcheck source=../../guest/home-files.sh
source "$(dirname "$0")/../../guest/home-files.sh"   # the home is written as the user
C=$H/.config/omarchy/shell.json
KEEP=$H/.config/omacvm/clock-before.json
# Off: a clock queued for the next login (omacvm-plugins) is not set either.
[[ $MODE != off ]] || home_run rm -f "$H/.local/state/omacvm/pending-clock"
if [[ ! -f $C ]]; then
  # Fresh build, nobody logged in yet: omacvm-plugins sets it at the next login.
  if [[ $MODE == on ]]; then
    S=$H/.local/state/omacvm
    home_mkdir "$S"
    printf '%s' "${3:?format}" | home_put "$S/pending-clock"
    install -m755 "$(dirname "$0")/../../lib/omacvm-plugins" /usr/local/bin/omacvm-plugins
    install -m644 "$(dirname "$0")/../../lib/omacvm-plugins.service" /etc/systemd/user/omacvm-plugins.service
    systemctl --global enable omacvm-plugins.service >/dev/null 2>&1 || true
    echo "clock: set at the next login"
  fi
  exit 0
fi

write() {   # jq program and args; result replaces shell.json in one step, if it changes
  local tmp rc=0
  tmp=$(mktemp)
  jq "$@" < <(home_cat "$C") > "$tmp" && { home_same "$C" "$tmp" || home_put "$C" < "$tmp"; } || rc=$?
  rm -f "$tmp"
  return "$rc"
}

case $MODE in
  on)
    FMT=${3:?format}
    if [[ ! -f $KEEP ]]; then
      home_mkdir "$H/.config/omacvm"
      jq '[.bar.layout | to_entries[] | .key as $s | .value | to_entries[]
           | select(.value.id == "omarchy.clock") | {section: $s, index: .key, entry: .value}][0] // {}' < <(home_cat "$C") | home_put "$KEEP"
    fi
    write --arg f "$FMT" '
      ([.bar.layout[][] | select(.id == "omarchy.clock")][0] // {id: "omarchy.clock"}) as $c
      | .bar.layout |= map_values(map(select(.id != "omarchy.clock")))
      | .bar.layout.right += [$c + {format: $f}]'
    echo "clock: far right, $FMT" ;;
  off)
    [[ -s $KEEP ]] || exit 0
    keep=$(mktemp); trap 'rm -f "$keep"' EXIT
    home_cat "$KEEP" > "$keep" || true
    if jq -e '.entry' "$keep" >/dev/null; then
      write --slurpfile k "$keep" '
        $k[0] as $k
        | .bar.layout |= map_values(map(select(.id != "omarchy.clock")))
        | .bar.layout[$k.section] |= (.[:$k.index] + [$k.entry] + .[$k.index:])'
    fi
    home_run rm -f "$KEEP"
    echo "clock: back as it was" ;;
  *) echo "clock.sh: on or off" >&2; exit 2 ;;
esac
