// Unit tests for the address → memory pool lookup (nvn_pool_find.h), against the plain full scan it replaces.
// 2,000 pools that do not overlap, in random order, entries larger than the two range words (the stride is used); 200,000 random lookups
// (inside a pool, across its end, in a gap, beyond all pools) and every pool's first and last byte must give the full scan's answer; the same after pools are removed the way
// mtl_pool_del does (the last entry moves into the hole) and added; overlapping pools: every answer must contain the range; and the answer
// stays right when the cached last hit no longer contains the next range. Lookups that alternate between a few pools (a draw's vertex, index and
// uniform buffers) are answered by the address cache (hc), never with a pool that does not hold the range.
#include "../nvn/nvn_pool_find.h"
#include <stdio.h>

typedef struct { uintptr_t lo, hi; uintptr_t base; void *buf; uint64_t gpu; const void *key; int res; } ent;   // the layout of nvn_mtl.m's pool_ent
static ent P[4096]; static int n;
static int fail, total;
static void t(const char *name, int ok) { total++; fail += !ok; printf("%-80s %s\n", name, ok ? "✓" : "✗"); }
static int scan(uint64_t a, uint64_t len) { for (int i = 0; i < n; i++) if (a >= P[i].lo && a + len <= P[i].hi) return i; return -1; }
static uint64_t rnd(void) { static uint64_t s = 0x9e3779b97f4a7c15ull; s ^= s << 13; s ^= s >> 7; s ^= s << 17; return s; }
static int compare(pool_find_t *f, int count, uint64_t span) {   // random lookups: how many disagree with the full scan
    int bad = 0;
    for (int k = 0; k < count; k++) {
        uint64_t a = 0x10000000 + rnd() % span, len = 1 + rnd() % 0x3000;
        if (pool_find(f, P, sizeof P[0], n, a, len) != scan(a, len)) bad++;
    }
    return bad;
}
int main(void) {
    // Pools of 4–64 KB with gaps of 0–16 KB, then shuffled (pools are added in no particular address order)
    uintptr_t at = 0x10000000;
    for (n = 0; n < 2000; n++) { uintptr_t sz = 0x1000 * (4 + rnd() % 61); P[n] = (ent){at, at + sz}; at += sz + 0x1000 * (rnd() % 5); }
    for (int i = n - 1; i > 0; i--) { int j = (int)(rnd() % (uint64_t)(i + 1)); ent x = P[i]; P[i] = P[j]; P[j] = x; }
    uint64_t span = at - 0x10000000 + 0x100000;
    pool_find_t f = {0}; pool_find_reset(&f);
    t("2000 shuffled pools, 200000 random lookups agree with the full scan", compare(&f, 200000, span) == 0);
    t("  ... all answered by the last hit or the binary search (none by the full scan)", f.rescued == 0);
    int edges = 1; for (int i = 0; i < n; i++) edges &= pool_find(&f, P, sizeof P[0], n, P[i].lo, 1) == i && pool_find(&f, P, sizeof P[0], n, P[i].hi - 1, 1) == i;
    t("every pool's first and last byte find that pool, none by the full scan", edges && f.rescued == 0);
    int i0 = 7; t("a range inside one pool: that pool", pool_find(&f, P, sizeof P[0], n, P[i0].lo + 16, 32) == i0);
    t("the same pool again (last hit)", pool_find(&f, P, sizeof P[0], n, P[i0].lo + 64, 32) == i0 && f.last == i0);
    t("a range across that pool's end: -1 (no pool holds it whole)", pool_find(&f, P, sizeof P[0], n, P[i0].hi - 8, 16) == scan(P[i0].hi - 8, 16));
    t("below every pool: -1", pool_find(&f, P, sizeof P[0], n, 0x1000, 16) == -1);
    t("the next lookup after a miss in another pool is right (cached hit not reused)", pool_find(&f, P, sizeof P[0], n, P[i0 + 1].lo, 8) == i0 + 1);
    {   // four pools in turn (their cache slots differ), 1,000 rounds: after the first round the address cache answers, and every answer is the pool
        int pk[4], np = 0; for (int i = 0; i < n && np < 4; i++) { int dup = 0; for (int k = 0; k < np; k++) dup |= pool_find_hslot_(P[i].lo + 0x100) == pool_find_hslot_(P[pk[k]].lo + 0x100); if (!dup) pk[np++] = i; }
        int right = 1; uint64_t c0 = f.cached;
        for (int r = 0; r < 1000; r++) for (int k = 0; k < 4; k++) right &= pool_find(&f, P, sizeof P[0], n, P[pk[k]].lo + 0x100 + (uint64_t)(r % 8) * 0x10, 0x40) == pk[k];
        t("four pools looked up in turn: every answer right", right);
        t("  ... answered by the address cache after the first round (at least 3,990 of 4,000)", f.cached - c0 >= 3990);
        int ca = -1, cb = -1; for (int i = 0; i < n && cb < 0; i++) for (int j = i + 1; j < n; j++) if (pool_find_hslot_(P[i].lo + 0x100) == pool_find_hslot_(P[j].lo + 0x100)) { ca = i; cb = j; break; }
        right = ca >= 0; for (int r = 0; r < 100 && right; r++) right &= pool_find(&f, P, sizeof P[0], n, P[ca].lo + 0x100, 0x40) == ca && pool_find(&f, P, sizeof P[0], n, P[cb].lo + 0x100, 0x40) == cb;
        t("two pools sharing a cache slot, in turn: every answer right", right);
    }
    // Remove 500 pools as mtl_pool_del does (the last entry moves into the hole), add 300 new ones past the end; reset after each change
    for (int k = 0; k < 500; k++) { int i = (int)(rnd() % (uint64_t)n); P[i] = P[--n]; pool_find_reset(&f); }
    for (int k = 0; k < 300; k++) { uintptr_t sz = 0x1000 * (4 + rnd() % 61); P[n++] = (ent){at, at + sz}; at += sz + 0x2000; pool_find_reset(&f); }
    span = at - 0x10000000 + 0x100000;
    t("after 500 removals and 300 additions, 200000 lookups agree with the full scan", compare(&f, 200000, span) == 0 && f.rescued == 0);
    // Overlapping pools: [A, A+64K), [A+16K, A+32K) and [A+8K, A+128K); whatever comes back must hold the range
    n = 0; uintptr_t A = 0x40000000;
    P[n++] = (ent){A, A + 0x10000}; P[n++] = (ent){A + 0x4000, A + 0x8000}; P[n++] = (ent){A + 0x2000, A + 0x20000}; pool_find_reset(&f);
    int ok = 1;
    for (uint64_t a = A; a < A + 0x20000; a += 0x800) {
        int r = pool_find(&f, P, sizeof P[0], n, a, 0x800), s = scan(a, 0x800);
        if ((r < 0) != (s < 0) || (r >= 0 && !(a >= P[r].lo && a + 0x800 <= P[r].hi))) ok = 0;
    }
    t("overlapping pools: found exactly when the full scan finds one, and the pool holds the range", ok);
    printf("== %d checks, %d failed ==\n", total, fail);
    free(f.idx); free(f.slo);
    return fail != 0;
}
