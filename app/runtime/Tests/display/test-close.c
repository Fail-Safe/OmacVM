/*
 * Closing the window (omacvm-close.h, from omacvm-cocoa-close-logic.patch):
 * which setting counts and what it does. test-close.sh builds it against
 * the patch.
 */
#include <stdio.h>
#include "omacvm-close.h"

static int fails;
static void check(int ok, const char *what)
{
    printf("%s %s\n", ok ? "ok  " : "FAIL", what);
    if (!ok) {
        fails++;
    }
}

int main(void)
{
    check(omacvm_close_parse("shutdown") == OMACVM_CLOSE_SHUTDOWN, "shutdown: shut down");
    check(omacvm_close_parse("keepRunning") == OMACVM_CLOSE_KEEP, "keepRunning: keep running");
    check(omacvm_close_parse("ask") == OMACVM_CLOSE_ASK, "ask: ask");
    check(omacvm_close_parse(NULL) == OMACVM_CLOSE_SHUTDOWN, "not set: shut down (as before the setting)");
    check(omacvm_close_parse("") == OMACVM_CLOSE_SHUTDOWN && omacvm_close_parse("KeepRunning") == OMACVM_CLOSE_SHUTDOWN &&
          omacvm_close_parse("keep") == OMACVM_CLOSE_SHUTDOWN && omacvm_close_parse("Ask") == OMACVM_CLOSE_SHUTDOWN &&
          omacvm_close_parse("keepRunning ") == OMACVM_CLOSE_SHUTDOWN,
          "anything else (case, a typo, a space): shut down");
    check(omacvm_close_pick(true, "keepRunning", "shutdown") == OMACVM_CLOSE_KEEP,
          "QEMU as the OmacVM app: the app's setting now (changed while the VM runs) over the start's");
    check(omacvm_close_pick(true, NULL, "keepRunning") == OMACVM_CLOSE_SHUTDOWN,
          "... the setting taken back to the default while the VM runs: shut down");
    check(omacvm_close_pick(false, "ask", "keepRunning") == OMACVM_CLOSE_KEEP,
          "not the OmacVM app (a development build): OMACVM_CLOSE_ACTION from the start");
    check(omacvm_close_pick(false, NULL, NULL) == OMACVM_CLOSE_SHUTDOWN, "... nothing passed: shut down");
    check(!strcmp(omacvm_close_name(OMACVM_CLOSE_KEEP), "keepRunning") && !strcmp(omacvm_close_name(OMACVM_CLOSE_ASK), "ask") &&
          !strcmp(omacvm_close_name(OMACVM_CLOSE_SHUTDOWN), "shutdown"), "names as the setting's values");
    return fails ? 1 : 0;
}
