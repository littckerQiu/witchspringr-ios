// iCloud sync core (cloudsync.c), seconds: two local directories are two devices, a third is the cloud. Every expectation is worked out by hand from
// the rules in cloudsync.c's header, not taken from running the code.
#include <dirent.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/time.h>
#include <unistd.h>
#include "../cloud.h"

static int fails, checks;
#define CHECK(c, ...) do { checks++; if (!(c)) { fails++; printf("  FAIL "); printf(__VA_ARGS__); printf("\n"); } } while (0)
static char R[512];
static const char *const PAT[] = { "Saves/Game*.sav", "Saves/Global.sav", "Packs/P*" };
enum { NPAT = 3 };
static void path(char *o, const char *dev, const char *rel) { snprintf(o, 1024, "%s/%s/%s", R, dev, rel); }
static void mkparents(const char *p) { char d[1024]; strcpy(d, p); for (char *s = d + strlen(R) + 1; (s = strchr(s, '/')); s++) { *s = 0; mkdir(d, 0755); *s = '/'; } }
static void put(const char *dev, const char *rel, const char *txt, long sec) {   // write a file, modification time sec
    char p[1024]; path(p, dev, rel); mkparents(p);
    FILE *f = fopen(p, "w"); fputs(txt, f); fclose(f);
    struct timeval tv[2] = { { sec, 0 }, { sec, 0 } }; utimes(p, tv);
}
static const char *get(const char *dev, const char *rel) {
    static char b[256]; char p[1024]; path(p, dev, rel); FILE *f = fopen(p, "r"); if (!f) return NULL;
    size_t n = fread(b, 1, 255, f); b[n] = 0; fclose(f); return b;
}
static int eq(const char *a, const char *b) { return a && b && !strcmp(a, b); }
static long mtime(const char *dev, const char *rel) { char p[1024]; struct stat st; path(p, dev, rel); return stat(p, &st) ? -1 : st.st_mtimespec.tv_sec; }
static int exists(const char *p) { struct stat st; return !stat(p, &st); }
static void rm(const char *dev, const char *rel) { char p[1024]; path(p, dev, rel); unlink(p); }
static int dsync(const char *dev, int down, uint64_t now) {
    char s[1024], c[1024], b[1024], t[1024]; path(s, dev, "save"); snprintf(c, sizeof c, "%s/cloud", R); path(b, dev, "bak"); path(t, dev, "state");
    return dm_cloud_sync(s, c, b, t, PAT, NPAT, down, now, NULL);
}
static int count_bak(const char *dev, const char *pre) {
    char d[1024]; path(d, dev, "bak"); DIR *dp = opendir(d); struct dirent *e; int n = 0;
    while (dp && (e = readdir(dp))) n += !strncmp(e->d_name, pre, strlen(pre));
    if (dp) closedir(dp);
    return n;
}
static int cloud_has(const char *pack) { char p[1024]; snprintf(p, sizeof p, "%s/cloud/%s", R, pack); return exists(p); }

int main(void) {
    const char *tmp = getenv("TMPDIR"); snprintf(R, sizeof R, "%s/t_cloudsync.XXXXXX", tmp ? tmp : "/tmp");
    if (!mkdtemp(R)) { perror("mkdtemp"); return 1; }
    { char c[1024]; snprintf(c, sizeof c, "%s/cloud", R); mkdir(c, 0755); }

    // 1. Upload from A, first download on B: same contents and modification time; units outside the patterns stay local
    put("A", "save/Saves/Game001.sav", "a1", 1000); put("A", "save/Saves/Global.sav", "g1", 1000); put("A", "save/Saves/Settings.json", "sa", 1000);
    CHECK(dsync("A", 1, 0) == 2, "1. A uploads two units");
    CHECK(cloud_has("Saves%2FGame001.sav.pack") && cloud_has("Saves%2FGlobal.sav.pack"), "1. packs named with %%2F");
    CHECK(!cloud_has("Saves%2FSettings.json.pack"), "1. Settings.json is not a unit");
    CHECK(dsync("B", 1, 0) == 2 && eq(get("B", "save/Saves/Game001.sav"), "a1") && mtime("B", "save/Saves/Game001.sav") == 1000, "1. B downloads, mtime kept");
    CHECK(get("B", "save/Saves/Settings.json") == NULL, "1. B gets no Settings.json");
    CHECK(dsync("A", 1, 0) == 0 && dsync("B", 1, 0) == 0, "1. nothing more to do");

    // 2. A changes while running (upload only); B at launch takes it, its old copy goes to the backup
    put("A", "save/Saves/Game001.sav", "a2", 2000);
    CHECK(dsync("A", 0, 0) == 1, "2. A uploads while running");
    CHECK(dsync("B", 0, 0) == 0 && eq(get("B", "save/Saves/Game001.sav"), "a1"), "2. B running: local untouched");
    CHECK(dsync("B", 1, 0) == 1 && eq(get("B", "save/Saves/Game001.sav"), "a2"), "2. B at launch downloads a2");
    CHECK(count_bak("B", "Saves%2FGame001.sav-") == 1, "2. B's replaced copy is in the backup");

    // 3. Both change: the newer write wins, the loser is in a backup
    put("A", "save/Saves/Game001.sav", "a3", 3000); put("B", "save/Saves/Game001.sav", "b3", 3500);
    CHECK(dsync("A", 0, 0) == 1, "3. A uploads a3");
    CHECK(dsync("B", 1, 0) == 1 && eq(get("B", "save/Saves/Game001.sav"), "b3"), "3. B (newer) keeps b3 and uploads it");
    CHECK(count_bak("B", "Saves%2FGame001.sav-3000") == 1, "3. the overwritten cloud copy a3 is in B's backup");
    CHECK(dsync("A", 1, 0) == 1 && eq(get("A", "save/Saves/Game001.sav"), "b3"), "3. A at launch takes b3");

    // 4. First sync of a unit with different contents on both sides: the cloud wins at launch, nothing happens while running
    put("C", "save/Saves/Global.sav", "c-own", 9000);
    CHECK(dsync("C", 0, 0) == 0, "4. C running: no action (downloads wait for the launch)");
    CHECK(eq(get("C", "save/Saves/Global.sav"), "c-own"), "4. C running: its own Global.sav untouched");
    CHECK(dsync("C", 1, 0) == 2 && eq(get("C", "save/Saves/Global.sav"), "g1"), "4. C at launch: Game001 downloaded, cloud Global.sav wins although older");
    CHECK(count_bak("C", "Saves%2FGlobal.sav-9000") == 1, "4. C's own copy is in the backup");

    // 5. Deletion while running → marker; other device deletes at launch with a backup; a unit missing at launch is fetched back instead
    put("A", "save/Saves/Game002.sav", "x", 4000); CHECK(dsync("A", 0, 0) == 1, "5. A uploads Game002");
    CHECK(dsync("B", 1, 0) == 1 && eq(get("B", "save/Saves/Game002.sav"), "x"), "5. B gets Game002");
    rm("A", "save/Saves/Game002.sav");
    CHECK(dsync("A", 0, 5000000) == 1, "5. A running: deletion marker");
    CHECK(dsync("B", 1, 0) == 1 && get("B", "save/Saves/Game002.sav") == NULL && count_bak("B", "Saves%2FGame002.sav-") == 1, "5. B deletes, backup kept");
    rm("B", "save/Saves/Global.sav");
    CHECK(dsync("B", 1, 0) == 1 && eq(get("B", "save/Saves/Global.sav"), "g1"), "5. missing at launch: fetched back, not deleted everywhere");

    // 6. Directory units: every file below, nested directories too
    put("A", "save/Packs/P1/a.bin", "pa", 6000); put("A", "save/Packs/P1/sub/b.bin", "pb", 6001); put("A", "save/Packs/Q1/c.bin", "q", 6000);
    CHECK(dsync("A", 0, 0) == 1 && cloud_has("Packs%2FP1.pack") && !cloud_has("Packs%2FQ1.pack"), "6. P1 is one unit, Q1 matches no pattern");
    CHECK(dsync("B", 1, 0) == 1 && eq(get("B", "save/Packs/P1/sub/b.bin"), "pb") && mtime("B", "save/Packs/P1/sub/b.bin") == 6001, "6. B gets the nested file");

    // 7. Backups: the newest 3 per unit are kept
    for (int i = 0; i < 5; i++) {
        char t[16]; snprintf(t, sizeof t, "v%d", i);
        put("A", "save/Saves/Game003.sav", t, 7000 + i); dsync("A", 0, 0); dsync("B", 1, 0);
    }
    CHECK(eq(get("B", "save/Saves/Game003.sav"), "v4") && count_bak("B", "Saves%2FGame003.sav-") == 3, "7. B has v4 and 3 backups (%d)", count_bak("B", "Saves%2FGame003.sav-"));

    // 8. A pack whose file lies outside its unit is refused
    {
        char cp[1024], ap[1024]; snprintf(cp, sizeof cp, "%s/cloud/Saves%%2FGame004.sav.pack", R); snprintf(ap, sizeof ap, "%s/cloud/Saves%%2FGame001.sav.pack", R);
        FILE *a = fopen(ap, "rb"), *b = fopen(cp, "wb"); int ch; while ((ch = fgetc(a)) != EOF) fputc(ch, b); fclose(a); fclose(b);   // Game001's pack under Game004's name
        CHECK(dsync("B", 1, 0) == 0 && get("B", "save/Saves/Game004.sav") == NULL && eq(get("B", "save/Saves/Game001.sav"), "b3"), "8. foreign pack refused, nothing written");
        unlink(cp);
    }

    // 9. '%' in a unit name round-trips
    put("A", "save/Saves/Game%5.sav", "pct", 8000);
    CHECK(dsync("A", 0, 0) == 1 && cloud_has("Saves%2FGame%255.sav.pack"), "9. %% encoded as %%25");
    CHECK(dsync("B", 1, 0) == 1 && eq(get("B", "save/Saves/Game%5.sav"), "pct"), "9. B decodes it");

    // 10. Bad arguments
    { char s[1024]; path(s, "A", "save"); CHECK(dm_cloud_sync(s, s, s, s, PAT, 0, 1, 0, NULL) == -1, "10. no patterns = -1"); }

    printf("t_cloudsync: %d/%d passed\n", checks - fails, checks);
    char cmd[600]; snprintf(cmd, sizeof cmd, "rm -rf '%s'", R); if (!fails) system(cmd);
    return fails != 0;
}
