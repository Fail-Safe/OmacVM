/*
 * The headroom the guest tone-maps into (ui/omacvm-edr.h, ADR 0048):
 * clamped to SDR at least, the display's potential and 16 at most; a new
 * value goes out only for the first one, PQ starting or stopping, or a move
 * of 10 % or more. Run by test-hdr-headroom.sh.
 */
#include <stdio.h>
#include <stdlib.h>
#include "omacvm-edr.h"

static int fails;

static void expect(int ok, const char *what)
{
    if (!ok) {
        fprintf(stderr, "test-hdr-headroom: %s\n", what);
        fails++;
    }
}

int main(void)
{
    /* The value: current headroom, clamped. */
    expect(omacvm_edr_value(4.25, 16, false) == 4.25, "the current headroom goes as it is");
    expect(omacvm_edr_value(1.0, 16, false) == 1.0, "no headroom now is SDR (1)");
    expect(omacvm_edr_value(0.5, 16, false) == 1.0, "below SDR is SDR");
    expect(omacvm_edr_value(NAN, 16, false) == 1.0, "no number is SDR");
    expect(omacvm_edr_value(20, 16, false) == 16, "at most the potential");
    expect(omacvm_edr_value(5, 2.5, false) == 2.5, "at most the display's potential");
    expect(omacvm_edr_value(40, 40, false) == OMACVM_EDR_MAX, "at most 16");
    expect(omacvm_edr_value(1.0, 16, true) == 16, "potential when asked for");
    expect(omacvm_edr_value(3, 1.0, false) == 1.0, "an SDR display stays SDR");
    expect(omacvm_edr_value(2.3456, 16, false) == 2.35, "1/100 steps");

    /* When it goes out. */
    expect(omacvm_edr_moved(-1, 1), "the first value goes out");
    expect(omacvm_edr_moved(-1, 0), "the first value goes out, also 0");
    expect(!omacvm_edr_moved(-1, -1), "HDR not wanted: nothing");
    expect(!omacvm_edr_moved(2, -1), "HDR not wanted: nothing");
    expect(omacvm_edr_moved(1, 0), "PQ stopping goes out");
    expect(omacvm_edr_moved(0, 1), "PQ starting goes out");
    expect(!omacvm_edr_moved(0, 0), "still no PQ: nothing");
    expect(!omacvm_edr_moved(4, 4.3), "under 10 %: nothing");
    expect(omacvm_edr_moved(4, 4.4), "10 %: goes out");
    expect(omacvm_edr_moved(4, 3.6), "10 % down: goes out");
    expect(!omacvm_edr_moved(4, 3.7), "under 10 % down: nothing");

    /* The panel's brightness slider moved from bright to dark and back:
     * a handful of messages, not one a second. */
    double sent = -1;
    int msgs = 0;
    for (int i = 0; i <= 100; i++) {
        double v = omacvm_edr_value(1.0 + 15.0 * i / 100.0, 16, false);
        if (omacvm_edr_moved(sent, v)) {
            sent = v;
            msgs++;
        }
    }
    expect(msgs > 10 && msgs < 40, "a slide from 1 to 16 sends a handful of values");
    expect(sent >= 14.5, "the last value is near the end");

    if (fails) {
        return 1;
    }
    printf("test-hdr-headroom: ok\n");
    return 0;
}
