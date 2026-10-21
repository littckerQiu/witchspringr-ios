// Controller face buttons (gamepad_map.h): real controllers × four face buttons, from the physical button pressed to the button the game gets.
// Every row is written by hand from facts, not from the code under test (the table follows upstream d2r-mobile 46cb318's t_padmap.c):
//   what the system reports: Nintendo controllers by the printed letter (issue #57's log; SDL takes a Nintendo controller's buttonA as the right
//   button), Xbox letters match their positions, PlayStation by position (bottom = buttonA);
//   what the game must get: the printed letter (the Switch button of that name, right A confirms); no letter: the Xbox letter at that position.
// The old mapping (Nintendo controllers swapped by position once more) fails every Nintendo row.
#include <stdio.h>
#include "../gamepad_map.h"
static int n, fail;
#define CHECK(c, ...) do { n++; if (c) printf("  ✓ "); else { fail++; printf("  ✗ "); } printf(__VA_ARGS__); printf("\n"); } while (0)
enum { GA, GB, GX, GY };   // the system's buttonA / B / X / Y
int main(void) {
    static const struct { const char *ctl, *pos, *cap; int sys; uint64_t want; } r[] = {
        { "Switch Pro Controller", "right", "A", GA, DM_BTN_A }, { "Switch Pro Controller", "bottom", "B", GB, DM_BTN_B },
        { "Switch Pro Controller", "top", "X", GX, DM_BTN_X }, { "Switch Pro Controller", "left", "Y", GY, DM_BTN_Y },
        { "Joy-Con (L/R)", "right", "A", GA, DM_BTN_A }, { "Joy-Con (L/R)", "bottom", "B", GB, DM_BTN_B },
        { "Joy-Con (L/R)", "top", "X", GX, DM_BTN_X }, { "Joy-Con (L/R)", "left", "Y", GY, DM_BTN_Y },
        { "Xbox Wireless Controller", "bottom", "A", GA, DM_BTN_A }, { "Xbox Wireless Controller", "right", "B", GB, DM_BTN_B },
        { "Xbox Wireless Controller", "left", "X", GX, DM_BTN_X }, { "Xbox Wireless Controller", "top", "Y", GY, DM_BTN_Y },
        { "DualSense Wireless Controller", "bottom", "cross", GA, DM_BTN_A }, { "DualSense Wireless Controller", "right", "circle", GB, DM_BTN_B },
        { "DualSense Wireless Controller", "left", "square", GX, DM_BTN_X }, { "DualSense Wireless Controller", "top", "triangle", GY, DM_BTN_Y } };
    static const char *const nm[] = { "A", "B", "X", "Y" };
    for (unsigned i = 0; i < sizeof r / sizeof *r; i++)
        CHECK(dm_gamepad_face(r[i].sys == GA, r[i].sys == GB, r[i].sys == GX, r[i].sys == GY) == r[i].want, "%s: the %s button (printed %s, the system's button%s) → the game's %s",
              r[i].ctl, r[i].pos, r[i].cap, nm[r[i].sys], nm[__builtin_ctzll(r[i].want)]);
    CHECK(dm_gamepad_face(1, 1, 0, 0) == (DM_BTN_A | DM_BTN_B), "two buttons at once: each counts on its own");
    CHECK(dm_gamepad_face(0, 0, 0, 0) == 0, "none pressed: 0");
    printf("t_padmap: %d checks, %d failed\n", n, fail);
    return fail != 0;
}
