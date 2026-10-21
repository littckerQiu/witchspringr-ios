// nn::audio AudioOut: the game (FMOD's nx output layer) appends PCM buffers in blocks; once played the system puts them back on the "released" queue and signals an event.
// Host: real sound = CoreAudio AudioUnit (Mac DefaultOutput / iOS RemoteIO); silent sink = buffers consumed in real time (no sound, same pacing as the device).
//       iOS plays real sound by default (the product must have sound), tests set DM_AUDIO=0 explicitly for silence; the Mac command-line host defaults to the silent sink (replays / gates are silent), DM_AUDIO=1 for real sound;
//       the Mac App (app_mac.m) is the product and sets DM_AUDIO=1 at launch ("no sound": the App used to take the command-line default and never played sound).
//       If the sound card cannot be opened (no output device etc.) it no longer exits: logs red, and this channel is consumed in real time by the silent sink while the game runs on.
// The contents of AudioOut / AudioOutBuffer / AudioOutParameter are read and written only through the interfaces below; the host defines its own internal layout and writes only the front part of each struct.
#include "hle.h"
#include <AudioToolbox/AudioToolbox.h>
#include <TargetConditionals.h>
#include <dispatch/dispatch.h>
#include <stdatomic.h>
#include <unistd.h>

enum { FMT_PCM16 = 2, STATE_STARTED = 0, STATE_STOPPED = 1, RATE = 48000 };
enum { BK_NONE, BK_AU, BK_NULL };   // what consumes an output's queue right now (aout.backend)

typedef struct { void *ptr; uint64_t cap, size; } gbuf;     // The first 24 bytes written into the guest AudioOutBuffer
#define QMAX 64
#define RELMAX QMAX                    // Released max = number of in-flight buffers (the game must take a buffer back before it can append again), same limit as pending
typedef struct {
    pthread_mutex_t m;
    void *event;                       // Guest SystemEvent: signaled whenever a buffer is released
    int ch;
    _Atomic int state;
    gbuf *q[QMAX]; _Atomic uint32_t q_head, q_tail;       // Pending: written by the game side, read by the output side
    gbuf *rel[RELMAX]; _Atomic uint32_t rel_head, rel_tail; // Released: written by the output side, read by the game side
    uint64_t pos;                      // Bytes already played of the current block
    AudioUnit au;
    int mix;                           // 1 = the game gives 5.1 (6 channels), downmixed to stereo by us before handing to CoreAudio (au_render)
    int16_t *mixbuf;                   // 6-channel staging for the downmix (MIXMAX frames)
    pthread_t null_th; _Atomic int null_run;
    int backend;                       // BK_*: the running consumer; Start, Stop and the background suspend change it only under g_aos_lock and act on it
    _Atomic int sinks;                 // silent sinks running on this output (more than one, or one beside the AudioUnit, is the race g_aos_lock prevents)
    dispatch_semaphore_t notify_sem;
    dispatch_semaphore_t rel_sem;      // signaled with every release batch: what dm_pcmout_wait blocks on (the audio renderer used to poll every millisecond)
    pthread_t notify_th; _Atomic int notify_run, notify_pending, notify_armed;
} aout;

// Registry of open outputs: suspended / resumed all at once by the front-end lifecycle (going to background). g_aos_lock also serializes every backend
// change (Start / Stop / suspend / resume): Start used to mark the output started and pick its backend outside it, so a suspend between them started a
// silent sink and Start a second one over the same single-consumer queues (or the AudioUnit beside it), and a Stop racing a suspend joined a sink that
// never existed (nxnative 8530042, MIT; t_audio scenario 4)
#define AOMAX 8
static aout *g_aos[AOMAX];
static pthread_mutex_t g_aos_lock = PTHREAD_MUTEX_INITIALIZER;
static int g_suspended;
static _Atomic unsigned g_consumer_dupes;   // a second consumer on one output's queues (two silent sinks, or a sink beside the AudioUnit): reported red at the next backend stop
static aout *ao(const void *g) { aout *a = objmap_get(g); if (!a) die("AudioOut %p was not created by the host", g); return a; }

static void notify_release(aout *a) {
    dispatch_semaphore_signal(a->rel_sem);
    atomic_store_explicit(&a->notify_pending, 1, memory_order_release);
    if (atomic_exchange_explicit(&a->notify_armed, 1, memory_order_acq_rel) == 0)
        dispatch_semaphore_signal(a->notify_sem);
}

static void *event_notify(void *p) {
    aout *a = p;
    for (;;) {
        dispatch_semaphore_wait(a->notify_sem, DISPATCH_TIME_FOREVER);
        if (atomic_exchange_explicit(&a->notify_pending, 0, memory_order_acq_rel) && a->event)
            hle_signal_system_event(a->event);
        atomic_store_explicit(&a->notify_armed, 0, memory_order_release);
        if (!atomic_load_explicit(&a->notify_run, memory_order_acquire)) break;
        if (atomic_load_explicit(&a->notify_pending, memory_order_acquire) &&
            atomic_exchange_explicit(&a->notify_armed, 1, memory_order_acq_rel) == 0)
            dispatch_semaphore_signal(a->notify_sem);
    }
    return NULL;
}

// Take n bytes from the pending queue and hand them to the output side; once a whole block has played, move it to released and notify the ordinary thread.
static void pull(aout *a, uint8_t *dst, uint64_t n) {
    int released = 0;
    uint32_t qh = atomic_load_explicit(&a->q_head, memory_order_relaxed);
    while (n) {
        uint32_t qt = atomic_load_explicit(&a->q_tail, memory_order_acquire);
        if (qh == qt || atomic_load_explicit(&a->state, memory_order_acquire) != STATE_STARTED) { memset(dst, 0, n); break; }
        gbuf *b = a->q[qh & (QMAX - 1)];
        uint64_t k = b->size - a->pos; if (k > n) k = n;
        memcpy(dst, (uint8_t *)b->ptr + a->pos, k);
        dst += k; n -= k; a->pos += k;
        if (a->pos >= b->size) {
            uint32_t rw = atomic_load_explicit(&a->rel_tail, memory_order_relaxed);
            uint32_t rr = atomic_load_explicit(&a->rel_head, memory_order_acquire);
            if (rw - rr == RELMAX) die("AudioOut released queue overflow");
            a->rel[rw & (RELMAX - 1)] = b;
            atomic_store_explicit(&a->rel_tail, rw + 1, memory_order_release);
            qh++;
            atomic_store_explicit(&a->q_head, qh, memory_order_release);
            a->pos = 0; released = 1;
        }
    }
    if (released) notify_release(a);
}

static _Atomic uint64_t g_render_calls;   // Cumulative sound card callbacks (lifecycle verification: must keep growing after resume)
uint64_t dm_audio_render_calls(void) { return atomic_load_explicit(&g_render_calls, memory_order_relaxed); }
// 5.1 -> stereo (previously: the game's 6 channels were handed to the AudioUnit as is without a channel layout; the system's implicit conversion took only the first two, and the centre - NPC dialogue - was dropped entirely).
// The game's channel order (measured in the Mac App by per-channel energy during the half second Akara starts speaking: only channel 3 jumps): front left, front right, centre, LFE, rear left, rear right.
// Coefficients from the ITU-R BS.775 Lo/Ro downmix: L = front left + 0.707*centre + 0.707*rear left, R symmetric; LFE is not mixed in (the standard downmix excludes LFE, and mixing it in muddies the low end);
// the whole is multiplied by 0.707 again for 3 dB of headroom, and anything still beyond 16 bits is saturated. Q15 fixed point: 0.707 = 23170, 0.707 x 0.707 = 16384
#define MIXMAX 4096
static void downmix51(const int16_t *in, int16_t *out, unsigned frames) {
    for (unsigned i = 0; i < frames; i++, in += 6, out += 2) {
        int32_t l = (23170 * in[0] + 16384 * in[2] + 16384 * in[4]) >> 15, r = (23170 * in[1] + 16384 * in[2] + 16384 * in[5]) >> 15;
        out[0] = (int16_t)(l > 32767 ? 32767 : l < -32768 ? -32768 : l); out[1] = (int16_t)(r > 32767 ? 32767 : r < -32768 ? -32768 : r); }
}
// DM_AUDIO_MUTE=1 (tests on the Mac, at night): the sound card is opened and fed as usual and silence goes out (read at the first OpenAudioOut)
static int g_audio_mute = -1;
static OSStatus au_render(void *ctx, AudioUnitRenderActionFlags *f, const AudioTimeStamp *ts, UInt32 bus, UInt32 frames, AudioBufferList *bl) {
    (void)f; (void)ts; (void)bus; (void)frames;
    aout *a = ctx;
#ifdef DM_TEST_MUTE_NO_PULL   // negative control of t_audio only: muted without taking the game's blocks
    if (g_audio_mute > 0) { memset(bl->mBuffers[0].mData, 0, bl->mBuffers[0].mDataByteSize); return noErr; }
#endif
    atomic_fetch_add_explicit(&g_render_calls, 1, memory_order_relaxed);
    if (atomic_load_explicit(&a->sinks, memory_order_relaxed)) atomic_fetch_add_explicit(&g_consumer_dupes, 1, memory_order_relaxed);   // counted only: no logging on the audio thread
    if (!a->mix) pull(a, bl->mBuffers[0].mData, bl->mBuffers[0].mDataByteSize);
    else { int16_t *o = bl->mBuffers[0].mData; unsigned left = bl->mBuffers[0].mDataByteSize / 4;   // stereo 16-bit: 4 bytes per frame
        while (left) { unsigned k = left < MIXMAX ? left : MIXMAX; pull(a, (uint8_t *)a->mixbuf, (uint64_t)k * 12); downmix51(a->mixbuf, o, k); o += 2 * k; left -= k; } }
    // Diagnostic switch DM_AUDIO_OUT_DUMP=<file>: append the data handed to CoreAudio as is (stereo after the downmix). This machine has no loopback device and cannot record the system output; to tell whether the dialogue was handed over, look at this file
    { static FILE *df; static int on = -1; if (on < 0) { const char *e = getenv("DM_AUDIO_OUT_DUMP"); on = e != NULL; if (on && !(df = fopen(e, "wb"))) LOG("[red] DM_AUDIO_OUT_DUMP: cannot open %s", e); }
      if (df) fwrite(bl->mBuffers[0].mData, 1, bl->mBuffers[0].mDataByteSize, df); }
    if (g_audio_mute > 0) memset(bl->mBuffers[0].mData, 0, bl->mBuffers[0].mDataByteSize);   // (after taking the blocks: the game's pacing goes on)
    return noErr;
}
#if !TARGET_OS_IPHONE
static void dev_name(AudioObjectID id, char *o, size_t n) {   // output device name (for the log)
    CFStringRef nm = NULL; UInt32 sz = sizeof nm; AudioObjectPropertyAddress pa = { kAudioObjectPropertyName, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain };
    o[0] = 0; if (!AudioObjectGetPropertyData(id, &pa, 0, NULL, &sz, &nm) && nm) { CFStringGetCString(nm, o, (CFIndex)n, kCFStringEncodingUTF8); CFRelease(nm); } }
#endif
// The open runs on the thread that calls OpenAudioOut. Measured on an M5 (plan item 55): 47 ms for a process's first AudioUnit (the component
// loads), 0.5-1 ms after; tomodachi-native once saw CoreAudio take about 40 s and moved the open to a queue (d7f52e1). The time is logged; above 1 s
// in red (the iPhone's is still to be seen, item 70)
__attribute__((weak)) const char *thr_cur_name(char *nb, size_t n) { (void)nb; (void)n; return NULL; }   // hle_thread.c; the unit tests link without it
static int au_open(aout *a) {   // 0 = the sound card is open; -1 = it cannot be opened (a->au set to null, the caller uses the silent sink)
    uint64_t t0 = now_ns();
    AudioComponentDescription d = {.componentType = kAudioUnitType_Output,
#if TARGET_OS_IPHONE
                                   .componentSubType = kAudioUnitSubType_RemoteIO,
#else
                                   .componentSubType = kAudioUnitSubType_DefaultOutput,
#endif
                                   .componentManufacturer = kAudioUnitManufacturer_Apple};
    AudioComponent c = AudioComponentFindNext(NULL, &d);
    if (!c || AudioComponentInstanceNew(c, &a->au)) { a->au = NULL; LOG("[red] cannot create the AudioUnit: this output uses a silent sink"); return -1; }
    a->mix = a->ch == 6; if (a->mix && !a->mixbuf) a->mixbuf = malloc(MIXMAX * 12);   // 5.1: we downmix ourselves and the AudioUnit only takes stereo (mono / stereo are passed through as before)
    if (a->mix && !a->mixbuf) { AudioComponentInstanceDispose(a->au); a->au = NULL; LOG("[red] cannot allocate the downmix buffer: this output uses a silent sink"); return -1; }
    int och = a->mix ? 2 : a->ch;
    AudioStreamBasicDescription f = {.mSampleRate = RATE, .mFormatID = kAudioFormatLinearPCM,
                                     .mFormatFlags = kLinearPCMFormatFlagIsSignedInteger | kLinearPCMFormatFlagIsPacked,
                                     .mBytesPerPacket = 2u * och, .mFramesPerPacket = 1, .mBytesPerFrame = 2u * och,
                                     .mChannelsPerFrame = (UInt32)och, .mBitsPerChannel = 16};
    if (a->mix) LOG("audio: the game gives 6 channels (5.1) → downmixed to stereo (center / surround ×0.707 into left and right, no LFE, −3 dB overall, saturating)");
    AURenderCallbackStruct cb = {au_render, a};
    if (AudioUnitSetProperty(a->au, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 0, &f, sizeof f) ||
        AudioUnitSetProperty(a->au, kAudioUnitProperty_SetRenderCallback, kAudioUnitScope_Input, 0, &cb, sizeof cb) ||
        AudioUnitInitialize(a->au)) { AudioComponentInstanceDispose(a->au); a->au = NULL; LOG("[red] AudioUnit setup failed (no output device?): this output uses a silent sink"); return -1; }
#if !TARGET_OS_IPHONE
    {   // the default output unit follows the system default output device: record both, to check that "the sound comes out of the device the system chose"
        AudioObjectID cur = 0, def = 0; UInt32 sz = sizeof cur; char cn[128], dn[128];
        AudioUnitGetProperty(a->au, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &cur, &sz);
        AudioObjectPropertyAddress pa = { kAudioHardwarePropertyDefaultOutputDevice, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain }; sz = sizeof def;
        AudioObjectGetPropertyData(kAudioObjectSystemObject, &pa, 0, NULL, &sz, &def); dev_name(cur, cn, sizeof cn); dev_name(def, dn, sizeof dn);
        LOG("audio: output device \"%s\" (%u), system default output \"%s\" (%u)%s", cn, (unsigned)cur, dn, (unsigned)def, cur == def ? ", same" : " [red] different"); }
#endif
    { double ms = (now_ns() - t0) / 1e6; char tn[64] = ""; const char *gn = thr_cur_name(tn, sizeof tn); if (!gn) { pthread_getname_np(pthread_self(), tn, sizeof tn); gn = tn; }
      LOG("audio: CoreAudio output opened in %.1f ms on %s thread \"%s\"%s", ms, thr_cur_name(tn, 1) ? "the guest" : "a host", gn, ms > 1000 ? " [red] slow: that thread waited (tomodachi-native once saw 40 s)" : ""); }
    return 0;
}
// Silent sink: consumes in real time at 48 kHz every 5 ms
static void *null_sink(void *p) {
    aout *a = p; uint8_t scratch[RATE / 200 * 2 * 8];
    uint64_t bytes = (uint64_t)RATE / 200 * 2 * a->ch, t = now_ns();
    if (atomic_fetch_add_explicit(&a->sinks, 1, memory_order_acq_rel)) atomic_fetch_add_explicit(&g_consumer_dupes, 1, memory_order_relaxed);
    while (atomic_load_explicit(&a->null_run, memory_order_acquire)) {
        t += 5000000; uint64_t now = now_ns(); if (t > now) usleep((useconds_t)((t - now) / 1000));
        pull(a, scratch, bytes);
    }
    atomic_fetch_sub_explicit(&a->sinks, 1, memory_order_acq_rel);
    return NULL;
}
// Backend changes; callers hold g_aos_lock. pull() takes no lock, so stopping the AudioUnit or joining a sink under it cannot deadlock
static void null_start(aout *a) { atomic_store_explicit(&a->null_run, 1, memory_order_release); pthread_create(&a->null_th, NULL, null_sink, a); a->backend = BK_NULL; }
static void null_stop(aout *a) { atomic_store_explicit(&a->null_run, 0, memory_order_release); pthread_join(a->null_th, NULL); a->backend = BK_NONE; }
static void backend_stop(aout *a) {
    if (a->backend == BK_AU) { AudioOutputUnitStop(a->au); a->backend = BK_NONE; }
    else if (a->backend == BK_NULL) null_stop(a);
    static unsigned seen; unsigned d = atomic_load_explicit(&g_consumer_dupes, memory_order_relaxed);
    if (d != seen) { seen = d; LOG("[red] audio output: a second consumer ran on one output (two silent sinks, or a sink beside the AudioUnit; %u times so far)", d); }
}
static int real_audio(void) { const char *e = getenv("DM_AUDIO"); return e ? atoi(e) != 0 : TARGET_OS_IPHONE; }

// AudioOutParameter = { int32 sampleRate; uint16 channelCount; uint16 _r; ... }, 0 = system default (48 kHz / 2 channels)
HLE_FORCE("_ZN2nn5audio27InitializeAudioOutParameterEPNS0_17AudioOutParameterE", "audio output parameter defaults", void, h_au_InitParam, uint8_t *p) { memset(p, 0, 8); }
// AudioOutInfo = { char name[256] }
HLE_FORCE("_ZN2nn5audio13ListAudioOutsEPNS0_12AudioOutInfoEi", "audio output list: one", int, h_au_List, char *info, int n) {
    if (n < 1) return 0;
    memset(info, 0, 256); strcpy(info, "DeviceOut"); return 1;
}
HLE_FORCE("_ZN2nn5audio12OpenAudioOutEPNS0_8AudioOutEPNS_2os11SystemEventEPKcRKNS0_17AudioOutParameterE", "connects to the audout service; host AudioUnit / silent sink",
          Result, h_au_Open, void *g, void *ev, const char *name, const uint8_t *param) {
    int ch = *(const uint16_t *)(param + 4); int rate = *(const int32_t *)param;
    if (!ch) ch = 2;
    if (rate && rate != RATE) die("AudioOut sample rate %d not supported (48 kHz only)", rate);
    aout *a = calloc(1, sizeof *a);
    pthread_mutex_init(&a->m, NULL); a->event = ev; a->ch = ch;
    atomic_init(&a->state, STATE_STOPPED);
    atomic_init(&a->q_head, 0); atomic_init(&a->q_tail, 0);
    atomic_init(&a->rel_head, 0); atomic_init(&a->rel_tail, 0);
    atomic_init(&a->null_run, 0); atomic_init(&a->notify_run, 1);
    atomic_init(&a->notify_pending, 0); atomic_init(&a->notify_armed, 0);
    a->notify_sem = dispatch_semaphore_create(0); a->rel_sem = dispatch_semaphore_create(0);
    // The thread that signals the game's buffer event at USER_INTERACTIVE (upstream d2r-mobile afad65c): at the default QoS (21) 16 of its wake-ups
    // in 240 s came more than 2 ms late on an iPhone 17 Pro Max, none after; a player heard gaps while moving (PR #52)
    { pthread_attr_t at; pthread_attr_init(&at); pthread_attr_set_qos_class_np(&at, QOS_CLASS_USER_INTERACTIVE, 0);
      pthread_create(&a->notify_th, &at, event_notify, a); pthread_attr_destroy(&at); }
    if (ev) hle_bind_system_event(ev, 1);   // Buffer release event: bind a kernel event on the guest thread (auto-clear), afterwards signaled by the audio thread
    objmap_put(g, a);
    pthread_mutex_lock(&g_aos_lock);
    int slot = -1; for (int i = 0; i < AOMAX; i++) if (!g_aos[i]) { slot = i; break; }
    if (slot < 0) die("more than %d AudioOuts open at once", AOMAX);
    g_aos[slot] = a;
    pthread_mutex_unlock(&g_aos_lock);
    if (g_audio_mute < 0) { const char *e = getenv("DM_AUDIO_MUTE"); g_audio_mute = e && atoi(e); if (g_audio_mute) LOG("audio: DM_AUDIO_MUTE=1: the sound card is fed, silence goes out"); }
    LOG("audio::OpenAudioOut %s, %d channels, %s", name ? name : "(default)", ch, real_audio() ? "real output" : "silent sink");
    if (real_audio()) au_open(a);   // if it cannot be opened, a->au is null, and playback goes to the silent sink when it starts
    return RES_OK;
}
// Default output device variants (Unity): same as OpenAudioOut with no device name; the overload without an event has the game poll GetReleasedAudioOutBuffer
HLE_FORCE_OPT("_ZN2nn5audio19OpenDefaultAudioOutEPNS0_8AudioOutEPNS_2os11SystemEventERKNS0_17AudioOutParameterE", "connects to the audout service (default device); host AudioUnit / silent sink",
              Result, h_au_OpenDef, void *g, void *ev, const uint8_t *param) { return h_au_Open(g, ev, NULL, param); }
HLE_FORCE_OPT("_ZN2nn5audio19OpenDefaultAudioOutEPNS0_8AudioOutERKNS0_17AudioOutParameterE", "connects to the audout service (default device, no release event); host AudioUnit / silent sink",
              Result, h_au_OpenDefNoEv, void *g, const uint8_t *param) { return h_au_Open(g, NULL, NULL, param); }
HLE_FORCE("_ZN2nn5audio13StartAudioOutEPNS0_8AudioOutE", "start playback", Result, h_au_Start, void *g) {
    aout *a = ao(g);
    pthread_mutex_lock(&g_aos_lock);
    if (atomic_exchange_explicit(&a->state, STATE_STARTED, memory_order_acq_rel) != STATE_STARTED) {
        if (a->au && !g_suspended) {
            if (AudioOutputUnitStart(a->au)) { LOG("[red] AudioUnit start failed: this output uses a silent sink"); AudioUnitUninitialize(a->au); AudioComponentInstanceDispose(a->au); a->au = NULL; }
            else a->backend = BK_AU;
        }
        if (a->backend == BK_NONE) null_start(a);
    }
    pthread_mutex_unlock(&g_aos_lock);
    return RES_OK;
}
HLE_FORCE("_ZN2nn5audio12StopAudioOutEPNS0_8AudioOutE", "stop playback", void, h_au_Stop, void *g) {
    aout *a = ao(g);
    pthread_mutex_lock(&g_aos_lock);
    atomic_store_explicit(&a->state, STATE_STOPPED, memory_order_release);
    backend_stop(a);   // the AudioUnit, or the silent sink (including one that took over during suspension)
    pthread_mutex_unlock(&g_aos_lock);
}
HLE_FORCE("_ZN2nn5audio13CloseAudioOutEPNS0_8AudioOutE", "close the audio output", void, h_au_Close, void *g) {
    h_au_Stop(g);
    aout *a = objmap_del(g);
    atomic_store_explicit(&a->notify_run, 0, memory_order_release);
    dispatch_semaphore_signal(a->notify_sem);
    pthread_join(a->notify_th, NULL);
    pthread_mutex_lock(&g_aos_lock);
    for (int i = 0; i < AOMAX; i++) if (g_aos[i] == a) g_aos[i] = NULL;
    pthread_mutex_unlock(&g_aos_lock);
    if (a->au) { AudioUnitUninitialize(a->au); AudioComponentInstanceDispose(a->au); }
    dispatch_release(a->notify_sem); dispatch_release(a->rel_sem);
    free(a->mixbuf); pthread_mutex_destroy(&a->m); free(a);
}
HLE_FORCE("_ZN2nn5audio16GetAudioOutStateEPKNS0_8AudioOutE", "playback state", int, h_au_State, const void *g) { return atomic_load_explicit(&ao(g)->state, memory_order_acquire); }
HLE_FORCE("_ZN2nn5audio21GetAudioOutSampleRateEPKNS0_8AudioOutE", "sample rate", int, h_au_Rate, const void *g) { (void)ao(g); return RATE; }
HLE_FORCE("_ZN2nn5audio23GetAudioOutChannelCountEPKNS0_8AudioOutE", "channel count", int, h_au_Ch, const void *g) { return ao(g)->ch; }
HLE_FORCE("_ZN2nn5audio23GetAudioOutSampleFormatEPKNS0_8AudioOutE", "sample format: PCM16 only", int, h_au_Fmt, const void *g) { (void)ao(g); return FMT_PCM16; }

HLE_FORCE("_ZN2nn5audio21SetAudioOutBufferInfoEPNS0_14AudioOutBufferEPvmm", "buffer description, written into the first 24 bytes of the guest struct", void, h_au_SetBuf, gbuf *b, void *p, uint64_t cap, uint64_t size) {
    b->ptr = p; b->cap = cap; b->size = size;
}
HLE_FORCE("_ZN2nn5audio28GetAudioOutBufferDataPointerEPKNS0_14AudioOutBufferE", "buffer data pointer", void *, h_au_BufPtr, const gbuf *b) { return b->ptr; }
HLE_FORCE("_ZN2nn5audio25GetAudioOutBufferDataSizeEPKNS0_14AudioOutBufferE", "buffer data size", uint64_t, h_au_BufSize, const gbuf *b) { return b->size; }
HLE_FORCE("_ZN2nn5audio20AppendAudioOutBufferEPNS0_8AudioOutEPNS0_14AudioOutBufferE", "append a buffer to play", unsigned, h_au_Append, void *g, gbuf *b) {
    aout *a = ao(g);
    // Diagnostic switch DM_AUDIO_DUMP=<file>: every PCM block the game appends is written out as is (16-bit, 48 kHz, channel count per the OpenAudioOut log, usually 6). Used to judge "did a given sound play or not":
    // cross-correlate the original game's audio against it (this is how the tier-one drop sound was verified). The file is opened only when the variable is set; when unset this costs only one extra cached check
    { static FILE *df; static int on = -1; if (on < 0) { const char *e = getenv("DM_AUDIO_DUMP"); on = e != NULL; if (on && !(df = fopen(e, "wb"))) LOG("[red] DM_AUDIO_DUMP: cannot open %s", e); }
      if (df && b && b->ptr && b->size) fwrite(b->ptr, 1, (size_t)b->size, df); }
    pthread_mutex_lock(&a->m);
    uint32_t qt = atomic_load_explicit(&a->q_tail, memory_order_relaxed);
    uint32_t qh = atomic_load_explicit(&a->q_head, memory_order_acquire);
    int ok = qt - qh < QMAX;
    if (ok) { a->q[qt & (QMAX - 1)] = b; atomic_store_explicit(&a->q_tail, qt + 1, memory_order_release); }
    pthread_mutex_unlock(&a->m);
    return ok;      // bool: false when the queue is full (the real device has a limit too)
}
HLE_FORCE("_ZN2nn5audio25GetReleasedAudioOutBufferEPNS0_8AudioOutE", "next played buffer, NULL if none", gbuf *, h_au_Released, void *g) {
    aout *a = ao(g); gbuf *b = NULL;
    pthread_mutex_lock(&a->m);
    uint32_t rr = atomic_load_explicit(&a->rel_head, memory_order_relaxed);
    uint32_t rw = atomic_load_explicit(&a->rel_tail, memory_order_acquire);
    if (rr != rw) { b = a->rel[rr & (RELMAX - 1)]; atomic_store_explicit(&a->rel_head, rr + 1, memory_order_release); }
    pthread_mutex_unlock(&a->m);
    return b;
}

// Host-internal PCM output for the in-process audio renderer (hle_audren.c): the same AudioOut machinery (real output / silent sink / lifecycle
// take-over), keyed by a host-allocated object instead of a guest AudioOut, without a release event. From nxnative's hle_audio.c (seedds, MIT)
void *dm_pcmout_open(int ch) {
    void *key = calloc(1, 64); uint8_t param[8] = {0}; *(uint16_t *)(param + 4) = (uint16_t)ch;
    if (!key || h_au_Open(key, NULL, "AudioRenderer", param)) die("host PCM output cannot be opened");
    return key;
}
void dm_pcmout_start(void *k) { h_au_Start(k); }
void dm_pcmout_close(void *k) { h_au_Close(k); free(k); }   // stop, leave the registry (frees its AOMAX slot), free it and its key (nxnative 8530042)
int dm_pcmout_append(void *k, void *b) { return (int)h_au_Append(k, b); }
void *dm_pcmout_released(void *k) { return h_au_Released(k); }
// Block until the output releases a buffer or ns pass (nxnative e06a8ec's dm_pcmout_wait, MIT): 1 = something was released (take it with
// dm_pcmout_released), 0 = timed out
int dm_pcmout_wait(void *k, int64_t ns) { return dispatch_semaphore_wait(ao(k)->rel_sem, dispatch_time(DISPATCH_TIME_NOW, ns)) == 0; }

// Front-end lifecycle / audio session interruption: suspend real audio output, with the silent sink taking over real-time consumption meanwhile (pacing unbroken); switch back to the AudioUnit on resume.
// The front end calls with 1 on going to background / interruption began, and with 0 on returning to foreground / interruption ended (shouldResume).
void dm_audio_suspend(int on) {
    pthread_mutex_lock(&g_aos_lock);
    if (g_suspended != on) {
        g_suspended = on; int failed = 0;
        for (int i = 0; i < AOMAX; i++) {
            aout *a = g_aos[i];
            if (!a || !a->au) continue;
            // While suspended the silent sink consumes in real time instead: otherwise buffers are no longer released, the FMOD output thread waits forever and the game's audio pacing stalls (same for an incoming call interruption)
            if (on) { if (a->backend == BK_AU) { AudioOutputUnitStop(a->au); null_start(a); } }
            else if (a->backend == BK_NULL) {
                null_stop(a);
                OSStatus st = AudioOutputUnitStart(a->au);
                if (!st) a->backend = BK_AU;
                else {   // The session is still held by someone else (switched back to the game with a call not yet hung up, or the user is still in another app when the interruption ends): not fatal, the silent sink keeps covering, and we retry at the next resume
                    LOG("[red] AudioUnit resume failed (status %d): silent until the next resume", (int)st);
                    null_start(a); failed = 1; } }
        }
        if (failed) g_suspended = 1;   // Resume did not succeed: the state stays "suspended", and the next call with 0 will retry
        LOG("audio %s", on ? "paused (background / interruption)" : failed ? "resume failed" : "resumed (foreground / interruption ended)");
    }
    pthread_mutex_unlock(&g_aos_lock);
}
