# 0048: What the VM frees goes back to the Mac; 2 update snapshots

Status: accepted, built (`disk`).

## Context

The VM should take only the space it uses on the Mac, and grow up to the
disk size set for it (`DISK_GB`, disk.img's length). For OmacVM.app VMs on
APFS that already worked, with nothing to switch on (checked link by link,
QEMU 11.1.1):

- btrfs mounts `/`, `/home` and `/var/log` with `discard=async`
  (`src/vm/base-install.sh`); `fstrim.timer` runs weekly.
- QEMU's NVMe turns a deallocate into a discard; `discard=unmap` passes it
  to the raw file, which calls `fcntl(F_PUNCHHOLE)`: APFS frees the blocks.
  disk.img's length (the ceiling) stays.
- The app's Storage shows disk.img's allocated size against its length.

What still kept space on the Mac (MacBook Pro, macOS 15.7.4):

1. **Update snapshots.** omarchy-mac snapshots `/` before every
   `omarchy update` and keeps 5 (`NUMBER_LIMIT=5`). Whatever is deleted
   outside `/home` stays while one of them holds it: up to 5 updates.
   3 GiB deleted in `/` with a snapshot over it stayed after 240 s and an
   fstrim; deleting the snapshot gave all of it back within 150 s.
2. **Space free before the boot.** Async discard only sees what is freed
   while mounted (and only pieces of 32 KiB and more); `/boot` (FAT) has no
   discard. The first fstrim on a VM gave back 0.5-0.7 GiB.
3. **@factory**, omarchy-mac's factory-reset copy of the installed system,
   is never pruned and keeps every file updates replace.
4. Write-zeroes has no hole path on macOS (ADR 0039); btrfs never sends it,
   and zeros it writes compress (1 GiB of zeros took 38 MiB).

## Decision

- snapper's root config keeps 2 (`NUMBER_LIMIT=2`,
  `NUMBER_LIMIT_IMPORTANT=2`), set by `src/guest/disk-space.sh` at every
  full apply (build, Update VM), once, when the number is still
  omarchy-mac's 5 (`/var/lib/omacvm/update-snapshots` records it); the
  extra snapshots go at once (`snapper cleanup number`). A number set by
  hand stays, 5 too. Every update still gets its snapshot; the last 2 can
  be booted from GRUB or restored.
- The same script turns `fstrim.timer` on and starts one trim
  (`fstrim.service`, not waited for). No daily timer: async discard covers
  deletions within about two minutes, what is left is small.
- @factory stays: without it omarchy-mac's factory reset has nothing to go
  back to. Removing it is the person's choice.
- No QEMU change, no app change, no switch: nothing visible changes but the
  number of snapshots.
- `omacvm check`: "freeing disk space" (FAIL when nothing trims, WARN while
  the VM still keeps omarchy-mac's 5).

## Measured

MacBook Pro M4 Max, macOS 15.7.4, QEMU 11.1.1 with the app's disk options,
an APFS clone of an 11-day-old app VM (full setup, OmacVM 3.0.6, 64 GB
disk). disk.img's allocated size on the Mac:

| step | disk.img |
|---|---|
| after boot (1 update snapshot) | 9006 MiB |
| 4 updates' snapshots, each holding 512 MiB deleted from `/` since | 11055 MiB |
| the next update with omarchy-mac's 5 | 11054 MiB: nothing back |
| `disk-space.sh` (as at Update VM): 2 kept, a trim | 8575 MiB: 2.4 GiB back (1.6 GiB within 20 s, the rest at about 2 minutes) |
| the next update with 2 kept | 8064 MiB: its oldest snapshot's 512 MiB back |
| 1 GiB written to `/home`, 1 GiB to `/`, both deleted | 10112 -> 8065 MiB within about 2 minutes |
| `disk-space.sh` again | nothing changed (65 MiB more from the trim) |

btrfs waits about 2 minutes before it discards space in block groups still
partly in use; whole free block groups go at once.

## Other routes

The VM does the same on every route (the same mount options, timer and
snapshots); whether the app's disk file gets smaller is the app's part, not
measured: UTM 5 keeps the disk as qcow2 on NVMe (its QEMU 10.0.12 has
`discard=unmap`), Parallels' disk is expanding with `OnlineCompactMode=1`
(no licence for a test), Fusion's is a growable vmdk on NVMe
(`vmware-vdiskmanager -k` compacts it by hand).
