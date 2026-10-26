/*
 * The size of QEMU's SDL playback buffers for the Mac's output (#548):
 * audio/omacvm-sdl-out-size.h from qemu-sdl-audio-out-size-logic.patch.
 * Built and run by test-out-size.sh.
 */
#include <stdio.h>
#include "omacvm-sdl-out-size.h"

static int failures;

static void expect(bool ok, const char *what)
{
    printf("%s %s\n", ok ? "ok  " : "FAIL", what);
    failures += !ok;
}

int main(void)
{
    /* The own thread's ring: 6 x 256 frames; the main loop's: 8 x 512. */
    const unsigned own = 6 * 256, main_loop = 8 * 512;

    expect(omacvm_sdl_out_frames(256, 0, own) == 256, "no wish: the own thread keeps 256");
    expect(omacvm_sdl_out_frames(512, 0, main_loop) == 512, "no wish: the main loop keeps 512");
    expect(omacvm_sdl_out_frames(256, 512, own) == 512, "a Bluetooth output: 512 on the own thread");
    expect(omacvm_sdl_out_frames(512, 512, main_loop) == 512, "a Bluetooth output: the main loop already has 512");
    expect(omacvm_sdl_out_frames(256, 300, own) == 512, "a wish is rounded up to a power of two");
    expect(omacvm_sdl_out_frames(256, 4096, own) == 1024, "never more than the ring holds");
    expect(omacvm_sdl_out_frames(512, 9999, main_loop) == 2048, "never more than 2048");
    expect(omacvm_sdl_out_frames(256, 100, own) == 256, "a smaller wish never shrinks the voice's own size");
    expect(omacvm_sdl_out_frames(256, 512, 300) == 256, "a ring smaller than the wish keeps the voice's own size");

    /* The steps after a refused start (AudioQueueStart -66681). */
    expect(omacvm_sdl_out_next(256, own) == 512, "256 refused: 512, the main loop path's size");
    expect(omacvm_sdl_out_next(512, own) == 1024, "512 refused: 1024");
    expect(omacvm_sdl_out_next(1024, own) == 0, "1024 refused on a 1536-frame ring: no larger size");
    expect(omacvm_sdl_out_next(128, own) == 512, "a tiny size goes straight to 512");
    expect(omacvm_sdl_out_next(1024, main_loop) == 2048, "the main loop's ring takes 2048");
    expect(omacvm_sdl_out_next(2048, main_loop) == 0, "2048 refused: nothing larger");

    /* Which failures a larger size may get past. */
    expect(omacvm_sdl_out_start_refused("CoreAudio error (AudioQueueStart): -66681"), "-66681 from the queue start");
    expect(omacvm_sdl_out_start_refused("CoreAudio error (AudioQueueStart): 268435460"), "any queue start error");
    expect(!omacvm_sdl_out_start_refused("CoreAudio: requested device exists, but isn't alive."), "a dead device: no");
    expect(!omacvm_sdl_out_start_refused("CoreAudio error (AudioQueueNewOutput): -50"), "a queue it could not make: no");
    expect(!omacvm_sdl_out_start_refused("No such device."), "no device: no");
    expect(!omacvm_sdl_out_start_refused(NULL), "no error text: no");

    /* The launcher's size file. */
    expect(omacvm_sdl_out_parse_hint("512\n") == 512, "512 and a newline");
    expect(omacvm_sdl_out_parse_hint("0\n") == 0, "0: no wish");
    expect(omacvm_sdl_out_parse_hint("") == 0, "empty: no wish");
    expect(omacvm_sdl_out_parse_hint("-512") == 0, "negative: no wish");
    expect(omacvm_sdl_out_parse_hint("512 frames") == 0, "text after the number: no wish");
    expect(omacvm_sdl_out_parse_hint("4096\n") == 0, "above 2048: no wish");
    expect(omacvm_sdl_out_parse_hint("99999999999999999999") == 0, "too long: no wish");
    expect(omacvm_sdl_out_parse_hint(NULL) == 0, "no file: no wish");

    if (failures) {
        printf("%d failed\n", failures);
        return 1;
    }
    printf("all passed\n");
    return 0;
}
