/*
 * refuse-small-start: an AudioQueueStart() that refuses playback queues of
 * small buffers with kAudioQueueErr_CannotStart (-66681), as AirPods over
 * A2DP did with the sound's own thread's 256-frame buffers (#548). For
 * qemu-sdl-audio-out-size.patch: the VM must play with the next size.
 *
 * Inject into a test copy of the QEMU runtime, re-signed with
 * allow-dyld-environment-variables and disable-library-validation (as
 * wedged-output-start.c):
 *   DYLD_INSERT_LIBRARIES=/path/aqrefuse.dylib
 *   AQREFUSE_BELOW=512   playback queues with buffers below this many frames
 *                        do not start (default 512; 0: every queue starts)
 *   AQREFUSE_BELOW_FILE=F  read the limit from this file at each start
 *                        instead (a number; missing file: the variable's),
 *                        for an output that changes while the VM runs
 *   AQREFUSE_RATE=48000  also refuse playback queues at this rate, whatever
 *                        their buffers (the other way the AirPods could
 *                        tell the two sound paths apart)
 *   AQREFUSE_HANG_CLOSE=S  the first close of a playback queue that
 *                        started hangs S seconds (a wedged coreaudiod), for
 *                        the time limit on a resize's close
 *   AQREFUSE_HANG_CLOSE_FILE=F  read S from this file at each close instead
 *                        (missing file: 0), to hang only a later close
 *   AQREFUSE_LOG=FILE    one line per playback queue start: its format,
 *                        buffers and what the start returned, and one when
 *                        it is disposed: buffers played, how many had sound
 *                        (default stderr)
 *
 * Build: clang -dynamiclib -o aqrefuse.dylib refuse-small-start.c
 *        -framework AudioToolbox
 */
#include <AudioToolbox/AudioToolbox.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#define DYLD_INTERPOSE(_replacement, _replacee)                              \
    __attribute__((used)) static struct {                                    \
        const void *replacement;                                             \
        const void *replacee;                                                \
    } _interpose_##_replacee __attribute__((section("__DATA,__interpose"))) = \
        { (const void *)(unsigned long)&_replacement,                        \
          (const void *)(unsigned long)&_replacee };

#define MAX_QUEUES 64

typedef struct {
    AudioQueueRef q;
    AudioStreamBasicDescription fmt;
    UInt32 smallest;            /* bytes of its smallest buffer */
    int buffers;
    int started;
    unsigned long played;       /* buffers enqueued after the start */
    unsigned long loud;         /* ... with a sample that is not 0 */
} Queue;

static Queue queues[MAX_QUEUES];
static pthread_mutex_t lock = PTHREAD_MUTEX_INITIALIZER;
static int close_hung;          /* AQREFUSE_HANG_CLOSE: only the first close */

static Queue *find(AudioQueueRef q, int add)
{
    for (int i = 0; i < MAX_QUEUES; i++) {
        if (queues[i].q == q) {
            return &queues[i];
        }
    }
    if (!add) {
        return NULL;
    }
    for (int i = 0; i < MAX_QUEUES; i++) {
        if (!queues[i].q) {
            queues[i].q = q;
            return &queues[i];
        }
    }
    return NULL;
}

static void say(const char *line)
{
    const char *path = getenv("AQREFUSE_LOG");
    FILE *f = path && *path ? fopen(path, "a") : NULL;

    fputs(line, f ? f : stderr);
    if (f) {
        fclose(f);
    }
}

static OSStatus my_new_output(const AudioStreamBasicDescription *fmt,
                              AudioQueueOutputCallback cb, void *user,
                              CFRunLoopRef rl, CFStringRef mode, UInt32 flags,
                              AudioQueueRef *out)
{
    OSStatus r = AudioQueueNewOutput(fmt, cb, user, rl, mode, flags, out);

    if (r == noErr && out && *out) {
        pthread_mutex_lock(&lock);
        Queue *e = find(*out, 1);
        if (e) {
            memset(e, 0, sizeof(*e));
            e->q = *out;
            e->fmt = *fmt;
        }
        pthread_mutex_unlock(&lock);
    }
    return r;
}
DYLD_INTERPOSE(my_new_output, AudioQueueNewOutput)

static OSStatus my_allocate(AudioQueueRef q, UInt32 bytes, AudioQueueBufferRef *out)
{
    OSStatus r = AudioQueueAllocateBuffer(q, bytes, out);

    if (r == noErr) {
        pthread_mutex_lock(&lock);
        Queue *e = find(q, 0);
        if (e) {
            e->buffers++;
            if (!e->smallest || bytes < e->smallest) {
                e->smallest = bytes;
            }
        }
        pthread_mutex_unlock(&lock);
    }
    return r;
}
DYLD_INTERPOSE(my_allocate, AudioQueueAllocateBuffer)

static OSStatus my_start(AudioQueueRef q, const AudioTimeStamp *when)
{
    const char *below_text = getenv("AQREFUSE_BELOW");
    const char *below_file = getenv("AQREFUSE_BELOW_FILE");
    UInt32 below = below_text ? (UInt32)strtoul(below_text, NULL, 10) : 512;
    char text[32];
    FILE *bf = below_file && *below_file ? fopen(below_file, "r") : NULL;

    if (bf) {
        if (fgets(text, sizeof(text), bf)) {
            below = (UInt32)strtoul(text, NULL, 10);
        }
        fclose(bf);
    }
    Queue e = { 0 };
    int known = 0;
    OSStatus r;
    char line[256];

    pthread_mutex_lock(&lock);
    Queue *p = find(q, 0);
    if (p) {
        e = *p;
        known = 1;
    }
    pthread_mutex_unlock(&lock);
    if (!known) {
        return AudioQueueStart(q, when);   /* a recording queue */
    }

    UInt32 frames = e.fmt.mBytesPerFrame ? e.smallest / e.fmt.mBytesPerFrame : 0;
    const char *rate_text = getenv("AQREFUSE_RATE");
    double rate = rate_text ? strtod(rate_text, NULL) : 0;
    if ((below && frames < below) || (rate > 0 && e.fmt.mSampleRate == rate)) {
        r = kAudioQueueErr_CannotStart;
    } else {
        r = AudioQueueStart(q, when);
    }
    if (r == noErr) {
        pthread_mutex_lock(&lock);
        p = find(q, 0);
        if (p) {
            p->started = 1;
        }
        pthread_mutex_unlock(&lock);
    }
    snprintf(line, sizeof(line),
             "aqrefuse: playback %.0f Hz %s%u-bit %u ch, %d x %u frames: start -> %d\n",
             e.fmt.mSampleRate,
             (e.fmt.mFormatFlags & kAudioFormatFlagIsFloat) ? "float " : "",
             (unsigned)e.fmt.mBitsPerChannel, (unsigned)e.fmt.mChannelsPerFrame,
             e.buffers, (unsigned)frames, (int)r);
    say(line);
    return r;
}
DYLD_INTERPOSE(my_start, AudioQueueStart)

static OSStatus my_enqueue(AudioQueueRef q, AudioQueueBufferRef b, UInt32 n,
                           const AudioStreamPacketDescription *d)
{
    pthread_mutex_lock(&lock);
    Queue *e = find(q, 0);
    if (e && e->started) {
        const unsigned char *data = b->mAudioData;
        int loud = 0;
        for (UInt32 i = 0; i < b->mAudioDataByteSize && !loud; i++) {
            loud = data[i] != 0;
        }
        e->played++;
        e->loud += loud;
    }
    pthread_mutex_unlock(&lock);
    return AudioQueueEnqueueBuffer(q, b, n, d);
}
DYLD_INTERPOSE(my_enqueue, AudioQueueEnqueueBuffer)

static OSStatus my_dispose(AudioQueueRef q, Boolean immediate)
{
    const char *hang_text = getenv("AQREFUSE_HANG_CLOSE");
    const char *hang_file = getenv("AQREFUSE_HANG_CLOSE_FILE");
    unsigned hang = hang_text ? (unsigned)strtoul(hang_text, NULL, 10) : 0;
    Queue e = { 0 };
    char line[160];

    if (hang_file && *hang_file) {
        FILE *hf = fopen(hang_file, "r");

        hang = 0;
        if (hf) {
            if (fgets(line, sizeof(line), hf)) {
                hang = (unsigned)strtoul(line, NULL, 10);
            }
            fclose(hf);
        }
    }

    pthread_mutex_lock(&lock);
    Queue *p = find(q, 0);
    if (p) {
        e = *p;
        p->q = NULL;
    }
    pthread_mutex_unlock(&lock);
    if (e.started) {
        snprintf(line, sizeof(line),
                 "aqrefuse: playback %u frames closed: %lu buffers played, %lu with sound\n",
                 e.fmt.mBytesPerFrame ? (unsigned)(e.smallest / e.fmt.mBytesPerFrame) : 0,
                 e.played, e.loud);
        say(line);
        pthread_mutex_lock(&lock);
        if (close_hung) {
            hang = 0;
        }
        close_hung |= hang > 0;
        pthread_mutex_unlock(&lock);
        if (hang) {
            snprintf(line, sizeof(line), "aqrefuse: playback close hangs %u s\n", hang);
            say(line);
            sleep(hang);
            say("aqrefuse: playback close returns\n");
        }
    }
    return AudioQueueDispose(q, immediate);
}
DYLD_INTERPOSE(my_dispose, AudioQueueDispose)
