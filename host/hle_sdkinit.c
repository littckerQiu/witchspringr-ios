// Service layer initialization called by nninitInitializeSdkModule: on the real device each connects to a Horizon system service (IPC), the host has no such service processes.
// Native takeover: create no session, return directly; each service's later interfaces are taken over one by one as host implementations when they come into use (see hle_*.c in the same directory).
// nn::os::InitializeVirtualAddressMemory belongs to the SDK's os layer and is not taken over; fs::SetLocalApplicationAccessLog /
// SetResultHandledByApplication only write SDK-internal switches and are not taken over.
#include "hle.h"

static void once(const char *what) { LOG("init takeover: %s (no-op)", what); }

HLE_FORCE("nndiagStartup", "connects to the lm log service; the host prints diagnostic logs itself", void, h_nndiagStartup, void) { once("nndiagStartup"); }
HLE_FORCE("_ZN2nn2oe10InitializeEv", "connects to the am/oe services; each environment query answers with host defaults", void, h_oe_Initialize, void) { once("oe::Initialize"); }
HLE_FORCE("_ZN2nn3aoc10InitializeEv", "add-on content (DLC) service: no session (no service process); hle_misc.c answers the aoc queries", void, h_aoc_Initialize, void) { once("aoc::Initialize"); }
HLE_FORCE("_ZN2nn3err26InitializeContextWriterApiEv", "connects to the err context service; the host reports nothing", void, h_err_InitCtx, void) { once("err::InitializeContextWriterApi"); }
HLE_FORCE("_ZN2nn2fs24InitializeForApplicationEv", "connects to fsp-srv; the fs calls go to the host file system and the RomFS", void, h_fs_InitApp, void) { once("fs::InitializeForApplication"); }
HLE_FORCE("_ZN2nn4pctl10InitializeEv", "connects to the pctl parental control service; none here", void, h_pctl_Initialize, void) { once("pctl::Initialize"); }
HLE_FORCE("_ZN2nn4diag34InitializeApplicationAbortObserverEv", "registers with the system abort observer; the host's signal handlers report crashes", void, h_diag_AbortObs, void) { once("diag::InitializeApplicationAbortObserver"); }
