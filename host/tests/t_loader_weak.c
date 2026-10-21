// Weak imports through the loader (loader.c relocate / resolve_sym, hle.c resolve_import), on synthetic ELF records: an importer with four
// GLOB_DAT relocations and an exporter that defines one of the names. An absent weak import stays 0 (the guest checks it and skips the call), a weak
// import the exporter defines resolves to it, one the host defines (HLE) resolves to the host function, an unresolved strong import gets a stub,
// and a later weak lookup of that strong name does not pick up its stub. From upstream's test of b84657b (d2r-mobile #66).
#include "../loader.c"

struct dm_flags g_flag;
uint64_t unimpl_stubs[4096];
void *hlecount_wrap(const char *kind, const char *name, void *function) { (void)kind; (void)name; return function; }
void *dm_hwrap(void *fn) { return fn; }
HLE("host_provided", int, host_provided, void) { return 7; }
static int n, fail;
#define CHECK(c, ...) do { n++; if (c) printf("  ✓ "); else { fail++; printf("  ✗ "); } printf(__VA_ARGS__); printf("\n"); } while (0)

int main(void) {
    _Alignas(16) uint8_t importer[4096] = {0}, exporter[4096] = {0};
    const char names[] = "\0optional\0provided\0host_provided\0required";
    Elf64_Sym imports[5] = {{0}, {.st_name = 1, .st_info = 0x20}, {.st_name = 10, .st_info = 0x20}, {.st_name = 19, .st_info = 0x20}, {.st_name = 33, .st_info = 0x10}};
    Elf64_Sym exports[2] = {{0}, {.st_name = 10, .st_info = 0x10, .st_shndx = 1, .st_value = 0x100}};
    Elf64_Dyn dynamic[] = {{.d_tag = DT_RELA, .d_un.d_ptr = 0x300}, {.d_tag = DT_RELASZ, .d_un.d_val = 4 * sizeof(Elf64_Rela)}, {0}};
    Elf64_Rela *rel = (Elf64_Rela *)(importer + 0x300);
    for (int i = 0; i < 4; i++) rel[i] = (Elf64_Rela){.r_offset = 0x200 + i * 8, .r_info = ((uint64_t)(i + 1) << 32) | R_AARCH64_GLOB_DAT};
    g_mod[0] = (module_t){.base = importer, .size = sizeof importer, .symtab = imports, .strtab = names, .nsym = 5, .dyn = dynamic};
    g_mod[1] = (module_t){.base = exporter, .size = sizeof exporter, .symtab = exports, .strtab = names, .nsym = 2};
    g_nmod = 2;
    relocate(&g_mod[0]);
    uint64_t *v = (uint64_t *)(importer + 0x200);
    CHECK(v[0] == 0, "an absent weak import stays 0 (%#llx)", (unsigned long long)v[0]);
    CHECK(v[1] == (uintptr_t)(exporter + 0x100), "a weak import the exporter defines resolves to it");
    CHECK(v[2] == (uintptr_t)host_provided, "a weak import the host defines resolves to the host function");
    CHECK(v[3] != 0, "an unresolved strong import gets a stub");
    CHECK(resolve_sym(&g_mod[0], "required", 1) == 0, "a weak lookup of that name does not reuse the strong import's stub");
    printf("t_loader_weak: %d checks, %d failed\n", n, fail); return fail != 0;
}
