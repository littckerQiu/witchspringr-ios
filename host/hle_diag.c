//   ModuleInfo = { const char *path; uint64 base; uint64 size; const uint8 *id; uint64 id_size; uint32 0 }
// nn::diag module info: the real device walks process memory block by block with svc QueryMemory and uses nn::ro to read each module's MOD0 header for the path and the module ID (GNU build-id note).
// Host modules are not in Horizon memory blocks, so the sdk implementation aborts in nn::ro::detail::GetExceptionInfo; here the loaded modules are reported directly in the same output format.
// Output format taken from the sdk's GetAllModuleInfoImpl (2.0.4b sdk+0xac060): the front of the buffer holds one 0x30-byte ModuleInfo per module in order,
// the path strings (with NUL) and module ID bytes are placed from the end of the buffer backward; each module takes path length + ID length + 0x31 bytes; returns the module count.
//   ModuleInfo = { const char *path; uint64 base; uint64 size; const uint8 *id; uint64 id_size; uint32 0 }
// Path: the module path record at the start of the module's .rodata (+0x10 u32 length, +0x14 string). Unity finds the main module by a path ending in .nss (from main+0x391344).
// Module ID: the module's only GNU build-id note (namesz 4, type 3, "GNU"), length = descsz (≤ 0x20), same as nn::ro::GetModuleId (sdk+0x15a420).
// The real device also lists rtld; the host does not load rtld and does not list it.
#include "hle.h"

typedef struct { const char *path; uint64_t plen; const uint8_t *base; uint64_t size; const uint8_t *id; uint64_t idlen; } modinfo;

static void mod_path(const module_t *m, modinfo *o) {
    const uint8_t *ro = m->base + m->ro_off;
    uint32_t n = *(const uint32_t *)(ro + 0x10);
    if (*(const uint32_t *)(ro + 0xc) == 0 && n && n < 0x200 && ro + 0x14 + n <= m->base + m->size && memchr(ro + 0x14, 0, n) == NULL) {
        o->path = (const char *)(ro + 0x14); o->plen = n; return;
    }
    LOG("[red] diag: no module path record at the start of %s .rodata; using the host module name", m->name);
    o->path = m->name; o->plen = strlen(m->name);
}
static void mod_id(const module_t *m, modinfo *o) {
    static const uint8_t tail[8] = {3, 0, 0, 0, 'G', 'N', 'U', 0};
    o->id = NULL; o->idlen = 0;
    for (uint64_t off = 0; off + 16 <= m->size; off += 4) {
        const uint8_t *p = m->base + off;
        if (*(const uint32_t *)p != 4 || memcmp(p + 8, tail, 8)) continue;
        uint32_t n = *(const uint32_t *)(p + 4);
        if (n > 0x20 || off + 16 + n > m->size) continue;
        o->id = p + 16; o->idlen = n; return;
    }
    LOG("[red] diag: no GNU build-id note in %s; module id left empty", m->name);
}
static int mods(modinfo *out) {
    static modinfo cache[MAX_MOD]; static int n = -1;
    if (n < 0) {
        int k = 0;
        for (int i = 0; i < g_nmod; i++) { modinfo o = {0}; mod_path(&g_mod[i], &o); mod_id(&g_mod[i], &o); o.base = g_mod[i].base; o.size = g_mod[i].size; cache[k++] = o; }
        for (int i = 1; i < k; i++) for (int j = i; j > 0 && cache[j].base < cache[j - 1].base; j--) { modinfo t = cache[j]; cache[j] = cache[j - 1]; cache[j - 1] = t; }   // the real device walks memory blocks in address order
        n = k;
    }
    memcpy(out, cache, sizeof cache);
    return n;
}

HLE_FORCE_OPT("_ZN2nn4diag40GetRequiredBufferSizeForGetAllModuleInfoEv", "module info buffer size, from the modules the host loaded", uint64_t, h_diag_ModBufSize, void) {
    modinfo m[MAX_MOD]; int n = mods(m); uint64_t sz = 0;
    for (int i = 0; i < n; i++) sz += m[i].plen + m[i].idlen + 0x31;
    return n ? sz : 0;
}
HLE_FORCE_OPT("_ZN2nn4diag16GetAllModuleInfoEPPNS0_10ModuleInfoEPvm", "module info of the modules the host loaded (format of sdk GetAllModuleInfoImpl)", int, h_diag_AllModInfo, void **out, void *buf, uint64_t bufsz) {
    *out = buf;
    modinfo m[MAX_MOD]; int n = mods(m), cnt = 0;
    if (bufsz <= 0x30) return 0;
    uint8_t *ent = buf, *tail = (uint8_t *)buf + bufsz; uint64_t used = 0;
    for (int i = 0; i < n; i++) {
        used += m[i].plen + m[i].idlen + 0x31;
        if (used > bufsz) break;
        tail -= m[i].plen + 1; memmove(tail, m[i].path, m[i].plen); tail[m[i].plen] = 0;
        uint64_t *e = (uint64_t *)ent;
        e[0] = (uint64_t)tail; e[1] = (uint64_t)m[i].base; e[2] = m[i].size;
        if (m[i].idlen) { tail -= m[i].idlen; memcpy(tail, m[i].id, m[i].idlen); e[3] = (uint64_t)tail; } else e[3] = 0;
        e[4] = m[i].idlen; *(uint32_t *)(ent + 0x28) = 0;
        ent += 0x30; cnt++;
        if ((uint64_t)(tail - ent) <= 0x30) break;
    }
    return cnt;
}
