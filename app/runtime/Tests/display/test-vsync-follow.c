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

    /* The lead: too few frames keep it; else the latest + 1 ms, down slowly, clamped. */
    OmacVMLead l = { 0 };
    for (int i = 0; i < 10; i++) {
        omacvm_lead_add(&l, 0.003);
    }
    CHECK(omacvm_lead_value(&l, 1 / 60.0, 0.005) == 0.005);
    for (int i = 0; i < 60; i++) {
        omacvm_lead_add(&l, 0.003 + (i % 20) * 0.0001);   /* 3.0 .. 4.9 ms */
    }
    CHECK(fabs(omacvm_lead_quantile(&l, 1.0) - 0.0049) < 1e-9);
    CHECK(fabs(omacvm_lead_quantile(&l, 0.0) - 0.003) < 1e-9);
    double v = omacvm_lead_value(&l, 1 / 60.0, 0.005);
    CHECK(fabs(v - 0.0059) < 1e-9);                      /* up at once: 4.9 + 1 ms */
    CHECK(fabs(omacvm_lead_value(&l, 1 / 60.0, 0.009) - 0.0085) < 1e-9);   /* down 0.5 ms at most */
    CHECK(fabs(omacvm_lead_value(&l, 1 / 60.0, 0.0062) - 0.0059) < 1e-9);  /* down to it when close */
    OmacVMLead one = { 0 };
    for (int i = 0; i < 63; i++) {
        omacvm_lead_add(&one, 0.002);
    }
    omacvm_lead_add(&one, 0.007);                          /* one slow frame sets it */
    CHECK(fabs(omacvm_lead_value(&one, 1 / 60.0, 0.004) - 0.008) < 1e-9);
    OmacVMLead fast = { 0 };
    for (int i = 0; i < 64; i++) {
        omacvm_lead_add(&fast, 0.0002);
    }
    CHECK(omacvm_lead_value(&fast, 1 / 120.0, 0.0021) == OMACVM_LEAD_MIN_S);
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
    CHECK(omacvm_lead_quantile(&slow, 0.5) < 0);

    /* Late frames wait in the queue when the frames need more than the lead can give, or > 1 % came late. */
    OmacVMLead ok = { 0 };
    for (int i = 0; i < 64; i++) {
        omacvm_lead_add(&ok, 0.003 + (i % 4) * 0.0005);   /* 3.0 .. 4.5 ms */
    }
    CHECK(!omacvm_follow_buffered(&ok, 1 / 120.0, 120, 1));    /* 4.5 + 1 < 7.33: follow, 1 late in 120 */
    CHECK(omacvm_follow_buffered(&ok, 1 / 120.0, 120, 2));     /* 2 in 120: more than 1 in 100 */
    omacvm_lead_add(&ok, 0.0071);                               /* 7.1 + 1 > 7.33 */
    CHECK(omacvm_follow_buffered(&ok, 1 / 120.0, 120, 0));
    CHECK(!omacvm_follow_buffered(&ok, 1 / 60.0, 60, 0));       /* at 60 Hz it fits */
    CHECK(omacvm_follow_buffered(&ok, 0, 60, 0));

    /* Since the grid's last vblank: wraps by the period, never negative. */
    CHECK(fabs(omacvm_vsync_since(10.004, 10.0, 0.01) - 0.004) < 1e-9);
    CHECK(fabs(omacvm_vsync_since(10.014, 10.0, 0.01) - 0.004) < 1e-9);
    CHECK(fabs(omacvm_vsync_since(9.996, 10.0, 0.01) - 0.006) < 1e-9);
    CHECK(omacvm_vsync_since(1, 1, 0) < 0);

    puts("ok   vsync follow: grid points, period, lead");
    return 0;
}
