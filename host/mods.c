// User mod folders (plan item 54, after SkyRecomp's runtime/mods.c, Apolinario-coder/SkyRecomp, MIT, with the Atmosphère layout): DM_MODS=<dir>
// (on iOS Documents/mods when it exists) puts each mod's RomFS in front of the game's own, as layers of DM_ROMFS_OVERLAY (hle_fs.c: a file in an
// earlier layer replaces the game's, new files are added, directory listings merge). Each entry of <dir>, sorted by name, the first winning (name
// them 01_..., 02_... to order them), skipped when the name starts with "." or "-" (rename a mod to "-name" to turn it off):
//   <entry>/romfs                                  a mod folder
//   <entry>/contents/<program id>/romfs            an Atmosphère contents folder (the entry "atmosphere" copied from an SD card is this)
//   <entry>/atmosphere/contents/<program id>/romfs a mod as it is shipped for Atmosphère
//   <entry> itself                                 loose files, when it has none of romfs / contents / atmosphere / exefs / exefs_patches
// The program ID is matched without regard to case (iOS file systems tell cases apart; mods spell it either way); other games' folders are left out.
// Code (exefs, exefs_patches) is not applied: the modules are rewritten for the host. The log lists each layer with its file count, files that
// replace the game's, and files two mods both have (the earlier one is used). Checked by host/tests/t_mods.c.
#include "dm.h"
#include "game.h"
#include <dirent.h>
#include <sys/stat.h>
#include <unistd.h>

static int is_dir(const char *p) { struct stat st; return !stat(p, &st) && S_ISDIR(st.st_mode); }
static int name_cmp(const void *a, const void *b) { return strcmp(*(char *const *)a, *(char *const *)b); }
// The directory in dir named like `name`, case aside, with its own spelling in out (an exact match first): the path then holds on a file system
// that tells cases apart (iOS) even when the Mac's does not
static int child_ci(const char *dir, const char *name, char *out, size_t n) {
#ifndef DM_TEST_MODS_CASE   // negative control of t_mods only: the asked spelling
    DIR *d = opendir(dir); if (!d) return 0;
    struct dirent *e; char got[256] = ""; int exact = 0;
    while ((e = readdir(d))) {
        char p[2048]; snprintf(p, sizeof p, "%s/%s", dir, e->d_name);
        if (!strcmp(e->d_name, name) && is_dir(p)) { strlcpy(got, e->d_name, sizeof got); exact = 1; break; }
        if (!got[0] && !strcasecmp(e->d_name, name) && is_dir(p)) strlcpy(got, e->d_name, sizeof got);
    }
    closedir(d); (void)exact;
    if (!got[0]) return 0;
    snprintf(out, n, "%s/%s", dir, got); return 1;
#else
    snprintf(out, n, "%s/%s", dir, name); return is_dir(out);
#endif
}
static int count_files(const char *dir, int depth) {
    DIR *d = opendir(dir); if (!d || depth > 32) { if (d) closedir(d); return 0; }
    struct dirent *e; int n = 0; char p[2048];
    while ((e = readdir(d))) {
        if (e->d_name[0] == '.') continue;
        snprintf(p, sizeof p, "%s/%s", dir, e->d_name); struct stat st;
        if (stat(p, &st)) continue;
        n += S_ISDIR(st.st_mode) ? count_files(p, depth + 1) : S_ISREG(st.st_mode);
    }
    closedir(d); return n;
}
// The RomFS root of one entry for program id `pid` (16 hex digits), or 0 (none: only code, another game, nothing)
static int mod_romfs(const char *entry, const char *pid, char *out, size_t n) {
    char a[1400], b[1400], c[1400];
    if (child_ci(entry, "romfs", out, n)) return 1;
    if (child_ci(entry, "contents", a, sizeof a) && child_ci(a, pid, b, sizeof b) && child_ci(b, "romfs", out, n)) return 1;
    if (child_ci(entry, "atmosphere", a, sizeof a) && child_ci(a, "contents", b, sizeof b) && child_ci(b, pid, c, sizeof c) && child_ci(c, "romfs", out, n)) return 1;
    static const char *code[] = {"contents", "atmosphere", "exefs", "exefs_patches"};
    for (int i = 0; i < 4; i++) if (child_ci(entry, code[i], a, sizeof a)) return 0;
    snprintf(out, n, "%s", entry); return 1;
}
// Files of `layer` (relative path) that an earlier layer or the game already has: counts, and the first few named
typedef struct { const char *game; const char *const *earlier; int nearlier; int replaced, shadowed; char first_shadow[256]; } walk_t;
static void walk(const char *root, const char *rel, walk_t *w, int depth) {
    char p[2048]; snprintf(p, sizeof p, "%s%s%s", root, *rel ? "/" : "", rel);
    DIR *d = opendir(p); if (!d || depth > 32) { if (d) closedir(d); return; }
    struct dirent *e;
    while ((e = readdir(d))) {
        if (e->d_name[0] == '.') continue;
        char r[1024], f[2048]; snprintf(r, sizeof r, "%s%s%s", rel, *rel ? "/" : "", e->d_name); snprintf(f, sizeof f, "%s/%s", root, r);
        struct stat st; if (stat(f, &st)) continue;
        if (S_ISDIR(st.st_mode)) { walk(root, r, w, depth + 1); continue; }
        for (int i = 0; i < w->nearlier; i++) { char g[2048]; snprintf(g, sizeof g, "%s/%s", w->earlier[i], r);
            if (!access(g, F_OK)) { if (!w->shadowed++) snprintf(w->first_shadow, sizeof w->first_shadow, "%s", r); break; } }
        if (w->game) { char g[2048]; snprintf(g, sizeof g, "%s/%s", w->game, r); w->replaced += !access(g, F_OK); }
    }
    closedir(d);
}
// The layers of `dir` for program id `pid`, highest priority first, joined by ':' into out (empty: none); returns how many. game: the game's RomFS
// (for the log's counts), may be NULL
int dm_mods_layers(const char *dir, uint64_t pid, const char *game, char *out, size_t n) {
    out[0] = 0;
    DIR *d = opendir(dir); if (!d) return 0;
    char *names[256]; int nn = 0; struct dirent *e;
    while ((e = readdir(d)) && nn < 256) if (e->d_name[0] != '.' && e->d_name[0] != '-') names[nn++] = strdup(e->d_name);
    closedir(d);
    qsort(names, (size_t)nn, sizeof *names, name_cmp);
    char ps[17]; snprintf(ps, sizeof ps, "%016llX", (unsigned long long)pid);
    static char layer[256][1400]; const char *done[256]; int nl = 0; size_t o = 0;
    for (int i = 0; i < nn; i++) {
        char entry[1100]; snprintf(entry, sizeof entry, "%s/%s", dir, names[i]);
        if (!is_dir(entry)) continue;
        if (!mod_romfs(entry, ps, layer[nl], sizeof layer[0])) { LOG("mods: %s: no RomFS for %s (code mods are not applied: the modules are rewritten for the host)", names[i], ps); continue; }
        if (strchr(layer[nl], ':')) { LOG("[red] mods: %s: a path with ':' cannot be a layer, skipped", layer[nl]); continue; }
        size_t l = strlen(layer[nl]);
        if (o + l + 2 > n) { LOG("[red] mods: too many mods for the overlay list (%zu bytes); %s and later left out", n, names[i]); break; }
        walk_t w = {game, done, nl, 0, 0, ""}; walk(layer[nl], "", &w, 0);
        LOG("mods: layer %d %s: %d files, %d of them the game's own (replaced)", nl + 1, layer[nl], count_files(layer[nl], 0), w.replaced);
        if (w.shadowed) LOG("mods:   %d files an earlier mod also has, used from that one (first: %s)", w.shadowed, w.first_shadow);
        if (o) out[o++] = ':';
        memcpy(out + o, layer[nl], l); o += l; out[o] = 0; done[nl] = layer[nl]; nl++;
    }
    for (int i = 0; i < nn; i++) free(names[i]);
    return nl;
}
// At boot (main.c, after the game's environment defaults): the mods' layers in front of DM_ROMFS_OVERLAY
void dm_mods_apply(void) {
    const char *dir = getenv("DM_MODS");
    if (!dir || !*dir) return;
    static char layers[4096]; const char *old = getenv("DM_ROMFS_OVERLAY");
    size_t room = sizeof layers - (old && *old ? strlen(old) + 1 : 0);
    if (room < 64) { LOG("[red] mods: the overlay list is full already"); return; }
    int nl = dm_mods_layers(dir, dm_game.program_id, getenv("DM_ROMFS"), layers, room);
    if (!nl) { LOG("mods: none in %s", dir); return; }
    int had = old && *old;   // (old points into the environment: setenv below may free it)
    if (had) { strlcat(layers, ":", sizeof layers); strlcat(layers, old, sizeof layers); }
    setenv("DM_ROMFS_OVERLAY", layers, 1);
    LOG("mods: %d in front of the game's RomFS%s", nl, had ? " and its own overlay" : "");
}
