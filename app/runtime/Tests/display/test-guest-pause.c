/*
 * Pause drawing while hidden (omacvm-guest-pause.h, from
 * omacvm-cocoa-guest-pause-logic.patch): when the guest is told that the
 * VM's window is out of sight and seen again, and when the window keeps its
 * last picture. test-guest-pause.sh builds it against the patch.
 */
#include <stdio.h>
#include "omacvm-guest-pause.h"

static int fails;
static void check(int ok, const char *what)
{
    printf("%s %s\n", ok ? "ok  " : "FAIL", what);
    if (!ok) {
        fails++;
    }
}

static OmacVMGuestPause fresh(void)
{
    return (OmacVMGuestPause){ .seen = true };
}

int main(void)
{
    OmacVMGuestPause p = fresh();

    /* Switch off: nothing is ever told, whatever the window does. */
    check(omacvm_gp_feed(&p, false, false, 10) == OMACVM_GP_NONE && omacvm_gp_due_at(&p) == 0 &&
          omacvm_gp_due(&p, 100) == OMACVM_GP_NONE && !p.hold,
          "switch off: an unseen window changes nothing");

    /* Out of sight: told only after OMACVM_GP_AFTER_S. */
    p = fresh();
    check(omacvm_gp_feed(&p, true, false, 10) == OMACVM_GP_NONE, "out of sight: nothing told at once");
    check(omacvm_gp_due_at(&p) == 10 + OMACVM_GP_AFTER_S, "... due after OMACVM_GP_AFTER_S");
    check(omacvm_gp_due(&p, 11) == OMACVM_GP_NONE, "... not before");
    check(omacvm_gp_feed(&p, true, false, 11.5) == OMACVM_GP_NONE && omacvm_gp_due_at(&p) == 12,
          "... another 'out of sight' does not move the time");
    check(omacvm_gp_due(&p, 12) == OMACVM_GP_UNSEEN && p.told && p.hold, "... then the guest is told unseen");
    check(omacvm_gp_due(&p, 13) == OMACVM_GP_NONE && omacvm_gp_due_at(&p) == 0, "... once");
    check(omacvm_gp_feed(&p, true, false, 20) == OMACVM_GP_NONE, "... still out of sight: nothing new");

    /* While told: the window keeps its last picture when the guest has no scanout. */
    check(omacvm_gp_keep(&p, false, 20), "told: no guest scanout: keep the last picture");
    check(!omacvm_gp_keep(&p, true, 20), "told: a guest scanout is drawn");
    check(omacvm_gp_frame(&p) == 0, "told: a frame (a guest that kept drawing) does not end the hold");

    /* Seen again: told at once; the hold until the first frame, at most OMACVM_GP_HOLD_S. */
    check(omacvm_gp_feed(&p, true, true, 30) == OMACVM_GP_SEEN && !p.told && p.paused_s == 18,
          "seen again: told at once (paused 18 s)");
    check(p.hold && omacvm_gp_keep(&p, false, 30.5), "... the last picture is kept while the guest's display is off");
    check(omacvm_gp_frame(&p) == 1 && !p.hold && !omacvm_gp_keep(&p, false, 30.6),
          "... the guest's first frame ends the hold");
    check(omacvm_gp_frame(&p) == 2 && omacvm_gp_frame(&p) == 3 && omacvm_gp_frame(&p) == 0,
          "... frames counted up to 3 (the log)");
    check(omacvm_gp_feed(&p, true, true, 31) == OMACVM_GP_NONE, "... seen again: nothing more to tell");

    /* No frame from the guest after "seen" (an older agent, a guest that went away): the hold ends. */
    p = fresh();
    omacvm_gp_feed(&p, true, false, 0);
    omacvm_gp_due(&p, OMACVM_GP_AFTER_S);
    omacvm_gp_feed(&p, true, true, 10);
    check(omacvm_gp_keep(&p, false, 10 + OMACVM_GP_HOLD_S), "no frame yet: kept up to OMACVM_GP_HOLD_S");
    check(!omacvm_gp_keep(&p, false, 10 + OMACVM_GP_HOLD_S + 0.01) && !p.hold, "... not after it");

    /* A short look away: never told. */
    p = fresh();
    omacvm_gp_feed(&p, true, false, 5);
    check(omacvm_gp_feed(&p, true, true, 5 + OMACVM_GP_AFTER_S - 0.1) == OMACVM_GP_NONE &&
          omacvm_gp_due(&p, 100) == OMACVM_GP_NONE && omacvm_gp_due_at(&p) == 0 && !p.hold,
          "back within OMACVM_GP_AFTER_S: the guest is never told");
    omacvm_gp_feed(&p, true, false, 50);
    check(omacvm_gp_due_at(&p) == 50 + OMACVM_GP_AFTER_S, "... the next time away counts from then");

    /* The switch goes off while told: seen at once; on again while out of sight: counts anew. */
    p = fresh();
    omacvm_gp_feed(&p, true, false, 0);
    omacvm_gp_due(&p, 3);
    check(omacvm_gp_feed(&p, false, false, 4) == OMACVM_GP_SEEN, "switch off while told: the guest draws again at once");
    check(omacvm_gp_due(&p, 100) == OMACVM_GP_NONE, "... and is not told unseen while off");
    check(omacvm_gp_feed(&p, true, false, 10) == OMACVM_GP_NONE && omacvm_gp_due_at(&p) == 10 + OMACVM_GP_AFTER_S,
          "switch on again while out of sight: told after OMACVM_GP_AFTER_S from then");
    check(omacvm_gp_due(&p, 10 + OMACVM_GP_AFTER_S) == OMACVM_GP_UNSEEN, "... then told");

    /* The switch turned on while the window is seen: nothing to tell. */
    p = fresh();
    check(omacvm_gp_feed(&p, true, true, 1) == OMACVM_GP_NONE && omacvm_gp_due_at(&p) == 0,
          "switch on, window seen: nothing");

    /* The switch off while a pending "unseen" waits: it never comes. */
    p = fresh();
    omacvm_gp_feed(&p, true, false, 0);
    omacvm_gp_feed(&p, false, false, 1);
    check(omacvm_gp_due(&p, 5) == OMACVM_GP_NONE && omacvm_gp_due_at(&p) == 0, "switch off before it was due: never told");

    /* Never paused: no hold, frames are not counted. */
    p = fresh();
    check(!omacvm_gp_keep(&p, false, 1) && omacvm_gp_frame(&p) == 0, "never paused: nothing kept, nothing counted");
    return fails ? 1 : 0;
}
