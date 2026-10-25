/*
 * The guest's vblanks in step with the Mac display's refresh
 * (ui/omacvm-vsync.h, omacvm-vsync-follow-logic.patch): the grid point the
 * guest gets, the period measured from the link's ticks, the lead from when
 * the guest's frames are ready.
 */
#include "omacvm-vsync.h"
#include <stdio.h>

#define CHECK(c) do { if (!(c)) { fprintf(stderr, "FAIL: %s (line %d)\n", #c, __LINE__); return 1; } } while (0)

int main(void)
{
    /* The next grid point: at or after now, in whole periods (ps). */
    const uint64_t p60 = 16666666667ull;            /* 60 Hz in ps */
    CHECK(omacvm_vsync_next(1000, p60, 1000) == 1000);
    CHECK(omacvm_vsync_next(1000, p60, 1001) == 1000 + 16666666);   /* 16666666.667, to the ns below */
    CHECK(omacvm_vsync_next(1000, p60, 1000 + 16666666) == 1000 + 16666666);
    CHECK(omacvm_vsync_next(1000, p60, 999) == 1000);
    CHECK(omacvm_vsync_next(1000, p60, 1000 - 16666666) == 1000);
    CHECK(omacvm_vsync_next(1000, p60, 1000 - 16666667) == 1000 - 16666666);  /* -16666666.667 */
    /* An hour later: 216000 whole periods of ps, no rounded ns added up. */
    int64_t hour = 3600ll * 1000000000ll;
    CHECK(omacvm_vsync_next(0, p60, hour) == (int64_t)(216000 * p60 / 1000));   /* +72 ns */
    CHECK(omacvm_vsync_next(0, p60, hour + 73) == (int64_t)(216001 * p60 / 1000));
    CHECK(omacvm_vsync_next(5, 0, 99) == 5);

    /* The full rate's period from a run of ticks (a slowed link too). */
    CHECK(omacvm_vsync_period_ps(1.0, 60) == 16666666667ull);
    CHECK(omacvm_vsync_period_ps(2.0 * 1.0001, 120) == 8334166667ull);  /* a display 100 ppm slow */
    CHECK(omacvm_vsync_period_ps(30 / 60.0, 120) == 8333333333ull);     /* 60 Hz ticks on a 120 Hz panel */
    CHECK(omacvm_vsync_period_ps(0.3, 60) == 0);                        /* too short */
    CHECK(omacvm_vsync_period_ps(1.0, 0) == 0);
    CHECK(omacvm_vsync_period_ps(1.0, 75) == 13333333333ull);

    /* The lead: too few frames keep it; else the 95th percentile + 1 ms, clamped. */
    OmacVMLead l = { 0 };
    for (int i = 0; i < 10; i++) {
        omacvm_lead_add(&l, 0.003);
    }
    CHECK(omacvm_lead_value(&l, 1 / 60.0, 0.005) == 0.005);
    for (int i = 0; i < 60; i++) {
        omacvm_lead_add(&l, 0.003 + (i % 20) * 0.0001);   /* 3.0 .. 4.9 ms */
    }
    double v = omacvm_lead_value(&l, 1 / 60.0, 0.005);
    CHECK(v > 0.0057 && v < 0.0060);                     /* p95 ~4.8-4.9 ms + 1 ms */
    OmacVMLead fast = { 0 };
    for (int i = 0; i < 64; i++) {
        omacvm_lead_add(&fast, 0.0002);
    }
    CHECK(omacvm_lead_value(&fast, 1 / 120.0, 0.005) == OMACVM_LEAD_MIN_S);
    OmacVMLead slow = { 0 };
    for (int i = 0; i < 64; i++) {
        omacvm_lead_add(&slow, 0.0079);
    }
    CHECK(fabs(omacvm_lead_value(&slow, 1 / 120.0, 0.005) - (1 / 120.0 - OMACVM_LEAD_SPARE_S)) < 1e-12);
    omacvm_lead_add(&slow, -1);                           /* not a time: ignored */
    omacvm_lead_add(&slow, NAN);
    CHECK(slow.n == OMACVM_LEAD_N);
    omacvm_lead_reset(&slow);
    CHECK(slow.n == 0 && omacvm_lead_value(&slow, 1 / 120.0, 0.004) == 0.004);

    /* Since the grid's last vblank: wraps by the period, never negative. */
    CHECK(fabs(omacvm_vsync_since(10.004, 10.0, 0.01) - 0.004) < 1e-9);
    CHECK(fabs(omacvm_vsync_since(10.014, 10.0, 0.01) - 0.004) < 1e-9);
    CHECK(fabs(omacvm_vsync_since(9.996, 10.0, 0.01) - 0.006) < 1e-9);
    CHECK(omacvm_vsync_since(1, 1, 0) < 0);

    puts("ok   vsync follow: grid points, period, lead");
    return 0;
}
