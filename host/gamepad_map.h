// Controller face buttons → the Switch buttons (pure, used by gamepad.m, checked by tests/t_padmap.c): the GameController buttonA / B / X / Y go to
// the game's A / B / X / Y as they are, whatever the controller. The system reports controllers with printed letters by the letter on the keycap:
// on a Switch Pro controller or a Joy-Con pair the right button (printed A) is buttonA and the bottom one (printed B) is buttonB, as on the Switch;
// Xbox letters and positions agree anyway (bottom A, right B, left X, top Y); controllers without letters (PlayStation) come by position, bottom =
// buttonA. This used to swap Nintendo controllers by position once more (from GCExtendedGamepad.h's diamond convention, never tried on a real
// controller), which swapped A / B and X / Y on them: upstream d2r-mobile 46cb318 (issue #57, a Switch Pro on iPadOS 27 recognised as Nintendo and
// still swapped; SDL's Apple controller code takes a Nintendo controller's buttonA as the right button) and Kamisorara/d2r-mobile 55c6fba.
#pragma once
#include <stdint.h>
#include "dm_input.h"
static inline uint64_t dm_gamepad_face(int a, int b, int x, int y) {   // whether the system's buttonA / B / X / Y are pressed
    return (a ? DM_BTN_A : 0) | (b ? DM_BTN_B : 0) | (x ? DM_BTN_X : 0) | (y ? DM_BTN_Y : 0);
}
