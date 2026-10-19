# 0048: What the VM frees goes back to the Mac; 2 update snapshots

Status: accepted, built (`disk`, `disk-followup`).

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
  `NUMBER_LIMIT_IMPORTANT=2`; `KEEP` at the top of
  `src/guest/disk-space.sh`), set once, when the number is still
  omarchy-mac's 5 (`/var/lib/omacvm/update-snapshots` records it and the
  number set); the extra snapshots go at once (`snapper cleanup number`). A
  number set by hand stays, 5 too. Every update still gets its snapshot;
  the last 2 can be booted from GRUB or restored.
- `omacvm apply` runs the script at every full apply (build, Update VM; not
  a repair with `--only`), and only after the VM side worked: update
  snapshots are the way back to a system that worked, so a failed or rolled
  back apply leaves them.
- The same script turns `fstrim.timer` on, waits for btrfs's cleaner
  (`btrfs subvolume sync /`), commits, and runs one trim (`fstrim.service`),
  waited for. The cleaner and the trim share at most a minute; a trim still
  running then goes on by itself. Both waits are needed (measured below):
  btrfs frees a dropped snapshot's blocks later, in its cleaner, so a trim
  before that misses them; and Update VM shuts the VM down right after the
  apply, which cuts a trim short, and async discard drops what it has not
  sent by then and does not send it at the next boot (it loads free space
  as trimmed). That part then waited for the next weekly trim. What the
  cleaner has not freed within the minute it frees at the next boot, and
  async discard sends that then.
- No daily timer: async discard covers deletions within about two minutes,
  what is left is small.
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
| `disk-space.sh` run by hand in the VM (not through Update VM; as in #463, before the cleaner wait): 2 kept, a trim | 8575 MiB: 2.4 GiB back. 0.9 GiB within 10 s was the first trim of this VM (space free since before the boot); 1.5 GiB was the 3 dropped snapshots', sent by async discard after the trim (1 GiB within 20 s, 0.5 GiB at about 2 minutes) |
| the next update with 2 kept | 8064 MiB: its oldest snapshot's 512 MiB back |
| 1 GiB written to `/home`, 1 GiB to `/`, both deleted | 10112 -> 8065 MiB within about 2 minutes |
| `disk-space.sh` again | nothing changed (65 MiB more from the trim) |

btrfs waits about 2 minutes before it discards space in block groups still
partly in use; whole free block groups go at once.

In Update VM's order: the script, then at once a poweroff (as
`update-vm.sh` stops the VM), on fresh clones of the same VM with 5 update
snapshots (the same 4 x 512 MiB), 11054 MiB before (`work/disk/dfu`,
2026-10-19). Then a boot with 5 minutes for async discard, then a trim:

| script | took | after the poweroff | next boot | a trim |
|---|---|---|---|---|
| #463: trim started, not waited for | 0 s | 10720 MiB | 9716 MiB: the cleaner went on at the boot | 9124 MiB |
| the cleaner waited for, the trim not | 4 s | 10694 MiB | 10717 MiB: nothing | 9132 MiB |
| both waited for (this) | 7 s | 9101 MiB | 9124 MiB | 9103 MiB: nothing left |

Without the waits the space came back only at a later trim (the weekly
timer). None of this ran through Update VM itself; part of it is the VM's
first trim, which comes once, and how much that is depends on the VM.

## Other routes

The VM does the same on every route (the same mount options, timer and
snapshots). Whether the app's disk file gets smaller is the app's part and
was not measured on any of them. What is known:

- UTM 5: the disk is a qcow2 on NVMe. `qemu-img convert` made one 64 GB
  test VM's file 8.05 -> 7.46 GB (2026-10-08).
- Parallels: OmacVM's disk is plain, a sparse raw `.hds`, and
  `prl_disk_tool` cannot compact it (`src/prebuilt/make-image.sh` copies it
  with `dd conv=sparse` for that reason; a test VM, 2026-10-08). Whether
  Parallels frees the VM's discards in it is not known (no licence for a
  test).
- Fusion: the disk is a growable vmdk on NVMe. `vmware-vdiskmanager -k`
  freed nothing on two test VMs (2026-10-08).
