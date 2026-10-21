// iCloud save sync core: compares and moves files between the local save directory and one cloud directory. No iCloud API here: cloud.m finds the
// directory in the ubiquity container, makes sure the packs are downloaded and then calls dm_cloud_sync. tests/t_cloudsync.c uses a local directory.
//
// Units: the game profile's save_sync patterns (game.json), relative to the save root, with a glob in the last path component only
// ("Saves_v1/GameSave*.nson"). Every regular file or directory matching a pattern is one unit; a directory unit holds all files below it.
// Nothing else in the save is synced (settings follow the device).
// Cloud: one pack per unit, <unit>.pack, with '/' in the unit path written as %2F and '%' as %25. A pack holds all files of the unit and is replaced
// whole, so old and new files never mix. A deletion marker is a pack with no files and the deleted flag.
// Timestamp: the newest modification time of the unit's files (ms), i.e. when the game last wrote it. A download restores every file's modification
// time from the pack, so both sides measure the same timestamp.
// State file: per unit, the digest and timestamp at the last sync; it tells local changes from cloud changes. One side changed: take that side.
// Both changed: the newer timestamp wins.
// First sync of a unit (no state record) with different contents on the two sides: the cloud wins; the local copy goes to the backup. While the game
// runs nothing happens until the next launch. Local is uploaded when the cloud has nothing.
// Nothing is lost: a copy that gets replaced or deleted is renamed into <backup>/<unit>-<timestamp>/ (the newest 3 per unit are kept); if that
// fails, nothing is replaced or deleted this time.
// allow_down = 0 (game running, after a save commit): upload only, the local save is never touched. Deletion markers are written only then.
#include <dirent.h>
#include <errno.h>
#include <fnmatch.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/time.h>
#include <time.h>
#include <unistd.h>
#include "cloud.h"
#include "dm.h"

#define MAXF 256       // files per unit
#define MAXU 512       // units per sync
#define UNIT_LEN 256   // unit path
typedef struct { char path[UNIT_LEN]; uint64_t mt; uint32_t size; uint8_t *data; } cs_file;   // path: relative to the save root
typedef struct { int n, tomb; uint64_t stamp, hash; cs_file f[MAXF]; } cs_unit;
static const char k_magic[8] = "DMPK1\n\0\0";

static void unit_free(cs_unit *u) { for (int i = 0; i < u->n; i++) free(u->f[i].data); u->n = 0; }
static uint64_t fnv(uint64_t h, const void *p, size_t n) { const uint8_t *b = p; for (size_t i = 0; i < n; i++) { h ^= b[i]; h *= 0x100000001b3ull; } return h; }
static int cmp_file(const void *a, const void *b) { return strcmp(((const cs_file *)a)->path, ((const cs_file *)b)->path); }
// Sort by path, then digest (paths + contents, not modification times) and timestamp
static void unit_finish(cs_unit *u) {
    qsort(u->f, (size_t)u->n, sizeof *u->f, cmp_file); u->hash = 0xcbf29ce484222325ull; u->stamp = 0;
    for (int i = 0; i < u->n; i++) {
        u->hash = fnv(u->hash, u->f[i].path, strlen(u->f[i].path) + 1); u->hash = fnv(u->hash, u->f[i].data, u->f[i].size);
        if (u->f[i].mt > u->stamp) u->stamp = u->f[i].mt;
    }
}
static int read_file(const char *full, const char *rel, cs_unit *u) {
    struct stat st; if (u->n >= MAXF || stat(full, &st) || !S_ISREG(st.st_mode) || st.st_size > (64 << 20)) return -1;
    FILE *f = fopen(full, "rb"); if (!f) return -1;
    cs_file *x = &u->f[u->n]; x->data = malloc((size_t)st.st_size + 1); x->size = (uint32_t)st.st_size;
    int ok = x->data && fread(x->data, 1, x->size, f) == x->size; fclose(f);
    if (!ok) { free(x->data); return -1; }
    strlcpy(x->path, rel, sizeof x->path); x->mt = (uint64_t)st.st_mtimespec.tv_sec * 1000 + (uint64_t)st.st_mtimespec.tv_nsec / 1000000; u->n++;
    return 0;
}
static int read_tree(const char *root, const char *rel, cs_unit *u, int depth) {   // every regular file below root/rel
    char d[1300]; snprintf(d, sizeof d, "%s/%s", root, rel); DIR *dp = opendir(d); struct dirent *e; int r = 0;
    if (!dp || depth > 8) { if (dp) closedir(dp); return -1; }
    while ((e = readdir(dp))) {
        if (e->d_name[0] == '.') continue;
        char full[1600], rp[UNIT_LEN + 300]; struct stat st;
        snprintf(full, sizeof full, "%s/%s", d, e->d_name); snprintf(rp, sizeof rp, "%s/%s", rel, e->d_name);
        if (stat(full, &st)) continue;
        if (S_ISDIR(st.st_mode)) { if (read_tree(root, rp, u, depth + 1)) r = -1; }
        else if (S_ISREG(st.st_mode) && (strlen(rp) >= UNIT_LEN || read_file(full, rp, u))) r = -1;
    }
    closedir(dp); return r;
}

// ---- Units and patterns
static int unit_matches(const char *unit, const char *const *pat, int npat) {
    if (!unit[0] || unit[0] == '/' || strstr(unit, "..") || strlen(unit) >= UNIT_LEN) return 0;
    for (int i = 0; i < npat; i++) if (!fnmatch(pat[i], unit, FNM_PATHNAME | FNM_PERIOD)) return 1;
    return 0;
}
static void pack_name(const char *unit, char *o, size_t n) {   // unit path → file name: '%' → %25, '/' → %2F
    size_t k = 0; for (const char *p = unit; *p && k + 4 < n; p++) {
        if (*p == '/') { memcpy(o + k, "%2F", 3); k += 3; } else if (*p == '%') { memcpy(o + k, "%25", 3); k += 3; } else o[k++] = *p; }
    o[k] = 0;
}
static int unit_of_pack(const char *name, char *o, size_t n) {   // file name → unit path; 0 = not a pack name
    size_t l = strlen(name), k = 0; if (name[0] == '.' || l <= 5 || strcmp(name + l - 5, ".pack")) return 0;
    for (size_t i = 0; i < l - 5; i++) {
        if (k + 1 >= n) return 0;
        if (name[i] == '%' && i + 2 < l - 5 && !strncmp(name + i, "%2F", 3)) { o[k++] = '/'; i += 2; }
        else if (name[i] == '%' && i + 2 < l - 5 && !strncmp(name + i, "%25", 3)) { o[k++] = '%'; i += 2; }
        else o[k++] = name[i];
    }
    o[k] = 0; return 1;
}
static void add_name(char (*names)[UNIT_LEN], int *n, const char *nm) {
    for (int i = 0; i < *n; i++) if (!strcmp(names[i], nm)) return;
    if (*n < MAXU && strlen(nm) < UNIT_LEN) strlcpy(names[(*n)++], nm, UNIT_LEN);
}
// Local units: for each pattern, the entries of its directory whose names match its last component
static void local_units(const char *save, const char *const *pat, int npat, char (*names)[UNIT_LEN], int *nn) {
    for (int i = 0; i < npat; i++) {
        const char *sl = strrchr(pat[i], '/'); char dir[UNIT_LEN] = "", d[1300];
        if (sl) { size_t l = (size_t)(sl - pat[i]); if (l >= sizeof dir) continue; memcpy(dir, pat[i], l); dir[l] = 0; }
        snprintf(d, sizeof d, "%s%s%s", save, dir[0] ? "/" : "", dir);
        DIR *dp = opendir(d); struct dirent *e;
        while (dp && (e = readdir(dp))) {
            if (e->d_name[0] == '.') continue;
            char unit[UNIT_LEN + 300]; snprintf(unit, sizeof unit, "%s%s%s", dir, dir[0] ? "/" : "", e->d_name);
            if (unit_matches(unit, pat, npat)) add_name(names, nn, unit);
        }
        if (dp) closedir(dp);
    }
}
// Read a local unit: 1 = present, 0 = absent, -1 = read failed (the unit is left alone this time)
static int local_read(const char *save, const char *unit, cs_unit *u) {
    memset(u, 0, sizeof *u);
    char full[1600]; struct stat st; snprintf(full, sizeof full, "%s/%s", save, unit);
    if (stat(full, &st)) return errno == ENOENT ? 0 : -1;
    int r = S_ISDIR(st.st_mode) ? read_tree(save, unit, u, 0) : S_ISREG(st.st_mode) ? read_file(full, unit, u) : -1;
    if (r) { unit_free(u); return -1; }
    if (!u->n) return 0;   // an empty directory counts as absent
    unit_finish(u); return 1;
}

// ---- Pack: magic 8 | timestamp u64 | flags u32 (1 = deleted) | file count u32 | per file: path length u16, path, modification time u64, length u32, contents
static int pack_write(const char *path, const cs_unit *u) {
    char tmp[1300]; snprintf(tmp, sizeof tmp, "%s.tmp", path); FILE *f = fopen(tmp, "wb"); if (!f) return -1;
    uint32_t fl = (uint32_t)u->tomb, n = (uint32_t)u->n;
    int ok = fwrite(k_magic, 8, 1, f) == 1 && fwrite(&u->stamp, 8, 1, f) == 1 && fwrite(&fl, 4, 1, f) == 1 && fwrite(&n, 4, 1, f) == 1;
    for (int i = 0; ok && i < u->n; i++) {
        uint16_t pl = (uint16_t)strlen(u->f[i].path);
        ok = fwrite(&pl, 2, 1, f) == 1 && fwrite(u->f[i].path, pl, 1, f) == 1 && fwrite(&u->f[i].mt, 8, 1, f) == 1 && fwrite(&u->f[i].size, 4, 1, f) == 1 &&
             (!u->f[i].size || fwrite(u->f[i].data, u->f[i].size, 1, f) == 1);
    }
    ok = fclose(f) == 0 && ok; if (ok) ok = rename(tmp, path) == 0;   // temporary file, then rename: the cloud only ever sees whole packs
    if (!ok) unlink(tmp);
    return ok ? 0 : -1;
}
// 1 = read, 0 = no such pack, -1 = bad pack. Every file must lie inside the unit (its path, or below it when the unit is a directory)
static int pack_read(const char *path, const char *unit, cs_unit *u) {
    memset(u, 0, sizeof *u); FILE *f = fopen(path, "rb"); if (!f) return errno == ENOENT ? 0 : -1;
    char mg[8]; uint32_t fl = 0, n = 0; size_t ul = unit ? strlen(unit) : 0;
    int ok = fread(mg, 8, 1, f) == 1 && !memcmp(mg, k_magic, 8) && fread(&u->stamp, 8, 1, f) == 1 && fread(&fl, 4, 1, f) == 1 && fread(&n, 4, 1, f) == 1 && n <= MAXF;
    for (uint32_t i = 0; ok && i < n; i++) {
        cs_file *x = &u->f[i]; uint16_t pl = 0;
        ok = fread(&pl, 2, 1, f) == 1 && pl < sizeof x->path && fread(x->path, pl, 1, f) == 1 && fread(&x->mt, 8, 1, f) == 1 && fread(&x->size, 4, 1, f) == 1 &&
             x->size <= (64u << 20);
        if (ok) { x->path[pl] = 0; x->data = malloc(x->size + 1); ok = x->data && (!x->size || fread(x->data, x->size, 1, f) == 1); u->n = (int)i + 1; }
        if (ok) ok = !strstr(x->path, "..") && x->path[0] != '/';
        if (ok && unit) ok = !strncmp(x->path, unit, ul) && (x->path[ul] == 0 || x->path[ul] == '/');
    }
    fclose(f);
    if (!ok) { unit_free(u); return -1; }
    uint64_t st = u->stamp; u->tomb = fl & 1; unit_finish(u); u->stamp = st;   // the header's timestamp counts (a deletion marker has no files)
    return 1;
}

// ---- Local write / remove / backup
static int rm_rf(const char *p) {
    struct stat st; if (lstat(p, &st)) return errno == ENOENT ? 0 : -1;
    if (!S_ISDIR(st.st_mode)) return unlink(p);
    DIR *d = opendir(p); struct dirent *e; int r = 0;
    while (d && (e = readdir(d))) { if (!strcmp(e->d_name, ".") || !strcmp(e->d_name, "..")) continue; char c[1600]; snprintf(c, sizeof c, "%s/%s", p, e->d_name); r |= rm_rf(c); }
    if (d) closedir(d);
    return r | rmdir(p);
}
static void mkparents(const char *full) {   // create the directories leading to full
    char p[1600]; strlcpy(p, full, sizeof p);
    for (char *s = p + 1; (s = strchr(s, '/')); s++) { *s = 0; mkdir(p, 0755); *s = '/'; }
}
// Write the unit's files below root, restoring their modification times
static int write_files(const char *root, const cs_unit *u) {
    for (int i = 0; i < u->n; i++) {
        char full[1600]; snprintf(full, sizeof full, "%s/%s", root, u->f[i].path); mkparents(full);
        FILE *f = fopen(full, "wb"); if (!f) return -1;
        int ok = !u->f[i].size || fwrite(u->f[i].data, u->f[i].size, 1, f) == 1; ok = fclose(f) == 0 && ok; if (!ok) return -1;
        struct timeval tv[2]; tv[0].tv_sec = tv[1].tv_sec = (time_t)(u->f[i].mt / 1000); tv[0].tv_usec = tv[1].tv_usec = (int)(u->f[i].mt % 1000) * 1000;
        utimes(full, tv);
    }
    return 0;
}
// Backup slot <backup>/<pack name>-<timestamp>/; a slot with the same name is the same copy and gets replaced
static int bak_dir(const char *bak, const char *unit, uint64_t stamp, char *d, size_t n) {
    char pn[UNIT_LEN * 3]; pack_name(unit, pn, sizeof pn); mkdir(bak, 0755);
    snprintf(d, n, "%s/%s-%llu", bak, pn, (unsigned long long)stamp); rm_rf(d);
    return mkdir(d, 0755);
}
static void bak_prune(const char *bak, const char *unit) {   // keep the newest 3 slots of a unit
    char pn[UNIT_LEN * 3], pre[UNIT_LEN * 3 + 2]; pack_name(unit, pn, sizeof pn); snprintf(pre, sizeof pre, "%s-", pn);
    uint64_t ts[64]; int n = 0; DIR *dp = opendir(bak); struct dirent *e;
    while (dp && (e = readdir(dp)) && n < 64)
        if (!strncmp(e->d_name, pre, strlen(pre))) { char *end; uint64_t t = strtoull(e->d_name + strlen(pre), &end, 10); if (!*end) ts[n++] = t; }
    if (dp) closedir(dp);
    while (n > 3) {
        int lo = 0; for (int i = 1; i < n; i++) if (ts[i] < ts[lo]) lo = i;
        char p[1600]; snprintf(p, sizeof p, "%s/%s%llu", bak, pre, (unsigned long long)ts[lo]); rm_rf(p); ts[lo] = ts[--n];
    }
}
// Move the local unit (whole) into a backup slot: a rename on the same volume, atomic, nothing half written. -1 = could not move: the caller must
// then neither replace nor delete — better no sync this time than a lost save
static int move_to_bak(const char *save, const char *bak, const char *unit, const cs_unit *cur, const char *why, char *d, size_t dn) {
    if (bak_dir(bak, unit, cur->stamp, d, dn)) { LOG("[red] iCloud sync: %s: cannot create backup slot %s, errno=%d; local save left alone", unit, d, errno); return -1; }
    char a[1600], b[1600]; snprintf(a, sizeof a, "%s/%s", save, unit); snprintf(b, sizeof b, "%s/%s", d, unit); mkparents(b);
    if (rename(a, b)) { int er = errno; rm_rf(d); LOG("[red] iCloud sync: %s: move to backup failed, errno=%d; local save left alone", unit, er); return -1; }
    LOG("iCloud sync: %s: %s copy moved to backup %s", unit, why, d); bak_prune(bak, unit);
    return 0;
}
// Replace the local unit with the cloud copy: write it beside the save first, back up the local copy, then rename into place
static int local_apply(const char *save, const char *bak, const char *unit, const cs_unit *cur, const cs_unit *cl) {
    char tmp[1300], d[1300]; snprintf(tmp, sizeof tmp, "%s/.cloudin", save); rm_rf(tmp); mkdir(tmp, 0755);
    if (write_files(tmp, cl)) { rm_rf(tmp); return -1; }
    if (cur && move_to_bak(save, bak, unit, cur, "local (replaced by a newer cloud copy)", d, sizeof d)) { rm_rf(tmp); return -1; }
    char a[1600], b[1600]; snprintf(a, sizeof a, "%s/%s", tmp, unit); snprintf(b, sizeof b, "%s/%s", save, unit); mkparents(b);
    if (rename(a, b)) {   // put the backed-up copy back
        int er = errno;
        if (cur) { char c[1600]; snprintf(c, sizeof c, "%s/%s", d, unit); rename(c, b); }
        rm_rf(tmp); errno = er; return -1;
    }
    rm_rf(tmp); return 0;
}
// Write a copy of a cloud unit into a backup slot (before the local copy overwrites it, or for an iCloud conflict version)
static int backup_copy(const char *bak, const char *unit, const cs_unit *u, const char *why) {
    char d[1300];
    if (bak_dir(bak, unit, u->stamp, d, sizeof d) || write_files(d, u)) {
        LOG("[red] iCloud sync: %s: writing the %s copy to backup failed, errno=%d; not uploading", unit, why, errno); rm_rf(d); return -1; }
    LOG("iCloud sync: %s: %s copy written to backup %s", unit, why, d); bak_prune(bak, unit);
    return 0;
}

// ---- State file: one line per unit, "unit\tdigest\ttimestamp\tdeleted"
typedef struct { char unit[UNIT_LEN]; uint64_t hash, stamp; int tomb; } cs_state;
static int state_load(const char *p, cs_state *s, int cap) {
    FILE *f = fopen(p, "r"); int n = 0; char ln[UNIT_LEN + 80]; if (!f) return 0;
    while (n < cap && fgets(ln, sizeof ln, f)) {
        unsigned long long h, t; int tb; char nm[UNIT_LEN];
        if (sscanf(ln, "%255[^\t]\t%llx\t%llu\t%d", nm, &h, &t, &tb) == 4) { strlcpy(s[n].unit, nm, sizeof s[n].unit); s[n].hash = h; s[n].stamp = t; s[n].tomb = tb; n++; }
    }
    fclose(f); return n;
}
static void state_save(const char *p, const cs_state *s, int n) {
    char tmp[1300]; snprintf(tmp, sizeof tmp, "%s.tmp", p); FILE *f = fopen(tmp, "w"); if (!f) return;
    for (int i = 0; i < n; i++) fprintf(f, "%s\t%llx\t%llu\t%d\n", s[i].unit, (unsigned long long)s[i].hash, (unsigned long long)s[i].stamp, s[i].tomb);
    if (fclose(f) == 0) rename(tmp, p); else unlink(tmp);
}
static cs_state *state_get(cs_state *s, int *n, int cap, const char *unit, int add) {
    for (int i = 0; i < *n; i++) if (!strcmp(s[i].unit, unit)) return &s[i];
    if (!add || *n >= cap) return NULL;
    memset(&s[*n], 0, sizeof *s); strlcpy(s[*n].unit, unit, sizeof s->unit); return &s[(*n)++];
}

// ---- Packs for cloud.m (iCloud conflict versions): timestamp of a pack; a pack's copy into the backup
uint64_t dm_cloud_pack_stamp(const char *pack) {
    cs_unit *u = calloc(1, sizeof *u); uint64_t t = u && pack_read(pack, NULL, u) == 1 ? u->stamp : 0;
    if (u) { unit_free(u); free(u); }
    return t;
}
int dm_cloud_bak_pack(const char *bak, const char *pack, const char *why) {
    char unit[UNIT_LEN]; const char *nm = strrchr(pack, '/'); nm = nm ? nm + 1 : pack;
    if (!unit_of_pack(nm, unit, sizeof unit)) return -1;
    cs_unit *u = calloc(1, sizeof *u); int r = u && pack_read(pack, unit, u) == 1 ? (u->tomb ? 0 : backup_copy(bak, unit, u, why)) : -1;
    if (u) { unit_free(u); free(u); }
    return r;
}

int dm_cloud_sync(const char *save, const char *cloud, const char *bak, const char *statef, const char *const *pat, int npat,
                  int allow_down, uint64_t now_ms, int (*ready)(const char *pack)) {
    if (!save || !cloud || !bak || !statef || !pat || npat <= 0) return -1;
    static char names[MAXU][UNIT_LEN]; static cs_state st[MAXU];
    int nn = 0, ns = state_load(statef, st, MAXU), acts = 0;
    local_units(save, pat, npat, names, &nn);
    DIR *dp = opendir(cloud); struct dirent *e;
    while (dp && (e = readdir(dp))) { char u[UNIT_LEN]; if (unit_of_pack(e->d_name, u, sizeof u) && unit_matches(u, pat, npat)) add_name(names, &nn, u); }
    if (dp) closedir(dp);
    for (int i = 0; i < ns; i++) if (unit_matches(st[i].unit, pat, npat)) add_name(names, &nn, st[i].unit);
    for (int k = 0; k < nn; k++) {
        const char *un = names[k]; char pn[UNIT_LEN * 3], cp[1300]; pack_name(un, pn, sizeof pn); snprintf(cp, sizeof cp, "%s/%s.pack", cloud, pn);
        { char rp[UNIT_LEN * 3 + 8]; snprintf(rp, sizeof rp, "%s.pack", pn); if (ready && !ready(rp)) { LOG("iCloud sync: %s: cloud copy not downloaded yet, skipped", un); continue; } }
        cs_unit *L = calloc(1, sizeof *L), *C = calloc(1, sizeof *C);
        if (!L || !C) { free(L); free(C); LOG("[red] iCloud sync: out of memory"); break; }
        int hl = local_read(save, un, L), hc = pack_read(cp, un, C);
        cs_state *S = state_get(st, &ns, MAXU, un, 0), *W = NULL;
        if (hl < 0 || hc < 0) { LOG("[red] iCloud sync: %s: cannot read the %s, skipped", un, hl < 0 ? "local copy" : "cloud pack"); goto next; }
        int lchg = hl ? (!S || S->tomb || L->hash != S->hash) : (S && !S->tomb);   // changed locally since the last sync (gone counts: deleted)
        int cchg = hc && (!S || C->stamp != S->stamp || C->tomb != S->tomb);         // no pack in the cloud = no news
        enum { NONE, UP, DOWN, DEL_LOCAL, TOMB } act = NONE;
        if (hl && hc && !C->tomb && L->hash == C->hash) act = NONE;                    // same contents: record the state only
        else if (!S && hl && hc && !C->tomb) { if (!allow_down) goto next; act = DOWN; }   // first sync, contents differ: the cloud wins (at launch)
        else if (hl && !hc) act = UP;
        else if (!hl && hc) { if (C->tomb) act = NONE; else if (lchg && !cchg && !allow_down) act = TOMB; else act = DOWN; }
        // Missing locally: only a unit found missing while the game runs (after a save commit, allow_down = 0) was deleted by the player → deletion
        // marker. Missing at launch (save directory wiped or replaced outside the game) is a local loss: fetch it back — otherwise one accidental
        // wipe would delete the save on every device
        else if (!hl && !hc) { if (lchg && S) act = NONE; }
        else if (!lchg && cchg) act = C->tomb ? DEL_LOCAL : DOWN;
        else if (lchg && !cchg) act = UP;
        else act = C->stamp > L->stamp ? (C->tomb ? DEL_LOCAL : DOWN) : UP;            // both changed: the newer write wins
        if ((act == DOWN || act == DEL_LOCAL) && !allow_down) goto next;              // never touch the local save while running: next launch
        if (act == UP) {
            if (hc && !C->tomb && C->hash != L->hash && cchg && backup_copy(bak, un, C, "cloud (overwritten by a newer local copy)")) goto next;
            L->tomb = 0;
            if (pack_write(cp, L)) { LOG("[red] iCloud sync: %s: upload failed, errno=%d", un, errno); goto next; }
            LOG("iCloud sync: %s: uploaded (timestamp %llu, %d file%s)", un, (unsigned long long)L->stamp, L->n, L->n == 1 ? "" : "s"); acts++;
            W = state_get(st, &ns, MAXU, un, 1); if (W) { W->hash = L->hash; W->stamp = L->stamp; W->tomb = 0; }
        } else if (act == DOWN) {
            if (local_apply(save, bak, un, hl ? L : NULL, C)) { LOG("[red] iCloud sync: %s: applying the download failed, errno=%d (local unchanged)", un, errno); goto next; }
            LOG("iCloud sync: %s: downloaded (timestamp %llu, %d file%s)", un, (unsigned long long)C->stamp, C->n, C->n == 1 ? "" : "s"); acts++;
            W = state_get(st, &ns, MAXU, un, 1); if (W) { W->hash = C->hash; W->stamp = C->stamp; W->tomb = 0; }
        } else if (act == DEL_LOCAL) {
            { char d[1300]; if (move_to_bak(save, bak, un, L, "local (deleted on another device)", d, sizeof d)) goto next; }
            LOG("iCloud sync: %s: deleted on another device, deleted here too (backup kept)", un); acts++;
            W = state_get(st, &ns, MAXU, un, 1); if (W) { W->hash = 0; W->stamp = C->stamp; W->tomb = 1; }
        } else if (act == TOMB) {
            cs_unit *t = calloc(1, sizeof *t); int bad = !t; if (t) { t->tomb = 1; t->stamp = now_ms; bad = pack_write(cp, t) != 0; free(t); }
            if (bad) { LOG("[red] iCloud sync: %s: writing the deletion marker failed, errno=%d", un, errno); goto next; }
            LOG("iCloud sync: %s: deleted here, deletion marker written to the cloud", un); acts++;
            W = state_get(st, &ns, MAXU, un, 1); if (W) { W->hash = 0; W->stamp = now_ms; W->tomb = 1; }
        } else if (hc) {   // identical: record as synced
            W = state_get(st, &ns, MAXU, un, 1); if (W) { W->hash = C->tomb ? 0 : C->hash; W->stamp = C->stamp; W->tomb = C->tomb; }
        }
    next:
        unit_free(L); unit_free(C); free(L); free(C);
    }
    state_save(statef, st, ns);
    return acts;
}
