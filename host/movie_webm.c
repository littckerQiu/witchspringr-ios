// WebM / Matroska demuxer for the movie library's host backend (movie_webm.h): Tears of the Kingdom's pre-rendered cutscenes (Event/Movie/*.webm:
// VP9, 1920x1080, 30 fps, video only). Layout from the Matroska specification (RFC 9559) and EBML (RFC 8794): an element is an ID (VINT that keeps
// its length marker, 1-4 bytes) and a data size (VINT, 1-8 bytes; all data bits set = unknown size, allowed for Segment and Cluster). EBML header
// (DocType "webm" or "matroska") → Segment → Info (TimestampScale, default 1000000 ns; Duration, a float in TimestampScale units), Tracks →
// TrackEntry, Cluster → Timestamp, SimpleBlock / BlockGroup → Block (a ReferenceBlock in the group: not a key frame). A block is the track number
// (VINT), a timestamp (signed 16 bits in TimestampScale units, relative to the Cluster Timestamp), flags (0x80 key frame in a SimpleBlock, 0x06
// lacing) and the frame. Laced blocks are counted and left out (TotK's movies have none). An unknown-sized Cluster ends at the next top-level element.
// The file is mapped; opening indexes every frame (offset, size, presentation time, key frame), the frames are read from the mapping.
#include "movie_webm.h"
#include <fcntl.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <unistd.h>

enum {
    ID_EBML = 0x1A45DFA3, ID_DOCTYPE = 0x4282, ID_SEGMENT = 0x18538067, ID_SEEKHEAD = 0x114D9B74, ID_INFO = 0x1549A966, ID_TIMESTAMPSCALE = 0x2AD7B1,
    ID_DURATION = 0x4489, ID_TRACKS = 0x1654AE6B, ID_TRACKENTRY = 0xAE, ID_TRACKNUMBER = 0xD7, ID_TRACKTYPE = 0x83, ID_CODECID = 0x86,
    ID_LANGUAGE = 0x22B59C, ID_DEFAULTDURATION = 0x23E383, ID_VIDEO = 0xE0, ID_PIXELWIDTH = 0xB0, ID_PIXELHEIGHT = 0xBA, ID_AUDIO = 0xE1,
    ID_SAMPLINGFREQUENCY = 0xB5, ID_CHANNELS = 0x9F, ID_CLUSTER = 0x1F43B675, ID_TIMESTAMP = 0xE7, ID_SIMPLEBLOCK = 0xA3, ID_BLOCKGROUP = 0xA0,
    ID_BLOCK = 0xA1, ID_REFERENCEBLOCK = 0xFB, ID_CUES = 0x1C53BB6B, ID_CHAPTERS = 0x1043A770, ID_TAGS = 0x1254C367, ID_ATTACHMENTS = 0x1941A469,
};
enum { MAX_TRACKS = 16 };
typedef struct { uint64_t track; webm_frame f; } raw_frame;   // indexed before the tracks are known (Tracks may follow a Cluster)

struct webm {
    int fd; const uint8_t *map; uint64_t size;
    uint64_t timescale; double duration;           // TimestampScale (ns), Info Duration (TimestampScale units)
    int ntracks; webm_track tracks[MAX_TRACKS];
    webm_frame *frames[MAX_TRACKS];
    raw_frame *raw; size_t nraw, capraw;           // frames in file order; pts_us holds the raw timestamp until opening ends
    struct { uint64_t track; int n; } laced[MAX_TRACKS]; int nlaced;
};

// VINT at *p (before end): its length from the leading zero bits. id = 1 keeps the length marker (Element IDs, at most 4 bytes); otherwise the
// marker is dropped (sizes, track numbers, at most 8 bytes) and *unknown tells whether every data bit is 1. 0 when it is malformed or runs past end.
static int vint(const uint8_t *d, uint64_t end, uint64_t *p, uint64_t *v, int id, int *unknown) {
    if (*p >= end) return 0;
    uint8_t b = d[*p]; int n = 1;
    while (n <= 8 && !(b & (0x80 >> (n - 1)))) n++;
    if (n > (id ? 4 : 8) || end - *p < (uint64_t)n) return 0;
    uint8_t mask = (uint8_t)(0xFF >> n);
    uint64_t x = id ? b : (uint64_t)(b & mask); int ones = (b & mask) == mask;
    for (int i = 1; i < n; i++) { uint8_t c = d[*p + i]; x = x << 8 | c; ones &= c == 0xFF; }
    if (unknown) *unknown = !id && ones;
    *p += (uint64_t)n; *v = x;
    return n;
}
typedef struct { uint64_t id, start, end; int unknown; } el;   // start: first data byte; end: past the data (the parent's end when unknown)
static int elem(const webm *w, uint64_t *p, uint64_t end, el *e) {
    uint64_t sz;
    if (!vint(w->map, end, p, &e->id, 1, NULL) || !vint(w->map, end, p, &sz, 0, &e->unknown)) return 0;
    e->start = *p;
    if (e->unknown) e->end = end;
    else { if (sz > end - *p) return 0; e->end = *p + sz; }
    return 1;
}
static uint64_t be_uint(const uint8_t *d, uint64_t n) { uint64_t v = 0; for (uint64_t i = 0; i < n && i < 8; i++) v = v << 8 | d[i]; return v; }
static double be_float(const uint8_t *d, uint64_t n) {
    if (n == 4) { uint32_t u = (uint32_t)be_uint(d, 4); float f; memcpy(&f, &u, 4); return f; }
    if (n == 8) { uint64_t u = be_uint(d, 8); double f; memcpy(&f, &u, 8); return f; }
    return 0;
}
static void be_string(char *out, size_t n, const uint8_t *d, uint64_t len) {   // EBML strings may be padded with zero bytes
    size_t k = len < n - 1 ? (size_t)len : n - 1; memcpy(out, d, k); out[k] = 0;
}
static int top_level(uint64_t id) {
    return id == ID_SEEKHEAD || id == ID_INFO || id == ID_TRACKS || id == ID_CLUSTER || id == ID_CUES || id == ID_CHAPTERS || id == ID_TAGS ||
           id == ID_ATTACHMENTS || id == ID_EBML;
}

static void info(webm *w, uint64_t p, uint64_t end) {
    el e;
    while (p < end && elem(w, &p, end, &e)) {
        if (e.id == ID_TIMESTAMPSCALE && e.end > e.start) w->timescale = be_uint(w->map + e.start, e.end - e.start);
        else if (e.id == ID_DURATION) w->duration = be_float(w->map + e.start, e.end - e.start);
        p = e.end;
    }
}
static void track_entry(webm *w, uint64_t p, uint64_t end) {
    webm_track t = {0}; el e;
    while (p < end && elem(w, &p, end, &e)) {
        const uint8_t *d = w->map + e.start; uint64_t n = e.end - e.start;
        switch (e.id) {
            case ID_TRACKNUMBER: t.number = (int)be_uint(d, n); break;
            case ID_TRACKTYPE: t.type = (int)be_uint(d, n); break;
            case ID_CODECID: be_string(t.codec, sizeof t.codec, d, n); break;
            case ID_LANGUAGE: be_string(t.lang, sizeof t.lang, d, n); break;
            case ID_DEFAULTDURATION: t.default_ns = (int64_t)be_uint(d, n); break;
            case ID_VIDEO: case ID_AUDIO: {
                if (e.id == ID_AUDIO) { t.channels = 1; t.sample_rate = 8000; }   // RFC 9559 defaults
                uint64_t q = e.start; el s;
                while (q < e.end && elem(w, &q, e.end, &s)) {
                    const uint8_t *sd = w->map + s.start; uint64_t sn = s.end - s.start;
                    if (s.id == ID_PIXELWIDTH) t.width = (int32_t)be_uint(sd, sn);
                    else if (s.id == ID_PIXELHEIGHT) t.height = (int32_t)be_uint(sd, sn);
                    else if (s.id == ID_CHANNELS) t.channels = (int32_t)be_uint(sd, sn);
                    else if (s.id == ID_SAMPLINGFREQUENCY) t.sample_rate = be_float(sd, sn);
                    q = s.end;
                }
                break;
            }
        }
        p = e.end;
    }
    if (t.number > 0 && w->ntracks < MAX_TRACKS) w->tracks[w->ntracks++] = t;
}
static void block(webm *w, uint64_t p, uint64_t end, int64_t cluster_ts, int simple, int referenced) {
    uint64_t tn;
    if (!vint(w->map, end, &p, &tn, 0, NULL) || end - p < 3) return;
    int16_t rel = (int16_t)(w->map[p] << 8 | w->map[p + 1]); uint8_t flags = w->map[p + 2]; p += 3;
    if (flags & 0x06) {
        int i = 0; while (i < w->nlaced && w->laced[i].track != tn) i++;
        if (i == w->nlaced && w->nlaced < MAX_TRACKS) w->laced[w->nlaced++].track = tn;
        if (i < w->nlaced) w->laced[i].n++;
        return;
    }
    if (end == p || end - p > UINT32_MAX) return;
    if (w->nraw == w->capraw) { w->capraw = w->capraw ? w->capraw * 2 : 4096; w->raw = realloc(w->raw, w->capraw * sizeof *w->raw); }
    w->raw[w->nraw++] = (raw_frame){tn, {p, (uint32_t)(end - p), (uint8_t)(simple ? (flags & 0x80) != 0 : !referenced), cluster_ts + rel}};
}
// Returns where the cluster ends: its end, or for an unknown size the next top-level element
static uint64_t cluster(webm *w, uint64_t p, uint64_t end, int unknown) {
    int64_t ts = 0; el e;
    while (p < end) {
        uint64_t at = p;
        if (!elem(w, &p, end, &e)) return end;
        if (unknown && top_level(e.id)) return at;
        if (e.id == ID_TIMESTAMP) ts = (int64_t)be_uint(w->map + e.start, e.end - e.start);
        else if (e.id == ID_SIMPLEBLOCK) block(w, e.start, e.end, ts, 1, 0);
        else if (e.id == ID_BLOCKGROUP) {
            uint64_t q = e.start, bs = 0, be = 0; int referenced = 0; el s;
            while (q < e.end && elem(w, &q, e.end, &s)) {
                if (s.id == ID_BLOCK) { bs = s.start; be = s.end; }
                else if (s.id == ID_REFERENCEBLOCK) referenced = 1;
                q = s.end;
            }
            if (be > bs) block(w, bs, be, ts, 0, referenced);
        }
        p = e.end;
    }
    return end;
}

static webm *fail(webm *w, char *why, size_t n, const char *fmt, ...) {
    va_list ap; va_start(ap, fmt); vsnprintf(why, n, fmt, ap); va_end(ap);
    webm_close(w);
    return NULL;
}
webm *webm_open(const char *file, char *why, size_t why_n) {
    webm *w = calloc(1, sizeof *w); w->fd = -1; w->timescale = 1000000;
    struct stat st;
    if ((w->fd = open(file, O_RDONLY)) < 0 || fstat(w->fd, &st) || st.st_size < 16) return fail(w, why, why_n, "cannot be read");
    const void *m = mmap(NULL, (size_t)st.st_size, PROT_READ, MAP_PRIVATE, w->fd, 0);
    if (m == MAP_FAILED) return fail(w, why, why_n, "cannot be mapped");
    w->map = m; w->size = (uint64_t)st.st_size;
    uint64_t p = 0; el e;
    if (!elem(w, &p, w->size, &e) || e.id != ID_EBML) return fail(w, why, why_n, "no EBML header");
    char doctype[16] = "";
    for (uint64_t q = e.start; q < e.end;) { el s; if (!elem(w, &q, e.end, &s)) break; if (s.id == ID_DOCTYPE) be_string(doctype, sizeof doctype, w->map + s.start, s.end - s.start); q = s.end; }
    if (strcmp(doctype, "webm") && strcmp(doctype, "matroska")) return fail(w, why, why_n, "DocType \"%s\" is neither webm nor matroska", doctype);
    p = e.end;
    while (p < w->size && elem(w, &p, w->size, &e) && e.id != ID_SEGMENT) p = e.end;
    if (e.id != ID_SEGMENT) return fail(w, why, why_n, "no Segment");
    for (uint64_t q = e.start; q < e.end;) {
        el s; uint64_t at = q;
        if (!elem(w, &q, e.end, &s)) break;
        if (s.id == ID_INFO) info(w, s.start, s.end);
        else if (s.id == ID_TRACKS) { for (uint64_t r = s.start; r < s.end;) { el t; if (!elem(w, &r, s.end, &t)) break; if (t.id == ID_TRACKENTRY) track_entry(w, t.start, t.end); r = t.end; } }
        else if (s.id == ID_CLUSTER) { q = cluster(w, s.start, s.end, s.unknown); if (q <= at) break; continue; }
        else if (s.unknown) break;   // only Segment and Cluster may have an unknown size
        q = s.end;
    }
    if (!w->timescale) return fail(w, why, why_n, "TimestampScale 0");
    for (size_t i = 0; i < w->nraw; i++) w->raw[i].f.pts_us = w->raw[i].f.pts_us * (int64_t)w->timescale / 1000;
    int frames = 0;
    for (int t = 0; t < w->ntracks; t++) {
        webm_track *tr = &w->tracks[t]; int n = 0;
        for (size_t i = 0; i < w->nraw; i++) n += w->raw[i].track == (uint64_t)tr->number;
        w->frames[t] = malloc(sizeof(webm_frame) * (size_t)(n ? n : 1));
        for (size_t i = 0; i < w->nraw; i++)
            if (w->raw[i].track == (uint64_t)tr->number) { w->frames[t][tr->nframes++] = w->raw[i].f; if (w->raw[i].f.size > tr->max_size) tr->max_size = w->raw[i].f.size; }
        for (int i = 0; i < w->nlaced; i++) if (w->laced[i].track == (uint64_t)tr->number) tr->laced = w->laced[i].n;
        frames += tr->nframes;
    }
    free(w->raw); w->raw = NULL; w->nraw = w->capraw = 0;
    if (!w->ntracks) return fail(w, why, why_n, "no tracks");
    if (!frames) return fail(w, why, why_n, "no frames");
    madvise((void *)w->map, (size_t)w->size, MADV_SEQUENTIAL);
    return w;
}
void webm_close(webm *w) {
    if (!w) return;
    for (int t = 0; t < MAX_TRACKS; t++) free(w->frames[t]);
    free(w->raw);
    if (w->map) munmap((void *)w->map, (size_t)w->size);
    if (w->fd >= 0) close(w->fd);
    free(w);
}
int webm_track_count(const webm *w) { return w->ntracks; }
const webm_track *webm_track_at(const webm *w, int i) { return i >= 0 && i < w->ntracks ? &w->tracks[i] : NULL; }
int64_t webm_duration_us(const webm *w) { return w->duration > 0 ? (int64_t)(w->duration * (double)w->timescale / 1000.0) : 0; }
uint64_t webm_file_size(const webm *w) { return w->size; }
const webm_frame *webm_frames(const webm *w, int track) { return track >= 0 && track < w->ntracks ? w->frames[track] : NULL; }
const uint8_t *webm_frame_data(const webm *w, const webm_frame *f) { return w->map + f->off; }
int webm_seek_frame(const webm *w, int track, int64_t us) {
    const webm_track *t = webm_track_at(w, track); int best = 0;
    if (!t) return 0;
    for (int i = 0; i < t->nframes; i++) if (w->frames[track][i].key && w->frames[track][i].pts_us <= us) best = i;
    return best;
}
