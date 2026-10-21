// User mod folders (mods.c, DM_MODS): a mods folder built by hand with every layout, the program ID 0100F2C0115B6000 spelled both ways:
//   01_one/contents/0100f2c0115b6000/romfs (lower case) with b.txt and c.txt, 02_two/romfs with b.txt, 03_three/atmosphere/contents/<ID>/romfs with
//   c.txt, 04_loose/Model/m.bfres (loose files), 05_code/exefs only, atmosphere/contents/<ID>/romfs with a.txt and atmosphere/contents/<another
//   game>/romfs, -off/romfs and .hidden/romfs (turned off).
// The layers come in name order (01, 02, 03, 04, atmosphere), the code-only, turned-off and other-game folders are left out; through hle_fs.c's
// dm_overlay_file each file resolves to the first layer that has it; dm_mods_apply puts them in front of an existing DM_ROMFS_OVERLAY.
// Paths keep each folder's own spelling (the Mac's file system ignores case, iOS's does not). Negative control: -DDM_TEST_MODS_CASE (paths built
// with the program ID as asked) puts the upper-case spelling into 01_one's layer.
#include "../mods.c"
#include <stdlib.h>
const dm_game_profile dm_game = { .id = "test", .program_id = 0x0100F2C0115B6000ull };
int dm_overlay_file(const char *rel, char *out, size_t n);   // hle_fs.c's lookup, here as in hle_fs.c
int dm_overlay_file(const char *rel, char *out, size_t n) {
    const char *ov = getenv("DM_ROMFS_OVERLAY");
    for (const char *p = ov ? ov : ""; *p;) {
        size_t l = strcspn(p, ":");
        if (l && snprintf(out, n, "%.*s/%s", (int)l, p, rel) < (int)n && !access(out, R_OK)) return 1;
        p += l; if (*p == ':') p++;
    }
    if (n) out[0] = 0;
    return 0;
}
static int n, fail;
#define CHECK(c, ...) do { n++; if (c) printf("  ✓ "); else { fail++; printf("  ✗ "); } printf(__VA_ARGS__); printf("\n"); } while (0)
static char g_root[1024];
static void put(const char *rel, const char *s) {
    char p[2048]; snprintf(p, sizeof p, "%s/%s", g_root, rel);
    char cmd[2200]; snprintf(cmd, sizeof cmd, "mkdir -p \"$(dirname '%s')\"", p); if (system(cmd)) {}
    FILE *f = fopen(p, "w"); fputs(s, f); fclose(f);
}
static int from(const char *rel, const char *want_layer_part, const char *want_text) {   // resolves to a file under a layer containing that text
    char p[2048]; if (!dm_overlay_file(rel, p, sizeof p)) return 0;
    char b[64] = {0}; FILE *f = fopen(p, "r"); if (!f) return 0; size_t k = fread(b, 1, sizeof b - 1, f); fclose(f); b[k] = 0;
    return strstr(p, want_layer_part) && !strcmp(b, want_text);
}
int main(void) {
    setvbuf(stdout, NULL, _IONBF, 0);
    const char *tp = getenv("TMPDIR"); snprintf(g_root, sizeof g_root, "%s/t_mods.XXXXXX", tp ? tp : "/private/tmp");
    if (!mkdtemp(g_root)) return 2;
    put("01_one/contents/0100f2c0115b6000/romfs/b.txt", "one-b"); put("01_one/contents/0100f2c0115b6000/romfs/c.txt", "one-c");
    put("02_two/romfs/b.txt", "two-b");
    put("03_three/atmosphere/contents/0100F2C0115B6000/romfs/c.txt", "three-c"); put("03_three/atmosphere/contents/0100F2C0115B6000/romfs/d.txt", "three-d");
    put("04_loose/Model/m.bfres", "loose");
    put("05_code/exefs/main.npdm", "x");
    put("atmosphere/contents/0100F2C0115B6000/romfs/a.txt", "atm-a"); put("atmosphere/contents/0100AAAA00000000/romfs/z.txt", "other");
    put("-off/romfs/a.txt", "off"); put(".hidden/romfs/a.txt", "hidden");
    char layers[4096]; int nl = dm_mods_layers(g_root, dm_game.program_id, NULL, layers, sizeof layers);
    printf("layers: %s\n", layers);
    CHECK(nl == 5, "five layers: 01, 02, 03, 04 and atmosphere (%d)", nl);
    const char *order[] = {"/01_one/", "/02_two/", "/03_three/", "/04_loose", "/atmosphere/"}; const char *p = layers; int ok = 1;
    for (int i = 0; i < 5 && ok; i++) { const char *q = strstr(p, order[i]); ok = q != NULL; p = q ? q + 1 : p; }
    CHECK(ok, "in name order");
    CHECK(strstr(layers, "/01_one/contents/0100f2c0115b6000/romfs") != NULL, "01_one's layer with its folder's own spelling (lower case), which holds on iOS too");
    CHECK(!strstr(layers, "05_code") && !strstr(layers, "-off") && !strstr(layers, ".hidden") && !strstr(layers, "0100AAAA"), "the code-only, turned-off, hidden and other-game folders left out");
    setenv("DM_MODS", g_root, 1); setenv("DM_ROMFS_OVERLAY", "/game/own/overlay", 1);
    dm_mods_apply();
    const char *ov = getenv("DM_ROMFS_OVERLAY");
    CHECK(ov && strstr(ov, "/01_one/") == strstr(ov, g_root) + strlen(g_root) && strstr(ov, ":/game/own/overlay") && !strcmp(ov + strlen(ov) - strlen("/game/own/overlay"), "/game/own/overlay"),
          "DM_ROMFS_OVERLAY: the mods first, the game's own overlay last");
    CHECK(from("b.txt", "/01_one/", "one-b"), "b.txt: 01_one's (02_two has one too)");
    CHECK(from("c.txt", "/01_one/", "one-c"), "c.txt: 01_one's (lower-case program ID; 03_three has one too)");
    CHECK(from("d.txt", "/03_three/", "three-d"), "d.txt: 03_three's (shipped as atmosphere/contents/<ID>/romfs)");
    CHECK(from("Model/m.bfres", "/04_loose", "loose"), "Model/m.bfres: 04_loose's (loose files)");
    CHECK(from("a.txt", "/atmosphere/", "atm-a"), "a.txt: the SD card's atmosphere folder's (-off and .hidden have one: not used)");
    char x[2048]; CHECK(!dm_overlay_file("z.txt", x, sizeof x), "z.txt of another game: not found");
    unsetenv("DM_ROMFS_OVERLAY"); setenv("DM_MODS", "/nonexistent/mods", 1); dm_mods_apply();
    CHECK(!getenv("DM_ROMFS_OVERLAY"), "a missing mods folder: nothing set");
    char cmd[1100]; snprintf(cmd, sizeof cmd, "rm -rf '%s'", g_root); if (system(cmd)) {}
    printf("== %d checks, %d failed ==\n", n, fail); return fail != 0;
}
