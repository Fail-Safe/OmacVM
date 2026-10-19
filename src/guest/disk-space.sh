#!/bin/bash
# What the VM frees goes back to the Mac: OmacVM.app's disk.img shrinks, up
# to its set size (DISK_GB). btrfs discards what it frees (discard=async,
# src/vm/base-install.sh), QEMU punches it out of disk.img, fstrim.timer
# trims the rest weekly. Only snapshots keep deleted files: omarchy-mac
# snapshots / before each update and kept 5, so a file deleted outside /home
# stayed on the disk for 5 more updates. OmacVM keeps fewer: KEEP.
# Root, idempotent. omacvm apply (src/cmd/apply.sh) runs it at every full
# apply (build, Update VM), once the VM side worked: update snapshots are the
# way back to a system that worked. Test: src/tests/disk-space.sh.
set -u
KEEP=2   # update snapshots kept (omarchy-mac: 5)
C=${OMACVM_SNAPPER_ROOT:-/etc/snapper/configs/root}
M=${OMACVM_SNAPPER_DONE:-/var/lib/omacvm/update-snapshots}

# omarchy-mac's own number is 5 (default/snapper/root). Changed once (the
# file M, which holds the number set): a number set by hand afterwards
# stays, 5 too.
if [[ ! -e $M && -f $C ]] && grep -qx 'NUMBER_LIMIT="5"' "$C"; then
  if snapper -c root set-config NUMBER_LIMIT=$KEEP NUMBER_LIMIT_IMPORTANT=$KEEP; then
    mkdir -p "${M%/*}" && echo "$KEEP" > "$M"
    snapper -c root cleanup number || true
    echo "update snapshots: the last $KEEP kept (were 5)"
  else
    echo "update snapshots: could not set the number kept (snapper)" >&2
  fi
fi

systemctl enable fstrim.timer >/dev/null 2>&1 || true
# A trim now: discard=async only sees what is freed while mounted, not what
# was free before (the install's leftovers, /boot after a new initramfs),
# and it drops what it has not sent yet when the VM shuts down, which
# Update VM does right after. btrfs frees a deleted snapshot's blocks later,
# in its cleaner: so the cleaner first, then a commit, so that what it freed
# is free space the trim sees, then the trim. At most about a minute for
# both; if that runs out, the trim goes on by itself.
# What the cleaner frees later (at the next boot, when the VM shut down
# first) goes back by async discard then, or with the next trim.
end=$((SECONDS + 60))
timeout 60 btrfs subvolume sync / >/dev/null 2>&1 || true
btrfs filesystem sync / >/dev/null 2>&1 || true
left=$((end - SECONDS)); (( left > 10 )) || left=10
timeout "$left" systemctl start fstrim.service >/dev/null 2>&1 || true
