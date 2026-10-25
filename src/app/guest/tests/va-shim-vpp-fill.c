/*
 * va-shim-vpp-fill: OmacVM's VA driver shim (omacvm_drv_video.c, "Chromium's RGB frames fill
 * their planes") around video processing. Built twice by va-shim-vpp-fill.sh: with
 * -DSTUB_DRIVER as a stand-in for Mesa's driver that records what it gets (surface sizes and
 * import descriptors at creation, the regions of each video processing call), and as the
 * program that loads the shim against it and does what Chrome does: an NV12 decoder surface,
 * an import of an ARGB frame's dma-buf, and video processing from the one into the other.
 *   va-shim-vpp-fill SHIM STUB yes|no [ARGS...]
 * yes: an RGB import of 320x180 whose buffer holds 192 rows is made at 320x192 (one that holds
 * only 180 rows: as it is); processing from a 320x180 NV12 surface into it reaches Mesa with
 * the source region scaled to the picture's part of the rounded planes (0,0,320,169) and the
 * output region the rounded size (0,0,320,192); the app's buffer has its own regions back
 * afterwards; a 16-aligned source and an output into part of the frame stay as they are.
 * no: everything as the app gave it.
 */
#define _GNU_SOURCE
#include <dlfcn.h>
#include <fcntl.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <va/va.h>
#include <va/va_backend.h>
#include <va/va_drmcommon.h>
#include <va/va_vpp.h>

#ifdef STUB_DRIVER
/* what "Mesa" saw */
struct seen_surface { unsigned format, width, height, desc_width, desc_height; } seen_surfaces[16];
unsigned nsurfaces;
VARectangle seen_src, seen_out;
int seen_src_null, seen_out_null, renders;

static struct buf { VABufferType type; unsigned size; void *data; } bufs[16];
static unsigned nbufs;
static VASurfaceID targets[8];

static VAStatus create_surfaces2(VADriverContextP ctx, unsigned int format, unsigned int w,
                                 unsigned int h, VASurfaceID *s, unsigned int n,
                                 VASurfaceAttrib *a, unsigned int na)
{
    (void)ctx;
    for (unsigned i = 0; i < n && nsurfaces < 16; i++) {
        struct seen_surface *ss = &seen_surfaces[nsurfaces];
        *ss = (struct seen_surface){ format, w, h, 0, 0 };
        for (unsigned k = 0; k < na; k++)
            if (a[k].type == VASurfaceAttribExternalBufferDescriptor && a[k].value.value.p) {
                const VADRMPRIMESurfaceDescriptor *d = a[k].value.value.p;
                ss->desc_width = d->width;
                ss->desc_height = d->height;
            }
        s[i] = nsurfaces++;
    }
    return VA_STATUS_SUCCESS;
}

static VAStatus export_surface(VADriverContextP ctx, VASurfaceID s, uint32_t mem, uint32_t flags,
                               void *descriptor)
{
    VADRMPRIMESurfaceDescriptor *d = descriptor;
    (void)ctx; (void)mem; (void)flags;
    if (s >= nsurfaces)
        return VA_STATUS_ERROR_INVALID_SURFACE;
    memset(d, 0, sizeof(*d));
    d->fourcc = seen_surfaces[s].format == VA_RT_FORMAT_RGB32 ? VA_FOURCC_ARGB : VA_FOURCC_NV12;
    d->width = seen_surfaces[s].width;
    d->height = seen_surfaces[s].height;
    d->num_objects = 1;
    d->objects[0].fd = open("/dev/null", O_RDONLY);
    d->num_layers = 1;
    return VA_STATUS_SUCCESS;
}

static VAStatus query_config_attributes(VADriverContextP ctx, VAConfigID config, VAProfile *profile,
                                        VAEntrypoint *entrypoint, VAConfigAttrib *a, int *n)
{
    (void)ctx; (void)a;
    *profile = config ? VAProfileNone : VAProfileVP9Profile0;
    *entrypoint = config ? VAEntrypointVideoProc : VAEntrypointVLD;
    *n = 0;
    return VA_STATUS_SUCCESS;
}

static VAStatus create_context(VADriverContextP ctx, VAConfigID config, int w, int h, int flag,
                               VASurfaceID *t, int nt, VAContextID *context)
{
    static VAContextID next;
    (void)ctx; (void)config; (void)w; (void)h; (void)flag; (void)t; (void)nt;
    *context = next++;
    return VA_STATUS_SUCCESS;
}

static VAStatus destroy_context(VADriverContextP ctx, VAContextID c) { (void)ctx; (void)c; return VA_STATUS_SUCCESS; }
static VAStatus terminate(VADriverContextP ctx) { (void)ctx; return VA_STATUS_SUCCESS; }

static VAStatus create_buffer(VADriverContextP ctx, VAContextID c, VABufferType type, unsigned int size,
                              unsigned int num, void *data, VABufferID *id)
{
    (void)ctx; (void)c;
    if (nbufs >= 16)
        return VA_STATUS_ERROR_ALLOCATION_FAILED;
    bufs[nbufs] = (struct buf){ type, size * num, calloc(1, size * num) };
    if (data)
        memcpy(bufs[nbufs].data, data, size * num);
    *id = nbufs++;
    return VA_STATUS_SUCCESS;
}

static VAStatus buffer_info(VADriverContextP ctx, VABufferID id, VABufferType *type, unsigned int *size,
                            unsigned int *num)
{
    (void)ctx;
    if (id >= nbufs)
        return VA_STATUS_ERROR_INVALID_BUFFER;
    *type = bufs[id].type;
    *size = bufs[id].size;
    *num = 1;
    return VA_STATUS_SUCCESS;
}

static VAStatus map_buffer(VADriverContextP ctx, VABufferID id, void **p)
{
    (void)ctx;
    if (id >= nbufs)
        return VA_STATUS_ERROR_INVALID_BUFFER;
    *p = bufs[id].data;
    return VA_STATUS_SUCCESS;
}

static VAStatus unmap_buffer(VADriverContextP ctx, VABufferID id) { (void)ctx; (void)id; return VA_STATUS_SUCCESS; }

static VAStatus begin_picture(VADriverContextP ctx, VAContextID c, VASurfaceID t)
{
    (void)ctx;
    if (c < 8)
        targets[c] = t;
    return VA_STATUS_SUCCESS;
}

static VAStatus render_picture(VADriverContextP ctx, VAContextID c, VABufferID *ids, int n)
{
    (void)ctx; (void)c;
    for (int i = 0; i < n; i++) {
        if (ids[i] >= nbufs || bufs[ids[i]].type != VAProcPipelineParameterBufferType)
            continue;
        const VAProcPipelineParameterBuffer *pp = bufs[ids[i]].data;
        seen_src_null = !pp->surface_region;
        seen_out_null = !pp->output_region;
        if (pp->surface_region)
            seen_src = *pp->surface_region;
        if (pp->output_region)
            seen_out = *pp->output_region;
        renders++;
    }
    return VA_STATUS_SUCCESS;
}

VAStatus __vaDriverInit_1_20(VADriverContextP ctx)
{
    ctx->vtable->vaCreateSurfaces2 = create_surfaces2;
    ctx->vtable->vaExportSurfaceHandle = export_surface;
    ctx->vtable->vaQueryConfigAttributes = query_config_attributes;
    ctx->vtable->vaCreateContext = create_context;
    ctx->vtable->vaDestroyContext = destroy_context;
    ctx->vtable->vaTerminate = terminate;
    ctx->vtable->vaCreateBuffer = create_buffer;
    ctx->vtable->vaBufferInfo = buffer_info;
    ctx->vtable->vaMapBuffer = map_buffer;
    ctx->vtable->vaUnmapBuffer = unmap_buffer;
    ctx->vtable->vaBeginPicture = begin_picture;
    ctx->vtable->vaRenderPicture = render_picture;
    return VA_STATUS_SUCCESS;
}
#else
static int failed;
static struct VADriverVTable vt;
static struct VADriverContext dc;

static void check(int ok, const char *what)
{
    printf("%s: %s\n", ok ? "ok" : "FAIL", what);
    failed |= !ok;
}

/* an ARGB frame of 320x180 whose dma-buf holds ROWS rows (a file of that size) */
static VASurfaceID import_argb(unsigned rows)
{
    char path[] = "/tmp/va-shim-vpp-XXXXXX";
    int fd = mkstemp(path);
    VADRMPRIMESurfaceDescriptor d;
    VASurfaceAttrib a[2];
    VASurfaceID s = VA_INVALID_SURFACE;

    unlink(path);
    if (fd < 0 || ftruncate(fd, (off_t)1280 * rows))
        return s;
    memset(&d, 0, sizeof(d));
    d.fourcc = VA_FOURCC_ARGB;
    d.width = 320;
    d.height = 180;
    d.num_objects = 1;
    d.objects[0].fd = fd;
    d.objects[0].size = 1280 * rows;
    d.num_layers = 1;
    d.layers[0].drm_format = 0x34325241;   /* AR24 */
    d.layers[0].num_planes = 1;
    d.layers[0].pitch[0] = 1280;
    a[0] = (VASurfaceAttrib){ .type = VASurfaceAttribMemoryType, .flags = VA_SURFACE_ATTRIB_SETTABLE,
                              .value = { .type = VAGenericValueTypeInteger,
                                         .value.i = VA_SURFACE_ATTRIB_MEM_TYPE_DRM_PRIME_2 } };
    a[1] = (VASurfaceAttrib){ .type = VASurfaceAttribExternalBufferDescriptor,
                              .flags = VA_SURFACE_ATTRIB_SETTABLE,
                              .value = { .type = VAGenericValueTypePointer, .value.p = &d } };
    vt.vaCreateSurfaces2(&dc, VA_RT_FORMAT_RGB32, 320, 180, &s, 1, a, 2);
    return s;
}

int main(int argc, char **argv)
{
    struct seen_surface { unsigned format, width, height, desc_width, desc_height; } *seen;
    VARectangle *seen_src, *seen_out;
    int *renders;
    VAStatus (*init)(VADriverContextP);
    char what[200];
    int yes;

    if (argc < 4)
        return 2;
    yes = !strcmp(argv[3], "yes");
    void *stub = dlopen(argv[2], RTLD_NOW | RTLD_GLOBAL);
    void *shim = dlopen(argv[1], RTLD_NOW);
    if (!stub || !shim) {
        fprintf(stderr, "dlopen: %s\n", dlerror());
        return 2;
    }
    seen = dlsym(stub, "seen_surfaces");
    seen_src = dlsym(stub, "seen_src");
    seen_out = dlsym(stub, "seen_out");
    renders = dlsym(stub, "renders");
    init = (VAStatus (*)(VADriverContextP))dlsym(shim, "__vaDriverInit_1_20");
    dc.vtable = &vt;
    dc.max_attributes = 4;
    if (!seen || !seen_src || !seen_out || !renders || !init || init(&dc) != VA_STATUS_SUCCESS) {
        fprintf(stderr, "the shim did not load the stand-in driver\n");
        return 2;
    }

    /* the decoder's NV12 surfaces: 320x180 (VP9) and 320x192 (H.264's coded size) */
    VASurfaceID src180, src192;
    vt.vaCreateSurfaces2(&dc, VA_RT_FORMAT_YUV420, 320, 180, &src180, 1, NULL, 0);
    vt.vaCreateSurfaces2(&dc, VA_RT_FORMAT_YUV420, 320, 192, &src192, 1, NULL, 0);

    /* Chrome's ARGB frames handed back to VA-API */
    VASurfaceID dst = import_argb(192), small = import_argb(180);
    snprintf(what, sizeof(what), "ARGB import 320x180 in a buffer of 192 rows: Mesa made it %ux%u (descriptor %ux%u)",
             seen[dst].width, seen[dst].height, seen[dst].desc_width, seen[dst].desc_height);
    check(yes ? seen[dst].height == 192 && seen[dst].desc_height == 192 :
                seen[dst].height == 180 && seen[dst].desc_height == 180, what);
    snprintf(what, sizeof(what), "ARGB import 320x180 in a buffer of 180 rows: Mesa made it %ux%u",
             seen[small].width, seen[small].height);
    check(seen[small].height == 180 && seen[small].desc_height == 180, what);

    /* video processing as Chrome's BlitSurface does it */
    VAContextID proc;
    VABufferID buf;
    VARectangle in = { 0, 0, 320, 180 }, out = { 0, 0, 320, 180 }, part = { 0, 0, 160, 90 };
    VAProcPipelineParameterBuffer pp;
    memset(&pp, 0, sizeof(pp));
    vt.vaCreateContext(&dc, 1, 320, 180, 0, NULL, 0, &proc);
    vt.vaCreateBuffer(&dc, proc, VAProcPipelineParameterBufferType, sizeof(pp), 1, &pp, &buf);
    VAProcPipelineParameterBuffer *app = NULL;
    vt.vaMapBuffer(&dc, buf, (void **)&app);

    struct { const char *name; VASurfaceID src, dst; VARectangle *out; VARectangle want_src, want_out; } cases[] = {
        { "320x180 NV12 into the 192-row ARGB import", src180, dst, &out,
          yes ? (VARectangle){ 0, 0, 320, 169 } : in, yes ? (VARectangle){ 0, 0, 320, 192 } : out },
        { "320x192 NV12 (H.264) into it", src192, dst, &out,
          in, yes ? (VARectangle){ 0, 0, 320, 192 } : out },
        { "into part of the frame", src192, dst, &part, in, part },
        { "into the 180-row import", src192, small, &out, in, out },
    };
    for (unsigned c = 0; c < sizeof(cases) / sizeof(cases[0]); c++) {
        int before = *renders;
        app->surface = cases[c].src;
        app->surface_region = &in;
        app->output_region = cases[c].out;
        vt.vaBeginPicture(&dc, proc, cases[c].dst);
        vt.vaRenderPicture(&dc, proc, &buf, 1);
        int ok = *renders == before + 1 &&
                 !memcmp(seen_src, &cases[c].want_src, sizeof(VARectangle)) &&
                 !memcmp(seen_out, &cases[c].want_out, sizeof(VARectangle)) &&
                 app->surface_region == &in && app->output_region == cases[c].out;
        snprintf(what, sizeof(what), "%s: Mesa got source %d,%d %ux%u and output %d,%d %ux%u; the app's regions back: %s",
                 cases[c].name, seen_src->x, seen_src->y, seen_src->width, seen_src->height,
                 seen_out->x, seen_out->y, seen_out->width, seen_out->height,
                 app->surface_region == &in && app->output_region == cases[c].out ? "yes" : "no");
        check(ok, what);
    }
    if (failed) {
        printf("va-shim-vpp-fill (%s): FAILED\n", argv[3]);
        return 1;
    }
    return 0;
}
#endif
