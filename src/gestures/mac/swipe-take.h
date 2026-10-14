// Swipe out to macOS that follows the fingers (#342): which three/four-finger
// swipe the Mac takes from the guest at the VM's first or last workspace, and
// how far macOS's Space has come with it. No device, no window server, so
// test-escape.c checks it with made-up frames.
//
// The guest says on every workspace change where a swipe would go ("E": for
// fingers going left and right, the macOS Space on that side, or the guest's
// own workspace swipe). A swipe that begins while one way leaves the VM, with
// a macOS Space on that side, is held back from the guest until its way is
// clear: TAKE_MIN of the trackpad's width, mostly sideways. Outward, it is the
// Mac's (the guest never sees it); any other way, the guest gets every held
// frame at once and the rest as usual. Taken, macOS's Space follows the
// fingers (one Space per `travel` of the trackpad's width) and at the lift it
// finishes or goes back, as a trackpad's own swipe does: back when the
// fingers were going back, else finished past half a Space or with a flick.
#ifndef OMACVM_SWIPE_TAKE_H
#define OMACVM_SWIPE_TAKE_H
#include <math.h>
#include <string.h>

#define TAKE_MIN 0.02          // trackpad widths of travel that tell the way
#define TAKE_RATIO 1.5         // ... and this much more sideways than up or down (the guest's SWIPE_OUT_RATIO)
#define TAKE_HOLD 0.25         // s: a touch whose way is not clear by then goes to the guest
#define TAKE_TRAVEL 0.5        // trackpad widths per Space (SwipeOutTravel changes it)
#define TAKE_VEL_TIME 0.06     // s of movement the lift's speed is read over
#define TAKE_BACK (-0.3)       // Spaces/s: going back at least this fast at the lift = back into the VM
#define TAKE_FLICK 0.8         // Spaces/s: this fast toward the Space finishes it ...
#define TAKE_FLICK_MIN 0.05    // ... from this far on
#define TAKE_STEP_MIN 0.12     // one-step way (macOS does not follow): trackpad widths, as the guest's SWIPE_OUT_MIN
#define TAKE_HIST 16

enum { TAKE_IDLE, TAKE_WATCH, TAKE_TAKEN, TAKE_PASS, TAKE_DONE };
// What to do with a frame: send it to the guest; keep it; send the kept ones
// and then this one; the swipe is taken now (macOS's swipe begins); it moved;
// it ended (commit says how); nothing (the rest of a taken swipe).
enum { TK_FORWARD, TK_HOLD, TK_FLUSH, TK_BEGIN, TK_MOVE, TK_END, TK_DROP };

typedef struct {
  int state;
  int side[2];          // fingers going left [0], right [1] with this many fingers: -1 the Space on the left,
                        // +1 on the right, 0 the guest's
  int toward;           // taken: the macOS side
  int way;              // taken: the fingers' way (-1 left, +1 right)
  double t0;            // when the swipe began
  double dx, dy;        // its travel (trackpad widths / heights)
  double along;         // taken: travel toward the Space, from the start (trackpad widths)
  double travel;        // trackpad widths per Space
  double progress;      // taken: Spaces shown so far (0 and up)
  int commit;           // at TK_END: finish (1) or back (0)
  double speed;         // at TK_END: Spaces/s toward the Space
  struct { double t, a; } hist[TAKE_HIST];
  int nh;
} SwipeTake;

static inline void takeReset(SwipeTake *s) { memset(s, 0, sizeof *s); }

static inline void takeNote(SwipeTake *s, double now) {
  if (s->nh == TAKE_HIST) { memmove(s->hist, s->hist + 1, sizeof s->hist[0] * (TAKE_HIST - 1)); s->nh--; }
  s->hist[s->nh].t = now; s->hist[s->nh].a = s->along; s->nh++;
}

// Spaces per second toward the Space over the last TAKE_VEL_TIME.
static inline double takeSpeed(const SwipeTake *s, double now) {
  if (s->nh < 2 || s->travel <= 0) return 0;
  int i = s->nh - 2;
  while (i > 0 && now - s->hist[i].t < TAKE_VEL_TIME) i--;
  double dt = s->hist[s->nh - 1].t - s->hist[i].t;
  return dt > 0.004 ? (s->hist[s->nh - 1].a - s->hist[i].a) / dt / s->travel : 0;
}

// The lift: finish or go back.
static inline int takeCommit(double progress, double speed) {
  if (speed <= TAKE_BACK) return 0;
  if (progress >= 0.5) return 1;
  return speed >= TAKE_FLICK && progress >= TAKE_FLICK_MIN;
}

// One frame: k fingers, moved by ddx, ddy (trackpad widths / heights) since
// the last frame, at time now (s). watchL/watchR: where fingers going left /
// right could go out with any count (read when a swipe begins: is it worth
// holding back); sideL/sideR: where they go out with this frame's count (the
// guest's workspace swipes may use 4 fingers and give 3 to something else;
// the count when the way is clear decides, as more fingers may still come
// down). travel: trackpad widths per Space. Returns what to do (TK_*).
static inline int takeFrame(SwipeTake *s, int k, int watchL, int watchR, int sideL, int sideR, double ddx, double ddy,
                            double travel, double now) {
  switch (s->state) {
  case TAKE_IDLE:
    if (k < 3) return TK_FORWARD;
    takeReset(s);
    s->t0 = now; s->travel = travel > 0 ? travel : TAKE_TRAVEL;
    if (!watchL && !watchR) { s->state = TAKE_PASS; return TK_FORWARD; }
    s->state = TAKE_WATCH;
    // this frame's movement counts too (a Magic Mouse's swipe begins with its travel)
    __attribute__((fallthrough));
  case TAKE_WATCH: {
    if (k < 3) { s->state = TAKE_IDLE; return TK_FLUSH; }   // lifted first (a tap): all of it to the guest
    s->side[0] = sideL; s->side[1] = sideR;
    s->dx += ddx; s->dy += ddy;
    double ax = fabs(s->dx), ay = fabs(s->dy);
    if (ax >= TAKE_MIN && ax >= TAKE_RATIO * ay) {
      int w = s->dx < 0 ? 0 : 1;
      if (!s->side[w]) { s->state = TAKE_PASS; return TK_FLUSH; }   // inward: Hyprland's swipe
      s->state = TAKE_TAKEN; s->way = w ? 1 : -1; s->toward = s->side[w];
      s->along = ax; s->progress = ax / s->travel;
      takeNote(s, now);
      return TK_BEGIN;
    }
    if (hypot(ax, ay) >= TAKE_MIN || now - s->t0 >= TAKE_HOLD) { s->state = TAKE_PASS; return TK_FLUSH; }
    return TK_HOLD;
  }
  case TAKE_PASS:
    if (k < 3) s->state = TAKE_IDLE;
    return TK_FORWARD;
  case TAKE_TAKEN:
    if (k < 3) {
      s->speed = takeSpeed(s, now);
      s->commit = takeCommit(s->progress, s->speed);
      s->state = k ? TAKE_DONE : TAKE_IDLE;
      return TK_END;
    }
    s->along += s->way * ddx;
    s->progress = s->along > 0 ? s->along / s->travel : 0;   // back past the start: the VM's Space, no further
    takeNote(s, now);
    return TK_MOVE;
  case TAKE_DONE:
  default:
    if (k == 0) s->state = TAKE_IDLE;
    return TK_DROP;
  }
}
#endif
