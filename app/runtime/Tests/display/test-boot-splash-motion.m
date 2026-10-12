// test-boot-splash-motion.m: the start animation (OMACVM -> Omarchy's logo)
// plays with macOS's Reduce motion on too (the user's choice, 2026-10-12);
// only OMACVM_SPLASH_ANIMATION=0 gives the still logo. omacvm_intro_start()
// comes from the patched ui/cocoa.m (build-qemu-gpu-runtime.sh) or from
// omacvm-cocoa-boot-splash.patch (check-boot-splash.sh) as intro-start.inc,
// and runs here with NSWorkspace's Reduce motion answer replaced.
#import <Cocoa/Cocoa.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/runtime.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

// What omacvm_intro_start() uses of ui/cocoa.m.
static int shown = -1;   // omacvm_intro_show's argument: 1 = still, 0 = animated
static int holds;
static bool omacvm_overlay_ok;
static char logged[256];
static NSView *cocoaView;
static bool omacvm_splash_enabled(void) { return true; }
static bool cocoa_gl_present_on(void) { return true; }
static void omacvm_intro_show(bool still) { shown = still; }
static void omacvm_hold_start(void) { holds++; }
static void info_report(const char *fmt, ...)
{
    va_list ap;
    va_start(ap, fmt);
    vsnprintf(logged, sizeof(logged), fmt, ap);
    va_end(ap);
}

#include "intro-start.inc"

static BOOL reduce;
static BOOL fake_reduce(id self, SEL cmd)
{
    (void)self;
    (void)cmd;
    return reduce;
}

static int fails;
static void check(bool ok, const char *what)
{
    printf("%s %s\n", ok ? "ok  " : "FAIL", what);
    if (!ok) {
        fails++;
    }
}

static void run(BOOL reduce_motion, const char *animation)
{
    reduce = reduce_motion;
    if (animation) {
        setenv("OMACVM_SPLASH_ANIMATION", animation, 1);
    } else {
        unsetenv("OMACVM_SPLASH_ANIMATION");
    }
    shown = -1;
    logged[0] = 0;
    omacvm_intro_start();
}

int main(void)
{
    @autoreleasepool {
        (void)cocoaView;
        Method m = class_getInstanceMethod([NSWorkspace class],
                                           @selector(accessibilityDisplayShouldReduceMotion));
        if (!m) {
            printf("FAIL NSWorkspace has no accessibilityDisplayShouldReduceMotion\n");
            return 1;
        }
        method_setImplementation(m, (IMP)fake_reduce);
        reduce = YES;
        check([[NSWorkspace sharedWorkspace] accessibilityDisplayShouldReduceMotion],
              "the stand-in answers Reduce motion on");

        run(NO, NULL);
        check(shown == 0 && holds == 1 && omacvm_overlay_ok, "Reduce motion off: the animation plays");
        check(!strcmp(logged, "cocoa: start animation on"), "Reduce motion off: qemu.log says on");

        run(YES, NULL);
        check(shown == 0, "Reduce motion on: the animation plays anyway (no still logo)");
        check(strstr(logged, "on (macOS Reduce motion is on") == logged + strlen("cocoa: start animation "),
              "Reduce motion on: qemu.log names it and says on");

        run(YES, "0");
        check(shown == 1, "OMACVM_SPLASH_ANIMATION=0: the still logo");
        check(strstr(logged, "still (OMACVM_SPLASH_ANIMATION=0)") != NULL, "OMACVM_SPLASH_ANIMATION=0: qemu.log says why");

        run(NO, "1");
        check(shown == 0, "OMACVM_SPLASH_ANIMATION=1: the animation plays");
    }
    printf("test-boot-splash-motion: %s\n", fails ? "FAILED" : "the animation plays with Reduce motion on");
    return fails ? 1 : 0;
}
