# 0057: Frames in step removed: no gain worth its cost

Status: accepted, built (`drop-vsync`, 3.2.7). Replaces
[0056](0056-frames-in-step.md), which stays as written for its design and
numbers. Option 1 of [0020](0020-frames-on-the-displays-refresh.md) is
not built any more; 0020's jitter buffer (option 4) stays.

## Context

3.2.3 shipped "Frames in step with the Mac" (`vsyncLock`, experimental,
off): OmacVM's virtio-gpu driver option `vsync_lock` asked QEMU for the Mac
display's refresh grid (OmacVM's command 0x0f00) and moved the guest's
vblank timer onto it (0056). What it gave, measured for 0056 (Mac mini M4,
MacBook Air M2):

- Input showed sooner only while the screen moved: at 60 Hz 1.5 to 7 ms,
  at 120 Hz up to about 2.5 ms (often 0). Nothing on a still screen.
- No power saved: whole-Mac power on the Air within 1 % (+0.9 % and
  +0.7 %), the same frames a second.
- At 120 Hz a few more skipped frames (8 instead of 2 in about 3 minutes
  of moving frames).

What it cost: two QEMU patches (virtio-gpu, hvf's timer offset, the
present's newest-frame rule), a 437-line guest driver patch that had to be
refreshed for each new kernel (it needed fuzz on 7.3 once), one more option
in the driver builder's tiers and loader, an `omacvm check` line, a row in
the VM window, and tests for all of it. It tied OmacVM to its own change of
Linux's display timing.

## Options

1. Keep it as an experimental switch, off.
2. Turn it on by default.
3. Remove it.

## Decision

Option 3. The coordinator put the numbers above to the user on 2026-10-26
with the other experimental switches of the weekend; the user, verbatim:
"ok drop nr 4, keep the others". "Pause drawing while hidden", "Draw only
what changed" and "Pointer on its own layer" stay as they are.

Removed in 3.2.7: the row and its key, the SMBIOS string
`omacvm.vsynclock=1`, the driver patch and option, the loader's and the
initramfs rule's reading of the flag, the check line, both QEMU patches and
their tests.

## Consequences

- A stored `vsyncLock` is removed once at launch (one log line); the VM
  draws as with the switch off. A downgrade to 3.2.6 reads it as off.
- The driver build's stamp changes (the patch is out of it), so Update VM
  builds the VM's driver once more for HDR, the pointer layer and "Draw only
  what changed" (internet once). Offline, the stock driver runs until then.
  The initramfs rule changes too: `mkinitcpio -P` runs once.
- An app of 3.2.3 to 3.2.6 with the switch on and a guest updated by a newer
  `omacvm`: the flag reaches the VM and asks for nothing (no check line).
- A 3.2.3 to 3.2.6 driver forced to ask (a hand-set SMBIOS string) gets
  virgl's "unknown command" answer, logs it once and keeps its own timer,
  as with GPU safe mode's 2D device.
- The input-latency harness (`src/tests/input-latency-vm.sh`) stays; it
  measures any change of the frame path.
- To try this again: a Linux virtio-gpu with a real vblank source (a host
  event per refresh) would need no timer of ours; until then 0056 has the
  design and the numbers.
