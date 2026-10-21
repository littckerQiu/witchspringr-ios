// Save write and save transaction unit test (takes seconds): includes hle_fs.c directly and calls its static implementation; pwrite is replaced by a scriptable fake.
// All expected values are hand-written from the semantics, not computed by calling the implementation under test:
//   (1) pwrite returns 0 (can happen when the disk is full) -> WriteFile returns failure after one call (it used to loop forever here);
//   (2) pwrite writes in pieces (3 bytes first, then the rest) -> success and the file content is complete;
//   (3) transaction: the failure in (1) causes this transaction's Commit to be rejected and the working directory to return to the committed version; the next transaction writes in the working directory, the committed directory is still the old version before Commit and the new version after Commit;
//   (4) DM_TEST_FS_FAIL=write:N:errno makes only the Nth save write fail, with writes before and after proceeding normally; that transaction's Commit is rejected, the committed version is unchanged, and the front end receives one notification;
//      the next transaction commits normally, and the final save = the content of the next transaction;
//   (5) remounting discards uncommitted content.
#include <stdio.h>
#include <pthread.h>
#include <stdlib.h>
#include <string.h>
#include <sys/types.h>
static ssize_t fake_pwrite(int fd, const void *buf, size_t n, off_t off);
#define pwrite fake_pwrite
#include "../hle_fs.c"
#undef pwrite
ssize_t pwrite(int, const void *, size_t, off_t);

struct dm_flags g_flag; uint64_t g_t0_ns; uint64_t now_ns(void) { return 0; } void dm_prof_mark(const char *s) { (void)s; }   // stubs for log timestamps and the read path (not used by the write path)
void dm_prof_add(int id, uint64_t ns, uint64_t b) { (void)id; (void)ns; (void)b; } void dm_guest_write_prepare(void *a, size_t n) { (void)a; (void)n; }
void dm_fs_save_poison(int e);
extern int g_nfail, g_lasterr;                                        // front-end notification count (the strong implementation in t_fs_stub.c replaces the weak one in hle_fs.c)
static int g_mode, g_calls;                   // 0 write normally; 1 always return 0; 2 write only 3 bytes the first time
static ssize_t fake_pwrite(int fd, const void *buf, size_t n, off_t off) {
    g_calls++;
    if (g_mode == 1) { if (g_calls > 1000) { printf("  FAIL pwrite retried over 1000 times after returning 0 (endless loop)\n"); exit(1); } return 0; }
    if (g_mode == 2 && g_calls == 1 && n > 3) n = 3;
    return pwrite(fd, buf, n, off);
}
static int fails, checks;
#define CHECK(c, ...) do { checks++; if (!(c)) { fails++; printf("  FAIL "); } else printf("  ok "); printf(__VA_ARGS__); printf("\n"); } while (0)
static void put(const char *p, const char *s) { FILE *f = fopen(p, "w"); fputs(s, f); fclose(f); }
static int same(const char *p, const char *s) {
    char b[64] = {0}; FILE *f = fopen(p, "r"); if (!f) return 0; size_t k = fread(b, 1, sizeof b - 1, f); fclose(f);
    return k == strlen(s) && !memcmp(b, s, k);
}
static Result write_save(const char *path, const char *s) {           // open -> set size -> write -> close
    uint64_t h; Result r = h_fs_OpenFile(&h, path, MODE_WRITE); if (r) return r;
    h_fs_SetFileSize(h, (int64_t)strlen(s));
    r = h_fs_WriteFile(h, 0, s, strlen(s), NULL); h_fs_CloseFile(h); return r;
}
static int read_fs(const char *path, char *out, size_t n) { uint64_t h; size_t got = 0; if (h_fs_OpenFile(&h, path, MODE_READ)) return 0; Result r = h_fs_ReadFile(&got, h, 0, out, n - 1); h_fs_CloseFile(h); out[got] = 0; return !r; }

static void *commit_later(void *a) { (void)a; usleep(150000); h_fs_Commit("save"); return NULL; }
int main(void) {
    char root[1024], save[1100], work[1200], p[1200];
    const char *sp = getenv("TMPDIR"); snprintf(root, sizeof root, "%s/t_fs.XXXXXX", sp ? sp : "/private/tmp");
    if (!mkdtemp(root)) { perror("mkdtemp"); return 1; }
    char rom[1100], overlay[1100], rdata[1200], odata[1200], fn[1300], got[64];
    snprintf(rom, sizeof rom, "%s/rom", root); snprintf(overlay, sizeof overlay, "%s/overlay", root); snprintf(rdata, sizeof rdata, "%s/data", rom); snprintf(odata, sizeof odata, "%s/data", overlay);
    mkdir(rom, 0755); mkdir(overlay, 0755); mkdir(rdata, 0755); mkdir(odata, 0755);
    snprintf(fn, sizeof fn, "%s/same", rdata); put(fn, "base"); snprintf(fn, sizeof fn, "%s/same", odata); put(fn, "overlay"); snprintf(fn, sizeof fn, "%s/base", rdata); put(fn, "only-base"); snprintf(fn, sizeof fn, "%s/over", odata); put(fn, "only-overlay");
    {   // a directory with more names than the old listing cap (2048), made before the mount builds the RomFS name index (used below)
        char big[1300], obig[1300]; snprintf(big, sizeof big, "%s/big", rom); snprintf(obig, sizeof obig, "%s/big", overlay); mkdir(big, 0755); mkdir(obig, 0755);
        for (int i = 0; i < 3000; i++) { snprintf(fn, sizeof fn, "%s/f%04d", big, i); put(fn, "b"); }
        for (int i = 2995; i < 3005; i++) { snprintf(fn, sizeof fn, "%s/f%04d", obig, i); put(fn, "ov"); } }
    setenv("DM_ROMFS", rom, 1); setenv("DM_ROMFS_OVERLAY", overlay, 1); CHECK(h_fs_MountRom("rom", NULL, 0) == RES_OK, "mount the RomFS with an overlay");
    CHECK(read_fs("rom:/data/same", got, sizeof got) && !strcmp(got, "overlay"), "the overlay file wins"); CHECK(read_fs("rom:/data/base", got, sizeof got) && !strcmp(got, "only-base"), "falls back to the base without an overlay file");
    uint64_t rh; CHECK(h_fs_OpenFile(&rh, "rom:/data/same", MODE_WRITE) == RES_FAIL, "both layers refuse writes");
    {   // A file in the overlay (dm_overlay_file): layers joined by colons, searched in order, earlier ones win
        char l2[1100], two[2300], want[1300]; snprintf(l2, sizeof l2, "%s/pack", root); mkdir(l2, 0755); snprintf(two, sizeof two, "%s:%s", overlay, l2); setenv("DM_ROMFS_OVERLAY", two, 1);
        snprintf(fn, sizeof fn, "%s/mark", overlay); put(fn, "1"); snprintf(fn, sizeof fn, "%s/only2", l2); put(fn, "2"); snprintf(fn, sizeof fn, "%s/mark", l2); put(fn, "2");
        snprintf(want, sizeof want, "%s/mark", overlay); CHECK(dm_overlay_file("mark", p, sizeof p) == 1 && !strcmp(p, want), "in both layers: the first");
        snprintf(want, sizeof want, "%s/only2", l2); CHECK(dm_overlay_file("only2", p, sizeof p) == 1 && !strcmp(p, want), "only in the second layer: the second");
        snprintf(want, sizeof want, "%s/data/over", overlay); CHECK(dm_overlay_file("data/over", p, sizeof p) == 1 && !strcmp(p, want), "relative path with a subdirectory");
        CHECK(dm_overlay_file("none", p, sizeof p) == 0 && !p[0], "in no layer: 0, output cleared");
        setenv("DM_ROMFS_OVERLAY", overlay, 1); snprintf(want, sizeof want, "%s/mark", overlay); CHECK(dm_overlay_file("mark", p, sizeof p) == 1 && !strcmp(p, want), "a single layer works the same");
        unsetenv("DM_ROMFS_OVERLAY"); CHECK(dm_overlay_file("mark", p, sizeof p) == 0, "no overlay set: 0"); setenv("DM_ROMFS_OVERLAY", overlay, 1); }
    {   // An overlaid directory with more names than the old cap of 2048: 3000 in the base, 10 in the overlay of which 5 are also in the base: 3005,
        // each once, the overlay's 10 with the overlay's size (2 bytes against the base's 1)
        uint64_t dh; int64_t cnt = -1, total = 0, n = 0; static DirectoryEntry de[512]; static unsigned char seen[3005]; int dups = 0, bad = 0, ovsize = 0;
        Result ro = h_fs_OpenDirectory(&dh, "rom:/big", DIRMODE_FILE); CHECK(ro == RES_OK, "open an overlaid directory of 3005 names");
        if (ro == RES_OK) {
        CHECK(h_fs_DirCount(&cnt, dh) == RES_OK && cnt == 3005, "entry count 3005 (got %lld)", (long long)cnt);
        do { n = 0; if (h_fs_ReadDirectory(&n, de, dh, 512)) break;
             for (int64_t i = 0; i < n; i++) { int k = atoi(de[i].name + 1); if (de[i].name[0] != 'f' || k < 0 || k >= 3005) { bad++; continue; } dups += seen[k]++ > 0; if (k >= 2995 && de[i].size == 2) ovsize++; }
             total += n; } while (n);
        CHECK(total == 3005 && !dups && !bad, "ReadDirectory hands out all 3005, each once (got %lld, %d twice, %d unknown)", (long long)total, dups, bad);
        CHECK(ovsize == 10, "the overlay's 10 carry the overlay's size (got %d)", ovsize);
        h_fs_CloseDirectory(dh); }
    }
    g_nmnt = 0;
    snprintf(save, sizeof save, "%s/save", root); snprintf(work, sizeof work, "%s.work", save);
    mkdir(save, 0755); snprintf(p, sizeof p, "%s/a", save); put(p, "old");
    setenv("DM_SAVE", save, 1); setenv("DM_TEST_FS_FAIL", "write:5:28", 1);   // the 5th save write fails, errno 28 = ENOSPC
    CHECK(h_fs_MountSave("save", NULL) == RES_OK, "mount the save");

    // Save write count: (1)=1st (2)=2nd (3)=3rd (4)=4th/5th/6th/7th (5)=8th
    printf("1 pwrite returns 0\n");
    g_mode = 1; g_calls = 0;
    CHECK(write_save("save:/a", "xyz") == RES_FAIL, "WriteFile fails with 0x2A2");
    CHECK(g_calls == 1, "pwrite called once (%d times; it used to retry forever)", g_calls);

    printf("2 pwrite writes in pieces\n");
    g_mode = 2; g_calls = 0;
    CHECK(write_save("save:/a", "abcdefg") == RES_OK, "WriteFile succeeds");
    CHECK(g_calls == 2, "pwrite called twice (3 bytes + 4 bytes; got %d)", g_calls);
    snprintf(p, sizeof p, "%s/a", work); CHECK(same(p, "abcdefg"), "the working directory has the whole abcdefg");
    g_mode = 0;

    printf("3 transactions\n");
    CHECK(h_fs_Commit("save") == RES_FAIL && g_nfail == 1 && g_lasterr == ENOSPC, "the transaction of 1 and 2 is refused, the front end is told once with errno=ENOSPC (%d times, errno=%d)", g_nfail, g_lasterr);
    snprintf(p, sizeof p, "%s/a", work); CHECK(same(p, "old"), "working directory discarded, back to the committed old");
    CHECK(write_save("save:/a", "new") == RES_OK, "next transaction: write new");
    snprintf(p, sizeof p, "%s/a", save); CHECK(same(p, "old"), "before Commit the committed directory still has old");
    CHECK(h_fs_Commit("save") == RES_OK, "Commit");
    CHECK(same(p, "new"), "after Commit the committed directory has new");
    snprintf(p, sizeof p, "%s.new", save); CHECK(access(p, F_OK) != 0, "the swapped-out copy is deleted (no .new left)");

    printf("4 DM_TEST_FS_FAIL=write:5:28\n");
    CHECK(write_save("save:/b", "4") == RES_PATH_NOT_FOUND, "(b does not exist: open fails, no write counted)");
    h_fs_CreateFile("save:/b", 0);
    CHECK(write_save("save:/b", "4") == RES_OK, "write 4 succeeds");
    errno = 0; CHECK(write_save("save:/b", "5") == RES_FAIL && errno == 28, "write 5 fails with errno=28 (errno=%d)", errno);
    CHECK(write_save("save:/b", "6") == RES_OK, "write 6 succeeds");
    CHECK(h_fs_Commit("save") == RES_FAIL && g_nfail == 2 && g_lasterr == 28, "that transaction is refused, the front end is told errno=28 (%d times in all)", g_nfail);
    snprintf(p, sizeof p, "%s/b", save); CHECK(access(p, F_OK) != 0, "committed directory unchanged (no b)");
    snprintf(p, sizeof p, "%s/b", work); CHECK(access(p, F_OK) != 0, "working directory discarded (no b)");
    snprintf(p, sizeof p, "%s/a", save); CHECK(same(p, "new"), "committed a is still new");
    h_fs_CreateFile("save:/b", 0);
    CHECK(write_save("save:/b", "7") == RES_OK && h_fs_Commit("save") == RES_OK, "next transaction: write b=7, Commit succeeds");
    snprintf(p, sizeof p, "%s/b", save); CHECK(same(p, "7"), "committed b = 7 at the end (the next transaction)");
    CHECK(g_nfail == 2, "a successful transaction sends no notice (still %d in all)", g_nfail);

    printf("5 remounting discards uncommitted content\n");
    CHECK(write_save("save:/a", "v9") == RES_OK, "write a=v9 without commit");
    g_nmnt = 0;                                                        // simulate a process restart: clear the mount table
    CHECK(h_fs_MountSave("save", NULL) == RES_OK, "remount");
    snprintf(p, sizeof p, "%s/a", work); CHECK(same(p, "new"), "working a is back to the committed new");
    snprintf(p, sizeof p, "%s/b", work); CHECK(same(p, "7"), "working b = the committed 7");

    // From upstream d2r-mobile b94670c (MIT): failing steps of a save transaction no longer end the process
    printf("6 failed steps do not exit (DM_TEST_FS_FAILAT)\n");
    unsetenv("DM_TEST_FS_FAIL");
    // 6a re-cloning after a refused commit fails: no exit, the working directory is left alone, the committed version is unchanged; the next commit
    //    is refused again and re-clones; the transaction after that commits
    setenv("DM_TEST_FS_FAILAT", "reclone:1", 1);
    CHECK(write_save("save:/a", "bad") == RES_OK, "write a=bad");
    dm_fs_save_poison(ENOSPC); int nf0 = g_nfail;
    CHECK(h_fs_Commit("save") == RES_FAIL && g_nfail == nf0 + 1, "refused (re-clone injected to fail), still running, front end told once");
    snprintf(p, sizeof p, "%s/a", save); CHECK(same(p, "new"), "committed a is still new");
    snprintf(p, sizeof p, "%s/a", work); CHECK(same(p, "bad"), "the working directory was not deleted (a is still bad)");
    CHECK(h_fs_Commit("save") == RES_FAIL && g_nfail == nf0 + 2, "still tainted: the next commit is refused as well");
    snprintf(p, sizeof p, "%s/a", work); CHECK(same(p, "new"), "this time the re-clone worked: working a is back to new");
    snprintf(p, sizeof p, "%s.re", work); CHECK(access(p, F_OK) != 0, "no .re left over");
    CHECK(write_save("save:/a", "good") == RES_OK && h_fs_Commit("save") == RES_OK, "next transaction writes a=good and commits");
    snprintf(p, sizeof p, "%s/a", save); CHECK(same(p, "good"), "committed a = good");
    // 6b writing the guest name after a rename fails and so does the undo: no exit; the file is in the transactional save, so this transaction's
    //    commit is refused and the committed version is unchanged; after the re-clone everything works
    setenv("DM_TEST_FS_FAILAT", "guestname:1,renameback:1", 1);
    h_fs_CreateFile("save:/c", 0); CHECK(write_save("save:/c", "c") == RES_OK, "write c");
    CHECK(h_fs_RenameFile("save:/c", "save:/d") != RES_OK, "rename c → d fails (both steps injected), still running");
    nf0 = g_nfail; CHECK(h_fs_Commit("save") == RES_FAIL && g_nfail == nf0 + 1, "this transaction's commit is refused");
    snprintf(p, sizeof p, "%s/c", save); CHECK(access(p, F_OK) != 0, "no c in the committed directory");
    snprintf(p, sizeof p, "%s/d", save); CHECK(access(p, F_OK) != 0, "no d in the committed directory");
    snprintf(p, sizeof p, "%s/a", save); CHECK(same(p, "good"), "committed a is still good");
    CHECK(write_save("save:/a", "ok2") == RES_OK && h_fs_Commit("save") == RES_OK, "the next transaction commits");
    // 6c cloning the working directory at mount fails: no exit; the committed directory is mounted read-only. Reads work, writes fail, commits are
    //    no-ops, the committed version is unchanged, the front end is told once; the next normal mount works as before
    setenv("DM_TEST_FS_FAILAT", "mountclone:1", 1); g_nmnt = 0; nf0 = g_nfail;
    snprintf(p, sizeof p, "rm -rf '%s'", work); system(p);
    CHECK(h_fs_MountSave("save", NULL) == RES_OK && g_nfail == nf0 + 1, "the mount succeeds, the front end is told once (%d times)", g_nfail - nf0);
    CHECK(read_fs("save:/a", got, sizeof got) && !strcmp(got, "ok2"), "the committed a=ok2 reads on the read-only mount (read %s)", got);
    CHECK(write_save("save:/a", "zzz") != RES_OK, "writes fail");
    // 6d (this host): creating what exists on a read-only mount answers "already exists"; null handles (a failed open) fail cleanly
    CHECK(h_fs_CreateFile("save:/a", 0) == RES_PATH_EXISTS, "CreateFile of an existing file on the read-only mount → PathAlreadyExists");
    CHECK(h_fs_CreateFile("save:/zz", 0) == RES_FAIL, "CreateFile of a new file on the read-only mount → failure");
    CHECK(h_fs_CreateDirectory("save:/a") == RES_PATH_EXISTS, "CreateDirectory over an existing entry → PathAlreadyExists");
    { size_t n0 = 99; int64_t sz0 = -1, dn = 99; DirectoryEntry de[2];
      CHECK(h_fs_ReadFile(&n0, 0, 0, got, sizeof got) == RES_FAIL && n0 == 0, "ReadFile on the null handle → failure, 0 bytes");
      CHECK(h_fs_WriteFile(0, 0, "x", 1, NULL) == RES_FAIL, "WriteFile on the null handle → failure");
      CHECK(h_fs_GetFileSize(&sz0, 0) == RES_FAIL && h_fs_SetFileSize(0, 1) == RES_FAIL, "GetFileSize / SetFileSize on the null handle → failure");
      h_fs_CloseFile(0);
      CHECK(h_fs_ReadDirectory(&dn, de, 0, 2) == RES_FAIL && dn == 0, "ReadDirectory on the null handle → failure, 0 entries");
      h_fs_CloseDirectory(0); CHECK(1, "CloseFile / CloseDirectory on the null handle return"); }
    CHECK(h_fs_Commit("save") == RES_OK, "commit is a no-op");
    snprintf(p, sizeof p, "%s/a", save); CHECK(same(p, "ok2"), "committed a is still ok2");
    unsetenv("DM_TEST_FS_FAILAT"); g_nmnt = 0;
    CHECK(h_fs_MountSave("save", NULL) == RES_OK && write_save("save:/a", "ok3") == RES_OK && h_fs_Commit("save") == RES_OK, "without the injection the remount is transactional again: a=ok3 commits");
    snprintf(p, sizeof p, "%s/a", save); CHECK(same(p, "ok3"), "committed a = ok3");

    // Quitting while the game saves (dm_fs_save_wait): nothing pending returns at once; a transaction with writes and no commit is waited for until
    // it commits (here 150 ms later, from another thread) or until the limit, then reported as still pending
    { int still = 9; double w = dm_fs_save_wait(15, &still);
      CHECK(w < 0.05 && still == 0, "no save in progress: returns at once (%.3f s), nothing pending", w);
      CHECK(write_save("save:/a", "ok4") == RES_OK, "a save write opens a transaction");
      w = dm_fs_save_wait(0.3, &still);
      CHECK(w >= 0.29 && w < 0.5 && still == 1, "never committed: waits the 0.3 s limit (%.3f s) and reports it pending", w);
      pthread_t ct; pthread_create(&ct, NULL, commit_later, NULL);
      w = dm_fs_save_wait(15, &still); pthread_join(ct, NULL);
      CHECK(w >= 0.12 && w < 1.0 && still == 0, "committed 150 ms later: the wait ends then (%.3f s), nothing pending", w);
      snprintf(p, sizeof p, "%s/a", save); CHECK(same(p, "ok4"), "the waited-for save is committed: a = ok4"); }

    // Language switch rewriting the settings file (settings_lang_apply): expected values computed by hand from the rule -- only when it "does not match the switch" are Language / VoiceLanguage changed to 0 (English) or 8 (Simplified Chinese); other keys and other languages are untouched

    char cmd[1200]; snprintf(cmd, sizeof cmd, "rm -rf '%s'", root); system(cmd);
    printf("t_fs: %d checks, %d failed\n", checks, fails);
    return fails != 0;
}
