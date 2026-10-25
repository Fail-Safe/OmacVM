# 0055: Tiled present: only the changed tiles of a frame go to WindowServer

Status: accepted, built (`omacvm-cocoa-present-tiles*.patch`), off by default:
`OMACVM_GL_PRESENT_TILES=1` (`=check` for tests). It acts only when the guest
says what changed: Linux 7.4, or OmacVM's virtio-gpu driver with the damage
fix ([0051](0051-partial-present.md), #520); the app gets an experimental
switch for it together with that driver (a switch that does nothing on
today's 7.2 guests would mislead). Notes and numbers:
work/tracks/window-draw.md.

## Context

QEMU's present ([0010](0010-iosurface-present.md)) puts every guest frame on
the view's layer as a new whole IOSurface. WindowServer cannot know which
pixels of it changed, so it composites the whole window again for every frame,
also when only a caret blinked or a spinner turned. 0051 makes QEMU's own draw
into the surface partial; WindowServer's composite stays whole.

What that costs, measured without a VM (work/window-draw/kit/wdbench.m, a window
like the VM's): on a MacBook Pro M1 Max at 120 frames a second a full-screen
HDR window (half-float PQ surfaces, 3024x1898) takes the whole Mac from 4.45 W
to 8.49 W; WindowServer 156 GPU ms/s and 57 % of a core. The same window as a
grid of 16x10 tile layers, only 2 of them getting a new surface per frame:
WindowServer 51 instead of 124 GPU ms/s and the copy 65 instead of 142 (same
round); MacBook Air M2 at 60 frames a second: 34 instead of 156 and 31 instead
of 100. WindowServer's work follows the changed area once only those layers
change.

## Options

1. Keep whole frames. WindowServer composites the whole window per frame.
2. Direct to the display (no composite at all): needs a full-screen opaque
   CAMetalLayer and nothing above it. No setup went direct in our rows (also a
   bare CAMetalLayer, untagged, over the notch), and on the user's M1 Max an app
   keeps a 1x1 window above everything, which forces a composite for every
   full-screen app.
3. Tiles: a grid of tile layers over the last whole frame; a frame that changed
   little gets new surfaces for its changed tiles only.

## Decision

Option 3, experimental. 256x256 tiles; a frame whose changed box (the
guest's flush rects since the last frame drawn, one box) touches at most 12
tiles is drawn into those tiles' own surfaces (up to five per tile, as the
whole frames, made when needed, in the whole surfaces' format and colour
space; at most 32 tiles keep theirs, the least recently drawn give theirs back
first, and none after 10 s of whole frames) and only those tile
layers change; else a whole frame, which hides the tiles. Nothing changed:
nothing is presented. Whole frames for everything 0051 draws in full (boot
logo, extra brightness, another size or colour path, a buffer not seen lately
or not flushed yet), and whenever the window does not show the frame pixel for
pixel. Each whole frame shown measures that; tiles that do not fit hide, and
frames stay whole until a whole frame finds the window showing it pixel for
pixel again (a window that scales the picture never goes back and forth
between tiles and whole frames). Frames the present queue
skips hand their tiles to the frame after them, so nothing changed is lost.

## Measured (a real VM)

MacBook Air M2, the VM full screen at 60 Hz with #520's driver, A/B/A/B,
180 s windows, whole-Mac power: the pointer moving (Hyprland draws it) 3.13 /
3.12 W with tiles, 3.75 / 3.75 W without (WindowServer 43 vs 154 GPU ms/s,
guest 59.9 frames a second either way); a scrolling terminal and typing: no
change. Pictures of the window, tiles on vs off: 0 pixels differ; the check
mode never found a differing tile.

## Consequences

- WindowServer composites the changed tiles only; QEMU draws only them.
- Up to 12 small GL passes a frame instead of one large one: more than 12
  changed tiles is one whole frame.
- Up to five surfaces for each of at most 32 tiles (3024x1896: 42 MB of 10-bit
  or 8-bit tiles, 84 MB half float), given back after 10 s of whole frames.
- No gain without the guest's damage: Linux before 7.4 flushes the whole
  plane on every page flip (then every frame is whole, as with the switch off).
