// RomFS check (romfs_validate.c) against a profile of its own: two key files with exact sizes, and a tree "Data" of 3 files / 10 bytes.
#include "../romfs_validate.h"
#include "../game.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

static const dm_game_file files[] = {{"Data/a.bin", 4}, {"Data/sub/b.bin", 3}, {0, 0}};
const dm_game_profile dm_game = { .id = "test", .title = "Test", .version = "1.0", .romfs_files = files, .romfs_nfiles = 2,
                                  .romfs_tree = "Data", .romfs_tree_files = 3, .romfs_tree_bytes = 10 };
static int fails, checks;
#define CHECK(c, ...) do { checks++; if (!(c)) { fails++; printf("  FAIL "); printf(__VA_ARGS__); printf("\n"); } } while (0)
static char R[512];
static void put(const char *rel, const char *txt) {
    char p[1024]; snprintf(p, sizeof p, "%s/%s", R, rel);
    for (char *s = p + strlen(R) + 1; (s = strchr(s, '/')); s++) { *s = 0; mkdir(p, 0755); *s = '/'; }
    FILE *f = fopen(p, "w"); fputs(txt, f); fclose(f);
}

int main(void) {
    const char *tmp = getenv("TMPDIR"); snprintf(R, sizeof R, "%s/t_romfs.XXXXXX", tmp ? tmp : "/tmp");
    if (!mkdtemp(R)) { perror("mkdtemp"); return 1; }
    char why[512], rep[512];
    CHECK(!dm_romfs_validate(R, why, sizeof why) && !strcmp(why, "missing Data/a.bin"), "empty directory refused: %s", why);
    CHECK(dm_romfs_report(R, rep, sizeof rep) == 3 && strstr(rep, "2 of 2 key files"), "report on an empty directory: %s", rep);
    put("Data/a.bin", "abc");
    CHECK(!dm_romfs_validate(R, why, sizeof why) && strstr(why, "Data/a.bin is 3 bytes, should be 4"), "short key file refused: %s", why);
    put("Data/a.bin", "abcd"); put("Data/sub/b.bin", "xyz");
    CHECK(!dm_romfs_validate(R, why, sizeof why) && strstr(why, "Data has 2 files, 7 bytes; should be 3 files, 10 bytes"), "missing tree file refused: %s", why);
    put("Data/c.bin", "12");
    CHECK(!dm_romfs_validate(R, why, sizeof why) && strstr(why, "9 bytes"), "half-copied tree file refused: %s", why);
    put("Data/c.bin", "123");
    CHECK(dm_romfs_validate(R, why, sizeof why), "complete RomFS accepted: %s", why);
    CHECK(dm_romfs_report(R, rep, sizeof rep) == 0, "report of a complete RomFS: %s", rep);
    put("Data/.DS_Store", "finder");
    CHECK(dm_romfs_validate(R, why, sizeof why), "dot files are not counted: %s", why);
    printf("t_romfs_validate: %d/%d passed\n", checks - fails, checks);
    char cmd[600]; snprintf(cmd, sizeof cmd, "rm -rf '%s'", R); system(cmd);
    return fails != 0;
}
