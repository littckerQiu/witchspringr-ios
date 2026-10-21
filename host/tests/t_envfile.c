// env.txt switches (envfile.h): NAME=value lines with spaces trimmed and a CR dropped, comments and blank lines skipped, an empty value set as
// empty, names other than DM_* / MTL_* and malformed names refused, a later file overriding an earlier one; no file gives -1. Expected values are
// written by hand from the file below.
#include "../envfile.h"
#include <unistd.h>
static int n, fail;
#define CHECK(c, ...) do { n++; if (c) printf("  ✓ "); else { fail++; printf("  ✗ "); } printf(__VA_ARGS__); printf("\n"); } while (0)
static int said;
static void say(const char *k, const char *v) { (void)k; (void)v; said++; }
static int is(const char *k, const char *want) { const char *v = getenv(k); return v && !strcmp(v, want); }
int main(void) {
    const char *td = getenv("TMPDIR"); char a[1024], b[1024]; snprintf(a, sizeof a, "%s/t_envfile_a.txt", td ? td : "/private/tmp"); snprintf(b, sizeof b, "%s/t_envfile_b.txt", td ? td : "/private/tmp");
    FILE *f = fopen(a, "w");
    fputs("# switches for a device run\n\nDM_A=1\n   DM_B =  two words  \nDM_CR=x\r\nDM_EMPTY=\nHOME=/nowhere\nDYLD_INSERT_LIBRARIES=/x\nDM_NO_EQUALS\nDM_BAD-NAME=1\nMTL_HUD_ENABLED=1\nDM_OVER=first\n", f);
    fclose(f);
    f = fopen(b, "w"); fputs("DM_OVER=second\n", f); fclose(f);
    const char *home = getenv("HOME");
    unsetenv("DM_A"); unsetenv("DM_B"); unsetenv("DM_CR"); unsetenv("DM_EMPTY"); unsetenv("MTL_HUD_ENABLED"); unsetenv("DM_OVER");
    int k = dm_env_file_apply(a, say);
    CHECK(k == 6 && said == 6, "six switches applied and reported (got %d, reported %d)", k, said);
    CHECK(is("DM_A", "1"), "DM_A=1");
    CHECK(is("DM_B", "two words"), "spaces around name and value trimmed, inner space kept: DM_B=\"two words\"");
    CHECK(is("DM_CR", "x"), "a CR at the end dropped");
    CHECK(is("DM_EMPTY", ""), "an empty value is set as empty");
    CHECK(is("MTL_HUD_ENABLED", "1"), "MTL_* names are taken");
    CHECK(home && is("HOME", home) && !getenv("DYLD_INSERT_LIBRARIES"), "other names (HOME, DYLD_*) refused");
    CHECK(!getenv("DM_NO_EQUALS") && !getenv("DM_BAD-NAME"), "a line without = and a name with other characters refused");
    CHECK(dm_env_file_apply(b, say) == 1 && is("DM_OVER", "second"), "a later file overrides: DM_OVER=second");
    CHECK(dm_env_file_apply("/nonexistent/env.txt", say) == -1, "no file: -1");
    unlink(a); unlink(b);
    printf("t_envfile: %d checks, %d failed\n", n, fail); return fail != 0;
}
