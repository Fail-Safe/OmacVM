/*
 * test-display-color-shader: the display colour present (ui/omacvm-dispcolor.h)
 * on Apple's software GL renderer only (never a real GPU: STANDARDS 14), core
 * profile as QEMU's present context. The table is filled by macOS's colour
 * management for a display space, the shader reads it; every result must
 * match macOS converting the same 8-bit sRGB pixel itself within one code
 * (8-bit target, as the present's surfaces) for Display P3 and sRGB, over all
 * 256 greys, the primaries and secondaries and 20000 random colours, and the
 * CPU check the present uses (omacvm_dc_error) must see what the GPU does
 * within a code, also for profiles the table cannot follow (Adobe RGB, P3 with
 * a plain gamma 2.2: those keep the sRGB tag); the
 * rows must come out the way QEMU's blit and its flip variant put them; the
 * alpha must stay the guest's.
 *   cc -fobjc-arc -I<folder with omacvm-dispcolor.h> test-display-color-shader.m \
 *      -framework Foundation -framework OpenGL -framework CoreGraphics
 */
#import <Foundation/Foundation.h>
#define GL_SILENCE_DEPRECATION 1
#import <OpenGL/OpenGL.h>
#import <OpenGL/gl3.h>
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include "omacvm-dispcolor.h"

static int failures;

#define FAIL(...) do { fprintf(stderr, "test-display-color-shader: " __VA_ARGS__); fputc('\n', stderr); failures++; } while (0)

static GLuint shader(GLenum type, const char *src)
{
    GLuint s = glCreateShader(type);
    GLint ok = 0;
    char log[1024] = "";

    glShaderSource(s, 1, &src, NULL);
    glCompileShader(s);
    glGetShaderiv(s, GL_COMPILE_STATUS, &ok);
    if (!ok) {
        glGetShaderInfoLog(s, sizeof(log), NULL, log);
        FAIL("does not compile: %s", log);
    }
    return s;
}

/* macOS's own conversion of 8-bit sRGB pixels into dst, 8-bit out. */
static void reference(CGColorSpaceRef dst, int count, const uint8_t *in, uint8_t *out)
{
    CGColorSpaceRef srgb = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    CGDataProviderRef prov = CGDataProviderCreateWithData(NULL, in, (size_t)count * 4, NULL);
    CGImageRef img = CGImageCreate(count, 1, 8, 32, (size_t)count * 4, srgb,
                                   kCGImageAlphaNoneSkipLast | kCGBitmapByteOrderDefault, prov, NULL,
                                   false, kCGRenderingIntentRelativeColorimetric);
    CGContextRef ctx = CGBitmapContextCreate(out, count, 1, 8, (size_t)count * 4, dst,
                                             kCGImageAlphaNoneSkipLast | kCGBitmapByteOrderDefault);
    CGContextSetInterpolationQuality(ctx, kCGInterpolationNone);
    CGContextSetRenderingIntent(ctx, kCGRenderingIntentRelativeColorimetric);
    CGContextSetBlendMode(ctx, kCGBlendModeCopy);
    CGContextDrawImage(ctx, CGRectMake(0, 0, count, 1), img);
    CGContextRelease(ctx);
    CGImageRelease(img);
    CGDataProviderRelease(prov);
    CGColorSpaceRelease(srgb);
}

/* A panel profile like a MacBook's: P3 primaries, D65, gamma 2.2 (not sRGB's curve). */
static CGColorSpaceRef panel_space(void)
{
    const CGFloat white[3] = { 0.9505, 1.0, 1.0891 };
    const CGFloat black[3] = { 0, 0, 0 };
    const CGFloat gamma[3] = { 2.2, 2.2, 2.2 };
    /* Display P3 primaries in XYZ (D65). */
    const CGFloat m[9] = { 0.4866, 0.2290, 0.0000,
                           0.2657, 0.6917, 0.0451,
                           0.1982, 0.0793, 1.0439 };
    return CGColorSpaceCreateCalibratedRGB(white, black, gamma, m);
}

/* Draw the w x h RGBA8 picture through the program into an RGBA8 target; read it back. */
static void draw(GLuint prog, GLuint vao, GLuint table, int w, int h, const uint8_t *pic, float yflip,
                 uint8_t *out)
{
    GLuint src, dst, fbo;

    glGenTextures(1, &src);
    glBindTexture(GL_TEXTURE_2D, src);
    glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA8, w, h, 0, GL_RGBA, GL_UNSIGNED_BYTE, pic);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_NEAREST);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_NEAREST);
    glGenTextures(1, &dst);
    glBindTexture(GL_TEXTURE_2D, dst);
    glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA8, w, h, 0, GL_RGBA, GL_UNSIGNED_BYTE, NULL);
    glGenFramebuffers(1, &fbo);
    glBindFramebuffer(GL_FRAMEBUFFER, fbo);
    glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_2D, dst, 0);
    if (glCheckFramebufferStatus(GL_FRAMEBUFFER) != GL_FRAMEBUFFER_COMPLETE) {
        FAIL("no 8-bit target");
    }
    glViewport(0, 0, w, h);
    glActiveTexture(GL_TEXTURE1);
    glBindTexture(GL_TEXTURE_3D, table);
    glActiveTexture(GL_TEXTURE0);
    glBindTexture(GL_TEXTURE_2D, src);
    glUseProgram(prog);
    glUniform1i(glGetUniformLocation(prog, "image"), 0);
    glUniform1i(glGetUniformLocation(prog, "table"), 1);
    glUniform1f(glGetUniformLocation(prog, "scale"), omacvm_dc_scale(OMACVM_DC_N));
    glUniform1f(glGetUniformLocation(prog, "offset"), omacvm_dc_offset(OMACVM_DC_N));
    glUniform1f(glGetUniformLocation(prog, "yflip"), yflip);
    glBindVertexArray(vao);
    glDrawArrays(GL_TRIANGLE_STRIP, 0, 4);
    glReadPixels(0, 0, w, h, GL_RGBA, GL_UNSIGNED_BYTE, out);
    glBindFramebuffer(GL_FRAMEBUFFER, 0);
    glDeleteFramebuffers(1, &fbo);
    glDeleteTextures(1, &dst);
    glDeleteTextures(1, &src);
}

static GLuint upload(const uint16_t *t)
{
    GLuint tex;

    glGenTextures(1, &tex);
    glBindTexture(GL_TEXTURE_3D, tex);
    glTexImage3D(GL_TEXTURE_3D, 0, GL_RGBA16, OMACVM_DC_N, OMACVM_DC_N, OMACVM_DC_N, 0, GL_RGBA,
                 GL_UNSIGNED_SHORT, t);
    glTexParameteri(GL_TEXTURE_3D, GL_TEXTURE_MIN_FILTER, GL_LINEAR);
    glTexParameteri(GL_TEXTURE_3D, GL_TEXTURE_MAG_FILTER, GL_LINEAR);
    glTexParameteri(GL_TEXTURE_3D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
    glTexParameteri(GL_TEXTURE_3D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);
    glTexParameteri(GL_TEXTURE_3D, GL_TEXTURE_WRAP_R, GL_CLAMP_TO_EDGE);
    return tex;
}

static void space(GLuint prog, GLuint vao, const char *name, CGColorSpaceRef cs, bool must_pass)
{
    enum { W = 128, H = 160 };          /* 20480 pixels: greys, corners, random */
    static uint8_t pic[W * H * 4], ref[W * H * 4], got[W * H * 4], flipped[W * H * 4], opaque[W * H * 4];
    uint16_t *t = calloc((size_t)OMACVM_DC_N * OMACVM_DC_N * OMACVM_DC_N * 4, sizeof(uint16_t));
    int n = 0, worst = 0, off1 = 0;

    if (!omacvm_dc_fill(cs, OMACVM_DC_N, t)) {
        FAIL("%s: no table", name);
        free(t);
        return;
    }
    srand(1025);
    for (int i = 0; i < W * H; i++) {
        uint8_t *p = pic + 4 * i;
        if (i < 256) {
            p[0] = p[1] = p[2] = (uint8_t)i;
        } else if (i < 264) {
            int c = i - 256;
            p[0] = c & 1 ? 255 : 0; p[1] = c & 2 ? 255 : 0; p[2] = c & 4 ? 255 : 0;
        } else {
            p[0] = (uint8_t)(rand() & 255); p[1] = (uint8_t)(rand() & 255); p[2] = (uint8_t)(rand() & 255);
        }
        p[3] = (uint8_t)(i * 7);       /* the guest's alpha: must come through */
        memcpy(opaque + 4 * i, p, 3);
        opaque[4 * i + 3] = 255;
    }
    reference(cs, W * H, opaque, ref);
    GLuint tex = upload(t);
    draw(prog, vao, tex, W, H, pic, 1.0f, got);
    for (int i = 0; i < W * H; i++, n++) {
        for (int c = 0; c < 3; c++) {
            int d = abs((int)got[4 * i + c] - (int)ref[4 * i + c]);
            worst = d > worst ? d : worst;
            off1 += d == 1;
        }
        if (got[4 * i + 3] != pic[4 * i + 3]) {
            FAIL("%s: pixel %d alpha %d, the guest's was %d", name, i, got[4 * i + 3], pic[4 * i + 3]);
            break;
        }
    }
    /*
     * The CPU check the present uses must see what the GPU does (within a
     * code): a space it passes is at most OMACVM_DC_MAX_ERR off on the GPU too.
     */
    int check = omacvm_dc_error(cs, OMACVM_DC_N, t);
    if (check < 0 || abs(check - worst) > 1) {
        FAIL("%s: the check says %d codes, the shader is %d off", name, check, worst);
    }
    if (check <= OMACVM_DC_MAX_ERR && worst > OMACVM_DC_MAX_ERR) {
        FAIL("%s: passes the check but is %d codes off on the GPU", name, worst);
    }
    if (must_pass && (check > OMACVM_DC_MAX_ERR || worst > 1)) {
        FAIL("%s: %d codes off macOS's own conversion (check %d)", name, worst, check);
    }
    /* yflip 1 reads the rows as stored (QEMU's flip), -1 turns them over, as omacvm_bright_blit. */
    draw(prog, vao, tex, W, H, pic, -1.0f, flipped);
    for (int y = 0; y < H; y++) {
        if (memcmp(flipped + 4 * W * y, got + 4 * W * (H - 1 - y), 4 * W)) {
            FAIL("%s: the flip does not turn the rows over (row %d)", name, y);
            break;
        }
    }
    printf("test-display-color-shader: %s: %d pixels, at most %d code off macOS's conversion (%d channels 1 off), "
           "check %d: %s\n", name, n, worst, off1, check, check <= OMACVM_DC_MAX_ERR ? "converts" : "keeps the sRGB tag");
    glDeleteTextures(1, &tex);
    free(t);
}

int main(void)
{
    @autoreleasepool {
        CGLPixelFormatAttribute attrs[] = {
            kCGLPFAOpenGLProfile, (CGLPixelFormatAttribute)kCGLOGLPVersion_3_2_Core,
            kCGLPFARendererID, (CGLPixelFormatAttribute)kCGLRendererGenericFloatID,
            (CGLPixelFormatAttribute)0
        };
        CGLPixelFormatObj pf;
        GLint npf = 0;
        CGLContextObj ctx;

        if (CGLChoosePixelFormat(attrs, &pf, &npf) != kCGLNoError || !pf) {
            fprintf(stderr, "test-display-color-shader: no software renderer\n");
            return 1;
        }
        CGLCreateContext(pf, NULL, &ctx);
        CGLDestroyPixelFormat(pf);
        CGLSetCurrentContext(ctx);

        GLuint vs = shader(GL_VERTEX_SHADER, OMACVM_DC_VERT);
        GLuint fs = shader(GL_FRAGMENT_SHADER, OMACVM_DC_FRAG);
        GLuint prog = glCreateProgram();
        GLint ok = 0;
        glAttachShader(prog, vs);
        glAttachShader(prog, fs);
        glBindAttribLocation(prog, 0, "in_position");
        glLinkProgram(prog);
        glGetProgramiv(prog, GL_LINK_STATUS, &ok);
        if (!ok) {
            FAIL("does not link");
            return 1;
        }
        static const GLfloat quad[] = { -1, -1, 1, -1, -1, 1, 1, 1 };
        GLuint vao, vbo;
        glGenVertexArrays(1, &vao);
        glBindVertexArray(vao);
        glGenBuffers(1, &vbo);
        glBindBuffer(GL_ARRAY_BUFFER, vbo);
        glBufferData(GL_ARRAY_BUFFER, sizeof(quad), quad, GL_STATIC_DRAW);
        glVertexAttribPointer(0, 2, GL_FLOAT, GL_FALSE, 0, 0);
        glEnableVertexAttribArray(0);
        glBindVertexArray(0);

        CGColorSpaceRef p3 = CGColorSpaceCreateWithName(kCGColorSpaceDisplayP3);
        CGColorSpaceRef adobe = CGColorSpaceCreateWithName(kCGColorSpaceAdobeRGB1998);
        CGColorSpaceRef srgb = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
        CGColorSpaceRef panel = panel_space();
        space(prog, vao, "Display P3", p3, true);
        space(prog, vao, "Adobe RGB", adobe, false);
        space(prog, vao, "P3, gamma 2.2", panel, false);
        space(prog, vao, "sRGB", srgb, true);
        CGColorSpaceRef gray = CGColorSpaceCreateWithName(kCGColorSpaceGenericGrayGamma2_2);
        uint16_t one[4];
        if (omacvm_dc_fill(gray, 1, one)) {
            FAIL("a grey space must not give a table");
        }
        CGColorSpaceRelease(gray);
        CGColorSpaceRelease(p3);
        CGColorSpaceRelease(adobe);
        CGColorSpaceRelease(srgb);
        CGColorSpaceRelease(panel);
        CGLSetCurrentContext(NULL);
        CGLDestroyContext(ctx);
    }
    if (failures) {
        fprintf(stderr, "test-display-color-shader: %d failure(s)\n", failures);
        return 1;
    }
    printf("test-display-color-shader: ok\n");
    return 0;
}
