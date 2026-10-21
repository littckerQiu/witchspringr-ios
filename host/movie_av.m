// Host media backend of the movie library, see movie_av.h. One AVAssetReader per track and reader, so tracks are read independently.
// Compressed reads split sample buffers that carry several samples (audio packets) into single samples, as a container demuxer returns them.
// WebM / Matroska files go to movie_webm.c (AVFoundation does not read them): compressed reads only, straight from the mapped file.
#import <AVFoundation/AVFoundation.h>
#include "movie_av.h"
#include "movie_webm.h"
#include "dm.h"
#include <stdatomic.h>

@interface MavMedia : NSObject {
@public
    AVURLAsset *asset;
    NSMutableArray<AVAssetTrack *> *tracks;
    mav_track info[8];
    int n;
    _Atomic int refs;
    webm *wm; int wtrack[8];   // WebM: the demuxer and the webm track of each entry
}
@end
@implementation MavMedia
- (void)dealloc { webm_close(wm); }
@end

@interface MavReader : NSObject {
@public
    AVAssetReader *reader;
    AVAssetReaderTrackOutput *output;
    int kind, compressed;
    int32_t width, height;
    CMSampleBufferRef cur;     // compressed: sample buffer being split
    CMItemCount next, count;
    uint8_t *buf; size_t cap;  // copy of the current sample
    MavMedia *media;           // WebM: keeps the mapping alive
    const webm_frame *frames; int wnext, wcount;
}
@end
@implementation MavReader
- (void)dealloc { if (cur) CFRelease(cur); free(buf); }
@end

static int64_t us_of(CMTime t) { return CMTIME_IS_NUMERIC(t) ? (int64_t)(CMTimeGetSeconds(t) * 1e6) : -1; }

static int is_ebml(const char *file) {
    FILE *f = fopen(file, "rb"); uint8_t b[4] = {0}; size_t n = f ? fread(b, 1, sizeof b, f) : 0;
    if (f) fclose(f);
    return n == 4 && b[0] == 0x1A && b[1] == 0x45 && b[2] == 0xDF && b[3] == 0xA3;
}
static const char *webm_mime(const webm_track *t) {
    if (t->type == WEBM_VIDEO) return !strcmp(t->codec, "V_VP9") ? "video/x-vnd.on2.vp9" : !strcmp(t->codec, "V_VP8") ? "video/x-vnd.on2.vp8" : "video/unknown";
    return !strcmp(t->codec, "A_VORBIS") ? "audio/vorbis" : "audio/unknown";
}
static mav_media *open_webm(const char *file) {
    char why[200]; webm *w = webm_open(file, why, sizeof why);
    if (!w) { LOG("[movie] [red] %s: %s", file, why); return NULL; }
    MavMedia *m = [MavMedia new]; m->wm = w;
    for (int i = 0; i < webm_track_count(w) && m->n < 8; i++) {
        const webm_track *t = webm_track_at(w, i); const webm_frame *f = webm_frames(w, i);
        if ((t->type != WEBM_VIDEO && t->type != WEBM_AUDIO) || !t->nframes) continue;
        if (t->laced) LOG("[movie] [red] %s track %d: %d laced blocks left out (lacing is not split)", file, t->number, t->laced);
        mav_track *ti = &m->info[m->n];
        memset(ti, 0, sizeof *ti);
        ti->kind = t->type == WEBM_VIDEO ? MAV_VIDEO : MAV_AUDIO; ti->mime = webm_mime(t);
        int64_t span = f[t->nframes - 1].pts_us - f[0].pts_us, bytes = 0;
        for (int k = 0; k < t->nframes; k++) bytes += f[k].size;
        ti->duration_us = webm_duration_us(w) > 0 ? webm_duration_us(w) : span + t->default_ns / 1000;
        ti->bit_rate = ti->duration_us > 0 ? (int32_t)(bytes * 8 * 1000000 / ti->duration_us) : 0;
        ti->max_sample = (int32_t)t->max_size;
        if (t->type == WEBM_VIDEO) {
            ti->width = t->width; ti->height = t->height;
            ti->frame_rate = t->default_ns > 0 ? (int32_t)llround(1e9 / (double)t->default_ns) : span > 0 ? (int32_t)llround((t->nframes - 1) * 1e6 / (double)span) : 0;
        } else { ti->channels = t->channels; ti->sample_rate = (int32_t)llround(t->sample_rate); }
        strlcpy(ti->lang, t->lang, sizeof ti->lang);
        m->wtrack[m->n++] = i;
    }
    if (!m->n) { LOG("[movie] [red] %s: no video or audio frames", file); return NULL; }
    atomic_store(&m->refs, 1);
    return (mav_media *)CFBridgingRetain(m);
}
mav_media *mav_open(const char *file) {
    if (is_ebml(file)) return open_webm(file);
    @autoreleasepool {
        AVURLAsset *a = [AVURLAsset URLAssetWithURL:[NSURL fileURLWithPath:@(file)] options:@{AVURLAssetPreferPreciseDurationAndTimingKey: @YES}];
        MavMedia *m = [MavMedia new];
        m->asset = a; m->tracks = [NSMutableArray new];
        for (AVAssetTrack *t in a.tracks) {
            BOOL video = [t.mediaType isEqualToString:AVMediaTypeVideo], audio = [t.mediaType isEqualToString:AVMediaTypeAudio];
            if ((!video && !audio) || m->n == 8) continue;
            CMFormatDescriptionRef fd = t.formatDescriptions.count ? (__bridge CMFormatDescriptionRef)t.formatDescriptions[0] : NULL;
            FourCharCode codec = fd ? CMFormatDescriptionGetMediaSubType(fd) : 0;
            mav_track *ti = &m->info[m->n];
            memset(ti, 0, sizeof *ti);
            ti->kind = video ? MAV_VIDEO : MAV_AUDIO;
            ti->duration_us = us_of(t.timeRange.duration);
            ti->bit_rate = (int32_t)t.estimatedDataRate;
            if (video) {
                ti->mime = codec == kCMVideoCodecType_H264 ? "video/avc" : "video/unknown";
                CMVideoDimensions d = fd ? CMVideoFormatDescriptionGetDimensions(fd) : (CMVideoDimensions){0, 0};
                ti->width = d.width; ti->height = d.height; ti->frame_rate = (int32_t)lroundf(t.nominalFrameRate);
            } else {
                ti->mime = codec == kAudioFormatMPEG4AAC ? "audio/mp4a-latm" : "audio/unknown";
                const AudioStreamBasicDescription *asbd = fd ? CMAudioFormatDescriptionGetStreamBasicDescription(fd) : NULL;
                if (asbd) { ti->channels = (int32_t)asbd->mChannelsPerFrame; ti->sample_rate = (int32_t)asbd->mSampleRate; }
            }
            NSString *lang = t.languageCode;
            if (lang) strlcpy(ti->lang, lang.UTF8String, sizeof ti->lang);
            [m->tracks addObject:t];
            m->n++;
        }
        if (!m->n) return NULL;
        atomic_store(&m->refs, 1);
        return (mav_media *)CFBridgingRetain(m);
    }
}
void mav_retain(mav_media *m) { atomic_fetch_add(&((__bridge MavMedia *)m)->refs, 1); }
void mav_release(mav_media *m) {
    if (m && atomic_fetch_sub(&((__bridge MavMedia *)m)->refs, 1) == 1) CFBridgingRelease(m);
}
int mav_track_count(const mav_media *m) { return ((__bridge MavMedia *)m)->n; }
const mav_track *mav_track_at(const mav_media *m, int i) {
    MavMedia *mm = (__bridge MavMedia *)m;
    return i >= 0 && i < mm->n ? &mm->info[i] : NULL;
}

mav_reader *mav_reader_new(mav_media *m_, int track, int64_t start_us, int compressed) {
    @autoreleasepool {
        MavMedia *m = (__bridge MavMedia *)m_;
        if (track < 0 || track >= m->n) return NULL;
        const mav_track *ti = &m->info[track];
        if (m->wm) {
            if (!compressed) return NULL;
            MavReader *r = [MavReader new];
            r->media = m; r->kind = ti->kind; r->compressed = 1; r->width = ti->width; r->height = ti->height;
            r->frames = webm_frames(m->wm, m->wtrack[track]); r->wcount = webm_track_at(m->wm, m->wtrack[track])->nframes;
            r->wnext = start_us > 0 ? webm_seek_frame(m->wm, m->wtrack[track], start_us) : 0;
            return (mav_reader *)CFBridgingRetain(r);
        }
        NSError *err = nil;
        AVAssetReader *rd = [[AVAssetReader alloc] initWithAsset:m->asset error:&err];
        if (!rd) return NULL;
        NSDictionary *settings = nil;
        if (!compressed && ti->kind == MAV_VIDEO) settings = @{(id)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange)};
        else if (!compressed) settings = @{AVFormatIDKey: @(kAudioFormatLinearPCM), AVSampleRateKey: @(ti->sample_rate), AVNumberOfChannelsKey: @(ti->channels),
                                           AVLinearPCMBitDepthKey: @16, AVLinearPCMIsFloatKey: @NO, AVLinearPCMIsBigEndianKey: @NO, AVLinearPCMIsNonInterleaved: @NO};
        AVAssetReaderTrackOutput *o = [AVAssetReaderTrackOutput assetReaderTrackOutputWithTrack:m->tracks[track] outputSettings:settings];
        o.alwaysCopiesSampleData = NO;
        if (![rd canAddOutput:o]) return NULL;
        [rd addOutput:o];
        if (start_us > 0) rd.timeRange = CMTimeRangeMake(CMTimeMake(start_us, 1000000), kCMTimePositiveInfinity);
        if (![rd startReading]) return NULL;
        MavReader *r = [MavReader new];
        r->reader = rd; r->output = o; r->kind = ti->kind; r->compressed = compressed; r->width = ti->width; r->height = ti->height;
        return (mav_reader *)CFBridgingRetain(r);
    }
}
void mav_reader_free(mav_reader *r) {
    if (!r) return;
    @autoreleasepool { MavReader *rr = CFBridgingRelease(r); if (rr->reader) [rr->reader cancelReading]; }
}

static uint8_t *room(MavReader *r, size_t n) {
    if (n > r->cap) { free(r->buf); r->cap = n; r->buf = malloc(n); }
    return r->buf;
}
// Decoded video frame → NV12 packed at the track's size (stride = width), whatever the pixel buffer's plane sizes and strides are
static int copy_nv12(MavReader *r, CVPixelBufferRef pb, mav_sample *out) {
    if (CVPixelBufferGetPlaneCount(pb) != 2) return -1;
    size_t W = (size_t)r->width, H = (size_t)r->height, CH = (H + 1) / 2, size = W * (H + CH);
    uint8_t *d = room(r, size);
    memset(d, 0, W * H); memset(d + W * H, 0x80, W * CH);
    CVPixelBufferLockBaseAddress(pb, kCVPixelBufferLock_ReadOnly);
    for (size_t p = 0; p < 2; p++) {
        const uint8_t *s = CVPixelBufferGetBaseAddressOfPlane(pb, p);
        size_t st = CVPixelBufferGetBytesPerRowOfPlane(pb, p), rows = MIN(CVPixelBufferGetHeightOfPlane(pb, p), p ? CH : H);
        size_t cols = MIN(CVPixelBufferGetWidthOfPlane(pb, p) * (p ? 2 : 1), W);
        for (size_t y = 0; y < rows; y++) memcpy(d + (p ? W * H : 0) + y * W, s + y * st, cols);
    }
    CVPixelBufferUnlockBaseAddress(pb, kCVPixelBufferLock_ReadOnly);
    out->data = d; out->size = size;
    return 1;
}
static int copy_block(MavReader *r, CMBlockBufferRef bb, size_t off, size_t n, mav_sample *out) {
    uint8_t *d = room(r, n ? n : 1);
    if (n && CMBlockBufferCopyDataBytes(bb, off, n, d) != kCMBlockBufferNoErr) return -1;
    out->data = d; out->size = n;
    return 1;
}

int mav_reader_next(mav_reader *r_, mav_sample *out) {
    @autoreleasepool {
        MavReader *r = (__bridge MavReader *)r_;
        memset(out, 0, sizeof *out);
        if (r->media) {   // WebM: the next indexed frame, from the mapping
            if (r->wnext >= r->wcount) return 0;
            const webm_frame *f = &r->frames[r->wnext++];
            out->data = webm_frame_data(r->media->wm, f); out->size = f->size; out->pts_us = out->dts_us = f->pts_us; out->sync = f->key;
            return 1;
        }
        for (;;) {
            if (r->cur && r->next < r->count) {   // compressed: next sample of the current buffer
                CMSampleBufferRef sb = r->cur; CMItemCount i = r->next++;
                CMSampleTimingInfo ti; size_t off = 0;
                for (CMItemCount k = 0; k < i; k++) off += CMSampleBufferGetSampleSize(sb, k);
                if (CMSampleBufferGetSampleTimingInfo(sb, i, &ti) != noErr) {   // one timing entry for all samples: count on from the first
                    if (CMSampleBufferGetSampleTimingInfo(sb, 0, &ti) != noErr) return -1;
                    CMTime step = CMTimeMultiply(ti.duration, (int32_t)i);
                    ti.presentationTimeStamp = CMTimeAdd(ti.presentationTimeStamp, step);
                    if (CMTIME_IS_NUMERIC(ti.decodeTimeStamp)) ti.decodeTimeStamp = CMTimeAdd(ti.decodeTimeStamp, step);
                }
                out->pts_us = us_of(ti.presentationTimeStamp); out->dts_us = us_of(ti.decodeTimeStamp);
                if (out->dts_us < 0) out->dts_us = out->pts_us;
                CFArrayRef att = CMSampleBufferGetSampleAttachmentsArray(sb, false);
                CFDictionaryRef a = att && CFArrayGetCount(att) > i ? CFArrayGetValueAtIndex(att, i) : NULL;
                out->sync = !(a && CFDictionaryGetValue(a, kCMSampleAttachmentKey_NotSync) == kCFBooleanTrue);
                return copy_block(r, CMSampleBufferGetDataBuffer(sb), off, CMSampleBufferGetSampleSize(sb, i), out);
            }
            if (r->cur) { CFRelease(r->cur); r->cur = NULL; }
            CMSampleBufferRef sb = [r->output copyNextSampleBuffer];
            if (!sb) return r->reader.status == AVAssetReaderStatusCompleted ? 0 : -1;
            CMItemCount ns = CMSampleBufferGetNumSamples(sb);
            if (!ns) { CFRelease(sb); continue; }   // marker-only sample buffer
            if (r->compressed) { r->cur = sb; r->next = 0; r->count = ns; continue; }
            out->pts_us = us_of(CMSampleBufferGetPresentationTimeStamp(sb)); out->dts_us = out->pts_us; out->sync = 1;
            int ok;
            CVImageBufferRef ib = CMSampleBufferGetImageBuffer(sb);
            if (ib) ok = copy_nv12(r, ib, out);
            else { CMBlockBufferRef bb = CMSampleBufferGetDataBuffer(sb); ok = bb ? copy_block(r, bb, 0, CMBlockBufferGetDataLength(bb), out) : -1; }
            CFRelease(sb);
            return ok;
        }
    }
}
