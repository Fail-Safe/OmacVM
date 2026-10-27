# 0051: Partial present: draw only what the guest changed

Status: accepted, built (`omacvm-cocoa-present-damage*.patch`), off by
default until a VM run with `OMACVM_GL_PRESENT_DAMAGE=check` in a window
that is composited (pointer, typing, a TTY switch, the boot console) shows
0 differing pixels; `=1` turns it on. It acts only on flushes with real
rects: a buffer flushed again (boot console, TTYs) on any kernel, a
compositor's frames from Linux 7.4 or OmacVM's virtio-gpu driver with the
fix. Notes and numbers: work/tracks/frame-path.md.

## Context

QEMU's present ([0010](0010-iosurface-present.md)) draws the guest's whole
scanout into one of its IOSurfaces for every frame shown, also when only the
pointer moved or one character was typed. Measured offscreen on a MacBook Air
M2 (the same draw as the present, 2940x1840, whole-Mac power, 3 minutes a
row): +0.19 W at 60 frames a second and +0.47 W at 120 over the same loop
without the draw; the same draw scissored to a 64x64 box +0.06 and +0.02 W.
On the M4 Max the GPU time per draw is mostly a fixed cost (a 64x64 box takes
55-75 % of a full draw), on the M2 it follows the size (591 vs 1767 us).

The guest says what changed: each RESOURCE_FLUSH carries a rect. Linux up to
7.3 sets it to the whole plane on every page flip (virtgpu_plane.c:
ignore_damage_clips when the framebuffer changes), which a compositor does on
every frame. Linux 7.4 keeps the compositor's damage for rendered buffers
(upstream 730f8554f35c, a9cc9905ddb7). Hyprland and aquamarine send buffer-age
damage, a superset of what changed on screen.

## Options

1. Keep full draws. Nothing to get wrong; the cost above stays.
2. Draw the union of the rects since each surface's last draw, scissored,
   without the clear. Full draws for everything that is not a plain copy.
3. Show the guest's own buffer (zero copy, 0010 option 3). Removes the draw
   entirely, but needs rectangle sampling in virglrenderer and flip pacing
   against WindowServer: size L, high risk.

## Decision

Option 2. Per surface one box (the union of every flush rect since that
surface was drawn: merged and skipped frames count). Full draws for new
surfaces, another frame size, a scaled frame, the boot logo, the 2D console,
extra brightness, another colour path, a scanout that is part of its
resource, a box of three quarters of the frame or more, a new scanout buffer
until its first flush, and a scanout buffer not among the last four seen: a compositor's own buffers rotate, while a new
one (a client's buffer scanned out directly, a new swapchain) may come with
damage that is not relative to what was shown. The rules are a header without
AppKit or GL, tested on their own; the wiring is checked in the patched
`ui/cocoa.m` at build time and in CI. `OMACVM_GL_PRESENT_DAMAGE=check` draws
every 30th partial frame in full beside it and compares them pixel for pixel
(qemu.log), for tests in a VM.

## Consequences

- Guests before Linux 7.4 send whole-plane rects for a compositor's frames
  (page flips): those stay full draws until their kernel (or OmacVM's
  driver) sends real damage. OmacVM's driver carries the fix
  (`linux-virtio-gpu-damage-clips.patch`, the two upstream commits squashed);
  it loads for a start with "Draw only what changed" on (SMBIOS
  `omacvm.damage=1`, 0055) and for the other switches that load it (HDR,
  the pointer layer, frames in step until 3.2.7; amended in 0049). `omacvm check`'s
  "Changed parts" line says whether the damage reaches QEMU. A buffer flushed again (the boot console, a
  TTY) carries real rects on any kernel, so once on, partial draws happen
  there on today's 7.2 guests too.
- The watt numbers are an offscreen bench (no VM); there is no A/B in a VM
  yet. The 120/s scissored row (+0.02 W) below the 60/s one (+0.06 W) puts
  the noise at about 0.04 W. Where only small parts change, the present's
  share goes from up to +0.19 W (60 frames a second) or +0.47 W (120) to a
  few hundredths, but only at that frame rate: typing is about 9 flushes a
  second (about 0.02 W saved); a moving pointer or a spinner flushes at the
  display's rate. Scrolling and video change most of the frame: no gain
  there.
- A wrong rect from the guest shows as stale pixels until the next full draw.
  The rules only trust rects for buffers already seen; the check mode exists
  to find such guests. The guest kernel reuses resource ids (lowest free),
  so a new buffer can count as one already seen: that is safe while the
  compositor's damage is relative to what the plane showed, as the DRM
  damage contract says.
- WindowServer still composites the whole layer each frame: that part of a
  frame's cost does not change.
