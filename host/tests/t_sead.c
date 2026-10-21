// sead heaps and lists (sead.c) on heaps built by hand in a 1 MB block with the layout sead.c reads: heap A (16 pages, 3 blocks, a child heap C in
// its third block), heap B (4 pages, 2 blocks) of A's class, heap D of a class without a use list (garbage at +0xc8), and 16 KB with no access
// below A. A scan finds A, B, C and D; the innermost heap holding an address (C inside A's block, none past A's end or below A); the use list
// walked (blocks, bytes); B's use list broken three ways (a null next, a prev that does not point back, a node in another heap), each reported
// with where, and counted as broken because A's class has whole lists while D's garbage is not. A list with a null next is found, and
// DM_LIST_WATCH=heap+<offset> dumps the threads once when a list breaks while it watches.
// Negative control: -DDM_TEST_SEAD_BROKEN (a heap taken whether or not it reaches the address) fails "past A's end".
#include "../sead.c"
#include <stdatomic.h>
#include <sys/mman.h>
static int n, fail;
#define CHECK(c, ...) do { n++; if (c) printf("  ✓ "); else { fail++; printf("  ✗ "); } printf(__VA_ARGS__); printf("\n"); } while (0)
static uint8_t *g_m;
void svc_guest_layout(uint8_t **alias, size_t *alias_n, uint8_t **stack, size_t *stack_n, uint8_t **heap, size_t *heap_n) {
    *alias = *stack = NULL; *alias_n = *stack_n = 0; *heap = g_m; *heap_n = 1 << 20;
}
static _Atomic int g_dumps;
void svc_thread_dump(void) { g_dumps++; }
uint64_t now_ns(void) { return clock_gettime_nsec_np(CLOCK_UPTIME_RAW); }
module_t *module_of(const void *p) { (void)p; return NULL; }

static uint64_t *w(uint64_t a) { return (uint64_t *)(uintptr_t)a; }
static void heap(uint64_t h, uint64_t vt, uint64_t size, const char *name) { w(h)[0] = vt; w(h + H_NAME)[0] = (uint64_t)(uintptr_t)name; w(h + H_START)[0] = h;
                                                                             w(h + H_SIZE)[0] = size; w(h + H_NFREE)[0] = 1; w(h + H_USE)[0] = w(h + H_USE)[1] = h + H_USE; }
static void block(uint64_t h, uint64_t b, uint64_t size) {   // appended to h's use list
    uint64_t s = h + H_USE, last = w(s)[0];
    w(b)[0] = last; w(b)[1] = s; w(b)[2] = 0x1; w(b)[3] = size; w(last)[1] = b; w(s)[0] = b;
}
static int at(uint64_t h) { for (int i = 0; i < g_nsh; i++) if (g_sh[i].h == h) return i; return -1; }
static int broken(void) { int k = 0; for (int i = 0; i < g_nsh; i++) k += !g_sh[i].list && class_lists(g_sh[i].vt); return k; }

int main(void) {
    setvbuf(stdout, NULL, _IONBF, 0);
    if (posix_memalign((void **)&g_m, 16384, 1 << 20)) return 2;
    memset(g_m, 0, 1 << 20);
    uint64_t M = (uint64_t)(uintptr_t)g_m, A = M + 0x4000, B = M + 0x28000, C = A + 0x2000 + B_DATA, D = M + 0x40000, V1 = 0x7100, V2 = 0x7200, V3 = 0x7300;
    heap(A, V1, 0x10000, "TestHeapA"); block(A, A + 0x100, 0x200); block(A, A + 0x400, 0x1000); block(A, A + 0x2000, 0x900);
    heap(C, V2, 0x800, "Child");
    heap(B, V1, 0x4000, "TestHeapB"); block(B, B + 0x100, 0x40); block(B, B + 0x200, 0x80);
    heap(D, V3, 0x2000, "Frame"); w(D + H_USE)[0] = 0x5; w(D + H_USE)[1] = 0x1234;   // another class: no use list there
    mprotect(g_m, 0x4000, PROT_NONE);   // the 16 KB below A: no access

    printf("scan and the heap holding an address:\n");
    uint64_t sz = 0;
    CHECK(sead_is_heap(A, &sz) && sz == 0x10000 && !sead_is_heap(A + 0x100, NULL), "A is a heap of 0x10000 bytes, its first block is not");
    g_nsh = 0; int nf = sead_scan(M, M + (1 << 20));
    CHECK(nf == 4 && at(A) >= 0 && at(B) >= 0 && at(C) >= 0 && at(D) >= 0, "a scan of the block (across 16 KB with no access) finds A, B, D and the child C in A's block (%d)", nf);
    CHECK(g_sh[at(A)].list && g_sh[at(C)].list && !g_sh[at(D)].list && g_sh[at(A)].vt == V1, "A and C have whole use lists, D none; classes by vtable");
    CHECK(sead_innermost(A + 0x2100) == at(C), "an address in A's third block, inside C: C");
    CHECK(sead_innermost(A + 0x100) == at(A), "an address in A's first block: A");
    CHECK(sead_innermost(A + 0x10010) == -1, "an address past A's end: no heap");
    CHECK(sead_innermost(A - 0x10) == -1, "an address below A: no heap");
    CHECK(sead_innermost(B + 0x3ff8) == at(B), "the last word of B: B");
    CHECK(broken() == 0, "nothing broken: D's garbage at +0xc8 is not counted (its class has no whole list)");

    printf("walking use lists:\n");
    sead_walk_t r = sead_walk(A, NULL, NULL);
    CHECK(!r.bad && r.blocks == 3 && r.used == 0x200 + 0x1000 + 0x900, "A: 3 blocks, 0x1b00 bytes (%llu, %#llx%s%s)", (unsigned long long)r.blocks, (unsigned long long)r.used, r.bad ? ", " : "", r.bad ? r.bad : "");
    sead_heap_of(C + 0x10); sead_heaps_print();   // (the log lines, by eye)
    uint64_t b1 = B + 0x100, b2 = B + 0x200, saved = w(b1)[1];
    w(b1)[1] = 0; r = sead_walk(B, NULL, NULL);
    CHECK(r.bad && strstr(r.bad, "null next") && r.bad_at == 1, "B with a null next after its first block: found there (%s)", r.bad ? r.bad : "-");
    g_nsh = 0; sead_scan(M, M + (1 << 20));
    CHECK(broken() == 1 && !g_sh[at(B)].list, "... and counted broken: A, of B's class, has a whole list");
    w(b1)[1] = saved; saved = w(b2)[0]; w(b2)[0] = B + 0x180; r = sead_walk(B, NULL, NULL);
    CHECK(r.bad && strstr(r.bad, "prev") && r.bad_at == 1 && r.bad_node == b2, "B's second block not pointing back: found at it (%s)", r.bad ? r.bad : "-");
    w(b2)[0] = saved; saved = w(b1)[1]; w(b1)[1] = A + 0x400; r = sead_walk(B, NULL, NULL);
    CHECK(r.bad && strstr(r.bad, "outside"), "B's first block linking to a block of A: a node outside the heap (%s)", r.bad ? r.bad : "-");
    w(b1)[1] = saved; r = sead_walk(B, NULL, NULL);
    CHECK(!r.bad && r.blocks == 2, "B repaired: 2 blocks");

    printf("lists:\n");
    uint64_t L = M + 0x80000, n1 = L + 0x40, n2 = L + 0x80, n3 = L + 0xc0, prev = 0;
    w(L)[0] = n3; w(L)[1] = n1; w(n1)[0] = L; w(n1)[1] = n2; w(n2)[0] = n1; w(n2)[1] = n3; w(n3)[0] = n2; w(n3)[1] = L;
    CHECK(sead_list_check(L, &prev) == 0, "a whole list: nothing found");
    w(n2)[1] = 0;
    CHECK(sead_list_check(L, &prev) == n2 && prev == n1, "a node with a null next: found, with its prev");
    w(n2)[1] = n3;
    char spec[64]; snprintf(spec, sizeof spec, "heap+%#llx", (unsigned long long)(L - M)); setenv("DM_LIST_WATCH", spec, 1);
    sead_list_watch_start(); usleep(100000);
    CHECK(g_dumps == 0, "DM_LIST_WATCH=%s: a whole list, no dump", spec);
    w(n3)[1] = 0;
    for (int i = 0; i < 400 && !g_dumps; i++) usleep(5000);
    usleep(50000);
    CHECK(g_dumps == 1, "... the list broken while it watches: the threads dumped once (%d)", (int)g_dumps);
    printf("== %d checks, %d failed ==\n", n, fail); return fail != 0;
}
