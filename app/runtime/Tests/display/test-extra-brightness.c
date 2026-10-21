/*
 * Extra brightness (ui/omacvm-bright.h, ADR 0050): the gain follows the
 * window's display's headroom, at most 2x, never above the headroom now,
 * only on a display above 2x; the log's states; the sRGB and PQ decodes
 * the shader does (PQ: SDR white at 1, clipped there, BT.2020 to sRGB's
 * primaries). Run by test-extra-brightness.sh.
 */
#include <stdio.h>
#include <stdlib.h>
#include "omacvm-bright.h"

static int fails;

/* PQ encode (ST 2084), the decode's inverse: nits to 0..1. */
static double pq_encode(double nits)
{
    double y = pow(fmax(nits, 0) / 10000.0, OMACVM_BRIGHT_PQ_M1);
    return pow((OMACVM_BRIGHT_PQ_C1 + OMACVM_BRIGHT_PQ_C2 * y) / (1 + OMACVM_BRIGHT_PQ_C3 * y),
               OMACVM_BRIGHT_PQ_M2);
}

/* BT.709 to BT.2020 (BT.2087), linear: how a guest puts an sRGB colour into its PQ frame. */
static void to2020(const double in[3], double out[3])
{
    static const double m[3][3] = {
        { 0.6274040, 0.3292820, 0.0433136 },
        { 0.0690970, 0.9195400, 0.0113612 },
        { 0.0163916, 0.0880132, 0.8955950 },
    };
    for (int i = 0; i < 3; i++) {
        out[i] = m[i][0] * in[0] + m[i][1] * in[1] + m[i][2] * in[2];
    }
}

static bool near3(const double got[3], double r, double g, double b, double tol)
{
    return fabs(got[0] - r) <= tol && fabs(got[1] - g) <= tol && fabs(got[2] - b) <= tol;
}

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
    expect(omacvm_bright_state(p, false, true, 16, 200) == OMACVM_BRIGHT_OFF, "switch off: off");
    expect(omacvm_bright_state(p, true, false, 16, 200) == OMACVM_BRIGHT_NO_PATH, "no IOSurface present: off (why)");
    expect(omacvm_bright_state(p, true, true, 2, 100) == OMACVM_BRIGHT_NO_DISPLAY, "an Air: not on this display");
    expect(omacvm_bright_state(p, true, true, 16, 200) == OMACVM_BRIGHT_ON, "2.00x: on (SDR or PQ frames alike)");
    expect(omacvm_bright_state(p, true, true, 16, 195) == OMACVM_BRIGHT_ON, "1.95x: on");
    expect(omacvm_bright_state(p, true, true, 16, 140) == OMACVM_BRIGHT_HELD, "1.40x: held back");
    expect(omacvm_bright_state(OMACVM_BRIGHT_ON, true, true, 16, 192) == OMACVM_BRIGHT_ON,
           "1.92x after on: still on");
    expect(omacvm_bright_state(OMACVM_BRIGHT_HELD, true, true, 16, 192) == OMACVM_BRIGHT_HELD,
           "1.92x after held back: still held back");
    expect(omacvm_bright_state(OMACVM_BRIGHT_HELD, true, true, 16, 196) == OMACVM_BRIGHT_ON,
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

    /* PQ (it wins over HDR): the decode to nits. */
    expect(omacvm_bright_pq_nits(0) == 0, "PQ 0: black");
    expect(fabs(omacvm_bright_pq_nits(1) - 10000) < 1e-6, "PQ 1: 10000 nits");
    expect(fabs(omacvm_bright_pq_nits(0.58069) - 203) < 0.05, "PQ 0.58069: 203 nits (SDR white)");
    expect(fabs(omacvm_bright_pq_nits(pq_encode(1000)) - 1000) < 0.01, "the decode undoes the encode (1000 nits)");
    expect(omacvm_bright_pq_nits(-1) == 0 && fabs(omacvm_bright_pq_nits(2) - 10000) < 1e-6, "PQ clamped to 0..1");
    expect(fabs(omacvm_bright_pq_nits(594 / 1023.0) / OMACVM_BRIGHT_SDR_NITS - 0.9996) < 0.0005,
           "Hyprland's PQ white (code 594 of 1023): 0.9996 of SDR white");
    last = -1;
    for (int i = 0; i <= 1023; i++) {
        double v = omacvm_bright_pq_nits(i / 1023.0);
        if (!(v > last || (i == 0 && v == 0))) {
            expect(0, "the PQ decode rises over all 1024 codes");
            break;
        }
        last = v;
    }

    /* PQ to linear light in sRGB's primaries: SDR white is 1, nothing above it. */
    double e[3], out[3], lin[3], bt2020[3];
    e[0] = e[1] = e[2] = 594 / 1023.0;
    omacvm_bright_pq_linear(e, out);
    expect(near3(out, 1, 1, 1, 0.001), "PQ white (code 594): white 1.00");
    e[0] = e[1] = e[2] = pq_encode(1000);
    omacvm_bright_pq_linear(e, out);
    expect(near3(out, 1, 1, 1, 1e-6), "a 1000-nit highlight: clipped at white (HDR not effective)");
    e[0] = e[1] = e[2] = 1;
    omacvm_bright_pq_linear(e, out);
    expect(near3(out, 1, 1, 1, 1e-6), "10000 nits: white");
    e[0] = e[1] = e[2] = pq_encode(101.5);
    omacvm_bright_pq_linear(e, out);
    expect(near3(out, 0.5, 0.5, 0.5, 1e-6), "101.5 nits: half of white");
    e[0] = e[1] = e[2] = 0;
    omacvm_bright_pq_linear(e, out);
    expect(near3(out, 0, 0, 0, 1e-9), "black stays black");
    /* sRGB's red, green and blue put in a PQ frame by a guest come back (the matrix's orientation). */
    for (int c = 0; c < 3; c++) {
        double rgb[3] = { c == 0, c == 1, c == 2 };
        to2020(rgb, bt2020);
        for (int i = 0; i < 3; i++) {
            e[i] = pq_encode(bt2020[i] * OMACVM_BRIGHT_SDR_NITS);
        }
        omacvm_bright_pq_linear(e, lin);
        expect(near3(lin, rgb[0], rgb[1], rgb[2], 0.002), "sRGB red, green and blue through PQ come back");
    }
    /* A BT.2020 green is outside sRGB: red and blue below 0, kept (extended range). */
    e[0] = 0;
    e[1] = pq_encode(OMACVM_BRIGHT_SDR_NITS);
    e[2] = 0;
    omacvm_bright_pq_linear(e, out);
    expect(out[0] < -0.5 && out[2] < -0.05 && out[1] > 1.1, "BT.2020 green: outside sRGB, kept");

    if (fails) {
        return 1;
    }
    printf("test-extra-brightness: rules ok\n");
    return 0;
}
