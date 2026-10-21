/*
 * test-extra-brightness-shader: extra brightness's shader (ui/omacvm-bright.h,
 * ADR 0050) on Apple's software GL renderer only (never a real GPU: STANDARDS
 * 14), core profile as QEMU's present context. Every 8-bit sRGB code and
 * every 10-bit PQ code (the guest's HDR) drawn into a half-float target
 * must read back as the C decode times the gain (1x, 2x, 1.37x), per
 * channel (no channel swapped, the BT.2020 matrix the right way round),
 * and the rows must come out the way QEMU's own blit and its flip variant
 * put them, in both kinds.
 *   cc -fobjc-arc -I<folder with omacvm-bright.h> test-extra-brightness-shader.m -framework OpenGL
 */
#import <Foundation/Foundation.h>
#define GL_SILENCE_DEPRECATION 1
#import <OpenGL/OpenGL.h>
#import <OpenGL/gl3.h>
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include "omacvm-bright.h"

static int failures;

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
        fprintf(stderr, "test-extra-brightness-shader: does not compile: %s\n", log);
        failures++;
    }
    return s;
}

/* Draw tex (w x h) into a w x h RGBA16F target with the program; read it back. */
static void draw(GLuint prog, GLuint vao, GLuint tex, int w, int h, float gain, float yflip, float pq,
                 float *out)
{
    GLuint dst, fbo;

    glGenTextures(1, &dst);
    glBindTexture(GL_TEXTURE_2D, dst);
    glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA16F, w, h, 0, GL_RGBA, GL_HALF_FLOAT, NULL);
    glGenFramebuffers(1, &fbo);
    glBindFramebuffer(GL_FRAMEBUFFER, fbo);
    glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_2D, dst, 0);
    if (glCheckFramebufferStatus(GL_FRAMEBUFFER) != GL_FRAMEBUFFER_COMPLETE) {
        fprintf(stderr, "test-extra-brightness-shader: no half-float target\n");
        failures++;
    }
    glViewport(0, 0, w, h);
    glActiveTexture(GL_TEXTURE0);
    glBindTexture(GL_TEXTURE_2D, tex);
    glUseProgram(prog);
    glUniform1i(glGetUniformLocation(prog, "image"), 0);
    glUniform1f(glGetUniformLocation(prog, "gain"), gain);
    glUniform1f(glGetUniformLocation(prog, "yflip"), yflip);
    glUniform1f(glGetUniformLocation(prog, "pq"), pq);
    glBindVertexArray(vao);
    glDrawArrays(GL_TRIANGLE_STRIP, 0, 4);
    glReadPixels(0, 0, w, h, GL_RGBA, GL_FLOAT, out);
    glBindFramebuffer(GL_FRAMEBUFFER, 0);
    glDeleteFramebuffers(1, &fbo);
    glDeleteTextures(1, &dst);
}

static GLuint texture(int w, int h, const uint8_t *rgba)
{
    GLuint t;

    glGenTextures(1, &t);
    glBindTexture(GL_TEXTURE_2D, t);
    glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA8, w, h, 0, GL_RGBA, GL_UNSIGNED_BYTE, rgba);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_NEAREST);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_NEAREST);
    return t;
}

/* A 10-bit texture (GL_RGB10_A2, the guest's 10-bit scanout) of w x h codes r, g, b. */
static GLuint texture10(int w, int h, const uint16_t *rgb)
{
    uint32_t *px = calloc((size_t)w * h, sizeof(*px));
    GLuint t;

    for (int i = 0; i < w * h; i++) {
        px[i] = rgb[i * 3] | (uint32_t)rgb[i * 3 + 1] << 10 | (uint32_t)rgb[i * 3 + 2] << 20 | 3u << 30;
    }
    glGenTextures(1, &t);
    glBindTexture(GL_TEXTURE_2D, t);
    glTexImage2D(GL_TEXTURE_2D, 0, GL_RGB10_A2, w, h, 0, GL_RGBA, GL_UNSIGNED_INT_2_10_10_10_REV, px);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_NEAREST);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_NEAREST);
    free(px);
    return t;
}

static bool near(double got, double want)
{
    return fabs(got - want) <= 2e-3 * fmax(1.0, want) + 1e-4;
}

int main(void)
{
    @autoreleasepool {
        CGLPixelFormatAttribute attrs[] = {
            kCGLPFARendererID, (CGLPixelFormatAttribute)kCGLRendererGenericFloatID,
            kCGLPFAOpenGLProfile, (CGLPixelFormatAttribute)kCGLOGLPVersion_3_2_Core,
            0
        };
        CGLPixelFormatObj pf;
        CGLContextObj ctx;
        GLint n;

        if (CGLChoosePixelFormat(attrs, &pf, &n) != kCGLNoError || !pf ||
            CGLCreateContext(pf, NULL, &ctx) != kCGLNoError) {
            fprintf(stderr, "test-extra-brightness-shader: no software GL context\n");
            return 1;
        }
        CGLDestroyPixelFormat(pf);
        CGLSetCurrentContext(ctx);

        GLuint vs = shader(GL_VERTEX_SHADER, OMACVM_BRIGHT_VERT);
        GLuint fs = shader(GL_FRAGMENT_SHADER, OMACVM_BRIGHT_FRAG);
        GLuint prog = glCreateProgram();
        GLint ok = 0;
        glAttachShader(prog, vs);
        glAttachShader(prog, fs);
        glBindAttribLocation(prog, 0, "in_position");
        glLinkProgram(prog);
        glGetProgramiv(prog, GL_LINK_STATUS, &ok);
        if (!ok || failures) {
            fprintf(stderr, "test-extra-brightness-shader: the program does not link\n");
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

        /* Every code: red rises, green falls, blue at half, alpha kept. */
        uint8_t ramp[256 * 4];
        for (int i = 0; i < 256; i++) {
            ramp[i * 4] = i;
            ramp[i * 4 + 1] = 255 - i;
            ramp[i * 4 + 2] = i / 2;
            ramp[i * 4 + 3] = 255;
        }
        GLuint t = texture(256, 1, ramp);
        static float out[256 * 4];
        const float gains[] = { 1.0f, 2.0f, 1.37f };
        for (int k = 0; k < 3; k++) {
            float g = gains[k];
            int bad = 0;
            draw(prog, vao, t, 256, 1, g, -1, 0, out);
            for (int i = 0; i < 256 && bad < 3; i++) {
                for (int c = 0; c < 3; c++) {
                    double want = omacvm_bright_linear(ramp[i * 4 + c] / 255.0) * g;
                    if (!near(out[i * 4 + c], want)) {
                        fprintf(stderr, "test-extra-brightness-shader: code %d channel %d at %.2fx: %.5f, not %.5f\n",
                                ramp[i * 4 + c], c, g, out[i * 4 + c], want);
                        bad++;
                        failures++;
                    }
                }
            }
        }
        /* White at 2x is 2.0, 50 % grey is 0.214 of it: what a capture of the window reads. */
        draw(prog, vao, t, 256, 1, 2.0f, -1, 0, out);
        if (!near(out[255 * 4], 2.0) || !near(out[128 * 4], 2.0 * omacvm_bright_linear(128 / 255.0))) {
            fprintf(stderr, "test-extra-brightness-shader: white %.4f, grey %.4f at 2x\n", out[255 * 4], out[128 * 4]);
            failures++;
        }
        /* Boot frames in linear surfaces (the switch just turned off, the hold-off): 8-bit white at 1x is 1.00. */
        draw(prog, vao, t, 256, 1, 1.0f, -1, 0, out);
        if (!near(out[255 * 4], 1.0)) {
            fprintf(stderr, "test-extra-brightness-shader: 8-bit white at 1x: %.4f\n", out[255 * 4]);
            failures++;
        }

        /* PQ (it wins over HDR): every 10-bit code, red rising, green falling, blue at half. */
        static uint16_t pq10[1024 * 3];
        for (int i = 0; i < 1024; i++) {
            pq10[i * 3] = i;
            pq10[i * 3 + 1] = 1023 - i;
            pq10[i * 3 + 2] = i / 2;
        }
        GLuint tp = texture10(1024, 1, pq10);
        static float outp[1024 * 4];
        for (int k = 0; k < 3; k++) {
            float g = gains[k];
            int bad = 0;
            draw(prog, vao, tp, 1024, 1, g, -1, 1, outp);
            for (int i = 0; i < 1024 && bad < 3; i++) {
                double e[3] = { pq10[i * 3] / 1023.0, pq10[i * 3 + 1] / 1023.0, pq10[i * 3 + 2] / 1023.0 };
                double lin[3];
                omacvm_bright_pq_linear(e, lin);
                for (int c = 0; c < 3; c++) {
                    if (!near(outp[i * 4 + c], lin[c] * g)) {
                        fprintf(stderr, "test-extra-brightness-shader: PQ code %d channel %d at %.2fx: %.5f, not %.5f\n",
                                pq10[i * 3 + c], c, g, outp[i * 4 + c], lin[c] * g);
                        bad++;
                        failures++;
                    }
                }
            }
        }
        /* PQ white (Hyprland's code 594) and a 1000-nit highlight: both at g, at 2x and at 1x (the hold-off). */
        const uint16_t whites[] = { 594, 594, 594,   1023, 1023, 1023,   0, 0, 0 };
        GLuint tw = texture10(3, 1, whites);
        float w3[3 * 4];
        const float wg[] = { 2.0f, 1.0f };
        for (int k = 0; k < 2; k++) {
            draw(prog, vao, tw, 3, 1, wg[k], -1, 1, w3);
            for (int c = 0; c < 3; c++) {
                if (!near(w3[c], wg[k]) || !near(w3[4 + c], wg[k]) || fabs(w3[8 + c]) > 1e-4) {
                    fprintf(stderr, "test-extra-brightness-shader: PQ white %.4f, highlight %.4f, black %.4f at %.0fx\n",
                            w3[c], w3[4 + c], w3[8 + c], wg[k]);
                    failures++;
                    break;
                }
            }
        }
        /* sRGB's red, green and blue as a guest puts them in a PQ frame (203 nits, BT.2020): back to themselves at 2x. */
        static const double to2020[3][3] = {
            { 0.6274040, 0.3292820, 0.0433136 },
            { 0.0690970, 0.9195400, 0.0113612 },
            { 0.0163916, 0.0880132, 0.8955950 },
        };
        uint16_t prim[3 * 3];
        for (int p = 0; p < 3; p++) {
            for (int i = 0; i < 3; i++) {
                double nits = to2020[i][p] * OMACVM_BRIGHT_SDR_NITS;
                double y = pow(nits / 10000.0, OMACVM_BRIGHT_PQ_M1);
                double enc = pow((OMACVM_BRIGHT_PQ_C1 + OMACVM_BRIGHT_PQ_C2 * y) / (1 + OMACVM_BRIGHT_PQ_C3 * y),
                                 OMACVM_BRIGHT_PQ_M2);
                prim[p * 3 + i] = (uint16_t)lround(enc * 1023);
            }
        }
        GLuint tq = texture10(3, 1, prim);
        draw(prog, vao, tq, 3, 1, 2.0f, -1, 1, w3);
        for (int p = 0; p < 3; p++) {
            for (int c = 0; c < 3; c++) {
                /* 10-bit codes: within 0.03 of 2x the primary. */
                if (fabs(w3[p * 4 + c] - (p == c ? 2.0 : 0.0)) > 0.03) {
                    fprintf(stderr, "test-extra-brightness-shader: primary %d channel %d through PQ at 2x: %.4f\n",
                            p, c, w3[p * 4 + c]);
                    failures++;
                }
            }
        }

        /* Rows: yflip -1 is QEMU's texture_blit (texture row 0 lands in the target's last row), 1 its flip. */
        const uint8_t rows[] = { 255, 0, 0, 255,   0, 0, 255, 255 };
        GLuint t2 = texture(1, 2, rows);
        float two[2 * 4];
        /* The same with PQ frames: a red row over a blue one, 10-bit. */
        const uint16_t rows10[] = { 1023, 0, 0,   0, 0, 1023 };
        GLuint t3 = texture10(1, 2, rows10);
        for (int kind = 0; kind < 2; kind++) {
            GLuint tr = kind ? t3 : t2;
            const char *name = kind ? "PQ" : "sRGB";
            draw(prog, vao, tr, 1, 2, 1.0f, -1, kind, two);
            if (!(two[4] > 0.9 && two[2] > 0.9)) {
                fprintf(stderr, "test-extra-brightness-shader: %s: yflip -1 does not turn the rows over as QEMU's blit\n", name);
                failures++;
            }
            draw(prog, vao, tr, 1, 2, 1.0f, 1, kind, two);
            if (!(two[0] > 0.9 && two[6] > 0.9)) {
                fprintf(stderr, "test-extra-brightness-shader: %s: yflip 1 does not keep the rows as QEMU's flip blit\n", name);
                failures++;
            }
        }
        GLenum e = glGetError();
        if (e != GL_NO_ERROR) {
            fprintf(stderr, "test-extra-brightness-shader: GL error 0x%x\n", e);
            failures++;
        }
        CGLSetCurrentContext(NULL);
        CGLDestroyContext(ctx);
        if (failures) {
            return 1;
        }
        printf("test-extra-brightness-shader: 256 sRGB and 1024 PQ codes x 3 channels at 1x, 2x and 1.37x match the C decode; "
               "PQ white and highlights at g, primaries kept; rows as QEMU's blit\n");
    }
    return 0;
}
