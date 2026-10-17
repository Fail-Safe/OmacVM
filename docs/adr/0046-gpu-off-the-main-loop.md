# 0046: The VM's GPU work lets go of the BQL, then leaves the main loop

Status: draft (`gpu-thread`, design phase; numbers in work/tracks/gpu-thread.md
on the mini). Builds on [0011](0011-async-fences.md),
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
- Open before it can be the default: at 60 Hz with a busy page beside, the
  spike's key-to-screen latency was worse (p50 36-62 ms vs 33-34 ms), all of
  it between the guest's flush and the screen; glmark2 scores and the Venus
  configuration are not measured yet.
- The main loop itself is still busy during a batch: its timers (the
  main-loop sound path, the present timer, GUI refresh), libslirp, NVMe
  completions and QMP wait as before. Option 2 is for those.
- GL threading on macOS does not change in this step.
- Extra displays and the layer fallback wait for the GPU lock during a long
  batch, as they wait for the BQL today.
- One BQL drop/take and at most one extra queue notification per run.
