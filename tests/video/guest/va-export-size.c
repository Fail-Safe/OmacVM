/*
 * va-export-size: a decoder surface's exported planes fit in their dma-bufs, as Chromium
 * checks before it hands them back to VA-API (vaapi_wrapper.cc ValidateAndGetPlaneInfo:
 * offset + pitch x rows of each plane <= lseek(fd, 0, SEEK_END)).
 * Run in the VM (any user):
 *   cc -O2 -o va-export-size va-export-size.c -lva -lva-drm && \
 *   OMACVM_VA_EXPORT=1 LIBVA_DRIVER_NAME=omacvm LIBVA_DRIVERS_PATH=/usr/local/lib/dri:/usr/lib/dri ./va-export-size
 * Surfaces are made as Chrome makes them (usage hint "decoder", no memory type), NV12 and
 * P010, 1080p (rounded to 1088 like Chrome's coded size) and 4K, exported as Chrome does
 * (DRM_PRIME_2, one layer). Prints each plane; exit 0 when every plane fits.
 * With Mesa's virgl alone the dma-bufs are one page ("Plane 0 is out of bounds: 2088960 >
 * 4096"); OmacVM's driver shim asks for exportable surfaces (src/app/guest/omacvm_drv_video.c).
 */
#include <fcntl.h>
#include <stdint.h>
#include <stdio.h>
#include <unistd.h>
#include <va/va.h>
#include <va/va_drm.h>
#include <va/va_drmcommon.h>

static int check(VADisplay dpy, unsigned rt, unsigned w, unsigned h, const char *name)
{
    VASurfaceAttrib hint = {
        .type = VASurfaceAttribUsageHint,
        .flags = VA_SURFACE_ATTRIB_SETTABLE,
        .value = { .type = VAGenericValueTypeInteger, .value.i = VA_SURFACE_ATTRIB_USAGE_HINT_DECODER },
    };
    VADRMPRIMESurfaceDescriptor d = { 0 };
    VASurfaceID s;
    unsigned bpp = rt == VA_RT_FORMAT_YUV420_10 ? 2 : 1, i, bad = 0;
    VAStatus st = vaCreateSurfaces(dpy, rt, w, h, &s, 1, &hint, 1);

    if (st != VA_STATUS_SUCCESS) {
        printf("%s %ux%u: vaCreateSurfaces: %s\n", name, w, h, vaErrorStr(st));
        return 1;
    }
    st = vaExportSurfaceHandle(dpy, s, VA_SURFACE_ATTRIB_MEM_TYPE_DRM_PRIME_2,
                               VA_EXPORT_SURFACE_READ_WRITE | VA_EXPORT_SURFACE_COMPOSED_LAYERS, &d);
    if (st != VA_STATUS_SUCCESS) {
        printf("%s %ux%u: vaExportSurfaceHandle: %s\n", name, w, h, vaErrorStr(st));
        vaDestroySurfaces(dpy, &s, 1);
        return 1;
    }
    for (i = 0; i < d.layers[0].num_planes && i < 4; i++) {
        unsigned obj = d.layers[0].object_index[i];
        off_t size = obj < d.num_objects ? lseek(d.objects[obj].fd, 0, SEEK_END) : -1;
        /* Chrome's rows for 4:2:0: all of them for Y, half (rounded up) for UV. */
        unsigned rows = i == 0 ? h : (h + 1) / 2;
        uint64_t end = (uint64_t)d.layers[0].offset[i] + (uint64_t)d.layers[0].pitch[i] * rows;
        int fits = size >= 0 && end <= (uint64_t)size && d.layers[0].pitch[i] >= w * bpp;

        printf("%s %ux%u plane %u: object %u lseek %lld, offset %u, pitch %u, end %llu: %s\n", name,
               w, h, i, obj, (long long)size, d.layers[0].offset[i], d.layers[0].pitch[i],
               (unsigned long long)end, fits ? "fits" : "OUT OF BOUNDS");
        bad |= !fits;
    }
    for (i = 0; i < d.num_objects && i < 4; i++)
        close(d.objects[i].fd);
    vaDestroySurfaces(dpy, &s, 1);
    return bad;
}

int main(void)
{
    int fd = open("/dev/dri/renderD128", O_RDWR | O_CLOEXEC), major, minor, bad = 0;
    VADisplay dpy;

    if (fd < 0) {
        perror("/dev/dri/renderD128");
        return 2;
    }
    dpy = vaGetDisplayDRM(fd);
    if (vaInitialize(dpy, &major, &minor) != VA_STATUS_SUCCESS) {
        fprintf(stderr, "vaInitialize failed\n");
        return 2;
    }
    printf("driver: %s\n", vaQueryVendorString(dpy));
    bad |= check(dpy, VA_RT_FORMAT_YUV420, 1920, 1088, "NV12");
    bad |= check(dpy, VA_RT_FORMAT_YUV420, 3840, 2160, "NV12");
    bad |= check(dpy, VA_RT_FORMAT_YUV420_10, 1920, 1088, "P010");
    bad |= check(dpy, VA_RT_FORMAT_YUV420, 640, 368, "NV12");
    vaTerminate(dpy);
    close(fd);
    printf("%s\n", bad ? "FAIL: a plane runs past its dma-buf" : "ok: every plane fits its dma-buf");
    return bad;
}
