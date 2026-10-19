# 0049: HDR and 10-bit colour: the guest tone-maps into the Mac's headroom

Status: accepted, built (`hdr`), behind the app's experimental switch
"HDR and 10-bit colour" (`hdr`, off). Amends
[0021](0021-colour-deep-colour-hdr.md). Notes and numbers:
work/tracks/hdr.md.

## Context

0021 built the path: a 10-bit guest scanout (the guest's patched
virtio-gpu, `XRGB2101010`) becomes half-float IOSurfaces, tagged sRGB or
BT.2100 PQ, and the layer asks for EDR. It stayed hidden because:

- The guest driver was built by hand and replaced the stock one for good
  (`/lib/modules/K/updates`).
- QEMU trusted `OMACVM_GL_HDR` that every 10-bit frame was PQ; when
  half-float surfaces failed, PQ codes went into 8-bit sRGB surfaces.
- macOS tone-maps PQ itself (the layer's `toneMapMode` automatic). On the
  MacBook Pro's XDR panel at headroom 1, PQ 203 nits (BT.2408's SDR white)
  read 0.50 of the Mac's white, with or without `kIOSurfaceContentHeadroom`
  (`ifSupported` the same); with `toneMapMode` never it read 1.00. So the
  guest's desktop looked dim whenever the panel had less headroom than the
  content could reach: a bright panel, or no EDR at all.

## Decision

1. **The guest tone-maps, macOS does not.** While QEMU shows PQ the layer's
   `toneMapMode` is never. QEMU tells the guest the headroom of the window's
   display now (`maximumExtendedDynamicRangeColorComponentValue`, 1 = SDR
   white, at most the display's potential and 16) as `"edr"` on Virtual-1's
   entry in the layout on the display port: looked at once a second while
   HDR is wanted, sent when it moved by 10 % or more; 0 when PQ cannot be
   shown this run. `omacvm-display-sync` runs Virtual-1 with `bitdepth = 10,
   cm = "hdr", max_luminance = 203 x edr, sdr_max_luminance = 203`
   (Hyprland applies luminance changes without a modeset), or `bitdepth =
   10, cm = "srgb"` without a headroom. SDR content is exactly the Mac's
   white; HDR highlights are compressed by Hyprland into what the panel can
   show now. QEMU is the single source of truth; the guest follows.
2. **The 10-bit driver is dormant until a start asks for it.** `omacvm
   apply` builds it on every app VM (7 s; downloaded, patched and built as
   a user id of its own, root only installs it) into `/usr/local/lib/omacvm/virtio-gpu/K`,
   which depmod never sees; a modprobe `install` rule loads it only when
   the start's SMBIOS says `omacvm.deepcolor=1`, else (and on any failure)
   the stock driver. In the initramfs (mkinitcpio's kms hook puts virtio_gpu
   there) a 10-bit start loads nothing yet and udev loads it from the real
   root, through the loader. Turning the switch on needs one VM restart;
   VMs whose app never asks never load it. The pacman hook rebuilds it for new kernels.
3. **One app-wide switch**, shown only while a display can show HDR (EDR
   potential > 1). A start gets it only with such a display, outside GPU
   safe mode and with the IOSurface present (`Settings.hdrStart`, one
   qemu.log line). The app sends `omacvm.deepcolor=1` and
   `OMACVM_GL_EDR=1`, not 0021's names: an older guest or runtime would
   take those as "every 10-bit frame is PQ".

## Options not taken

- macOS tone-maps (automatic, with the content's headroom tagged): SDR white
  drops whenever the panel's headroom is short (measured above).
- The guest switches between PQ and sRGB as the window moves between HDR
  and SDR displays: a race of wrong-coloured frames at each switch. With a
  headroom of 1 PQ shows SDR exactly, so the guest stays PQ.
- A guest report of its colour mode to QEMU: more untrusted input for one
  case (a user's own rule for Virtual-1), which the check names.
- A per-VM feature in `features.tsv`: enable/disable, off.sh, the control
  centre and the questionnaire for something a start switches anyway.

## Consequences

- 10-bit colour: a 10-bit ramp reaches macOS's compositor with about twice
  the levels of the 8-bit path (dark ramp 117 vs 58 distinct levels).
- Few Linux apps send HDR (October 2026): GStreamer's `waylandsink` does;
  mpv 0.41 on OpenGL does not (mpv's master does, with `vo=gpu-next`; app
  VMs use `vo=gpu`), Chromium clips CSS PQ at SDR white, Firefox only for
  video behind a pref. Their HDR video shows as SDR, correctly.
- Only the main window: the other displays' windows stay 8-bit SDR
  (CAOpenGLLayer).
- macOS 26 deprecates `wantsExtendedDynamicRangeContent` for
  `preferredDynamicRange`; tested on macOS 15.7 only (the only HDR display
  here). `OMACVM_GL_EDR_HEADROOM=potential` sends the display's most if
  macOS kept the current headroom at 1.
- Half-float surfaces (8 bytes a pixel) and EDR while the VM shows: more
  memory and some battery.
