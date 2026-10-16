// A virtual Mac display for testing OmacVM.app's external displays without a
// monitor (CoreGraphics' private CGVirtualDisplay, as BetterDisplay and
// Chromium's tests use it). The display exists while this process runs:
// killing it is unplugging it.
//
//   clang -fobjc-arc -framework Foundation -framework CoreGraphics \
//     virtual-display.m -o virtual-display
//   ./virtual-display WIDTHxHEIGHT [--hidpi] [--at X,Y | --main] [--name NAME] [--serial N]
//
// WIDTHxHEIGHT is the size in points; --hidpi gives it 2x pixels (Retina).
// --at puts its top-left corner at X,Y in the Mac's display arrangement
// (points, origin at the main display's top-left). --main makes it the main
// display (the menu bar): the whole arrangement moves so that it sits at
// the origin. --serial gives it that serial number (default: the pid; the
// same serial is the same monitor to macOS). Prints "id=<display id>"
// once the display is up.
//
// While it runs (#428: a display that goes for a moment):
//   kill -USR1  unplugs it (the process stays)   prints "state=off"
//   kill -USR2  plugs the same display in again  prints "state=on id=<display id>"
//   kill -HUP   to a 1 x 1 mode and back (macOS shows a waking display like
//               that for a few seconds)          prints "state=tiny ..." / "state=on ..."
#import <CoreGraphics/CoreGraphics.h>
#import <Foundation/Foundation.h>
#include <signal.h>

@class CGVirtualDisplay;

@interface CGVirtualDisplayDescriptor : NSObject
@property(retain, nonatomic) dispatch_queue_t queue;
@property(retain, nonatomic) NSString *name;
@property(nonatomic) unsigned int maxPixelsHigh;
@property(nonatomic) unsigned int maxPixelsWide;
@property(nonatomic) CGSize sizeInMillimeters;
@property(nonatomic) unsigned int serialNum;
@property(nonatomic) unsigned int productID;
@property(nonatomic) unsigned int vendorID;
@property(copy, nonatomic) void (^terminationHandler)(id, CGVirtualDisplay *);
@end

@interface CGVirtualDisplayMode : NSObject
- (instancetype)initWithWidth:(NSUInteger)width height:(NSUInteger)height refreshRate:(CGFloat)refreshRate;
@end

@interface CGVirtualDisplaySettings : NSObject
@property(retain, nonatomic) NSArray *modes;
@property(nonatomic) unsigned int hiDPI;
@end

@interface CGVirtualDisplay : NSObject
@property(readonly, nonatomic) CGDirectDisplayID displayID;
- (instancetype)initWithDescriptor:(CGVirtualDisplayDescriptor *)descriptor;
- (BOOL)applySettings:(CGVirtualDisplaySettings *)settings;
@end

static void quit(int sig) { exit(0); }

static unsigned w, h, serial;
static BOOL hidpi, place, makeMain, tiny;
static int x, y;
static NSString *name;
static CGVirtualDisplay *display;

static BOOL apply(unsigned mw, unsigned mh)
{
    CGVirtualDisplaySettings *s = [[CGVirtualDisplaySettings alloc] init];
    s.hiDPI = hidpi && mw > 1;
    // The mode is in points; with hiDPI macOS backs it with 2x pixels.
    s.modes = @[[[CGVirtualDisplayMode alloc] initWithWidth:mw height:mh refreshRate:60]];
    return [display applySettings:s];
}

static CGDirectDisplayID plug(void)
{
    unsigned k = hidpi ? 2 : 1;
    CGVirtualDisplayDescriptor *d = [[CGVirtualDisplayDescriptor alloc] init];
    d.queue = dispatch_get_main_queue();
    d.name = name;
    d.maxPixelsWide = w * k;
    d.maxPixelsHigh = h * k;
    // About 110 points per inch, like a normal desktop monitor.
    d.sizeInMillimeters = CGSizeMake(w * 25.4 / 110.0, h * 25.4 / 110.0);
    d.vendorID = 0x0ac7;  // made up
    d.productID = 0x1234 + (serial & 0xff);
    d.serialNum = serial;
    d.terminationHandler = ^(id a, CGVirtualDisplay *b) { exit(0); };
    display = [[CGVirtualDisplay alloc] initWithDescriptor:d];
    if (!display) {
        fprintf(stderr, "virtual-display: could not create the display\n");
        return 0;
    }
    if (!apply(w, h)) {
        fprintf(stderr, "virtual-display: settings refused\n");
        return 0;
    }
    CGDirectDisplayID id = display.displayID;
    if (makeMain) {
        // The main display is the one at (0,0): move every display by this one's place.
        [[NSRunLoop mainRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:1.0]];
        CGRect self_ = CGDisplayBounds(id);
        CGDirectDisplayID all[16];
        uint32_t n = 0;
        CGDisplayConfigRef config;
        if (CGGetOnlineDisplayList(16, all, &n) == kCGErrorSuccess &&
            CGBeginDisplayConfiguration(&config) == kCGErrorSuccess) {
            for (uint32_t i = 0; i < n; i++) {
                CGRect b = CGDisplayBounds(all[i]);
                CGConfigureDisplayOrigin(config, all[i], (int32_t)(b.origin.x - self_.origin.x),
                                         (int32_t)(b.origin.y - self_.origin.y));
            }
            CGCompleteDisplayConfiguration(config, kCGConfigureForSession);
        }
    }
    if (place) {
        // The new display needs a moment before it can be placed.
        [[NSRunLoop mainRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:1.0]];
        CGDisplayConfigRef config;
        if (CGBeginDisplayConfiguration(&config) == kCGErrorSuccess) {
            CGConfigureDisplayOrigin(config, id, x, y);
            CGCompleteDisplayConfiguration(config, kCGConfigureForSession);
        }
    }
    return id;
}

static void state(const char *what)
{
    CGDirectDisplayID id = display ? display.displayID : 0;
    // macOS takes a moment to show the change.
    [[NSRunLoop mainRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:1.0]];
    CGRect b = id ? CGDisplayBounds(id) : CGRectZero;
    printf("state=%s id=%u active=%d size=%.0fx%.0f\n", what, id,
           id ? (int)CGDisplayIsActive(id) : 0, b.size.width, b.size.height);
    fflush(stdout);
}

static dispatch_source_t on_signal(int sig, void (^handler)(void))
{
    signal(sig, SIG_IGN);
    dispatch_source_t src = dispatch_source_create(DISPATCH_SOURCE_TYPE_SIGNAL, sig, 0,
                                                   dispatch_get_main_queue());
    dispatch_source_set_event_handler(src, handler);
    dispatch_resume(src);
    return src;
}

int main(int argc, const char **argv)
{
    @autoreleasepool {
        name = @"OmacVM Test Display";
        serial = (unsigned)getpid();
        for (int i = 1; i < argc; i++) {
            if (!strcmp(argv[i], "--hidpi")) {
                hidpi = YES;
            } else if (!strcmp(argv[i], "--main")) {
                makeMain = YES;
            } else if (!strcmp(argv[i], "--at") && i + 1 < argc) {
                place = sscanf(argv[++i], "%d,%d", &x, &y) == 2;
            } else if (!strcmp(argv[i], "--name") && i + 1 < argc) {
                name = [NSString stringWithUTF8String:argv[++i]];
            } else if (!strcmp(argv[i], "--serial") && i + 1 < argc) {
                serial = (unsigned)strtoul(argv[++i], NULL, 0);
            } else if (sscanf(argv[i], "%ux%u", &w, &h) != 2) {
                fprintf(stderr, "usage: virtual-display WIDTHxHEIGHT [--hidpi] [--at X,Y | --main] [--name NAME] [--serial N]\n");
                return 2;
            }
        }
        if (!w || !h) {
            fprintf(stderr, "usage: virtual-display WIDTHxHEIGHT [--hidpi] [--at X,Y | --main] [--name NAME] [--serial N]\n");
            return 2;
        }
        CGDirectDisplayID id = plug();
        if (!id) {
            return 1;
        }
        dispatch_source_t s1 = on_signal(SIGUSR1, ^{
            display = nil;   // released: unplugged
            tiny = NO;
            state("off");
        });
        dispatch_source_t s2 = on_signal(SIGUSR2, ^{
            if (!display && plug()) {
                state("on");
            }
        });
        dispatch_source_t s3 = on_signal(SIGHUP, ^{
            if (!display) {
                return;
            }
            tiny = !tiny;
            if (!apply(tiny ? 1 : w, tiny ? 1 : h)) {
                fprintf(stderr, "virtual-display: %s mode refused\n", tiny ? "1 x 1" : "its");
                tiny = !tiny;
            }
            state(tiny ? "tiny" : "on");
        });
        (void)s1; (void)s2; (void)s3;
        signal(SIGTERM, quit);
        signal(SIGINT, quit);
        printf("id=%u\n", id);
        fflush(stdout);
        [[NSRunLoop mainRunLoop] run];
    }
    return 0;
}
