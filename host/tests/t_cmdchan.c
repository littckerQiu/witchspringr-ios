// Live command channel (cmdchan.c, DM_CMD): the parser on a table of good and malformed lines, then the loop following a file a writer appends to:
// a line written in two parts runs once, whole, when its newline comes; a key is held for its time and released; "wait 3" holds the next line
// until three frames are presented; a malformed line and an over-long line are skipped and the lines after them run; "quit" ends the loop.
// Negative control: -DDM_TEST_CMD_PARTIAL (a line run as far as it was written, as a reader with fgets at the end of the file would) fails the
// line written in two parts.
#include "../cmdchan.c"
#include <stdatomic.h>
static int n, fail;
#define CHECK(c, ...) do { n++; if (c) printf("  ✓ "); else { fail++; printf("  ✗ "); } printf(__VA_ARGS__); printf("\n"); } while (0)

// The hooks, recorded
uint32_t hid_key_mask(const char *name) { return !strcmp(name, "A") ? 1 : !strcmp(name, "ZR") ? 1u << 9 : !strcmp(name, "LSL") ? 1u << 24 : 0; }
static _Atomic uint64_t g_held, g_ever;
void hid_cmd_keys(uint64_t down, uint64_t up) { atomic_fetch_or(&g_held, down); atomic_fetch_or(&g_ever, down); atomic_fetch_and(&g_held, ~up); }
static _Atomic uint64_t g_frame;
uint64_t dm_nvn_frame_count(void) { return g_frame; }
static _Atomic int g_shots, g_threads, g_quit, g_hlecount, g_pd; static char g_shot_path[CMD_LINE];
void dm_gfx_shot_at(long k, const char *path) { (void)k; strlcpy(g_shot_path, path, sizeof g_shot_path); g_shots++; }
void mtl_passdump_next(long k) { g_pd = (int)k; }
void svc_thread_dump(void) { g_threads++; }
long dm_memsnap_write(const char *path, long frame) { (void)path; (void)frame; return 0; }
void hlecount_flush(void) { g_hlecount++; }
void dm_host_shutdown(const char *why) { (void)why; g_quit++; }
void sead_heaps_print(void) {}
void sead_heap_of(uint64_t addr) { (void)addr; }

static int parse_ok(const char *line, int kind, uint32_t mask, long v, const char *path) {
    dm_cmd c; const char *why; if (cmd_parse(line, &c, &why)) return 0;
    return c.kind == kind && c.mask == mask && c.n == v && (!path || !strcmp(c.path, path));
}
static int parse_bad(const char *line, const char *want) { dm_cmd c; const char *why; return cmd_parse(line, &c, &why) && why && strstr(why, want); }

static int g_fd;
static void put(const char *s) { if (write(g_fd, s, strlen(s)) != (ssize_t)strlen(s)) abort(); }
static int until(_Atomic int *v, int want, int ms) { for (int i = 0; i < ms / 5; i++) { if (*v >= want) return 1; usleep(5000); } return *v >= want; }
static long g_ran = -1;
static void *loop_thread(void *a) { g_ran = cmd_loop((int)(intptr_t)a); return NULL; }

int main(void) {
    setvbuf(stdout, NULL, _IONBF, 0);
    printf("parser:\n");
    CHECK(parse_ok("key A 300", CMD_KEY, 1, 300, NULL), "key A 300");
    CHECK(parse_ok("key A", CMD_KEY, 1, 200, NULL), "key A: 200 ms by default");
    CHECK(parse_ok("  key\tLSL   50  \r", CMD_KEY, 1u << 24, 50, NULL), "spaces, a tab and a carriage return around the words");
    CHECK(parse_ok("down ZR", CMD_DOWN, 1u << 9, 0, NULL) && parse_ok("up ZR", CMD_UP, 1u << 9, 0, NULL), "down ZR / up ZR");
    CHECK(parse_ok("wait 30", CMD_WAIT, 0, 30, NULL) && parse_ok("sleep 10", CMD_SLEEP, 0, 10, NULL) && parse_ok("passdump 3", CMD_PASSDUMP, 0, 3, NULL), "wait / sleep / passdump");
    CHECK(parse_ok("shot /tmp/a b.png", CMD_SHOT, 0, 0, "/tmp/a b.png") && parse_ok("memsnap /tmp/s", CMD_MEMSNAP, 0, 0, "/tmp/s"), "shot and memsnap keep a path with a space");
    CHECK(parse_ok("heaps", CMD_HEAPS, 0, 0, NULL) && parse_ok("heap 0x1234", CMD_HEAP, 0, 0x1234, NULL) && parse_bad("heap", "address") && parse_bad("heap 0x12z", "address"), "heaps / heap <addr>");
    CHECK(parse_ok("threads", CMD_THREADS, 0, 0, NULL) && parse_ok("hlecount", CMD_HLECOUNT, 0, 0, NULL) && parse_ok("quit", CMD_QUIT, 0, 0, NULL), "threads / hlecount / quit");
    CHECK(parse_ok("", CMD_NONE, 0, 0, NULL) && parse_ok("   ", CMD_NONE, 0, 0, NULL) && parse_ok("# key A", CMD_NONE, 0, 0, NULL), "blank lines and comments do nothing");
    CHECK(parse_bad("key Q 10", "unknown key") && parse_bad("down", "key name") && parse_bad("key A 10 x", "key <name>"), "an unknown key, no key, an extra word");
    CHECK(parse_bad("key A 0", "1-5000") && parse_bad("key A 6000", "1-5000"), "key times outside 1-5000 ms");
    CHECK(parse_bad("wait 0", "1-100000") && parse_bad("wait x", "1-100000") && parse_bad("wait 3x", "1-100000") && parse_bad("passdump 601", "1-600"), "wait and passdump out of range or not numbers");
    CHECK(parse_bad("shot", "path") && parse_bad("threads now", "no argument") && parse_bad("jump", "unknown command") && parse_bad("keyboard A", "unknown command"), "no path, an extra argument, unknown commands");

    printf("loop, following a file:\n");
    char path[1024]; snprintf(path, sizeof path, "%s/t_cmdchan_%d.txt", getenv("TMPDIR") ? getenv("TMPDIR") : "/tmp", getpid());
    g_fd = open(path, O_WRONLY | O_CREAT | O_TRUNC, 0644); int rd = open(path, O_RDONLY); if (g_fd < 0 || rd < 0) { printf("cannot open %s\n", path); return 2; }
    pthread_t t; pthread_create(&t, NULL, loop_thread, (void *)(intptr_t)rd);
    put("# a test\nthr"); usleep(300000);
    CHECK(g_threads == 0, "a line without its newline has not run yet");
    put("eads\n");
    CHECK(until(&g_threads, 1, 2000) && g_threads == 1, "... and runs once, whole, when its newline comes (threads %d)", (int)g_threads);
    put("key A 600\n");
    uint64_t t0 = 0, t1 = 0; for (int i = 0; i < 400 && !t0; i++) { if (g_held == 1) t0 = clock_gettime_nsec_np(CLOCK_UPTIME_RAW); else usleep(5000); }
    CHECK(t0, "key A is held");
    for (int i = 0; i < 800 && !t1; i++) { if (!g_held) t1 = clock_gettime_nsec_np(CLOCK_UPTIME_RAW); else usleep(5000); }
    CHECK(t1 && t1 - t0 >= 500000000ull && g_ever == 1, "... for its time, then released (%.0f ms)", t1 ? (t1 - t0) / 1e6 : -1.0);
    put("wait 3\nshot /x/y.png\n"); usleep(200000);
    CHECK(g_shots == 0, "wait 3: the next line waits for frames");
    g_frame += 2; usleep(100000);
    CHECK(g_shots == 0, "... still after two frames");
    g_frame += 1;
    CHECK(until(&g_shots, 1, 2000) && !strcmp(g_shot_path, "/x/y.png"), "... runs after the third (%s)", g_shot_path);
    put("bogus line\nthreads\n");
    CHECK(until(&g_threads, 2, 2000), "a malformed line is skipped, the next one runs");
    char big[1500]; memset(big, 'x', sizeof big - 2); big[sizeof big - 2] = '\n'; big[sizeof big - 1] = 0; put(big); put("threads\n");
    CHECK(until(&g_threads, 3, 2000) && g_threads == 3, "a line over 1023 bytes is skipped, the next one runs");
    put("passdump 4\nhlecount\nquit\nthreads\n");
    CHECK(until(&g_quit, 1, 2000), "quit");
    pthread_join(t, NULL);
    CHECK(g_pd == 4 && g_hlecount == 1, "passdump 4 and hlecount ran before it");
    CHECK(g_ran == 9 && g_threads == 3, "the loop ended at quit: 9 lines run, the line after quit not (%ld)", g_ran);
    close(g_fd); close(rd); unlink(path);
    printf("== %d checks, %d failed ==\n", n, fail); return fail != 0;
}
