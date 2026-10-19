#!/bin/bash
# Display sync, guest side. Run as root inside the VM: ./install.sh <desktop-user>
# parallels-dynres makes Hyprland follow what Parallels pushes: the window or
# display size, the refresh rate (120 Hz ProMotion), every external display and
# the macOS arrangement. Needs the read-only shared folder "vmlog" (the VM bundle,
# set up by build.sh) for the arrangement; without it, sizes only.
set -euo pipefail
cd "$(dirname "$0")"
U=${1:?usage: install.sh <desktop-user>}
H=$(getent passwd "$U" | cut -d: -f6)
source ../../guest/home-files.sh   # the home is written as the user

install -m755 parallels-dynres /usr/local/bin/parallels-dynres

# monitors.lua: keep the scale chosen in Omarchy's menu if there already is one.
M=$H/.config/hypr/monitors.lua
scale=$(home_grep "$M" -m1 '^local omarchy_monitor_scale = ' | sed -n 's/^local omarchy_monitor_scale = \([0-9.]*\).*/\1/p' || true)
# One write, only when it changes: Hyprland reloads on every write.
tmp=$(mktemp); trap 'rm -f "$tmp"' EXIT
cp monitors.lua "$tmp"
[[ -n $scale ]] && sed -i "s/^local omarchy_monitor_scale = .*/local omarchy_monitor_scale = $scale/" "$tmp"
home_same "$M" "$tmp" || home_put "$M" < "$tmp"

A=$H/.config/hypr/autostart.lua
home_grep "$A" -q parallels-dynres || echo 'o.launch_on_start("parallels-dynres")' | home_append "$A"
echo "display sync installed"
