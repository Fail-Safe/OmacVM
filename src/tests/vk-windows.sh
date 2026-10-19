#!/bin/bash
# Offline checks for Vulkan windows without a copy (ADR 0047; no VM, no runtime build):
#  - the patch is pinned and applied after the CPU copy it falls back to
#  - the app's switch (vkWindowsNoCopy, on by default; GPU safe mode and vkWindowsCopy keep
#    the copy) sets QEMU's OMACVM_VK_WINDOWS=iosurface, which the patch reads
#  - the patch's log lines are the ones omacvm check reads, and check.sh's verdicts
#  - the build runs the re-stride test
# Exit 0 when every check passes.
set -uo pipefail
R=$(cd "$(dirname "$0")/../.." && pwd)
PD=$R/app/runtime/patches
P=$PD/virgl-vulkan-windows-iosurface.patch
B=$R/app/runtime/build-qemu-gpu-runtime.sh
RUNNER=$R/app/app/Sources/OmacVM/Runner.swift
MODEL=$R/app/app/Sources/OmacVM/Model.swift
CHECK=$R/src/cmd/check.sh
FAIL=0; N=0
ok() { N=$((N + 1)); printf '  ok    %s\n' "$1"; }
bad() { N=$((N + 1)); FAIL=$((FAIL + 1)); printf '  FAIL  %s\n' "$1"; }
check() { local what=$1; shift; if "$@" >/dev/null 2>&1; then ok "$what"; else bad "$what"; fi; }

check "the patch is pinned in SHA256SUMS" grep -q ' virgl-vulkan-windows-iosurface.patch$' "$PD/SHA256SUMS"
line() { grep -n "patches/$1.patch\"" "$B" | head -1 | cut -d: -f1; }
lc=$(line virgl-set-type-without-egl); lu=$(line virgl-const-uniform-buffer); lv=$(line virgl-vulkan-windows-iosurface)
check "the runtime build applies it after the CPU copy and the last virgl patch" \
  test -n "$lv" -a "${lv:-0}" -gt "${lc:-0}" -a "${lv:-0}" -gt "${lu:-0}"
check "the patch has the header (what, why, upstream, test)" \
  sh -c "grep -q '^What:' '$P' && grep -q '^Why:' '$P' && grep -q '^Upstream:' '$P' && grep -q '^Test:' '$P'"
check "the app's switch is on by default" grep -qF 'return d.object(forKey: "vkWindowsNoCopy") as? Bool ?? true' "$MODEL"
check "GPU safe mode and vkWindowsCopy keep the copy" grep -qF 'if gpuSafeMode || d.bool(forKey: "vkWindowsCopy") { return false }' "$MODEL"
check "the launcher sets OMACVM_VK_WINDOWS=iosurface for it" grep -qF 'env["OMACVM_VK_WINDOWS"] = "iosurface"' "$RUNNER"
check "the patch reads OMACVM_VK_WINDOWS=iosurface" sh -c "grep -qF '+   const char *env = getenv(\"OMACVM_VK_WINDOWS\");' '$P' && grep -qF '!strcmp(env, \"iosurface\")' '$P'"
check "the patch takes KosmicKrisp only" grep -qF 'driver_props.driverID != VK_DRIVER_ID_MESA_KOSMICKRISP' "$P"
check "the patch logs both ways for omacvm check" \
  sh -c "grep -qF 'vkr_log(\"Vulkan windows are IOSurfaces (OMACVM_VK_WINDOWS=iosurface)\");' '$P' && grep -qF 'vkr_log(\"Vulkan windows are copied (no IOSurfaces: %s)\", why);' '$P'"
check "the build runs the re-stride test" grep -q 'run_test("test-vulkan-window-restride", "vrend_blitter.c")' "$R/app/runtime/Tests/virgl/run-regressions.py"

# check.sh's verdict for each line virglrenderer can write (its own case, run here).
verdict() {   # LOG_LINE -> the status check.sh prints
  local miclog TYPE=app out
  miclog=$(mktemp); printf '%s\n' "$1" > "$miclog"
  ok() { echo "ok:$2"; }; warn() { echo "warn:$2"; }
  out=$(eval "$(sed -n '/^# Vulkan windows without a copy this run/,/^fi$/p' "$CHECK")")
  rm -f "$miclog"; echo "$out"
}
check "check.sh: IOSurfaces are ok" grep -q "^ok:without a copy" <<<"$(verdict 'vkr: Vulkan windows are IOSurfaces (OMACVM_VK_WINDOWS=iosurface)')"
check "check.sh: asked but copied warns with the reason" grep -q "^warn:.*no IOSurfaces: the Vulkan driver is not KosmicKrisp" \
  <<<"$(verdict 'vkr: Vulkan windows are copied (no IOSurfaces: the Vulkan driver is not KosmicKrisp)')"
check "check.sh: switch off prints nothing" test -z "$(verdict 'context 8 (Hyprland) shows a Vulkan image by CPU copy')"

echo "vk-windows: $((N - FAIL))/$N ok"
exit $(( FAIL > 0 ))
