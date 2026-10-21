// nn::ro (dynamically loaded NRO modules): on the real device the ldr:ro service maps NROs. The host only runs modules rewritten offline and built into the program, so no new code can be loaded at run time.
// Unity reads rom:/.nrr/dynamic.nrr at startup to register loadable native plugins; when the game ships no plugin the file is absent and nothing is loaded.
// LookupSymbol searches the loaded modules (main / sdk / subsdk*) by name, like dlsym; an actual LoadModule fails loudly.
#include "hle.h"

HLE_FORCE_OPT("_ZN2nn2ro10InitializeEv", "ldr:ro connection: no service", Result, h_ro_Init, void) { return RES_OK; }
HLE_FORCE_OPT("_ZN2nn2ro18RegisterModuleInfoEPNS0_16RegistrationInfoEPKv", "NRR registration: NRO hashes are not checked", Result, h_ro_RegInfo, void *info, const void *nrr) { (void)info; (void)nrr; return RES_OK; }
HLE_FORCE_OPT("_ZN2nn2ro20UnregisterModuleInfoEPNS0_16RegistrationInfoE", "NRR unregistration: as above", Result, h_ro_UnregInfo, void *info) { (void)info; return RES_OK; }
HLE_FORCE_OPT("_ZN2nn2ro13GetBufferSizeEPmPKv", "NRO buffer size: the host loads no NRO", Result, h_ro_BufSize, size_t *out, const void *nro) { (void)nro; *out = 0; return RES_OK; }
HLE_FORCE_OPT("_ZN2nn2ro10LoadModuleEPNS0_6ModuleEPKvPvmi", "load NRO: code loaded at run time would need the offline rewrite first; not supported (fails loudly)", Result, h_ro_Load, void *mod, const void *nro, void *buf, size_t sz, int flag) {
    (void)mod; (void)buf; (void)flag; LOG("[red] nn::ro::LoadModule: the game loads an NRO at run time (%p, buffer %#zx bytes); the host runs only modules rewritten offline, load fails", nro, sz);
    return RES_FAIL;
}
HLE_FORCE_OPT("_ZN2nn2ro12UnloadModuleEPNS0_6ModuleE", "unload NRO: none was loaded", Result, h_ro_Unload, void *mod) { (void)mod; return RES_OK; }
HLE_FORCE_OPT("_ZN2nn2ro12ProtectRelroEPKvS2_S2_S2_S2_", "RELRO protection: the host loader sets segment permissions itself", Result, h_ro_Relro, const void *a, const void *b, const void *c, const void *d, const void *e) {
    (void)a; (void)b; (void)c; (void)d; (void)e; return RES_OK;
}
HLE_FORCE_OPT("_ZN2nn2ro12LookupSymbolEPmPKc", "symbol by name, in the loaded modules (like dlsym)", Result, h_ro_Lookup, uint64_t *out, const char *name) {
    void *p = guest_sym(name);
    if (g_flag.imports) LOG("nn::ro::LookupSymbol %s → %p", name, p);
    if (!p) return RES_FAIL;
    *out = (uint64_t)p; return RES_OK;
}
HLE_FORCE_OPT("_ZN2nn2ro18LookupModuleSymbolEPmPKNS0_6ModuleEPKc", "symbol in a given NRO: the host loaded none", Result, h_ro_LookupMod, uint64_t *out, const void *mod, const char *name) {
    (void)out; (void)mod; LOG("nn::ro::LookupModuleSymbol %s: no NRO loaded", name); return RES_FAIL;
}

// C++ exception unwinding (the sdk's libunwind) fetches the eh_frame_hdr of the module containing pc: the real device uses svc QueryMemory to find the code block containing pc and the data blocks after it,
// then reads the module's MOD0 header. Host modules are not in Horizon memory blocks, so the sdk implementation aborts; here the same result is given directly from the loaded modules.
// ExceptionInfo (written by sdk+0x15a850, read by libunwind at sdk+0x668e64) = { uint64 module start; uint64 module size; uint64 eh_frame_hdr offset from start; uint64 eh_frame_hdr bytes },
// eh_frame_hdr start / end = MOD0 + MOD0[+0x10] / MOD0 + MOD0[+0x14] (signed 32-bit, relative to MOD0). Returns false when pc is in no module.
// The rewriter makes calls from the patch area return to the original call site + 4 (patch_nso.py site_xbranch), so unwinding only passes through original code and the original FDEs apply.
HLE_FORCE_OPT("_ZN2nn2ro6detail16GetExceptionInfoEPNS1_13ExceptionInfoEm", "exception unwinding eh_frame_hdr, from the MOD0 header of the loaded modules", uint32_t, h_ro_ExcInfo, uint64_t *info, uint64_t pc) {
    module_t *m = module_of((const void *)pc);
    if (!m) return 0;
    const uint8_t *mod0 = m->base + *(const uint32_t *)(m->base + 4);
    if (memcmp(mod0, "MOD0", 4)) { LOG("[red] GetExceptionInfo: the MOD0 header of %s is not where it should be", m->name); return 0; }
    int32_t hs = *(const int32_t *)(mod0 + 0x10), he = *(const int32_t *)(mod0 + 0x14);
    info[0] = (uint64_t)m->base; info[1] = m->size;
    info[2] = (uint64_t)(mod0 + hs - m->base); info[3] = (uint64_t)(he - hs);
    return 1;
}
