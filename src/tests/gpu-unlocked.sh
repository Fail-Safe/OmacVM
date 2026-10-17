#!/bin/bash
# Offline checks for the VM's GPU work without QEMU's big lock (ADR 0046; no VM, no QEMU build):
#  - the three patches are pinned and applied in order, before the App Nap patch
#  - the launcher, QEMU's patch and omacvm check use the same switch and log lines
#    (gpuOffMainLoop -> OMACVM_GPU_UNLOCKED=1; "virtio-gpu: virgl runs with/without the BQL")
#  - the commands that may run without the BQL never include one that needs it (display,
#    DMA mapping, memory regions, unref), and the type is checked again where a command runs
#  - both AppKit draws of virgl textures take the GPU lock, before the BQL
# Exit 0 when every check passes.
set -uo pipefail
R=$(cd "$(dirname "$0")/../.." && pwd)
PD=$R/app/runtime/patches
B=$R/app/runtime/build-qemu-gpu-runtime.sh
U=$PD/qemu-virtio-gpu-virgl-unlocked.patch
L=$PD/qemu-console-gl-render-lock.patch
P0=$PD/qemu-cocoa-gl-present-bh-main-thread.patch
RUNNER=$R/app/app/Sources/OmacVM/Runner.swift
MODEL=$R/app/app/Sources/OmacVM/Model.swift
CHECK=$R/src/cmd/check.sh
FAIL=0; N=0
ok() { N=$((N + 1)); printf '  ok    %s\n' "$1"; }
bad() { N=$((N + 1)); FAIL=$((FAIL + 1)); printf '  FAIL  %s\n' "$1"; }
check() { local what=$1; shift; if "$@" >/dev/null 2>&1; then ok "$what"; else bad "$what"; fi; }

for p in qemu-cocoa-gl-present-bh-main-thread qemu-console-gl-render-lock qemu-virtio-gpu-virgl-unlocked; do
  check "$p.patch is pinned in SHA256SUMS" grep -q " $p.patch$" "$PD/SHA256SUMS"
done
line() { grep -n "patches/$1.patch\"" "$B" | head -1 | cut -d: -f1; }
l0=$(line qemu-cocoa-gl-present-bh-main-thread); l1=$(line qemu-console-gl-render-lock)
l2=$(line qemu-virtio-gpu-virgl-unlocked); nap=$(line omacvm-cocoa-no-app-nap)
vs=$(line qemu-cocoa-gl-present-vsync); fence=$(grep -n 'patches/qemu-cocoa-gl-async-fence.patch' "$B" | head -1 | cut -d: -f1)
check "runtime build applies them in order, after the present and fence patches, before App Nap" \
  test -n "$l0" -a -n "$l1" -a -n "$l2" -a "${l0:-0}" -gt "${vs:-0}" -a "${l0:-0}" -gt "${fence:-0}" \
       -a "${l1:-0}" -gt "${l0:-0}" -a "${l2:-0}" -gt "${l1:-0}" -a "${l2:-0}" -lt "${nap:-0}"
check "the present BH runs on the iohandler context (main loop thread only)" \
  grep -qF '+        present_bh = aio_bh_new(iohandler_get_aio_context(),' "$P0"

# The switch: app setting -> environment -> QEMU, safe mode and gpuMainLoop keep the BQL.
check "QEMU's patch reads OMACVM_GPU_UNLOCKED" grep -qF 'getenv("OMACVM_GPU_UNLOCKED")' "$U"
check "launcher sets OMACVM_GPU_UNLOCKED=1 for gpuOffMainLoop" grep -qF 'env["OMACVM_GPU_UNLOCKED"] = "1"' "$RUNNER"
check "gpuOffMainLoop is off by default" grep -qF 'return d.object(forKey: "gpuOffMainLoop") as? Bool ?? false' "$MODEL"
check "GPU safe mode and gpuMainLoop keep the BQL" grep -qF 'if gpuSafeMode || d.bool(forKey: "gpuMainLoop") { return false }' "$MODEL"
check "no unlocked runs with polled fences" grep -qF 'gl->unlocked = want && virgl_poll_fd >= 0;' "$U"
for l in 'virtio-gpu: virgl runs without the BQL' 'virtio-gpu: virgl runs with the BQL'; do
  check "patch logs '$l'" grep -qF "\"$l" "$U"
done

# check.sh's verdict for each line QEMU can write (its own case, run here).
verdict() {   # LOG_LINE -> the status check.sh prints
  local miclog TYPE=app out
  miclog=$(mktemp); printf '%s\n' "$1" > "$miclog"
  ok() { echo "ok:$2"; }; warn() { echo "warn:$2"; }
  out=$(eval "$(sed -n '/^# Whether the VM.s GPU work ran without/,/^fi$/p' "$CHECK")")
  rm -f "$miclog"; echo "$out"
}
check "check.sh: unlocked is ok" grep -q "^ok:virgl's GPU-only commands run without" \
  <<<"$(verdict 'OmacVM: info: virtio-gpu: virgl runs without the BQL')"
check "check.sh: the default is ok" grep -q "^ok:virgl runs with QEMU's big lock" \
  <<<"$(verdict 'OmacVM: info: virtio-gpu: virgl runs with the BQL')"
check "check.sh: asked but fences polled warns" grep -q "^warn:" \
  <<<"$(verdict 'OmacVM: warning: virtio-gpu: virgl runs with the BQL (fences polled: no unlocked runs)')"
check "check.sh: an old runtime prints nothing" test -z "$(verdict 'OmacVM: info: virtio-gpu: virgl fences reported by the sync thread')"

# What may run without the BQL: the classifier's cases, nothing that needs the BQL.
cases=$(sed -n '/^+bool virtio_gpu_virgl_cmd_unlocked/,/^+}/p' "$U" | grep -o 'VIRTIO_GPU_CMD_[A-Z0-9_]*' | sort -u)
check "the classifier names its commands" test -n "$cases"
for c in SET_SCANOUT SET_SCANOUT_BLOB RESOURCE_FLUSH RESOURCE_ATTACH_BACKING RESOURCE_DETACH_BACKING \
         RESOURCE_MAP_BLOB RESOURCE_UNMAP_BLOB RESOURCE_UNREF GET_DISPLAY_INFO GET_EDID; do
  check "$c keeps the BQL" test -z "$(grep -x "VIRTIO_GPU_CMD_$c" <<<"$cases")"
done
check "blobs run unlocked only without guest pages (HOST3D)" \
  grep -qF 'le32_to_cpu(cblob.blob_mem) != VIRTIO_GPU_BLOB_MEM_HOST3D) {' "$U"
check "the type is checked again where a command runs (guest rewrites)" \
  grep -qF 'if (g->unlocked_run && cmd->cmd_hdr.type != cmd->run_type) {' "$U"
check "the blob kind is checked again where a blob is made" \
  grep -qF 'if (g->unlocked_run && cblob.blob_mem != VIRTIO_GPU_BLOB_MEM_HOST3D) {' "$U"
check "no run during a device reset" grep -qF 'if (!g->resetting && vgc->cmd_unlocked && vgc->cmd_unlocked(g, cmd)) {' "$U"
check "a run gives the BQL up before it takes the GPU lock" \
  bash -c "sed -n '/^+static void virtio_gpu_run_begin/,/^+}/p' '$U' | tr -d '\n' | grep -q 'bql_unlock();+    qemu_console_gl_render_lock();'"
check "and the GPU lock back before it takes the BQL again" \
  bash -c "sed -n '/^+static void virtio_gpu_run_end/,/^+}/p' '$U' | tr -d '\n' | grep -q 'qemu_console_gl_render_unlock();+    bql_lock();'"

# The GPU lock: both AppKit draws of virgl textures, before the BQL.
check "two draws take the GPU lock" test "$(grep -c '^+    qemu_console_gl_render_lock();' "$L")" = 2
check "each takes it before the BQL" \
  test "$(awk '/qemu_console_gl_render_lock\(\);/ {n = 3; next} n && /BQL_LOCK_GUARD\(\);/ {c++; n = 0} n {n--} END {print c + 0}' "$L")" = 2

echo "gpu-unlocked: $((N - FAIL)) of $N checks passed"
exit $((FAIL > 0))
