/* Decoding beside vrend's thread (virgl-videotoolbox-decode-async.patch): END_FRAME
 * sends the picture to the Mac's media engine and returns; the picture goes into the
 * guest's planes when it is in, and always before anything reads or writes them.
 * Checks, with an H.264 stream made here by VTCompressionSession (3840x2160):
 * - END_FRAME returns in less than half the time VideoToolbox takes for the same
 *   picture when it is waited for (measured here with a session of the test's own);
 * - every picture lands in its planes, read back right after END_FRAME;
 * - more pictures sent at once than the decoder keeps in flight all land, in order;
 * - another guest context copying the planes right after END_FRAME (no poll, no
 *   read in between) copies the picture, not what was there before;
 * - another guest context clearing a plane right after END_FRAME (a draw-type
 *   command: the planes as its render target) clears after the picture went in;
 * - a fence made after END_FRAME signals only once the picture is in the planes:
 *   read straight from the GL texture once it signalled (no vrend in between);
 * - a buffer and a decoder destroyed with pictures in flight: the other pictures land;
 * - a picture the media engine never gives back (OMACVM_TEST_VIDEO_LOSE): the
 *   fence after it signals once the picture is given up after 1 s, also polled.
 * OMACVM_TEST_THREAD_SYNC=1: fences reported by the sync thread (QEMU's way).
 * OMACVM_VIDEO_DECODE_SYNC=1 (END_FRAME waits, as before): the timing check is
 * skipped, everything else must hold the same.
 * Runs on Apple's software OpenGL (soft-gl.h); the decoder is the Mac's media engine.
 * Skips when the Mac has no H.264 encoder or decoder. */
#include <CoreMedia/CoreMedia.h>
#include <OpenGL/OpenGL.h>
#include <VideoToolbox/VideoToolbox.h>
#include <math.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/uio.h>
#include <unistd.h>
#include "soft-gl.h"
#define VIRGL_RENDERER_UNSTABLE_APIS 1
#include "virglrenderer.h"
#include "virgl_hw.h"
#include "virgl_protocol.h"
#include "virgl_video_hw.h"

/* GL without the GL headers (they clash with virgl's) */
void glBindTexture(unsigned int target, unsigned int texture);
void glGetTexImage(unsigned int target, int level, unsigned int format, unsigned int type,
                   void *pixels);
void glPixelStorei(unsigned int pname, int param);
void glFinish(void);
#define T_GL_TEXTURE_2D 0x0DE1
#define T_GL_RED 0x1903
#define T_GL_UNSIGNED_BYTE 0x1401
#define T_GL_PACK_ALIGNMENT 0x0D05

enum { W = 3840, H = 2160, FRAMES = 12, NBUF = 6 };
enum { TEST_PIPE_BUFFER = 0, TEST_PIPE_TEXTURE_2D = 2 };
/* guest numbering (Mesa >= 26): enum pipe_video_profile / entrypoint */
enum { G_AVC_HIGH = 11, G_ENTRYPOINT_BITSTREAM = 1 };
/* resources: the description and data buffers, a copy target; buffer B's planes */
enum { R_DESC = 1, R_BITS, R_COPY };
#define R_Y(b) (10u + 2u * (b))
#define R_UV(b) (11u + 2u * (b))
#define BUF(b) (100u + (b))

static CGLContextObj main_ctx;
static int failures;
static int sync_mode;

static void check(int ok, const char *what)
{
   printf("%s: %s\n", ok ? "ok" : "FAIL", what);
   failures += !ok;
}

static volatile uint32_t fence_done;
static uint32_t fence_next;

static void write_fence(void *cookie, uint32_t fence)
{
   (void)cookie;
   __atomic_store_n(&fence_done, fence, __ATOMIC_RELEASE);
}

static virgl_renderer_gl_context create_gl_context(void *cookie, int scanout,
                                                   struct virgl_renderer_gl_ctx_param *param)
{
   (void)cookie;
   (void)scanout;
   (void)param;
   /* QEMU (ui/cocoa) shares every context with its view's context. */
   return soft_gl_context(main_ctx);
}

static void destroy_gl_context(void *cookie, virgl_renderer_gl_context ctx)
{
   (void)cookie;
   CGLDestroyContext(ctx);
}

static int make_current(void *cookie, int scanout, virgl_renderer_gl_context ctx)
{
   (void)cookie;
   (void)scanout;
   return CGLSetCurrentContext(ctx) ? -1 : 0;
}

static struct virgl_renderer_callbacks callbacks = {
   .version = 1,
   .write_fence = write_fence,
   .create_gl_context = create_gl_context,
   .destroy_gl_context = destroy_gl_context,
   .make_current = make_current,
};

struct cmds {
   uint32_t dw[4096];
   unsigned n;
};

static struct cmds *c;

static void emit(uint32_t v)
{
   c->dw[c->n++] = v;
}

static int submit(uint32_t ctx_id)
{
   int r = virgl_renderer_submit_cmd(c->dw, (int)ctx_id, (int)c->n);
   c->n = 0;
   return r;
}

static struct iovec iov[64];

static void make_res(uint32_t handle, uint32_t target, uint32_t format, uint32_t bind,
                     uint32_t w, uint32_t h, void *backing, size_t size)
{
   struct virgl_renderer_resource_create_args a = {
      .handle = handle, .target = target, .format = format, .bind = bind,
      .width = w, .height = h, .depth = 1, .array_size = 1,
   };
   virgl_renderer_resource_create(&a, NULL, 0);
   if (backing) {
      iov[handle] = (struct iovec){ backing, size };
      virgl_renderer_resource_attach_iov(handle, &iov[handle], 1);
   }
}

/* the guest writes zeros into a whole 2D plane (TRANSFER_TO_HOST, as a vaPutImage) */
static uint8_t zeros[W * H];

static void clear_plane(uint32_t handle, uint32_t ctx, uint32_t w, uint32_t h, uint32_t bpp)
{
   struct virgl_box box = { 0, 0, 0, w, h, 1 };
   struct iovec in = { zeros, (size_t)w * h * bpp };
   virgl_renderer_transfer_write_iov(handle, ctx, 0, w * bpp, 0, &box, 0, &in, 1);
}

/* a moving gradient with a square, so pictures differ */
static uint8_t ys[FRAMES][W * H];

static void make_picture(int f, uint8_t *y, uint8_t *uv)
{
   for (int j = 0; j < H; j++)
      for (int i = 0; i < W; i++) {
         int v = (i + 24 * f) * 255 / (W + 400);
         if (i >= 200 + 60 * f && i < 600 + 60 * f && j >= 300 && j < 700)
            v = 235;
         y[j * W + i] = (uint8_t)(16 + v * 219 / 255);
      }
   for (int j = 0; j < H / 2; j++)
      for (int i = 0; i < W / 2; i++) {
         uv[(j * W / 2 + i) * 2] = (uint8_t)(100 + j / 8);
         uv[(j * W / 2 + i) * 2 + 1] = (uint8_t)(150 - i / 16);
      }
}

/* --- the stream: Annex B access units from VideoToolbox's encoder ----------------- */
struct stream {
   int count;
   uint8_t *au[FRAMES];
   size_t au_size[FRAMES];
   CMFormatDescriptionRef fmt;
};
static struct stream avc;

static void put_nal(uint8_t **out, size_t *n, const uint8_t *nal, size_t len)
{
   *out = realloc(*out, *n + 4 + len);
   memcpy(*out + *n, "\0\0\0\1", 4);
   memcpy(*out + *n + 4, nal, len);
   *n += 4 + len;
}

static void enc_cb(void *ref, void *frame_ref, OSStatus st, VTEncodeInfoFlags flags,
                   CMSampleBufferRef sample)
{
   struct stream *s = ref;
   (void)frame_ref;
   (void)flags;
   if (st != noErr || !sample || s->count >= FRAMES)
      return;
   uint8_t *out = NULL;
   size_t n = 0;
   CFArrayRef att = CMSampleBufferGetSampleAttachmentsArray(sample, false);
   int key = !(att && CFArrayGetCount(att) &&
               CFDictionaryContainsKey(CFArrayGetValueAtIndex(att, 0),
                                       kCMSampleAttachmentKey_NotSync));
   if (key) {
      CMFormatDescriptionRef fmt = CMSampleBufferGetFormatDescription(sample);
      for (size_t i = 0; i < 2; i++) {
         const uint8_t *ps = NULL;
         size_t len = 0;
         if (CMVideoFormatDescriptionGetH264ParameterSetAtIndex(fmt, i, &ps, &len, NULL,
                                                                NULL) == noErr)
            put_nal(&out, &n, ps, len);
      }
      if (!s->fmt && fmt) {
         s->fmt = fmt;
         CFRetain(fmt);
      }
   }
   CMBlockBufferRef block = CMSampleBufferGetDataBuffer(sample);
   size_t total = CMBlockBufferGetDataLength(block);
   uint8_t *data = malloc(total);
   CMBlockBufferCopyDataBytes(block, 0, total, data);
   for (size_t off = 0; off + 4 <= total;) {
      size_t len = (size_t)data[off] << 24 | data[off + 1] << 16 | data[off + 2] << 8 |
                   data[off + 3];
      if (len > total - off - 4)
         break;
      put_nal(&out, &n, data + off + 4, len);
      off += 4 + len;
   }
   free(data);
   s->au[s->count] = out;
   s->au_size[s->count++] = n;
}

static int make_stream(struct stream *s)
{
   VTCompressionSessionRef vt = NULL;
   if (VTCompressionSessionCreate(NULL, W, H, kCMVideoCodecType_H264, NULL, NULL, NULL,
                                  enc_cb, s, &vt) != noErr)
      return 0;
   VTSessionSetProperty(vt, kVTCompressionPropertyKey_RealTime, kCFBooleanTrue);
   VTSessionSetProperty(vt, kVTCompressionPropertyKey_AllowFrameReordering, kCFBooleanFalse);
   VTSessionSetProperty(vt, kVTCompressionPropertyKey_ProfileLevel,
                        kVTProfileLevel_H264_High_AutoLevel);
   static uint8_t uv[W * H / 2];
   for (int f = 0; f < FRAMES; f++) {
      CVPixelBufferRef pix = NULL;
      CVPixelBufferCreate(NULL, W, H, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, NULL,
                          &pix);
      make_picture(f, ys[f], uv);
      CVPixelBufferLockBaseAddress(pix, 0);
      for (int p = 0; p < 2; p++) {
         uint8_t *dst = CVPixelBufferGetBaseAddressOfPlane(pix, p);
         size_t row = CVPixelBufferGetBytesPerRowOfPlane(pix, p);
         for (int j = 0; j < (p ? H / 2 : H); j++)
            memcpy(dst + j * row, p ? uv + j * W : ys[f] + j * W, W);
      }
      CVPixelBufferUnlockBaseAddress(pix, 0);
      VTCompressionSessionEncodeFrame(vt, pix, CMTimeMake(f, 30), kCMTimeInvalid, NULL, NULL,
                                      NULL);
      CVPixelBufferRelease(pix);
   }
   VTCompressionSessionCompleteFrames(vt, kCMTimeInvalid);
   VTCompressionSessionInvalidate(vt);
   CFRelease(vt);
   return s->count == FRAMES;
}

/* --- how long VideoToolbox takes for a picture when it is waited for --------------- */
static void own_cb(void *refcon, void *frame, OSStatus st, VTDecodeInfoFlags flags,
                   CVImageBufferRef image, CMTime pts, CMTime dur)
{
   (void)refcon; (void)frame; (void)st; (void)flags; (void)image; (void)pts; (void)dur;
}

static uint64_t now_ns(void)
{
   return clock_gettime_nsec_np(CLOCK_UPTIME_RAW);
}

static int cmp_u64(const void *a, const void *b)
{
   uint64_t x = *(const uint64_t *)a, y = *(const uint64_t *)b;
   return x < y ? -1 : x > y;
}

/* median ns of DecodeFrame + WaitForAsynchronousFrames over the stream (AVCC samples) */
static uint64_t own_decode_ns(void)
{
   VTDecompressionSessionRef s = NULL;
   VTDecompressionOutputCallbackRecord cb = { own_cb, NULL };
   uint64_t t[FRAMES];
   int n = 0;
   if (VTDecompressionSessionCreate(NULL, avc.fmt, NULL, NULL, &cb, &s) != noErr)
      return 0;
   VTSessionSetProperty(s, kVTDecompressionPropertyKey_RealTime, kCFBooleanTrue);
   for (int f = 0; f < FRAMES; f++) {
      /* Annex B -> 4-byte lengths, slices only (the parameter sets are in fmt) */
      uint8_t *avcc = malloc(avc.au_size[f]);
      size_t m = 0;
      const uint8_t *a = avc.au[f];
      for (size_t i = 0; i + 4 <= avc.au_size[f];) {
         size_t j = i + 4;
         while (j + 4 <= avc.au_size[f] && memcmp(a + j, "\0\0\0\1", 4))
            j++;
         if (j + 4 > avc.au_size[f])
            j = avc.au_size[f];
         size_t len = j - i - 4;
         int type = a[i + 4] & 0x1f;
         if (type != 7 && type != 8) {
            avcc[m] = (uint8_t)(len >> 24); avcc[m + 1] = (uint8_t)(len >> 16);
            avcc[m + 2] = (uint8_t)(len >> 8); avcc[m + 3] = (uint8_t)len;
            memcpy(avcc + m + 4, a + i + 4, len);
            m += 4 + len;
         }
         i = j;
      }
      CMBlockBufferRef block = NULL;
      CMSampleBufferRef sample = NULL;
      CMBlockBufferCreateWithMemoryBlock(NULL, NULL, m, NULL, NULL, 0, m,
                                         kCMBlockBufferAssureMemoryNowFlag, &block);
      CMBlockBufferReplaceDataBytes(avcc, block, 0, m);
      CMSampleBufferCreate(NULL, block, true, NULL, NULL, avc.fmt, 1, 0, NULL, 1, &m, &sample);
      uint64_t t0 = now_ns();
      VTDecodeInfoFlags info = 0;
      if (VTDecompressionSessionDecodeFrame(s, sample, 0, NULL, &info) == noErr &&
          VTDecompressionSessionWaitForAsynchronousFrames(s) == noErr)
         t[n++] = now_ns() - t0;
      CFRelease(sample);
      CFRelease(block);
      free(avcc);
   }
   VTDecompressionSessionInvalidate(s);
   CFRelease(s);
   if (n < FRAMES / 2)
      return 0;
   qsort(t, (size_t)n, sizeof(t[0]), cmp_u64);
   return t[n / 2];
}

/* --- the guest side ---------------------------------------------------------------- */
static union virgl_picture_desc desc;
static uint8_t bits[1 << 22];

static void create_codec(uint32_t handle)
{
   emit(VIRGL_CMD0(VIRGL_CCMD_CREATE_VIDEO_CODEC, 0, 8));
   emit(handle);
   emit(G_AVC_HIGH);
   emit(G_ENTRYPOINT_BITSTREAM);
   emit(1);                    /* chroma 4:2:0 */
   emit(51);
   emit(W);
   emit(H);
   emit(4);
}

static void destroy_codec(uint32_t handle)
{
   emit(VIRGL_CMD0(VIRGL_CCMD_DESTROY_VIDEO_CODEC, 0, 1));
   emit(handle);
}

static void create_buffer(unsigned b)
{
   emit(VIRGL_CMD0(VIRGL_CCMD_CREATE_VIDEO_BUFFER, 0, 6));
   emit(BUF(b));
   emit(VIRGL_FORMAT_Y8_U8V8_420_UNORM);
   emit(W);
   emit(H);
   emit(R_Y(b));
   emit(R_UV(b));
}

static void destroy_buffer(unsigned b)
{
   emit(VIRGL_CMD0(VIRGL_CCMD_DESTROY_VIDEO_BUFFER, 0, 1));
   emit(BUF(b));
}

/* Picture F into buffer B with CODEC: the luma plane cleared first, then BEGIN_FRAME,
 * DECODE_BITSTREAM, END_FRAME in one submit of context 1. Returns the submit's time.
 * The host takes the data and the description at DECODE_BITSTREAM: one buffer each will do.
 * Pictures go in stream order (a P picture needs the one before it). */
static unsigned pictures_sent;
/* the picture whose output the host drops (test hook, numbered from 1) */
#define LOST_PICTURE 29

static uint64_t send_picture(uint32_t codec, unsigned b, int f)
{
   pictures_sent++;
   clear_plane(R_Y(b), 1, W, H, 1);
   memcpy(bits, avc.au[f], avc.au_size[f]);
   memset(&desc, 0, sizeof(desc));
   desc.h264.base.profile = G_AVC_HIGH;
   desc.h264.base.entry_point = G_ENTRYPOINT_BITSTREAM;
   desc.h264.frame_num = (uint32_t)f;
   desc.h264.is_reference = 1;
   desc.h264.num_ref_frames = 4;
   desc.h264.slice_count = 1;
   emit(VIRGL_CMD0(VIRGL_CCMD_BEGIN_FRAME, 0, 2));
   emit(codec);
   emit(BUF(b));
   emit(VIRGL_CMD0(VIRGL_CCMD_DECODE_BITSTREAM, 0, 5));
   emit(codec);
   emit(BUF(b));
   emit(R_DESC);
   emit(R_BITS);
   emit((uint32_t)avc.au_size[f]);
   emit(VIRGL_CMD0(VIRGL_CCMD_END_FRAME, 0, 2));
   emit(codec);
   emit(BUF(b));
   uint64_t t0 = now_ns();
   submit(1);
   return now_ns() - t0;
}

static double psnr(const uint8_t *got, int f)
{
   double se = 0;
   for (int i = 0; i < W * H; i++) {
      double e = (double)got[i] - ys[f][i];
      se += e * e;
   }
   double mse = se / (W * H);
   return mse > 0 ? 10 * log10(255.0 * 255.0 / mse) : 99;
}

static uint8_t got[W * H];

/* the luma plane of RES as the guest reads it (TRANSFER_FROM_HOST in context CTX) */
static double read_luma(uint32_t res, uint32_t ctx, int f)
{
   struct virgl_box box = { 0, 0, 0, W, H, 1 };
   struct iovec out = { got, sizeof(got) };
   memset(got, 0, sizeof(got));
   if (virgl_renderer_transfer_read_iov(res, ctx, 0, W, 0, &box, 0, &out, 1))
      return 0;
   return psnr(got, f);
}

/* the luma plane of RES straight from its GL texture, past vrend */
static double read_luma_gl(uint32_t res, int f)
{
   struct virgl_renderer_resource_info info;
   memset(got, 0, sizeof(got));
   if (virgl_renderer_resource_get_info((int)res, &info) || !info.tex_id)
      return 0;
   CGLContextObj old = CGLGetCurrentContext();
   CGLSetCurrentContext(main_ctx);
   glFinish();
   glBindTexture(T_GL_TEXTURE_2D, info.tex_id);
   glPixelStorei(T_GL_PACK_ALIGNMENT, 1);
   glGetTexImage(T_GL_TEXTURE_2D, 0, T_GL_RED, T_GL_UNSIGNED_BYTE, got);
   glBindTexture(T_GL_TEXTURE_2D, 0);
   CGLSetCurrentContext(old);
   return psnr(got, f);
}

/* a fence after what was submitted; polls (as QEMU's main loop does) until it signals */
static int wait_fence(void)
{
   uint32_t id = ++fence_next;

   virgl_renderer_create_fence((int)id, 1);
   for (int i = 0; i < 5000; i++) {
      virgl_renderer_poll();
      if (__atomic_load_n(&fence_done, __ATOMIC_ACQUIRE) >= id)
         return 0;
      usleep(1000);
   }
   printf("FAIL: fence %u not signalled after 5 s\n", id);
   return -1;
}

/* the share of the luma plane of RES (read in context CTX) that is V */
static double share_of(uint32_t res, uint32_t ctx, uint8_t v)
{
   struct virgl_box box = { 0, 0, 0, W, H, 1 };
   struct iovec out = { got, sizeof(got) };
   long n = 0;
   memset(got, 0, sizeof(got));
   if (virgl_renderer_transfer_read_iov(res, ctx, 0, W, 0, &box, 0, &out, 1))
      return 0;
   for (int i = 0; i < W * H; i++)
      n += got[i] == v;
   return (double)n / (W * H);
}

static uint32_t fbits(float f)
{
   uint32_t u;
   memcpy(&u, &f, sizeof(u));
   return u;
}

int main(void)
{
   char line[300];

   setvbuf(stdout, NULL, _IONBF, 0);
   char lose[16];
   snprintf(lose, sizeof(lose), "%d", LOST_PICTURE);
   setenv("OMACVM_TEST_VIDEO_LOSE", lose, 1);
   const char *ds = getenv("OMACVM_VIDEO_DECODE_SYNC");
   sync_mode = ds && *ds == '1';
   main_ctx = soft_gl_context(NULL);
   if (!main_ctx || CGLSetCurrentContext(main_ctx)) {
      printf("skip: no OpenGL context on this Mac\n");
      return 0;
   }
   soft_gl_require();
   static int cookie;
   int flags = VIRGL_RENDERER_USE_VIDEO;
   const char *ts = getenv("OMACVM_TEST_THREAD_SYNC");
   if (ts && !strcmp(ts, "1")) {
      flags |= VIRGL_RENDERER_THREAD_SYNC | VIRGL_RENDERER_ASYNC_FENCE_CB;
      printf("fences: reported by the sync thread\n");
   }
   if (virgl_renderer_init(&cookie, flags, &callbacks)) {
      printf("FAIL: virgl_renderer_init\n");
      return 1;
   }
   if (!make_stream(&avc) || !avc.fmt) {
      printf("skip: no H.264 encoder to make the test stream (%d pictures)\n", avc.count);
      return 0;
   }
   uint64_t own = own_decode_ns();
   if (!own) {
      printf("skip: no H.264 decoder for the test stream\n");
      return 0;
   }

   c = calloc(1, sizeof(*c));
   make_res(R_DESC, TEST_PIPE_BUFFER, VIRGL_FORMAT_R8_UNORM, VIRGL_BIND_CUSTOM,
            sizeof(desc), 1, &desc, sizeof(desc));
   make_res(R_BITS, TEST_PIPE_BUFFER, VIRGL_FORMAT_R8_UNORM, VIRGL_BIND_CUSTOM,
            sizeof(bits), 1, bits, sizeof(bits));
   make_res(R_COPY, TEST_PIPE_TEXTURE_2D, VIRGL_FORMAT_R8_UNORM,
            VIRGL_BIND_SAMPLER_VIEW | VIRGL_BIND_RENDER_TARGET, W, H, NULL, 0);
   for (unsigned b = 0; b < NBUF; b++) {
      make_res(R_Y(b), TEST_PIPE_TEXTURE_2D, VIRGL_FORMAT_R8_UNORM,
               VIRGL_BIND_SAMPLER_VIEW | VIRGL_BIND_RENDER_TARGET, W, H, NULL, 0);
      make_res(R_UV(b), TEST_PIPE_TEXTURE_2D, VIRGL_FORMAT_R8G8_UNORM,
               VIRGL_BIND_SAMPLER_VIEW | VIRGL_BIND_RENDER_TARGET, W / 2, H / 2, NULL, 0);
   }
   /* context 1 decodes; context 2 (another guest app) sees the same planes */
   for (uint32_t ctx = 1; ctx <= 2; ctx++) {
      virgl_renderer_context_create(ctx, 4, ctx == 1 ? "vdec" : "other");
      virgl_renderer_ctx_attach_resource((int)ctx, R_COPY);
      for (unsigned b = 0; b < NBUF; b++) {
         virgl_renderer_ctx_attach_resource((int)ctx, (int)R_Y(b));
         virgl_renderer_ctx_attach_resource((int)ctx, (int)R_UV(b));
      }
   }
   virgl_renderer_ctx_attach_resource(1, R_DESC);
   virgl_renderer_ctx_attach_resource(1, R_BITS);
   for (unsigned b = 0; b < NBUF; b++)
      create_buffer(b);
   create_codec(10);
   submit(1);

   /* 1: END_FRAME's time, and every picture read right after it */
   uint64_t t[FRAMES];
   double low = 99;
   for (int f = 0; f < FRAMES; f++) {
      t[f] = send_picture(10, 0, f);
      double p = read_luma(R_Y(0), 1, f);
      if (p < low)
         low = p;
   }
   qsort(t, FRAMES, sizeof(t[0]), cmp_u64);
   snprintf(line, sizeof(line), "%d pictures land in their planes, read right after END_FRAME: "
            "lowest luma PSNR %.1f dB", FRAMES, low);
   check(low > 30, line);
   snprintf(line, sizeof(line), "END_FRAME returns before the picture is decoded: median "
            "%.2f ms, VideoToolbox waited for: %.2f ms", t[FRAMES / 2] / 1e6, own / 1e6);
   if (sync_mode)
      printf("skip (OMACVM_VIDEO_DECODE_SYNC=1): %s\n", line);
   else
      check(t[FRAMES / 2] * 2 < own, line);

   /* 2: more pictures at once than the decoder keeps in flight, then read */
   low = 99;
   for (unsigned b = 0; b < NBUF; b++)
      send_picture(10, b, (int)b);
   for (unsigned b = 0; b < NBUF; b++) {
      double p = read_luma(R_Y(b), 1, (int)b);
      if (p < low)
         low = p;
   }
   snprintf(line, sizeof(line), "%d pictures sent at once, then read: lowest luma PSNR %.1f dB",
            NBUF, low);
   check(low > 30, line);

   /* 3: another context copies the plane right after END_FRAME */
   send_picture(10, 1, 6);
   emit(VIRGL_CMD0(VIRGL_CCMD_RESOURCE_COPY_REGION, 0, VIRGL_CMD_RESOURCE_COPY_REGION_SIZE));
   emit(R_COPY);
   emit(0);
   emit(0);
   emit(0);
   emit(0);
   emit(R_Y(1));
   emit(0);
   emit(0);
   emit(0);
   emit(0);
   emit(W);
   emit(H);
   emit(1);
   submit(2);
   double p = read_luma(R_COPY, 2, 6);
   snprintf(line, sizeof(line), "another context copies the plane right after END_FRAME: "
            "the picture (luma PSNR %.1f dB)", p);
   check(p > 30, line);

   /* 3b: another context clears the plane (its render target) right after END_FRAME:
    * the picture goes in first, the clear wins */
   emit(VIRGL_CMD0(VIRGL_CCMD_CREATE_OBJECT, VIRGL_OBJECT_SURFACE, VIRGL_OBJ_SURFACE_SIZE));
   emit(50);
   emit(R_Y(1));
   emit(VIRGL_FORMAT_R8_UNORM);
   emit(0);
   emit(0);
   emit(VIRGL_CMD0(VIRGL_CCMD_SET_FRAMEBUFFER_STATE, 0, VIRGL_SET_FRAMEBUFFER_STATE_SIZE(1)));
   emit(1);
   emit(0);
   emit(50);
   submit(2);
   send_picture(10, 1, 7);
   emit(VIRGL_CMD0(VIRGL_CCMD_CLEAR, 0, VIRGL_OBJ_CLEAR_SIZE));
   emit(1u << 2);                       /* PIPE_CLEAR_COLOR0 */
   emit(fbits(1.0f));
   emit(fbits(0.0f));
   emit(fbits(0.0f));
   emit(fbits(1.0f));
   emit(0);
   emit(0);
   emit(0);
   submit(2);
   double sh = share_of(R_Y(1), 2, 255);
   snprintf(line, sizeof(line), "another context clears the plane right after END_FRAME: "
            "the clear wins (%.1f %% of the plane cleared)", sh * 100);
   check(sh > 0.999, line);
   emit(VIRGL_CMD0(VIRGL_CCMD_SET_FRAMEBUFFER_STATE, 0, VIRGL_SET_FRAMEBUFFER_STATE_SIZE(0)));
   emit(0);
   emit(0);
   emit(VIRGL_CMD0(VIRGL_CCMD_DESTROY_OBJECT, VIRGL_OBJECT_SURFACE, 1));
   emit(50);
   submit(2);

   /* 4: a fence after END_FRAME, then the GL texture itself */
   low = 99;
   for (int f = 0; f < 4; f++) {
      send_picture(10, 2, f);
      if (wait_fence())
         break;
      double q = read_luma_gl(R_Y(2), f);
      if (q < low)
         low = q;
   }
   snprintf(line, sizeof(line), "a fence after END_FRAME signals once the picture is in its "
            "plane (read from GL): lowest luma PSNR %.1f dB", low);
   check(low > 30, line);

   /* 5: a buffer and then the decoder go away with pictures in flight */
   send_picture(10, 3, 4);
   send_picture(10, 4, 5);
   send_picture(10, 5, 6);
   destroy_buffer(4);
   destroy_codec(10);
   submit(1);
   double p3 = read_luma(R_Y(3), 1, 4), p5 = read_luma(R_Y(5), 1, 6);
   snprintf(line, sizeof(line), "a buffer and the decoder destroyed with pictures in flight: "
            "the others land (luma PSNR %.1f / %.1f dB)", p3, p5);
   check(p3 > 30 && p5 > 30, line);

   /* the renderer still answers and goes away cleanly */
   create_codec(11);
   submit(1);
   send_picture(11, 0, 0);
   p = read_luma(R_Y(0), 1, 0);
   snprintf(line, sizeof(line), "a new decoder afterwards decodes (luma PSNR %.1f dB)", p);
   check(p > 30, line);

   /* 6: the media engine never gives a picture back: the fence after it waits for
    * the give-up after 1 s, not 2 s (sync thread) or for ever (polled) */
   if (!sync_mode) {
      check(pictures_sent + 1 == LOST_PICTURE, "the lost picture is the next one");
      send_picture(11, 1, 1);
      uint64_t t0 = now_ns();
      int r = wait_fence();
      double s = (now_ns() - t0) / 1e9;
      snprintf(line, sizeof(line), "a picture that never comes back: the fence after it "
               "signals after %.2f s (given up after 1 s)", s);
      check(!r && s < 1.6, line);
      send_picture(11, 2, 2);
      p = read_luma(R_Y(2), 1, 2);
      snprintf(line, sizeof(line), "the decoder goes on after it (luma PSNR %.1f dB)", p);
      check(p > 30, line);
   }
   virgl_renderer_context_destroy(2);
   virgl_renderer_context_destroy(1);
   virgl_renderer_cleanup(&cookie);

   if (failures) {
      printf("video decode async: %d checks FAILED\n", failures);
      return 1;
   }
   printf("video decode async: all checks passed\n");
   return 0;
}
