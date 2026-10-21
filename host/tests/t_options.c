// Code options (options.c, plan item 57): a product directory built by hand, main.options.tsv with option a (two rows), b (one) and c (two, the
// second one's original not what the image holds), and an image with the originals. DM_OPTIONS=a,zzz applies a's two rows and nothing else, says
// zzz is unknown; without DM_OPTIONS the directory's options.default (b) is used; DM_OPTIONS= and DM_OPTIONS=none ask for none; c is refused whole
// (its first row not written either). Negative control: -DDM_TEST_OPTIONS_NO_CHECK (written without checking) writes c's first row.
#include "../options.c"
#include <stdlib.h>
#include <unistd.h>
static int n, fail;
#define CHECK(c, ...) do { n++; if (c) printf("  ✓ "); else { fail++; printf("  ✗ "); } printf(__VA_ARGS__); printf("\n"); } while (0)
static uint8_t img[0x100];
static void reset(void) { memset(img, 0, sizeof img); img[0x10] = 0x11; img[0x11] = 0x22; img[0x20] = 0x33; img[0x30] = 0x44; img[0x40] = 0x55; img[0x50] = 0x66; }
int main(void) {
    setvbuf(stdout, NULL, _IONBF, 0);
    char dir[1024]; const char *tp = getenv("TMPDIR"); snprintf(dir, sizeof dir, "%s/t_options.XXXXXX", tp ? tp : "/private/tmp");
    if (!mkdtemp(dir)) return 2;
    char p[1100]; snprintf(p, sizeof p, "%s/main.options.tsv", dir); FILE *f = fopen(p, "w");
    fprintf(f, "# BUILD_ID\t0011\n" "a\t0x10\t1122\taabb\tfirst of a\n" "a\t0x20\t33\tcc\tsecond of a\n" "b\t0x30\t44\tdd\tb\n"
               "c\t0x40\t55\tee\tfirst of c\n" "c\t0x50\t99\tff\tsecond of c: the image has 66, not 99\n"); fclose(f);
    char w[256];
    setenv("DM_OPTIONS", "a,zzz", 1); dm_options_wanted(dir, w, sizeof w); reset();
    int r = dm_options_apply(dir, "main", img, sizeof img, w);
    CHECK(!strcmp(w, "a,zzz"), "DM_OPTIONS=a,zzz: asked for a and zzz (%s)", w);
    CHECK(r == 2 && img[0x10] == 0xaa && img[0x11] == 0xbb && img[0x20] == 0xcc, "a's two rows written (%d words)", r);
    CHECK(img[0x30] == 0x44 && img[0x40] == 0x55, "b and c not");
    CHECK(dm_option_on("a") && !dm_option_on("b") && !dm_option_on("c"), "dm_option_on: a only");
    CHECK(dm_options_check(w) == 1, "zzz: no module has it (one unknown)");
    snprintf(p, sizeof p, "%s/options.default", dir); f = fopen(p, "w"); fputs("b\n", f); fclose(f);
    unsetenv("DM_OPTIONS"); dm_options_wanted(dir, w, sizeof w); reset(); r = dm_options_apply(dir, "main", img, sizeof img, w);
    CHECK(!strcmp(w, "b") && r == 1 && img[0x30] == 0xdd && img[0x10] == 0x11, "without DM_OPTIONS: the product's options.default, b (%s)", w);
    setenv("DM_OPTIONS", "", 1); dm_options_wanted(dir, w, sizeof w);
    CHECK(!w[0], "DM_OPTIONS= (empty): none, options.default not read");
    setenv("DM_OPTIONS", "none", 1); dm_options_wanted(dir, w, sizeof w);
    CHECK(!w[0], "DM_OPTIONS=none: none");
    setenv("DM_OPTIONS", " c , ", 1); dm_options_wanted(dir, w, sizeof w); reset(); r = dm_options_apply(dir, "main", img, sizeof img, w);
    CHECK(r == -1 && img[0x40] == 0x55 && img[0x50] == 0x66 && !dm_option_on("c"), "c with a row whose original differs: refused whole, its first row not written either");
    snprintf(p, sizeof p, "rm -rf '%s'", dir); if (system(p)) {}
    printf("== %d checks, %d failed ==\n", n, fail); return fail != 0;
}
