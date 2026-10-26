# 0054: The pointer on its own layer: virtio-gpu's cursor plane without hotspots

Status: accepted, built (`guest-scanout`), behind the app's experimental
switch "Pointer on its own layer" (`pointerPlane`, off). Uses the per-start
driver of [0049](0049-hdr-guest-tone-maps.md). Notes and numbers:
work/tracks/guest-scanout.md.

## Context

Omarchy's Hyprland draws the pointer into its frames (a software cursor) on
virtio-gpu. Every pointer move is then a whole frame: Hyprland renders its
work buffer and copies it into the next scanout buffer, and QEMU draws that
buffer into the window's surface. On a 3024x1896 screen that is the same
GPU work as any other full frame (6.5 ms per guest frame with HDR on an
M1 Max, tracks/m1-power.md), at up to 120 moves a second.

virtio-gpu has a cursor plane, and QEMU already shows its image as a layer
over the VM's window (`cocoa.m` cursorLayer, placed by the plane's top
left). Hyprland does not use it: since Linux 6.8 a virtual GPU
(`DRIVER_CURSOR_HOTSPOT`) hides its cursor plane from atomic clients that do
not set `DRM_CLIENT_CAP_CURSOR_PLANE_HOTSPOT`, and Hyprland's aquamarine
does not set it (nor the HOTSPOT_X/Y properties). That rule exists for hosts
that place the cursor by its hotspot at their own mouse position.

## Decision

1. **OmacVM's virtio-gpu build gets a module option `cursor_plane`** (off by
   default; `linux-virtio-gpu-cursor-plane.patch` after the deep-colour
   patch). With it the probe clears `DRIVER_CURSOR_HOTSPOT` from the device's
   features, so the plane shows to every client, as before Linux 6.8. Every
   output keeps its cursor plane, and QEMU shows each output's image over
   that output's window (the main window's cursor layer; a pointer layer
   over each other display's window, `omacvm-cocoa-pointer-heads*.patch`).
   (3.2.3 gave only the first output a plane, meaning the others to keep
   Hyprland's software pointer. They got none: aquamarine 0.15.1's
   `CDRMOutput::setCursor` accepts a cursor for a CRTC without a cursor
   plane and its commit leaves it out, so Hyprland's hardware cursor
   "works" there and it draws no pointer itself. #554: no pointer on an
   external display.)
2. **The app's switch sends `omacvm.pointerplane=2`** (3.2.3 sent `=1`; a
   guest loader takes only `2`, the value of an app whose QEMU shows the
   pointer on every display, so an app and a guest from different sides of
   #554 fall back to Hyprland's own pointer, never to none). The loader
   (`omacvm-virtio-gpu-load`) then loads OmacVM's driver with
   `cursor_plane=1` (also on an 8-bit start), never together with the hidden
   `macPointer` (`omacvm.hwcursor=1`): that one makes the image the Mac's
   own cursor, which needs the hotspot this plane does not get. The 10-bit
   formats come only with `deep_color=1` (an HDR start, as in #520), so on
   an 8-bit start OmacVM's driver differs from the stock one by the cursor
   plane only.
3. **Hyprland follows the running driver, not the switch.** `omacvm_app.lua`
   reads `/sys/module/virtio_gpu/parameters/cursor_plane`; with `Y` it sets
   `cursor:no_hardware_cursors = 0` and `use_cpu_buffer = 1` (a dumb buffer
   the driver copies to the host with the plane update). A start that fell
   back to the stock driver stays as before. `omacvm check` says which
   (`Pointer layer`).
4. **Same picture.** The image is Hyprland's own cursor image at the same
   place; QEMU draws it 1:1 over the window (the layer is sized in guest
   pixels), premultiplied as virtio-gpu sends it (QEMU's layer took it as
   straight alpha before: the white outline's soft edge came out up to 55
   levels darker). The pointer is not in the guest's frames any more; in-guest
   screenshots and recordings get it the way they do on any hardware cursor
   (Hyprland adds it to the copy when the client asks for the pointer).
5. **As bright as the frames.** With Extra brightness ([0050](0050-extra-brightness.md))
   the frames show SDR white at up to 2x, and an 8-bit image would stay at
   1x (a white pointer at half the brightness of the page under it). While
   the frames are boosted, QEMU makes the image in half floats, extended
   linear sRGB, decoded like the frames and times their gain, and shows the
   layer with EDR as theirs (`omacvm-cocoa-pointer-bright*.patch`); it
   follows the gain when it moves and goes back to the 8-bit image when the
   boost stops. HDR without Extra brightness needs nothing: SDR white is the
   Mac's 1.0 there, as the 8-bit image.

## Consequences

- A pointer move no longer renders a frame in the guest; Hyprland still
  commits one per move (aquamarine's atomic `moveCursor` schedules a frame),
  so QEMU still presents the unchanged frame. Measured: see the track notes
  and the PR (QEMU GPU time and whole-Mac watts, A/B).
- Experimental and off by default: hotspot-less placement relies on QEMU
  drawing the image itself; a cursor bigger than the plane (64x64) or
  Hyprland's zoom goes back to the software pointer by Hyprland's own rules.
- What was checked: whole-window pixels on a MacBook Air (SDR, 60 Hz),
  today's setup (stock driver) against the switch on, a boot each: only the
  pointer's soft edge differed (107-123 pixels, up to 55 levels: the
  straight-alpha bug in 4.); after the fix 0 and 3 pixels (1 level, the
  rounding two pictures of today's setup show too). Extra brightness: on
  the mini, a boosted layer with the patch's pointer image and an HDR
  capture (page 2.00, the new pointer image 2.00, the old 8-bit one 1.00).
  Not yet checked on screen: HDR at 120 Hz and Extra brightness on an XDR
  panel (queued on the M1 Max, tracks/m1-bench-queue.md). The pointer's soft edge is blended by macOS over the
  frames, not by the guest into them: with Extra brightness on, those few
  edge pixels may differ a little.
- The pointer layer moves when the guest moves the plane, not with the
  frames: while dragging a window or selecting text it can be a frame ahead
  of what it drags (as the Mac's own pointer). Check a drag before the
  default changes.
- The layer uses one scale for both axes. While the window size and the
  guest's mode differ (a resize, until the guest follows), the frames
  stretch on each axis and the pointer can sit a little off for that time.
- Direct scanout of full-screen windows was measured in the same lane
  (QEMU GPU -30 % for mpv full screen) and not built: in Omarchy's real use
  it would change pixels (mpv's colour description, Omarchy's 0.985 window
  opacity) or never engage (Chromium's subsurfaces and buffers without an
  opaque region, the notifications layer while a toast shows).
