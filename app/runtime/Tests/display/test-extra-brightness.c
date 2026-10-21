/*
 * Extra brightness (ui/omacvm-bright.h, ADR 0050): the gain follows the
 * window's display's headroom, at most 2x, never above the headroom now,
 * only on a display above 2x; the log's states; the sRGB decode the
 * shader does. Run by test-extra-brightness.sh.
 */
#include <stdio.h>
#include <stdlib.h>
#include "omacvm-bright.h"

static int fails;

static void expect(int ok, const char *what)
{
    if (!ok) {
        fprintf(stderr, "test-extra-brightness: %s\n", what);
        fails++;
    }
}

int main(void)
{
    /* Which displays. */
    expect(!omacvm_bright_display(1), "an SDR monitor (potential 1): no");
    expect(!omacvm_bright_display(2), "a MacBook Air (potential 2): no");
    expect(!omacvm_bright_display(2.05), "2.05: no");
    expect(omacvm_bright_display(16), "an XDR panel (potential 16): yes");
    expect(omacvm_bright_display(4), "an HDR monitor (potential 4): yes");
    expect(!omacvm_bright_display(NAN) && !omacvm_bright_display(INFINITY), "no number: no");

    /* The gain. */
    expect(omacvm_bright_gain(1.2, 16) == 120, "headroom now 1.2: 1.20x");
    expect(omacvm_bright_gain(3, 16) == 200, "headroom now 3: 2.00x (the target)");
    expect(omacvm_bright_gain(16, 16) == 200, "headroom 16: still 2.00x");
    expect(omacvm_bright_gain(1.4, 16) == 140, "macOS holds it at 1.4 (hot): 1.40x");
    expect(omacvm_bright_gain(1.999, 16) == 199, "rounded down: never above the headroom now");
    expect(omacvm_bright_gain(1.0, 16) == 100, "headroom 1: 1x");
    expect(omacvm_bright_gain(0.5, 16) == 100, "below 1: 1x");
    expect(omacvm_bright_gain(NAN, 16) == 100 && omacvm_bright_gain(INFINITY, 16) == 100, "no number: 1x");
    expect(omacvm_bright_gain(2, 2) == 100, "an Air (potential 2): 1x");
    expect(omacvm_bright_gain(1, 1) == 100, "an SDR monitor: 1x");
    expect(omacvm_bright_gain(3, NAN) == 100, "no potential: 1x");
    expect(omacvm_bright_gain(2.5, 2.5) == 200, "a potential above 2: up to 2x");
    expect(omacvm_bright_gain(2.2, 2.06) == 200, "a potential just above 2.05: up to 2x");
    for (int i = 0; i <= 2000; i++) {
        double now = 0.5 + i * 0.01;
        int g = omacvm_bright_gain(now, 16);
        if (g < 100 || g > 200 || (now >= 1 && g > now * 100 + 1e-6)) {
            expect(0, "the gain stays within 1x .. min(2x, headroom now)");
            break;
        }
    }

    /* A new frame for a move of 0.02 or more. */
    expect(!omacvm_bright_moved(200, 199), "0.01: no new frame");
    expect(omacvm_bright_moved(200, 198) && omacvm_bright_moved(120, 200), "0.02 or more: a new frame");
    expect(omacvm_bright_moved(198, 200), "up as well as down");

    /* The log's states. */
    OmacVMBright p = OMACVM_BRIGHT_OFF;
    expect(omacvm_bright_state(p, false, true, 16, false, 200) == OMACVM_BRIGHT_OFF, "switch off: off");
    expect(omacvm_bright_state(p, true, false, 16, false, 200) == OMACVM_BRIGHT_NO_PATH, "no IOSurface present: off (why)");
    expect(omacvm_bright_state(p, true, true, 2, false, 100) == OMACVM_BRIGHT_NO_DISPLAY, "an Air: not on this display");
    expect(omacvm_bright_state(p, true, true, 16, true, 200) == OMACVM_BRIGHT_NO_HDR, "PQ: not with HDR yet");
    expect(omacvm_bright_state(p, true, true, 16, false, 200) == OMACVM_BRIGHT_ON, "2.00x: on");
    expect(omacvm_bright_state(p, true, true, 16, false, 195) == OMACVM_BRIGHT_ON, "1.95x: on");
    expect(omacvm_bright_state(p, true, true, 16, false, 140) == OMACVM_BRIGHT_HELD, "1.40x: held back");
    expect(omacvm_bright_state(OMACVM_BRIGHT_ON, true, true, 16, false, 192) == OMACVM_BRIGHT_ON,
           "1.92x after on: still on");
    expect(omacvm_bright_state(OMACVM_BRIGHT_HELD, true, true, 16, false, 192) == OMACVM_BRIGHT_HELD,
           "1.92x after held back: still held back");
    expect(omacvm_bright_state(OMACVM_BRIGHT_HELD, true, true, 16, false, 196) == OMACVM_BRIGHT_ON,
           "1.96x after held back: on");

    /* The decode (the shader's, checked on a renderer by test-extra-brightness-shader.m). */
    expect(omacvm_bright_linear(0) == 0 && omacvm_bright_linear(1) == 1, "black and white stay");
    expect(fabs(omacvm_bright_linear(0.5) - 0.214041) < 1e-5, "50 % grey: 0.214 of white in linear light");
    expect(fabs(omacvm_bright_linear(0.04045) - 0.04045 / 12.92) < 1e-9, "the linear part");
    expect(omacvm_bright_linear(-1) == 0 && omacvm_bright_linear(2) == 1, "clamped to 0..1");
    double last = -1;
    for (int i = 0; i <= 255; i++) {
        double v = omacvm_bright_linear(i / 255.0);
        if (v < last) {
            expect(0, "the decode rises");
            break;
        }
        last = v;
    }

    if (fails) {
        return 1;
    }
    printf("test-extra-brightness: rules ok\n");
    return 0;
}
