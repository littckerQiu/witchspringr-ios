// hle_hid.c: DM_KEYS timed script, merging with the front end, the on-screen controls and the game controller, press latches, touch items. A fake clock; the real parser
// and the real GetNpadState path. Expectations are written by hand from the rules in hle_hid.c.
#ifndef HLE_HID_SOURCE
#define HLE_HID_SOURCE "../hle_hid.c"
#endif
#include <signal.h>
#include <sys/wait.h>
#include <unistd.h>
#include HLE_HID_SOURCE
#include "../touchpad.h"   // touchpad.c is linked in: its dm_touchpad_read replaces hle_hid.c's weak default
module_t g_mod[MAX_MOD]; int g_nmod;
uint64_t g_t0_ns;
void hle_bind_system_event(void *g, int autoclear) { (void)g; (void)autoclear; }
static uint64_t clock_ns = 1000000000ull;
uint64_t now_ns(void) { return clock_ns; }
uint64_t guest_ns(void) { return clock_ns; }
static uint64_t frame_now;
uint64_t dm_nvn_frame_count(void) { return frame_now; }
static int opmode = 1;
int dm_opmode(void) { return opmode; }
int touch_fill(void *out, uint64_t now) { (void)out; (void)now; return 0; }
static dm_touch g_t[16]; static int g_tn = -1, g_tcalls;
void dm_touch_set(const dm_touch *t, int n) { g_tn = n; g_tcalls++; if (n > 0) memcpy(g_t, t, sizeof *t * (size_t)n); }
static int checks, fails;
#define CHECK(c, s) do { checks++; int ok = !!(c); fails += !ok; printf("%s %s\n", ok ? "ok" : "FAIL", s); } while (0)
static void at(double sec) { clock_ns = g_kbase + (uint64_t)(sec * 1e9); }   // script time is counted from keys_parse
static void setup(const char *script) { setenv("DM_KEYS", script, 1); keys_parse(); }
static NpadState rd(void) { NpadState s; uint32_t id = 0; h_hid_GetFullKey(&s, &id); return s; }

int main(void) {
    setup("A@1+0.5,B@2,LSL@3,LSU@3.1+0.1,T0.25:0.5@4+0.1");
    at(0.99); CHECK(rd().buttons == 0, "nothing before 1 s");
    at(1.0); CHECK(rd().buttons == DM_BTN_A, "A from 1 s");
    at(1.49); CHECK(rd().buttons == DM_BTN_A, "A held until 1.5 s");
    at(1.5); CHECK(rd().buttons == 0, "A released at 1.5 s");
    at(2.1); CHECK(rd().buttons == DM_BTN_B, "B with the default hold of 0.2 s");
    at(2.2); CHECK(rd().buttons == 0, "B released at 2.2 s");
    at(3.05); { NpadState s = rd(); CHECK(s.lx == -32767 && s.ly == 0 && s.buttons == 0, "LSL pushes the left stick left, not a button"); }
    at(3.15); { NpadState s = rd(); CHECK(s.lx == -32767 && s.ly == 32767, "LSL and LSU overlap: both axes"); }
    at(4.05); rd(); CHECK(g_tn == 1 && g_t[0].id == 0 && g_t[0].x == 0.25f && g_t[0].y == 0.5f, "touch item: one finger at (0.25, 0.5)");
    int calls = g_tcalls; at(4.06); rd(); CHECK(g_tcalls == calls, "unchanged touch set: not pushed again");
    at(4.2); rd(); CHECK(g_tn == 0, "touch item over: all lifted");

    setup("A@f100+10,B@f200,X@2");   // frame items next to a time item
    at(0); frame_now = 99; CHECK(rd().buttons == 0, "frame items: nothing before frame 100");
    frame_now = 100; CHECK(rd().buttons == DM_BTN_A, "A from frame 100");
    at(50); frame_now = 109; CHECK(rd().buttons == DM_BTN_A, "A held through frame 109, whatever the seconds");
    frame_now = 110; CHECK(rd().buttons == 0, "A released at frame 110 (hold 10 frames)");
    frame_now = 211; CHECK(rd().buttons == DM_BTN_B, "B with the default hold of 12 frames: still at frame 211");
    frame_now = 212; CHECK(rd().buttons == 0, "B released at frame 212");
    at(2.1); frame_now = 0; CHECK(rd().buttons == DM_BTN_X, "a time item in the same script still goes by seconds");
    frame_now = 0;

    setup("");
    at(10); dm_input_set(DM_BTN_B, 100, -200, 0, 0); { NpadState s = rd(); CHECK(s.buttons == DM_BTN_B && s.lx == 100 && s.ly == -200, "front end buttons and stick"); }
    dm_input_set(DM_BTN_X, 0, 0, 0, 0); dm_input_set(0, 0, 0, 0, 0);
    CHECK(rd().buttons == DM_BTN_X, "a press released before the read is still seen once");
    CHECK(rd().buttons == 0, "and only once");
    dm_pad_set(DM_BTN_Y, 5000, 6000, 0, 0); { NpadState s = rd(); CHECK(s.buttons == DM_BTN_Y && s.lx == 5000 && s.ly == 6000, "game controller buttons and stick"); }
    dm_input_set(DM_BTN_A, -7, 8, 0, 0); { NpadState s = rd(); CHECK(s.buttons == (DM_BTN_A | DM_BTN_Y) && s.lx == -7 && s.ly == 8, "buttons ORed, the front end's stick wins when not at rest"); }
    dm_input_set(0, 0, 0, 0, 0); dm_pad_set(0, 0, 0, 0, 0); rd();
    CHECK(hid_key_mask("A") == DM_BTN_A && hid_key_mask("MINUS") == DM_BTN_MINUS && hid_key_mask("LSL") == PK_LSL && !hid_key_mask("Q") && !hid_key_mask("T0.5:0.5"),
          "command channel key names: buttons and left stick keys, not touch items or unknown names");
    hid_cmd_keys(DM_BTN_ZR | PK_LSR, 0); { NpadState s = rd(); CHECK(s.buttons == DM_BTN_ZR && s.lx == 32767, "command channel keys held (cmdchan.c down)"); }
    hid_cmd_keys(0, DM_BTN_ZR); { NpadState s = rd(); CHECK(s.buttons == 0 && s.lx == 32767, "... ZR released, the stick still held"); }
    hid_cmd_keys(0, PK_LSR); { NpadState s = rd(); CHECK(s.buttons == 0 && s.lx == 0, "... all released"); }

    // On-screen controls (touchpad.c): buttons ORed; their stick after the front end's, before the controller's
    { NpadState s; uint64_t lb; int32_t la[4];
      CHECK(hle_hid_last(&lb, &la[0], &la[1], &la[2], &la[3]) && lb == 0 && !la[0], "hle_hid_last: what the game last read (nothing held)");
      tp_layout(844, 390, 47, 0, 47, 21); float sx, sy, ax, ay, r; tp_find("stick", &sx, &sy, &r); tp_find("A", &ax, &ay, &r);
      at(20); tp_touch(1, TP_DOWN, ax, ay); s = rd(); CHECK(s.buttons == DM_BTN_A && s.lx == 0, "on-screen A");
      dm_pad_set(DM_BTN_B, 1000, 0, 0, 0); tp_touch(2, TP_DOWN, sx, sy); tp_touch(2, TP_MOVE, sx, sy - 200); at(20.05); s = rd();
      CHECK(s.buttons == (DM_BTN_A | DM_BTN_B) && s.lx == 0 && s.ly == 32767, "with a controller: buttons ORed, the on-screen stick before the controller's");
      CHECK(hle_hid_last(&lb, &la[0], &la[1], &la[2], &la[3]) && lb == (DM_BTN_A | DM_BTN_B) && la[1] == 32767, "hle_hid_last: that state");
      dm_input_set(0, -5, 6, 0, 0); at(20.1); s = rd(); CHECK(s.lx == -5 && s.ly == 6, "the front end's stick before the on-screen one");
      dm_input_set(0, 0, 0, 0, 0); tp_touch(1, TP_UP, 0, 0); tp_touch(2, TP_UP, 0, 0); at(20.15); s = rd();
      CHECK(s.buttons == DM_BTN_B && s.lx == 1000 && s.ly == 0, "fingers lifted: the controller's again");
      dm_pad_set(0, 0, 0, 0, 0); tp_enable(0); rd(); }

    opmode = 0; { NpadState s; uint32_t id = 0x20; dm_input_set(DM_BTN_L, 0, 0, 0, 0); h_hid_GetHandheld(&s, &id);
                  CHECK(s.attributes == 1 && s.buttons == DM_BTN_L, "handheld mode: handheld controller connected"); }
    { NpadState s = rd(); CHECK(s.attributes == 0 && s.buttons == 0, "handheld mode: no full key controller"); }

    pid_t p = fork();
    if (!p) { freopen("/dev/null", "w", stderr); setup("Q@1"); _exit(0); }
    int st; waitpid(p, &st, 0); CHECK(WIFSIGNALED(st), "unknown key name aborts");
    p = fork();
    if (!p) { freopen("/dev/null", "w", stderr); setup("A1"); _exit(0); }
    waitpid(p, &st, 0); CHECK(WIFSIGNALED(st), "item without @ aborts");
    p = fork();
    if (!p) { freopen("/dev/null", "w", stderr); setup("A@fx"); _exit(0); }
    waitpid(p, &st, 0); CHECK(WIFSIGNALED(st), "f without a frame number aborts");

    printf("t_hid_script: %d checks, %d failed\n", checks, fails);
    return fails != 0;
}
