# 0055: Tiled present: only the changed tiles of a frame go to WindowServer

Status: accepted, built (`omacvm-cocoa-present-tiles*.patch`), experimental and
off by default (the app's switch "Draw only what changed", `presentTiles`;
`OMACVM_GL_PRESENT_TILES=1`, `=check` for tests). It acts only when the guest
says what changed: Linux 7.4, or OmacVM's virtio-gpu driver with the damage
fix ([0051](0051-partial-present.md), #520). Notes and numbers:
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
tiles is drawn into those tiles' own surfaces (five per tile, as the whole frames, made on first
use, in the whole surfaces' format and colour space) and only those tile
layers change; else a whole frame, which hides the tiles. Nothing changed:
nothing is presented. Whole frames for everything 0051 draws in full (boot
logo, extra brightness, another size or colour path, a buffer not seen lately
or not flushed yet), and whenever the window does not show the frame pixel for
pixel (the tiles hide and the next frame is whole). Frames the present queue
skips hand their tiles to the frame after them, so nothing changed is lost.

## Consequences

- WindowServer composites the changed tiles only; QEMU draws only them.
- Up to 12 small GL passes a frame instead of one large one: more than 12
  changed tiles is one whole frame.
- Five surfaces per tile that ever changed (at most five whole frames'
  worth of memory, usually much less).
- No gain without the guest's damage: Linux before 7.4 flushes the whole
  plane on every page flip (then every frame is whole, as with the switch off).
