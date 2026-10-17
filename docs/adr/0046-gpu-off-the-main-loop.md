# 0046: The VM's GPU work lets go of the BQL, then leaves the main loop

Status: accepted, built (`gpu-thread`), off by default (`gpuOffMainLoop`).
Option 2 not built. Builds on [0011](0011-async-fences.md),
[0026](0026-fence-tests-off-the-render-threads-lock.md),
[0036](0036-sound-main-loop-qos.md) and [0045](0045-sound-own-thread.md).

## Context

OmacVM.app's QEMU runs all of virglrenderer in its main loop: every virtio-gpu
command (shader compiles, draws, uploads, readbacks, Venus submits), the
display's present and the fence answers run in bottom halves, with QEMU's big
lock (BQL) held. While Chromium opens a window or scrolls, those batches take
100-350 ms. On HVF every vCPU exit (WFI, MMIO, timer) takes the BQL, so during
such a batch the vCPUs that leave the guest wait too: the worst vCPU wait
equalled the worst main-loop stall in every run of the audio lane (ADR 0045).
The guest freezes, its sound streams run dry, and input waits.

Upstream QEMU has no thread or iothread option for virtio-gpu and keeps GL on
the main loop on purpose (QEMU 11.1.1; upstream to 2026-10-13). Its offload,
vhost-user-gpu, is a separate process without blob resources (no Venus) that
hands scanouts over as Linux dmabufs. virglrenderer needs all its calls on one
thread, but not on any particular one; its own threads (fence sync, Venus,
VideoToolbox) do not use the BQL.

## Options

1. Let go of the BQL while virgl works, on the same thread: commands that touch
   only virgl run as one unlocked run; display, DMA mapping, memory regions and
   device state keep the BQL. Same thread and GL contexts as today.
2. A GPU thread of its own (an IOThread with its own AioContext) that owns
   virgl, every GL context and the present engine. Also frees the main loop's
   timers, disk and network during GPU work. Moves GL to a new thread and needs
   1's split of the commands anyway.
3. vhost-user-gpu in another process: no blobs/Venus, dmabuf display, and our
   Venus heap pointers and IOSurface present would need a Mach-port protocol.
4. Shorten each stall at its cause (shader cache, PBO uploads, fewer
   readbacks): partly done; the guest decides what it sends, and Apple's GL has
   no parallel shader compile.
5. vCPU exits without the BQL in HVF: MMIO exits still need it; core
   accelerator code.

## Decision

Option 1 first (`OMACVM_GPU_UNLOCKED=1`), then option 2 on top of it if the
numbers after 1 say the main loop's own stalls still matter.

Option 1's rules:

- Unlocked: SUBMIT_3D, resource create 2D/3D and host blobs, transfers,
  context create/destroy/attach/detach, capsets. With the BQL: set scanout,
  flush (console and IOSurface present), attach/detach backing and blobs with
  guest pages (DMA mapping), map/unmap blob, unref, display info, EDID,
  renderer init and reset.
- Answers of unlocked commands are written at once and pushed to the queue
  with the BQL after the run.
- A GPU lock: the main loop holds it during an unlocked run and never holds
  it together with the BQL; the AppKit thread takes it before the BQL around
  the virgl texture draws of extra displays and the layer fallback.
- The BH's re-entrancy guard is off during an unlocked run (a vCPU's queue
  kick would be refused otherwise); nothing there maps guest memory.
- virgl's GL context callback no longer reads the window's 2D surface (which
  the console replaces with the BQL held); it takes the pixel depth from an
  atomic set with the surface.
- A device reset waits for a run in progress; the present BH runs only on the
  main thread (iohandler context).
- `gpuOffMainLoop` turns it on, `gpuMainLoop` keeps today's path whatever the
  default, GPU safe mode always keeps it; qemu.log and `omacvm check` say
  which ran.

## Consequences

- vCPUs, the AppKit thread (input, the window) and the sound's own thread no
  longer wait for the GPU's batches. Mac mini M4, 8 vCPUs, bench lock, a
  throwaway spike of this option against the same build (one run each, so
  far): worst main-loop BQL hold while new Chromium windows open 107 ms -> 1 ms,
  worst vCPU wait 107 ms -> 1 ms, vCPU waits of 20 ms or more 13 -> 0, worst
  guest freeze 18 ms -> 0; glmark2 40 ms -> 1 ms; browsing with the sound on
  its own thread: worst vCPU wait 58 ms -> 4 ms. Every long hold before was a
  single SUBMIT_3D. Numbers and method: work/tracks/gpu-thread.md.
- With it the VM's frames reach the present steadily, and its jitter buffer
  (ADR 0020) then kept one or two extra frames: the guest's display clock
  runs about a frame a second faster than the Mac's, the once-a-second trim
  only held the queue where it was, and virgl's BQL holds no longer made the
  guest miss the frames that used to drain it (60 Hz, Chromium scrolling:
  key to screen p50 36-62 ms vs 33-34). So the app sets
  `OMACVM_GL_TRIM=quarter` with it: a frame left over after every refresh for
  a quarter second is skipped. Then, pooled over interleaved runs: 60 Hz
  scrolling p50 34.8 / p95 45.5 ms (today 37.3 / 69.2), 120 Hz scrolling
  24.8 / 36.9 (today 25.5 / 34.0; the tail is Mac-side input delivery in
  runs of both). The trim stays off without gpuOffMainLoop.
- Venus (KosmicKrisp): vkcube, vkmark (3131 vs 3123), glmark2 (2074 vs
  2065) and WebGPU in Chromium (1169 vs 1122 GFLOPS) as before; the worst
  BQL hold of that run 779 -> 14 ms (one Venus host blob of vkmark's, made
  without the BQL now). The sound on its own thread while browsing: no
  breaks on either path, worst vCPU wait 301 -> 1.2 ms. 20 rounds of GPU
  process kills, desktop restarts, VM resets and shutdowns under load: all
  came back.
- Off by default; the user decides after their own test.
- One BQL drop/take and at most one extra queue notification per run.
- The guest may rewrite a command while QEMU reads it twice; the type (and a
  blob's kind) a run picked a command for is checked again where it runs, so
  a command that needs the BQL is refused instead of run without it.
- Carry-over: upstream QEMU reworked scanout handling in virtio-gpu after our
  pin (September 2026: virtio_gpu_disable_scanout_for_resource, dmabuf release
  on unref). The next QEMU update has to carry this change's hunks in
  virtio-gpu.c, virtio-gpu-gl.c and virtio-gpu-virgl.c over by hand;
  src/tests/gpu-unlocked.sh checks what must stay true.
