# 0056: Direct to display: the VM's frames copied into a CAMetalLayer, so macOS can show the window itself

Status: proposed, built (`direct-display`), experimental and off by default ("Show directly on the display",
`directDisplay`; `OMACVM_GL_DIRECT=1`). Not merged before a measured watt gain. Notes and numbers:
work/tracks/direct-display.md.

## Context

Full-screen games and video players on a Mac can be shown by the display hardware itself:
WindowServer then neither reads the app's frame nor writes its own framebuffer for it
("direct to display"; Core Animation calls the layer "detached"). The VM's window never was:
WindowServer composited every frame (MacBook Air M2, 60 frames a second: 54-110 GPU ms/s and
30-40 % of a core for a window like the VM's; M1 Max, HDR at 120 Hz: 125-158 GPU ms/s).

What macOS 27 needs, measured on a MacBook Air M2 with a bench window like the VM's (no VM;
WindowServer's GPU time per second, and Metal's HUD, which says "Direct" or "Composited"):

- The layer is a CAMetalLayer. A plain CALayer showing IOSurfaces (QEMU's present until now) is
  always composited, whatever the surface's kind (plain, lossless, IsDisplayable and the drawables'
  own surface properties), the colour tag, the background, filters, or Core Animation's private
  `allowsDisplayCompositing` switch. AVSampleBufferDisplayLayer frames are composited too.
- Nothing of another window covers any part of it. A 1x1 pt window at level 1000 in a corner is
  enough to composite every frame (the user's own Refresh Floor app keeps such a window on the
  M1 Max). A notification dialog does the same: every earlier Air row of window-path and
  window-draw had our test app's Local Network prompt on screen. The pointer at the top edge of a
  full-screen Space shows the menu bar over the window, also.
- Not needed: the panel's own pixel size (the Air's scaled default mode, 2940x1912 drawn for a
  2560x1664 panel, goes direct: the display pipe scales), an untagged colour space (sRGB- and
  display-tagged frames go direct), no sublayers (QEMU's cursor layer, visible, stays direct), no
  windows at all (a window over the menu-bar strip, like Omanotch's, keeps it direct), plain
  drawables (lossless-compressed ones, Core Animation's private `wantsIOSurfaceCompression`, and
  half-float ones go direct too).
- Core Animation's own status of a CAMetalLayer (`displayCompositingInternalStatus`, private)
  reads 0 while it is shown directly and 0xe0017 while composited, so QEMU can log the state.

## Decision

1. With the switch on, the view's layer is a CAMetalLayer. QEMU draws each frame into its own
   surfaces as before (lossless-compressed 8-bit, ADR 0052; half float; partial draws, ADR 0051),
   and the commit thread copies the frame's surface with a Metal blit into one of the layer's
   drawables, instead of setting it as a plain CALayer's contents. Everything else of the present
   stays: the vsync queue and its pacing (it holds a frame's drawable with its surface), the
   colour tags and EDR settings on the layer, the band below a guest a few rows shorter than the
   window, the sublayers.
2. 8-bit drawables are lossless-compressed, as the 8-bit surfaces are (same gate: macOS 27, not
   with `OMACVM_GL_LOSSLESS=0`). Half-float drawables stay plain, as the half-float surfaces do
   until lossless half float is proven; `OMACVM_GL_DIRECT_COMPRESS=all` compresses them to
   measure it.
3. Drawables come from a queue of their own (`nextDrawable` can wait); QEMU's thread takes the
   spare one without waiting and treats "none yet", or one of an old size or kind, as all
   surfaces busy (the frame waits a refresh). The layer's size and kind change on that queue,
   never during a `nextDrawable`. A surface stays in use until the GPU has copied it. Three
   drawables at most.
4. Off: needs the vsync present and a Metal device; GPU safe mode keeps the plain layer. If Metal
   cannot read a frame, the plain layer for the rest of the run (one warning). Metal is not linked
   into QEMU: the device through `dlsym`, its classes by name.
5. Experimental and off by default until it saves watts where it is used: full screen, nothing on
   top. In a window (composited) it costs one more copy a frame.

## The first version (GL straight into the drawables), and why it changed

GL drew each frame straight into the drawables (their IOSurfaces bound as GL textures). GL cannot
draw into compressed drawables (`CGLTexImageIOSurface2D` refuses them, error 10008), so the
drawables were plain, and there were no partial draws. The real VM on the Air (full screen, 60 Hz,
on/off/on/off, same frame rates and pixels): the display showed the window itself (WindowServer 0
vs 58-113 GPU ms/s, its CPU 13-24 % vs 22-41 %, GPU busy 13-20 % vs 19-29 %), but the whole Mac used
the same or a little more: scrolling 4.29 vs 4.27 W, a 1080p30 video 3.85 vs 3.79 W, the pointer
moving 3.58 vs 3.44 W. QEMU's CPU, wakeups and energy were the same both ways (the drawable queue
costs nothing there); its GPU time was 9-15 % higher (plain drawables instead of its lossless
surfaces), and the display read a plain frame. Copying keeps the lossless surfaces and gives the
display a compressed frame. It also removed a freeze the first version could hit: each drawable
held a GL texture slot, and drawables Core Animation made anew could fill the five slots.

## Consequences

- Bench, Air, no VM, 60 frames a second, GL draws like QEMU (240 s windows): today's lossless
  composite 2.74 W; GL into plain drawables 2.64 W; GL into lossless surfaces + Metal copy into
  compressed drawables 2.69 W (all direct: WindowServer 0 GPU ms/s). The real VM's rows are in
  work/tracks/direct-display.md (the bench did not predict the first version's VM result).
- It only works while nothing covers the VM: a notification, a menu, another app's always-on-top
  window (even 1x1 pt) composites again until it is gone. qemu.log and `omacvm check` say which it
  is.
- Same frames and pixels: the same GL draw into the same surfaces, then a byte copy. Window
  captures (ScreenCaptureKit) compare them; what the display pipe does with colours on the panel
  itself (it colour-matches the frames instead of WindowServer) cannot be captured.
- It relies on two private Core Animation selectors (compressed drawables, and the status for the
  log), both checked with `respondsToSelector:`; the present itself is public API.
