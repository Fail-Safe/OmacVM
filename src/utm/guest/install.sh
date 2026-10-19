#!/bin/bash
# UTM specifics, guest side. Run as root inside the VM:
#   ./install.sh <desktop-user> <WIDTHxHEIGHT@HZ>
# (apply.sh passes the Mac's built-in display below the notch, display/mac-display.swift)
#  * UTM's guest tools: the SPICE daemon with OmacVM's Wayland session agent
#    (clipboard both ways, pointer over the whole screen; the stock agent is
#    X11-only and sizes the pointer wrong under Hyprland) and the QEMU guest
#    agent (utmctl ip-address / exec / file push)
#  * virtio-gpu workarounds for Hyprland
#  * the GPU for the browsers: Chrome, Chromium, Brave, Firefox (virgl-msaa.c)
#  * a fixed display mode from boot: UTM's GPU path goes blank when the mode
#    changes while running, and "preferred" is only 1280x800
set -euo pipefail
cd "$(dirname "$0")"
U=${1:?usage: install.sh <desktop-user> <WxH@Hz>}; MODE=${2:?display mode}
H=$(getent passwd "$U" | cut -d: -f6)
source ../../guest/home-files.sh   # the home is written as the user
../../guest/pkg-add spice-vdagent qemu-guest-agent wl-clipboard python
systemctl enable --now qemu-guest-agent spice-vdagentd >/dev/null 2>&1 || true
install -m755 omacvm-vdagent /usr/local/bin/omacvm-vdagent
install -m644 omacvm-vdagent.service /etc/systemd/user/omacvm-vdagent.service
systemctl --global mask spice-vdagent.service >/dev/null 2>&1
systemctl --global enable omacvm-vdagent.service >/dev/null 2>&1
# swap agents in a running session too
if systemctl --user -M "$U@" daemon-reload 2>/dev/null; then
  systemctl --user -M "$U@" stop spice-vdagent.service 2>/dev/null || true
  systemctl --user -M "$U@" restart omacvm-vdagent.service 2>/dev/null || true
fi
install -Dm644 90-omacvm-utm.conf /etc/environment.d/90-omacvm-utm.conf

# GPU in the browsers: see virgl-msaa.c. Built here, as
# the kernel headers it needs come with the VM.
../../guest/pkg-add gcc
L=/usr/local/lib/omacvm/virgl-msaa.so
install -d /usr/local/lib/omacvm
if gcc -shared -fPIC -O2 -o "$L.new" virgl-msaa.c -ldl; then mv -f "$L.new" "$L"
else rm -f "$L.new"; echo "UTM: could not build virgl-msaa.so (browser GPU not updated)" >&2; fi
if [[ -f $L ]]; then grep -qx "$L" /etc/ld.so.preload 2>/dev/null || echo "$L" >> /etc/ld.so.preload; fi

# mpv's defaults, as in app VMs (app/guest/venus/mpv.sh): vo=gpu. UTM's GPU is
# virgl too, where mpv's default output (gpu-next) keeps a file per frame and
# stops drawing after ~17 s of 60 fps video.
../../app/guest/venus/mpv.sh || echo "UTM: mpv's defaults are not set; mpv may stop drawing after ~17 s of video" >&2

M=$H/.config/hypr/monitors.lua
scale=$(home_grep "$M" -m1 '^local omarchy_monitor_scale = ' | sed -n 's/^local omarchy_monitor_scale = \([0-9.]*\).*/\1/p' || true)
# Written next to it and moved into place, only when it changes: Hyprland
# reloads on every write.
tmp=$(mktemp); trap 'rm -f "$tmp"' EXIT
cat > "$tmp" <<LUA
-- OmacVM, UTM: the Mac's built-in display below the notch, fixed from boot.
-- UTM's virtio-gpu (virgl) goes blank when the mode changes while running, so
-- do not switch modes live; edit and reboot instead. Omarchy's scaling menu
-- writes omarchy_monitor_scale here.
local omarchy_gdk_scale = 2
local omarchy_monitor_scale = ${scale:-2}

hl.env("GDK_SCALE", tostring(omarchy_gdk_scale))
hl.monitor({ output = "Virtual-1", mode = "$MODE", position = "0x0", scale = omarchy_monitor_scale })
LUA
# A new mode while Omarchy runs would go live and blank virgl: then it waits in
# monitors.lua.pending, which omacvm-utm-display puts in place at the next boot.
cat > /etc/systemd/system/omacvm-utm-display.service <<'UNIT'
[Unit]
Description=OmacVM, UTM: a display mode set while Omarchy ran
Before=display-manager.service

[Service]
Type=oneshot
ExecStart=/usr/local/bin/omacvm-utm-display

[Install]
WantedBy=multi-user.target
UNIT
cat > /usr/local/bin/omacvm-utm-display <<'SH'
#!/bin/sh
# Moved by the home's owner, not root: a link in the home must not make root
# move a file of the system.
for h in /home/*; do
  f=$h/.config/hypr/monitors.lua.pending
  [ -f "$f" ] || continue
  u=$(stat -c %U "$h") && [ "$u" != root ] || continue
  setpriv --reuid="$u" --regid="$(id -g "$u")" --init-groups -- mv -f "$f" "${f%.pending}" < /dev/null
done
exit 0
SH
chmod 755 /usr/local/bin/omacvm-utm-display
systemctl enable -q omacvm-utm-display.service 2>/dev/null || true
when=now
if home_same "$M" "$tmp"; then home_run rm -f "$M.pending"
elif [[ -n $(ls -A "/run/user/$(id -u "$U")/hypr" 2>/dev/null) ]]; then home_put "$M.pending" < "$tmp"; when="from the next boot"
else home_put "$M" < "$tmp"
fi
echo "UTM: guest tools, virtio-gpu settings, browser GPU, display $MODE ($when)"
