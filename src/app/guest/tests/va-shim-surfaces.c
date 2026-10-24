/*
 * va-shim-surfaces: what OmacVM's VA driver shim (omacvm_drv_video.c) passes on to
 * Mesa's vaCreateSurfaces2. Built twice by va-shim-surfaces.sh: with -DSTUB_DRIVER as a
 * stand-in for Mesa's driver that keeps the attributes it gets, and as the program that
 * loads the shim (built against the stand-in), creates surfaces like Chromium and others
 * do, and checks them.
 *   va-shim-surfaces SHIM STUB yes|no
 * yes: every surface Mesa allocates itself gets VASurfaceAttribMemoryType DRM_PRIME_2
 * added (Mesa then makes it exportable, with a dma-buf of its real size); imports and
 * surfaces with a memory type of their own pass unchanged; the largest surface size the
 * driver reports is at most OMACVM_VA_MAX (default 1920, 0: Mesa's). no: everything
 * unchanged.
 */
#include <dlfcn.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <va/va.h>
#include <va/va_backend.h>
#include <va/va_drmcommon.h>

#ifdef STUB_DRIVER
VASurfaceAttrib seen[64];
unsigned int nseen = 99;

static VAStatus create_surfaces2(VADriverContextP ctx, unsigned int format, unsigned int w,
                                 unsigned int h, VASurfaceID *s, unsigned int n,
                                 VASurfaceAttrib *a, unsigned int na)
{
    (void)ctx; (void)format; (void)w; (void)h;
    nseen = na;
    if (na <= 64 && a)
        memcpy(seen, a, na * sizeof(*a));
    for (unsigned int i = 0; i < n; i++)
        s[i] = i + 1;
    return VA_STATUS_SUCCESS;
}

/* Mesa's list for a decoding config: NV12 and I420, up to 4096 x 4096 */
static VAStatus query_surface_attributes(VADriverContextP ctx, VAConfigID config,
                                         VASurfaceAttrib *a, unsigned int *n)
{
    static const struct { VASurfaceAttribType type; int value; } list[] = {
        { VASurfaceAttribPixelFormat, VA_FOURCC_NV12 }, { VASurfaceAttribPixelFormat, VA_FOURCC_I420 },
        { VASurfaceAttribMinWidth, 1 }, { VASurfaceAttribMinHeight, 1 },
        { VASurfaceAttribMaxWidth, 4096 }, { VASurfaceAttribMaxHeight, 4096 },
    };
    (void)ctx; (void)config;
    if (!a) {
        *n = 6;
        return VA_STATUS_SUCCESS;
    }
    for (unsigned int i = 0; i < 6 && i < *n; i++)
        a[i] = (VASurfaceAttrib){ .type = list[i].type, .flags = VA_SURFACE_ATTRIB_GETTABLE,
                                  .value = { .type = VAGenericValueTypeInteger, .value.i = list[i].value } };
    *n = 6;
    return VA_STATUS_SUCCESS;
}

VAStatus __vaDriverInit_1_20(VADriverContextP ctx)
{
    ctx->vtable->vaCreateSurfaces2 = create_surfaces2;
    ctx->vtable->vaQuerySurfaceAttributes = query_surface_attributes;
    return VA_STATUS_SUCCESS;
}
#else
static VASurfaceAttrib *seen;
static unsigned int *nseen;
static VADriverContextP ctx;
static int failed;

static VASurfaceAttrib attr(VASurfaceAttribType type, int value)
{
    return (VASurfaceAttrib){ .type = type, .flags = VA_SURFACE_ATTRIB_SETTABLE,
                              .value = { .type = VAGenericValueTypeInteger, .value.i = value } };
}

/* Creates surfaces with LIST (N attributes) and checks what Mesa got: the same list,
 * with the export hint added when HINT. */
static void check(const char *name, unsigned int rt, VASurfaceAttrib *list, unsigned int n, int hint)
{
    VASurfaceID s[2];
    VAStatus st = ctx->vtable->vaCreateSurfaces2(ctx, rt, 1920, 1088, s, 2, list, n);
    int ok = st == VA_STATUS_SUCCESS && *nseen == n + (hint ? 1 : 0) &&
             (!n || !memcmp(seen, list, n * sizeof(*list)));

    if (ok && hint)
        ok = seen[n].type == VASurfaceAttribMemoryType &&
             seen[n].flags == VA_SURFACE_ATTRIB_SETTABLE &&
             seen[n].value.type == VAGenericValueTypeInteger &&
             seen[n].value.value.i == VA_SURFACE_ATTRIB_MEM_TYPE_DRM_PRIME_2;
    printf("%s: %s (Mesa got %u attributes)\n", ok ? "ok" : "FAIL", name, *nseen);
    failed |= !ok;
}

int main(int argc, char **argv)
{
    VADRMPRIMESurfaceDescriptor desc = { 0 };
    VASurfaceAttribExternalBuffers ext = { 0 };
    struct VADriverVTable vt = { 0 };
    struct VADriverContext dc = { 0 };
    VASurfaceAttrib l[40];
    void *shim, *stub;
    VAStatus (*init)(VADriverContextP);
    int yes;

    if (argc < 4)
        return 2;
    yes = !strcmp(argv[3], "yes");
    stub = dlopen(argv[2], RTLD_NOW | RTLD_GLOBAL);
    shim = dlopen(argv[1], RTLD_NOW);
    if (!stub || !shim) {
        fprintf(stderr, "dlopen: %s\n", dlerror());
        return 2;
    }
    seen = dlsym(stub, "seen");
    nseen = dlsym(stub, "nseen");
    init = (VAStatus (*)(VADriverContextP))dlsym(shim, "__vaDriverInit_1_20");
    dc.vtable = &vt;
    ctx = &dc;
    if (!seen || !nseen || !init || init(ctx) != VA_STATUS_SUCCESS) {
        fprintf(stderr, "the shim did not load the stand-in driver\n");
        return 2;
    }

    /* Chromium's decoder surfaces and its RGB frames (vaapi_wrapper.cc CreateSurfaces). */
    l[0] = attr(VASurfaceAttribUsageHint, VA_SURFACE_ATTRIB_USAGE_HINT_DECODER);
    check("NV12 decoder surface with a usage hint", VA_RT_FORMAT_YUV420, l, 1, yes);
    l[0] = attr(VASurfaceAttribUsageHint, VA_SURFACE_ATTRIB_USAGE_HINT_GENERIC);
    check("RGB32 surface (Chrome's converted frames)", VA_RT_FORMAT_RGB32, l, 1, yes);
    l[0] = attr(VASurfaceAttribPixelFormat, VA_FOURCC_P010);
    check("P010 surface with a pixel format", VA_RT_FORMAT_YUV420_10, l, 1, yes);
    check("surface without attributes", VA_RT_FORMAT_YUV420, NULL, 0, yes);
    l[0] = attr(VASurfaceAttribMemoryType, VA_SURFACE_ATTRIB_MEM_TYPE_VA);
    check("memory type VA (Mesa allocates)", VA_RT_FORMAT_YUV420, l, 1, yes);

    /* Imports, and apps that ask for a memory type themselves: unchanged. */
    l[0] = attr(VASurfaceAttribMemoryType, VA_SURFACE_ATTRIB_MEM_TYPE_DRM_PRIME_2);
    l[1] = (VASurfaceAttrib){ .type = VASurfaceAttribExternalBufferDescriptor,
                              .flags = VA_SURFACE_ATTRIB_SETTABLE,
                              .value = { .type = VAGenericValueTypePointer, .value.p = &desc } };
    check("DRM_PRIME_2 import", VA_RT_FORMAT_YUV420, l, 2, 0);
    l[0] = attr(VASurfaceAttribMemoryType, VA_SURFACE_ATTRIB_MEM_TYPE_DRM_PRIME);
    l[1].value.value.p = &ext;
    check("DRM_PRIME import", VA_RT_FORMAT_YUV420, l, 2, 0);
    l[0] = attr(VASurfaceAttribMemoryType, VA_SURFACE_ATTRIB_MEM_TYPE_DRM_PRIME_2);
    check("the app's own export hint", VA_RT_FORMAT_YUV420, l, 1, 0);
    l[0] = attr(VASurfaceAttribUsageHint, VA_SURFACE_ATTRIB_USAGE_HINT_DECODER);
    l[1] = (VASurfaceAttrib){ .type = VASurfaceAttribExternalBufferDescriptor,
                              .flags = VA_SURFACE_ATTRIB_SETTABLE,
                              .value = { .type = VAGenericValueTypePointer, .value.p = &ext } };
    check("external buffers with the default memory type", VA_RT_FORMAT_YUV420, l, 2, 0);

    /* The largest size Chromium is told (its decoder uses the CPU above it); I420 is
     * hidden either way. */
    {
        VASurfaceAttrib q[8];
        unsigned int nq = 8, maxw = 0, maxh = 0, i420 = 0;
        const char *env = getenv("OMACVM_VA_MAX");
        unsigned int want = !yes ? 4096 : env && *env ? (unsigned int)atoi(env) : 1920;

        if (!want)
            want = 4096;
        ctx->vtable->vaQuerySurfaceAttributes(ctx, 0, q, &nq);
        for (unsigned int k = 0; k < nq; k++) {
            maxw = q[k].type == VASurfaceAttribMaxWidth ? (unsigned)q[k].value.value.i : maxw;
            maxh = q[k].type == VASurfaceAttribMaxHeight ? (unsigned)q[k].value.value.i : maxh;
            i420 |= q[k].type == VASurfaceAttribPixelFormat && q[k].value.value.i == VA_FOURCC_I420;
        }
        int ok = maxw == want && maxh == want && !i420 && nq == 5;
        printf("%s: largest surface %ux%u (want %u), I420 %s\n", ok ? "ok" : "FAIL", maxw, maxh, want,
               i420 ? "listed" : "hidden");
        failed |= !ok;
    }

    /* A list too long to copy: unchanged. */
    for (int i = 0; i < 40; i++)
        l[i] = attr(VASurfaceAttribUsageHint, VA_SURFACE_ATTRIB_USAGE_HINT_DECODER);
    check("32 attributes", VA_RT_FORMAT_YUV420, l, 32, 0);
    check("31 attributes", VA_RT_FORMAT_YUV420, l, 31, yes);
    return failed;
}
#endif
