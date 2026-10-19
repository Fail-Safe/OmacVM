// cursor-tool: the Mac's real cursor for src/tests/pointer-reveal-vm.sh.
//   state            visible=0|1 empty=0|1|? at X,Y   (empty: the image shown has no pixel, ?: unknown)
//   bg OP...         as a background process that hides and shows the cursor the way OmacVM
//                    Gestures did over full-screen VMs (window server property
//                    SetsCursorInBackground, CGDisplayHideCursor/ShowCursor): h, s, or seconds to wait;
//                    prints the state after each
//   win PID          the biggest normal window of PID: X Y W H (points, top left)
//   path X1 Y1 X2 Y2 N MS   N+1 pointer moves from X1,Y1 to X2,Y2, MS apart (HID level)
//   click X Y        a left click (HID level)
//   key-ctrl-opt-g   Ctrl+Option+G (QEMU's let-go of the pointer)
//   key-ctrl-opt-esc Ctrl+Option+Esc (OmacVM Gestures' escape combo)
//   front PID        PID's app to the front through Accessibility (no input events)
//   app              the app in front: PID name
// Synthetic input only over the test VM's window, on a Mac nobody uses (the harness checks).
// clang -fobjc-arc -framework AppKit -framework ApplicationServices cursor-tool.m -o cursor-tool
#import <AppKit/AppKit.h>
#import <ApplicationServices/ApplicationServices.h>
#include <dlfcn.h>

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
static int visible(void) { return CGCursorIsVisible() ? 1 : 0; }
#pragma clang diagnostic pop

// 1: the image the window server shows has no pixel, 0: it has some, -1: unknown.
static int empty_image(void) {
  NSCursor *c = [NSCursor currentSystemCursor];
  CGImageRef cg = c ? [[c image] CGImageForProposedRect:NULL context:nil hints:nil] : NULL;
  if (!cg) return -1;
  size_t w = CGImageGetWidth(cg), h = CGImageGetHeight(cg);
  if (!w || !h || w > 1024 || h > 1024) return -1;
  NSMutableData *buf = [NSMutableData dataWithLength:w * h * 4];
  CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
  CGContextRef ctx = CGBitmapContextCreate(buf.mutableBytes, w, h, 8, w * 4, cs, (CGBitmapInfo)kCGImageAlphaPremultipliedLast);
  CGColorSpaceRelease(cs);
  if (!ctx) return -1;
  CGContextDrawImage(ctx, CGRectMake(0, 0, w, h), cg);
  CGContextRelease(ctx);
  const uint8_t *p = buf.bytes;
  for (size_t i = 3; i < w * h * 4; i += 4) if (p[i]) return 0;
  return 1;
}

static void state(void) {
  CGEventRef e = CGEventCreate(NULL);
  CGPoint p = CGEventGetLocation(e);
  CFRelease(e);
  int em = empty_image();
  printf("visible=%d empty=%s at %.0f,%.0f\n", visible(), em < 0 ? "?" : em ? "1" : "0", p.x, p.y);
  fflush(stdout);
}

static void post_mouse(CGEventType t, CGPoint p) {
  CGEventSourceRef src = CGEventSourceCreate(kCGEventSourceStateHIDSystemState);
  CGEventRef e = CGEventCreateMouseEvent(src, t, p, kCGMouseButtonLeft);
  CGEventPost(kCGHIDEventTap, e);
  CFRelease(e);
  CFRelease(src);
}

static void post_key(CGKeyCode k, bool down, CGEventFlags f) {
  CGEventSourceRef src = CGEventSourceCreate(kCGEventSourceStateHIDSystemState);
  CGEventRef e = CGEventCreateKeyboardEvent(src, k, down);
  CGEventSetFlags(e, f);
  CGEventPost(kCGHIDEventTap, e);
  CFRelease(e);
  CFRelease(src);
}

int main(int argc, char **argv) {
  @autoreleasepool {
    [NSApplication sharedApplication];
    NSString *cmd = argc > 1 ? @(argv[1]) : @"";
    if ([cmd isEqual:@"state"]) { state(); return 0; }
    if ([cmd isEqual:@"bg"]) {
      typedef int (*Conn)(void);
      typedef int (*Set)(int, int, CFStringRef, CFTypeRef);
      Conn conn = (Conn)dlsym(RTLD_DEFAULT, "_CGSDefaultConnection");
      Set set = (Set)dlsym(RTLD_DEFAULT, "CGSSetConnectionProperty");
      if (!conn || !set || set(conn(), conn(), CFSTR("SetsCursorInBackground"), kCFBooleanTrue)) {
        printf("bg: SetsCursorInBackground refused\n"); return 1;
      }
      for (int i = 2; i < argc; i++) {
        if (!strcmp(argv[i], "h")) CGDisplayHideCursor(kCGNullDirectDisplay);
        else if (!strcmp(argv[i], "s")) CGDisplayShowCursor(kCGNullDirectDisplay);
        else usleep((useconds_t)(atof(argv[i]) * 1e6));
        usleep(300000);
        printf("bg %s: ", argv[i]); state();
      }
      return 0;
    }
    if ([cmd isEqual:@"win"] && argc > 2) {
      pid_t pid = atoi(argv[2]);
      NSArray *all = CFBridgingRelease(CGWindowListCopyWindowInfo(kCGWindowListOptionAll, kCGNullWindowID));
      CGRect best = CGRectNull;
      for (NSDictionary *w in all) {
        if ([w[(id)kCGWindowOwnerPID] intValue] != pid || [w[(id)kCGWindowLayer] intValue] != 0) continue;
        CGRect r;
        if (!CGRectMakeWithDictionaryRepresentation((__bridge CFDictionaryRef)w[(id)kCGWindowBounds], &r)) continue;
        if (CGRectIsNull(best) || r.size.width * r.size.height > best.size.width * best.size.height) best = r;
      }
      if (CGRectIsNull(best)) { printf("none\n"); return 1; }
      printf("%.0f %.0f %.0f %.0f\n", best.origin.x, best.origin.y, best.size.width, best.size.height);
      return 0;
    }
    if ([cmd isEqual:@"path"] && argc > 7) {
      double x1 = atof(argv[2]), y1 = atof(argv[3]), x2 = atof(argv[4]), y2 = atof(argv[5]), ms = atof(argv[7]);
      int n = atoi(argv[6]);
      for (int i = 0; i <= n; i++) {
        double f = n ? (double)i / n : 1;
        post_mouse(kCGEventMouseMoved, CGPointMake(x1 + (x2 - x1) * f, y1 + (y2 - y1) * f));
        usleep((useconds_t)(ms * 1000));
      }
      return 0;
    }
    if ([cmd isEqual:@"click"] && argc > 3) {
      CGPoint p = CGPointMake(atof(argv[2]), atof(argv[3]));
      post_mouse(kCGEventLeftMouseDown, p);
      usleep(60000);
      post_mouse(kCGEventLeftMouseUp, p);
      return 0;
    }
    if ([cmd isEqual:@"key-ctrl-opt-g"]) {
      CGEventFlags f = kCGEventFlagMaskControl | kCGEventFlagMaskAlternate;
      post_key(59, true, kCGEventFlagMaskControl);   // left Control
      post_key(58, true, f);                         // left Option
      post_key(5, true, f);                          // G
      usleep(50000);
      post_key(5, false, f);
      post_key(58, false, kCGEventFlagMaskControl);
      post_key(59, false, 0);
      return 0;
    }
    if ([cmd isEqual:@"key-ctrl-opt-esc"]) {   // the escape combo (OmacVM Gestures)
      CGEventFlags f = kCGEventFlagMaskControl | kCGEventFlagMaskAlternate;
      post_key(59, true, kCGEventFlagMaskControl);
      post_key(58, true, f);
      post_key(53, true, f);                         // Esc
      usleep(50000);
      post_key(53, false, f);
      post_key(58, false, kCGEventFlagMaskControl);
      post_key(59, false, 0);
      return 0;
    }
    if ([cmd isEqual:@"front"] && argc > 2) {
      AXError e = AXUIElementSetAttributeValue(AXUIElementCreateApplication(atoi(argv[2])),
                                               kAXFrontmostAttribute, kCFBooleanTrue);
      printf("front %s: %s\n", argv[2], e == kAXErrorSuccess ? "ok" : "refused");
      return e == kAXErrorSuccess ? 0 : 1;
    }
    if ([cmd isEqual:@"app"]) {
      NSRunningApplication *a = [[NSWorkspace sharedWorkspace] frontmostApplication];
      printf("%d %s\n", a.processIdentifier, a.localizedName.UTF8String ?: "?");
      return 0;
    }
    fprintf(stderr, "usage: cursor-tool state | bg OP... | win PID | path X1 Y1 X2 Y2 N MS | click X Y | key-ctrl-opt-g | key-ctrl-opt-esc | front PID | app\n");
    return 2;
  }
}
