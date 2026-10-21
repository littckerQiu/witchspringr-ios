// WebM / Matroska demuxing for the movie library's host backend (movie_av.m hands EBML files here). The file is mapped and indexed when opened.
#pragma once
#include <stddef.h>
#include <stdint.h>

typedef struct webm webm;
enum { WEBM_VIDEO = 1, WEBM_AUDIO = 2 };          // TrackType
typedef struct {
    int number, type;                              // TrackNumber, TrackType
    char codec[32];                                // CodecID: "V_VP9", "V_VP8", "A_VORBIS", "A_OPUS", ...
    char lang[8];                                  // Language ("" when absent)
    int32_t width, height;                         // video: PixelWidth, PixelHeight
    int32_t channels; double sample_rate;          // audio: Channels, SamplingFrequency
    int64_t default_ns;                            // DefaultDuration (0 when absent)
    int nframes, laced;                            // frames indexed; laced blocks left out (lacing is not split)
    uint32_t max_size;                             // largest frame in bytes
} webm_track;
typedef struct { uint64_t off; uint32_t size; uint8_t key; int64_t pts_us; } webm_frame;   // off: frame bytes in the file

// NULL when the file is not a WebM / Matroska file this can read; why says what is wrong
webm *webm_open(const char *file, char *why, size_t why_n);
void webm_close(webm *w);
int webm_track_count(const webm *w);
const webm_track *webm_track_at(const webm *w, int i);
int64_t webm_duration_us(const webm *w);           // Info Duration (0 when absent)
uint64_t webm_file_size(const webm *w);
const webm_frame *webm_frames(const webm *w, int track);    // the track's frames in file (decode) order, webm_track_at(w, track)->nframes of them
const uint8_t *webm_frame_data(const webm *w, const webm_frame *f);
int webm_seek_frame(const webm *w, int track, int64_t us);  // index of the last key frame at or before us (0 when there is none)
