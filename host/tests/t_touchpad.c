// On-screen controls (touchpad.c, plan item 58): an 844x390 layout (an iPhone in landscape, points), fingers at chosen times and the game reading
// the controller at 30 fps on a fake clock. BotWRecomp's input checks (touch.cpp plan_check: stick, A with the stick, a camera drag at 250 pt/s,
// resting, release, the base following, the D-pad sliding, several buttons, a second left finger ignored) with their limits, then this host's own:
// a finger keeps its button when it slides off it, a tap between two reads is seen once, the eye collapses the controls, off releases every finger,
// a read after a pause gives the camera no spike, every control's centre reaches its own button. Negative control: -DDM_TEST_TP_REHIT (a sliding
// finger takes the button under it) fails "slid off A".
#include "../touchpad.c"
#include <stdio.h>
uint64_t g_t0_ns;
static uint64_t clock_ns = 1000000000ull;
uint64_t now_ns(void) { return clock_ns; }
uint64_t dm_nvn_frame_count(void) { return 0; }
int hle_hid_last(uint64_t *b, int32_t *lx, int32_t *ly, int32_t *rx, int32_t *ry) { *b = 0; *lx = *ly = *rx = *ry = 0; return 0; }
static int n, fail;
#define CHECK(c, ...) do { n++; if (c) printf("  ✓ "); else { fail++; printf("  ✗ "); } printf(__VA_ARGS__); printf("\n"); } while (0)
static double T;                     // test time, seconds
static pad S;                        // what the game read last
static void rd(void) { tp_read(T, &S.b, &S.lx, &S.ly, &S.rx, &S.ry); }
static void run_to(double t) { while (T + 1 / 30.0 <= t + 1e-9) { T += 1 / 30.0; rd(); } T = t; rd(); }   // the game reads every 1/30 s up to t
static float cx(const char *l) { float x, y, r; return tp_find(l, &x, &y, &r) ? x : -1000; }
static float cy(const char *l) { float x, y, r; return tp_find(l, &x, &y, &r) ? y : -1000; }
static void down(long id, const char *l, float dx, float dy) { tp_touch(id, TP_DOWN, cx(l) + dx, cy(l) + dy); }
static void up(long id) { tp_touch(id, TP_UP, 0, 0); }
#define PAD(name, pred) CHECK(pred(&S), "%-24s buttons %05llx  L %+.2f %+.2f  R %+.2f %+.2f", name, (unsigned long long)S.b, S.lx, S.ly, S.rx, S.ry)

int main(void) {
    setvbuf(stdout, NULL, _IONBF, 0);
    tp_layout(844, 390, 47, 0, 47, 21);
    float u, px, py, r; tp_find("stick", &px, &py, &r); u = g.u;
    CHECK(u > 0.97f && u < 0.98f && fabsf(r - 54 * u) < 0.01f, "layout: %.4f points per design point (390 / 400), stick ring %.1f", u, r);

    // BotWRecomp's plan_check, t0 = 1 s
    double t0 = 1; run_to(t0);
    tp_touch(1, TP_DOWN, px, py); run_to(t0 + 0.05); tp_touch(1, TP_MOVE, px + 40 * u, py);
    run_to(t0 + 0.25); PAD("stick right", c_stick_right);
    down(2, "A", 0, 0);
    run_to(t0 + 0.45); PAD("A held + stick", c_a_stick);
    float lx0 = 844 * 0.62f, ly0 = 390 * 0.5f; tp_touch(3, TP_DOWN, lx0, ly0);
    double start = T;
    while (T < start + 0.5 - 1e-9) {   // the finger moves at 60 Hz (touch events), the game reads at 30 Hz
        T += 1 / 60.0; tp_touch(3, TP_MOVE, lx0 + (float)(T - start) * 250 * u, ly0);
        if (((int)lround((T - start) * 60)) % 2 == 0) rd();
        if (fabs(T - (t0 + 0.85)) < 1 / 120.0) PAD("camera drag right", c_cam_right);
    }
    run_to(t0 + 1.35); PAD("camera finger resting", c_cam_rest);
    up(3); run_to(t0 + 1.45); PAD("camera released", c_cam_up);
    up(2); run_to(t0 + 1.55); PAD("A released", c_a_up);
    tp_touch(1, TP_MOVE, px - 160 * u, py); run_to(t0 + 1.75); PAD("stick hard left", c_hard_left);
    tp_touch(1, TP_MOVE, px - 130 * u, py); run_to(t0 + 1.95); PAD("stick base followed", c_followed);
    tp_touch(1, TP_MOVE, px - 106 * u, py - 80 * u); run_to(t0 + 2.10); PAD("stick up", c_stick_up);
    up(1); run_to(t0 + 2.20); PAD("stick released", c_released);
    float dr; { float x, y; tp_find("dpad", &x, &y, &dr); }
    down(4, "dpad", 0, -dr * 0.6f); run_to(t0 + 2.30); PAD("dpad up", c_dpad_up);
    tp_touch(4, TP_MOVE, cx("dpad") + dr * 0.6f, cy("dpad")); run_to(t0 + 2.40); PAD("dpad slid right", c_dpad_right);
    up(4); run_to(t0 + 2.50);
    down(5, "ZR", -30 * u, 10 * u); down(6, "R3", 8 * u, 0); down(7, "L", 0, 0); down(8, "Y", 0, -12 * u);
    run_to(t0 + 2.60); PAD("ZR + R3 + L + Y", c_four_a);
    for (long i = 5; i <= 8; i++) up(i);
    run_to(t0 + 2.70); down(9, "-", 0, 0); down(10, "L3", 0, 0); down(11, "X", 0, 0); down(12, "ZL", 0, 0);
    run_to(t0 + 2.80); PAD("- + L3 + X + ZL", c_four_b);
    for (long i = 9; i <= 12; i++) up(i);
    run_to(t0 + 2.85); down(13, "+", 0, 0); down(14, "R", 0, 0); down(15, "B", 0, 0);
    run_to(t0 + 2.95); PAD("+ + R + B", c_three);
    for (long i = 13; i <= 15; i++) up(i);
    run_to(t0 + 3.05); tp_touch(16, TP_DOWN, px, py); tp_touch(17, TP_DOWN, px + 120 * u, py - 40 * u);
    run_to(t0 + 3.10); tp_touch(16, TP_MOVE, px, py + 40 * u); tp_touch(17, TP_MOVE, px + 200 * u, py - 40 * u);
    run_to(t0 + 3.25); PAD("2nd left finger ignored", c_second_left);
    up(16); up(17); run_to(t0 + 3.35); PAD("all released", c_released);

    // A finger owns its control: from A slid onto Y and past the stick's half, still A (and no stick)
    run_to(6); down(20, "A", 0, 0); run_to(6.1);
    tp_touch(20, TP_MOVE, cx("Y"), cy("Y")); run_to(6.2); tp_touch(20, TP_MOVE, 200, 300); run_to(6.3);
    CHECK(S.b == DM_BTN_A && !S.lx && !S.ly, "slid off A onto Y and the stick's half: A still held, nothing else (%05llx)", (unsigned long long)S.b);
    up(20); run_to(6.4);
    // A tap between two reads is seen once
    run_to(7); T += 0.005; down(21, "B", 0, 0); T += 0.010; up(21); run_to(7 + 1 / 30.0);
    CHECK(S.b == DM_BTN_B, "a 10 ms tap between two reads: B seen at the next read");
    run_to(7 + 2 / 30.0); CHECK(S.b == 0, "and only once");
    // The eye
    run_to(8); down(22, "eye", 0, 0); up(22);
    tp_draw_state d; tp_draw(&d);
    CHECK(tp_hidden() && d.collapsed && d.n == 1 && !strcmp(d.items[0].label, "eye"), "eye: collapsed, only the eye drawn");
    tp_touch(23, TP_DOWN, px, py); tp_touch(23, TP_MOVE, px + 40 * u, py); down(24, "A", 0, 0); run_to(8.2);
    CHECK(S.b == 0 && !S.lx && !S.rx, "collapsed: the stick and A dead");
    up(23); up(24); down(25, "eye", 0, 0); up(25);
    tp_touch(26, TP_DOWN, px, py); tp_touch(26, TP_MOVE, px + 40 * u, py); run_to(8.4);
    CHECK(!tp_hidden() && S.lx > 0.6f, "eye again: shown, the stick works (%.2f)", S.lx);
    // Off (a controller connected) releases every finger; back on, the old finger counts no more
    tp_enable(0); { uint64_t b; float a[4]; CHECK(!tp_read(8.5, &b, &a[0], &a[1], &a[2], &a[3]), "off: nothing read"); }
    tp_draw(&d); CHECK(!d.visible, "off: nothing drawn");
    tp_enable(1); tp_touch(26, TP_MOVE, px + 50 * u, py); T = 8.6; rd();
    CHECK(S.lx == 0 && !S.b, "on again: the finger held from before counts no more");
    // A pause between reads (the game loading): the first read after it gives the camera no spike
    run_to(9); tp_touch(27, TP_DOWN, lx0, ly0); run_to(9.1);
    tp_touch(27, TP_MOVE, lx0 + 300 * u, ly0); T = 9.6; rd();
    CHECK(S.rx == 0, "camera: 300 pt moved during a 0.5 s pause in reads, no spike after it (%.2f)", S.rx);
    up(27); run_to(9.7);
    // Every control's centre reaches its own button; the drawing marks it pressed
    static const struct { const char *l; uint64_t m; } all[] = {{"A", DM_BTN_A}, {"B", DM_BTN_B}, {"X", DM_BTN_X}, {"Y", DM_BTN_Y}, {"ZL", DM_BTN_ZL}, {"L", DM_BTN_L},
        {"ZR", DM_BTN_ZR}, {"R", DM_BTN_R}, {"-", DM_BTN_MINUS}, {"+", DM_BTN_PLUS}, {"L3", DM_BTN_LS}, {"R3", DM_BTN_RS}};
    int ok = 1, inside = 1;
    for (int i = 0; i < 12; i++) {
        float x = cx(all[i].l), y = cy(all[i].l); inside &= x > 47 && x < 844 - 47 && y > 0 && y < 390 - 21;
        down(30 + i, all[i].l, 0, 0); T += 1 / 30.0; rd(); tp_draw(&d);
        int pressed = 0; for (int k = 0; k < d.n; k++) pressed |= !strcmp(d.items[k].label, all[i].l) && d.items[k].pressed;
        if (S.b != all[i].m || !pressed) { ok = 0; printf("    %s: %05llx\n", all[i].l, (unsigned long long)S.b); }
        up(30 + i); T += 1 / 30.0; rd();
    }
    CHECK(ok, "each of the 12 buttons' centres presses that button alone, drawn pressed");
    CHECK(inside, "every button inside the safe area");
    // Laid out again: the same size and safe area keep a held finger (UIKit lays out for other reasons too); a new size releases it
    down(41, "A", 0, 0); T += 1 / 30.0; rd();   // (this read takes the press latch)
    tp_layout(844, 390, 47, 0, 47, 21); T += 1 / 30.0; rd();
    CHECK(S.b == DM_BTN_A, "laid out again unchanged: A still held");
    tp_layout(844, 390, 0, 0, 0, 21); T += 1 / 30.0; rd();
    CHECK(S.b == 0, "a new safe area: every finger released");
    up(41); tp_layout(844, 390, 47, 0, 47, 21); tp_find("stick", &px, &py, &r);
    // dm_touchpad_read: the hid scale (±32767, up positive)
    clock_ns = 20000000000ull; tp_touch(40, TP_DOWN, px, py); tp_touch(40, TP_MOVE, px, py - 200 * u);
    { uint64_t b; int32_t a[4]; int on = dm_touchpad_read(&b, &a[0], &a[1], &a[2], &a[3]); CHECK(on && a[0] == 0 && a[1] == 32767, "dm_touchpad_read: stick fully up = ly 32767 (%d, %d)", a[0], a[1]); }
    up(40);
    printf("t_touchpad: %d checks, %d failed\n", n, fail);
    return fail != 0;
}
