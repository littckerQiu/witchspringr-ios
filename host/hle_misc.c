// Miscellaneous service layer: add-on content / shop / error applet / profanity filter / server name resolution / parental controls / software keyboard.
// On the real device each goes through IPC or a system applet; the host gives results as single-player offline. Pure-computation SDK parts (hash, util, software Opus) are not taken over, the original implementation is used directly.
#include "game.h"
#include "hle.h"

// ---------- aoc add-on content / ec shop ----------
// Owned add-on content = the profile's aoc list (game.json "aoc", default none). Only for DLC that is an unlock ticket whose content already ships in
// the main RomFS: the host mounts no add-on content data
HLE_FORCE("_ZN2nn3aoc17CountAddOnContentEv", "add-on content count: the profile's aoc list", int, h_aoc_Count, void) { return dm_game.aoc_n; }
// ListAddOnContent(out, start index, max count): writes the owned indices from the start index on, returns how many
HLE_FORCE("_ZN2nn3aoc16ListAddOnContentEPiii", "add-on content list: the profile's aoc list", int, h_aoc_List, int *out, int off, int n) {
    int w = 0;
    for (int i = off; i >= 0 && i < dm_game.aoc_n && w < n; i++) out[w++] = dm_game.aoc[i];
    return w;
}
// The event object is created on demand by the nn::os side table (not signaled), the game waiting on it only times out / gets not-signaled
HLE_FORCE("_ZN2nn3aoc31GetAddOnContentListChangedEventEPNS_2os11SystemEventE", "add-on content change event: bound to a kernel event, never signalled (games poll it with TryWait and abort when it is not initialized)", void, h_aoc_GetEv, void *ev) { hle_bind_system_event(ev, 0); }
HLE_FORCE("_ZN2nn2ec24ShowShopAddOnContentListEv", "shop applet (out of scope): no-op", void, h_ec_ShowShop, void) { LOG("ec::ShowShopAddOnContentList (cut)"); }

// ---------- prepo play reports (telemetry): saving / sending report success, nothing is kept or sent. The Add / Set calls only fill the game's own
// buffer and stay in the SDK; Save goes to the prepo service through sm (TotK aborted there). From nxnative's hle_offline.c (seedds, MIT) ----------
HLE_FORCE_OPT("_ZN2nn5prepo10PlayReport4SaveERKNS_7account3UidE", "play report save (user): not sent, success", Result, h_prepo_SaveU, void *self, const void *uid) { (void)self; (void)uid; return RES_OK; }
HLE_FORCE_OPT("_ZN2nn5prepo10PlayReport4SaveEv", "play report save: not sent, success", Result, h_prepo_Save, void *self) { (void)self; return RES_OK; }
HLE_FORCE_OPT("_ZN2nn5prepo27AddInternetConnectionStatusEPNS0_10PlayReportEPKcS4_S4_", "play report connection status: asks the service on the console; nothing added, success",
              Result, h_prepo_AddNet, void *rep, const char *a, const char *b, const char *c) { (void)rep; (void)a; (void)b; (void)c; return RES_OK; }
HLE_FORCE_OPT("_ZN2nn5prepo28RequestImmediateTransmissionEv", "play report upload now: not sent, success", Result, h_prepo_Tx, void) { return RES_OK; }

// ---------- err error applet: printed by the host ----------
HLE_FORCE("_ZN2nn3err9ShowErrorENS_6ResultE", "error applet; the host logs module / description", void, h_err_ShowError, Result r) {
    LOG("err::ShowError Result=%#x (module %u, description %u)", r, r & 0x1ff, (r >> 9) & 0x1fff);
}

// ---------- ngc profanity filter: the word list is in a system data save (mounted via IPC); single-player has no text visible to others, always judged as no profanity ----------
HLE_FORCE("_ZN2nn3ngc15ProfanityFilterC1Ev", "profanity filter (word list in system save data); not created", void, h_ngc_Ctor, void *self) { (void)self; }
HLE_FORCE("_ZN2nn3ngc15ProfanityFilterD1Ev", "profanity filter", void, h_ngc_Dtor, void *self) { (void)self; }
HLE_FORCE("_ZN2nn3ngc15ProfanityFilter10InitializeEPvm", "profanity filter initialization; no word list", Result, h_ngc_Init, void *self, void *work, uint64_t sz) { (void)self; (void)work; (void)sz; return RES_OK; }
HLE_FORCE("_ZN2nn3ngc15ProfanityFilter17GetContentVersionEv", "word list version: 0", uint32_t, h_ngc_Ver, void *self) { (void)self; return 0; }
HLE_FORCE("_ZN2nn3ngc15ProfanityFilter19CheckProfanityWordsEPjjPPKcm", "profanity check: never matches", Result, h_ngc_Check, void *self, uint32_t *masks, uint32_t pat, const char **words, uint64_t n) {
    (void)self; (void)pat; (void)words;
    for (uint64_t i = 0; i < n; i++) masks[i] = 0;
    return RES_OK;
}

// ---------- nsd server name resolution / pctl free communication: networking, out of scope ----------
HLE_FORCE("_ZN2nn3nsd7ResolveEPNS0_4FqdnERKS1_", "server name resolution (online, out of scope): fails", Result, h_nsd_Resolve, void *out, const void *in) { (void)out; (void)in; return RES_FAIL; }
HLE_FORCE("_ZN2nn3nsd9ResolveExEPNS0_4FqdnERKS1_", "server name resolution (online, out of scope): fails", Result, h_nsd_ResolveEx, void *out, const void *in) { (void)out; (void)in; return RES_FAIL; }
// bool arguments only look at the low 8 bits; returns bool
HLE_FORCE("_ZN2nn4pctl25TryBeginFreeCommunicationEb", "parental control, free communication (online, out of scope): never allowed", unsigned, h_pctl_TryBegin, unsigned show_ui) { (void)show_ui; return 0; }
HLE_FORCE("_ZN2nn4pctl20EndFreeCommunicationEv", "parental control, free communication", void, h_pctl_End, void) {}

// swkbd software keyboard: see hle_swkbd.c

// ---------- libc getenv: the guest's environment ----------
// The console gives an application no environment variables, but libraries still read settings from it: IL2CPP's garbage collector (Boehm) reads
// GC_PRINT_STATS, GC_FREE_SPACE_DIVISOR, GC_MAXIMUM_HEAP_SIZE, … when it starts. DM_GUEST_ENV="NAME=value;NAME=value" gives the guest such
// variables; any other name goes to the SDK's own getenv.
#include <string.h>
HLE_FORCE_OPT("getenv", "guest environment: DM_GUEST_ENV, then the SDK's getenv", char *, h_getenv, const char *name) {
    static char *(*orig)(const char *); static char env[2048]; static int init;
    if (!init) { init = 1; const char *e = getenv("DM_GUEST_ENV"); if (e) { snprintf(env, sizeof env, "%s", e); LOG("DM_GUEST_ENV: %s", env); }
                 for (int i = 0; i < g_nmod; i++) if (!strcmp(g_mod[i].name, "sdk")) orig = (char *(*)(const char *))module_sym(&g_mod[i], "getenv"); }
    size_t n = name ? strlen(name) : 0;
    for (char *p = env; n && *p; ) {
        char *end = strchr(p, ';'); size_t len = end ? (size_t)(end - p) : strlen(p);
        if (len > n && p[n] == '=' && !strncmp(p, name, n)) {
            static char val[16][256]; static int k; char *v = val[k++ & 15]; size_t vl = len - n - 1; if (vl > 255) vl = 255;
            memcpy(v, p + n + 1, vl); v[vl] = 0;
            { static int said; if (said++ < 32) LOG("guest getenv(\"%s\") = \"%s\" (DM_GUEST_ENV)", name, v); }
            return v;
        }
        p += len + (end != NULL);
    }
    { static int said; if (env[0] && said++ < 32) LOG("guest getenv(\"%s\") → the SDK's", name ? name : "(null)"); }   // listed only when DM_GUEST_ENV is in use
    return orig ? orig(name) : NULL;
}
