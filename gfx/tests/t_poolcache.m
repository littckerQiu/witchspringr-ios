// Replay lookups without the lock: the second mtl_addr / mtl_gpu_addr of a pool on a thread is a cache hit with the same answer; removing the pool
// (or adding one) invalidates the cache, so an address in a removed pool is not found any more (a cache kept across the removal would hand out the
// gone buffer); another thread's lookups have their own cache. A residency add of an object already in the set, or a removal of one that is not,
// changes nothing.
#include "../nvn/nvn_mtl.m"
void *front_metal_layer(void) { return NULL; }
module_t *module_of(const void *p) { (void)p; return NULL; }
module_t g_mod[MAX_MOD]; int g_nmod;
void svc_thread_dump(void) {}
uint64_t now_ns(void) { return bp_now(); }
static int n, fail;
#define EXPECT(name, want, got) do { long long w_ = (long long)(want), g_ = (long long)(got); n++; printf("%-78s expected %-6lld → got %-6lld %s\n", name, w_, g_, w_ == g_ ? "✓" : "✗"); fail += w_ != g_; } while (0)
static uint8_t *g_mem; static uint64_t g_other_hits; static int g_other_ok;
static void *other(void *a) { (void)a; void *b; uint64_t o; uint64_t h0 = g_pc_hits; g_other_ok = mtl_addr((uint64_t)(uintptr_t)g_mem + 64, 16, &b, &o); g_other_hits = g_pc_hits - h0; return NULL; }
int main(void) { @autoreleasepool {
    mtl_init();
    size_t sz = 1 << 20; if (posix_memalign((void **)&g_mem, getpagesize(), sz)) abort(); mtl_pool_add(g_mem, sz);
    uint64_t a = (uint64_t)(uintptr_t)g_mem + 0x1000; void *b1, *b2; uint64_t o1, o2, g1, g2;
    uint64_t h0 = g_pc_hits;
    EXPECT("first lookup: found", 1, mtl_gpu_addr(a, 256, &b1, &o1, &g1));
    EXPECT("... through the lock (no cache hit)", 0, g_pc_hits - h0);
    EXPECT("second lookup: found", 1, mtl_gpu_addr(a + 512, 256, &b2, &o2, &g2));
    EXPECT("... a cache hit", 1, g_pc_hits - h0);
    EXPECT("... same buffer, offsets and GPU address as the lock would give", 1, b1 == b2 && o2 == o1 + 512 && g2 == g1 + 512);
    EXPECT("mtl_addr on the same thread: a cache hit too", 1, mtl_addr(a, 16, &b2, &o2) && g_pc_hits - h0 == 2);
    pthread_t t; pthread_create(&t, NULL, other, NULL); pthread_join(t, NULL);
    EXPECT("another thread: found, through its own (empty) cache", 1, g_other_ok && g_other_hits == 0);
    mtl_pool_del(g_mem);
    EXPECT("after the pool is removed: not found (the cache is invalid)", 0, mtl_addr(a, 16, &b2, &o2));
    // residency: a second add of the same object and a removal of an object not in the set change nothing
    id<MTLBuffer> rb = [g_dev newBufferWithLength:4096 options:MTLResourceStorageModeShared];
    uint64_t n0 = g_res_noop; res_add(rb); res_commit(); g_res_dirty = 0;
    res_add(rb); EXPECT("residency: adding an object already in the set changes nothing", 1, g_res_noop - n0 == 1 && !g_res_dirty);
    res_remove(rb); res_remove(rb); EXPECT("residency: removing it twice, the second changes nothing", 2, g_res_noop - n0);
    printf("t_poolcache: %d checks, %d failed\n", n, fail); return fail != 0;
} }
