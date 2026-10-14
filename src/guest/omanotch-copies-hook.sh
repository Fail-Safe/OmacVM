#!/bin/bash
# pacman hook zz-omacvm-omanotch-copies.hook (root), after an update of
# Omarchy's bar or background: starts the desktop user's
# omanotch-copies.service, which waits for the end of the update and an
# unlocked session, then brings Omanotch's copies of them up to Omarchy's
# (src/omanotch/guest/copies.py). Nobody logged in: it runs at the next login.
U=$(sed -n 's/^OMACVM_USER=//p' /etc/omacvm/env 2>/dev/null)
[[ $U =~ ^[a-z_][a-z0-9_-]*$ ]] || exit 0
systemctl --user -M "$U@" start --no-block omanotch-copies.service >/dev/null 2>&1 || true
exit 0
