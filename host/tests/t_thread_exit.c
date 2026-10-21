// ExitThread must leave the guest stack before the exit becomes visible to waiters (deterministic, no sleeps). From TommyLau/botw-mobile 4a9b641
// (MIT), adapted to this host: the publication is observed through now_ns (its first call records the exit time) instead of a game tick hook.
// The SDK's nn::os::WaitThread unmaps the alias stack as soon as the kernel wait on the thread handle returns, so the exit publication and the
// pthread TSD destructors must not run on that stack. The test links the real hle_thread.c, thread.c and entry.S (dm_thread_enter, dm_gate):
//   - each worker is created with SVC 0x08, enters its own mmap'd guest stack through dm_thread_enter, poisons all callee-saved registers and
//     issues ExitThread through dm_gate (t_thread_exit_guest.S);
//   - the waiter retires the guest stack right after the exit is published: even iterations mprotect it PROT_NONE (unmapped alias), odd ones
//     map fresh memory over it and fill it with garbage (alias reused); the next worker reuses the same address;
//   - a TSD destructor blocks until the stack has been retired and then does real work; it must run exactly once, on the host pthread stack;
//   - the exit publication must also run on the host pthread stack;
//   - two paths alternate: wait-then-close (WaitThread + DestroyThread order) and close-before-exit (the exiting thread frees the object);
//   - finally the registered main thread (no saved host context) exits through the fallback, waking a worker that waits on its handle.
// Two builds: t_thread_exit (must pass) and t_thread_exit_old (-DDM_TEST_EXIT_ON_GUEST_STACK keeps the pre-fix exit on the guest stack; it must
// fail, with a fault on the retired stack reported by the handler below).
#include "../game.h"
#include "../dm.h"
#include <pthread.h>
#include <signal.h>
#include <stdatomic.h>
#include <sys/mman.h>
#include <unistd.h>
#if __has_feature(ptrauth_calls)
#include <ptrauth.h>
#define RAW_FN(f) ((uint64_t)ptrauth_strip((void *)(f), ptrauth_key_function_pointer))   // dm_thread_enter branches with a plain br, like a guest entry address
#else
#define RAW_FN(f) ((uint64_t)(f))
#endif

int svc_thread(int num, uint64_t *regs);
uint32_t svc_thread_main_init(void);
void thr_counts(int *handles, int *live, int *objs);
void t_guest_entry(uint64_t arg);   // t_thread_exit_guest.S
_Noreturn void t_exit_via_gate(void);

// ---------- Test state ----------
enum { STACK_SIZE = 256 << 10, ITER = 64 };
enum { M_WAIT, M_CLOSE_FIRST, M_WAIT_MAIN };
typedef struct rec {
    int iter, mode;
    int in_guest, may_exit, dtor_started, retired, dtor_done;   // gates, guarded by g_m
    int guest_on_alias, publish_n, publish_on_host, dtor_on_host, work_ok;
    _Atomic int exiting;   // set by the guest code right before it issues ExitThread
    _Atomic int dtor_n;
    int64_t main_wait_rc;
    void *altstack;
} rec_t;
static uint8_t *g_stack;
static pthread_mutex_t g_m = PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t g_c = PTHREAD_COND_INITIALIZER;
static pthread_key_t g_dkey;
static rec_t *g_next_rec;
static _Atomic int g_dtor_total;
static uint32_t g_main_handle;
static int fails, checks;
#define EXPECT(name, want, got) do { long w_ = (long)(want), g_ = (long)(got); checks++; \
    printf("%s %-62s expected %-6ld got %-6ld\n", w_ == g_ ? "ok  " : "FAIL", name, w_, g_); if (w_ != g_) fails++; } while (0)

static uintptr_t cur_sp(void) { uintptr_t sp; __asm__ volatile("mov %0, sp" : "=r"(sp)); return sp; }
static int on_guest_stack(uintptr_t sp) { return sp >= (uintptr_t)g_stack && sp < (uintptr_t)g_stack + STACK_SIZE; }
static int on_host_stack(uintptr_t sp) {
    pthread_t s = pthread_self(); uintptr_t hi = (uintptr_t)pthread_get_stackaddr_np(s), lo = hi - pthread_get_stacksize_np(s);
    return sp > lo && sp <= hi && !on_guest_stack(sp);
}

// ---------- Host facilities hle_thread.c / thread.c / entry.S need ----------
struct dm_flags g_flag;
const dm_game_profile dm_game = { .id = "test" };   // virtual cores off (hle_thread.c reads dm_game.virtual_cores)
uint64_t g_t0_ns;
pthread_key_t g_key18, g_keytls, g_keytlr, g_keygate;
void *guest_sym(const char *name) { (void)name; return NULL; }
module_t *module_of(const void *p) { (void)p; return NULL; }
void dm_prof_add(int id, uint64_t ns, uint64_t bytes) { (void)id; (void)ns; (void)bytes; }
#include <mach/mach_time.h>
// The exit publication starts with exit_ns = now_ns(): a call on an exiting thread marks where the publication runs
uint64_t now_ns(void) {
    rec_t *r = pthread_getspecific(g_dkey);
    if (r && atomic_load(&r->exiting)) { r->publish_n++; r->publish_on_host = on_host_stack(cur_sp()); }
    static mach_timebase_info_data_t tb; if (!tb.denom) mach_timebase_info(&tb); return mach_absolute_time() * tb.numer / tb.denom;
}
uint64_t guest_ns(void) { return now_ns(); }
int dm_detclock_enabled(void) { return 0; }
uint64_t unimpl_c(unsigned idx, uint64_t *regs) { (void)regs; die("unexpected unimplemented stub %u", idx); }
uint64_t gate_dispatch(uint64_t ret, uint64_t *regs) {   // test gate: SVC number in x16
    (void)ret;
    if (!svc_thread((int)regs[16], regs)) die("unexpected SVC %#llx", regs[16]);
    return regs[0];
}

static void gate_set(int *f) { pthread_mutex_lock(&g_m); *f = 1; pthread_cond_broadcast(&g_c); pthread_mutex_unlock(&g_m); }
static void gate_wait(int *f) { pthread_mutex_lock(&g_m); while (!*f) pthread_cond_wait(&g_c, &g_m); pthread_mutex_unlock(&g_m); }

// A fault while the old code runs on the retired guest stack lands here (on the per-thread alternate stack)
static void fault(int sig, siginfo_t *si, void *uc) {
    (void)uc; char m[128] = "FAIL fault signal __ at 0x0000000000000000: exiting thread touched memory outside the guest stack\n";
    uintptr_t a = (uintptr_t)si->si_addr;
    if (on_guest_stack(a)) strcpy(m + 42, ": exiting thread touched the retired guest stack\n");
    m[18] = (char)('0' + sig / 10); m[19] = (char)('0' + sig % 10);
    for (int i = 0; i < 16; i++) m[26 + 15 - i] = "0123456789abcdef"[(a >> (4 * i)) & 15];
    write(1, m, strlen(m)); _exit(1);
}

// Called by thread_main on the host stack before the guest is entered (stands in for the crash.c alternate stack and its TSD)
void crash_thread_init(void) {
    rec_t *r = g_next_rec;
    r->altstack = malloc(65536);
    stack_t ss = {.ss_sp = r->altstack, .ss_size = 65536}; sigaltstack(&ss, 0);
    pthread_setspecific(g_dkey, r);
}
// Deliberately slow TSD destructor: blocks until the waiter has retired the guest stack, then uses a good amount of stack
static void work_dtor(void *v) {
    rec_t *r = v;
    int host = on_host_stack(cur_sp());
    atomic_fetch_add(&r->dtor_n, 1); atomic_fetch_add(&g_dtor_total, 1);
    gate_set(&r->dtor_started);
    gate_wait(&r->retired);
    volatile char buf[32 << 10];
    for (size_t i = 0; i < sizeof buf; i += 64) buf[i] = (char)i;
    char line[64]; snprintf(line, sizeof line, "%.3f %d", 3.14159 * r->iter, buf[128]);
    r->work_ok = line[0] != 0 && buf[64] == 64;
    r->dtor_on_host = host && on_host_stack(cur_sp());
    stack_t off = {.ss_flags = SS_DISABLE}; sigaltstack(&off, 0); free(r->altstack);
    gate_set(&r->dtor_done);
}

// Runs on the guest stack, called from t_guest_entry
void t_guest_body(uint64_t arg) {
    rec_t *r = (rec_t *)arg;
    r->guest_on_alias = on_guest_stack(cur_sp());
    if (r->mode == M_CLOSE_FIRST) { gate_set(&r->in_guest); gate_wait(&r->may_exit); }
    if (r->mode == M_WAIT_MAIN) {
        uint32_t h = g_main_handle; uint64_t w[31] = {0, (uint64_t)&h, 1, (uint64_t)-1};
        gate_set(&r->in_guest);
        svc_thread(0x18, w); r->main_wait_rc = (int64_t)w[0];
    }
    atomic_store(&r->exiting, 1);
}

static void retire(int i) {   // what the SDK's unmapping of the alias stack, and a later reuse of the range, look like to the exiting thread
    if (i % 2 == 0) { if (mprotect(g_stack, STACK_SIZE, PROT_NONE)) die("mprotect"); }
    else { if (mmap(g_stack, STACK_SIZE, PROT_READ | PROT_WRITE, MAP_FIXED | MAP_ANON | MAP_PRIVATE, -1, 0) != g_stack) die("mmap");
           memset(g_stack, 0xA5, STACK_SIZE); }
}
static void unretire(void) { if (mprotect(g_stack, STACK_SIZE, PROT_READ | PROT_WRITE)) die("mprotect"); }
static uint32_t create_start(rec_t *r) {
    g_next_rec = r;
    uint64_t c[31] = {0, RAW_FN(t_guest_entry), (uint64_t)r, (uint64_t)(g_stack + STACK_SIZE - 32), 44, 0};
    svc_thread(0x08, c);
    uint64_t s[31] = {c[1]}; svc_thread(0x09, s);
    return (uint32_t)c[1];
}

static int bad_alias, bad_publish, bad_dtor, bad_work, bad_wait, bad_objs, bad_closed_alive;
static void run_iter(int i) {
    rec_t r = {.iter = i, .mode = i % 4 < 2 ? M_WAIT : M_CLOSE_FIRST};
    int h0, live0, objs0, h1, live1, objs1; thr_counts(&h0, &live0, &objs0);
    uint32_t h = create_start(&r);
    if (r.mode == M_WAIT) {
        uint64_t w[31] = {0, (uint64_t)&h, 1, (uint64_t)-1};
        svc_thread(0x18, w);                          // nn::os::WaitThread: kernel wait on the thread handle
        retire(i);                                    // ... then the alias stack is unmapped at once
        bad_wait += w[0] != 0 || w[1] != 0;
        uint64_t cl[31] = {h}; svc_thread(0x16, cl);   // DestroyThread closes the handle; may free the object while the destructors still run
    } else {
        gate_wait(&r.in_guest);
        uint64_t cl[31] = {h}; svc_thread(0x16, cl);   // closed while still running: the exiting thread frees the object
        thr_counts(&h1, &live1, &objs1); bad_closed_alive += objs1 != objs0 + 1 || live1 != live0 + 1;
        gate_set(&r.may_exit);
        gate_wait(&r.dtor_started);                   // destructors start only after the publication
        retire(i);
    }
    gate_set(&r.retired);
    gate_wait(&r.dtor_done);
    unretire();
    thr_counts(&h1, &live1, &objs1);
    bad_alias += !r.guest_on_alias;
    bad_publish += r.publish_n != 1 || !r.publish_on_host;
    bad_dtor += atomic_load(&r.dtor_n) != 1 || !r.dtor_on_host;
    bad_work += !r.work_ok;
    bad_objs += h1 != h0 || live1 != live0 || objs1 != objs0;
}

static rec_t g_main_rec, g_wm_rec;
static void *guest_main(void *a) {
    (void)a;
    g_main_handle = svc_thread_main_init();
    for (int i = 0; i < ITER; i++) run_iter(i);
    // Main thread fallback: a worker waits on the main handle, then the main thread issues ExitThread on its own native stack
    g_wm_rec.mode = M_WAIT_MAIN; g_wm_rec.iter = ITER;
    create_start(&g_wm_rec);
    gate_wait(&g_wm_rec.in_guest);
    gate_set(&g_main_rec.retired);     // nothing to retire for the main thread; its destructor runs straight through
    pthread_setspecific(g_dkey, &g_main_rec);
    atomic_store(&g_main_rec.exiting, 1);
    t_exit_via_gate();
}

int main(void) {
    alarm(60);
    struct sigaction sa = {.sa_sigaction = fault, .sa_flags = SA_SIGINFO | SA_ONSTACK};
    int sigs[] = {SIGSEGV, SIGBUS, SIGILL, SIGTRAP};
    for (unsigned i = 0; i < sizeof sigs / sizeof *sigs; i++) sigaction(sigs[i], &sa, NULL);
    if (pthread_key_create(&g_dkey, work_dtor) || pthread_key_create(&g_key18, NULL) || pthread_key_create(&g_keytls, NULL) ||
        pthread_key_create(&g_keytlr, NULL) || pthread_key_create(&g_keygate, NULL)) die("pthread_key_create");
    g_stack = mmap(NULL, STACK_SIZE, PROT_READ | PROT_WRITE, MAP_ANON | MAP_PRIVATE, -1, 0);
    if (g_stack == MAP_FAILED) die("mmap");

    pthread_t gm; if (pthread_create(&gm, NULL, guest_main, NULL)) die("pthread_create");
    pthread_join(gm, NULL);
    gate_wait(&g_wm_rec.dtor_started);
    retire(0);
    gate_set(&g_wm_rec.retired);
    gate_wait(&g_wm_rec.dtor_done);

    EXPECT("worker iterations entered the guest stack via dm_thread_enter", 0, bad_alias);
    EXPECT("exit publication ran once, on the host pthread stack", 0, bad_publish);
    EXPECT("TSD destructor ran once, on the host pthread stack", 0, bad_dtor);
    EXPECT("destructor work completed after the guest stack was retired", 0, bad_work);
    EXPECT("WaitSynchronization on the thread handle returned 0, index 0", 0, bad_wait);
    EXPECT("closed-but-running thread object kept alive until its exit", 0, bad_closed_alive);
    EXPECT("handles / live threads / thread objects back to baseline", 0, bad_objs);
    EXPECT("main fallback: exit published once, on its native stack", 1, g_main_rec.publish_n == 1 && g_main_rec.publish_on_host);
    EXPECT("main fallback: TSD destructor ran once, on its native stack", 1, atomic_load(&g_main_rec.dtor_n) == 1 && g_main_rec.dtor_on_host);
    EXPECT("main fallback: waiter on the main handle woke with result 0", 0, g_wm_rec.main_wait_rc);
    EXPECT("main fallback waiter: exit + destructor on the host stack", 1, g_wm_rec.guest_on_alias && g_wm_rec.publish_n == 1 &&
           g_wm_rec.publish_on_host && atomic_load(&g_wm_rec.dtor_n) == 1 && g_wm_rec.dtor_on_host);
    int h, live, objs; thr_counts(&h, &live, &objs);
    EXPECT("live guest threads after everything exited", 0, live);
    EXPECT("thread objects left (main + its waiter, handles never closed)", 2, objs);
    EXPECT("destructor calls in total (iterations + main + waiter)", ITER + 2, atomic_load(&g_dtor_total));
    printf("t_thread_exit: %d checks, %d failed\n", checks, fails);
    fflush(stdout); _exit(fails != 0);
}
