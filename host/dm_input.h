// Front end (keyboard / touchscreen / game controller) → nn::hid input state (hle_hid.c).
#pragma once
#include <stdint.h>
// Button bits = nn::hid::NpadButton bit order (the DM_KEYS key names in hle_hid.c come from these). Front ends compose buttons from these names.
enum {
    DM_BTN_A = 1u << 0, DM_BTN_B = 1u << 1, DM_BTN_X = 1u << 2, DM_BTN_Y = 1u << 3,
    DM_BTN_LS = 1u << 4, DM_BTN_RS = 1u << 5, DM_BTN_L = 1u << 6, DM_BTN_R = 1u << 7,
    DM_BTN_ZL = 1u << 8, DM_BTN_ZR = 1u << 9, DM_BTN_PLUS = 1u << 10, DM_BTN_MINUS = 1u << 11,
    DM_BTN_LEFT = 1u << 12, DM_BTN_UP = 1u << 13, DM_BTN_RIGHT = 1u << 14, DM_BTN_DOWN = 1u << 15,
};
#define DM_STICK_MAX 32767   // sticks are ±32767, up is positive
// Keyboard / on-screen controls of the front end
void dm_input_set(uint64_t buttons, int32_t lx, int32_t ly, int32_t rx, int32_t ry);
// Game controller (dm_gamepad.m): kept apart from dm_input_set; buttons are ORed and a stick is used when the front end's is at rest
void dm_pad_set(uint64_t buttons, int32_t lx, int32_t ly, int32_t rx, int32_t ry);
// ios/Sources/dm_gamepad.m (GameController, Mac and iOS), main thread: start watching controllers; clear all held state on focus loss;
// virtual controllers 1 / 2 for scripted tests (inject sets the state, unplug removes it)
void dm_gamepad_start(void);
void dm_gamepad_reset(void);
void dm_gamepad_inject(int n, uint64_t buttons, int32_t lx, int32_t ly, int32_t rx, int32_t ry);
void dm_gamepad_unplug(int n);
uint64_t dm_input_samples(void);   // how many times the game has read a controller (a front end can tell whether a press was seen)
// DM_HID_RECEIPT_LOG=<JSONL path>: log of what GetNpadState really returned (see hle_hid.c)
