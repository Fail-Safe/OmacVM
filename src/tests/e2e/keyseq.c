// keyseq: keyboard and pointer events with exact flags, posted to one process
// (CGEventPostToPid: no other app sees them) or at the HID level (the whole Mac).
// For src/tests/e2e/modifier-keys.sh (#412).
//   keyseq --pid PID | --hid  [--gap MS]  EV...
//   EV: fc:CODE:FLAGS (flagsChanged)  kd:CODE:FLAGS  ku:CODE:FLAGS  ptr:FLAGS (pointer moved)  wait:MS
//   CODE: macOS virtual key code; FLAGS: CGEventFlags (hex)
#include <ApplicationServices/ApplicationServices.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

int main(int argc, char **argv)
{
    pid_t pid = 0; int hid = 0, gap = 40, i = 1;
    for (; i < argc && argv[i][0] == '-'; i++) {
        if (!strcmp(argv[i], "--pid") && i + 1 < argc) pid = atoi(argv[++i]);
        else if (!strcmp(argv[i], "--hid")) hid = 1;
        else if (!strcmp(argv[i], "--gap") && i + 1 < argc) gap = atoi(argv[++i]);
        else { fprintf(stderr, "bad option %s\n", argv[i]); return 2; }
    }
    if (!pid == !hid) { fprintf(stderr, "usage: keyseq --pid PID | --hid [--gap MS] EV...\n"); return 2; }
    CGEventSourceRef src = CGEventSourceCreate(kCGEventSourceStatePrivate);
    for (; i < argc; i++) {
        char kind[8] = {0}; unsigned code = 0; unsigned long long flags = 0; CGEventRef e = NULL;
        if (sscanf(argv[i], "wait:%u", &code) == 1) { usleep(code * 1000); continue; }
        if (sscanf(argv[i], "ptr:%llx", &flags) == 1) {
            CGEventRef cur = CGEventCreate(NULL);
            CGPoint at = CGEventGetLocation(cur); CFRelease(cur);
            e = CGEventCreateMouseEvent(src, kCGEventMouseMoved, at, kCGMouseButtonLeft);
        } else if (sscanf(argv[i], "%2[a-z]:%i:%llx", kind, &code, &flags) == 3) {
            e = CGEventCreateKeyboardEvent(src, (CGKeyCode)code, strcmp(kind, "ku") != 0);
            if (!strcmp(kind, "fc")) CGEventSetType(e, kCGEventFlagsChanged);
            else if (strcmp(kind, "kd") && strcmp(kind, "ku")) { fprintf(stderr, "bad event %s\n", argv[i]); return 2; }
        } else { fprintf(stderr, "bad event %s\n", argv[i]); return 2; }
        CGEventSetFlags(e, (CGEventFlags)flags);
        if (hid) CGEventPost(kCGHIDEventTap, e); else CGEventPostToPid(pid, e);
        CFRelease(e);
        usleep(gap * 1000);
    }
    return 0;
}
