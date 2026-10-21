// Memory snapshots (memsnap.c): a fake guest address space of 64 pages, PROT_NONE but for a readable and writable part with a PROT_NONE hole, in which
// some pages are touched and others not; a fake module whose text, data and key page are touched. The snapshot holds the touched readable pages of
// the guest block and of the module's data with their bytes, and nothing else (no untouched page, no page behind PROT_NONE, no text, no key page);
// the header names the ranges. DM_MEMSNAP's value: frames sorted, the prefix kept with its own ':' and ','; no ':' or no frame turns it off.
// And the trigger: frame 2 asked, the counter reaches 3, the file is there with frame 2.
#include "../dm.h"
#include <sys/mman.h>
#include <unistd.h>
long dm_memsnap_write(const char *path, long frame);
int dm_memsnap_parse(const char *spec, long *frames, int max, char *prefix, size_t prefix_n);
void dm_memsnap_init(void);
module_t g_mod[MAX_MOD]; int g_nmod;
static uint8_t *g_as; static size_t PG;
void svc_guest_range(uint8_t **base, size_t *size) { *base = g_as; *size = 64 * PG; }
void svc_guest_layout(uint8_t **alias, size_t *alias_n, uint8_t **stack, size_t *stack_n, uint8_t **heap, size_t *heap_n) {
    *alias = g_as + 4 * PG; *alias_n = 20 * PG; *stack = g_as + 24 * PG; *stack_n = 8 * PG; *heap = g_as + 32 * PG; *heap_n = 32 * PG;
}
static _Atomic uint64_t g_frame;
uint64_t dm_nvn_frame_count(void) { return g_frame; }
uint64_t now_ns(void) { return clock_gettime_nsec_np(CLOCK_UPTIME_RAW); }
static int n, fail;
#define CHECK(c, ...) do { n++; if (c) printf("  ✓ "); else { fail++; printf("  ✗ "); } printf(__VA_ARGS__); printf("\n"); } while (0)

typedef struct { uint64_t lo, hi; char name[16]; } rng;
static uint8_t *g_buf; static size_t g_len;
static int slurp(const char *p) { FILE *f = fopen(p, "rb"); if (!f) return 0; fseek(f, 0, SEEK_END); g_len = (size_t)ftell(f); fseek(f, 0, SEEK_SET);
                                  free(g_buf); g_buf = malloc(g_len); size_t k = fread(g_buf, 1, g_len, f); fclose(f); return k == g_len; }
// The records' pages: 1 per page of the 64 + module pages (index 64 + i), 0 otherwise; -1 when a record is malformed or its bytes differ from memory
static int pages[96];
static int scan(uint8_t *mod, uint64_t *frame, rng *r, uint32_t *nr) {
    memset(pages, 0, sizeof pages);
    if (g_len < 24 || memcmp(g_buf, "DMSNAP01", 8)) return -1;
    memcpy(frame, g_buf + 8, 8); memcpy(nr, g_buf + 16, 4); size_t o = 24 + *nr * sizeof(rng); if (*nr > 12 || o > g_len) return -1;
    memcpy(r, g_buf + 24, *nr * sizeof(rng));
    while (o < g_len) {
        uint64_t a, l; if (o + 16 > g_len) return -1; memcpy(&a, g_buf + o, 8); memcpy(&l, g_buf + o + 8, 8); o += 16;
        if (o + l > g_len || l % PG || a % PG) return -1;
        if (memcmp((void *)(uintptr_t)a, g_buf + o, l)) return -1;
        for (uint64_t p = a; p < a + l; p += PG) {
            if (p >= (uintptr_t)g_as && p < (uintptr_t)g_as + 64 * PG) pages[(p - (uintptr_t)g_as) / PG]++;
            else if (p >= (uintptr_t)mod && p < (uintptr_t)mod + 8 * PG) pages[64 + (p - (uintptr_t)mod) / PG]++;
            else return -1;
        }
        o += l;
    }
    return 0;
}
int main(void) {
    PG = (size_t)getpagesize();
    g_as = mmap(NULL, 64 * PG, PROT_NONE, MAP_PRIVATE | MAP_ANON, -1, 0);
    mprotect(g_as + 4 * PG, 60 * PG, PROT_READ | PROT_WRITE);
    int touch[] = {5, 6, 7, 25, 40, 41, 50}; for (unsigned i = 0; i < sizeof touch / sizeof *touch; i++) memset(g_as + touch[i] * PG, 0x30 + i, PG);
    memset(g_as + 44 * PG, 0x55, PG); mprotect(g_as + 44 * PG, PG, PROT_NONE);   // touched, then made unreadable
    // module: text pages 0-1, data 2-4 (2 and 4 touched), key page 5, patch area 6-7
    uint8_t *mod = mmap(NULL, 8 * PG, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANON, -1, 0);
    memset(mod, 0x11, 2 * PG); memset(mod + 2 * PG, 0x22, PG); memset(mod + 4 * PG, 0x44, PG); memset(mod + 5 * PG, 0x66, 3 * PG);
    g_mod[0] = (module_t){.name = "main", .base = mod, .size = 8 * PG, .data_off = 2 * PG, .key_page_off = 5 * PG, .patch_off = 6 * PG}; g_nmod = 1;
    char dir[1024]; const char *td = getenv("TMPDIR"); snprintf(dir, sizeof dir, "%s/t_memsnap.XXXXXX", td ? td : "/private/tmp");
    if (!mkdtemp(dir)) { perror("mkdtemp"); return 1; }
    char path[1100]; snprintf(path, sizeof path, "%s/s_9.bin", dir);
    long w = dm_memsnap_write(path, 9);
    uint64_t frame = 0; rng r[12]; uint32_t nr = 0;
    int ok = slurp(path) && scan(mod, &frame, r, &nr) == 0;
    CHECK(ok, "the file parses and every record's bytes equal memory (%ld bytes written)", w);
    CHECK(frame == 9 && nr == 5 && !strcmp(r[0].name, "prefix") && !strcmp(r[3].name, "heap") && !strcmp(r[4].name, "main.data")
          && r[4].lo == (uintptr_t)(mod + 2 * PG) && r[4].hi == (uintptr_t)(mod + 5 * PG), "header: frame 9, ranges prefix / alias / stack / heap / main.data");
    int want[96] = {0}; for (unsigned i = 0; i < sizeof touch / sizeof *touch; i++) want[touch[i]] = 1; want[64 + 2] = want[64 + 4] = 1;
    int same = ok; for (int i = 0; i < 96; i++) if (pages[i] != want[i]) { same = 0; printf("    page %d: %d record(s), want %d\n", i, pages[i], want[i]); }
    CHECK(same, "exactly the touched readable pages: guest 5-7, 25, 40-41, 50 and the module's data pages 2 and 4");
    CHECK(w == 9 * (long)PG, "the bytes written are the 9 pages (%ld)", w);
    long f[16]; char pre[64];
    int k = dm_memsnap_parse("300,20,1000:/tmp/a:b,c", f, 16, pre, sizeof pre);
    CHECK(k == 3 && f[0] == 20 && f[1] == 300 && f[2] == 1000 && !strcmp(pre, "/tmp/a:b,c"), "parse: frames 20, 300, 1000 and the prefix /tmp/a:b,c (%d, %s)", k, pre);
    CHECK(dm_memsnap_parse("300", f, 16, pre, sizeof pre) == 0 && dm_memsnap_parse(":/tmp/a", f, 16, pre, sizeof pre) == 0
          && dm_memsnap_parse("5:", f, 16, pre, sizeof pre) == 0, "parse: no ':', no frame or no prefix turns it off");
    char spec[1100]; snprintf(spec, sizeof spec, "2:%s/t", dir); setenv("DM_MEMSNAP", spec, 1);
    dm_memsnap_init(); snprintf(path, sizeof path, "%s/t_2.bin", dir);
    usleep(30000); int early = access(path, F_OK) == 0;
    g_frame = 3;
    int got = 0; for (int i = 0; i < 400 && !got; i++) { usleep(10000); got = slurp(path) && g_len > 24 && scan(mod, &frame, r, &nr) == 0 && pages[5]; }
    CHECK(!early && got && frame == 2, "the trigger: nothing at frame 0, the snapshot of frame 2 once the counter reaches 3");
    char cmd[1100]; snprintf(cmd, sizeof cmd, "rm -rf '%s'", dir); system(cmd);
    printf("t_memsnap: %d checks, %d failed\n", n, fail); return fail != 0;
}
