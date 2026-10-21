#include "../nvn/nvn_dirty.h"
#include "../../host/dm.h"
#include <sys/mman.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

module_t g_mod[MAX_MOD];
int g_nmod;
module_t *module_of(const void *p) { (void)p; return NULL; }
void crash_install(void);

static int g_fail;
#define EXPECT(name, want, got) do { \
    long long want_ = (long long)(want), got_ = (long long)(got); \
    printf("%-52s expected %-4lld → got %-4lld %s\n", name, want_, got_, want_ == got_ ? "✓" : "✗"); \
    if (want_ != got_) g_fail++; \
} while (0)

static void *page_map(void) {
    void *p = mmap(NULL, 4096, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANON, -1, 0);
    if (p == MAP_FAILED) { perror("mmap"); exit(2); }
    return p;
}

int main(void) {
    crash_install();

    for (int i = 0; i < 65; i++) {
        void *p = page_map();
        nvn_dirty_add_range(p, 4096);
        nvn_dirty_remove_range(p);
        munmap(p, 4096);
    }

    void *reused = page_map();
    nvn_dirty_add_range(reused, 4096);
    nvn_dirty_protect(reused, 4096);
    uint64_t stamp = nvn_dirty_now();
    ((volatile uint8_t *)reused)[0] = 1;
    EXPECT("after 65 pool destructions in total, a write to a new pool is judged dirty", 1, nvn_dirty_since(reused, 4096, stamp));
    nvn_dirty_remove_range(reused);
    munmap(reused, 4096);

    void *live[300];
    for (int i = 0; i < 300; i++) {
        live[i] = page_map();
        nvn_dirty_add_range(live[i], 4096);
    }
    void *overflow = live[299];
    nvn_dirty_protect(overflow, 4096);
    stamp = nvn_dirty_now();
    ((volatile uint8_t *)overflow)[0] = 2;
    EXPECT("a pool beyond the limit of pools alive at once is conservatively judged dirty", 1, nvn_dirty_since(overflow, 4096, stamp));
    for (int i = 0; i < 300; i++) {
        nvn_dirty_remove_range(live[i]);
        munmap(live[i], 4096);
    }

    // More pools alive at once than the fixed 4,096 slots held (seedds/nxnative 7dde056, MIT: Breath of the Wild reaches 4,006 in its first shrine):
    // the table grows, and the last pool is tracked
    enum { NMANY = 5000 };
    void **many = malloc(NMANY * sizeof *many);
    for (int i = 0; i < NMANY; i++) { many[i] = page_map(); nvn_dirty_add_range(many[i], 4096); }
    void *last = many[NMANY - 1];
    EXPECT("5000 pools alive at once: the last one is tracked", 1, nvn_dirty_tracked(last, 4096));
    nvn_dirty_protect(last, 4096);
    stamp = nvn_dirty_now();
    EXPECT("the 5000th pool, protected and not written: clean", 0, nvn_dirty_since(last, 4096, stamp));
    ((volatile uint8_t *)last)[0] = 5;
    EXPECT("the 5000th pool written by the game: dirty", 1, nvn_dirty_since(last, 4096, stamp));
    for (int i = 0; i < NMANY; i++) { nvn_dirty_remove_range(many[i]); munmap(many[i], 4096); }
    free(many);

    // Adjacent pools sharing a host page (pools are 4 KB aligned, host pages 16 KB). From seedds/nxnative c2c0105 (MIT): there, the first page of
    // an ASTC texture pool was shared with a small preceding pool, judged untracked, and the textures were re-uploaded on every use
    size_t pg = (size_t)getpagesize();
    uint8_t *blk = mmap(NULL, 4 * pg, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANON, -1, 0);
    if (blk == MAP_FAILED) { perror("mmap"); exit(2); }
    uint8_t *pa = blk, *pb = blk + pg - 0x1000;               // pool A covers the start of page 0, pool B starts in the last 4 KB of page 0
    size_t na = pg - 0x1000, nb = 2 * pg, tex = pg + 0x800;   // the texture in B spans the shared page and the next one
    nvn_dirty_add_range(pa, na);
    nvn_dirty_add_range(pb, nb);
    EXPECT("shared page: a texture in the later pool is tracked", 1, nvn_dirty_tracked(pb, tex));
    nvn_dirty_protect(pb, tex);
    stamp = nvn_dirty_now();
    EXPECT("shared page: protected, nobody writes: clean", 0, nvn_dirty_since(pb, tex, stamp));
    pb[0x10] = 3;
    EXPECT("shared page: the game writes B's part: B's texture dirty", 1, nvn_dirty_since(pb, tex, stamp));
    nvn_dirty_protect(pb, tex);
    stamp = nvn_dirty_now();
    pa[0x10] = 4;   // same host page, A's part: the page is read-only, the fault must be claimed through B's range or it is taken for a crash
    EXPECT("shared page: the game writes A's part: B's texture dirty (conservative)", 1, nvn_dirty_since(pb, tex, stamp));
    nvn_dirty_protect(pb, tex);
    stamp = nvn_dirty_now();
    dm_guest_write_prepare(pa, 0x20); pa[0x20] = 5;   // the host writes into A (a file read, a GPU result): the shared page must release B's protection too
    EXPECT("shared page: host write into A: B's texture dirty", 1, nvn_dirty_since(pb, tex, stamp));
    nvn_dirty_remove_range(pb);
    EXPECT("shared page: A still tracked after B is destroyed (matched by pool start)", 1, nvn_dirty_tracked(pa, na));
    EXPECT("shared page: B no longer tracked after it is destroyed", 0, nvn_dirty_tracked(pb, tex));
    nvn_dirty_remove_range(pa);
    munmap(blk, 4 * pg);

    // A host write over 8 protected pages unprotects them in one mprotect (it took one per page), and each page counts as written
    {   uint8_t *m = mmap(NULL, 16 * pg, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANON, -1, 0); nvn_dirty_add_range(m, 16 * pg);
        nvn_dirty_protect(m + 4 * pg, 8 * pg); uint64_t s0 = nvn_dirty_now(), c0, c1, pg0, pg1, ns;
        nvn_dirty_mp_stats(&c0, &pg0, &ns);
        dm_guest_write_prepare(m + 4 * pg, 8 * pg); memset(m + 4 * pg, 7, 8 * pg);
        nvn_dirty_mp_stats(&c1, &pg1, &ns);
        EXPECT("host write over 8 protected pages: mprotect calls", 1, c1 - c0);
        EXPECT("... pages unprotected", 8, pg1 - pg0);
        int all = 1; for (int k = 4; k < 12; k++) all &= nvn_dirty_since(m + k * pg, pg, s0);
        EXPECT("... every page counts as written", 1, all);
        nvn_dirty_protect(m + 4 * pg, 2 * pg); nvn_dirty_protect(m + 8 * pg, 2 * pg);   // two runs with an unprotected gap
        nvn_dirty_mp_stats(&c0, &pg0, &ns); dm_guest_write_prepare(m + 4 * pg, 6 * pg); nvn_dirty_mp_stats(&c1, &pg1, &ns);
        EXPECT("two protected runs with a gap: two mprotect calls", 2, c1 - c0);
        EXPECT("... 4 pages unprotected", 4, pg1 - pg0);
        // the range a texture lives in is remembered: one walk, then none; a removed and reused slot is found again
        int hint = -1; uint64_t w0 = nvn_dirty_hint_walks(); uint64_t s1 = nvn_dirty_now();
        EXPECT("hint: clean texture", 0, nvn_dirty_state_hint(m + 2 * pg, pg, s1, &hint));
        EXPECT("... found by one walk", 1, nvn_dirty_hint_walks() - w0);
        EXPECT("hint: checked again, no walk", 0, nvn_dirty_state_hint(m + 2 * pg, pg, s1, &hint) + (int)(nvn_dirty_hint_walks() - w0 - 1));
        nvn_dirty_remove_range(m);
        uint8_t *m2 = mmap(NULL, 4 * pg, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANON, -1, 0); nvn_dirty_add_range(m2, 4 * pg);   // likely the freed slot
        EXPECT("hint after its pool is gone: not tracked", 2, nvn_dirty_state_hint(m + 2 * pg, pg, s1, &hint));
        EXPECT("... and the hint is cleared", -1, hint);
        nvn_dirty_remove_range(m2); munmap(m2, 4 * pg); munmap(m, 16 * pg); }
    return g_fail != 0;
}
