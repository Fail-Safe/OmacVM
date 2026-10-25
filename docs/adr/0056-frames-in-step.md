# 0056: Frames in step with the Mac: the guest's vblank timer follows the host's refresh

Status: accepted, built (`input-vsync`), behind the app's experimental
switch "Frames in step with the Mac" (`vsyncLock`, off). It is option 1 of
[0020](0020-frames-on-the-displays-refresh.md) ("guest paced by the host"),
built on the jitter buffer of 0020 and the per-start driver of
[0049](0049-hdr-guest-tone-maps.md) / [0054](0054-pointer-on-its-own-layer.md).
Notes and numbers: work/tracks/input-vsync.md.

## Context

Linux 7.2's virtio-gpu has no vblank interrupt: DRM runs a timer at the
mode's frame time, started one frame after the first commit that follows a
pause (`drm_crtc_vblank_start_timer`). Its phase is wherever that commit
happened to come, so it has nothing to do with the Mac display's refresh.

Hyprland draws a frame right after a vblank. QEMU's present
(qemu-cocoa-gl-present-vsync, 0020) puts a frame that comes while frames
come steadily on the layer at the next commit, 3 ms before the Mac's vsync.
A frame done just after one commit waits almost a whole refresh for the
next: with a free phase that wait is anywhere from 0 to a refresh, on
average half of one, on top of the wait for the guest's own vblank. A native
app has only one of the two. Measured on 3.2.0 (tracks/input-latency.md): a
key while the pointer moves took about 11 ms more than on an idle screen at
60 Hz; the present's knobs (lead, input first, no vsync) did not help,
because the wait is in the phase, not in the queue.

## Options

1. QEMU answers the guest's flush fence at the Mac's vsync, and the driver
   completes the flip on it. Exact pacing, but fences on one context finish
   in order: one held fence holds back every later one (any client's), and
   a host that stops answering (window hidden, display asleep) stalls the
   guest.
2. QEMU sends a vblank event of its own. virtio-gpu has no event for it;
   the config-change interrupt is for display changes.
3. The guest's timer keeps running on its own and only moves its phase to a
   grid the host gives (this decision). If the host says nothing, nothing
   changes.

## Decision

1. **The guest asks.** OmacVM's virtio-gpu driver gets an option
   `vsync_lock` (off by default; `linux-virtio-gpu-vsync-lock.patch`, after
   the cursor-plane patch). With it, when the vblank timer starts and every
   half second while it runs (every 100 ms in its first half second), the
   driver sends OmacVM's own command 0x0f00 (scanout id). The answer (0x11f0)
   has the guest counter (CNTVCT) of the next vblank the host wants and the
   period in picoseconds, or no grid. QEMU computes the counter as the Mac's
   clock less hvf's vtimer offset, so no clock is translated twice. A QEMU
   that does not know the command answers with an error once, and the
   driver stops asking.
2. **The timer follows, gently.** After each vblank (the timer is already
   forwarded) the driver takes the host's period and moves the next expiry
   toward the nearest grid point by at most an eighth of a period, and never
   to within a quarter period of now: from any phase it is on the grid within
   six vblanks, and no frame is more than an eighth of a period shorter or
   longer than the others. No answer, a grid older than 2 s or a period more
   than 2 % off the mode's: the stock timer. The math is tested on its own
   against a simulated timer (`src/tests/virtio-gpu-vsync.sh`).
3. **The host places the vblank `lead` before each commit.** While a guest
   asked in the last 2 s, each tick of the present's display link publishes
   the grid: the guest's vblank at the tick's commit time less the lead, at
   the full rate's period measured over the link's run of ticks (a link
   slowed to 60 or 24 Hz on a ProMotion panel still ticks on that grid). The
   lead is when the guest's frames are ready after their vblank: the latest
   of the last 64 plus 1 ms, up at once, down by at most 2 ms a second, at
   least 2 ms, at most a period less 1 ms (`ui/omacvm-vsync.h`, tested in
   `test-vsync-follow.c`). Frames are timed on the grid the guest got at its
   last ask, and not for six vblanks after that grid moved: timed on the
   newest grid, a raised lead made the next frames look late and raised it
   again (the first build's lead wandered between 4.5 and 8.4 ms).
4. **A late frame costs one repeat.** While a guest follows, a tick that
   finds two frames shows the newer: the older came late for its own
   refresh. Without that, it would be shown a refresh late and keep every
   later frame a refresh late until the quarter-second trim.
5. **A switch, off by default.** The app's "Frames in step with the Mac"
   sends `omacvm.vsynclock=1`; the guest's loader adds `vsync_lock=1`
   (also on an 8-bit start: the driver then differs from the stock one only
   by the options asked for). Experimental: a new path between the guest's
   kernel and QEMU, and the late-frame rule changes how a missed refresh
   looks.

## Consequences

- Mac mini M4, 60 Hz, while the screen moves: keys 1.4-2.4 ms sooner, the
  pointer 4.8-4.9 ms, keys while the terminal scrolls 4-5 ms (3-8 runs a
  side); repeats + drops 86 instead of 103 over the final version's runs
  (off, the free phase drifts and the trims drop frames). At 120 Hz about 1 ms: the guest's frames are ready 5
  ms after their vblank (median) and up to a refresh, so the lead sits at its
  cap and late frames wait as before. The gain is smaller than the model's
  half refresh because the lead covers the slowest frame. Tables:
  work/tracks/input-vsync.md; docs/architecture/graphics.md section 12.
- MacBook Air M2 (60 Hz, pointer moving and scrolling, 180 s windows, off on
  on off): whole-Mac power the same within the rounds' spread (+0.5 to
  +1.4 %), the same frames a second, 0 pixels differ.
- Same frames: the guest still draws one frame per vblank at the display's
  rate (60, 120 Hz, ProMotion); only when it draws moves. Nothing changes on a
  still screen or for frames that come one at a time (typing on an idle
  screen): those are shown when ready, as before.
- The guest timer's own timestamps move with it (by at most an eighth of a
  period a vblank), so the vblank times Hyprland sees are the ones it draws on.
- One more virtqueue command every half second while the timer runs, and
  one spin lock per tick and per frame in QEMU.
- Needs Update VM (the driver is built in the VM from kernel.org's sources,
  like the 10-bit one).
