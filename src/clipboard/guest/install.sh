#!/bin/bash
# Clipboard, guest side. Run as root inside the VM: ./install.sh <desktop-user>
# Mac -> VM is Parallels Tools. VM -> Mac: every copied text goes to the shared
# folder "clip", where omacvm-clip-in on the Mac puts it on the clipboard.
set -euo pipefail
cd "$(dirname "$0")"
U=${1:?usage: install.sh <desktop-user>}
H=$(getent passwd "$U" | cut -d: -f6)
source ../../guest/home-files.sh   # the home is written as the user

install -m755 parallels-clip-out /usr/local/bin/parallels-clip-out
A=$H/.config/hypr/autostart.lua
home_grep "$A" -q parallels-clip-out ||
  echo 'o.launch_on_start("wl-paste --type text --watch parallels-clip-out")' | home_append "$A"
# Parallels Tools' invisible clipboard helper window stays out of the tiling layout.
C=$H/.config/hypr/hyprland.lua
home_grep "$C" -q "Parallels Shared Clipboard" || home_append "$C" < clipboard-window-rule.lua
echo "clipboard installed"
