// nn::codec::HardwareOpusDecoder: the real device decodes in hardware via the hwopus service (the game's audio and cutscene tracks are all Opus; this is not an online feature).
// Host: the constructor instead constructs the SDK's software OpusDecoder in the same memory (the sdk bundles libopus, native ARM).
// Basis: both are implementations of nn::codec::IOpusDecoder, with the 10 vtable slots identical one by one in order and signature (destructor×2, GetWorkBufferSize, IsInitialized,
// Initialize, Finalize, GetSampleRate, GetChannelCount, Reset, DecodeInterleaved); the game allocates 0x40 bytes and the software object is 0x30 bytes.
#include "hle.h"

HLE_FORCE("_ZN2nn5codec19HardwareOpusDecoderC1Ei", "hwopus service; the SDK's software OpusDecoder instead (same IOpusDecoder interface)",
          void, h_codec_HwOpusCtor, void *self, int option) {
    (void)option;
    static void (*soft_ctor)(void *);
    if (!soft_ctor && !(soft_ctor = guest_sym("_ZN2nn5codec11OpusDecoderC1Ev"))) die("no OpusDecoder constructor in the guest");
    soft_ctor(self);
}

// The C interface of the hardware decoder (TotK main imports it): each function → the SDK's software counterpart, same arguments except the hardware
// option. nn::codec::OpusDecoderType fits in the storage the game gives HardwareOpusDecoderType: the software Impl functions touch +0x0..+0x20 (sdk
// 0x2ba270 / 0x2ba460), the hardware ones +0x0..+0x28 (sdk 0x2bdd60 / 0x2be090), sample rate at +0x18 and channel count at +0x1c in both.
static void *codec_sym(const char *n) { void *p = guest_sym(n); if (!p) die("no %s in the guest", n); return p; }
#define SOFT(var, sym, type) static __typeof__(type) var; if (!var) var = (__typeof__(type))codec_sym(sym)
HLE_FORCE_OPT("_ZN2nn5codec36GetHardwareOpusDecoderWorkBufferSizeEiii", "hwopus: work buffer of the SDK's software decoder", size_t, h_codec_HwWorkSize, int rate, int ch, int option) {
    (void)option; SOFT(f, "_ZN2nn5codec28GetOpusDecoderWorkBufferSizeEii", size_t (*)(int, int)); return f(rate, ch);
}
HLE_FORCE_OPT("_ZN2nn5codec29InitializeHardwareOpusDecoderEPNS0_23HardwareOpusDecoderTypeEiiPvmi", "hwopus: the SDK's software decoder in the same storage",
              int, h_codec_HwInit, void *t, int rate, int ch, void *buf, size_t n, int option) {
    (void)option; SOFT(f, "_ZN2nn5codec21InitializeOpusDecoderEPNS0_15OpusDecoderTypeEiiPvm", int (*)(void *, int, int, void *, size_t)); return f(t, rate, ch, buf, n);
}
HLE_FORCE_OPT("_ZN2nn5codec27FinalizeHardwareOpusDecoderEPNS0_23HardwareOpusDecoderTypeE", "hwopus: software decoder", void, h_codec_HwFini, void *t) {
    SOFT(f, "_ZN2nn5codec19FinalizeOpusDecoderEPNS0_15OpusDecoderTypeE", void (*)(void *)); f(t);
}
HLE_FORCE_OPT("_ZN2nn5codec24ResetHardwareOpusDecoderEPNS0_23HardwareOpusDecoderTypeE", "hwopus: software decoder", void, h_codec_HwReset, void *t) {
    SOFT(f, "_ZN2nn5codec16ResetOpusDecoderEPNS0_15OpusDecoderTypeE", void (*)(void *)); f(t);
}
HLE_FORCE_OPT("_ZN2nn5codec32GetHardwareOpusDecoderSampleRateEPKNS0_23HardwareOpusDecoderTypeE", "hwopus: software decoder", int, h_codec_HwRate, const void *t) {
    SOFT(f, "_ZN2nn5codec24GetOpusDecoderSampleRateEPKNS0_15OpusDecoderTypeE", int (*)(const void *)); return f(t);
}
HLE_FORCE_OPT("_ZN2nn5codec34GetHardwareOpusDecoderChannelCountEPKNS0_23HardwareOpusDecoderTypeE", "hwopus: software decoder", int, h_codec_HwCh, const void *t) {
    SOFT(f, "_ZN2nn5codec26GetOpusDecoderChannelCountEPKNS0_15OpusDecoderTypeE", int (*)(const void *)); return f(t);
}
HLE_FORCE_OPT("_ZN2nn5codec33DecodeOpusInterleavedWithHardwareEPNS0_23HardwareOpusDecoderTypeEPmPiPsmPKvm", "hwopus: software decoder",
              int, h_codec_HwDecode, void *t, size_t *used, int *samples, int16_t *out, size_t outn, const void *in, size_t inn) {
    SOFT(f, "_ZN2nn5codec21DecodeOpusInterleavedEPNS0_15OpusDecoderTypeEPmPiPsmPKvm", int (*)(void *, size_t *, int *, int16_t *, size_t, const void *, size_t));
    return f(t, used, samples, out, outn, in, inn);
}
#undef SOFT
