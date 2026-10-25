/*
 * test-display-color: the rules of the display colour present
 * (ui/omacvm-dispcolor.h): the table's grid and layout, when the present
 * converts, the switch, and the self-check that keeps the sRGB tag for a
 * display profile the table cannot follow (macOS's colour management is the
 * reference, as WindowServer's).
 *   cc -I<folder with omacvm-dispcolor.h> test-display-color.c -framework CoreGraphics
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "omacvm-dispcolor.h"

static int failures;

#define CHECK(cond, ...) do { if (!(cond)) { fprintf(stderr, "test-display-color: " __VA_ARGS__); \
    fputc('\n', stderr); failures++; } } while (0)

static int error_of(CGColorSpaceRef cs)
{
    uint16_t *t = calloc((size_t)OMACVM_DC_N * OMACVM_DC_N * OMACVM_DC_N * 4, sizeof(uint16_t));
    int e = omacvm_dc_fill(cs, OMACVM_DC_N, t) ? omacvm_dc_error(cs, OMACVM_DC_N, t) : -2;
    free(t);
    return e;
}

int main(void)
{
    /* Grid: exact ends, even steps. */
    CHECK(omacvm_dc_grid16(0, 33) == 0 && omacvm_dc_grid16(32, 33) == 65535, "grid ends");
    CHECK(omacvm_dc_grid16(16, 33) == 32768, "grid middle %d", omacvm_dc_grid16(16, 33));
    for (int i = 1; i < 33; i++) {
        int d = omacvm_dc_grid16(i, 33) - omacvm_dc_grid16(i - 1, 33);
        CHECK(d == 2047 || d == 2048, "grid step %d at %d", d, i);
    }
    /* Layout: red fastest, then green, then blue (GL_TEXTURE_3D x, y, z). */
    CHECK(omacvm_dc_index(1, 0, 0, 33) == 1 && omacvm_dc_index(0, 1, 0, 33) == 33 &&
          omacvm_dc_index(0, 0, 1, 33) == 33 * 33 && omacvm_dc_index(32, 32, 32, 33) == 33 * 33 * 33 - 1,
          "table layout");
    /* 0 and 1 land on the first and last texel centres. */
    float s = omacvm_dc_scale(33), o = omacvm_dc_offset(33);
    CHECK(fabsf(o - 0.5f / 33) < 1e-7f && fabsf(s + o - (32.5f / 33)) < 1e-6f, "texel centres");

    /* When the present converts. */
    OmacvmDcState on = { .tagged = true, .known = true };
    CHECK(omacvm_dc_wanted(&on), "an 8-bit frame for a P3 display converts");
    OmacvmDcState st;
    st = on; st.tagged = false;      CHECK(!omacvm_dc_wanted(&st), "OMACVM_GL_COLOR=native: untagged, as before");
    st = on; st.deep = true;         CHECK(!omacvm_dc_wanted(&st), "HDR / 10-bit stays PQ or sRGB half float");
    st = on; st.linear = true;       CHECK(!omacvm_dc_wanted(&st), "extra brightness stays extended linear sRGB");
    st = on; st.off = true;          CHECK(!omacvm_dc_wanted(&st), "switched off");
    st = on; st.known = false;       CHECK(!omacvm_dc_wanted(&st), "no display space yet");
    st = on; st.display_srgb = true; CHECK(!omacvm_dc_wanted(&st), "an sRGB display needs no conversion");
    st = on; st.failed = true;       CHECK(!omacvm_dc_wanted(&st), "table or shader failed");
    st = on; st.splash = true;       CHECK(!omacvm_dc_wanted(&st), "the boot logo draws sRGB");

    /* The switch. */
    CHECK(!omacvm_dc_env_off(NULL) && !omacvm_dc_env_off("1") && !omacvm_dc_env_off("on"), "on by default");
    CHECK(omacvm_dc_env_off("0") && omacvm_dc_env_off("off") && omacvm_dc_env_off("no") &&
          omacvm_dc_env_off("OFF") && omacvm_dc_env_off(""), "off words");

    /* The self-check against macOS's own conversion. */
    CGColorSpaceRef p3 = CGColorSpaceCreateWithName(kCGColorSpaceDisplayP3);
    CGColorSpaceRef srgb = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    CGColorSpaceRef gray = CGColorSpaceCreateWithName(kCGColorSpaceGenericGrayGamma2_2);
    const CGFloat white[3] = { 0.9505, 1.0, 1.0891 }, black[3] = { 0, 0, 0 }, gamma[3] = { 2.2, 2.2, 2.2 };
    const CGFloat m[9] = { 0.4866, 0.2290, 0.0000, 0.2657, 0.6917, 0.0451, 0.1982, 0.0793, 1.0439 };
    CGColorSpaceRef g22 = CGColorSpaceCreateCalibratedRGB(white, black, gamma, m);
    int ep3 = error_of(p3), esrgb = error_of(srgb), eg22 = error_of(g22);
    printf("test-display-color: table vs macOS: Display P3 %d, sRGB %d, P3 gamma 2.2 %d codes\n", ep3, esrgb, eg22);
    CHECK(ep3 >= 0 && ep3 <= 1, "Display P3: the table is %d codes off", ep3);
    CHECK(esrgb == 0, "sRGB: the table is %d codes off", esrgb);
    CHECK(eg22 > OMACVM_DC_MAX_ERR, "a gamma 2.2 profile must fail the check (%d), so it keeps the sRGB tag", eg22);
    CHECK(error_of(gray) == -2, "a grey space gives no table");
    CHECK(omacvm_dc_error(NULL, OMACVM_DC_N, NULL) == -1, "no space: not measured");
    CGColorSpaceRelease(p3);
    CGColorSpaceRelease(srgb);
    CGColorSpaceRelease(gray);
    CGColorSpaceRelease(g22);

    if (failures) {
        fprintf(stderr, "test-display-color: %d failure(s)\n", failures);
        return 1;
    }
    printf("test-display-color: ok\n");
    return 0;
}
