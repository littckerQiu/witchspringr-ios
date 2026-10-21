// Released texture copies (nvn_mtl.m tex_snap_retire / tex_snap_reap): each is freed at its due submission, and a reap walks only the copies due.
// Before, a reap walked every released copy each submission (fin_drain 0.7 ms with 18,000 copies waiting in Tears of the Kingdom). The dues only
// grow (submission index + SNAP_KEEP), so the list is kept in due order and a reap stops at the first copy not due.
#include "../nvn/nvn_mtl.m"
void *front_metal_layer(void) { return NULL; }
module_t *module_of(const void *p) { (void)p; return NULL; }
module_t g_mod[MAX_MOD]; int g_nmod;
void svc_thread_dump(void) {}
uint64_t now_ns(void) { return bp_now(); }
static int fail, count;
#define EXPECT(name, want, got) do { long long w=(want), g=(got); count++; printf("%-78s expected %-6lld → got %-6lld %s\n", name, w, g, w==g?"✓":"✗"); fail += w != g; } while (0)
static void snap(uint64_t serial) { tex_t t = {.serial = serial}; mtl_tex_snap(&t); }
int main(void) {
    setvbuf(stdout, NULL, _IONBF, 0);
    uint64_t n0 = mtl_tex_snap_count();
    snap(101); snap(102); snap(103);
    EXPECT("three copies made", 3, (long long)(mtl_tex_snap_count() - n0));
    tex_snap_retire(101, 10); tex_snap_retire(102, 20); tex_snap_retire(103, 30);
    tex_snap_reap(9);  EXPECT("none due at 9", 3, (long long)(mtl_tex_snap_count() - n0));
    tex_snap_reap(15); EXPECT("the one due at 10 freed at 15", 2, (long long)(mtl_tex_snap_count() - n0));
    tex_snap_reap(30); EXPECT("the ones due at 20 and 30 freed at 30 (due <= now)", 0, (long long)(mtl_tex_snap_count() - n0));
    // The list emptied: a copy released after that is still found and freed (the tail goes back to the head)
    snap(104); tex_snap_retire(104, 40);
    tex_snap_reap(39); EXPECT("released after the list emptied: kept until due", 1, (long long)(mtl_tex_snap_count() - n0));
    tex_snap_reap(40); EXPECT("... and freed when due", 0, (long long)(mtl_tex_snap_count() - n0));
    tex_snap_retire(999, 50); EXPECT("releasing a serial without a copy changes nothing", 0, (long long)(mtl_tex_snap_count() - n0));
    // A copy still in use is not freed by any reap
    snap(105); tex_snap_reap(1000000); EXPECT("a copy not released stays", 1, (long long)(mtl_tex_snap_count() - n0));
    // Cost: 20,000 released copies not due; a reap now looks at the first one only
    enum { N = 20000, R = 2000 };
    for (uint64_t s = 0; s < N; s++) { snap(200000 + s); tex_snap_retire(200000 + s, 2000000 + s); }
    uint64_t t0 = bp_now(); for (int i = 0; i < R; i++) tex_snap_reap(1000000 + i); uint64_t ns = (bp_now() - t0) / R;
    printf("reap with %d copies waiting: %llu ns each\n", N, (unsigned long long)ns);
    EXPECT("a reap with 20,000 copies not due takes under 1 µs (a walk of all of them takes tens)", 1, ns < 1000);
    EXPECT("... and frees none of them", N + 1, (long long)(mtl_tex_snap_count() - n0));
    tex_snap_reap(2000000 + N / 2 - 1); EXPECT("half due: half freed", N / 2 + 1, (long long)(mtl_tex_snap_count() - n0));
    tex_snap_reap(UINT64_MAX); EXPECT("all due: all freed", 1, (long long)(mtl_tex_snap_count() - n0));
    printf("== %d checks, %d failed ==\n", count, fail); return fail != 0;
}
