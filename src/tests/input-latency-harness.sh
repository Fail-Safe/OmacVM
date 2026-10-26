#!/bin/bash
# input-latency-vm.sh without a VM: its stage split on a made-up QEMU trace, and it refuses the
# person's own VMs (~/OmacVM) before anything else.
#   src/tests/input-latency-harness.sh
set -uo pipefail
R=$(cd "$(dirname "$0")/../.." && pwd)
H=$R/src/tests/input-latency-vm.sh
fail=0
W=$(mktemp -d "${TMPDIR:-/tmp}/il-harness.XXXXXX")
trap 'rm -rf "$W"' EXIT
expect() {   # WHAT WANT GOT
  if [[ $2 == "$3" ]]; then echo "ok   $1"; else echo "FAIL $1: want '$2', got '$3'"; fail=1; fi
}

# The split's parser, as the harness runs it (its python heredoc in breakdown()).
awk '/^python3 - "\$1" "\$2" <<.PY.$/ {f = 1; next} /^PY$/ {f = 0} f' "$H" > "$W/split.py"
[[ -s $W/split.py ]] || { echo "FAIL the harness's parser not found"; exit 1; }

# Fence 0x5 was asked and answered once before; asked again after Hyprland's submit, it is
# answered 2 ms later. The answer before it was asked is not its answer.
mkdir -p "$W/fence"
cat > "$W/fence/qemu.log" <<'LOG'
2026-10-25T05:00:00.000000Z virtio_gpu_cmd_ctx_create ctx 0x2, name Hyprland
2026-10-25T05:00:00.000100Z virtio_gpu_fence_ctrl fence 0x5, type 0x207
2026-10-25T05:00:00.000900Z virtio_gpu_fence_resp fence 0x5
2026-10-25T05:00:01.000000Z input_event_key_qcode down 1
2026-10-25T05:00:01.001000Z virtio_gpu_cmd_ctx_submit ctx 0x2, size 100
2026-10-25T05:00:01.001010Z virtio_gpu_fence_ctrl fence 0x5, type 0x207
2026-10-25T05:00:01.003000Z virtio_gpu_fence_resp fence 0x5
2026-10-25T05:00:01.003200Z virtio_gpu_cmd_res_flush res 0x1
2026-10-25T05:00:01.004000Z cocoa_present_frame x
LOG
post=$(python3 -c 'import datetime as d; print(d.datetime(2026, 10, 25, 5, 0, 0, 999000, tzinfo=d.timezone.utc).timestamp() * 1e6)')
echo "{\"post_us\": $post, \"lat_ms\": 20}" > "$W/fence/key.jsonl"
got=$(python3 "$W/split.py" "$W/fence" key 2>&1 | python3 -c 'import json, sys; d = json.loads(sys.stdin.readline()); print(d["key"]["compositor_fence_ms"], d["key"]["compositor_to_flush_ms"])' 2>&1)
expect "a fence id asked again: its answer after the ask (2 ms), not the one before" "2.0 2.2" "$got"
# --parse (a run recorded on a Mac without python3): the same split, into breakdown.json.
"$H" --parse "$W/fence" > /dev/null 2>&1
got=$(python3 -c 'import json, sys; d = json.load(open(sys.argv[1])); print(d["key"]["compositor_fence_ms"], d["key"]["compositor_to_flush_ms"])' "$W/fence/breakdown.json" 2>&1)
expect "--parse: the same split from a recorded run" "2.0 2.2" "$got"

# The person's VM, by its path and through a link; --hz 61 is invalid, so a harness that does not
# refuse first stops at its usage (exit 2) instead.
mkdir -p "$W/home/OmacVM/Omarchy" "$W/test/OmacVM T-x"
touch "$W/home/OmacVM/Omarchy/disk.img" "$W/home/OmacVM/Omarchy/efi-vars.fd" "$W/test/OmacVM T-x/disk.img" "$W/test/OmacVM T-x/efi-vars.fd"
ln -s "$W/home/OmacVM/Omarchy" "$W/test/link"
run() { HOME=$W/home "$H" --runtime "$W/none" --vm "$1" --ssh-port 52999 --hz 61 > "$W/out" 2>&1; echo "$? $(grep -c 'one of your own VMs' "$W/out")"; }
expect "the person's VM is refused" "1 1" "$(run "$W/home/OmacVM/Omarchy")"
expect "the person's VM through a link is refused" "1 1" "$(run "$W/test/link")"
expect "a test VM elsewhere is not refused (usage for --hz 61)" "2 0" "$(run "$W/test/OmacVM T-x")"

exit $fail
