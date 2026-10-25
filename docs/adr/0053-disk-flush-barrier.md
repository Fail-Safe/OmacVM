# 0053: A guest disk flush is a write barrier on the Mac's drive

Status: accepted, built (`disk`, 3.2.1).

## Context

When the VM's file system commits (btrfs every 30 s, and at every `fsync()`
an app makes), the guest sends its NVMe disk a flush and expects everything
written before it to be safe. QEMU 11.1.1 turns that flush into `fdatasync()`
(`block/file-posix.c`, `handle_aiocb_flush`). On macOS, `fsync()` and
`fdatasync()` hand the data to the drive and return; the drive keeps it in
its own cache and writes it to flash in any order. Apple's answer is
`fcntl(F_FULLFSYNC)` (wait until the drive has written it) or
`fcntl(F_BARRIERFSYNC)` (the drive writes nothing after the barrier before
what came before it).

After a power cut (the Mac mini and the Studio have no battery; a held power
button on a laptop) the guest could lose writes it was told were safe and
keep later ones. For btrfs that can mean a superblock that points at trees
that never reached the flash: a disk that no longer mounts, not only the
last seconds lost. Virtualization.framework has a similar switch
(`VZDiskImageSynchronizationMode`): "full" (`F_FULLFSYNC`, its default) or
"fsync" (plain `fsync()`, no barrier). It has no barrier level.

## Measured

Cost of one call on the Mac (4 KiB write + flush, p50):

| Mac, drive | fsync | F_BARRIERFSYNC | F_FULLFSYNC |
|---|---|---|---|
| Mac mini M4, internal | 20 µs | 357 µs | 3019 µs |
| Mac mini M4, WD_BLACK SN850X over Thunderbolt | 36 µs | 537 µs | 544 µs |
| MacBook Pro M4 Max, internal | 42 µs | 211 µs | 4503 µs |
| MacBook Pro M1 Max, internal (night run) | 21-36 µs | 0.66-0.75 ms | 5.7-6.0 ms |

The external drive takes no barrier: APFS flushes it instead, which is cheap
on that drive.

In the VM (MacBook Pro M4 Max, internal SSD, 4 vCPUs / 4 GB, the VM's own
btrfs, one runtime switched with `OMACVM_DISK_FLUSH`, median of 3):

| flush | 4k write + fsync, QD1 | git: 200 commits | git checkout, 20k files | pacman: 222 packages of a real update | 1 GiB write |
|---|---|---|---|---|---|
| fsync (QEMU's own, up to 3.2.0) | 379 µs, 2566/s | 0.70 s | 0.44 s | 41.4 s | 1535 MB/s |
| **barrier (new default)** | 627 µs, 1534/s | 0.97 s | 0.46 s | 41.2 s | 1679 MB/s |
| full | 6586 µs, 152/s | 6.65 s | 0.46 s | 41.4 s | 1522 MB/s |

On this M4 Max a barrier costs about 0.25 ms per guest fsync. The M1 Max's
barrier costs about three times the M4 Max's on the Mac (table above), so
there a guest fsync likely costs about 1 ms; not measured in a VM. Only work
that flushes all the time
sees it: 1.4 ms more per git commit, fewer small synced writes per second.
Installs, checkouts and big writes are the same. A full flush costs 6 ms each
and makes git commits ten times slower.

Kill test, same VM: a writer in the guest makes files of 4-256 KiB, syncs
each with its checksum and prints its number; QEMU is killed with `kill -9`
4-15 s in, the VM boots again and checks every printed file, then runs a
btrfs scrub. Barrier: 10 kills, 4983 synced files, none missing or damaged,
scrub clean. Old fsync: 5 kills, 2607 files, the same. This proves the path
from the guest's flush to macOS, in both modes (a killed QEMU loses nothing
macOS already has). What the drive does at a real power cut cannot be tested
on a Mac we use; the barrier rests on Apple's documented meaning of the call.

Not measured: SD cards and USB drives. A drive without barrier support gets a
full flush from APFS instead (the SN850X above: 537 vs 544 µs). A drive with
a slow cache flush pays that at every guest fsync, and a browser profile's
SQLite fsyncs often. The Air's SD card (SD4TB) was not attached when this was
written (2026-10-25). `OMACVM_DISK_FLUSH=fsync` gives the old cost back.

## Decision

- Every guest flush is `fcntl(F_BARRIERFSYNC)`
  (`app/runtime/patches/qemu-darwin-disk-flush-barrier.patch`). The guest's
  file system should stay whole after a power cut, with at most the last
  moments before it lost, as on a Linux PC with a disk cache (Apple's
  documented meaning of the call; a real power cut was not tested).
- `OMACVM_DISK_FLUSH=full` in QEMU's environment waits for the drive at every
  flush (`F_FULLFSYNC`); `=fsync` is the old behaviour. Not a setting in the
  app: nobody needs to pick it.
- A drive whose file system refuses the call (ENOTSUP, EOPNOTSUPP, ENOTTY or
  EINVAL; some network and non-Apple file systems) gets the next weaker one,
  down to `fdatasync()`, the behaviour up to 3.2.0. qemu.log says so once, and
  `omacvm check` shows a warning in its "disk flush" line. A refused barrier
  does not go up to `F_FULLFSYNC`: on such a drive that is an unmeasured cost
  at every flush. Each flush asks again (a refusal costs a few µs, and the
  answer belongs to the drive, not to QEMU). APFS, HFS+, exFAT and FAT all
  take both calls (a review's probe on the mini, macOS 27).
- The Mac folder (9p) keeps plain `fsync()`: those files are the Mac's own.
