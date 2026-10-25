#!/bin/bash
# OmacVM's virtio-gpu driver with vsync_lock=1 (linux-virtio-gpu-vsync-lock.patch):
# its vblank timer follows the host's refresh grid. The patch's math (between
# "vsync math" and "end of the vsync math") is taken out of the patch and run
# here against a simulated timer: from any start phase it comes onto the grid
# in a few vblanks, no frame is more than an eighth of a period shorter or
# longer than the period, no vblank comes within a quarter period of the one
# before, and once on the grid it stays there (the host's period, not the
# mode's). No kernel, no VM.
#   src/tests/virtio-gpu-vsync.sh
set -euo pipefail
R=$(cd "$(dirname "$0")/../.." && pwd)
P=$R/src/app/guest/virtio-gpu/linux-virtio-gpu-vsync-lock.patch
T=$(mktemp -d "${TMPDIR:-/tmp}/virtio-gpu-vsync.XXXXXX")
trap 'rm -rf "$T"' EXIT
math=$(sed -n '/vsync math: plain integers/,/end of the vsync math/p' "$P" | sed 's/^+//')
[[ $math == *vsync_step_ns* && $math == *vsync_nearest_ns* ]] || { echo "FAIL: no vsync math in $P"; exit 1; }
cat > "$T/t.c" <<EOF
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
typedef int64_t s64;
typedef uint64_t u64;
static s64 div64_s64(s64 a, s64 b) { return a / b; }
#define clamp_t(t, v, lo, hi) ((t)(v) < (t)(lo) ? (t)(lo) : (t)(v) > (t)(hi) ? (t)(hi) : (t)(v))
$math
#define CHECK(c) do { if (!(c)) { fprintf(stderr, "FAIL: %s (line %d)\n", #c, __LINE__); return 1; } } while (0)

/*
 * A timer that starts at phase start_ns (from the grid's anchor) with the
 * mode's period mode_ns; the host's grid has period_ps. Each vblank: the
 * core forwards the timer by its interval, the driver (from the second
 * vblank on, once the grid came) sets the interval to the host's period and
 * moves the next expiry by vsync_step_ns. Returns the vblanks it took to be
 * within 1 us of the grid (and stay), -1 if never; checks every interval.
 */
static int run(s64 start_ns, s64 mode_ns, u64 period_ps, s64 irq_late_ns, int n, s64 *worst)
{
	s64 period_ns = (s64)((period_ps + 500) / 1000);
	s64 e = start_ns, interval = mode_ns, settled = -1;
	*worst = 0;
	for (int i = 0; i < n; i++) {
		s64 now = e + irq_late_ns;
		s64 next = e + interval;            /* hrtimer_forward_now */
		if (i >= 1) {                         /* the grid came */
			interval = period_ns;
			next = e + interval;
			next += vsync_step_ns(next, next - now, period_ps);
		}
		s64 d = next - e;
		if (i >= 1) {
			if (d > period_ns + period_ns / 8 + 1 || d < period_ns - period_ns / 8 - 1) {
				fprintf(stderr, "interval %lld ns at vblank %d (period %lld)\n", (long long)d, i, (long long)period_ns);
				return -2;
			}
			if (d < period_ns / 4) {
				fprintf(stderr, "vblank %lld ns after the one before\n", (long long)d);
				return -2;
			}
		}
		s64 off = next - vsync_nearest_ns(next, period_ps);
		if (off < 0) off = -off;
		if (off <= 1000) { if (settled < 0) settled = i; }
		else settled = -1;
		if (d - period_ns > *worst) *worst = d - period_ns;
		if (period_ns - d > *worst) *worst = period_ns - d;
		e = next;
	}
	return (int)settled;
}

int main(void)
{
	/* Periods in ps: 60, 120 and 144 Hz. */
	u64 periods[] = { 16666667ull * 1000 - 333, 8333333ull * 1000 + 333, 6944444ull * 1000 + 444 };
	for (unsigned k = 0; k < sizeof(periods) / sizeof(periods[0]); k++) {
		u64 pp = periods[k];
		s64 pn = (s64)((pp + 500) / 1000);
		/* The mode's rate a hair faster than the host's (the EDID's 120.006 Hz). */
		s64 mode = pn - pn / 20000;
		for (int f = 0; f < 16; f++) {
			s64 start = pn * f / 16 + 12345 + 1000000000ll * 3;   /* any phase, seconds after the anchor */
			s64 worst;
			int settled = run(start, mode, pp, 30000, 400, &worst);
			CHECK(settled >= 0);
			CHECK(settled <= 6);                  /* half a period at an eighth a vblank: 4, + the first */
			CHECK(worst <= pn / 8 + 1);
			/* Before the anchor too (an old grid, negative ns). */
			settled = run(-start, mode, pp, 30000, 400, &worst);
			CHECK(settled >= 0 && settled <= 6);
			/* A late interrupt (2 ms) never brings a vblank too close. */
			settled = run(start, mode, pp, 2000000, 400, &worst);
			CHECK(settled >= 0 && settled <= 6);
		}
	}
	/* Nearest: exact points, halves, negatives. */
	CHECK(vsync_nearest_ns(0, 10000000000ull) == 0);
	CHECK(vsync_nearest_ns(4999999, 10000000000ull) == 0);
	CHECK(vsync_nearest_ns(5000001, 10000000000ull) == 10000000);
	CHECK(vsync_nearest_ns(-4999999, 10000000000ull) == 0);
	CHECK(vsync_nearest_ns(-5000001, 10000000000ull) == -10000000);
	CHECK(vsync_nearest_ns(-15000001, 10000000000ull) == -20000000);
	/* A step: at most an eighth, toward the nearer point. */
	CHECK(vsync_step_ns(3000000, 10000000, 16666667000ull) == -16666667 / 8);
	CHECK(vsync_step_ns(15000000, 10000000, 16666667000ull) == 1666667);
	CHECK(vsync_step_ns(12000000, 10000000, 16666667000ull) == 16666667 / 8);
	CHECK(vsync_step_ns(16666000, 10000000, 16666667000ull) == 667);
	/* Never earlier than a quarter period from now. */
	CHECK(vsync_step_ns(3000000, 4000000, 16666667000ull) == 0);
	puts("ok   vsync lock: on the grid within 6 vblanks from any phase, frames within an eighth of a period");
	return 0;
}
EOF
cc -std=c11 -Wall -Wextra -Werror "$T/t.c" -o "$T/t"
"$T/t"
