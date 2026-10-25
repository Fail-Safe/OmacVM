/* The sync thread's naps between fence tests (virgl-darwin-fence-wait-proportional.patch). Plays
 * do_wait's schedule (fence_naps_wake before each nap) against fences that finish after
 * 0.05-20 ms and checks when each is seen, against the schedule before (50 us naps, doubled once a
 * wait is past 1 ms, at most 1 ms; the doubled naps saw a 1.85 ms fence at 2.6 ms):
 * - wake-ups on time, tests free: never later than before, and past the first millisecond at most
 *   an eighth of the fence's time late;
 * - wake-ups late and tests slow (20/5 and 60/30 us): every nap ends after the test before it
 *   (no test again without a nap), at most an eighth late plus those times, on average earlier;
 * - OMACVM_VIRGL_FENCE_SHORT_NAPS=0 (share off): exactly the schedule before;
 * - a long job still gets about 1000 wake-ups a second, 2-3 ms fences a few more than before.
 * No GL, no clock: the times are made up (ns stand in for mach ticks). */
#include "vrend/vrend_renderer.c"

#define CHECK(c) do { if (!(c)) { fprintf(stderr, "FAIL: %s (line %d)\n", #c, __LINE__); return 1; } } while (0)

/* When a fence done after DONE ns is seen: a test starts at t (seen if done by then) and takes
 * COST, a nap that should end at wake ends LATE after it. UINT64_MAX: a nap that does not end
 * after its test, or one longer than 1 ms. */
static uint64_t seen_at(uint64_t done, uint64_t late, uint64_t cost, bool share, unsigned *wakes)
{
   struct fence_naps s = { .nap_min = FENCE_NAP_NS, .lng = FENCE_LONG_NS, .nap_max = FENCE_NAP_MAX_NS,
                           .share = share };
   uint64_t t = 0;
   unsigned n = 0;
   fence_naps_start(&s, 0);
   while (t < done) {
      uint64_t now = t + cost;
      uint64_t wake = fence_naps_wake(&s, now);
      if (wake <= now || wake - now > FENCE_NAP_MAX_NS)
         return UINT64_MAX;
      t = wake + late;
      n++;
   }
   if (wakes)
      *wakes = n;
   return t;
}

/* The doubled naps alone (the code before this patch), same model. */
static uint64_t seen_doubled(uint64_t done, uint64_t late, uint64_t cost, unsigned *wakes)
{
   uint64_t t = 0, nap = FENCE_NAP_NS;
   unsigned n = 0;
   while (t < done) {
      uint64_t now = t + cost;
      t = now + nap + late;
      n++;
      if (now > FENCE_LONG_NS && nap < FENCE_NAP_MAX_NS)
         nap = MIN2(nap * 2, FENCE_NAP_MAX_NS);
   }
   if (wakes)
      *wakes = n;
   return t;
}

/* All fences of 0.05-20 ms (5 us steps) with these wake-up and test times. */
static int sweep(uint64_t late, uint64_t cost)
{
   uint64_t sum = 0, sum_before = 0, count = 0;
   for (uint64_t done = 50000; done <= 20000000; done += 5000) {
      uint64_t seen = seen_at(done, late, cost, true, NULL), before = seen_doubled(done, late, cost, NULL);
      if (seen == UINT64_MAX) {
         fprintf(stderr, "a fence of %llu us (late %llu us, test %llu us): a nap ends before its test\n",
                 (unsigned long long)(done / 1000), (unsigned long long)(late / 1000),
                 (unsigned long long)(cost / 1000));
         return 1;
      }
      CHECK(seen_at(done, late, cost, false, NULL) == before);
      if (!late && !cost && seen > before) {
         fprintf(stderr, "a fence of %llu us is seen at %llu us, the doubled naps saw it at %llu us\n",
                 (unsigned long long)(done / 1000), (unsigned long long)(seen / 1000),
                 (unsigned long long)(before / 1000));
         return 1;
      }
      uint64_t allowed = MAX2(done / FENCE_NAP_SHARE, FENCE_NAP_NS) + late + 2 * cost;
      if (done > FENCE_LONG_NS && seen - done > allowed) {
         fprintf(stderr, "a fence of %llu us (late %llu us, test %llu us) is seen %llu us late (allowed %llu)\n",
                 (unsigned long long)(done / 1000), (unsigned long long)(late / 1000),
                 (unsigned long long)(cost / 1000), (unsigned long long)((seen - done) / 1000),
                 (unsigned long long)(allowed / 1000));
         return 1;
      }
      if (done > FENCE_LONG_NS && done <= 8000000) {
         sum += seen - done;
         sum_before += before - done;
         count++;
      }
   }
   CHECK(sum < sum_before);
   fprintf(stderr, "fence naps, wake-ups %llu us late, tests %llu us: 1-8 ms fences seen %llu us late on "
           "average (doubled naps: %llu)\n", (unsigned long long)(late / 1000), (unsigned long long)(cost / 1000),
           (unsigned long long)(sum / count / 1000), (unsigned long long)(sum_before / count / 1000));
   return 0;
}

int main(void)
{
   CHECK(!sweep(0, 0));
   CHECK(!sweep(20000, 5000));
   CHECK(!sweep(60000, 30000));

   /* The case from QEMU's trace. */
   CHECK(seen_doubled(1850000, 0, 0, NULL) == 2600000);
   CHECK(seen_at(1850000, 0, 0, true, NULL) - 1850000 <= 1850000 / FENCE_NAP_SHARE);

   /* Wake-ups: a few more for 2-3 ms fences; a 100 ms job ~1000 a second, as before. */
   unsigned w2, w3, w100, b2, b3, b100, l100, lb100;
   seen_at(2000000, 0, 0, true, &w2); seen_doubled(2000000, 0, 0, &b2);
   seen_at(3000000, 0, 0, true, &w3); seen_doubled(3000000, 0, 0, &b3);
   seen_at(100000000, 0, 0, true, &w100); seen_doubled(100000000, 0, 0, &b100);
   seen_at(100000000, 60000, 30000, true, &l100); seen_doubled(100000000, 60000, 30000, &lb100);
   CHECK(w2 <= b2 + 8 && w3 <= b3 + 10);
   CHECK(w100 <= b100 + 20 && l100 <= lb100 + 20);
   fprintf(stderr, "PASS: fence naps: wake-ups 2 ms %u (%u), 3 ms %u (%u), 100 ms %u (%u), "
           "100 ms with late wake-ups %u (%u)\n", w2, b2, w3, b3, w100, b100, l100, lb100);
   return 0;
}
