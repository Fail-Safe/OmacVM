// The pointer check's next look over a full-screen VM (cursor-rest.h):
// 120 Hz while the pointer moves, at rest 0.5 s with the rest tap, else 20 Hz.
//   clang -o /tmp/t test-cursor-rest.c && /tmp/t
#include <stdio.h>
#include "cursor-rest.h"

static int fails;
static void expect(const char *what, double got, double want) {
  int ok = got == want;
  printf("%s %s (got %g)\n", ok ? "ok  " : "FAIL", what, got);
  fails += !ok;
}

int main(void) {
  expect("moving: the timer's own 120 Hz", cursorNextLook(0.0, 0), 0);
  expect("moving, tap armed (just moved): 120 Hz", cursorNextLook(0.2, 1), 0);
  expect("a second at rest is not rest yet", cursorNextLook(CURSOR_REST_AFTER, 1), 0);
  expect("at rest with the tap: every 0.5 s", cursorNextLook(1.5, 1), CURSOR_REST_LOOK);
  expect("at rest without the tap: 20 Hz as before", cursorNextLook(1.5, 0), CURSOR_REST_EVERY);
  expect("long at rest with the tap: still 0.5 s", cursorNextLook(600, 1), 0.5);
  expect("the window list at rest comes on each 0.5 s look", CURSOR_WINDOWS_EVERY < CURSOR_REST_LOOK, 1);
  expect("and not on the 20 Hz ones", CURSOR_WINDOWS_EVERY > CURSOR_REST_EVERY, 1);
  return fails ? 1 : 0;
}
