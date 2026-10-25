# 0049: HDR and 10-bit colour: the guest tone-maps into the Mac's headroom

Status: accepted, built (`hdr`), behind the app's experimental switch
"HDR and 10-bit colour" (`hdr`, off). Amends
[0021](0021-colour-deep-colour-hdr.md). Amended by
[0050](0050-extra-brightness.md) (2026-10-21): while Extra brightness is
on, the guest is told headroom 1 and its PQ frames end at SDR white.
Notes and numbers: work/tracks/hdr.md.

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
   white. HDR windows are clipped at `max_luminance`, not tone-mapped by
   Hyprland (amended 2026-10-19, below): Chrome and Chromium fit HDR into
   the headroom themselves; a client that does not is clipped there
   (below). QEMU is the single source of truth; the guest follows.
2. **The 10-bit driver is dormant until a start asks for it.** (Amended
   2026-10-25 for [0051](0051-partial-present.md): OmacVM's driver also
   carries Linux 7.4's damage fix and loads at every start where that fix
   is ours, that is on kernels before 7.4; the 10-bit formats stay behind
   the module option `deep_color=1`, passed only for a start that asks, so
   an 8-bit start offers the stock formats. A patch that does not fit a
   kernel is left out of that kernel's build (deep colour stays; the
   builder's `without` file and `--status` say which), and the loader
   passes only the options the build has. In the initramfs nothing loads
   for any start (as for 10-bit starts before): QEMU's boot logo stays until
   udev loads the driver from the real root, so a question or an emergency
   shell in the initramfs would not show (app VMs have no disk encryption;
   the VMs have no firmware framebuffer for Linux to use there). A real root
   without the loader gets the stock driver. What follows is the state
   before.) `omacvm
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
  VMs use `vo=gpu`), Firefox only for video behind a pref. Their HDR video
  shows as SDR, correctly.
- Chrome and Chromium (amended 2026-10-19, user report on a MacBook Air): on
  the HDR output they draw the whole window in PQ, SDR white at 203 nits and
  HDR video already tone-mapped into the headroom, and tag it `luminances(0,
  1000, 203)`. Hyprland 0.56 tone-maps any window above `max_luminance` with
  a curve that also lowers SDR white (`tonemap.glsl`: 0.52 of it at headroom
  1, 0.64 at 2): every page looked gray. So while Virtual-1 is PQ,
  `omacvm-display-sync` gives all windows the rule `tonemap = "clamp"` (back
  to `"on"`, Hyprland's default, when PQ ends; `omacvm_app.lua` sets it
  again after a config reload). Measured on the scanout: Chrome's white 203
  nits as an SDR client's (was 105), a 1000-nit video bar 390 nits with
  `max_luminance` 406 (headroom 2; was 206). SDR windows are not tone-mapped
  either way; mpv (`gpu-next`) tags the output's own maximum and is not
  touched; Obsidian 1.14.4 (Electron) draws SDR. Every window, not a list of
  browser names: any app on a recent Chromium does the same. Lost: a client
  that sends raw PQ above the headroom (GStreamer's `waylandsink`) is
  clipped there instead of compressed; its SDR white is now right (it was at
  half too). The rule is on every display: such a client on another Mac
  display (8-bit SDR) while the main window is HDR is clipped at that
  display's SDR white (Chrome and mpv draw SDR there). Notes:
  work/tracks/hdr-chrome.md.
- Only the main window: the other displays' windows stay 8-bit SDR
  (CAOpenGLLayer).
- macOS 26 deprecates `wantsExtendedDynamicRangeContent` for
  `preferredDynamicRange`; tested on macOS 15.7 only (the only HDR display
  here). `OMACVM_GL_EDR_HEADROOM=potential` sends the display's most if
  macOS kept the current headroom at 1.
- Half-float surfaces (8 bytes a pixel) and EDR while the VM shows: more
  memory and some battery.
- Amended 2026-10-25 (hdr-pass): with Virtual-1 in PQ and SDR white at
  203 nits, Hyprland 0.56 keeps an unmodified SDR copy of every frame for
  screen sharing by default (`render:keep_unmodified_copy` auto): each
  window is drawn twice. `omacvm_app.lua` sets it to 0 (unless the user
  set it in their own Hyprland files), so the copy is made only while
  something captures the output. The screen, screenshots and screen
  shares are the same; an HDR frame costs the GPU 10-19 % less (mini,
  QEMU GPU ms/s; M1 Max at 120 Hz -17 %).
