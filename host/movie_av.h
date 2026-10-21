// Host media backend of the movie library (hle_movie.c): AVFoundation opens the container, reads samples and decodes; WebM / Matroska files
// (EBML) are demuxed by movie_webm.c instead, and their VP8 / VP9 samples are decoded by the movie decoder from what the game sends (hle_movie.c).
#pragma once
#include <stddef.h>
#include <stdint.h>

typedef struct mav_media mav_media;
typedef struct mav_reader mav_reader;

enum { MAV_VIDEO = 1, MAV_AUDIO = 2 };
typedef struct {
    int kind;                                    // MAV_VIDEO / MAV_AUDIO
    const char *mime;                            // movie::DecoderType names: "video/avc", "audio/mp4a-latm", "video/x-vnd.on2.vp8", "video/x-vnd.on2.vp9",
                                                 // "audio/vorbis"; anything else "video/unknown" / "audio/unknown"
    int32_t width, height, frame_rate, bit_rate, channels, sample_rate;
    int32_t max_sample;                          // largest compressed sample in bytes (0 = not known)
    int64_t duration_us;
    char lang[8];                                // ISO 639-2 code from the container ("" when absent)
} mav_track;

// Audio and video tracks of a file, in container order. NULL when none is found (the reason is logged for WebM). Reference counted: mav_open returns
// one reference.
mav_media *mav_open(const char *file);
void mav_retain(mav_media *m);
void mav_release(mav_media *m);
int mav_track_count(const mav_media *m);
const mav_track *mav_track_at(const mav_media *m, int i);

// Reads one track from start_us on (WebM: from the last key frame at or before it). compressed = 1: samples as stored, in decode order; 0 (not for
// WebM tracks: NULL): decoded, video as NV12 4:2:0 video range
// at the track's size (Y plane width × height, then interleaved CbCr width × (height + 1) / 2, both with stride = width), audio as interleaved PCM16.
mav_reader *mav_reader_new(mav_media *m, int track, int64_t start_us, int compressed);
void mav_reader_free(mav_reader *r);
typedef struct { const uint8_t *data; size_t size; int64_t pts_us, dts_us; int sync; } mav_sample;
// Next sample: 1 = *out filled (data valid until the next call or mav_reader_free), 0 = end of track, -1 = read error.
int mav_reader_next(mav_reader *r, mav_sample *out);
