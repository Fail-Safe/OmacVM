# 0056: Direct to display: the VM's frames in a CAMetalLayer, so macOS can show the window itself

Status: proposed, built (`direct-display`, branch only: no watt gain measured yet), experimental and off by
default ("Show directly on the display", `directDisplay`; `OMACVM_GL_DIRECT=1`). Notes and numbers:
work/tracks/direct-display.md.

## Context

Full-screen games and video players on a Mac can be shown by the display hardware itself:
WindowServer then neither reads the app's frame nor writes its own framebuffer for it
("direct to display"; Core Animation calls the layer "detached"). The VM's window never was:
WindowServer composited every frame (MacBook Air M2, 60 frames a second: 54-110 GPU ms/s and
30-40 % of a core for a window like the VM's).

What macOS 27 needs, measured on a MacBook Air M2 with a bench window like the VM's (no VM;
WindowServer's GPU time per second, and Metal's HUD, which says "Direct" or "Composited"):

- The layer is a CAMetalLayer. A plain CALayer showing IOSurfaces (QEMU's present until now) is
  always composited, whatever the surface's kind (plain, lossless, IsDisplayable and the drawables'
  own surface properties), the colour tag, the background, filters, or Core Animation's private
  `allowsDisplayCompositing` switch. AVSampleBufferDisplayLayer frames are composited too.
- Nothing of another window covers any part of it. A 1x1 pt window at level 1000 in a corner is
  enough to composite every frame (the user's own Refresh Floor app keeps such a window on the
  M1 Max: nothing goes direct there while it runs). A notification dialog does the same: every
  earlier Air row of window-path and window-draw had our test app's Local Network prompt on screen.
  The pointer at the top edge of a full-screen Space shows the menu bar over the window, also.
- Not needed: the panel's own pixel size (the Air's scaled default mode, 2940x1912 drawn for a
  2560x1664 panel, goes direct: the display pipe scales), an untagged colour space (sRGB- and
  display-tagged frames go direct), no sublayers (QEMU's cursor layer, visible, stays direct), no
  windows at all (a window over the menu-bar strip, like Omanotch's, keeps it direct).
- Core Animation's own status of a CAMetalLayer (`displayCompositingInternalStatus`, private)
  reads 0 while it is shown directly and 0xe0017 while composited, so QEMU can log the state.

## Decision

1. With the switch on, the view's layer is a CAMetalLayer and QEMU's GL draws each frame into one
   of its drawables (their IOSurfaces bound as GL textures, once each) instead of into surfaces of
   its own. Everything else of the present stays: the vsync queue and its pacing (a drawable is
   presented where a surface was set as the layer's contents), the colour tags and EDR settings,
   the half-float kinds for HDR and Extra brightness, the band below a guest a few rows shorter
   than the window, the sublayers.
2. Drawables come from a queue of their own (`nextDrawable` can wait); QEMU's thread takes the
   spare one without waiting and treats "none yet" as all surfaces busy, as before (the frame
   waits a refresh). Three drawables at most.
3. No partial draws into drawables (each comes back holding an older frame): the partial present
   (ADR 0051) and lossless surfaces (ADR 0052) do not apply while it is on.
4. Off: needs the vsync present and a Metal device; GPU safe mode keeps the plain layer. If GL
   cannot draw into a drawable, the plain layer for the rest of the run (one warning).
5. Experimental and off by default: on the MacBook Air it saves no watts (below). Not merged until
   a measured gain where the composite costs more (half-float HDR frames at 120 Hz on an XDR
   display; the M1 Max needs its Refresh Floor window gone for that, the MBP an unlocked screen).
6. Lossless-compressed drawables (Core Animation's private `wantsIOSurfaceCompression`) do go
   direct, but GL cannot draw into them (`CGLTexImageIOSurface2D` refuses them, error 10008), so
   the drawables stay plain.

## Consequences

- The real VM on the Air (full screen, 60 Hz, on/off/on/off, same frame rates and pixels): the
  display shows the window itself (WindowServer 0 vs 58-113 GPU ms/s, its CPU 13-24 % vs 22-41 %,
  GPU busy 13-20 % vs 19-29 %), but the whole Mac uses the same or a little more: scrolling 4.29 vs
  4.27 W, a 1080p30 video 3.85 vs 3.79 W, the pointer moving 3.58 vs 3.44 W. QEMU's draw into plain
  drawables costs it 9-15 % more GPU time than into its lossless surfaces (ADR 0052), and the display
  reads a plain frame: the bytes WindowServer's composite of compressed surfaces saved.
- Bench (no VM, 60 frames a second): direct with plain drawables 2.69 / 2.66 W vs the lossless
  composite 2.76 / 2.77 W (-0.09 W); against plain surfaces it looked like -0.20 W (the lossless
  surfaces' own saving).
- It only works while nothing covers the VM: a notification, a menu, another app's always-on-top
  window (even 1x1 pt) composites again until it is gone; in a window nothing changes. qemu.log
  and `omacvm check` say which it is.
- Same frames and pixels as the plain layer: the same GL draw into the same kind of surface;
  captured with ScreenCaptureKit (work/direct-display). What the display pipe does with colours
  on the panel itself (it colour-matches sRGB frames instead of WindowServer) cannot be captured.
- It relies on one private Core Animation selector for the log only (checked with
  `respondsToSelector:`); the present itself is public API.
