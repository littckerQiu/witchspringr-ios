// nn::hid (controllers / touchscreen): on the console the state comes from hid shared memory; the host builds it from what the front end publishes
// (dm_input.h: keyboard / touch / game controller) plus the DM_KEYS script. The connected controller follows the operation mode: DM_OPMODE=1
// (console, default) → player 1 full-key controller; 0 (handheld) → handheld controller. No vibration devices.
#include "hle.h"
#include "dm_input.h"
#include "front.h"
#include <stdatomic.h>
#include <unistd.h>

enum { NPAD_HANDHELD = 0x20 };
enum { STYLE_FULLKEY = 1u << 0, STYLE_HANDHELD = 1u << 1 };
enum { ATTR_CONNECTED = 1u << 0 };

// nn::hid::NpadFullKeyState / NpadHandheldState (same layout)
typedef struct {
    int64_t sampling;
    uint64_t buttons;
    int32_t lx, ly, rx, ry;
    uint32_t attributes;
    uint32_t _pad;
} NpadState;
_Static_assert(sizeof(NpadState) == 0x28, "NpadState");

static struct { _Atomic uint64_t buttons; _Atomic int32_t lx, ly, rx, ry; } g_in;
static _Atomic int64_t g_sampling;
// Press-edge latch: a key the front end turns from released to pressed is kept until the game's next read, so a press and release between two reads
// (a quick tap, or the game not reading input while loading) is still seen once; afterwards the current value applies
static _Atomic uint64_t g_press_latch;
// Game controller (dm_pad_set): buttons and the four axes in two atomics, press edges latched the same way
static _Atomic uint64_t g_pad_btn, g_pad_axes, g_pad_latch;
void dm_pad_set(uint64_t buttons, int32_t lx, int32_t ly, int32_t rx, int32_t ry) {
    uint64_t old = atomic_exchange(&g_pad_btn, buttons); atomic_fetch_or(&g_pad_latch, buttons & ~old);
    atomic_store(&g_pad_axes, (uint64_t)(uint16_t)lx | (uint64_t)(uint16_t)ly << 16 | (uint64_t)(uint16_t)rx << 32 | (uint64_t)(uint16_t)ry << 48);
}
void dm_input_set(uint64_t buttons, int32_t lx, int32_t ly, int32_t rx, int32_t ry) {
    atomic_fetch_or(&g_press_latch, buttons & ~g_in.buttons);
    g_in.buttons = buttons; g_in.lx = lx; g_in.ly = ly; g_in.rx = rx; g_in.ry = ry;
}
uint64_t dm_input_samples(void) { return (uint64_t)atomic_load(&g_sampling); }   // how many times the game has read a controller

static uint32_t connected_id(void) { return dm_opmode() == 0 ? NPAD_HANDHELD : 0; }   // follows the operation mode (hle_oe.c)
uint32_t hle_hid_connected_npad(void) { return connected_id(); }   // nfp's NFC device sits on this controller (hle_nfp.c)
static uint32_t style_of(uint32_t id) {
    if (id != connected_id()) return 0;
    return id == NPAD_HANDHELD ? STYLE_HANDHELD : STYLE_FULLKEY;
}

// ---------- Scripted input DM_KEYS (inject without a window) ----------
// Comma separated items key@seconds[+hold seconds], time counted from host start; hold defaults to 0.2 s. key@f<frame>[+hold frames] counts presented
// frames instead (dm_nvn_frame_count; hold defaults to 12 frames): when the machine is busy, seconds drift from the game's progress and frames do not
// (after nxnative d6cd8a8).
//   DM_KEYS="A@8,A@12+0.5" = A at 8 s, A held 0.5 s at 12 s; "A@f3600" = A at frame 3600 for 12 frames.
// Key names = DM_BTN_* of dm_input.h without the prefix, plus left stick pseudo-keys LSL / LSR / LSU / LSD (stick pushed fully while held), plus touch
// T<x>:<y> = one finger at normalized picture coordinates (origin top left) while held. Script keys are ORed with what the front end publishes.
#define K(n) {DM_BTN_##n, #n}
static const struct { uint32_t mask; const char *name; } k_names[] = {
    K(A), K(B), K(X), K(Y), K(LS), K(RS), K(L), K(R), K(ZL), K(ZR), K(PLUS), K(MINUS), K(LEFT), K(UP), K(RIGHT), K(DOWN)};
#undef K
enum { PK_LSL = 1u << 24, PK_LSR = 1u << 25, PK_LSU = 1u << 26, PK_LSD = 1u << 27, PK_MASK = 0xFu << 24, PK_TOUCH = 1u << 28 };   // outside the button bits
static const struct { uint32_t mask; const char *name; } k_stick[] = {{PK_LSL, "LSL"}, {PK_LSR, "LSR"}, {PK_LSU, "LSU"}, {PK_LSD, "LSD"}};
#define KMAX 256
static struct { uint32_t mask; uint64_t t0, t1; float tx, ty; int frame; } g_keys[KMAX];   // frame: t0 / t1 are frame numbers
static int g_nkeys;
static uint64_t g_kbase;
static _Atomic uint64_t g_cmd_mask;   // keys held through the command channel (cmdchan.c), ORed with the script's
// The key of a DM_KEYS name (a button or a left stick pseudo-key; 0 for touch items and unknown names), for the command channel
uint32_t hid_key_mask(const char *name) {
    for (int i = 0; i < (int)(sizeof k_names / sizeof *k_names); i++) if (!strcmp(name, k_names[i].name)) return k_names[i].mask;
    for (int i = 0; i < 4; i++) if (!strcmp(name, k_stick[i].name)) return k_stick[i].mask;
    return 0;
}
void hid_cmd_keys(uint64_t down, uint64_t up) { atomic_fetch_or(&g_cmd_mask, down); atomic_fetch_and(&g_cmd_mask, ~up); }
static void keys_parse(void) {
    g_nkeys = 0; g_kbase = now_ns();
    const char *e = getenv("DM_KEYS"); if (!e) e = "";
    char buf[4096]; strncpy(buf, e, sizeof buf - 1); buf[sizeof buf - 1] = 0;
    for (char *save, *tok = strtok_r(buf, ",", &save); tok; tok = strtok_r(NULL, ",", &save)) {
        char *at = strchr(tok, '@'); if (!at) die("DM_KEYS item \"%s\": missing @seconds", tok);
        *at = 0;
        uint32_t mask = 0; float tx = 0, ty = 0;
        if (tok[0] == 'T' && ((tok[1] >= '0' && tok[1] <= '9') || tok[1] == '.')) {
            char *c = strchr(tok, ':'); if (!c) die("DM_KEYS touch item \"%s\": expected T<x>:<y>@seconds", tok);
            tx = (float)atof(tok + 1); ty = (float)atof(c + 1); mask = PK_TOUCH;
        }
        for (int i = 0; i < (int)(sizeof k_names / sizeof *k_names); i++) if (!strcmp(tok, k_names[i].name)) mask = k_names[i].mask;
        for (int i = 0; i < 4; i++) if (!strcmp(tok, k_stick[i].name)) mask = k_stick[i].mask;
        if (!mask) die("DM_KEYS: unknown key \"%s\"", tok);
        const char *v = at + 1; int frame = *v == 'f'; v += frame;
        if (!((*v >= '0' && *v <= '9') || *v == '.')) die("DM_KEYS item \"%s@%s\": expected seconds or f<frame> after @", tok, at + 1);
        char *plus = strchr(v, '+');
        double t = atof(v), d = plus ? atof(plus + 1) : frame ? 12 : 0.2, u = frame ? 1 : 1e9;
        if (g_nkeys == KMAX) die("DM_KEYS: more than %d items", KMAX);
        g_keys[g_nkeys++] = (typeof(g_keys[0])){mask, (uint64_t)(t * u), (uint64_t)((t + d) * u), tx, ty, frame};
    }
    if (g_nkeys) LOG("hid script: %d timed items", g_nkeys);
}
static pthread_once_t g_kone = PTHREAD_ONCE_INIT;
void hid_keys_init(void) { pthread_once(&g_kone, keys_parse); }
static uint64_t keys_now(void) {
    pthread_once(&g_kone, keys_parse);
    uint64_t t = now_ns() - g_kbase, m = 0, f = g_nkeys ? dm_nvn_frame_count() : 0;
    // Touch items active now are pushed to the touchscreen as one set (hle_touch.c), only when the set changes
    dm_touch act[16]; int na = 0; uint32_t on = 0;
    for (int i = 0; i < g_nkeys; i++) if ((g_keys[i].frame ? f : t) >= g_keys[i].t0 && (g_keys[i].frame ? f : t) < g_keys[i].t1) {
        if (!(g_keys[i].mask & PK_TOUCH)) { m |= g_keys[i].mask; continue; }
        if (na < 16) { act[na] = (dm_touch){(uint32_t)na, g_keys[i].tx, g_keys[i].ty}; on |= 1u << i % 32; na++; }
    }
    m |= atomic_load(&g_cmd_mask);
    static _Atomic uint32_t touch_on; static _Atomic int touch_n;
    int changed = atomic_exchange(&touch_on, on) != on; changed |= atomic_exchange(&touch_n, na) != na;   // both exchanges always run
    if (changed) dm_touch_set(act, na);
    static _Atomic uint64_t seen;   // one line the first time a key is really read by the game (proves the injection arrived)
    uint64_t newbits = m & ~atomic_fetch_or(&seen, m);
    if (newbits) LOG("hid script key first read: mask=%#llx @%.2fs", newbits, t / 1e9);
    return m;
}

// Optional log of real GetNpadState returns, DM_HID_RECEIPT_LOG=<JSONL path>: state changes plus at most one activity line per second, ending with
// limit_reached after 1024 lines (a truncated log is not complete evidence). read_start_ns / time_ns use now_ns(), the same clock front ends use.
static FILE *g_receipt_file;
static pthread_once_t g_receipt_once = PTHREAD_ONCE_INIT;
static pthread_mutex_t g_receipt_lock = PTHREAD_MUTEX_INITIALIZER;
static void receipt_init(void) {
    const char *path = getenv("DM_HID_RECEIPT_LOG");
    if (path && *path) {
        g_receipt_file = fopen(path, "w");
        if (!g_receipt_file) LOG("[red] DM_HID_RECEIPT_LOG: cannot open %s", path);
    }
}
static void receipt(const NpadState *s, uint32_t id, uint32_t style, uint64_t km, uint64_t read_start_ns) {
    if (!g_receipt_file) return;
    static NpadState last; static uint32_t last_id, last_style;
    static uint64_t last_km, last_ns; static unsigned count; static int have, truncated;
    NpadState state = *s; state.sampling = 0; uint64_t t = now_ns();
    pthread_mutex_lock(&g_receipt_lock);
    if (truncated || (have && id == last_id && style == last_style && km == last_km && !memcmp(&state, &last, sizeof state) && t - last_ns < 1000000000ull)) {
        pthread_mutex_unlock(&g_receipt_lock); return;
    }
    if (count == 1024) {
        fprintf(g_receipt_file, "{\"event\":\"limit_reached\",\"limit\":1024}\n"); truncated = 1;
    } else {
        fprintf(g_receipt_file, "{\"event\":\"npad_return\",\"read_start_ns\":%llu,\"time_ns\":%llu,\"sampling\":%lld,\"id\":%u,\"style\":%u,\"buttons\":%llu,\"lx\":%d,\"ly\":%d,\"rx\":%d,\"ry\":%d,\"attributes\":%u,\"script_mask\":%llu}\n",
                (unsigned long long)read_start_ns, (unsigned long long)t, (long long)s->sampling, id, style, (unsigned long long)s->buttons,
                s->lx, s->ly, s->rx, s->ry, s->attributes, (unsigned long long)km);
        last = state; last_id = id; last_style = style; last_km = km; last_ns = t; have = 1; count++;
    }
    if (fflush(g_receipt_file)) { LOG("[red] DM_HID_RECEIPT_LOG: write failed"); truncated = 1; }
    pthread_mutex_unlock(&g_receipt_lock);
}

// On-screen controls (touchpad.c), for a game with game.json "touch": "pad"; this default when the host is built without them (the tests)
__attribute__((weak)) int dm_touchpad_read(uint64_t *buttons, int32_t *lx, int32_t *ly, int32_t *rx, int32_t *ry) { (void)buttons; (void)lx; (void)ly; (void)rx; (void)ry; return 0; }
// The controller the game last read (touchpad.c's DM_TEST_TOUCHPAD checks it); 0 before the first read
static _Atomic uint64_t g_last_btn, g_last_axes; static _Atomic int g_last_have;
int hle_hid_last(uint64_t *buttons, int32_t *lx, int32_t *ly, int32_t *rx, int32_t *ry) {
    uint64_t ax = atomic_load(&g_last_axes); *buttons = atomic_load(&g_last_btn);
    *lx = (int16_t)ax; *ly = (int16_t)(ax >> 16); *rx = (int16_t)(ax >> 32); *ry = (int16_t)(ax >> 48);
    return atomic_load(&g_last_have);
}
// Controller state = front end + on-screen controls + script + game controller: buttons ORed; each stick from the first of the front end, the
// on-screen controls and the controller that pushes it
static void fill(NpadState *s, uint32_t id, uint32_t style) {
    pthread_once(&g_receipt_once, receipt_init);
    uint64_t read_start_ns = g_receipt_file ? now_ns() : 0;
    memset(s, 0, sizeof *s);
    s->sampling = ++g_sampling;
    if (!(style_of(id) & style)) { receipt(s, id, style, 0, read_start_ns); return; }   // style not connected: all zero
    uint64_t km = keys_now();
    s->buttons = (g_in.buttons | atomic_exchange(&g_press_latch, 0)) | (km & ~(uint64_t)PK_MASK) | atomic_load(&g_pad_btn) | atomic_exchange(&g_pad_latch, 0);
    s->lx = g_in.lx; s->ly = g_in.ly; s->rx = g_in.rx; s->ry = g_in.ry;
    { uint64_t tb; int32_t t[4];
      if (dm_touchpad_read(&tb, &t[0], &t[1], &t[2], &t[3])) {
          s->buttons |= tb;
          if (!(s->lx || s->ly)) { s->lx = t[0]; s->ly = t[1]; } if (!(s->rx || s->ry)) { s->rx = t[2]; s->ry = t[3]; } } }
    { uint64_t ax = atomic_load(&g_pad_axes); int16_t plx = (int16_t)ax, ply = (int16_t)(ax >> 16), prx = (int16_t)(ax >> 32), pry = (int16_t)(ax >> 48);
      if (!(s->lx || s->ly) && (plx || ply)) { s->lx = plx; s->ly = ply; } if (!(s->rx || s->ry) && (prx || pry)) { s->rx = prx; s->ry = pry; } }
    if (km & PK_LSL) s->lx = -32767; if (km & PK_LSR) s->lx = 32767;   // script stick pseudo-keys (up is positive)
    if (km & PK_LSU) s->ly = 32767;  if (km & PK_LSD) s->ly = -32767;
    s->attributes = ATTR_CONNECTED;
    atomic_store(&g_last_btn, s->buttons);
    atomic_store(&g_last_axes, (uint64_t)(uint16_t)s->lx | (uint64_t)(uint16_t)s->ly << 16 | (uint64_t)(uint16_t)s->rx << 32 | (uint64_t)(uint16_t)s->ry << 48);
    atomic_store(&g_last_have, 1);
    receipt(s, id, style, km, read_start_ns);
}

HLE_FORCE("_ZN2nn3hid14InitializeNpadEv", "connects to the hid service; input comes from dm_input", void, h_hid_InitNpad, void) {}
HLE_FORCE("_ZN2nn3hid21InitializeTouchScreenEv", "connects to the hid service; touch comes from the front end", void, h_hid_InitTouch, void) {}
HLE_FORCE("_ZN2nn3hid22SetSupportedNpadIdTypeEPKjm", "supported Npad ids: fixed", void, h_hid_SetIds, const uint32_t *ids, uint64_t n) { (void)ids; (void)n; }
// BitFlagSet<32> is passed by value in a w register
HLE_FORCE("_ZN2nn3hid24SetSupportedNpadStyleSetENS_4util10BitFlagSetILi32ENS0_12NpadStyleTagEEE", "supported Npad styles: fixed", void, h_hid_SetStyles, uint32_t styles) { (void)styles; }
HLE_FORCE("_ZN2nn3hid29SetNpadHandheldActivationModeENS0_26NpadHandheldActivationModeE", "handheld activation mode: fixed", void, h_hid_SetHhMode, int m) { (void)m; }
HLE_FORCE("_ZN2nn3hid15GetNpadStyleSetERKj", "Npad style: follows DM_OPMODE", uint32_t, h_hid_GetStyle, const uint32_t *id) { return style_of(*id); }
HLE_FORCE("_ZN2nn3hid12GetNpadStateEPNS0_16NpadFullKeyStateERKj", "full key Npad state, from dm_input", void, h_hid_GetFullKey, NpadState *s, const uint32_t *id) { fill(s, *id, STYLE_FULLKEY); }
HLE_FORCE("_ZN2nn3hid12GetNpadStateEPNS0_17NpadHandheldStateERKj", "handheld Npad state, from dm_input", void, h_hid_GetHandheld, NpadState *s, const uint32_t *id) { fill(s, *id, STYLE_HANDHELD); }

// Vibration: device count 0, the game will not initialize / send any further
HLE_FORCE("_ZN2nn3hid20IsVibrationPermittedEv", "vibration permitted: no (returns bool)", unsigned, h_hid_VibPermit, void) { return 0; }
HLE_FORCE("_ZN2nn3hid25GetVibrationDeviceHandlesEPNS0_21VibrationDeviceHandleEiRKjNS_4util10BitFlagSetILi32ENS0_12NpadStyleTagEEE",
          "vibration devices: none", int, h_hid_GetVibHandles, void *out, int max, const uint32_t *id, uint32_t style) { (void)out; (void)max; (void)id; (void)style; return 0; }
HLE_FORCE("_ZN2nn3hid25InitializeVibrationDeviceERKNS0_21VibrationDeviceHandleE", "vibration: not supported", void, h_hid_InitVib, const void *h) { (void)h; }
HLE_FORCE("_ZN2nn3hid18SendVibrationValueERKNS0_21VibrationDeviceHandleERKNS0_14VibrationValueE", "vibration: not supported", void, h_hid_SendVib, const void *h, const void *v) { (void)h; (void)v; }

// Touchscreen: nn::hid::TouchScreenState<16> = { int64 sampling; int32 count; int32 _r; TouchState touches[16] (0x28 each) }
// Contents are filled by hle_touch.c from the touch points pushed by the front end (see that file for the layout and the short-press latch); the game only looks at entry 0, returns the number of states written, 1
typedef struct { int64_t sampling; int32_t count, _r; uint8_t touches[16][0x28]; } TouchState16;
_Static_assert(sizeof(TouchState16) == 0x290, "TouchScreenState<16>");
int touch_fill(void *out, uint64_t now_ns);
HLE_FORCE("_ZN2nn3hid20GetTouchScreenStatesILm16EEEiPNS0_16TouchScreenStateIXT_EEEi", "touch screen state: the front end's touches (hle_touch.c)", int, h_hid_GetTouch, TouchState16 *out, int n) {
    if (n < 1) return 0;
    touch_fill(out, guest_ns());
    return 1;
}

// ---------- nn::hid APIs other games use (Unity's input module links the whole set) ----------
// Npad state variants share fill(): a style the host does not connect (Joy-Con dual / left / right) reads as not connected.
// Touch: TouchScreenState<N> = { int64 sampling; int32 count; int32 _r; TouchState touches[N] } (0x28 each, same as <16> above);
// filled through a 16-slot scratch and cut to N, so a smaller array is never overrun.
static void touch_fill_n(void *out, unsigned n) {
    TouchState16 t; touch_fill(&t, guest_ns());
    if (t.count > (int32_t)n) t.count = (int32_t)n;
    memcpy(out, &t, 16 + (size_t)n * 0x28);
}
#define TOUCH_N(n) \
    HLE_FORCE_OPT("_ZN2nn3hid20GetTouchScreenStatesILm" #n "EEEiPNS0_16TouchScreenStateIXT_EEEi", "touch screen state<" #n ">: the front end's touches", int, h_hid_GetTouchs##n, void *out, int cnt) { if (cnt < 1) return 0; touch_fill_n(out, n); return 1; } \
    HLE_FORCE_OPT("_ZN2nn3hid19GetTouchScreenStateILm" #n "EEEvPNS0_16TouchScreenStateIXT_EEE", "touch screen state<" #n "> (single): the front end's touches", void, h_hid_GetTouch1_##n, void *out) { touch_fill_n(out, n); }
TOUCH_N(1) TOUCH_N(2) TOUCH_N(3) TOUCH_N(4) TOUCH_N(5) TOUCH_N(6) TOUCH_N(7) TOUCH_N(8) TOUCH_N(9) TOUCH_N(10) TOUCH_N(11) TOUCH_N(12) TOUCH_N(13) TOUCH_N(14) TOUCH_N(15)
HLE_FORCE_OPT("_ZN2nn3hid19GetTouchScreenStateILm16EEEvPNS0_16TouchScreenStateIXT_EEE", "touch screen state<16> (single): the front end's touches", void, h_hid_GetTouch1_16, void *out) { touch_fill_n(out, 16); }

enum { STYLE_JOYDUAL = 1u << 2, STYLE_JOYLEFT = 1u << 3, STYLE_JOYRIGHT = 1u << 4 };
#define NPAD_ONE(mangled, style, cname) HLE_FORCE_OPT(mangled, "Npad state (single), from dm_input", void, cname, NpadState *s, const uint32_t *id) { fill(s, *id, style); }
#define NPAD_MANY(mangled, style, cname) HLE_FORCE_OPT(mangled, "Npad states (several; only the first is written), from dm_input", int, cname, NpadState *s, int n, const uint32_t *id) { if (n < 1) return 0; fill(s, *id, style); return 1; }
NPAD_ONE("_ZN2nn3hid12GetNpadStateEPNS0_16NpadJoyDualStateERKj", STYLE_JOYDUAL, h_hid_GetJoyDual)
NPAD_ONE("_ZN2nn3hid12GetNpadStateEPNS0_16NpadJoyLeftStateERKj", STYLE_JOYLEFT, h_hid_GetJoyLeft)
NPAD_ONE("_ZN2nn3hid12GetNpadStateEPNS0_17NpadJoyRightStateERKj", STYLE_JOYRIGHT, h_hid_GetJoyRight)
NPAD_MANY("_ZN2nn3hid13GetNpadStatesEPNS0_16NpadFullKeyStateEiRKj", STYLE_FULLKEY, h_hid_GetFullKeyN)
NPAD_MANY("_ZN2nn3hid13GetNpadStatesEPNS0_17NpadHandheldStateEiRKj", STYLE_HANDHELD, h_hid_GetHandheldN)
NPAD_MANY("_ZN2nn3hid13GetNpadStatesEPNS0_16NpadJoyDualStateEiRKj", STYLE_JOYDUAL, h_hid_GetJoyDualN)
NPAD_MANY("_ZN2nn3hid13GetNpadStatesEPNS0_16NpadJoyLeftStateEiRKj", STYLE_JOYLEFT, h_hid_GetJoyLeftN)
NPAD_MANY("_ZN2nn3hid13GetNpadStatesEPNS0_17NpadJoyRightStateEiRKj", STYLE_JOYRIGHT, h_hid_GetJoyRightN)

static _Atomic int g_hold_type = 1, g_comm_mode;   // NpadJoyHoldType 1 = horizontal (system default)
HLE_FORCE_OPT("_ZN2nn3hid18SetNpadJoyHoldTypeENS0_15NpadJoyHoldTypeE", "Joy-Con hold type: kept and returned as set", void, h_hid_SetHold, int t) { atomic_store(&g_hold_type, t); }
HLE_FORCE_OPT("_ZN2nn3hid18GetNpadJoyHoldTypeEv", "Joy-Con hold type: the value the game set", int, h_hid_GetHold, void) { return atomic_load(&g_hold_type); }
HLE_FORCE_OPT("_ZN2nn3hid24SetNpadCommunicationModeENS0_21NpadCommunicationModeE", "Npad communication mode: kept", void, h_hid_SetComm, int m) { atomic_store(&g_comm_mode, m); }
HLE_FORCE_OPT("_ZN2nn3hid24GetNpadCommunicationModeEv", "Npad communication mode: the value the game set", int, h_hid_GetComm, void) { return atomic_load(&g_comm_mode); }
HLE_FORCE_OPT("_ZN2nn3hid29GetNpadHandheldActivationModeEv", "handheld activation mode: 0", int, h_hid_GetHhMode, void) { return 0; }
HLE_FORCE_OPT("_ZN2nn3hid24GetSupportedNpadStyleSetEv", "supported Npad styles: full key + handheld", uint32_t, h_hid_GetSupStyles, void) { return STYLE_FULLKEY | STYLE_HANDHELD; }
HLE_FORCE_OPT("_ZN2nn3hid20GetNpadJoyAssignmentERKj", "Joy-Con assignment: 0 = dual", int, h_hid_GetAssign, const uint32_t *id) { (void)id; return 0; }
HLE_FORCE_OPT("_ZN2nn3hid19GetPlayerLedPatternERKj", "player LED pattern: LED 1", uint32_t, h_hid_LedPattern, const uint32_t *id) { (void)id; return 1; }
// Result: the caller checks it, nothing is written
HLE_FORCE_OPT("_ZN2nn3hid22GetNpadControllerColorEPNS0_19NpadControllerColorERKj", "controller color: none, fails without writing", Result, h_hid_Color1, void *c, const uint32_t *id) { (void)c; (void)id; return RES_FAIL; }
HLE_FORCE_OPT("_ZN2nn3hid22GetNpadControllerColorEPNS0_19NpadControllerColorES2_RKj", "controller colors (left / right): none, fails without writing", Result, h_hid_Color2, void *l, void *r, const uint32_t *id) { (void)l; (void)r; (void)id; return RES_FAIL; }
// Style set update event: bound once per caller-provided event, never signaled (the host's controller style only changes with the operation mode)
HLE_FORCE_OPT("_ZN2nn3hid27BindNpadStyleSetUpdateEventERKjPNS_2os15SystemEventTypeENS3_14EventClearModeE", "Npad style update event: bound to a kernel event, never signalled", void, h_hid_BindStyleEv, const uint32_t *id, void *ev, int mode) {
    (void)id; hle_bind_system_event(ev, mode == 1);
}

// Stubs: logged once, return 0, write nothing (structure sizes not established yet; see the log for which ones the game calls)
#define HID_STUB(mangled, cname, label) HLE_FORCE_OPT(mangled, "hid stub: logged once, returns 0, writes nothing", uint64_t, cname, void) { static int once; if (!once++) LOG("hid stub called: %s", label); return 0; }
HID_STUB("_ZN2nn3hid13GetMouseStateEPNS0_10MouseStateERKNS0_11MouseHandleE", h_hid_stub1, "nn::hid::GetMouseState(nn::hid::MouseState*, nn::hid::MouseHandle const&)")
HID_STUB("_ZN2nn3hid14DisconnectNpadERKj", h_hid_stub2, "nn::hid::DisconnectNpad(unsigned int const&)")
HID_STUB("_ZN2nn3hid14GetMouseHandleEv", h_hid_stub3, "nn::hid::GetMouseHandle()")
HID_STUB("_ZN2nn3hid14GetMouseStatesEPNS0_10MouseStateEiRKNS0_11MouseHandleE", h_hid_stub4, "nn::hid::GetMouseStates(nn::hid::MouseState*, int, nn::hid::MouseHandle const&)")
HID_STUB("_ZN2nn3hid15InitializeMouseERKNS0_11MouseHandleE", h_hid_stub5, "nn::hid::InitializeMouse(nn::hid::MouseHandle const&)")
HID_STUB("_ZN2nn3hid16GetGestureStatesEPNS0_12GestureStateEi", h_hid_stub6, "nn::hid::GetGestureStates(nn::hid::GestureState*, int)")
// KeyboardState = 0x30 bytes (the sdk's detail::GetKeyboardState at sdk+0x502710 copies 0x30): int64 sampling number + modifiers / attributes + 256 key bits.
// The host attaches no USB keyboard: only the sampling number advances, the rest is 0 (not connected, no key down). It used to be a stub that wrote nothing, so the game read uninitialized stack contents every frame.
HLE_FORCE_OPT("_ZN2nn3hid16GetKeyboardStateEPNS0_13KeyboardStateE", "keyboard state: not connected (sampling number counts up, the rest 0)", void, h_hid_GetKeyboard, uint8_t *out) {
    static _Atomic int64_t n; memset(out, 0, 0x30); int64_t v = atomic_fetch_add(&n, 1) + 1; memcpy(out, &v, 8);
}
// Mouse without a handle (TotK main): not connected. Without these the sdk opens the hid service proxy (sm::Initialize aborts, from InitializeMouse
// in TotK's startup). From nxnative's hle_hid.c (seedds, MIT)
HLE_FORCE_OPT("_ZN2nn3hid15InitializeMouseEv", "mouse: the host provides none", void, h_hid_InitMouse0, void) {}
HLE_FORCE_OPT("_ZN2nn3hid14GetMouseStatesEPNS0_10MouseStateEi", "mouse states: none written", int, h_hid_MouseStates0, void *out, int n) { (void)out; (void)n; return 0; }
// Values queued by the vibration graph reach the sdk's FlushEnqueuedVibrationValues and from there the hid service proxy: success, nothing sent
// (nxnative, Metroid Dread)
HLE_FORCE_OPT("_ZN2nn3hid6detail19SendVibrationValuesEPKNS0_21VibrationDeviceHandleEPKNS0_14VibrationValueEi", "vibration (batch): the host has none", Result, h_hid_SendVibs, const void *h, const void *v, int n) {
    (void)h; (void)v; (void)n; return 0;
}
HID_STUB("_ZN2nn3hid17InitializeGestureEii", h_hid_stub8, "nn::hid::InitializeGesture(int, int)")
HID_STUB("_ZN2nn3hid17InitializeGestureEv", h_hid_stub9, "nn::hid::InitializeGesture()")
HID_STUB("_ZN2nn3hid17StopSixAxisSensorERKNS0_19SixAxisSensorHandleE", h_hid_stub10, "nn::hid::StopSixAxisSensor(nn::hid::SixAxisSensorHandle const&)")
HID_STUB("_ZN2nn3hid18InitializeKeyboardEv", h_hid_stub11, "nn::hid::InitializeKeyboard()")
HID_STUB("_ZN2nn3hid18StartSixAxisSensorERKNS0_19SixAxisSensorHandleE", h_hid_stub12, "nn::hid::StartSixAxisSensor(nn::hid::SixAxisSensorHandle const&)")
HID_STUB("_ZN2nn3hid18SwapNpadAssignmentERKjS2_", h_hid_stub13, "nn::hid::SwapNpadAssignment(unsigned int const&, unsigned int const&)")
HID_STUB("_ZN2nn3hid19GetDebugMouseHandleEv", h_hid_stub14, "nn::hid::GetDebugMouseHandle()")
HID_STUB("_ZN2nn3hid20StopLrAssignmentModeEv", h_hid_stub15, "nn::hid::StopLrAssignmentMode()")
HID_STUB("_ZN2nn3hid21GetSixAxisSensorStateEPNS0_18SixAxisSensorStateERKNS0_19SixAxisSensorHandleE", h_hid_stub16, "nn::hid::GetSixAxisSensorState(nn::hid::SixAxisSensorState*, nn::hid::SixAxisSensorHandle const&)")
HID_STUB("_ZN2nn3hid21InitializeTouchScreenEii", h_hid_stub17, "nn::hid::InitializeTouchScreen(int, int)")
HID_STUB("_ZN2nn3hid21IsSixAxisSensorAtRestERKNS0_19SixAxisSensorHandleE", h_hid_stub18, "nn::hid::IsSixAxisSensorAtRest(nn::hid::SixAxisSensorHandle const&)")
HID_STUB("_ZN2nn3hid21ShowControllerSupportEPNS0_27ControllerSupportResultInfoERKNS0_20ControllerSupportArgE", h_hid_stub19, "nn::hid::ShowControllerSupport(nn::hid::ControllerSupportResultInfo*, nn::hid::ControllerSupportArg const&)")
HID_STUB("_ZN2nn3hid21ShowControllerSupportERKNS0_20ControllerSupportArgE", h_hid_stub20, "nn::hid::ShowControllerSupport(nn::hid::ControllerSupportArg const&)")
HID_STUB("_ZN2nn3hid21StartLrAssignmentModeEv", h_hid_stub21, "nn::hid::StartLrAssignmentMode()")
HID_STUB("_ZN2nn3hid22GetSixAxisSensorStatesEPNS0_18SixAxisSensorStateEiRKNS0_19SixAxisSensorHandleE", h_hid_stub22, "nn::hid::GetSixAxisSensorStates(nn::hid::SixAxisSensorState*, int, nn::hid::SixAxisSensorHandle const&)")
HID_STUB("_ZN2nn3hid22GetVibrationDeviceInfoEPNS0_19VibrationDeviceInfoERKNS0_21VibrationDeviceHandleE", h_hid_stub23, "nn::hid::GetVibrationDeviceInfo(nn::hid::VibrationDeviceInfo*, nn::hid::VibrationDeviceHandle const&)")
HID_STUB("_ZN2nn3hid23GetActualVibrationValueEPNS0_14VibrationValueERKNS0_21VibrationDeviceHandleE", h_hid_stub24, "nn::hid::GetActualVibrationValue(nn::hid::VibrationValue*, nn::hid::VibrationDeviceHandle const&)")
HID_STUB("_ZN2nn3hid23GetSixAxisSensorHandlesEPNS0_19SixAxisSensorHandleEiRKjNS_4util10BitFlagSetILi32ENS0_12NpadStyleTagEEE", h_hid_stub25, "nn::hid::GetSixAxisSensorHandles(nn::hid::SixAxisSensorHandle*, int, unsigned int const&, nn::util::BitFlagSet<32, nn::hid::NpadStyleTag>)")
HID_STUB("_ZN2nn3hid23MergeSingleJoyAsDualJoyERKjS2_", h_hid_stub26, "nn::hid::MergeSingleJoyAsDualJoy(unsigned int const&, unsigned int const&)")
HID_STUB("_ZN2nn3hid24ShowControllerStrapGuideEv", h_hid_stub27, "nn::hid::ShowControllerStrapGuide()")
HID_STUB("_ZN2nn3hid25EnableSixAxisSensorFusionERKNS0_19SixAxisSensorHandleEb", h_hid_stub28, "nn::hid::EnableSixAxisSensorFusion(nn::hid::SixAxisSensorHandle const&, bool)")
HID_STUB("_ZN2nn3hid25GetGyroscopeZeroDriftModeERKNS0_19SixAxisSensorHandleE", h_hid_stub29, "nn::hid::GetGyroscopeZeroDriftMode(nn::hid::SixAxisSensorHandle const&)")
HID_STUB("_ZN2nn3hid25SetGyroscopeZeroDriftModeERKNS0_19SixAxisSensorHandleERKNS0_22GyroscopeZeroDriftModeE", h_hid_stub30, "nn::hid::SetGyroscopeZeroDriftMode(nn::hid::SixAxisSensorHandle const&, nn::hid::GyroscopeZeroDriftMode const&)")
HID_STUB("_ZN2nn3hid28IsSixAxisSensorFusionEnabledERKNS0_19SixAxisSensorHandleE", h_hid_stub31, "nn::hid::IsSixAxisSensorFusionEnabled(nn::hid::SixAxisSensorHandle const&)")
HID_STUB("_ZN2nn3hid28SetNpadJoyAssignmentModeDualERKj", h_hid_stub32, "nn::hid::SetNpadJoyAssignmentModeDual(unsigned int const&)")
HID_STUB("_ZN2nn3hid28ShowControllerFirmwareUpdateERKNS0_27ControllerFirmwareUpdateArgE", h_hid_stub33, "nn::hid::ShowControllerFirmwareUpdate(nn::hid::ControllerFirmwareUpdateArg const&)")
HID_STUB("_ZN2nn3hid30SetNpadJoyAssignmentModeSingleEPjRKjNS0_17NpadJoyDeviceTypeE", h_hid_stub34, "nn::hid::SetNpadJoyAssignmentModeSingle(unsigned int*, unsigned int const&, nn::hid::NpadJoyDeviceType)")
HID_STUB("_ZN2nn3hid30SetNpadJoyAssignmentModeSingleERKj", h_hid_stub35, "nn::hid::SetNpadJoyAssignmentModeSingle(unsigned int const&)")
HID_STUB("_ZN2nn3hid30SetNpadJoyAssignmentModeSingleERKjNS0_17NpadJoyDeviceTypeE", h_hid_stub36, "nn::hid::SetNpadJoyAssignmentModeSingle(unsigned int const&, nn::hid::NpadJoyDeviceType)")
HID_STUB("_ZN2nn3hid32GetSixAxisSensorFusionParametersEPfS1_RKNS0_19SixAxisSensorHandleE", h_hid_stub37, "nn::hid::GetSixAxisSensorFusionParameters(float*, float*, nn::hid::SixAxisSensorHandle const&)")
HID_STUB("_ZN2nn3hid32SetSixAxisSensorFusionParametersERKNS0_19SixAxisSensorHandleEff", h_hid_stub38, "nn::hid::SetSixAxisSensorFusionParameters(nn::hid::SixAxisSensorHandle const&, float, float)")
HID_STUB("_ZN2nn3hid34ResetSixAxisSensorFusionParametersERKNS0_19SixAxisSensorHandleE", h_hid_stub39, "nn::hid::ResetSixAxisSensorFusionParameters(nn::hid::SixAxisSensorHandle const&)")
HID_STUB("_ZN2nn3hid41IsFirmwareUpdateAvailableForSixAxisSensorERKNS0_19SixAxisSensorHandleE", h_hid_stub40, "nn::hid::IsFirmwareUpdateAvailableForSixAxisSensor(nn::hid::SixAxisSensorHandle const&)")
