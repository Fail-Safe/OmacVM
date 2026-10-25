# 0051: Partial present: draw only what the guest changed

Status: accepted, built (`omacvm-cocoa-present-damage*.patch`), on by default;
`OMACVM_GL_PRESENT_DAMAGE=0` goes back. It acts only when the guest sends
damage rects: Linux 7.4, or OmacVM's virtio-gpu driver with the fix. Notes
and numbers: work/tracks/frame-path.md.

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
resource, a box of three quarters of the frame or more, and a scanout buffer
not among the last four seen: a compositor's own buffers rotate, while a new
one (a client's buffer scanned out directly, a new swapchain) may come with
damage that is not relative to what was shown. The rules are a header without
AppKit or GL, tested on their own; the wiring is checked in the patched
`ui/cocoa.m` at build time and in CI. `OMACVM_GL_PRESENT_DAMAGE=check` draws
every 30th partial frame in full beside it and compares them pixel for pixel
(qemu.log), for tests in a VM.

## Consequences

- Guests before Linux 7.4 send whole-plane rects: their frames stay full
  draws, so nothing changes for them until their kernel (or OmacVM's driver)
  sends real damage.
- Where only small parts change (the pointer, typing, a caret, clocks, chat
  apps' spinners) the present's share of power goes from up to +0.47 W (120
  frames a second) to a few tens of mW. Scrolling and video change most of the
  frame: no gain there.
- A wrong rect from the guest shows as stale pixels until the next full draw.
  The rules only trust rects for buffers already seen; the check mode exists
  to find such guests.
- WindowServer still composites the whole layer each frame: that part of a
  frame's cost does not change.
