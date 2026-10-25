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
   features, so the plane shows to every client, as before Linux 6.8. Only
   the first output gets a cursor plane then: QEMU shows the image over its
   main window only, and other outputs (external displays) keep Hyprland's
   software pointer.
2. **The app's switch sends `omacvm.pointerplane=1`.** The loader
   (`omacvm-virtio-gpu-load`) then loads OmacVM's driver with
   `cursor_plane=1` (also on an 8-bit start), never together with the hidden
   `macPointer` (`omacvm.hwcursor=1`): that one makes the image the Mac's
   own cursor, which needs the hotspot this plane does not get.
3. **Hyprland follows the running driver, not the switch.** `omacvm_app.lua`
   reads `/sys/module/virtio_gpu/parameters/cursor_plane`; with `Y` it sets
   `cursor:no_hardware_cursors = 0` and `use_cpu_buffer = 1` (a dumb buffer
   the driver copies to the host with the plane update). A start that fell
   back to the stock driver stays as before. `omacvm check` says which
   (`Pointer layer`).
4. **Same picture.** The image is Hyprland's own cursor image at the same
   place; QEMU draws it 1:1 over the window (the layer is sized in guest
   pixels). The pointer is not in the guest's frames any more; in-guest
   screenshots and recordings get it the way they do on any hardware cursor
   (Hyprland adds it to the copy when the client asks for the pointer).

## Consequences

- A pointer move no longer renders a frame in the guest; Hyprland still
  commits one per move (aquamarine's atomic `moveCursor` schedules a frame),
  so QEMU still presents the unchanged frame. Measured: see the track notes
  and the PR (QEMU GPU time and whole-Mac watts, A/B).
- Experimental and off by default: hotspot-less placement relies on QEMU
  drawing the image itself; a cursor bigger than the plane (64x64) or
  Hyprland's zoom goes back to the software pointer by Hyprland's own rules.
- Direct scanout of full-screen windows was measured in the same lane
  (QEMU GPU -30 % for mpv full screen) and not built: in Omarchy's real use
  it would change pixels (mpv's colour description, Omarchy's 0.985 window
  opacity) or never engage (Chromium's subsurfaces and buffers without an
  opaque region, the notifications layer while a toast shows).
