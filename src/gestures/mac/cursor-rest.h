// The macOS pointer over a full-screen VM: when the pointer check looks next.
// While the pointer moves it looks 120 times a second (the timer's own
// interval). Once it has rested CURSOR_REST_AFTER seconds, a listen-only tap
// for the pointer's own events (moves, drags) wakes the check at its first
// move, so the check itself only looks every CURSOR_REST_LOOK seconds for
// windows that appear under a resting pointer (the Dock, a notification).
// Without that tap it looks every CURSOR_REST_EVERY seconds, as up to 3.1.15
// (PointerRestTap off, no Input Monitoring, a tap macOS took away).
// Pure: test-cursor-rest.c runs it.
#ifndef OMACVM_CURSOR_REST_H
#define OMACVM_CURSOR_REST_H

#define CURSOR_REST_AFTER 1.0
#define CURSOR_REST_EVERY 0.05
#define CURSOR_REST_LOOK 0.5
// The window list again after this long at rest (a little under the look,
// so a look that comes a few milliseconds early still makes it).
#define CURSOR_WINDOWS_EVERY 0.45

// Seconds until the next look, `sinceMove` seconds after the last move; 0:
// keep the timer's own 120 Hz.
static inline double cursorNextLook(double sinceMove, int tapArmed) {
  if (sinceMove <= CURSOR_REST_AFTER) return 0;
  return tapArmed ? CURSOR_REST_LOOK : CURSOR_REST_EVERY;
}

#endif
