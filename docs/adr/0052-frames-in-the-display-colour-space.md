# 0052: The VM's frames in the display's own colour space

Status: accepted, built (`window-path`), on by default (`OMACVM_GL_DISPLAY_COLOR=0`
keeps the sRGB tag). Amends the colour part of [0049](0049-hdr-guest-tone-maps.md)'s
chain for 8-bit SDR frames only. Notes and numbers: work/tracks/window-path.md.

## Context

QEMU's IOSurface present tags the guest's 8-bit frames sRGB, so Core Animation
shows the right colours on a P3 panel (`qemu-cocoa-gl-present-color.patch`). The
price: WindowServer converts the whole window from sRGB to the display's colour
space on every composite. On a MacBook Air M2 (full screen, 2940x1840) a window like
the VM's costs WindowServer 79.6 GPU ms/s at 30 frames a second tagged sRGB and 56.5
when the frames are already in the display's space (the same as untagged); at 60
frames 154 vs 109 (work/window-path/wsbench, no VM; the VM measured the same: 77 vs
53 untagged for a 1080p video). Chrome and other native apps render in the display's
space and tag their surfaces with it, so WindowServer only copies them.

## Decision

1. **QEMU converts, in the pass it draws anyway.** The present draws 8-bit SDR frames
   through a 33x33x33 table into the window's display's colour space and tags the
   surfaces with that space. One more texture read per pixel; no new pass.
2. **macOS makes the table.** CoreGraphics converts the table's grid from sRGB to the
   display's space (relative colorimetric, as WindowServer matches a tagged surface),
   so any profile works without parsing ICC data.
3. **Checked before use.** At each new display space QEMU compares the table, read as
   the GPU reads it, with macOS converting 2304 colours itself. More than 2 codes off
   (a plain gamma 2.2 profile: 4-5 near black) and that display keeps the sRGB tag.
   Display P3 and MacBook panels are 1 code off, an LG UltraFine's profile 2.
4. **Only where it is the same picture.** HDR (PQ), 10-bit, Extra brightness, the boot
   logo, an sRGB display and any failure keep what they had. The surfaces there
   decide how a frame is drawn (the remake hold-off), so no frame shows in the wrong
   colours; a new display space remakes them at once (at most once a second).

## Consequences

- WindowServer's GPU time for the window drops by about 30 % (video, scrolling,
  anything that changes the window). Whole-Mac watts drop less (about 0.02 W at 30
  frames a second on the Air): the composite's cost is mostly reading and writing
  the pixels, not the colour maths.
- Colours stay within 1-2 codes of what macOS showed before (8-bit in the display's
  space, as Chrome renders).
- A screenshot or screen recording of the window gets frames tagged with the display's
  space; macOS converts them for the file as for any app.
