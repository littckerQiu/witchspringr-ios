// nn::nfp (amiibo). On the console the library connects to the nfp service through sm, which the host does not have (TotK aborted in nfp::Initialize),
// so the whole family is taken over. The host has no NFC reader: it reports one NFC device on the connected controller (hle_hid.c) whose detection
// never finds a tag, as on a console with no amiibo at hand: the game's "touch an amiibo" screen shows and cancelling leaves it. Operations that need a
// tag (mount, application area, the amiibo settings applets) return "tag not found". From nxnative's hle_sdk16.c (seedds, MIT), written for Super Mario
// Bros. Wonder and The Legend of Zelda: Breath of the Wild 1.9.0 (same sdk module as TotK 1.4.3).
#include "hle.h"
#include <stdatomic.h>

#define NFP_RES_TAG_NOT_FOUND (115u | 97u << 9)   // module 115 (nfp), description 97
enum { NFP_STATE_INIT = 0, NFP_STATE_SEARCH = 1 };   // 0 initialized, 1 searching for a tag (2 = tag found, never on the host)
typedef struct { uint32_t id; uint8_t reserved[4]; } NfpDeviceHandle;
#define NFP_DEVICE_ID 0x4e465030u   // 'NFP0'
static _Atomic int g_nfp_state;
uint32_t hle_hid_connected_npad(void);
static Result nfp_no_tag(const char *what) {
    static _Atomic int logged; if (!atomic_exchange(&logged, 1)) LOG("nfp: %s and other operations that need an amiibo tag → tag not found (the host has no NFC)", what);
    return NFP_RES_TAG_NOT_FOUND;
}
HLE_FORCE_OPT("_ZN2nn3nfp10InitializeEv", "amiibo library: one NFC device that never finds a tag", void, h_nfp_Init, void) { LOG("nfp::Initialize: one NFC device on the host, no amiibo tag will be found"); }
HLE_FORCE_OPT("_ZN2nn3nfp29AttachAvailabilityChangeEventEPNS_2os15SystemEventTypeE", "NFC availability event: bound, never signalled", void, h_nfp_AttachAvail, void *ev) { hle_bind_system_event(ev, 0); }
HLE_FORCE_OPT("_ZN2nn3nfp11ListDevicesEPNS0_12DeviceHandleEPii", "NFC devices: one", Result, h_nfp_List, NfpDeviceHandle *out, int *n, int max) {
    *n = 0; if (max >= 1) { memset(&out[0], 0, sizeof out[0]); out[0].id = NFP_DEVICE_ID; *n = 1; }
    return RES_OK;
}
HLE_FORCE_OPT("_ZN2nn3nfp9GetNpadIdEPjRKNS0_12DeviceHandleE", "NFC device's controller: the connected one", Result, h_nfp_NpadId, uint32_t *out, const NfpDeviceHandle *h) { (void)h; *out = hle_hid_connected_npad(); return RES_OK; }
HLE_FORCE_OPT("_ZN2nn3nfp14StartDetectionERKNS0_12DeviceHandleE", "start looking for a tag (never found)", Result, h_nfp_Start, const NfpDeviceHandle *h) { (void)h; atomic_store(&g_nfp_state, NFP_STATE_SEARCH); return RES_OK; }
HLE_FORCE_OPT("_ZN2nn3nfp13StopDetectionERKNS0_12DeviceHandleE", "stop looking for a tag", Result, h_nfp_Stop, const NfpDeviceHandle *h) { (void)h; atomic_store(&g_nfp_state, NFP_STATE_INIT); return RES_OK; }
HLE_FORCE_OPT("_ZN2nn3nfp14GetDeviceStateERKNS0_12DeviceHandleE", "device state: initialized / searching", int, h_nfp_State, const NfpDeviceHandle *h) { (void)h; return atomic_load(&g_nfp_state); }
HLE_FORCE_OPT("_ZN2nn3nfp10GetTagInfoEPNS0_7TagInfoERKNS0_12DeviceHandleE", "tag info: no tag", Result, h_nfp_TagInfo, void *out, const NfpDeviceHandle *h) { (void)out; (void)h; return nfp_no_tag("GetTagInfo"); }
HLE_FORCE_OPT("_ZN2nn3nfp12GetModelInfoEPNS0_9ModelInfoERKNS0_12DeviceHandleE", "model info: no tag", Result, h_nfp_ModelInfo, void *out, const NfpDeviceHandle *h) { (void)out; (void)h; return nfp_no_tag("GetModelInfo"); }
HLE_FORCE_OPT("_ZN2nn3nfp5MountERKNS0_12DeviceHandleENS0_9ModelTypeENS0_11MountTargetE", "mount tag: no tag", Result, h_nfp_Mount, const NfpDeviceHandle *h, int model, int target) { (void)h; (void)model; (void)target; return nfp_no_tag("Mount"); }
// Tag activate / deactivate events: bound, never signalled (without the takeover the SDK reads a null pointer at sdk+0x3f2a78, nxnative)
HLE_FORCE_OPT("_ZN2nn3nfp19AttachActivateEventEPNS_2os15SystemEventTypeERKNS0_12DeviceHandleE", "tag placed event: bound, never signalled", Result, h_nfp_AttachAct, void *ev, const NfpDeviceHandle *h) { (void)h; hle_bind_system_event(ev, 0); return RES_OK; }
HLE_FORCE_OPT("_ZN2nn3nfp21AttachDeactivateEventEPNS_2os15SystemEventTypeERKNS0_12DeviceHandleE", "tag removed event: bound, never signalled", Result, h_nfp_AttachDeact, void *ev, const NfpDeviceHandle *h) { (void)h; hle_bind_system_event(ev, 0); return RES_OK; }
HLE_FORCE_OPT("_ZN2nn3nfp5MountERKNS0_12DeviceHandleENS0_9ModelTypeE", "mount tag (two arguments): no tag", Result, h_nfp_Mount2, const NfpDeviceHandle *h, int model) { (void)h; (void)model; return nfp_no_tag("Mount"); }
HLE_FORCE_OPT("_ZN2nn3nfp7UnmountERKNS0_12DeviceHandleE", "unmount tag: no tag", Result, h_nfp_Unmount, const NfpDeviceHandle *h) { (void)h; return nfp_no_tag("Unmount"); }
HLE_FORCE_OPT("_ZN2nn3nfp13GetCommonInfoEPNS0_10CommonInfoERKNS0_12DeviceHandleE", "common info: no tag", Result, h_nfp_CommonInfo, void *out, const NfpDeviceHandle *h) { (void)out; (void)h; return nfp_no_tag("GetCommonInfo"); }
HLE_FORCE_OPT("_ZN2nn3nfp15GetRegisterInfoEPNS0_12RegisterInfoERKNS0_12DeviceHandleE", "register info: no tag", Result, h_nfp_RegInfo, void *out, const NfpDeviceHandle *h) { (void)out; (void)h; return nfp_no_tag("GetRegisterInfo"); }
HLE_FORCE_OPT("_ZN2nn3nfp8GetStateEv", "amiibo library state: initialized (1)", int, h_nfp_LibState, void) { return 1; }
HLE_FORCE_OPT("_ZN2nn3nfp8FinalizeEv", "amiibo library finalize: no session", void, h_nfp_Fini, void) {}
HLE_FORCE_OPT("_ZN2nn3nfp5FlushERKNS0_12DeviceHandleE", "write back to the tag: no tag", Result, h_nfp_Flush, const NfpDeviceHandle *h) { (void)h; return nfp_no_tag("Flush"); }
HLE_FORCE_OPT("_ZN2nn3nfp19OpenApplicationAreaERKNS0_12DeviceHandleEj", "open application area: no tag", Result, h_nfp_OpenArea, const NfpDeviceHandle *h, uint32_t id) { (void)h; (void)id; return nfp_no_tag("OpenApplicationArea"); }
HLE_FORCE_OPT("_ZN2nn3nfp18GetApplicationAreaEPvPmRKNS0_12DeviceHandleEm", "read application area: no tag", Result, h_nfp_GetArea, void *buf, uint64_t *n, const NfpDeviceHandle *h, uint64_t sz) {
    (void)buf; (void)h; (void)sz; if (n) *n = 0; return nfp_no_tag("GetApplicationArea");
}
HLE_FORCE_OPT("_ZN2nn3nfp18SetApplicationAreaERKNS0_12DeviceHandleEPKvm", "write application area: no tag", Result, h_nfp_SetArea, const NfpDeviceHandle *h, const void *buf, uint64_t sz) { (void)h; (void)buf; (void)sz; return nfp_no_tag("SetApplicationArea"); }
HLE_FORCE_OPT("_ZN2nn3nfp21CreateApplicationAreaERKNS0_12DeviceHandleERKNS0_25ApplicationAreaCreateInfoE", "create application area: no tag", Result, h_nfp_CreateArea, const NfpDeviceHandle *h, const void *info) { (void)h; (void)info; return nfp_no_tag("CreateApplicationArea"); }
HLE_FORCE_OPT("_ZN2nn3nfp23RecreateApplicationAreaERKNS0_12DeviceHandleERKNS0_25ApplicationAreaCreateInfoE", "recreate application area: no tag", Result, h_nfp_RecreateArea, const NfpDeviceHandle *h, const void *info) { (void)h; (void)info; return nfp_no_tag("RecreateApplicationArea"); }
HLE_FORCE_OPT("_ZN2nn3nfp13StartRestorerEPNS0_12DeviceHandleERKNS0_24AmiiboSettingsStartParamERKNS0_7TagInfoE", "amiibo restorer applet: no tag", Result, h_nfp_Restorer, NfpDeviceHandle *h, const void *p, const void *tag) { (void)h; (void)p; (void)tag; return nfp_no_tag("StartRestorer"); }
HLE_FORCE_OPT("_ZN2nn3nfp19StartGameDataEraserEPNS0_12DeviceHandleERKNS0_24AmiiboSettingsStartParamERKNS0_7TagInfoE", "amiibo game data eraser applet: no tag", Result, h_nfp_Eraser, NfpDeviceHandle *h, const void *p, const void *tag) { (void)h; (void)p; (void)tag; return nfp_no_tag("StartGameDataEraser"); }
HLE_FORCE_OPT("_ZN2nn3nfp29StartNicknameAndOwnerSettingsEPNS0_12DeviceHandleEPbPNS0_12RegisterInfoERKNS0_24AmiiboSettingsStartParamERKNS0_7TagInfoE", "amiibo nickname and owner applet: no tag",
              Result, h_nfp_Nick, NfpDeviceHandle *h, uint8_t *changed, void *reg, const void *p, const void *tag) { (void)h; (void)reg; (void)p; (void)tag; if (changed) *changed = 0; return nfp_no_tag("StartNicknameAndOwnerSettings"); }
HLE_FORCE_OPT("_ZN2nn3nfp29StartNicknameAndOwnerSettingsEPNS0_12DeviceHandleEPbPNS0_12RegisterInfoERKNS0_24AmiiboSettingsStartParamERKNS0_7TagInfoERKS4_", "amiibo nickname and owner applet (with register info): no tag",
              Result, h_nfp_Nick2, NfpDeviceHandle *h, uint8_t *changed, void *reg, const void *p, const void *tag, const void *old) { (void)h; (void)reg; (void)p; (void)tag; (void)old; if (changed) *changed = 0; return nfp_no_tag("StartNicknameAndOwnerSettings"); }
