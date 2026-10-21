// movie:: — the Nintendo movie library in subsdk0, which Unity's VideoPlayer drives. Its Extractor, Decoder, MediaData and Buffer are replaced by
// host versions: the container is read through the game's ClientStreamReader into a temporary file, and AVFoundation demuxes and decodes it
// (movie_av.m). Unity asks for decoded data in CPU buffers (DecoderMode_Cpu): video as NV12 (DecoderOutputFormat_VideoColorNv12), audio as PCM16
// (manosaba main+0x9184f8 / +0x9185b4, the Decoder constructions).
// Semantics follow the NintendoSDK movie docs: Status codes, BufferFlags, the MediaData keys, input / output buffer indices and DecoderEvents
// (input available, output available, format changed, error). vtable slot order is that of subsdk0's own vtables (_ZTVN5movie7DecoderE,
// _ZTVN5movie9ExtractorE). Library objects are allocated by the game with its global operator new (0x10 bytes: vtable + host state pointer);
// the deleting destructors return them with the game's operator delete.
// Decoding is driven by the input: each input buffer the game sends is answered with the next decoded unit of that track (one video frame, one
// PCM chunk); the input buffer stays busy until then, so the game cannot run ahead of the output buffers it has not released. The compressed bytes
// the game copies in are not looked at: the decoder reads the same track decoded. When the game loops a movie (Extractor::SeekTo back to the start
// at end of stream), the decoder restarts its read at the time of the next input once its own read has ended.
// The output format (width, height, crop, stride, NV12 plane offsets / audio channels, sample rate) is announced with the format-changed event at
// Start: Unity reads frame sizes in its format-changed handler (main+0x916a60). Crop is inclusive (Unity computes width = right − left + 1).
// Tears of the Kingdom plays its pre-rendered cutscenes (Event/Movie/*.webm, VP9 1920x1080 30 fps, video only) with Extractor::SetDataSource(path)
// ("content:/Event/Movie/....webm", opened in place through the fs mount table) and a VP9 decoder that decodes what the game sends, with libvpx
// (see "Decoder for VP8 / VP9" below; without libvpx at build time the cutscenes cannot play).
// DM_MOVIE=1 logs the calls.
#include "hle.h"
#include "movie_av.h"
#include <stdatomic.h>
#include <sys/stat.h>
#include <unistd.h>
#if __has_include(<vpx/vpx_decoder.h>)   // host/Makefile adds libvpx when it is installed (not in the iOS app yet)
#define DM_HAVE_VPX 1
#include <arm_neon.h>
#include <vpx/vp8dx.h>
#include <vpx/vpx_decoder.h>
#else
#define DM_HAVE_VPX 0
#endif

enum {   // movie::Status (SDK movie/Status.h)
    ST_OK = 0, ST_UNKNOWN = 0x1000, ST_BUFFER_TOO_SMALL = 0x1005, ST_NOT_SUPPORTED = 0x1006, ST_IO = 0x1009, ST_BAD_VALUE = 0x100b, ST_FAILED_TO_CONFIGURE = 0x100c,
    ST_OUT_NOT_AVAILABLE = 0x100e, ST_INVALID_STATE = 0x100f, ST_IN_NOT_AVAILABLE = 0x1011,
    ST_EOS = 0x2000, ST_INVALID_CONFIG = 0x2001, ST_FAILED_TO_START = 0x2002, ST_TRACK_NOT_FOUND = 0x3000, ST_NULL_EXTRACTOR = 0x3003,
    ST_UNSUPPORTED_MEDIA = 0x4000, ST_INVALID_DIMENSIONS = 0x4005,
};
enum { BF_SYNC = 1, BF_CODEC_CONFIG = 2, BF_EOS = 4 };
enum { DEC_NONE = 0, DEC_AVC = 1, DEC_VP8 = 2, DEC_VP9 = 3, DEC_AAC = 4, DEC_VORBIS = 5 };
#define NN_OS_DEFAULT_THREAD_PRIORITY 16
#define MVLOG(fmt, ...) do { if (g_flag.movie) LOG("[movie] [%.3f] " fmt, (now_ns() - g_t0_ns) / 1e9, ##__VA_ARGS__); } while (0)
static int trace(void) { static int v = -1; if (v < 0) { const char *e = getenv("DM_MOVIE"); v = e && atoi(e) >= 2; } return v; }
#define MVTRACE(fmt, ...) do { if (trace()) LOG("[movie] [%.3f] " fmt, (now_ns() - g_t0_ns) / 1e9, ##__VA_ARGS__); } while (0)

// ---------- Media cache: one temporary copy per source path, shared by the extractors that open it ----------
// Unity opens the same clip twice (probe, then playback). The copy is removed when the last extractor using it is destroyed;
// readers already created keep the file open.
typedef struct mv_src { struct mv_src *next; char path[512], file[1024]; mav_media *media; int users, owned; } mv_src;   // owned: file is our temporary copy
static pthread_mutex_t g_src_mu = PTHREAD_MUTEX_INITIALIZER;
static mv_src *g_srcs;

typedef struct { void **vt; } guest_reader;   // movie::ClientStreamReader: slot 2 Open(path, void **h), 3 ReadAt(h, off, buf, n), 4 Close(h)
static int copy_from_reader(void *reader, const char *path, const char *file) {
    void **vt = *(void ***)reader; void *h = NULL;
    if (!(((uint32_t (*)(void *, const char *, void **))vt[2])(reader, path, &h) & 1)) { LOG("[movie] [red] reader cannot open %s", path); return -1; }
    FILE *f = fopen(file, "wb");
    if (!f) { LOG("[movie] [red] cannot create %s", file); ((void (*)(void *, void *))vt[4])(reader, h); return -1; }
    enum { CHUNK = 4 << 20 }; uint8_t *buf = malloc(CHUNK); int64_t off = 0; int ok = 1;
    for (;;) {
        size_t n = ((size_t (*)(void *, void *, int64_t, void *, size_t))vt[3])(reader, h, off, buf, CHUNK);
        if (n > CHUNK || (n && fwrite(buf, 1, n, f) != n)) { ok = 0; break; }
        off += (int64_t)n;
        if (n < CHUNK) break;
    }
    free(buf); fclose(f);
    ((void (*)(void *, void *))vt[4])(reader, h);
    MVLOG("copied %s: %lld bytes", path, (long long)off);
    return ok && off > 0 ? 0 : -1;
}
static mv_src *src_find(const char *path) {
    pthread_mutex_lock(&g_src_mu);
    mv_src *s = g_srcs; while (s && strcmp(s->path, path)) s = s->next;
    if (s) s->users++;
    pthread_mutex_unlock(&g_src_mu);
    return s;
}
static mv_src *src_add(mv_src *s) {
    for (int i = 0; i < mav_track_count(s->media); i++) {
        const mav_track *t = mav_track_at(s->media, i);
        LOG("[movie] %s track %d: %s %dx%d %d fps, %d ch %d Hz, %.3f s", s->path, i, t->mime, t->width, t->height, t->frame_rate, t->channels, t->sample_rate,
            t->duration_us / 1e6);
    }
    s->users = 1;
    pthread_mutex_lock(&g_src_mu); s->next = g_srcs; g_srcs = s; pthread_mutex_unlock(&g_src_mu);
    return s;
}
static mv_src *src_open(void *reader, const char *path) {   // through the game's ClientStreamReader, into a temporary copy
    mv_src *s = src_find(path);
    if (s) return s;
    s = calloc(1, sizeof *s);
    strlcpy(s->path, path, sizeof s->path); s->owned = 1;
    uint64_t h = 0xcbf29ce484222325ull; for (const char *p = path; *p; p++) h = (h ^ (uint8_t)*p) * 0x100000001b3ull;
    const char *tmp = getenv("DM_TEMP"); if (!tmp) tmp = getenv("TMPDIR"); if (!tmp) tmp = "/tmp";
    mkdir(tmp, 0755);
    snprintf(s->file, sizeof s->file, "%s/movie-%016llx.mp4", tmp, (unsigned long long)h);
    if (copy_from_reader(reader, path, s->file) || !(s->media = mav_open(s->file))) {
        LOG("[movie] [red] %s: no playable audio / video track", path);
        unlink(s->file); free(s); return NULL;
    }
    return src_add(s);
}
static mv_src *src_open_path(const char *path) {   // a guest file path, read in place (the file is the game's: never removed)
    mv_src *s = src_find(path);
    if (s) return s;
    s = calloc(1, sizeof *s);
    strlcpy(s->path, path, sizeof s->path);
    if (!dm_fs_host_file(path, s->file, sizeof s->file)) { LOG("[movie] [red] %s: no such file", path); free(s); return NULL; }
    if (!(s->media = mav_open(s->file))) { LOG("[movie] [red] %s: no playable audio / video track", path); free(s); return NULL; }
    return src_add(s);
}
static void src_close(mv_src *s) {
    if (!s) return;
    pthread_mutex_lock(&g_src_mu);
    int last = --s->users == 0;
    if (last) for (mv_src **p = &g_srcs; *p; p = &(*p)->next) if (*p == s) { *p = s->next; break; }
    pthread_mutex_unlock(&g_src_mu);
    if (!last) return;
    mav_release(s->media); if (s->owned) unlink(s->file); free(s);
}

// ---------- Allocator, events ----------
static void (*g_delete)(void *);
static void (*g_signal)(void *);
static void guest_fns(void) {
    if (g_signal) return;
    g_delete = guest_sym("_ZdlPv"); g_signal = guest_sym("_ZN2nn2os11SignalEventEPNS0_9EventTypeE");
    if (!g_delete || !g_signal) die("movie: missing guest operator delete / nn::os::SignalEvent");
}
HLE_FORCE("_ZN5movie12SetAllocatorEPFPvmmS0_EPFvS0_S0_EPFS0_S0_mS0_ES0_", "movie library: host objects use host memory, the allocator is not needed",
          void, mv_SetAllocator, void *alloc, void *fr, void *realloc_, void *user) { (void)alloc; (void)fr; (void)realloc_; (void)user; }
HLE_FORCE_OPT("_ZN5movie11SetCoreMaskEm", "movie library: decoding runs on host threads", void, mv_SetCoreMask, uint64_t mask) { (void)mask; }
HLE_FORCE("_ZN5movie17GetThreadPriorityEv", "movie library: only passed to the Decoder constructor", int, mv_GetThreadPriority, void) { return NN_OS_DEFAULT_THREAD_PRIORITY; }

// ---------- Buffer: host layout, only used through these methods ----------
typedef struct { uint8_t *data; uint64_t cap; int32_t off, size; } mvbuf;
HLE_FORCE("_ZN5movie6BufferC1Ev", "movie::Buffer", void, mv_Buffer, mvbuf *b) { memset(b, 0, sizeof *b); }
HLE_FORCE("_ZN5movie6BufferD1Ev", "movie::Buffer (the data belongs to whoever set it)", void, mv_BufferD, mvbuf *b) { (void)b; }
HLE_FORCE("_ZNK5movie6Buffer4DataEv", "movie::Buffer", void *, mv_BufData, const mvbuf *b) { return b->data; }
HLE_FORCE("_ZNK5movie6Buffer6OffsetEv", "movie::Buffer", int, mv_BufOffset, const mvbuf *b) { return b->off; }
HLE_FORCE("_ZNK5movie6Buffer4SizeEv", "movie::Buffer", int, mv_BufSize, const mvbuf *b) { return b->size; }
HLE_FORCE("_ZN5movie6Buffer8SetRangeEii", "movie::Buffer", void, mv_BufSetRange, mvbuf *b, int off, int size) { b->off = off; b->size = size; }
HLE_FORCE("_ZN5movie6Buffer18SetDataAndCapacityEPvm", "movie::Buffer", void, mv_BufSetData, mvbuf *b, void *p, uint64_t cap) {
    b->data = p; b->cap = cap; b->off = b->size = 0;
}

// ---------- MediaData: the guest object's first 8 bytes point to a host table ----------
typedef struct { char key[24]; char type; int64_t i; int32_t r[4]; char s[32]; } md_ent;   // type: 'i' int32, 'l' int64, 'r' rect, 's' string
typedef struct { int n; md_ent e[24]; mav_media *media; int track; } md_t;              // media / track: set by GetTrackConfiguration, read by Configure
static md_t *md_get(void *self) { md_t **p = self; if (!*p) *p = calloc(1, sizeof(md_t)); return *p; }
static md_ent *md_add(md_t *m, const char *k, char type) {
    md_ent *e = NULL;
    for (int i = 0; i < m->n; i++) if (!strcmp(m->e[i].key, k)) e = &m->e[i];
    if (!e && m->n < (int)(sizeof m->e / sizeof *m->e)) e = &m->e[m->n++];
    if (!e) die("movie: MediaData full");
    memset(e, 0, sizeof *e); strlcpy(e->key, k, sizeof e->key); e->type = type;
    return e;
}
static void md_i32(md_t *m, const char *k, int32_t v) { md_add(m, k, 'i')->i = v; }
static void md_i64(md_t *m, const char *k, int64_t v) { md_add(m, k, 'l')->i = v; }
static void md_str(md_t *m, const char *k, const char *v) { strlcpy(md_add(m, k, 's')->s, v, sizeof m->e[0].s); }
static void md_rect(md_t *m, const char *k, int l, int t, int r, int b) { md_ent *e = md_add(m, k, 'r'); e->r[0] = l; e->r[1] = t; e->r[2] = r; e->r[3] = b; }
static void md_clear(md_t *m) { if (!m) return; if (m->media) mav_release(m->media); memset(m, 0, sizeof *m); }
static void md_copy(md_t *d, const md_t *s) { md_clear(d); if (!s) return; *d = *s; if (d->media) mav_retain(d->media); }
static const md_ent *md_find(void *self, const char *k, char type) {
    const md_t *m = *(md_t **)self;
    if (m) for (int i = 0; i < m->n; i++) if (m->e[i].type == type && !strcmp(m->e[i].key, k)) return &m->e[i];
    return NULL;
}
HLE_FORCE("_ZN5movie9MediaDataC1Ev", "movie::MediaData → host table", void, mv_MediaData, void **self) { *self = NULL; }
HLE_FORCE_OPT("_ZN5movie9MediaDataC1ERKS0_", "movie::MediaData copy", void, mv_MediaDataCopy, void **self, void *const *other) {
    *self = NULL; if (*other) md_copy(md_get(self), *(md_t *const *)other);
}
HLE_FORCE_OPT("_ZN5movie9MediaDataaSERKS0_", "movie::MediaData assignment", void *, mv_MediaDataAssign, void **self, void *const *other) {
    if (self != (void **)other) { if (*other) md_copy(md_get(self), *(md_t *const *)other); else md_clear(*(md_t **)self); }
    return self;
}
HLE_FORCE("_ZN5movie9MediaDataD1Ev", "movie::MediaData → host table", void, mv_MediaDataD, void **self) { md_clear(*(md_t **)self); free(*self); *self = NULL; }
HLE_FORCE_OPT("_ZN5movie9MediaData5ClearEv", "movie::MediaData", void, mv_MediaDataClear, void **self) { md_clear(*(md_t **)self); }
HLE_FORCE("_ZNK5movie9MediaData9FindInt32EPKcPi", "movie::MediaData", int, mv_FindInt32, void **self, const char *k, int32_t *v) {
    const md_ent *e = md_find(self, k, 'i'); if (e) *v = (int32_t)e->i; return e != NULL;
}
HLE_FORCE("_ZNK5movie9MediaData9FindInt64EPKcPl", "movie::MediaData", int, mv_FindInt64, void **self, const char *k, int64_t *v) {
    const md_ent *e = md_find(self, k, 'l'); if (e) *v = e->i; return e != NULL;
}
HLE_FORCE("_ZNK5movie9MediaData10FindStringEPKcPS2_", "movie::MediaData", int, mv_FindString, void **self, const char *k, const char **v) {
    const md_ent *e = md_find(self, k, 's'); if (e) *v = e->s; return e != NULL;
}
HLE_FORCE_OPT("_ZNK5movie9MediaData8FindRectEPKcPiS3_S3_S3_", "movie::MediaData", int, mv_FindRect, void **self, const char *k, int32_t *l, int32_t *t, int32_t *r, int32_t *b) {
    const md_ent *e = md_find(self, k, 'r'); if (e) { *l = e->r[0]; *t = e->r[1]; *r = e->r[2]; *b = e->r[3]; } return e != NULL;
}
// Track description (Extractor::GetTrackConfiguration) and decoder output format (Decoder::GetOutputFormat etc.)
static void md_track(md_t *m, mav_media *media, int track) {
    const mav_track *t = mav_track_at(media, track);
    md_clear(m);
    m->media = media; m->track = track; mav_retain(media);
    md_str(m, "mime", t->mime); md_i64(m, "durationUs", t->duration_us);
    if (t->bit_rate) md_i32(m, "bit-rate", t->bit_rate);
    if (t->kind == MAV_VIDEO) {
        md_i32(m, "width", t->width); md_i32(m, "height", t->height); md_i32(m, "frame-rate", t->frame_rate);
        md_i32(m, "max-input-size", t->max_sample ? t->max_sample : t->width * t->height * 3 / 2);
    } else {
        md_i32(m, "channel-count", t->channels); md_i32(m, "sample-rate", t->sample_rate); md_i32(m, "max-input-size", 64 << 10);
        if (t->lang[0]) md_str(m, "media-language", t->lang);
    }
}

// ---------- Extractor (16 slots) ----------
typedef struct {
    pthread_mutex_t mu;
    mv_src *src;
    int ntracks, sel[8];
    mav_reader *rd[8]; mav_sample cur[8]; int have[8];   // per selected track: the next sample in decode order
} ext_t;
static ext_t *EXT(void *self) { return ((ext_t **)self)[1]; }
static void ext_fill(ext_t *x, int t) { x->have[t] = x->rd[t] && mav_reader_next(x->rd[t], &x->cur[t]) == 1; }
static void ext_start(ext_t *x, int t, int64_t at_us) {
    mav_reader_free(x->rd[t]); x->rd[t] = mav_reader_new(x->src->media, t, at_us, 1); ext_fill(x, t);
}
static int ext_next_track(ext_t *x) {   // the selected track whose pending sample comes first in decode order; -1 at end of stream
    int best = -1;
    for (int t = 0; t < x->ntracks; t++)
        if (x->sel[t] && x->have[t] && (best < 0 || x->cur[t].dts_us < x->cur[best].dts_us)) best = t;
    return best;
}
static void ext_free(ext_t *x) {
    if (!x) return;
    for (int t = 0; t < 8; t++) mav_reader_free(x->rd[t]);
    src_close(x->src); pthread_mutex_destroy(&x->mu); free(x);
}
static void ext_dtor(void **self) { ext_free(EXT(self)); self[1] = NULL; }
static void ext_delete(void **self) { ext_dtor(self); guest_fns(); g_delete(self); }
static int ext_SetDataSourceReader(void **self, void *reader, const char *path) {
    ext_t *x = EXT(self);
    if (x->src) return ST_IO;
    mv_src *s = src_open(reader, path);
    if (!s) return ST_UNSUPPORTED_MEDIA;
    x->src = s; x->ntracks = mav_track_count(s->media);
    MVLOG("Extractor %p SetDataSource %s: %d tracks", (void *)self, path, x->ntracks);
    return ST_OK;
}
static int ext_SetDataSourcePath(void **self, const char *path) {
    ext_t *x = EXT(self);
    if (x->src) return ST_IO;
    mv_src *s = src_open_path(path);
    if (!s) return ST_UNSUPPORTED_MEDIA;
    x->src = s; x->ntracks = mav_track_count(s->media);
    MVLOG("Extractor %p SetDataSource %s: %d tracks", (void *)self, path, x->ntracks);
    return ST_OK;
}
static int ext_SetDataSourceMem(void **self, const void *p, int n) { (void)self; (void)p; LOG("[movie] [red] Extractor::SetDataSource(memory, %d): not supported", n); return ST_NOT_SUPPORTED; }
static int ext_GetTrackCount(void **self, int32_t *n) { ext_t *x = EXT(self); *n = x->ntracks; return x->src ? ST_OK : ST_NULL_EXTRACTOR; }
static int ext_GetTrackConfiguration(void **self, int i, void **md) {
    ext_t *x = EXT(self);
    if (!x->src) return ST_NULL_EXTRACTOR;
    if (i < 0 || i >= x->ntracks) return ST_TRACK_NOT_FOUND;
    md_track(md_get(md), x->src->media, i);
    return ST_OK;
}
static int ext_SelectTrack(void **self, int i) {
    ext_t *x = EXT(self);
    if (!x->src || i < 0 || i >= x->ntracks) return ST_TRACK_NOT_FOUND;
    pthread_mutex_lock(&x->mu);
    if (!x->sel[i]) { x->sel[i] = 1; ext_start(x, i, 0); }
    pthread_mutex_unlock(&x->mu);
    MVLOG("Extractor %p SelectTrack %d", (void *)self, i);
    return ST_OK;
}
static int ext_UnselectTrack(void **self, int i) {
    ext_t *x = EXT(self);
    if (i < 0 || i >= x->ntracks) return ST_TRACK_NOT_FOUND;
    pthread_mutex_lock(&x->mu); x->sel[i] = 0; mav_reader_free(x->rd[i]); x->rd[i] = NULL; x->have[i] = 0; pthread_mutex_unlock(&x->mu);
    return ST_OK;
}
static int ext_SeekTo(void **self, int64_t us) {
    ext_t *x = EXT(self);
    pthread_mutex_lock(&x->mu);
    for (int t = 0; t < x->ntracks; t++) if (x->sel[t]) ext_start(x, t, us);
    pthread_mutex_unlock(&x->mu);
    MVLOG("Extractor %p SeekTo %lld us", (void *)self, (long long)us);
    return ST_OK;
}
static int ext_GetTrackIndexForAvailableData(void **self, uint64_t *idx) {
    ext_t *x = EXT(self);
    pthread_mutex_lock(&x->mu); int t = ext_next_track(x); pthread_mutex_unlock(&x->mu);
    if (t < 0) return ST_EOS;
    *idx = (uint64_t)t; return ST_OK;
}
static int ext_Read(void **self, mvbuf *b) {
    ext_t *x = EXT(self); int st = ST_OK;
    pthread_mutex_lock(&x->mu);
    int t = ext_next_track(x);
    if (t < 0) st = ST_EOS;
    else if (x->cur[t].size > b->cap) st = ST_BUFFER_TOO_SMALL;
    else { memcpy(b->data, x->cur[t].data, x->cur[t].size); b->off = 0; b->size = (int32_t)x->cur[t].size; }
    pthread_mutex_unlock(&x->mu);
    if (st == ST_BUFFER_TOO_SMALL) LOG("[movie] [red] Extractor::Read: sample %zu bytes, buffer %llu", x->cur[t].size, (unsigned long long)b->cap);
    return st;
}
static int ext_Advance(void **self) {
    ext_t *x = EXT(self);
    pthread_mutex_lock(&x->mu); int t = ext_next_track(x); if (t >= 0) ext_fill(x, t); pthread_mutex_unlock(&x->mu);
    return t < 0 ? ST_EOS : ST_OK;
}
static int ext_GetSampleTime(void **self, int64_t *us) {
    ext_t *x = EXT(self);
    pthread_mutex_lock(&x->mu); int t = ext_next_track(x); if (t >= 0) *us = x->cur[t].pts_us; pthread_mutex_unlock(&x->mu);
    return t < 0 ? ST_EOS : ST_OK;
}
static int ext_GetSampleMetaData(void **self, void **md) {
    ext_t *x = EXT(self);
    pthread_mutex_lock(&x->mu); int t = ext_next_track(x); int sync = t >= 0 && x->cur[t].sync; pthread_mutex_unlock(&x->mu);
    if (t < 0) return ST_EOS;
    md_i32(md_get(md), "is-sync-frame", sync);
    return ST_OK;
}
static int ext_GetBufferedRange(void **self, int64_t *start, int64_t *end) {   // the whole file is local
    ext_t *x = EXT(self); int64_t d = 0;
    for (int t = 0; x->src && t < x->ntracks; t++) { int64_t v = mav_track_at(x->src->media, t)->duration_us; if (v > d) d = v; }
    *start = 0; *end = d; return ST_OK;
}
static void *const g_ext_vt[16] = {
    ext_dtor, ext_delete, ext_SetDataSourcePath, ext_SetDataSourceMem, ext_GetTrackCount, ext_GetTrackConfiguration, ext_SelectTrack, ext_UnselectTrack,
    ext_SeekTo, ext_GetTrackIndexForAvailableData, ext_Read, ext_Advance, ext_GetSampleTime, ext_GetSampleMetaData, ext_GetBufferedRange,
    ext_SetDataSourceReader,
};
HLE_FORCE("_ZN5movie9ExtractorC1ENS_13ContainerTypeE", "movie::Extractor → host (AVFoundation)", void, mv_Extractor, void **self, int type) {
    (void)type; guest_fns();
    ext_t *x = calloc(1, sizeof *x); pthread_mutex_init(&x->mu, NULL);
    self[0] = (void *)dm_hwrap_vt(g_ext_vt, 16); self[1] = x;   // the slots run on the thread's host stack (hstack.S)
}
// The non-virtual entries main imports directly
HLE_FORCE_OPT("_ZN5movie9ExtractorD1Ev", "movie::Extractor → host", void, mv_ExtractorD, void **self) { ext_dtor(self); }
HLE_FORCE_OPT("_ZN5movie9Extractor13SetDataSourceEPKc", "movie::Extractor → host", int, mv_ExtSetDataSourcePath, void **self, const char *p) { return ext_SetDataSourcePath(self, p); }
HLE_FORCE_OPT("_ZN5movie9Extractor13GetTrackCountEPi", "movie::Extractor → host", int, mv_ExtGetTrackCount, void **self, int32_t *n) { return ext_GetTrackCount(self, n); }
HLE_FORCE_OPT("_ZN5movie9Extractor21GetTrackConfigurationEiPNS_9MediaDataE", "movie::Extractor → host", int, mv_ExtGetTrackConfiguration, void **self, int i, void **md) {
    return ext_GetTrackConfiguration(self, i, md);
}

// ---------- Decoder (19 slots) ----------
enum { NIN = 4, NOUT = 4 };
enum { IN_FREE, IN_CLIENT, IN_SENT };
enum { OUT_FREE, OUT_READY, OUT_CLIENT };
typedef struct {
    pthread_mutex_t mu;
    int type, fmt, mode, kind, started, last_error;
    mav_media *media; int track; int32_t width, height, channels, sample_rate;
    void *ev[4];                                     // DecoderEvents: input available, output available, format changed, error
    mav_reader *rd; int rd_done, restart;            // restart: read again from the next input's time once rd_done
    int in_state[NIN]; uint8_t *in_mem[NIN]; size_t in_cap; int64_t in_pts[NIN]; uint32_t in_flags[NIN];
    int credit[NIN], ncredit;                        // sent inputs not yet answered, in order
    int eos_in, eos_out;
    int out_state[NOUT]; uint8_t *out_mem[NOUT]; size_t out_cap, out_size[NOUT]; int64_t out_pts[NOUT]; uint32_t out_flags[NOUT];
    int ready[NOUT], nready;
    mav_sample carry; size_t carry_off; int have_carry;   // audio: rest of a decoded chunk larger than one output buffer
    uint64_t frames;
} dec_t;
static dec_t *DEC(void *self) { return ((dec_t **)self)[1]; }
static void dec_format(dec_t *d, void **md) {
    md_t *m = md_get(md);
    md_track(m, d->media, d->track);
    if (d->kind == MAV_VIDEO) {
        md_i32(m, "stride", d->width); md_i32(m, "slice-height", d->height); md_rect(m, "crop", 0, 0, d->width - 1, d->height - 1);
        md_i32(m, "nv12-y-stride", d->width); md_i32(m, "nv12-y-offset", 0); md_i32(m, "nv12-uv-offset", d->width * d->height);
    }
}
static void dec_buffers_free(dec_t *d) {
    for (int i = 0; i < NIN; i++) { free(d->in_mem[i]); d->in_mem[i] = NULL; }
    for (int i = 0; i < NOUT; i++) { free(d->out_mem[i]); d->out_mem[i] = NULL; }
    mav_reader_free(d->rd); d->rd = NULL;
}
static void dec_drop(dec_t *d) {   // Flush / Reset: forget queued work, keep the buffers
    for (int i = 0; i < NIN; i++) d->in_state[i] = IN_FREE;
    for (int i = 0; i < NOUT; i++) d->out_state[i] = OUT_FREE;
    d->ncredit = d->nready = 0; d->eos_in = d->eos_out = 0; d->have_carry = 0;
    mav_reader_free(d->rd); d->rd = NULL; d->rd_done = 0; d->restart = 1;
}
static int out_slot(dec_t *d) { for (int i = 0; i < NOUT; i++) if (d->out_state[i] == OUT_FREE) return i; return -1; }
static void out_push(dec_t *d, int o, const uint8_t *p, size_t n, int64_t pts, uint32_t flags) {
    if (n) memcpy(d->out_mem[o], p, n);
    d->out_size[o] = n; d->out_pts[o] = pts; d->out_flags[o] = flags; d->out_state[o] = OUT_READY; d->ready[d->nready++] = o;
}
// Next decoded unit into output slot o; 0 when the track has ended
static int decode_one(dec_t *d, int o, int64_t at_us) {
    if (!d->rd && !d->rd_done) {
        d->rd = mav_reader_new(d->media, d->track, at_us > 0 ? at_us : 0, 0);
        if (!d->rd) { d->rd_done = 1; d->last_error = ST_UNSUPPORTED_MEDIA; LOG("[movie] [red] decoder: track %d cannot be decoded", d->track); return 0; }
    }
    if (!d->have_carry) {
        int r = d->rd_done ? 0 : mav_reader_next(d->rd, &d->carry);
        if (r != 1) {
            if (r < 0) LOG("[movie] [red] decoder: read error on track %d", d->track);
            d->rd_done = 1; return 0;
        }
        d->have_carry = 1; d->carry_off = 0;
    }
    size_t n = d->carry.size - d->carry_off;
    if (n > d->out_cap) n = d->kind == MAV_AUDIO ? d->out_cap / (2 * d->channels) * (2 * d->channels) : d->out_cap;
    int64_t pts = d->carry.pts_us;
    if (d->kind == MAV_AUDIO && d->carry_off) pts += (int64_t)(d->carry_off / (2 * d->channels)) * 1000000 / d->sample_rate;
    out_push(d, o, d->carry.data + d->carry_off, n, pts, 0);
    d->carry_off += n;
    if (d->carry_off >= d->carry.size) d->have_carry = 0;
    d->frames++;
    return 1;
}
// Answers sent inputs while output slots are free; at end of input drains what is left and ends with an empty end-of-stream output.
// Returns which events to signal (bit 0 input available, bit 1 output available).
static int dec_pump(dec_t *d) {
    int sig = 0, o;
    while (d->started && d->ncredit && (o = out_slot(d)) >= 0) {
        int i = d->credit[0];
        memmove(d->credit, d->credit + 1, sizeof d->credit[0] * (size_t)--d->ncredit);
        int64_t at = 0;   // where a new read starts: the beginning, or this input's time after a loop / flush
        if (d->restart && (d->rd_done || !d->rd) && !(d->in_flags[i] & BF_EOS)) {
            mav_reader_free(d->rd); d->rd = NULL; d->rd_done = 0; d->have_carry = 0; at = d->in_pts[i];
            MVLOG("decoder track %d: restart at %lld us", d->track, (long long)at);
        }
        d->restart = 0;
        if (decode_one(d, o, at)) sig |= 2;
        else if (!(d->in_flags[i] & BF_EOS)) d->restart = 1;   // the game feeds on after our read ended: it looped
        if (d->in_flags[i] & BF_EOS) d->eos_in = 1;
        d->in_state[i] = IN_FREE; sig |= 1;
    }
    while (d->started && d->eos_in && !d->eos_out && !d->ncredit && (o = out_slot(d)) >= 0) {
        if (decode_one(d, o, 0)) { sig |= 2; continue; }
        out_push(d, o, NULL, 0, 0, BF_EOS); d->eos_out = 1; sig |= 2;
        MVLOG("decoder track %d: end of stream after %llu units", d->track, (unsigned long long)d->frames);
    }
    return sig;
}
static void dec_signal(dec_t *d, int sig) {   // outside the lock: the woken game thread calls back in
    if ((sig & 1) && d->ev[0]) g_signal(d->ev[0]);
    if ((sig & 2) && d->ev[1]) g_signal(d->ev[1]);
}
static void dec_dtor(void **self) {
    dec_t *d = DEC(self); if (!d) return;
    dec_buffers_free(d); if (d->media) mav_release(d->media);
    pthread_mutex_destroy(&d->mu); free(d); self[1] = NULL;
}
static void dec_delete(void **self) { dec_dtor(self); g_delete(self); }
static int dec_Configure(void **self, void **md) {
    dec_t *d = DEC(self); const md_t *m = *(md_t **)md;
    if (!m || !m->media) { LOG("[movie] [red] Decoder::Configure without a track configuration"); return ST_INVALID_CONFIG; }
    const mav_track *t = mav_track_at(m->media, m->track);
    int want = t->kind == MAV_VIDEO ? (!strcmp(t->mime, "video/avc") ? DEC_AVC : DEC_NONE) : (!strcmp(t->mime, "audio/mp4a-latm") ? DEC_AAC : DEC_NONE);
    if (want != d->type) { LOG("[movie] [red] Decoder::Configure: decoder type %d, track %s", d->type, t->mime); return ST_UNSUPPORTED_MEDIA; }
    pthread_mutex_lock(&d->mu);
    dec_buffers_free(d); if (d->media) mav_release(d->media);
    d->media = m->media; mav_retain(d->media); d->track = m->track; d->kind = t->kind;
    d->width = t->width; d->height = t->height; d->channels = t->channels ? t->channels : 2; d->sample_rate = t->sample_rate ? t->sample_rate : 48000;
    d->in_cap = t->kind == MAV_VIDEO ? (size_t)t->width * t->height * 3 / 2 + (64 << 10) : 64 << 10;
    // Video: one NV12 frame as movie_av.h packs it. Audio: one AAC frame (1024 samples per channel), so each packet sent is answered with the PCM it holds;
    // larger outputs ran the audio decoder ahead of its input, and since the extractor interleaves tracks by time, video starved behind unread audio.
    d->out_cap = t->kind == MAV_VIDEO ? (size_t)t->width * (t->height + (t->height + 1) / 2) : (size_t)1024 * 2 * d->channels;
    for (int i = 0; i < NIN; i++) d->in_mem[i] = malloc(d->in_cap);
    for (int i = 0; i < NOUT; i++) d->out_mem[i] = malloc(d->out_cap);
    dec_drop(d); d->restart = 0;
    pthread_mutex_unlock(&d->mu);
    MVLOG("Decoder %p Configure: track %d %s", (void *)self, d->track, t->mime);
    return ST_OK;
}
static int dec_RegisterClientEvents(void **self, void **ev) { dec_t *d = DEC(self); for (int i = 0; i < 4; i++) d->ev[i] = ev[i]; return ST_OK; }
static int dec_GetOutputFormat(void **self, void **md) {
    dec_t *d = DEC(self); if (!d->media) return ST_INVALID_CONFIG;
    dec_format(d, md); MVTRACE("dec %p GetOutputFormat", (void *)self); return ST_OK;
}
static int dec_Start(void **self) {
    dec_t *d = DEC(self);
    if (!d->media) return ST_INVALID_CONFIG;
    pthread_mutex_lock(&d->mu); d->started = 1; int sig = 1 | dec_pump(d); pthread_mutex_unlock(&d->mu);
    MVLOG("Decoder %p Start (track %d)", (void *)self, d->track);
    if (d->ev[2]) g_signal(d->ev[2]);   // format changed: Unity learns the frame size from GetOutputFormat
    dec_signal(d, sig);
    return ST_OK;
}
static int dec_Stop(void **self) { dec_t *d = DEC(self); pthread_mutex_lock(&d->mu); d->started = 0; pthread_mutex_unlock(&d->mu); MVLOG("Decoder %p Stop", (void *)self); return ST_OK; }
static int dec_Reset(void **self) {
    dec_t *d = DEC(self);
    pthread_mutex_lock(&d->mu); d->started = 0; dec_drop(d); pthread_mutex_unlock(&d->mu);
    return ST_OK;
}
static int dec_Flush(void **self) {
    dec_t *d = DEC(self);
    pthread_mutex_lock(&d->mu); dec_drop(d); int sig = d->started ? 1 : 0; pthread_mutex_unlock(&d->mu);
    MVLOG("Decoder %p Flush", (void *)self);
    dec_signal(d, sig);
    return ST_OK;
}
static int dec_AcquireInputBufferIndex(void **self, int32_t *idx, int32_t *remaining) {
    dec_t *d = DEC(self); int st = ST_IN_NOT_AVAILABLE;
    pthread_mutex_lock(&d->mu);
    *idx = -1; *remaining = 0;
    for (int i = 0; d->started && i < NIN; i++)
        if (d->in_state[i] == IN_FREE) { if (*idx < 0) { *idx = i; d->in_state[i] = IN_CLIENT; st = ST_OK; } else ++*remaining; }
    pthread_mutex_unlock(&d->mu);
    MVTRACE("dec %p AcquireInput → %#x idx %d rem %d", (void *)self, st, *idx, *remaining);
    return st;
}
static int dec_GetInputBuffer(void **self, int32_t i, mvbuf *b) {
    dec_t *d = DEC(self);
    if (i < 0 || i >= NIN || d->in_state[i] != IN_CLIENT) return ST_IN_NOT_AVAILABLE;
    b->data = d->in_mem[i]; b->cap = d->in_cap; b->off = b->size = 0;
    return ST_OK;
}
static int dec_SendInputBufferForDecode(void **self, int32_t i, int32_t off, int32_t size, int64_t pts, uint32_t flags) {
    (void)off; (void)size;
    dec_t *d = DEC(self);
    pthread_mutex_lock(&d->mu);
    if (i < 0 || i >= NIN || d->in_state[i] != IN_CLIENT) { pthread_mutex_unlock(&d->mu); return ST_IN_NOT_AVAILABLE; }
    d->in_state[i] = IN_SENT; d->in_pts[i] = pts; d->in_flags[i] = flags; d->credit[d->ncredit++] = i;
    MVTRACE("dec %p SendInput idx %d off %d size %d pts %lld flags %#x", (void *)self, i, off, size, (long long)pts, flags);
    int sig = dec_pump(d);
    pthread_mutex_unlock(&d->mu);
    dec_signal(d, sig);
    return ST_OK;
}
static int dec_AcquireOutputBufferIndex(void **self, int32_t *idx, int64_t *pts, uint32_t *flags, int32_t *remaining) {
    dec_t *d = DEC(self); int st = ST_OUT_NOT_AVAILABLE;
    pthread_mutex_lock(&d->mu);
    *idx = -1; *remaining = 0;
    if (d->nready) {
        int o = d->ready[0]; memmove(d->ready, d->ready + 1, sizeof d->ready[0] * (size_t)--d->nready);
        d->out_state[o] = OUT_CLIENT; *idx = o; *pts = d->out_pts[o]; *flags = d->out_flags[o]; *remaining = d->nready; st = ST_OK;
    }
    pthread_mutex_unlock(&d->mu);
    MVTRACE("dec %p AcquireOutput → %#x idx %d pts %lld flags %#x rem %d", (void *)self, st, *idx, st ? 0ll : (long long)*pts, st ? 0 : *flags, *remaining);
    return st;
}
static int out_copy(dec_t *d, int32_t o, mvbuf *b) {
    if (o < 0 || o >= NOUT || d->out_state[o] != OUT_CLIENT) return ST_OUT_NOT_AVAILABLE;
    size_t n = d->out_size[o];
    if (n > b->cap) { LOG("[movie] [red] Decoder::GetOutputBuffer: %zu bytes, buffer %llu", n, (unsigned long long)b->cap); return ST_BUFFER_TOO_SMALL; }
    if (n) memcpy(b->data, d->out_mem[o], n);
    b->off = 0; b->size = (int32_t)n;
    return ST_OK;
}
static int dec_GetOutputBuffer(void **self, int32_t o, mvbuf *b) {
    int st = out_copy(DEC(self), o, b);
    MVTRACE("dec %p GetOutputBuffer idx %d cap %llu → %#x size %d", (void *)self, o, (unsigned long long)b->cap, st, b->size);
    return st;
}
static int dec_GetOutputBufferFmt(void **self, int32_t o, mvbuf *b, void **md) {
    int st = out_copy(DEC(self), o, b); if (!st) dec_format(DEC(self), md);
    MVTRACE("dec %p GetOutputBuffer+format idx %d → %#x", (void *)self, o, st);
    return st;
}
static int dec_GetOutputBufferSize(void **self, int32_t *size, int32_t *align) {
    dec_t *d = DEC(self); *size = (int32_t)d->out_cap; *align = 256;
    MVTRACE("dec %p GetOutputBufferSize → %d", (void *)self, *size);
    return d->media ? ST_OK : ST_INVALID_CONFIG;
}
static int dec_ReleaseOutputBufferIndex(void **self, int32_t o) {
    dec_t *d = DEC(self);
    pthread_mutex_lock(&d->mu);
    if (o < 0 || o >= NOUT || d->out_state[o] != OUT_CLIENT) { pthread_mutex_unlock(&d->mu); return ST_OUT_NOT_AVAILABLE; }
    d->out_state[o] = OUT_FREE;
    MVTRACE("dec %p ReleaseOutput idx %d", (void *)self, o);
    int sig = dec_pump(d);
    pthread_mutex_unlock(&d->mu);
    dec_signal(d, sig);
    return ST_OK;
}
static int dec_GetLastError(void **self) { return DEC(self)->last_error; }
static int dec_GetOutputBufferFormat(void **self, int32_t o, void **md) {
    dec_t *d = DEC(self);
    MVTRACE("dec %p GetOutputBufferFormat idx %d", (void *)self, o);
    if (o < 0 || o >= NOUT || d->out_state[o] != OUT_CLIENT) return ST_OUT_NOT_AVAILABLE;
    dec_format(d, md); return ST_OK;
}
static void *const g_dec_vt[19] = {
    dec_dtor, dec_delete, dec_Configure, dec_RegisterClientEvents, dec_GetOutputFormat, dec_Start, dec_Stop, dec_Reset,
    dec_Flush, dec_AcquireInputBufferIndex, dec_GetInputBuffer, dec_SendInputBufferForDecode, dec_AcquireOutputBufferIndex,
    dec_GetOutputBuffer, dec_GetOutputBufferSize, dec_ReleaseOutputBufferIndex, dec_GetLastError, dec_GetOutputBufferFmt, dec_GetOutputBufferFormat,
};
// ---------- Decoder for VP8 / VP9 (libvpx) ----------
// Tears of the Kingdom creates Decoder(VideoVp9, VideoColorNv12, Cpu) for its cutscenes and feeds it the samples our extractor reads. Unlike the
// decoder above, this one decodes the bytes the game sends. Behaviour and pacing follow MacNativeGames' runtime/movie_host.c
// (ly05010419/MacNativeGames, MIT, reviewed at 41e1e0c; libvpx as there), ported by hand onto this file's host MediaData and Buffer:
// - input (4) and output (8) buffer indices are handed out first in, first out; decoding is synchronous in SendInputBufferForDecode, and an input
//   waits while every output buffer is taken (it is decoded when the game releases one);
// - output is packed NV12 (Y rows, then rows of interleaved Cb Cr; stride = width) described as MediaCodec does ("video/raw", color-format 21, crop,
//   nv12-* offsets); the format-changed event comes with the first frame;
// - pacing: the game shows one decoded frame per game frame, so a frame is handed over when its presentation time is due, counted from the first
//   one (dm_movie_tick at every present, on the guest clock), at most one per present. When the game falls behind (TotK drops to 20 fps under load)
//   a frame more than 1.5 frame periods late is dropped if the next one is due too: the picture keeps time with the cutscene's sound instead of
//   lagging. DM_MOVIE_PACE=0 hands every frame over as soon as it is decoded.
// Stop only stops decoding (SDK docs: the client may still send the buffers it holds); Reset returns to the created state.
#if DM_HAVE_VPX
enum { VX_IN = 4, VX_OUT = 8, VX_IN_MIN = 2 << 20 };
enum { EV_INPUT, EV_OUTPUT, EV_FORMAT, EV_ERROR };   // DecoderEvents order
typedef struct { int index; uint32_t flags; int64_t pts; } vx_out;
typedef struct { int index, off, size; uint32_t flags; int64_t pts; } vx_in;
typedef struct vx_t {
    struct vx_t *next;                         // live decoders (dm_movie_tick)
    pthread_mutex_t mu;
    int type, fmt, mode, configured, started, w, h, eos_in, format_sent, last_error;
    void *ev[4];
    vpx_codec_ctx_t vpx; int vpx_live;
    uint8_t *in[VX_IN]; size_t in_cap; int in_free[VX_IN], nin_free;
    vx_in pending[VX_IN]; int npending;        // sent while every output buffer was taken
    uint8_t *out[VX_OUT]; int out_bytes[VX_OUT], out_held[VX_OUT];
    vx_out ready[VX_OUT]; int nready;          // handed over: AcquireOutputBufferIndex takes them in order
    vx_out decoded[VX_OUT]; int ndecoded;      // paced: decoded, not due yet
    uint64_t t0; int64_t pts0;                 // paced: guest time and presentation time of the first frame handed over
    int64_t duration_us;                       // of the configured track, for the output format
    uint64_t frames, decode_ns, errors, dropped;
} vx_t;
static vx_t *g_vx; static pthread_mutex_t g_vx_mu = PTHREAD_MUTEX_INITIALIZER;   // lock order: g_vx_mu, then a decoder's mu
static int g_vx_pace = -1;                                                        // DM_MOVIE_PACE (-1 = not read; the unit test sets it)
static vx_t *VX(void *self) { return ((vx_t **)self)[1]; }
static int vx_pace(void) { if (g_vx_pace < 0) { const char *e = getenv("DM_MOVIE_PACE"); g_vx_pace = !(e && !strcmp(e, "0")); } return g_vx_pace; }
typedef struct { void *ev[8]; int n; } vx_sig;   // events are signalled after the locks are released: the woken game thread calls straight back in
static void vx_note(vx_t *v, vx_sig *s, int which) { if (v->ev[which] && s->n < 8) s->ev[s->n++] = v->ev[which]; }
static void vx_fire(const vx_sig *s) { for (int i = 0; i < s->n; i++) g_signal(s->ev[i]); }
static int vx_frame_bytes(const vx_t *v) { return v->w * v->h + v->w * v->h / 2; }   // even sizes only (Configure)
static void vx_nv12(const vpx_image_t *img, uint8_t *dst, int w, int h) {   // I420 (libvpx) → packed NV12
    for (int y = 0; y < h; y++) memcpy(dst + (size_t)y * w, img->planes[VPX_PLANE_Y] + (size_t)y * img->stride[VPX_PLANE_Y], (size_t)w);
    uint8_t *uv = dst + (size_t)w * h;
    for (int y = 0; y < h / 2; y++) {
        const uint8_t *u = img->planes[VPX_PLANE_U] + (size_t)y * img->stride[VPX_PLANE_U], *cr = img->planes[VPX_PLANE_V] + (size_t)y * img->stride[VPX_PLANE_V];
        uint8_t *o = uv + (size_t)y * w; int x = 0;
        for (; x + 16 <= w / 2; x += 16) { uint8x16x2_t p = {{vld1q_u8(u + x), vld1q_u8(cr + x)}}; vst2q_u8(o + 2 * x, p); }
        for (; x < w / 2; x++) { o[2 * x] = u[x]; o[2 * x + 1] = cr[x]; }
    }
}
static int vx_free_out(const vx_t *v) { for (int i = 0; i < VX_OUT; i++) if (!v->out_held[i]) return i; return -1; }
static void vx_push(vx_t *v, vx_sig *s, int o, uint32_t flags, int64_t pts, int bytes) {
    v->out_held[o] = 1; v->out_bytes[o] = bytes;
    if (vx_pace()) { v->decoded[v->ndecoded++] = (vx_out){o, flags, pts}; return; }
    v->ready[v->nready++] = (vx_out){o, flags, pts}; vx_note(v, s, EV_OUTPUT);
}
// One input into output buffers; 0 when it has to wait for a free output buffer
static int vx_decode(vx_t *v, vx_sig *s, const vx_in *p) {
    int data = p->size > 0 && !(p->flags & BF_CODEC_CONFIG), need = data + ((p->flags & BF_EOS) && !v->eos_in), nfree = 0;
    for (int i = 0; i < VX_OUT; i++) nfree += !v->out_held[i];
    if (nfree < need) return 0;
    if (data) {
        uint64_t t0 = now_ns();
        vpx_codec_err_t e = vpx_codec_decode(&v->vpx, v->in[p->index] + p->off, (unsigned)p->size, NULL, 0);
        if (e != VPX_CODEC_OK) {
            v->errors++; v->last_error = ST_UNKNOWN; vx_note(v, s, EV_ERROR);
            if (v->errors <= 4) LOG("[movie] [red] VP%d decode error on a %d-byte frame at %lld us: %s", v->type == DEC_VP9 ? 9 : 8, p->size, (long long)p->pts,
                                    vpx_codec_error_detail(&v->vpx) ? vpx_codec_error_detail(&v->vpx) : vpx_codec_err_to_string(e));
        } else {
            vpx_codec_iter_t it = NULL; const vpx_image_t *img;
            while ((img = vpx_codec_get_frame(&v->vpx, &it))) {
                int o = vx_free_out(v);
                if (img->fmt != VPX_IMG_FMT_I420 || (int)img->d_w != v->w || (int)img->d_h != v->h || o < 0) {
                    if (!v->errors++) LOG("[movie] [red] VP%d frame %ux%u format %#x (configured %dx%d I420, free output buffer %d): left out", v->type == DEC_VP9 ? 9 : 8,
                                          img->d_w, img->d_h, img->fmt, v->w, v->h, o);
                    v->last_error = ST_INVALID_DIMENSIONS; vx_note(v, s, EV_ERROR); continue;
                }
                if (!v->format_sent) { v->format_sent = 1; vx_note(v, s, EV_FORMAT); }
                vx_nv12(img, v->out[o], v->w, v->h);
                vx_push(v, s, o, 0, p->pts, vx_frame_bytes(v)); v->frames++;
            }
        }
        v->decode_ns += now_ns() - t0;
    }
    int after_eos = v->eos_in;
    if ((p->flags & BF_EOS) && !v->eos_in) {
        v->eos_in = 1; vx_push(v, s, vx_free_out(v), BF_EOS, p->pts, 0);
        MVLOG("VP%d decoder: end of stream after %llu frames (%.2f ms per frame, %llu dropped to keep time, %llu errors)", v->type == DEC_VP9 ? 9 : 8,
              (unsigned long long)v->frames, v->frames ? v->decode_ns / 1e6 / (double)v->frames : 0.0, (unsigned long long)v->dropped, (unsigned long long)v->errors);
    }
    // The end-of-stream input and every input after it stay here until Flush / Reset / Configure, as in the library's codec: ACodec's
    // postFillThisBuffer (subsdk0 0x2bd214) offers no input buffer once the input port is at end of stream (+0x248, set by onInputBufferFilled).
    // Handing them back made TotK's player send them straight back with the end-of-stream flag, signalling input available without end: its
    // event loop takes the input event before the output event, so the end-of-stream output was never taken and the game waited after the movie.
    if (!(p->flags & BF_EOS) && !after_eos) { v->in_free[v->nin_free++] = p->index; vx_note(v, s, EV_INPUT); }
    return 1;
}
static void vx_drain(vx_t *v, vx_sig *s) {
    while (v->npending && vx_decode(v, s, &v->pending[0])) memmove(v->pending, v->pending + 1, (size_t)--v->npending * sizeof v->pending[0]);
}
static uint64_t vx_due(const vx_t *v, const vx_out *d) { int64_t ahead = d->pts - v->pts0; return v->t0 + (uint64_t)(ahead > 0 ? ahead : 0) * 1000; }
// One present: drop leading frames more than 1.5 frame periods late while the next one is due too, then hand over at most one due frame
// (end of stream as soon as it is first in line)
static void vx_release_due(vx_t *v, vx_sig *s, uint64_t now) {
    int dropped = 0;
    while (v->ndecoded > 1 && !(v->decoded[0].flags & BF_EOS) && !(v->decoded[1].flags & BF_EOS) && v->t0) {
        uint64_t due = vx_due(v, &v->decoded[0]), next = vx_due(v, &v->decoded[1]);
        if (now < next || now - due <= (next - due) * 3 / 2) break;
        v->out_held[v->decoded[0].index] = 0; v->dropped++; dropped = 1;
        memmove(v->decoded, v->decoded + 1, (size_t)--v->ndecoded * sizeof v->decoded[0]);
    }
    if (dropped) vx_drain(v, s);
    if (!v->ndecoded) return;
    vx_out d = v->decoded[0];
    if (!(d.flags & BF_EOS)) {
        if (!v->t0) { v->t0 = now; v->pts0 = d.pts; }
        if (now < vx_due(v, &d)) return;
    }
    memmove(v->decoded, v->decoded + 1, (size_t)--v->ndecoded * sizeof v->decoded[0]);
    v->ready[v->nready++] = d; vx_note(v, s, EV_OUTPUT);
}
static void vx_reset_queues(vx_t *v) {
    v->nin_free = 0; for (int i = 0; i < VX_IN; i++) v->in_free[v->nin_free++] = i;
    memset(v->out_held, 0, sizeof v->out_held); v->npending = v->nready = v->ndecoded = 0; v->eos_in = 0; v->t0 = 0;
}
static int vx_codec_init(vx_t *v) {
    vpx_codec_dec_cfg_t cfg = {.threads = 4, .w = (unsigned)v->w, .h = (unsigned)v->h};
    v->vpx_live = vpx_codec_dec_init(&v->vpx, v->type == DEC_VP9 ? vpx_codec_vp9_dx() : vpx_codec_vp8_dx(), &cfg, 0) == VPX_CODEC_OK;
    // VP9 row multithreading (nxnative's hle_movie.c, MIT): rows of a tile decode in parallel, not only tiles (a 1080p movie has few tile columns).
    // DM_VPX_ROW_MT=0 turns it off
    static int row_mt = -1; if (row_mt < 0) { const char *e = getenv("DM_VPX_ROW_MT"); row_mt = !(e && !strcmp(e, "0")); }
    if (v->vpx_live && v->type == DEC_VP9 && row_mt) vpx_codec_control(&v->vpx, VP9D_SET_ROW_MT, 1);
    return v->vpx_live;
}
static void vx_release(vx_t *v) {   // back to the created state
    if (v->vpx_live) { vpx_codec_destroy(&v->vpx); v->vpx_live = 0; }
    for (int i = 0; i < VX_IN; i++) { free(v->in[i]); v->in[i] = NULL; }
    for (int i = 0; i < VX_OUT; i++) { free(v->out[i]); v->out[i] = NULL; }
    v->configured = v->started = 0; vx_reset_queues(v);
}
static void vx_destroy(void **self) {
    vx_t *v = VX(self); if (!v) return;
    pthread_mutex_lock(&g_vx_mu);
    for (vx_t **p = &g_vx; *p; p = &(*p)->next) if (*p == v) { *p = v->next; break; }
    pthread_mutex_lock(&v->mu); pthread_mutex_unlock(&v->mu);   // wait for a dm_movie_tick in progress
    pthread_mutex_unlock(&g_vx_mu);
    MVLOG("VP%d decoder %p destroyed after %llu frames (%llu dropped to keep time)", v->type == DEC_VP9 ? 9 : 8, (void *)self, (unsigned long long)v->frames, (unsigned long long)v->dropped);
    vx_release(v); pthread_mutex_destroy(&v->mu); free(v); self[1] = NULL;
}
static void vx_dtor(void **self) { vx_destroy(self); }
static void vx_delete(void **self) { vx_destroy(self); g_delete(self); }
static void vx_format(const vx_t *v, void **md) {
    md_t *m = md_get(md); md_clear(m);
    md_str(m, "mime", "video/raw"); md_i32(m, "width", v->w); md_i32(m, "height", v->h); md_i32(m, "stride", v->w); md_i32(m, "slice-height", v->h);
    md_i32(m, "color-format", 21);   // COLOR_FormatYUV420SemiPlanar
    md_rect(m, "crop", 0, 0, v->w - 1, v->h - 1); md_i32(m, "crop-width", v->w); md_i32(m, "crop-height", v->h);
    md_i32(m, "nv12-y-stride", v->w); md_i32(m, "nv12-uv-stride", v->w); md_i32(m, "nv12-y-offset", 0); md_i32(m, "nv12-uv-offset", v->w * v->h);
    if (v->duration_us > 0) md_i64(m, "durationUs", v->duration_us);
}
static int vx_Configure(void **self, void **md) {
    vx_t *v = VX(self);
    if (!md || !*md) return ST_BAD_VALUE;
    const char *want = v->type == DEC_VP9 ? "video/x-vnd.on2.vp9" : "video/x-vnd.on2.vp8";
    const md_ent *mime = md_find(md, "mime", 's'), *we = md_find(md, "width", 'i'), *he = md_find(md, "height", 'i'), *mis = md_find(md, "max-input-size", 'i'),
                 *dur = md_find(md, "durationUs", 'l');
    int w = we ? (int)we->i : 0, h = he ? (int)he->i : 0;
    if (v->mode != 1 || v->fmt != 4) { LOG("[movie] [red] VP%d decoder: output format %d mode %d (only NV12 in CPU buffers)", v->type == DEC_VP9 ? 9 : 8, v->fmt, v->mode); return ST_INVALID_CONFIG; }
    if (!mime || strcmp(mime->s, want)) { LOG("[movie] [red] VP%d decoder configured with %s", v->type == DEC_VP9 ? 9 : 8, mime ? mime->s : "no mime"); return ST_UNSUPPORTED_MEDIA; }
    if (w <= 0 || h <= 0 || w > 8192 || h > 8192 || (w | h) & 1) { LOG("[movie] [red] VP%d decoder: %dx%d (even sizes up to 8192 only)", v->type == DEC_VP9 ? 9 : 8, w, h); return ST_INVALID_DIMENSIONS; }
    pthread_mutex_lock(&v->mu);
    vx_release(v); v->w = w; v->h = h; v->duration_us = dur ? dur->i : 0;
    if (!vx_codec_init(v)) { pthread_mutex_unlock(&v->mu); LOG("[movie] [red] libvpx: VP%d decoder initialisation failed", v->type == DEC_VP9 ? 9 : 8); return ST_FAILED_TO_CONFIGURE; }
    v->in_cap = mis && mis->i > VX_IN_MIN ? (size_t)mis->i : VX_IN_MIN;
    for (int i = 0; i < VX_IN; i++) v->in[i] = malloc(v->in_cap);
    for (int i = 0; i < VX_OUT; i++) v->out[i] = malloc((size_t)vx_frame_bytes(v));
    vx_reset_queues(v); v->format_sent = 0; v->last_error = 0; v->configured = 1;
    pthread_mutex_unlock(&v->mu);
    MVLOG("VP%d decoder %p configured: %dx%d, %d input buffers of %zu KiB, %d output frames of %d bytes, libvpx %s", v->type == DEC_VP9 ? 9 : 8, (void *)self, w, h,
          VX_IN, v->in_cap >> 10, VX_OUT, vx_frame_bytes(v), vpx_codec_version_str());
    return ST_OK;
}
static int vx_RegisterClientEvents(void **self, void **ev) { vx_t *v = VX(self); if (!ev) return ST_BAD_VALUE; for (int i = 0; i < 4; i++) v->ev[i] = ev[i]; return ST_OK; }
static int vx_GetOutputFormat(void **self, void **md) { vx_t *v = VX(self); if (!md) return ST_BAD_VALUE; if (!v->configured) return ST_INVALID_CONFIG; vx_format(v, md); return ST_OK; }
static int vx_Start(void **self) {
    vx_t *v = VX(self); vx_sig s = {0};
    pthread_mutex_lock(&v->mu);
    if (!v->configured) { pthread_mutex_unlock(&v->mu); return ST_FAILED_TO_START; }
    v->started = 1; vx_note(v, &s, EV_INPUT);
    pthread_mutex_unlock(&v->mu); vx_fire(&s);
    MVLOG("VP%d decoder %p Start", v->type == DEC_VP9 ? 9 : 8, (void *)self);
    return ST_OK;
}
static int vx_Stop(void **self) { vx_t *v = VX(self); pthread_mutex_lock(&v->mu); v->started = 0; pthread_mutex_unlock(&v->mu); MVLOG("VP decoder %p Stop after %llu frames", (void *)self, (unsigned long long)v->frames); return ST_OK; }
static int vx_Reset(void **self) { vx_t *v = VX(self); pthread_mutex_lock(&v->mu); vx_release(v); v->last_error = 0; pthread_mutex_unlock(&v->mu); return ST_OK; }
static int vx_Flush(void **self) {   // drop queued work; the next input starts a new decode (after a seek: a key frame)
    vx_t *v = VX(self); vx_sig s = {0}; int st = ST_OK;
    pthread_mutex_lock(&v->mu);
    if (v->configured) {
        if (v->vpx_live) { vpx_codec_destroy(&v->vpx); v->vpx_live = 0; }
        if (!vx_codec_init(v)) st = ST_FAILED_TO_CONFIGURE;
        vx_reset_queues(v);
        if (v->started) vx_note(v, &s, EV_INPUT);
    }
    pthread_mutex_unlock(&v->mu); vx_fire(&s);
    MVLOG("VP decoder %p Flush", (void *)self);
    return st;
}
static int vx_AcquireInputBufferIndex(void **self, int32_t *idx, int32_t *remaining) {
    vx_t *v = VX(self); int st = ST_IN_NOT_AVAILABLE;
    if (!idx || !remaining) return ST_BAD_VALUE;
    pthread_mutex_lock(&v->mu);
    *idx = -1; *remaining = 0;
    if (v->started && v->nin_free) { *idx = v->in_free[0]; memmove(v->in_free, v->in_free + 1, (size_t)--v->nin_free * sizeof v->in_free[0]); *remaining = v->nin_free; st = ST_OK; }
    pthread_mutex_unlock(&v->mu);
    MVTRACE("vp %p AcquireInput → %#x idx %d rem %d", (void *)self, st, *idx, *remaining);
    return st;
}
static int vx_GetInputBuffer(void **self, int32_t i, mvbuf *b) {
    vx_t *v = VX(self);
    if (!b) return ST_BAD_VALUE;
    if (i < 0 || i >= VX_IN || !v->in[i]) return ST_IN_NOT_AVAILABLE;
    b->data = v->in[i]; b->cap = v->in_cap; b->off = b->size = 0;
    return ST_OK;
}
static int vx_SendInputBufferForDecode(void **self, int32_t i, int32_t off, int32_t size, int64_t pts, uint32_t flags) {
    vx_t *v = VX(self); vx_sig s = {0};
    if (i < 0 || i >= VX_IN || off < 0 || size < 0 || (uint64_t)off + (uint64_t)size > v->in_cap) return ST_BAD_VALUE;
    pthread_mutex_lock(&v->mu);
    if (!v->started) { pthread_mutex_unlock(&v->mu); return ST_INVALID_STATE; }
    vx_in p = {i, off, size, flags, pts};
    MVTRACE("vp %p SendInput idx %d off %d size %d pts %lld flags %#x", (void *)self, i, off, size, (long long)pts, flags);
    if (v->eos_in) {}   // after the end of stream the buffer stays here (vx_decode)
    else if (v->npending || !vx_decode(v, &s, &p)) v->pending[v->npending++] = p;
    pthread_mutex_unlock(&v->mu); vx_fire(&s);
    return ST_OK;
}
static int vx_AcquireOutputBufferIndex(void **self, int32_t *idx, int64_t *pts, uint32_t *flags, int32_t *remaining) {
    vx_t *v = VX(self); int st = ST_OUT_NOT_AVAILABLE;
    if (!idx || !pts || !flags || !remaining) return ST_BAD_VALUE;
    pthread_mutex_lock(&v->mu);
    *idx = -1; *pts = 0; *flags = 0; *remaining = 0;
    if (v->nready) {
        vx_out r = v->ready[0]; memmove(v->ready, v->ready + 1, (size_t)--v->nready * sizeof v->ready[0]);
        *idx = r.index; *pts = r.pts; *flags = r.flags; *remaining = v->nready; st = ST_OK;
    }
    pthread_mutex_unlock(&v->mu);
    MVTRACE("vp %p AcquireOutput → %#x idx %d pts %lld flags %#x", (void *)self, st, *idx, (long long)*pts, *flags);
    return st;
}
static int vx_copy_out(vx_t *v, int32_t o, mvbuf *b) {   // v->mu held
    if (o < 0 || o >= VX_OUT || !v->out_held[o]) return ST_OUT_NOT_AVAILABLE;
    int n = v->out_bytes[o];
    if (n && (!b->data || b->cap < (uint64_t)n)) { LOG("[movie] [red] Decoder::GetOutputBuffer: buffer of %llu bytes for a %d-byte frame", (unsigned long long)b->cap, n); return ST_BUFFER_TOO_SMALL; }
    if (n) memcpy(b->data, v->out[o], (size_t)n);
    b->off = 0; b->size = n;
    return ST_OK;
}
static int vx_GetOutputBuffer(void **self, int32_t o, mvbuf *b) {
    vx_t *v = VX(self); if (!b) return ST_BAD_VALUE;
    pthread_mutex_lock(&v->mu); int st = vx_copy_out(v, o, b); pthread_mutex_unlock(&v->mu);
    return st;
}
static int vx_GetOutputBufferSize(void **self, int32_t *size, int32_t *align) {   // SDK docs: buffer size and alignment
    vx_t *v = VX(self); if (!size || !align) return ST_BAD_VALUE;
    *size = v->configured ? vx_frame_bytes(v) : 0; *align = 256;
    return v->configured ? ST_OK : ST_INVALID_CONFIG;
}
static int vx_ReleaseOutputBufferIndex(void **self, int32_t o) {
    vx_t *v = VX(self); vx_sig s = {0}; int st = ST_OUT_NOT_AVAILABLE;
    pthread_mutex_lock(&v->mu);
    if (o >= 0 && o < VX_OUT && v->out_held[o]) {
        int queued = 0;
        for (int i = 0; i < v->nready; i++) queued |= v->ready[i].index == o;
        for (int i = 0; i < v->ndecoded; i++) queued |= v->decoded[i].index == o;
        if (!queued) { v->out_held[o] = 0; vx_drain(v, &s); st = ST_OK; }
    }
    pthread_mutex_unlock(&v->mu); vx_fire(&s);
    MVTRACE("vp %p ReleaseOutput idx %d → %#x", (void *)self, o, st);
    return st;
}
static int vx_GetLastError(void **self) { return VX(self)->last_error; }
static int vx_GetOutputBufferFormat(void **self, int32_t o, void **md) {
    vx_t *v = VX(self); if (!md) return ST_BAD_VALUE;
    pthread_mutex_lock(&v->mu); int held = o >= 0 && o < VX_OUT && v->out_held[o]; pthread_mutex_unlock(&v->mu);
    if (!held) return ST_OUT_NOT_AVAILABLE;
    vx_format(v, md); return ST_OK;
}
static int vx_GetOutputBufferFmt(void **self, int32_t o, mvbuf *b, void **md) {
    vx_t *v = VX(self); if (!b && !md) return ST_BAD_VALUE;
    int st = md ? vx_GetOutputBufferFormat(self, o, md) : ST_OK;
    if (st == ST_OK && b) { pthread_mutex_lock(&v->mu); st = vx_copy_out(v, o, b); pthread_mutex_unlock(&v->mu); }
    return st;
}
static void *const g_vx_vt[19] = {   // the same slot order as g_dec_vt
    vx_dtor, vx_delete, vx_Configure, vx_RegisterClientEvents, vx_GetOutputFormat, vx_Start, vx_Stop, vx_Reset,
    vx_Flush, vx_AcquireInputBufferIndex, vx_GetInputBuffer, vx_SendInputBufferForDecode, vx_AcquireOutputBufferIndex,
    vx_GetOutputBuffer, vx_GetOutputBufferSize, vx_ReleaseOutputBufferIndex, vx_GetLastError, vx_GetOutputBufferFmt, vx_GetOutputBufferFormat,
};
static void vx_create(void **self, int type, int fmt, int mode) {
    vx_t *v = calloc(1, sizeof *v); pthread_mutex_init(&v->mu, NULL);
    v->type = type; v->fmt = fmt; v->mode = mode; vx_reset_queues(v);
    pthread_mutex_lock(&g_vx_mu); v->next = g_vx; g_vx = v; pthread_mutex_unlock(&g_vx_mu);
    self[0] = (void *)dm_hwrap_vt(g_vx_vt, 19); self[1] = v;
    MVLOG("VP%d decoder %p created (libvpx %s): output format %d mode %d", type == DEC_VP9 ? 9 : 8, (void *)self, vpx_codec_version_str(), fmt, mode);
}
// Called at every present (gfx/nvn/hle_nvn.c, on the game's thread before it gives its core away): hands paced frames over
void dm_movie_tick(void) {
    if (!vx_pace()) return;
    vx_sig s = {0};
    pthread_mutex_lock(&g_vx_mu);
    for (vx_t *v = g_vx; v; v = v->next) { pthread_mutex_lock(&v->mu); if (v->started) vx_release_due(v, &s, guest_ns()); pthread_mutex_unlock(&v->mu); }
    pthread_mutex_unlock(&g_vx_mu);
    vx_fire(&s);
}
#else
void dm_movie_tick(void) {}
#endif

HLE_FORCE("_ZN5movie7DecoderC1ENS_11DecoderTypeENS_19DecoderOutputFormatENS_11DecoderModeEi", "movie::Decoder → host (AVFoundation)",
          void, mv_Decoder, void **self, int type, int fmt, int mode, int prio) {
    (void)prio; guest_fns();
#if DM_HAVE_VPX
    if (type == DEC_VP9 || type == DEC_VP8) { vx_create(self, type, fmt, mode); return; }
#else
    if (type == DEC_VP9 || type == DEC_VP8) LOG("[movie] [red] Decoder type %d (VP%d): this build has no libvpx (brew install libvpx, then rebuild the host)", type, type == DEC_VP9 ? 9 : 8);
#endif
    dec_t *d = calloc(1, sizeof *d); pthread_mutex_init(&d->mu, NULL);
    d->type = type; d->fmt = fmt; d->mode = mode;
    if (mode != 1 || (fmt != 1 && fmt != 4))   // DecoderMode_Cpu with AudioPcm16 / VideoColorNv12 only
        LOG("[movie] [red] Decoder type %d output format %d mode %d: only CPU mode with PCM16 / NV12 is implemented", type, fmt, mode);
    self[0] = (void *)dm_hwrap_vt(g_dec_vt, 19); self[1] = d;
    MVLOG("Decoder %p created: type %d format %d mode %d", (void *)self, type, fmt, mode);
}
