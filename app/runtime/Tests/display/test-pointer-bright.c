/*
 * The pointer's image with extra brightness (ui/omacvm-pointer-bright.h):
 * the same light as the boosted frames under it. Run by
 * test-pointer-bright.sh against the header the logic patch makes.
 */
#include <math.h>
#include <stdio.h>
#include "omacvm-pointer-bright.h"

static int fails;

static void near(const char *what, double want, double got)
{
    /* half floats: 11 bits, so 1/1000 of the value (or of 1 near zero) */
    double tol = fmax(fabs(want), 1.0) / 1000.0;
    if (fabs(want - got) > tol) {
        printf("FAIL %s: want %.5f, got %.5f\n", what, want, got);
        fails++;
    } else {
        printf("ok   %s\n", what);
    }
}

static void same(const char *what, int want, int got)
{
    if (want != got) {
        printf("FAIL %s: want %d, got %d\n", what, want, got);
        fails++;
    } else {
        printf("ok   %s\n", what);
    }
}

int main(void)
{
    /* bytes B G R A in memory = 0xAARRGGBB as a 32-bit word (little endian) */
    const uint32_t px[] = {
        0xffffffff,     /* opaque white */
        0xff000000,     /* opaque black */
        0xff804020,     /* opaque R 0x80 G 0x40 B 0x20 */
        0x80000000,     /* the shadow: black at half alpha */
        0x80ffffff,     /* white at half alpha */
        0x00ffffff,     /* clear */
    };
    _Float16 out[6 * 4];
    double g = 2.0, a = 0x80 / 255.0;

    same("not boosted: 1x (the 8-bit image)", OMACVM_BRIGHT_ONE, omacvm_pointer_gain(false, 200));
    same("boosted at 1.00x: 1x", OMACVM_BRIGHT_ONE, omacvm_pointer_gain(true, OMACVM_BRIGHT_ONE));
    same("boosted at 1.40x: 1.40x", 140, omacvm_pointer_gain(true, 140));
    same("boosted at 2.00x: 2.00x", 200, omacvm_pointer_gain(true, 200));

    omacvm_pointer_bright_pixels(px, 6, 200, out);
    /* The page's white under it: the frames' decode times g (the shader's rule). */
    double page_white = omacvm_bright_linear(1.0) * g;
    near("white at 2x: red as the page's white", page_white, out[0]);
    near("white at 2x: green", page_white, out[1]);
    near("white at 2x: blue", page_white, out[2]);
    near("white: alpha 1", 1.0, out[3]);
    near("black stays black", 0.0, out[4]);
    near("black: alpha 1", 1.0, out[7]);
    near("red channel: decoded, times g", omacvm_bright_linear(0x80 / 255.0) * g, out[8]);
    near("green channel: decoded, times g", omacvm_bright_linear(0x40 / 255.0) * g, out[9]);
    near("blue channel: decoded, times g", omacvm_bright_linear(0x20 / 255.0) * g, out[10]);
    near("the shadow: no colour", 0.0, out[12]);
    near("the shadow: its alpha as it is (not times g)", a, out[15]);
    near("white at half alpha: premultiplied", g * a, out[16]);
    near("white at half alpha: alpha", a, out[19]);
    near("clear: nothing", 0.0, out[20] + out[21] + out[22] + out[23]);

    omacvm_pointer_bright_pixels(px, 1, 140, out);
    near("white at 1.40x", 1.4, out[0]);
    omacvm_pointer_bright_pixels(px, 1, OMACVM_BRIGHT_ONE, out);
    near("white at 1x: 1 (SDR white)", 1.0, out[0]);

    return fails != 0;
}
