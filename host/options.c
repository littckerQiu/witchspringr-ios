// Code options (plan item 57, after tomodachi-native 0428c80, kuosuko/tomodachi-native, MIT): changes the rewriter lists in <module>.options.tsv
// (tools/patch_nso.py OPTIONS: checked against the original there, not written into the image) are applied by the loader to the image it maps,
// before the code is sealed, when DM_OPTIONS names them (comma-separated; "" or "none" for none), or else the product directory's options.default
// (one line, the same form): one product serves Tears of the Kingdom at 30 fps (no option, the game as shipped) and at 60 fps (fps60,realtime,scene).
// The original bytes are checked again here; an option is applied whole or not at all. iOS maps the signed executable's code, which cannot be
// changed at load (tomodachi-native afd88e9 embeds the changed pages instead: item 62). Checked by host/tests/t_options.c.
#include "dm.h"
#define OPT_MAX 16
static char g_on[OPT_MAX][32]; static int g_non;      // options applied
static char g_seen[OPT_MAX][32]; static int g_nseen;  // options the modules' lists have
static int listed(char (*set)[32], int n, const char *name) { for (int i = 0; i < n; i++) if (!strcmp(set[i], name)) return 1; return 0; }
int dm_option_on(const char *name) { return listed(g_on, g_non, name); }
// The options asked for into out (comma-separated, no spaces), from DM_OPTIONS or <dir>/options.default; empty for none
void dm_options_wanted(const char *dir, char *out, size_t n) {
    const char *e = getenv("DM_OPTIONS"); char buf[256] = "";
    if (e) strlcpy(buf, e, sizeof buf);
    else { char p[1100]; snprintf(p, sizeof p, "%s/options.default", dir); FILE *f = fopen(p, "r"); if (f) { if (!fgets(buf, sizeof buf, f)) buf[0] = 0; fclose(f); } }
    size_t o = 0; out[0] = 0;
    for (char *sv, *t = strtok_r(buf, ", \t\r\n", &sv); t; t = strtok_r(NULL, ", \t\r\n", &sv)) {
        if (!strcmp(t, "none")) continue;
        size_t l = strlen(t); if (o + l + 2 > n) break;
        if (o) out[o++] = ','; memcpy(out + o, t, l); o += l; out[o] = 0;
    }
}
static int wanted_has(const char *wanted, const char *name) {
    size_t l = strlen(name);
    for (const char *p = wanted; *p;) { size_t k = strcspn(p, ","); if (k == l && !strncmp(p, name, l)) return 1; p += k; if (*p == ',') p++; }
    return 0;
}
static int hexbytes(const char *h, uint8_t *out, int max) { int n = 0; while (h[0] && h[1] && n < max) { unsigned v; if (sscanf(h, "%2x", &v) != 1) return -1; out[n++] = (uint8_t)v; h += 2; } return n; }
// Applies the rows of <dir>/<module>.options.tsv whose option is wanted to img (sz bytes); returns the words written, -1 if an option was refused
int dm_options_apply(const char *dir, const char *module, uint8_t *img, size_t sz, const char *wanted) {
    char p[1100]; snprintf(p, sizeof p, "%s/%s.options.tsv", dir, module);
    FILE *f = fopen(p, "r"); if (!f) return 0;
    typedef struct { char name[32]; uint64_t off; uint8_t ob[16], nb[16]; int n; } row;
    row *r = NULL; int nr = 0, cap = 0; char line[1024];
    while (fgets(line, sizeof line, f)) {
        if (line[0] == '#') continue;
        char name[32], off[32], ob[64], nb[64];
        if (sscanf(line, "%31s %31s %63s %63s", name, off, ob, nb) != 4) continue;
        if (!listed(g_seen, g_nseen, name) && g_nseen < OPT_MAX) strlcpy(g_seen[g_nseen++], name, sizeof g_seen[0]);
        if (!wanted_has(wanted, name)) continue;
        if (nr == cap) { cap = cap ? cap * 2 : 32; r = realloc(r, (size_t)cap * sizeof *r); }
        row *x = &r[nr]; strlcpy(x->name, name, sizeof x->name); x->off = strtoull(off, NULL, 0);
        x->n = hexbytes(ob, x->ob, 16); if (x->n <= 0 || hexbytes(nb, x->nb, 16) != x->n) continue;
        nr++;
    }
    fclose(f);
    int words = 0, refused = 0;
    for (int i = 0; i < nr; i++) {   // one option at a time: all of its rows checked, then all written
        int first = 1; for (int j = 0; j < i; j++) if (!strcmp(r[j].name, r[i].name)) first = 0;
        if (!first) continue;
        int ok = 1, k = 0;
        for (int j = i; j < nr; j++) if (!strcmp(r[j].name, r[i].name)) {
#ifndef DM_TEST_OPTIONS_NO_CHECK   // negative control of t_options only: written without checking the original
            if (r[j].off + (uint64_t)r[j].n > sz || memcmp(img + r[j].off, r[j].ob, (size_t)r[j].n)) { ok = 0; LOG("[red] option %s: %s+%#llx is not the original the product lists: not applied", r[i].name, module, (unsigned long long)r[j].off); break; }
#else
            if (r[j].off + (uint64_t)r[j].n > sz) { ok = 0; break; }
#endif
        }
        if (!ok) { refused = 1; continue; }
        for (int j = i; j < nr; j++) if (!strcmp(r[j].name, r[i].name)) { memcpy(img + r[j].off, r[j].nb, (size_t)r[j].n); k++; }
        words += k; if (!listed(g_on, g_non, r[i].name) && g_non < OPT_MAX) strlcpy(g_on[g_non++], r[i].name, sizeof g_on[0]);
        LOG("option %s: %d words of %s", r[i].name, k, module);
    }
    free(r);
    return refused ? -1 : words;
}
// After every module: an option asked for that no module lists (a typing error) in red; returns how many
int dm_options_check(const char *wanted) {
    int bad = 0;
    for (const char *p = wanted; *p;) {
        size_t k = strcspn(p, ","); char name[32]; snprintf(name, sizeof name, "%.*s", (int)k, p);
        if (k && !listed(g_seen, g_nseen, name)) { LOG("[red] option %s: no module of this product has it", name); bad++; }
        p += k; if (*p == ',') p++;
    }
    return bad;
}
