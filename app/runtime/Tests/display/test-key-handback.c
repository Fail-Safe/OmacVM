/*
 * Unit test for ui/omacvm-key-handback.h (#563: a click in another
 * display's window keeps the pointer and the keyboard with the VM).
 *
 * A small model of ui/cocoa.m stands in for QEMU: the main window's
 * windowDidResignKey: (keep, or let go: the guard's hold with its warp, the
 * grab with the Mac's cursor shown, held keys released), the head window's
 * mouseDown: (handKeyBack, then the click, which takes the pointer again if
 * it was let go: the cursor hidden again) and the next turn of the main loop
 * (omacvm_handback_settle). AppKit's side: a click in a head window makes it
 * key first (the main window resigns), then its mouseDown: runs; the escape
 * combo or a swipe moves the main window's Space off its display and macOS
 * makes the head window key with no click; Command-Tab makes another app
 * active.
 *
 * Each case runs the new code and the old one (3.0.0 to 3.2.6: every resign
 * lets go). The click case shows the report in the model (the old code
 * shows and hides the Mac's cursor and releases a held Shift at every
 * click); every other case must end exactly as the old code does.
 *
 * cc -Wall -Werror -I<qemu>/ui test-key-handback.c -o t && ./t
 */
#include <stdio.h>
#include <string.h>

#include "omacvm-key-handback.h"

static int failures, checks;

#define CHECK(cond, ...) do { \
    checks++; \
    if (!(cond)) { \
        failures++; \
        printf("FAIL %s:%d: ", __FILE__, __LINE__); \
        printf(__VA_ARGS__); \
        printf("\n"); \
    } \
} while (0)

typedef struct World {
    bool old;           /* 3.0.0-3.2.6: every resign lets go */
    OmacVMHandback hb;
    bool settle_due;    /* the dispatch_async of a kept resign */
    /* AppKit */
    bool main_key, head_key, main_visible, main_space, active;
    /* QEMU */
    bool grabbed;
    bool guard_held;    /* the full-screen guard holds the Mac's cursor */
    bool cursor_hidden;
    int shows, hides;   /* Mac cursor changes */
    int warps;          /* the guard's let-go warps */
    int keys_held;      /* keys down in the guest */
    int keys_released;  /* released by raiseAllKeys */
    int clicks;         /* button-downs the guest got */
} World;

typedef enum Ev { EV_NONE, EV_CLICK_HEAD, EV_CLICK_MAIN, EV_KEY, EV_GESTURE } Ev;

static World world(bool old)
{
    World w;

    memset(&w, 0, sizeof(w));
    w.old = old;
    w.main_key = true;
    w.main_visible = true;
    w.main_space = true;
    w.active = true;
    w.grabbed = true;
    w.guard_held = true;
    w.cursor_hidden = true;
    w.keys_held = 1;    /* Shift, for a Shift-click */
    return w;
}

/* windowDidResignKey:'s old body: omacvm_pointer_left, ungrabMouse, raiseAllKeys. */
static void let_go(World *w)
{
    if (w->guard_held) {
        w->guard_held = false;
        w->warps++;
    }
    if (w->grabbed) {
        w->grabbed = false;
        if (w->cursor_hidden) {
            w->cursor_hidden = false;
            w->shows++;
        }
    }
    w->keys_released += w->keys_held;
    w->keys_held = 0;
}

/* The main window resigned key while AppKit handled event ev. */
static void resign(World *w, Ev ev)
{
    OmacVMResignIn in = {
        .click = ev == EV_CLICK_HEAD || ev == EV_CLICK_MAIN,
        .in_head = ev == EV_CLICK_HEAD,
        .main_visible = w->main_visible,
        .main_space = w->main_space,
        .active = w->active,
    };

    w->main_key = false;
    if (!w->old && omacvm_handback_keep(&w->hb, &in)) {
        w->settle_due = true;
        return;
    }
    let_go(w);
}

/* The head view's mouseDown: (handKeyBack, then omacvmHeadEvent). */
static void head_mouse_down(World *w)
{
    if (omacvm_handback_ok(w->main_visible, w->main_space, w->active, w->main_key)) {
        w->main_key = true;
        w->head_key = false;
    }
    if (!w->grabbed) {
        w->grabbed = true;
        if (!w->cursor_hidden) {
            w->cursor_hidden = true;
            w->hides++;
        }
    }
    w->clicks++;
}

/* The main loop's next turn. */
static void end_turn(World *w)
{
    if (w->settle_due) {
        w->settle_due = false;
        if (omacvm_handback_settle(&w->hb, w->main_key)) {
            let_go(w);
        }
    }
}

/* A click in a head window: it becomes key (if the main one is), then its mouseDown:. */
static void click_head(World *w, bool reaches_view)
{
    if (w->main_key) {
        w->head_key = true;
        resign(w, EV_CLICK_HEAD);
    }
    if (reaches_view) {
        head_mouse_down(w);
    }
    end_turn(w);
}

/* macOS made the head window key with no click (escape combo, swipe) or another app came. */
static void key_away(World *w, Ev ev)
{
    if (w->main_key) {
        resign(w, ev);
    }
    end_turn(w);
}

static bool same_end(const World *a, const World *b)
{
    return a->grabbed == b->grabbed && a->guard_held == b->guard_held &&
           a->cursor_hidden == b->cursor_hidden && a->shows == b->shows &&
           a->hides == b->hides && a->warps == b->warps &&
           a->keys_held == b->keys_held && a->keys_released == b->keys_released &&
           a->main_key == b->main_key && a->clicks == b->clicks;
}

static void dump(const char *what, const World *w)
{
    printf("  %s: grabbed %d held %d hidden %d shows %d hides %d warps %d keys %d/%d key %d clicks %d\n",
           what, w->grabbed, w->guard_held, w->cursor_hidden, w->shows, w->hides, w->warps,
           w->keys_held, w->keys_released, w->main_key, w->clicks);
}

static void test_rule(void)
{
    for (int i = 0; i < 16; i++) {
        bool v = i & 1, s = i & 2, a = i & 4, k = i & 8;
        CHECK(omacvm_handback_ok(v, s, a, k) == (v && s && a && !k),
              "handKeyBack's rule visible %d space %d active %d key %d", v, s, a, k);
    }
}

/* The user's case: clicks on the external display's bar, Shift held. */
static void test_click_head(void)
{
    World n = world(false), o = world(true);

    for (int i = 0; i < 3; i++) {
        click_head(&n, true);
        click_head(&o, true);
    }
    CHECK(n.grabbed && n.main_key && n.clicks == 3, "the clicks reach the VM, the main window keeps the key");
    CHECK(n.shows == 0 && n.hides == 0 && n.cursor_hidden,
          "the Mac's cursor is never shown at a click (shows %d hides %d)", n.shows, n.hides);
    CHECK(n.guard_held && n.warps == 0, "the guard keeps its hold, no let-go warp (warps %d)", n.warps);
    CHECK(n.keys_held == 1 && n.keys_released == 0, "a held Shift stays held (released %d)", n.keys_released);
    CHECK(!n.hb.pending && !n.settle_due, "nothing left pending");
    /* The old code: what #563 removes. */
    CHECK(o.shows == 3 && o.hides == 3 && o.warps == 1 && o.keys_released == 1,
          "the model's old code shows and hides the cursor at every click (shows %d hides %d warps %d)",
          o.shows, o.hides, o.warps);
    if (failures) {
        dump("new", &n);
        dump("old", &o);
    }
}

/* Every resign that is not a click's hand-back lets go exactly as before. */
static void test_same_as_before(void)
{
    struct {
        const char *what;
        Ev ev;
        bool space, active, visible;
        bool click;         /* a click in the head window, not a key change alone */
        bool reaches_view;
    } c[] = {
        { "escape combo (the main window's Space left its display)", EV_KEY, false, true, true, false, false },
        { "swipe out (the main window's Space left its display)", EV_GESTURE, false, true, true, false, false },
        { "Command-Tab (another app in front)", EV_KEY, true, false, true, false, false },
        { "Mission Control / another Space, no event of ours", EV_NONE, false, true, true, false, false },
        { "the head window made key without a click", EV_NONE, true, true, true, false, false },
        { "a click in the head window with the main window's Space not shown", EV_CLICK_HEAD, false, true, true, true, true },
        { "a click in the head window with QEMU not in front", EV_CLICK_HEAD, true, false, true, true, true },
        { "a click in the head window with the main window hidden", EV_CLICK_HEAD, true, true, false, true, true },
        { "a resign at a click in the main window", EV_CLICK_MAIN, true, true, true, false, false },
    };

    for (size_t i = 0; i < sizeof(c) / sizeof(c[0]); i++) {
        World n = world(false), o = world(true);
        World *ws[2] = { &n, &o };

        for (int j = 0; j < 2; j++) {
            ws[j]->main_space = c[i].space;
            ws[j]->active = c[i].active;
            ws[j]->main_visible = c[i].visible;
            if (c[i].click) {
                click_head(ws[j], c[i].reaches_view);
            } else {
                key_away(ws[j], c[i].ev);
            }
        }
        CHECK(same_end(&n, &o), "%s: ends as before", c[i].what);
        /* a click takes the pointer again afterwards (as before); a key change does not */
        CHECK(n.warps == 1 && n.keys_released == 1 && n.grabbed == c[i].click, "%s: lets go", c[i].what);
        CHECK(!n.hb.pending, "%s: nothing pending", c[i].what);
        if (!same_end(&n, &o)) {
            dump("new", &n);
            dump("old", &o);
        }
    }
}

/* The click never reached the head view (the key stayed there): let go on the next turn. */
static void test_key_not_back(void)
{
    World n = world(false), o = world(true);

    n.head_key = true;
    resign(&n, EV_CLICK_HEAD);
    CHECK(n.grabbed && n.settle_due, "kept until the turn ends");
    end_turn(&n);
    o.head_key = true;
    resign(&o, EV_CLICK_HEAD);
    end_turn(&o);
    CHECK(same_end(&n, &o) && !n.grabbed && n.keys_released == 1,
          "the key did not come back: the let-go runs, as before");
}

/* The settle alone. */
static void test_settle(void)
{
    OmacVMHandback h = { false };
    OmacVMResignIn in = { true, true, true, true, true };

    CHECK(!omacvm_handback_settle(&h, false), "nothing kept: no let-go from the settle");
    CHECK(omacvm_handback_keep(&h, &in) && h.pending, "a click's resign is kept");
    CHECK(!omacvm_handback_settle(&h, true), "the key came back: no let-go");
    CHECK(!h.pending, "settled");
    CHECK(omacvm_handback_keep(&h, &in), "kept again");
    CHECK(omacvm_handback_keep(&h, &in), "a second click in the same turn");
    CHECK(omacvm_handback_settle(&h, false), "the key is not back: let go");
    CHECK(!omacvm_handback_settle(&h, false), "the second settle of that turn lets go no more");
    for (int i = 0; i < 32; i++) {
        OmacVMResignIn x = { i & 1, i & 2, i & 4, i & 8, i & 16 };
        OmacVMHandback g = { false };
        bool want = i == 31;

        CHECK(omacvm_handback_keep(&g, &x) == want && g.pending == want,
              "kept only for a click in a head window with the hand-back's rule (case %d)", i);
    }
}

int main(void)
{
    test_rule();
    test_click_head();
    test_same_as_before();
    test_key_not_back();
    test_settle();
    if (failures) {
        printf("test-key-handback: %d of %d checks FAILED\n", failures, checks);
        return 1;
    }
    printf("test-key-handback: %d checks ok\n", checks);
    return 0;
}
