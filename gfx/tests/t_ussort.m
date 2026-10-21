// Uniform snapshot preparation (nvn_mtl.m us_rng_sort / us_seen / us_copy_all): the radix sort orders the bindings by start as qsort does (random,
// clustered and repeated starts, high bits shared or not); a binding repeated through a submission is collected once; a snapshot above US_PAR_MIN bytes
// is copied in parts on worker threads and every copy holds its range's bytes. Negative control: DM_NVN_UBO_SNAPSHOT_PAR=0 fails "copied in parts".
#include "../nvn/nvn_mtl.m"
void *front_metal_layer(void) { return NULL; }
module_t *module_of(const void *p) { (void)p; return NULL; }
module_t g_mod[MAX_MOD]; int g_nmod;
void svc_thread_dump(void) {}
uint64_t now_ns(void) { return bp_now(); }
static int fail, count;
#define EXPECT(name, want, got) do { long long w=(want), g=(got); count++; printf("%-84s expected %-8lld → got %-8lld %s\n", name, w, g, w==g?"✓":"✗"); fail += w != g; } while (0)
typedef struct { uint8_t *p; size_t n; } chain;
static void emit(chain *c, unsigned op, const void *a, size_t n) { size_t z=(8+n+7)&~7ull; op_hdr h={op,(uint32_t)z}; memcpy(c->p+c->n,&h,8); if(n) memcpy(c->p+c->n+8,a,n); c->n+=z; }
static uint64_t rnd(void) { static uint64_t s = 0x2545F4914F6CDD1Dull; s ^= s << 13; s ^= s >> 7; s ^= s << 17; return s; }
static int sorted_same(us_rng *v, int n) {   // radix result equal to qsort's: same multiset, ascending starts
    us_rng *q = malloc((size_t)n * sizeof *q); memcpy(q, v, (size_t)n * sizeof *q);
    qsort(q, (size_t)n, sizeof *q, us_rng_cmp); us_rng_sort(v, n);
    int ok = 1; for (int i = 0; i < n && ok; i++) ok = v[i].lo == q[i].lo && (i == 0 || v[i - 1].lo <= v[i].lo);
    uint64_t hv = 0, hq = 0; for (int i = 0; i < n; i++) { hv += v[i].lo * 31 + v[i].hi; hq += q[i].lo * 31 + q[i].hi; }   // the same ranges went along
    free(q); return ok && hv == hq;
}
int main(void) { @autoreleasepool {
    setvbuf(stdout, NULL, _IONBF, 0); mtl_init();
    enum { N = 20000 }; static us_rng v[N];
    for (int i = 0; i < N; i++) { uint64_t lo = 0x900000000ull + (rnd() % 0x40000000ull & ~15ull); v[i] = (us_rng){lo, lo + 16 + rnd() % 4096}; }
    EXPECT("radix sort = qsort: 20,000 random starts in 1 GiB, high bits shared", 1, sorted_same(v, N));
    for (int i = 0; i < N; i++) { uint64_t lo = 0x900000000ull + (uint64_t)(rnd() % 64) * 0x100; v[i] = (us_rng){lo, lo + 256}; }
    EXPECT("radix sort = qsort: 20,000 starts out of 64 (repeats)", 1, sorted_same(v, N));
    for (int i = 0; i < N; i++) { uint64_t lo = rnd() & ~15ull; v[i] = (us_rng){lo, lo + 64}; }
    EXPECT("radix sort = qsort: 20,000 starts over the whole 64-bit range", 1, sorted_same(v, N));
    for (int i = 0; i < 100; i++) v[i] = (us_rng){0x123400 + (uint64_t)(100 - i) * 0x40, 0x123400 + (uint64_t)(100 - i) * 0x40 + 0x40};
    EXPECT("radix sort = qsort: 100 descending", 1, sorted_same(v, 100));
    // A submission binding 600 blocks of 1 KiB (600 KiB, above US_PAR_MIN), each bound 8 times: collected once each, copied in parts, bytes right
    uint8_t *mem; size_t msz = 4 << 20; if (posix_memalign((void **)&mem, getpagesize(), msz)) abort(); for (size_t i = 0; i < msz; i++) mem[i] = (uint8_t)(i * 13 + (i >> 11));
    mtl_pool_add(mem, msz);
    chain c = {0}; if (posix_memalign((void **)&c.p, getpagesize(), 1 << 20)) abort(); mtl_pool_add(c.p, 1 << 20);
    for (int r = 0; r < 8; r++) for (int b = 0; b < 600; b++) { p_bind_buf ub = {NVN_SHADER_STAGE_FRAGMENT, 3, (uint64_t)(uintptr_t)(mem + (size_t)b * 6144), 1024}; emit(&c, OP_BIND_UBO, &ub, sizeof ub); }
    emit(&c, OP_END, NULL, 0);
    mtl_sub_begin(); uint64_t hh = (uint64_t)(uintptr_t)c.p; uint64_t r0 = g_us_ranges;
    uint64_t par0 = g_us_par_n;
    mtl_sub_snapshot(&hh, 1);
    // A block whose four probes in the seen table find no place (it depends on the addresses: about one run in ten here) is collected again at each
    // of its 7 later bindings, and the merge drops the repeats: 600 plus 7 per such block, a few at most
    long long got = (long long)(g_us_ranges - r0);
    printf("    (%lld collected)\n", got);
    EXPECT("4,800 bindings of 600 blocks: 600 collected, plus 7 for each block the seen table had no place for (at most 8)", 1, got >= 600 && got <= 600 + 7 * 8 && (got - 600) % 7 == 0);
    EXPECT("600 copies (6 KiB apart: not merged)", 600, g_us_n);
    int bad = 0; for (int b = 0; b < 600; b++) { const us_ent *u = us_find((uint64_t)(uintptr_t)(mem + (size_t)b * 6144), 1024); bad += !u || memcmp(u->cpu, mem + (size_t)b * 6144, 1024); }
    EXPECT("every copy holds its block's bytes", 0, bad);
    EXPECT("copied in parts on worker threads [DM_NVN_UBO_SNAPSHOT_PAR=0 fails]", 1, (long long)(g_us_par_n - par0));
    mtl_wait(mtl_sub_commit(), 5000000000ull);
    printf("== %d checks, %d failed ==\n", count, fail); return fail != 0;
} }
