#!/bin/bash
# Per-display workspaces, guest side. Run as root inside the VM: ./install.sh <desktop-user>
# Every display gets its own workspaces 1..0 (keys and bar), like Spaces on the
# Mac. Unplugging a display parks its workspaces on the main one and replugging
# puts them back (monitor_workspaces.lua).
set -euo pipefail
cd "$(dirname "$0")"
U=${1:?usage: install.sh <desktop-user>}
H=$(getent passwd "$U" | cut -d: -f6)
source ../../guest/home-files.sh   # the home is written as the user
# Replaced in one step: Omarchy reloads its config on every change, and
# bindings.lua requires this file (a reload in between showed "module not found").
# Only when it changed: a reload moves the displays (a flicker on each apply).
home_same "$H/.config/hypr/monitor_workspaces.lua" monitor_workspaces.lua ||
  home_put "$H/.config/hypr/monitor_workspaces.lua" < monitor_workspaces.lua
B=$H/.config/hypr/bindings.lua
home_grep "$B" -q 'require("hypr.monitor_workspaces")' || home_append "$B" < workspace-bindings.lua
../../lib/install-plugin.sh "$U" ../plugins/omacvm.workspaces
echo "per-display workspaces installed"
