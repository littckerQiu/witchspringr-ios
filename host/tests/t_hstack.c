// Host calls and svcs on a per-thread host stack (hstack.S, hstack.c, entry.S dm_gate / dm_thread_enter, hle_thread.c GetThreadContext3), after
// MacNativeGames' hle_stack (MIT). A guest thread made with svc 0x08 runs on a 16 KiB guest stack with an inaccessible page below it and calls the
// host the ways guest code does (t_hstack_guest.S):
//   1  a host function through its wrapper (dm_hwrap): x0..x7 / d0..d7 arrive, it runs on the thread's host stack and can use 64 KiB there,
//      DM_GUEST_RA finds the guest call site, a frame pointer walk reaches the guest frame (and needs its one step between the stacks), x19..x28 /
//      d8..d15 are kept;
//   2  an svc through dm_gate: on the host stack, every register kept but the results, x16 / x17 written back;
//   3  a host function that calls guest code that calls the host again: the inner call stays on the host stack, the slot comes back after;
//   4  an unimplemented import's stub: on the host stack, with its stub number and the arguments;
//   5  GetThreadContext3 of the thread paused in a host call (a condition variable wait), in an svc, and in an svc made by guest code a host
//      function called: the guest's sp, x19..x28, fp and lr at the outer entry; always (also with DM_HSTACK=0) the reported sp on the guest stack
//      at or below the sp of the call, and every guest value in the registers or on the guest stack above that sp: what the IL2CPP GC scans;
//   6  the least free guest stack at svc entries, and the line below 1 KiB;
//   7  the libc functions hle_table.c calls direct, each run on a painted stack with ordinary and slow-path arguments: at most 1 KiB each, and
//      the list measured is the table's;
//   8  the cost of a wrapped call and of a gate round trip (printed).
// Negative controls (host/tests/Makefile): `DM_HSTACK=0 t_hstack deep` faults on the page below the guest stack (1 on the guest stack);
// t_hstack_old (-DDM_TEST_HSTACK_OLD_CONTEXT: the context as before) fails 5. `DM_HSTACK=0 t_hstack` runs 1-5 without the 64 KiB, the exact
// entry checks and 6 (the old path, kept).
#include "../game.h"
#include "../dm.h"
#include <mach-o/getsect.h>
#include <mach-o/ldsyms.h>
#include <mach/mach_time.h>
#include <math.h>
#include <signal.h>
#include <sys/mman.h>
#include <time.h>
#include <unistd.h>
#if __has_feature(ptrauth_calls)
#include <ptrauth.h>
#define RAW_FN(f) ((uint64_t)ptrauth_strip((void *)(f), ptrauth_key_function_pointer))
#else
#define RAW_FN(f) ((uint64_t)(f))
#endif

typedef struct { uint64_t fn, sp, ret, kept, ra, fp, x1, x2, x3, lr; } tg_t;   // t_hstack_guest.S
void tg_call(tg_t *t); void tg_svc(tg_t *t); void tg_svc_at(tg_t *t, uint64_t sp); void tg_entry(uint64_t arg);
uint64_t tg_on_stack(uint64_t (*fn)(void *), void *arg, uint64_t top); void tg_gate_loop(uint64_t n);
extern char tg_code_begin[], tg_code_end[];
extern uint64_t unimpl_stubs[];
extern uint64_t dm_hstk_off;
int svc_thread(int num, uint64_t *regs);
uint32_t svc_thread_main_init(void);
void thr_svc_enter(uint64_t *regs, uint64_t pc); void thr_svc_exit(void);
int thr_stack_info(uint32_t h, uint64_t *top, uint64_t *low, uint64_t *bot, int *said);

static int fails, checks;
#define CHECK(c, ...) do { checks++; if (c) printf("ok   "); else { fails++; printf("FAIL "); } printf(__VA_ARGS__); printf("\n"); } while (0)

// ---------- What hle_thread.c / thread.c / entry.S need ----------
struct dm_flags g_flag;
const dm_game_profile dm_game = { .id = "test" };   // virtual cores off
uint64_t g_t0_ns;
pthread_key_t g_key18, g_keytls, g_keytlr, g_keygate;
void *guest_sym(const char *name) { (void)name; return NULL; }
static module_t g_fake = { .name = "guest" };
module_t *module_of(const void *p) { return (const char *)p >= tg_code_begin && (const char *)p < tg_code_end ? &g_fake : NULL; }
void dm_prof_add(int id, uint64_t ns, uint64_t bytes) { (void)id; (void)ns; (void)bytes; }
uint64_t now_ns(void) { static mach_timebase_info_data_t tb; if (!tb.denom) mach_timebase_info(&tb); return mach_absolute_time() * tb.numer / tb.denom; }
uint64_t guest_ns(void) { return now_ns(); }
int dm_detclock_enabled(void) { return 0; }

enum { GSTACK = 16 << 10, GUARD = 16 << 10 };
static uint8_t *g_glo;   // the guest stack's lowest byte; the page below is inaccessible
uint64_t dm_mapping_of(uint64_t a, uint64_t *size) {   // the guest stack is "mapped" as the SDK maps thread stacks (hle_svc.c)
    if (a >= (uint64_t)g_glo && a < (uint64_t)g_glo + GSTACK) { *size = GSTACK; return (uint64_t)g_glo; }
    *size = 0; return 0;
}
static void fault(int sig, siginfo_t *si, void *uc) {
    (void)uc; uintptr_t a = (uintptr_t)si->si_addr;
    const char *m = a >= (uintptr_t)g_glo - GUARD && a < (uintptr_t)g_glo ? "FAIL host code touched the page below the guest stack\n" : "FAIL fault outside the guest stack's guard page\n";
    (void)sig; write(1, m, strlen(m)); _exit(1);
}
void crash_thread_init(void) { stack_t ss = {.ss_sp = malloc(65536), .ss_size = 65536}; sigaltstack(&ss, 0); }

// ---------- Helpers ----------
static uintptr_t cur_sp(void) { uintptr_t sp; __asm__ volatile("mov %0, sp" : "=r"(sp)); return sp; }
static int on_guest(uintptr_t a) { return a >= (uintptr_t)g_glo && a < (uintptr_t)g_glo + GSTACK; }
static int on_host(uintptr_t a) {
    pthread_t s = pthread_self(); uintptr_t hi = (uintptr_t)pthread_get_stackaddr_np(s), lo = hi - pthread_get_stacksize_np(s);
    return a > lo && a <= hi;
}
static uint64_t slot(void) { if (!dm_hstk_off) return 0; uint64_t tp; __asm__ volatile("mrs %0, tpidrro_el0" : "=r"(tp)); return *(volatile uint64_t *)(tp + dm_hstk_off); }
static __attribute__((noinline)) int deep(void) { volatile char b[64 << 10]; for (size_t i = 0; i < sizeof b; i += 256) b[i] = (char)(i >> 8); return b[512] == 2; }
static pthread_mutex_t g_m = PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t g_c = PTHREAD_COND_INITIALIZER;
static int g_nblock, g_nrel;   // blocked waits so far / released so far (guarded by g_m)
static void block_here(void) {   // a guest-side wait inside host code, released by the driver
    pthread_mutex_lock(&g_m); int k = ++g_nblock; pthread_cond_broadcast(&g_c);
    while (g_nrel < k) pthread_cond_wait(&g_c, &g_m);
    pthread_mutex_unlock(&g_m);
}
static void wait_blocked(int k) { pthread_mutex_lock(&g_m); while (g_nblock < k) pthread_cond_wait(&g_c, &g_m); pthread_mutex_unlock(&g_m); }
static void release(int k) { pthread_mutex_lock(&g_m); g_nrel = k; pthread_cond_broadcast(&g_c); pthread_mutex_unlock(&g_m); }
// Callee-saved registers overwritten here: the guest's values are then only where this function saved them (its frame)
#define CLOBBER_CALLEE() __asm__ volatile("mov x19, #0\n mov x20, #0\n mov x21, #0\n mov x22, #0\n mov x23, #0\n mov x24, #0\n mov x25, #0\n mov x26, #0\n mov x27, #0\n mov x28, #0" \
                                          ::: "x19", "x20", "x21", "x22", "x23", "x24", "x25", "x26", "x27", "x28")
static uint64_t G(int r) { return 0xa5a5000000000000ull | (uint64_t)(r / 10 * 16 + r % 10) * 0x101; }   // the value t_hstack_guest.S puts in xr

static int g_on, g_deep;   // the switch is on; use 64 KiB in the host functions
static tg_t *g_tg;                  // the call in progress

// ---------- Host functions the guest calls ----------
static uint64_t g_hsp;
static uint64_t h_args(uint64_t a0, uint64_t a1, uint64_t a2, uint64_t a3, uint64_t a4, uint64_t a5, uint64_t a6, uint64_t a7,
                       double d0, double d1, double d2, double d3, double d4, double d5, double d6, double d7) {
    uint64_t bad = 0, ra = DM_GUEST_RA();
    if (a0 != 1 || a1 != 2 || a2 != 3 || a3 != 4 || a4 != 5 || a5 != 6 || a6 != 7 || a7 != 8) bad |= 1;
    if (d0 != 1.5 || d1 != 2.5 || d2 != 3.5 || d3 != 4.5 || d4 != 5.5 || d5 != 6.5 || d6 != 7.5 || d7 != 8.5) bad |= 2;
    uintptr_t sp = g_hsp = cur_sp();
    if (g_on ? !on_host(sp) || on_guest(sp) : !on_guest(sp)) bad |= 4;
    if (g_deep && !deep()) bad |= 8;
    if (ra != g_tg->ra) bad |= 16;
    // The walk reaches the call site (in the record) and the guest frames beyond it (tg_call's own return address, in its frame record)
    uint64_t beyond = ((const uint64_t *)g_tg->fp)[1]; int site = 0, found = 0, strict = 0, jumps = 0;
    for (uint64_t f = (uint64_t)__builtin_frame_address(0), k = 0; f && !(f & 7) && k < 32; k++) {
        uint64_t nfp = ((uint64_t *)f)[0], r = ((uint64_t *)f)[1]; site |= r == g_tg->ra; found |= r == beyond; if (!dm_fp_step_ok(f, nfp, &jumps)) break; f = nfp; }
    for (uint64_t f = (uint64_t)__builtin_frame_address(0), k = 0; f && !(f & 7) && k < 32; k++) {   // the walk as it was: up the stack only
        uint64_t nfp = ((uint64_t *)f)[0]; strict |= ((uint64_t *)f)[1] == beyond; if (nfp <= f) break; f = nfp; }
    if (!site || !found) bad |= 32;
    if (g_on && (uintptr_t)g_glo < sp && strict) bad |= 64;   // the guest stack lies below the host stack: the strict walk stops before it
    return bad ? bad : 0x600d;
}
static tg_t g_inner;
static uint64_t g_osp, g_isp, g_oslot, g_islot;
static uint64_t h_inner(void) { g_isp = cur_sp(); g_islot = slot(); return 0x1a1; }
static uint64_t h_outer(void) { g_osp = cur_sp(); g_oslot = slot(); tg_call(&g_inner); return g_inner.ret == 0x1a1 && g_inner.kept == 1 ? 0x600d : 1; }
static uint64_t h_block(void) { CLOBBER_CALLEE(); block_here(); return 0x600d; }
static tg_t g_nsvc = {.fn = 0x81};
static uint64_t h_nest(void) { tg_svc(&g_nsvc); return g_nsvc.ret == 0x600d ? 0x600d : 1; }
static uint64_t h_nop(uint64_t x) { return x + 1; }
static unsigned g_uidx; static uint64_t g_usp, g_uargs;
uint64_t unimpl_c(unsigned idx, uint64_t *regs) { g_uidx = idx; g_usp = cur_sp(); g_uargs = regs[0] == 1 && regs[7] == 8; return 0x777; }

// The test gate: 0x80 an svc that checks where it runs, 0x81 the same blocking until released, 0x82 returns at once; others go to svc_thread
static uint64_t g_gsp; static int g_gregs;
uint64_t gate_dispatch(uint64_t ret, uint64_t *regs) {
    int num = (int)regs[16];
    if (num == 0x83) return regs[0];   // the gate round trip alone (8)
    if (num < 0x80 || num > 0x82) { if (!svc_thread(num, regs)) die("unexpected SVC %#x", num); return regs[0]; }
    thr_svc_enter(regs, ret);
    if (num != 0x82) {
        g_gsp = cur_sp();
        int ok = regs[0] == 0x100 && regs[3] == 0x103 && regs[17] == 0x1700;
        for (int r = 9; r <= 15; r++) ok &= regs[r] == G(r);
        for (int r = 19; r <= 28; r++) ok &= regs[r] == G(r);
        g_gregs = ok;
        if (g_deep && !deep()) g_gregs = 0;
        if (num == 0x81) { CLOBBER_CALLEE(); block_here(); }
        regs[0] = 0x600d; regs[1] = 0x601; regs[2] = 0x602; regs[3] = 0x603; regs[16] = 0x1616; regs[17] = 0x1717;
    }
    thr_svc_exit();
    return regs[0];
}

// ---------- The guest thread ----------
static tg_t g_t1, g_t2, g_t3, g_t3b, g_t4, g_td, g_te, g_tf, g_t6;
static uint64_t g_slot_after, g_top_seen;
static uint64_t g_bench_wrapped, g_bench_direct, g_bench_gate;
static void *g_w_args, *g_w_outer, *g_w_block, *g_w_nest, *g_w_nop;
void tg_main(uint64_t arg) {
    (void)arg;
    g_top_seen = slot();
    g_t1.fn = (uint64_t)g_w_args; g_tg = &g_t1; tg_call(&g_t1);                          // 1
    if (getenv("T_HSTACK_DEEP_ONLY")) return;
    g_t2.fn = 0x80; tg_svc(&g_t2);                                                       // 2
    g_t3.fn = (uint64_t)g_w_outer; g_tg = &g_t3; tg_call(&g_t3);                         // 3
    g_slot_after = slot();
    g_t3b.fn = (uint64_t)g_w_args; g_tg = &g_t3b; tg_call(&g_t3b);
    g_t4.fn = RAW_FN(&unimpl_stubs[3]); tg_call(&g_t4);                                 // 4
    g_td.fn = (uint64_t)g_w_block; tg_call(&g_td);                                       // 5
    g_te.fn = 0x81; tg_svc(&g_te);
    g_tf.fn = (uint64_t)g_w_nest; tg_call(&g_tf);
    if (g_on) { g_t6.fn = 0x82; tg_svc_at(&g_t6, (uint64_t)g_glo + 512); }               // 6
    uint64_t (*w)(uint64_t) = (uint64_t (*)(uint64_t))g_w_nop, (*volatile d)(uint64_t) = h_nop, s = 0;   // 8
    uint64_t t0 = now_ns(); for (int i = 0; i < 1000000; i++) s += w((uint64_t)i);
    uint64_t t1 = now_ns(); for (int i = 0; i < 1000000; i++) s += d((uint64_t)i);
    uint64_t t2 = now_ns(); g_bench_wrapped = t1 - t0; g_bench_direct = t2 - t1; if (s == 1) g_bench_direct++;
    tg_gate_loop(1000000); g_bench_gate = now_ns() - t2;
}

// The context checks of 5: at = the guest call whose entry is reported, hcall = it was a host call (else an svc)
static void ctx_check(const char *what, uint32_t h, const tg_t *at, int hcall) {
    uint64_t a[31] = {h, 1}; svc_thread(0x32, a);
    CHECK(a[0] == 0, "%s: SetThreadActivity pauses (%#llx)", what, (unsigned long long)a[0]);
    _Alignas(16) uint8_t ctx[0x320]; uint64_t c[31] = {(uint64_t)ctx, h}; svc_thread(0x33, c);
    const uint64_t *x = (const uint64_t *)ctx; uint64_t top = (uint64_t)g_glo + GSTACK;
    CHECK(c[0] == 0, "%s: GetThreadContext3 answers (%#llx)", what, (unsigned long long)c[0]);
    int sp_ok = x[31] >= (uint64_t)g_glo && x[31] < top && x[31] <= at->sp;
    CHECK(sp_ok, "%s: sp %#llx on the guest stack, at or below the call's %#llx (the GC scans every guest frame)", what, (unsigned long long)x[31], (unsigned long long)at->sp);
    int vis = 1;
    for (int r = 19; r <= 28; r++) {
        int seen = 0; for (int k = 0; k < 31; k++) seen |= x[k] == G(r);
        for (uint64_t p = x[31]; sp_ok && !seen && p + 8 <= top; p += 8) seen = *(const uint64_t *)p == G(r);
        vis &= seen;
    }
    CHECK(vis, "%s: the guest's x19..x28 in the registers reported or on the guest stack above that sp", what);
    if (g_on) {
        int regs = 1; for (int r = 19; r <= 28; r++) regs &= x[r] == G(r);
        CHECK(x[31] == at->sp && regs && x[29] == at->fp, "%s: exactly the guest's sp, x19..x28 and fp at the outer entry", what);
        if (hcall) CHECK(x[30] == at->ra && x[32] == at->ra && x[0] == 1 && x[7] == 8, "%s: lr / pc = the return address, x0..x7 = the arguments", what);
        else CHECK(x[30] == at->lr && x[32] == at->ra, "%s: lr = the gate block's x30, pc = the svc's", what);
    }
    uint64_t r[31] = {h, 0}; svc_thread(0x32, r);
    CHECK(r[0] == 0, "%s: SetThreadActivity resumes", what);
}

// ---------- 7: the direct libc functions ----------
typedef struct { const char *name; void *fn; int direct; } hle_ent;   // = hle.h
enum { MSTACK = 64 << 10 };
static uint8_t *g_mstack;
static volatile double g_sink;
static int in(const char *n, const char *const *l) { for (; *l; l++) if (!strcmp(n, *l)) return 1; return 0; }
static int run_fn(const char *n, void *fn) {   // 1 when the name is known: calls fn with ordinary and slow-path arguments
    static const char *const F1[] = {"sqrtf", "cbrtf", "expf", "acosf", "cosf", "sinf", "atanf", "tanf", "asinf", "logf", "log10f", "exp2f", "log2f", 0};
    static const char *const D1[] = {"cos", "sin", "log10", "log", "exp2", "log2", 0};
    static const char *const F2[] = {"atan2f", "fmodf", "powf", 0}, *const D2[] = {"pow", "atan2", 0};
    static const float fv[] = {0.5f, -0.75f, 3.0f, 1e30f, -1e-30f, 1e10f, 123456.789f, 1.0000001f, 88.7f, -103.0f};
    static const double dv[] = {0.5, -0.75, 3.0, 1e300, 1e-300, 1e22, 123456.789, 1.0000001, 709.7, 6.0e15};
    static char a[4096], b[4096], s[4096];
    if (in(n, F1)) { for (int i = 0; i < 10; i++) g_sink += ((float (*)(float))fn)(fv[i]); return 1; }
    if (in(n, D1)) { for (int i = 0; i < 10; i++) g_sink += ((double (*)(double))fn)(dv[i]); return 1; }
    if (in(n, F2)) { for (int i = 0; i < 10; i++) for (int j = 0; j < 10; j++) g_sink += ((float (*)(float, float))fn)(fv[i], fv[j]); return 1; }
    if (in(n, D2)) { for (int i = 0; i < 10; i++) for (int j = 0; j < 10; j++) g_sink += ((double (*)(double, double))fn)(dv[i], dv[j]); return 1; }
    if (!strcmp(n, "ldexpf")) { for (int i = 0; i < 10; i++) g_sink += ((float (*)(float, int))fn)(fv[i], i * 40 - 200); return 1; }
    if (!strcmp(n, "ldexp")) { for (int i = 0; i < 10; i++) g_sink += ((double (*)(double, int))fn)(dv[i], i * 300 - 1500); return 1; }
    if (!strcmp(n, "frexp")) { int e; for (int i = 0; i < 10; i++) g_sink += ((double (*)(double, int *))fn)(dv[i], &e) + e; return 1; }
    if (!strcmp(n, "modff")) { float ip; for (int i = 0; i < 10; i++) g_sink += ((float (*)(float, float *))fn)(fv[i], &ip) + ip; return 1; }
    if (!strcmp(n, "lroundf")) { for (int i = 0; i < 10; i++) g_sink += (double)((long (*)(float))fn)(fv[i]); return 1; }
    memset(a, 'a', sizeof a - 1); memset(b, 'a', sizeof b - 1); b[4000] = 'B'; memcpy(s, "Hello, World", 13);
    typedef void *(*mem3)(void *, const void *, size_t);
    if (!strcmp(n, "memcpy") || !strcmp(n, "memmove")) { size_t k[] = {1, 64, 4000}; for (int i = 0; i < 3; i++) g_sink += ((mem3)fn)(b, a + 1, k[i]) != NULL; return 1; }
    if (!strcmp(n, "memset")) { g_sink += ((void *(*)(void *, int, size_t))fn)(b, 1, 4000) != NULL; return 1; }
    if (!strcmp(n, "memcmp")) { g_sink += ((int (*)(const void *, const void *, size_t))fn)(a, b, 4095); return 1; }
    if (!strcmp(n, "memchr")) { g_sink += ((void *(*)(const void *, int, size_t))fn)(b, 'B', 4095) != NULL; return 1; }
    if (!strcmp(n, "strlen")) { g_sink += (double)((size_t (*)(const char *))fn)(a); return 1; }
    if (!strcmp(n, "strnlen")) { g_sink += (double)((size_t (*)(const char *, size_t))fn)(a, 4000); return 1; }
    if (!strcmp(n, "strcmp") || !strcmp(n, "strcasecmp")) { g_sink += ((int (*)(const char *, const char *))fn)(a, b); return 1; }
    if (!strcmp(n, "strncmp") || !strcmp(n, "strncasecmp")) { g_sink += ((int (*)(const char *, const char *, size_t))fn)(a, b, 4095); return 1; }
    if (!strcmp(n, "strcpy")) { g_sink += ((char *(*)(char *, const char *))fn)(b, a) != NULL; return 1; }
    if (!strcmp(n, "strncpy")) { g_sink += ((char *(*)(char *, const char *, size_t))fn)(b, s, 4000) != NULL; return 1; }
    if (!strcmp(n, "strcat")) { b[0] = 0; g_sink += ((char *(*)(char *, const char *))fn)(b, a + 100) != NULL; return 1; }
    if (!strcmp(n, "strncat")) { b[0] = 0; g_sink += ((char *(*)(char *, const char *, size_t))fn)(b, a, 4000) != NULL; return 1; }
    if (!strcmp(n, "strchr") || !strcmp(n, "strrchr")) { g_sink += ((char *(*)(const char *, int))fn)(b, 'B') != NULL; return 1; }
    if (!strcmp(n, "strstr")) { g_sink += ((char *(*)(const char *, const char *))fn)(b, "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaB") != NULL; return 1; }
    if (!strcmp(n, "strpbrk")) { g_sink += ((char *(*)(const char *, const char *))fn)(b, "XYZB") != NULL; return 1; }
    // Two of the functions on the host stack, to show the method sees deep ones (time zone load, number parsing)
    if (!strcmp(n, "localtime_r")) { time_t t = 1700000000; struct tm tm; g_sink += ((struct tm *(*)(const time_t *, struct tm *))fn)(&t, &tm) != NULL; return 1; }
    if (!strcmp(n, "strtod")) { g_sink += ((double (*)(const char *, char **))fn)("1.000000000000000000000000000000000000000000000001e-300", NULL); return 1; }
    if (!strcmp(n, "strspn") || !strcmp(n, "strcspn")) { g_sink += (double)((size_t (*)(const char *, const char *))fn)(b, "abcdefghijklmnopqrstuvwxyz"); return 1; }
    return 0;
}
static uint64_t runner(void *p) { const hle_ent *e = p; return (uint64_t)run_fn(e->name, e->fn); }
static long painted_use(const hle_ent *e, int *known) {   // bytes below the runner's frame the call wrote, on a painted stack of its own
    memset(g_mstack, 0xA5, MSTACK);
    *known = (int)tg_on_stack(runner, (void *)e, (uint64_t)g_mstack + MSTACK);
    size_t i = 0; while (i < MSTACK && g_mstack[i] == 0xA5) i++;
    return (long)(MSTACK - i);
}
static void libc_direct(void) {
    unsigned long sz; const hle_ent *sec = (const hle_ent *)getsectiondata(&_mh_execute_header, "__DATA", "swhle", &sz);
    unsigned n = sec ? (unsigned)(sz / sizeof *sec) : 0, nd = 0, unknown = 0; long worst = 0; const char *wn = "";
    if (posix_memalign((void **)&g_mstack, 16384, MSTACK)) die("posix_memalign");
    static const hle_ent none = {"", NULL, 1}; int known;
    long base = painted_use(&none, &known);
    for (unsigned i = 0; i < n; i++) {
        if (!sec[i].direct) continue;
        nd++; long u = painted_use(&sec[i], &known) - base;
        if (!known) { printf("     no measurement for %s: add it to run_fn\n", sec[i].name); unknown++; continue; }
        if (u > worst) { worst = u; wn = sec[i].name; }
    }
    printf("     %u direct libc functions, the deepest %s: %ld bytes below the caller's frame (the caller alone: %ld)\n", nd, wn, worst, base);
    long lt = 0, sd = 0;
    for (unsigned i = 0; i < n; i++) { if (!strcmp(sec[i].name, "localtime_r")) lt = painted_use(&sec[i], &known) - base; if (!strcmp(sec[i].name, "strtod")) sd = painted_use(&sec[i], &known) - base; }
    printf("     on the host stack instead: localtime_r %ld bytes (the first call loads the time zone), strtod %ld\n", lt, sd);
    CHECK(lt > 1024, "7: the measurement sees a deep function (localtime_r: %ld bytes)", lt);
    CHECK(nd >= 50 && !unknown, "7: every direct libc function of hle_table.c measured (%u, %u without a measurement)", nd, unknown);
    CHECK(worst <= 1024, "7: each uses at most 1 KiB of stack (%s: %ld)", wn, worst);
}

int main(int argc, char **argv) {
    alarm(60); setvbuf(stdout, NULL, _IONBF, 0);
    struct sigaction sa = {.sa_sigaction = fault, .sa_flags = SA_SIGINFO | SA_ONSTACK};
    sigaction(SIGSEGV, &sa, NULL); sigaction(SIGBUS, &sa, NULL);
    crash_thread_init();
    if (pthread_key_create(&g_key18, NULL) || pthread_key_create(&g_keytls, NULL) || pthread_key_create(&g_keytlr, NULL) || pthread_key_create(&g_keygate, NULL))
        die("pthread_key_create");
    int deep_only = argc > 1 && !strcmp(argv[1], "deep");
    if (deep_only) setenv("T_HSTACK_DEEP_ONLY", "1", 1);
    uint8_t *m = mmap(NULL, GSTACK + GUARD, PROT_READ | PROT_WRITE, MAP_ANON | MAP_PRIVATE, -1, 0);
    if (m == MAP_FAILED || mprotect(m, GUARD, PROT_NONE)) die("mmap");
    g_glo = m + GUARD;
    g_w_args = dm_hwrap((void *)h_args); g_w_outer = dm_hwrap((void *)h_outer); g_w_block = dm_hwrap((void *)h_block);
    g_w_nest = dm_hwrap((void *)h_nest); g_w_nop = dm_hwrap((void *)h_nop);
    g_inner.fn = (uint64_t)dm_hwrap((void *)h_inner);
    g_on = dm_hstk_off != 0; g_deep = g_on || deep_only;
    printf("     host stack switch %s%s\n", g_on ? "on" : "off (DM_HSTACK=0)", deep_only ? ", deep calls only" : "");
    CHECK(!g_on || (g_w_args != (void *)h_args && dm_hwrap((void *)h_args) == g_w_args && g_inner.fn != (uint64_t)g_w_args), "wrappers: one per function, the same one again");
    svc_thread_main_init();

    uint64_t c[31] = {0, RAW_FN(tg_entry), 0, (uint64_t)g_glo + GSTACK - 64, 44, 0};
    svc_thread(0x08, c); uint32_t h = (uint32_t)c[1];
    { uint64_t s[31] = {h}; svc_thread(0x09, s); }
    if (!deep_only) {
        wait_blocked(1);
        printf("     guest stack %p, host stack near %#llx\n", (void *)g_glo, (unsigned long long)g_hsp);
        ctx_check("5 host call", h, &g_td, 1); release(1);
        wait_blocked(2); ctx_check("5 svc", h, &g_te, 0); release(2);
        wait_blocked(3); ctx_check("5 svc inside a host call", h, &g_tf, 1); release(3);
    }
    uint64_t w[31] = {0, (uint64_t)&h, 1, (uint64_t)-1}; svc_thread(0x18, w);
    CHECK(w[0] == 0, "the guest thread exited through ExitThread (from its host stack when on)");

    CHECK(g_t1.ret == 0x600d, "1: host function: arguments, stack, %sguest return address, frame walk (%#llx)", g_deep ? "64 KiB, " : "", (unsigned long long)g_t1.ret);
    CHECK(g_t1.kept == 1, "1: x19..x28 / d8..d15 kept across the host call");
    CHECK(!g_on || g_top_seen != 0, "the guest thread has a host stack top in its slot (%#llx)", (unsigned long long)g_top_seen);
    if (!deep_only) {
        CHECK(g_t2.ret == 0x600d && g_t2.x1 == 0x601 && g_t2.x3 == 0x603 && g_gregs && g_t2.kept == 1, "2: svc: results, registers in, every other register kept, x16 / x17 written back");
        CHECK(g_on ? !on_guest(g_gsp) : on_guest(g_gsp), "2: the svc ran on the %s stack", g_on ? "host" : "guest");
        CHECK(g_t3.ret == 0x600d && g_t3.kept == 1, "3: host → guest → host: both calls done, registers kept");
        CHECK(!g_on || (!on_guest(g_osp) && !on_guest(g_isp) && g_isp < g_osp && !g_oslot && !g_islot && g_slot_after == g_top_seen),
              "3: the inner call stayed on the host stack below the outer one, the slot empty inside and back after");
        CHECK(g_t3b.ret == 0x600d, "3: the next call takes the host stack again (%#llx)", (unsigned long long)g_t3b.ret);
        CHECK(g_t4.ret == 0x777 && g_uidx == 3 && g_uargs && (g_on ? !on_guest(g_usp) : on_guest(g_usp)), "4: unimplemented import stub 3: number, arguments, stack");
        CHECK(g_td.ret == 0x600d && g_te.ret == 0x600d && g_tf.ret == 0x600d, "5: the paused calls finished");
        if (g_on) {
            uint64_t top, low, bot; int said; thr_stack_info(h, &top, &low, &bot, &said);
            CHECK(bot == (uint64_t)g_glo && low == g_t6.sp && said, "6: least free guest stack: %llu bytes at the deepest svc (the low-stack line logged: %d)",
                  (unsigned long long)(low - bot), said);
            printf("     a wrapped call costs %.1f ns more than a direct one (%.1f against %.1f ns); a gate round trip (svc / cntpct entry) %.1f ns\n",
                   (g_bench_wrapped - (double)g_bench_direct) / 1e6, g_bench_wrapped / 1e6, g_bench_direct / 1e6, g_bench_gate / 1e6);
        }
        libc_direct();
    }
    printf("t_hstack: %d checks, %d failed\n", checks, fails);
    return fails != 0;
}
