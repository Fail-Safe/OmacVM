#!/bin/bash
# What the VM frees goes back to the Mac: OmacVM.app's disk.img shrinks, up
# to its set size (DISK_GB). btrfs discards what it frees (discard=async,
# src/vm/base-install.sh), QEMU punches it out of disk.img, fstrim.timer
# trims the rest weekly. Only snapshots keep deleted files: omarchy-mac
# snapshots / before each update and kept 5, so a file deleted outside /home
# stayed on the disk for 5 more updates. OmacVM keeps 2.
# Root, idempotent; guest/install.sh runs it at every full apply (build,
# Update VM). Test: src/tests/disk-space.sh.
set -u
C=${OMACVM_SNAPPER_ROOT:-/etc/snapper/configs/root}
M=${OMACVM_SNAPPER_DONE:-/var/lib/omacvm/update-snapshots}

# omarchy-mac's own number is 5 (default/snapper/root). Changed once (the
# file M): a number set by hand afterwards stays, 5 too.
if [[ ! -e $M && -f $C ]] && grep -qx 'NUMBER_LIMIT="5"' "$C"; then
  if snapper -c root set-config NUMBER_LIMIT=2 NUMBER_LIMIT_IMPORTANT=2; then
    mkdir -p "${M%/*}" && : > "$M"
    snapper -c root cleanup number || true
    echo "update snapshots: the last 2 kept (were 5)"
  else
    echo "update snapshots: could not set the number kept (snapper)" >&2
  fi
fi

systemctl enable fstrim.timer >/dev/null 2>&1 || true
# A trim now: discard=async only sees what is freed while mounted, not what
# was free before (the install's leftovers, /boot after a new initramfs).
systemctl start --no-block fstrim.service >/dev/null 2>&1 || true
