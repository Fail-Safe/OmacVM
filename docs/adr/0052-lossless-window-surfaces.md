# 0052: The VM window's 8-bit surfaces are lossless-compressed

Status: accepted, built (`window-path`), on by default (`OMACVM_GL_LOSSLESS=0` keeps
plain surfaces). Notes and numbers: work/tracks/window-path.md.

## Context

Each guest frame is drawn by QEMU into one of the window's IOSurfaces (2940x1840 on a
MacBook Air: 21 MB) and read again by WindowServer for its composite. Measured on the
Air, the window costs about 0.5 W at 30 frames a second, and its GPU time is not what
costs: taking WindowServer's colour matching out of its composite (frames in the
display's colour space, tried and dropped: work/tracks/window-path.md) took a third off
its GPU time and nothing off the watts. What costs is moving the pixels. Apple GPUs
keep surfaces in a lossless-compressed layout when asked ('&BGA',
`kCVPixelFormatType_Lossless_32BGRA`); VideoToolbox and Apple's apps use it. Only the
CPU cannot read such a surface, and the present never reads its surfaces on the CPU
(the boot logo's readback reads the guest's texture). GL draws into one exactly (read
back through Core Image: 0 codes off, on an M1 Max, an M2 and an M4).

## Decision

1. The present's 8-bit surfaces are made through CoreVideo as lossless-compressed BGRA,
   tagged sRGB as before.
2. Half-float surfaces (HDR, Extra brightness) stay plain: there is no such layout for
   them here.
3. If one cannot be made or bound to GL, every surface is plain `BGRA` for the rest of
   the run (one warning in qemu.log). qemu.log names the kind when it changes.
4. Only on macOS 27 and newer for now: there it is checked on an M1 Max, an M2 and an M4
   (the picture as a layer's contents, the same pixels). No Mac here runs an older
   macOS, and a surface the system cannot show would be a black window, not an error.

## Consequences

- MacBook Air M2, the real VM full screen at 60 Hz, A/B/A/B: scrolling 4.45 W against
  4.65 W plain (-0.20 W, -4 %); a 1080p30 video the same within the gauge's noise. The
  same pixels on screen (a 144-patch page: all identical) and the same frame rates.
- QEMU's own draw takes 20-25 % less GPU time (a window like the VM's, no VM).
- How much a frame saves depends on the picture: flat areas and text compress much
  more than video.
- Nothing may read these surfaces on the CPU; test-present-lossless.sh checks for it.
