// Host front end interface (Mac: front_mac.m; iOS: ios/Sources/front_ios.m implements the same names).
#pragma once
#include <stdint.h>
// Run the guest: with a window it runs on its own thread and the main thread belongs to the system UI; without one, on the current thread
void front_run(void (*guest)(void));
// The CAMetalLayer the graphics backend presents to (NULL without a window)
void *front_metal_layer(void);
// Text input (software keyboard, hle_swkbd.c): the main thread shows a native input box, the calling thread blocks until confirmed or cancelled.
// UTF-8 throughout; max_chars is a hint (0 = unlimited; hle_swkbd.c truncates in UTF-16 units). Returns 1 with the text in out (NUL terminated),
// 0 when cancelled, -1 without a window (nothing shown).
int front_text_input(const char *title, const char *sub, const char *guide, const char *initial, int max_chars, char *out, int out_cap);

// Start host loading early on a background thread, alongside the front end's own startup (main.c has the conditions)
void dm_host_preload_start(int argc, char **argv);

// Touchscreen (hle_touch.c), called by the front ends: the whole set of touch points is pushed whenever it changes (down / move / up / cancel); n = 0 = all lifted.
// id = finger slot 0–15 (lowest free slot on down, kept until up; used as finger_id); x / y = normalized coordinates [0,1) of the game picture, origin top left.
// The host scales them to the touch space the game reads (see dm_touch_screen) and latches short taps (a down and up between two reads is seen once). Any thread.
typedef struct { uint32_t id; float x, y; } dm_touch;
void dm_touch_set(const dm_touch *t, int n);
// Game picture size (nvnWindowSetCrop width × height): the touch space follows it (Unity reads touches as screen pixels)
void dm_touch_screen(int w, int h);

// A save transaction of the game was refused because a write failed (disk full etc.): the previously committed save is unchanged, the next transaction
// commits as usual. err = the first failing errno (ENOSPC = 28). Called on the game thread; the front end must not block (switch to the main thread)
void front_save_failed(int err);
