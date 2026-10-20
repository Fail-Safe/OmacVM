/*
 * test-extra-brightness-shader: extra brightness's shader (ui/omacvm-bright.h,
 * ADR 0050) on Apple's software GL renderer only (never a real GPU: STANDARDS
 * 14), core profile as QEMU's present context. Every 8-bit sRGB code drawn
 * into a half-float target must read back as the C decode times the gain
 * (1x and 2x), per channel (no channel swapped), and the rows must come out
 * the way QEMU's own blit and its flip variant put them.
 *   cc -fobjc-arc -I<folder with omacvm-bright.h> test-extra-brightness-shader.m -framework OpenGL
 */
#import <Foundation/Foundation.h>
#define GL_SILENCE_DEPRECATION 1
#import <OpenGL/OpenGL.h>
#import <OpenGL/gl3.h>
#include <math.h>
#include <stdio.h>
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
static void draw(GLuint prog, GLuint vao, GLuint tex, int w, int h, float gain, float yflip, float *out)
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
            draw(prog, vao, t, 256, 1, g, -1, out);
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
        draw(prog, vao, t, 256, 1, 2.0f, -1, out);
        if (!near(out[255 * 4], 2.0) || !near(out[128 * 4], 2.0 * omacvm_bright_linear(128 / 255.0))) {
            fprintf(stderr, "test-extra-brightness-shader: white %.4f, grey %.4f at 2x\n", out[255 * 4], out[128 * 4]);
            failures++;
        }

        /* Rows: yflip -1 is QEMU's texture_blit (texture row 0 lands in the target's last row), 1 its flip. */
        const uint8_t rows[] = { 255, 0, 0, 255,   0, 0, 255, 255 };
        GLuint t2 = texture(1, 2, rows);
        float two[2 * 4];
        draw(prog, vao, t2, 1, 2, 1.0f, -1, two);
        if (!(two[4] > 0.9 && two[2] > 0.9)) {
            fprintf(stderr, "test-extra-brightness-shader: yflip -1 does not turn the rows over as QEMU's blit\n");
            failures++;
        }
        draw(prog, vao, t2, 1, 2, 1.0f, 1, two);
        if (!(two[0] > 0.9 && two[6] > 0.9)) {
            fprintf(stderr, "test-extra-brightness-shader: yflip 1 does not keep the rows as QEMU's flip blit\n");
            failures++;
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
        printf("test-extra-brightness-shader: 256 codes x 3 channels at 1x, 2x and 1.37x match the C decode; rows as QEMU's blit\n");
    }
    return 0;
}
