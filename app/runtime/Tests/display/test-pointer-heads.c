/*
 * The guest's pointer over the windows of the other displays
 * (ui/omacvm-pointer-heads.h, #554): placed and sized as the output's frames
 * are stretched over the window's view. Run by test-pointer-heads.sh against
 * the header the logic patch makes.
 */
#include <limits.h>
#include <math.h>
#include <stdio.h>
#include "omacvm-pointer-heads.h"

static int fails;

static void check(const char *what, bool ok)
{
    printf("%s %s\n", ok ? "ok  " : "FAIL", what);
    fails += !ok;
}

static bool at(OmacVMHeadPointerFrame f, double x, double y, double w, double h)
{
    return f.shown && fabs(f.x - x) < 1e-9 && fabs(f.y - y) < 1e-9 &&
           fabs(f.w - w) < 1e-9 && fabs(f.h - h) < 1e-9;
}

int main(void)
{
    OmacVMHeadPointerFrame f;

    /* A Retina display: a 3024x1964 output in a 1512x982-point window. */
    f = omacvm_head_pointer_frame(true, 100, 200, 64, 64, 3024, 1964, 1512, 982);
    check("Retina: top left at half the pixels, from the view's top", at(f, 50, 882, 32, 32));
    f = omacvm_head_pointer_frame(true, 0, 0, 48, 48, 3024, 1964, 1512, 982);
    check("the output's top left corner: the view's top left", at(f, 0, 982, 24, 24));

    /* A 1:1 external display: 2560x1440 output, 2560x1440-point window. */
    f = omacvm_head_pointer_frame(true, 1280, 720, 24, 24, 2560, 1440, 2560, 1440);
    check("1:1: the same place", at(f, 1280, 720, 24, 24));

    /* The frames stretch each axis on its own (a window not yet at the output's shape). */
    f = omacvm_head_pointer_frame(true, 1000, 500, 64, 64, 2000, 1000, 1000, 1000);
    check("stretched: each axis by its own scale", at(f, 500, 500, 32, 64));

    /* Partly off the output's edges: still shown, the visible part where it is. */
    f = omacvm_head_pointer_frame(true, 2550, 1430, 24, 24, 2560, 1440, 2560, 1440);
    check("partly over the right and bottom edges: shown", at(f, 2550, 10, 24, 24));
    f = omacvm_head_pointer_frame(true, -10, -10, 24, 24, 2560, 1440, 2560, 1440);
    check("hot spot near the top left: partly above and left: shown", at(f, -10, 1450, 24, 24));

    /* The guest hides the plane, or the image is wholly off this output. */
    check("plane off: hidden", !omacvm_head_pointer_frame(false, 10, 10, 24, 24, 2560, 1440, 2560, 1440).shown);
    check("right of the output: hidden", !omacvm_head_pointer_frame(true, 2560, 10, 24, 24, 2560, 1440, 2560, 1440).shown);
    check("below the output: hidden", !omacvm_head_pointer_frame(true, 10, 1440, 24, 24, 2560, 1440, 2560, 1440).shown);
    check("wholly left of it: hidden", !omacvm_head_pointer_frame(true, -24, 10, 24, 24, 2560, 1440, 2560, 1440).shown);
    check("wholly above it: hidden", !omacvm_head_pointer_frame(true, 10, -24, 24, 24, 2560, 1440, 2560, 1440).shown);

    /* Sizes not known yet: hidden, never a division by zero. */
    check("no image yet: hidden", !omacvm_head_pointer_frame(true, 10, 10, 0, 0, 2560, 1440, 2560, 1440).shown);
    check("no output size yet: hidden", !omacvm_head_pointer_frame(true, 10, 10, 24, 24, 0, 0, 2560, 1440).shown);
    check("no view size yet: hidden", !omacvm_head_pointer_frame(true, 10, 10, 24, 24, 2560, 1440, 0, 0).shown);
    check("view size NaN: hidden", !omacvm_head_pointer_frame(true, 10, 10, 24, 24, 2560, 1440, NAN, 1440).shown);

    /* The guest's numbers can be anything. */
    check("x at INT_MAX: hidden", !omacvm_head_pointer_frame(true, INT_MAX, 10, 24, 24, 2560, 1440, 2560, 1440).shown);
    check("x at INT_MIN: hidden", !omacvm_head_pointer_frame(true, INT_MIN, 10, 24, 24, 2560, 1440, 2560, 1440).shown);
    check("y at INT_MIN: hidden", !omacvm_head_pointer_frame(true, 10, INT_MIN, 24, 24, 2560, 1440, 2560, 1440).shown);

    /* QEMU's thread sends the output's size only when it changed, not at every page flip. */
    {
        OmacVMHeadPointerSize last = { 0, 0 };
        int sends = 0;

        check("no size yet (0 x 0): nothing to send", !omacvm_head_pointer_size_changed(&last, 0, 0));
        check("the first size: sent", omacvm_head_pointer_size_changed(&last, 2560, 1440));
        for (int i = 0; i < 1000; i++) {
            sends += omacvm_head_pointer_size_changed(&last, 2560, 1440);
        }
        check("1000 page flips at the same size: nothing sent", sends == 0);
        check("a new width: sent", omacvm_head_pointer_size_changed(&last, 1920, 1440));
        check("a new height: sent", omacvm_head_pointer_size_changed(&last, 1920, 1080));
        check("the new size again: nothing sent", !omacvm_head_pointer_size_changed(&last, 1920, 1080));
        check("the output off (0 x 0): sent", omacvm_head_pointer_size_changed(&last, 0, 0));
        check("kept: the last size sent", last.w == 0 && last.h == 0);
    }

    printf("%s\n", fails ? "FAIL test-pointer-heads" : "ok   test-pointer-heads: all");
    return fails ? 1 : 0;
}
