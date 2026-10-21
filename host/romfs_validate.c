// RomFS check driven by the game profile (game.h): dir = the RomFS root. The key files must have their exact sizes (which also tells the version), and the
// profile's tree directory must hold exactly its file count and byte total (a half-copied file makes the total disagree). Names starting with a dot
// (.DS_Store etc.) are not counted.
#include "romfs_validate.h"
#include "game.h"
#include <dirent.h>
#include <stdio.h>
#include <string.h>
#include <sys/stat.h>

static int tally(const char *root, int *n, long long *bytes) {
    DIR *d = opendir(root); if (!d) return -1;
    struct dirent *e;
    while ((e = readdir(d))) {
        if (e->d_name[0] == '.') continue;
        char p[4096]; snprintf(p, sizeof p, "%s/%s", root, e->d_name);
        struct stat st; if (stat(p, &st)) { closedir(d); return -1; }
        if (S_ISDIR(st.st_mode)) { if (tally(p, n, bytes)) { closedir(d); return -1; } }
        else { (*n)++; *bytes += st.st_size; }
    }
    closedir(d); return 0;
}
// 0 complete, 1 missing, 2 wrong size
static int file_state(const char *dir, const dm_game_file *f, long long *have) {
    char p[4096]; snprintf(p, sizeof p, "%s/%s", dir, f->path); struct stat st; *have = 0;
    if (stat(p, &st) || !S_ISREG(st.st_mode)) return 1;
    *have = (long long)st.st_size; return *have == f->size ? 0 : 2;
}
// 1 = the tree matches (or the profile has none)
static int tree_ok(const char *dir, int *n, long long *bytes) {
    *n = 0; *bytes = 0;
    if (!dm_game.romfs_tree) return 1;
    char p[4096]; snprintf(p, sizeof p, "%s/%s", dir, dm_game.romfs_tree);
    return !tally(p, n, bytes) && *n == dm_game.romfs_tree_files && *bytes == dm_game.romfs_tree_bytes;
}
int dm_romfs_report(const char *dir, char *out, size_t out_n) {
    int bad = 0, n; long long have, bytes;
    for (int i = 0; i < dm_game.romfs_nfiles; i++) if (file_state(dir, &dm_game.romfs_files[i], &have)) bad++;
    int whole = tree_ok(dir, &n, &bytes);
    snprintf(out, out_n, "%s %s: %d of %d key files missing or of the wrong size; %s: %d / %d files, %lld / %lld bytes", dm_game.title, dm_game.version, bad,
             dm_game.romfs_nfiles, dm_game.romfs_tree ? dm_game.romfs_tree : "-", n, dm_game.romfs_tree_files, bytes, dm_game.romfs_tree_bytes);
    return bad + !whole;
}
int dm_romfs_validate(const char *dir, char *why, size_t why_n) {
    for (int i = 0; i < dm_game.romfs_nfiles; i++) {
        const dm_game_file *f = &dm_game.romfs_files[i]; long long have; int st = file_state(dir, f, &have);
        if (st == 1) { snprintf(why, why_n, "missing %s", f->path); return 0; }
        if (st == 2) { snprintf(why, why_n, "%s is %lld bytes, should be %lld (not fully copied, or another version)", f->path, have, f->size); return 0; }
    }
    int n; long long bytes;
    if (!tree_ok(dir, &n, &bytes)) {
        snprintf(why, why_n, "%s has %d files, %lld bytes; should be %d files, %lld bytes (not fully copied)", dm_game.romfs_tree, n, bytes,
                 dm_game.romfs_tree_files, dm_game.romfs_tree_bytes); return 0; }
    snprintf(why, why_n, "%d key files of the right size; %s complete (%d files, %lld bytes)", dm_game.romfs_nfiles, dm_game.romfs_tree ? dm_game.romfs_tree : "-", n, bytes);
    return 1;
}
