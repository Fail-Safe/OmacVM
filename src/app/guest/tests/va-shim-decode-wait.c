/*
 * va-shim-decode-wait: OmacVM's VA driver shim (omacvm_drv_video.c, "Waiting for the
 * picture") after vaEndPicture. Built twice by va-shim-decode-wait.sh: with -DSTUB_DRIVER
 * as a stand-in for Mesa's driver (config 0 decodes, 1 is video processing), and as the
 * program that loads the shim against it. The program's own ioctl() stands in for the
 * virtio-gpu kernel driver: an EXECBUFFER gets a pipe as its fence, written now, after
 * FENCE_MS or never.
 *   va-shim-decode-wait SHIM STUB yes|no [ARGS...]
 * yes: vaEndPicture on a decoding context sends one empty command (a VIRGL_CCMD_NOP,
 * fence out) and returns once its fence signalled (at most about 100 ms), then closes the
 * fence; video processing contexts, a destroyed decoding context's ID used again for video
 * processing, and a failed vaEndPicture send nothing. no: nothing is ever sent.
 */
#define _GNU_SOURCE
#include <dlfcn.h>
#include <errno.h>
#include <fcntl.h>
#include <pthread.h>
#include <stdarg.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>
#include <sys/ioctl.h>
#include <drm/virtgpu_drm.h>
#include <va/va.h>
#include <va/va_backend.h>
#include <va/va_drmcommon.h>

#ifdef STUB_DRIVER
int end_fails;   /* the program sets it: vaEndPicture fails */

static VAStatus query_config_attributes(VADriverContextP ctx, VAConfigID config, VAProfile *profile,
                                        VAEntrypoint *entrypoint, VAConfigAttrib *a, int *n)
{
    (void)ctx; (void)a;
    if (config > 1)
        return VA_STATUS_ERROR_INVALID_CONFIG;
    *profile = config ? VAProfileNone : VAProfileH264Main;
    *entrypoint = config ? VAEntrypointVideoProc : VAEntrypointVLD;
    *n = 0;
    return VA_STATUS_SUCCESS;
}

static VAContextID next_id = 7, freed = VA_INVALID_ID;

/* an ID that was freed comes back first, as in Mesa's handle table */
static VAStatus create_context(VADriverContextP ctx, VAConfigID config, int w, int h, int flag,
                               VASurfaceID *t, int nt, VAContextID *context)
{
    (void)ctx; (void)config; (void)w; (void)h; (void)flag; (void)t; (void)nt;
    if (freed != VA_INVALID_ID) {
        *context = freed;
        freed = VA_INVALID_ID;
    } else {
        *context = next_id++;
    }
    return VA_STATUS_SUCCESS;
}

static VAStatus destroy_context(VADriverContextP ctx, VAContextID context)
{
    (void)ctx;
    freed = context;
    return VA_STATUS_SUCCESS;
}

static VAStatus terminate(VADriverContextP ctx)
{
    (void)ctx;
    return VA_STATUS_SUCCESS;
}

static VAStatus end_picture(VADriverContextP ctx, VAContextID context)
{
    (void)ctx; (void)context;
    return end_fails ? VA_STATUS_ERROR_OPERATION_FAILED : VA_STATUS_SUCCESS;
}

VAStatus __vaDriverInit_1_20(VADriverContextP ctx)
{
    ctx->vtable->vaQueryConfigAttributes = query_config_attributes;
    ctx->vtable->vaCreateContext = create_context;
    ctx->vtable->vaDestroyContext = destroy_context;
    ctx->vtable->vaTerminate = terminate;
    ctx->vtable->vaEndPicture = end_picture;
    return VA_STATUS_SUCCESS;
}
#else
/* --- the kernel driver as the shim sees it --- */
static int sent, bad;           /* fenced EXECBUFFERs; ones that were not one NOP */
static int fence_ms;            /* 0: signalled at once; -1: never */
static int last_fence = -1;

static void *write_later(void *arg)
{
    int fd = (int)(intptr_t)arg;
    usleep((useconds_t)fence_ms * 1000);
    if (write(fd, "", 1) < 0) { }
    close(fd);
    return NULL;
}

int ioctl(int fd, unsigned long request, ...)
{
    va_list ap;
    void *arg;

    (void)fd;
    va_start(ap, request);
    arg = va_arg(ap, void *);
    va_end(ap);
    if (request != DRM_IOCTL_VIRTGPU_EXECBUFFER) {
        errno = ENOTTY;   /* GET_CAPS: an older host, no limits */
        return -1;
    }
    struct drm_virtgpu_execbuffer *eb = arg;
    int p[2];
    if (eb->size != 4 || !eb->command || *(const uint32_t *)(uintptr_t)eb->command != 0 ||
        eb->num_bo_handles || !(eb->flags & VIRTGPU_EXECBUF_FENCE_FD_OUT))
        bad++;
    if (pipe(p))
        return -1;
    sent++;
    eb->fence_fd = p[0];
    last_fence = p[0];
    if (fence_ms == 0) {
        if (write(p[1], "", 1) < 0) { }
        close(p[1]);
    } else if (fence_ms > 0) {
        pthread_t t;
        pthread_create(&t, NULL, write_later, (void *)(intptr_t)p[1]);
        pthread_detach(t);
    }   /* never: p[1] stays open */
    return 0;
}

static int failed;

static void check(int ok, const char *what)
{
    printf("%s: %s\n", ok ? "ok" : "FAIL", what);
    failed |= !ok;
}

static double ms_since(const struct timespec *t0)
{
    struct timespec t;
    clock_gettime(CLOCK_MONOTONIC, &t);
    return (t.tv_sec - t0->tv_sec) * 1e3 + (t.tv_nsec - t0->tv_nsec) / 1e6;
}

int main(int argc, char **argv)
{
    struct VADriverVTable vt = { 0 };
    struct VADriverContext dc = { 0 };
    struct drm_state drm = { 0 };
    VAStatus (*init)(VADriverContextP);
    VAContextID dec, vpp;
    struct timespec t0;
    char what[160];
    int yes, *end_fails;

    if (argc < 4)
        return 2;
    yes = !strcmp(argv[3], "yes");
    void *stub = dlopen(argv[2], RTLD_NOW | RTLD_GLOBAL);
    void *shim = dlopen(argv[1], RTLD_NOW);
    if (!stub || !shim) {
        fprintf(stderr, "dlopen: %s\n", dlerror());
        return 2;
    }
    end_fails = dlsym(stub, "end_fails");
    init = (VAStatus (*)(VADriverContextP))dlsym(shim, "__vaDriverInit_1_20");
    drm.fd = open("/dev/null", O_RDWR);
    dc.vtable = &vt;
    dc.drm_state = &drm;
    dc.max_attributes = 4;
    if (!end_fails || !init || init(&dc) != VA_STATUS_SUCCESS) {
        fprintf(stderr, "the shim did not load the stand-in driver\n");
        return 2;
    }

    vt.vaCreateContext(&dc, 0, 1920, 1080, 0, NULL, 0, &dec);
    vt.vaCreateContext(&dc, 1, 1920, 1080, 0, NULL, 0, &vpp);

    /* a decoding context: one fenced NOP, waited for */
    fence_ms = 50;
    clock_gettime(CLOCK_MONOTONIC, &t0);
    VAStatus st = vt.vaEndPicture(&dc, dec);
    double took = ms_since(&t0);
    snprintf(what, sizeof(what), "decoding: %d fenced command(s) sent, returned after %.0f ms "
             "(fence after 50 ms)", sent, took);
    check(st == VA_STATUS_SUCCESS && (yes ? sent == 1 && took >= 40 && !bad :
                                            sent == 0 && took < 40), what);
    if (yes) {
        check(last_fence >= 0 && fcntl(last_fence, F_GETFD) < 0 && errno == EBADF,
              "the fence is closed afterwards");
    }

    /* a fence that never signals: back after about 100 ms */
    sent = 0;
    fence_ms = -1;
    clock_gettime(CLOCK_MONOTONIC, &t0);
    vt.vaEndPicture(&dc, dec);
    took = ms_since(&t0);
    snprintf(what, sizeof(what), "a fence that never signals: returned after %.0f ms", took);
    check(yes ? sent == 1 && took >= 80 && took < 400 : sent == 0, what);

    /* video processing: nothing sent */
    sent = 0;
    fence_ms = 0;
    vt.vaEndPicture(&dc, vpp);
    check(sent == 0, "video processing context: nothing sent");

    /* vaEndPicture failed: nothing sent */
    *end_fails = 1;
    vt.vaEndPicture(&dc, dec);
    *end_fails = 0;
    check(sent == 0, "failed vaEndPicture: nothing sent");

    /* the decoding context's ID used again for video processing: nothing sent */
    vt.vaDestroyContext(&dc, dec);
    VAContextID again;
    vt.vaCreateContext(&dc, 1, 1920, 1080, 0, NULL, 0, &again);
    vt.vaEndPicture(&dc, again);
    snprintf(what, sizeof(what), "a destroyed decoder's ID (%u) used for video processing "
             "(%u): nothing sent", dec, again);
    check(again == dec && sent == 0, what);

    /* a new decoding context after vaTerminate of the display: none known any more */
    vt.vaCreateContext(&dc, 0, 1920, 1080, 0, NULL, 0, &dec);
    vt.vaTerminate(&dc);
    vt.vaEndPicture(&dc, dec);
    check(sent == 0, "after vaTerminate: nothing sent");

    if (failed) {
        printf("va-shim-decode-wait (%s): FAILED\n", argv[3]);
        return 1;
    }
    return 0;
}
#endif
