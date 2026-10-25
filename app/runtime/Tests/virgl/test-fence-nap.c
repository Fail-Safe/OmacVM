/* The sync thread's naps between fence tests (virgl-darwin-fence-wait-proportional.patch). Plays
 * do_wait's schedule (fence_naps_wake before each nap, fence_naps_woke after it) against fences that
 * finish after 0.05-20 ms and checks when each is seen: never later than the doubled naps alone
 * (the schedule before: 50 us, doubled once a wait is past 1 ms, at most 1 ms), and past the first
 * millisecond at most an eighth of the fence's time late (the doubled naps saw a 1.85 ms fence at
 * 2.6 ms). Also: a long job still gets about 1000 wake-ups a second, and a few more wake-ups for
 * 2-3 ms fences than before. No GL, no clock: the times are made up (ns stand in for mach ticks). */
#include "vrend/vrend_renderer.c"

#define CHECK(c) do { if (!(c)) { fprintf(stderr, "FAIL: %s (line %d)\n", #c, __LINE__); return 1; } } while (0)

/* When a fence done after DONE ns is seen, and after how many wake-ups. */
static uint64_t seen_at(uint64_t done, unsigned *wakes)
{
   struct fence_naps s = { .nap_min = FENCE_NAP_NS, .lng = FENCE_LONG_NS, .nap_max = FENCE_NAP_MAX_NS };
   uint64_t t = 0;
   unsigned n = 0;
   fence_naps_start(&s, 0);
   while (t < done) {
      uint64_t wake = fence_naps_wake(&s, t);
      if (wake <= t || wake - t > FENCE_NAP_MAX_NS)
         return UINT64_MAX;            /* no nap, or one longer than 1 ms */
      t = wake;
      n++;
      fence_naps_woke(&s, wake);
   }
   if (wakes)
      *wakes = n;
   return t;
}

/* The doubled naps alone (the code before this patch). */
static uint64_t seen_doubled(uint64_t done, unsigned *wakes)
{
   uint64_t t = 0, nap = FENCE_NAP_NS;
   unsigned n = 0;
   while (t < done) {
      uint64_t now = t;
      t += nap;
      n++;
      if (now > FENCE_LONG_NS && nap < FENCE_NAP_MAX_NS)
         nap = MIN2(nap * 2, FENCE_NAP_MAX_NS);
   }
   if (wakes)
      *wakes = n;
   return t;
}

int main(void)
{
   uint64_t worst = 0, worst_before = 0;
   for (uint64_t done = 50000; done <= 20000000; done += 5000) {
      uint64_t seen = seen_at(done, NULL), before = seen_doubled(done, NULL);
      CHECK(seen != UINT64_MAX);
      if (seen > before) {
         fprintf(stderr, "a fence of %llu us is seen at %llu us, the doubled naps saw it at %llu us\n",
                 (unsigned long long)(done / 1000), (unsigned long long)(seen / 1000),
                 (unsigned long long)(before / 1000));
         return 1;
      }
      uint64_t allowed = MAX2(done / FENCE_NAP_SHARE, FENCE_NAP_NS);
      if (done > FENCE_LONG_NS && seen - done > allowed) {
         fprintf(stderr, "a fence of %llu us is seen %llu us late (allowed %llu)\n",
                 (unsigned long long)(done / 1000), (unsigned long long)((seen - done) / 1000),
                 (unsigned long long)(allowed / 1000));
         return 1;
      }
      if (done >= 1000000 && done <= 3000000) {
         worst = MAX2(worst, seen - done);
         worst_before = MAX2(worst_before, before - done);
      }
   }
   /* The case from QEMU's trace. */
   CHECK(seen_doubled(1850000, NULL) == 2600000);
   CHECK(seen_at(1850000, NULL) - 1850000 <= 1850000 / FENCE_NAP_SHARE);

   /* Wake-ups: a few more for 2-3 ms fences; a 100 ms job ~1000 a second, as before. */
   unsigned w2, w3, w100, b2, b3, b100;
   seen_at(2000000, &w2); seen_doubled(2000000, &b2);
   seen_at(3000000, &w3); seen_doubled(3000000, &b3);
   seen_at(100000000, &w100); seen_doubled(100000000, &b100);
   CHECK(w2 <= b2 + 8 && w3 <= b3 + 10);
   CHECK(w100 <= b100 + 20);
   fprintf(stderr, "PASS: fence naps: 1-3 ms fences at most %llu us late (doubled naps: %llu); "
           "wake-ups 2 ms %u (%u), 3 ms %u (%u), 100 ms %u (%u)\n",
           (unsigned long long)(worst / 1000), (unsigned long long)(worst_before / 1000),
           w2, b2, w3, b3, w100, b100);
   return 0;
}
