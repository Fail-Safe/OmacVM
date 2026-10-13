#!/bin/bash
# Omarchy's night light indicator leaves the bar's indicators widget: the
# Mac's Night Shift tints the screen (switching hyprsunset would tint it
# twice). Run by install.sh as root:
#   nightlight-indicator.sh SHELL_JSON MARKER [INDICATORS_QML]
# MARKER keeps the widget's own items the first time (null: Omarchy's
# default), so turning the Bridge off puts them back (../../guest/off.sh).
# Without items of the user's own the widget gets Omarchy's default list
# less NightLight, read from the installed widget (INDICATORS_QML): it
# differs between Omarchy versions. MARKER.set keeps the list it wrote, so
# the next run follows Omarchy's default while the user has not changed it.
# Edits SHELL_JSON only when it changes.
set -euo pipefail
C=${1:?usage: nightlight-indicator.sh SHELL_JSON MARKER [INDICATORS_QML]}
MARK=${2:?usage: nightlight-indicator.sh SHELL_JSON MARKER [INDICATORS_QML]}
IND=${3:-/usr/share/omarchy/shell/plugins/bar/widgets/Indicators.qml}
SET=$MARK.set
# Omarchy's default before October 2026 (and what OmacVM up to 3.1.2 wrote
# less NightLight for a widget without items of its own).
OLD='["Dictation", "ScreenRecording", "Reminder", "NightLight", "Dnd", "StayAwake"]'

[[ -f $C ]] || exit 0
jq -e '[.bar.layout[]?[]? | select(.id == "omarchy.indicators")] | length > 0' "$C" >/dev/null || exit 0
if [[ ! -f $MARK ]]; then
  mkdir -p "$(dirname "$MARK")"
  jq -c '[.bar.layout[]?[]? | select(.id == "omarchy.indicators") | .items] | first' "$C" > "$MARK"
fi
D=$(sed -n 's/^ *readonly property var defaultIndicatorEntries: *\(\[.*\]\) *$/\1/p' "$IND" 2>/dev/null | head -n1 || true)
jq -e 'type == "array" and length > 0 and all(type == "string")' <<<"${D:-null}" >/dev/null 2>&1 || D=$OLD
own=$(cat "$MARK")
jq -e . <<<"$own" >/dev/null 2>&1 || own=null
last=$(cat "$SET" 2>/dev/null || true)
jq -e 'type == "array"' <<<"${last:-null}" >/dev/null 2>&1 || last=null
# Next to it and renamed into place, only when it changes (the shell reads it).
tmp=$(mktemp "$C.XXXXXX")
jq --argjson d "$D" --argjson old "$OLD" --argjson own "$own" --argjson last "$last" '
  (.bar.layout[]?[]? | select(.id == "omarchy.indicators")) |=
    (.items = ((if $own == null and (.items == null or .items == ($old - ["NightLight"]) or .items == $last) then $d
                else (.items // $d) end) - ["NightLight"]))' "$C" > "$tmp"
jq -c '[.bar.layout[]?[]? | select(.id == "omarchy.indicators") | .items] | first' "$tmp" > "$SET"
if cmp -s "$tmp" "$C"; then rm -f "$tmp"
else chmod --reference="$C" "$tmp" 2>/dev/null || chmod "$(stat -f %Lp "$C")" "$tmp"
  chown --reference="$C" "$tmp" 2>/dev/null || true
  mv -f "$tmp" "$C"; echo changed; fi
