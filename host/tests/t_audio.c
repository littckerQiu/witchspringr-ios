// hle_audio.c unit test (silent sink): 3 buffers of 100 ms each -> released in order at about 100/200/300 ms, each release triggering the event.
// Expected values are computed directly from the sample rate and block length: 4800 frames / 48 kHz = 100 ms.
// Host PCM output (the audio renderer's): dm_pcmout_wait returns when the first 100 ms block is released (90-115 ms after start), not a poll
// interval later, and times out with 0 when nothing is playing.
// Backend changes (nxnative 8530042): three real outputs, two threads starting and stopping them at random while a third suspends and resumes (as going
// to the background does): never a second consumer on one output (two silent sinks, or a sink beside the AudioUnit), no hang, all stopped at the end.
// Start used to pick its backend outside the lock the suspend holds. Without an output device (a CI runner) only the silent sink path runs.
// DM_AUDIO_MUTE (the sound card callback called directly): muted, what goes out is all zeros and the game's block is still taken and released;
// not muted, the block's samples go out. Negative control: -DDM_TEST_MUTE_NO_PULL (muted without taking the blocks) fails "still taken".
#include "../hle_audio.c"
#include <fcntl.h>
#include <signal.h>
#include <time.h>
uint64_t now_ns(void) { struct timespec t; clock_gettime(CLOCK_MONOTONIC, &t); return (uint64_t)t.tv_sec * 1000000000ull + t.tv_nsec; }
static struct { const void *k; void *v; } om[8];
void *objmap_get(const void *k) { for (int i = 0; i < 8; i++) if (om[i].k == k) return om[i].v; return NULL; }
void objmap_put(const void *k, void *v) { for (int i = 0; i < 8; i++) if (!om[i].k) { om[i].k = k; om[i].v = v; return; } }
void *objmap_del(const void *k) { for (int i = 0; i < 8; i++) if (om[i].k == k) { om[i].k = 0; return om[i].v; } return NULL; }
static _Atomic int g_sig;
void hle_signal_system_event(void *g) { (void)g; atomic_fetch_add_explicit(&g_sig, 1, memory_order_seq_cst); }
void hle_bind_system_event(void *g, int autoclear) { (void)g; (void)autoclear; }   // the real implementation needs a guest thread + SDK kernel event; the unit test only counts triggers
static char g_o4[3][64];
static void *toggler(void *arg) {   // scenario 4: Start / Stop at random on the three outputs
    unsigned r = (unsigned)(uintptr_t)arg;
    for (int i = 0; i < 100; i++) { r = r * 1103515245u + 12345u; void *o = g_o4[(r >> 8) % 3]; if ((r >> 4) & 1) h_au_Start(o); else h_au_Stop(o); usleep((r >> 12) % 400); }
    return NULL;
}
static void *suspender(void *arg) {   // scenario 4: background and back
    unsigned r = (unsigned)(uintptr_t)arg;
    for (int i = 0; i < 40; i++) { r = r * 1103515245u + 12345u; dm_audio_suspend(1); usleep((r >> 8) % 700); dm_audio_suspend(0); usleep((r >> 16) % 700); }
    return NULL;
}
static void on_alarm(int s) { (void)s; static const char m[] = "FAIL scenario 4 hung (30 s)\n"; write(1, m, sizeof m - 1); _exit(1); }
int main(void) {
    {   // 5.1 downmix (expected values worked out by hand from the Q15 coefficients: 0.707*0.707 = 16384/32768 = 0.5, 0.707 = 23170/32768): order front left, front right, centre, LFE, rear left, rear right
        static const struct { int16_t in[6]; int16_t l, r; const char *what; } c[] = {
            { { 0, 0, 10000, 0, 0, 0 }, 5000, 5000, "center only (dialogue) → 5000 each side" },
            { { 0, 0, 0, 0, 10000, 0 }, 5000, 0, "rear left only → left 5000, right 0" },
            { { 10000, 0, 0, 0, 0, 0 }, 7070, 0, "front left only → left 7070 (−3 dB)" },
            { { 0, 0, 0, 30000, 0, 0 }, 0, 0, "LFE only → not mixed in, 0" },
            { { 32767, 32767, 32767, 0, 32767, 32767 }, 32767, 32767, "full scale sum → saturates at 32767" },
            { { -32768, -32768, -32768, 0, -32768, -32768 }, -32768, -32768, "negative full scale sum → saturates at −32768" } };
        int bad = 0;
        for (unsigned i = 0; i < sizeof c / sizeof *c; i++) { int16_t o[2]; downmix51(c[i].in, o, 1); int ok = o[0] == c[i].l && o[1] == c[i].r; bad |= !ok;
            printf("downmix: %s: want (%d,%d), got (%d,%d) %s\n", c[i].what, c[i].l, c[i].r, o[0], o[1], ok ? "ok" : "FAIL"); }
        if (bad) return 1; }
    char out[64], ev[64]; uint8_t prm[16]; gbuf b[3]; static int16_t pcm[3][4800 * 2];
    h_au_InitParam(prm);
    if (h_au_Open(out, ev, NULL, prm)) return 1;
    if (h_au_Ch(out) != 2 || h_au_Rate(out) != 48000 || h_au_State(out) != STATE_STOPPED) { puts("FAIL parameters"); return 1; }
    { qos_class_t qc = QOS_CLASS_UNSPECIFIED; int rp = 0; pthread_get_qos_class_np(ao(out)->notify_th, &qc, &rp);
      printf("release notifier thread QoS: want USER_INTERACTIVE (%#x), got %#x %s\n", QOS_CLASS_USER_INTERACTIVE, qc, qc == QOS_CLASS_USER_INTERACTIVE ? "ok" : "FAIL");
      if (qc != QOS_CLASS_USER_INTERACTIVE) return 1; }
    for (int i = 0; i < 3; i++) { h_au_SetBuf(&b[i], pcm[i], sizeof pcm[i], sizeof pcm[i]); if (!h_au_Append(out, &b[i])) return 1; }
    if (h_au_Released(out)) { puts("FAIL released before start"); return 1; }
    uint64_t t0 = now_ns(); h_au_Start(out);
    int got = 0, fail = 0;
    while (got < 3 && now_ns() - t0 < 10000000000ull) {
        gbuf *r = h_au_Released(out);
        if (!r) { usleep(1000); continue; }
        int ok = r == &b[got];
        printf("release #%d: want block %d in order, got block %ld %s\n", got, got, (long)(r - b), ok ? "ok" : "FAIL");
        fail |= !ok; got++;
    }
    h_au_Close(out);
    int sig1 = atomic_load_explicit(&g_sig, memory_order_acquire);
    printf("released %d/3, event signalled %d times (want 3)\n", got, sig1);
    if (fail || got != 3 || sig1 != 3) return 1;

    // Scenario 2: the real audio output sink (PCM all 0, inaudible) plays 6 blocks of 100 ms each, pausing at 150 ms (app to background / incoming call) and resuming at 350 ms.
    // Expected: during the pause the silent sink takes over and consumes in real time, all 6 blocks are released in order with 6 events; total duration ~ 600 ms (real time, neither stalled by the pause nor sped up).
    setenv("DM_AUDIO", "1", 1);
    char out2[64]; gbuf b2[6]; static int16_t pcm2[6][4800 * 2]; g_sig = 0;
    if (h_au_Open(out2, ev, NULL, prm)) return 1;
    for (int i = 0; i < 6; i++) { h_au_SetBuf(&b2[i], pcm2[i], sizeof pcm2[i], sizeof pcm2[i]); h_au_Append(out2, &b2[i]); }
    t0 = now_ns(); h_au_Start(out2);
    int got2 = 0, order_ok = 1, susp = 0, resumed = 0;
    while (got2 < 6 && now_ns() - t0 < 10000000000ull) {
        uint64_t ms = (now_ns() - t0) / 1000000;
        if (!susp && ms >= 150) { dm_audio_suspend(1); susp = 1; }
        if (susp && !resumed && ms >= 350) { dm_audio_suspend(0); resumed = 1; }
        gbuf *r = h_au_Released(out2);
        if (!r) { usleep(1000); continue; }
        order_ok &= r == &b2[got2]; got2++;
    }
    double total = (now_ns() - t0) / 1e6;
    h_au_Close(out2);
    int sig2 = atomic_load_explicit(&g_sig, memory_order_acquire);
    int ok2 = got2 == 6 && order_ok && sig2 == 6 && total > 520;
    printf("pause / resume: released %d/6 in order=%d events %d (want 6), total at least 520 ms, got %.0f ms %s\n", got2, order_ok, sig2, total, ok2 ? "ok" : "FAIL");

    // Scenario 3: the host PCM output (silent sink) and dm_pcmout_wait
    unsetenv("DM_AUDIO");
    void *po = dm_pcmout_open(2); gbuf b3[2]; static int16_t pcm3[2][4800 * 2];
    for (int i = 0; i < 2; i++) { h_au_SetBuf(&b3[i], pcm3[i], sizeof pcm3[i], sizeof pcm3[i]); dm_pcmout_append(po, &b3[i]); }
    uint64_t t3 = now_ns(); dm_pcmout_start(po);
    int w3 = dm_pcmout_wait(po, 1000000000); double ms3 = (now_ns() - t3) / 1e6; gbuf *r3 = dm_pcmout_released(po);
    int ok3 = w3 == 1 && ms3 >= 90 && ms3 <= 115 && r3 == &b3[0];
    printf("pcmout wait: returned %d after %.1f ms with block %ld released (want 1, 90-115 ms, block 0) %s\n", w3, ms3, r3 ? (long)(r3 - b3) : -1L, ok3 ? "ok" : "FAIL");
    while (dm_pcmout_wait(po, 300000000)) if (dm_pcmout_released(po) == &b3[1]) break;   // the second block
    int w4 = dm_pcmout_wait(po, 20000000);
    printf("pcmout wait with nothing playing: %d after the 20 ms timeout (want 0) %s\n", w4, w4 == 0 ? "ok" : "FAIL");
    int open3 = 0, left3 = 0; for (int i = 0; i < AOMAX; i++) open3 += g_aos[i] != NULL;
    dm_pcmout_close(po); for (int i = 0; i < AOMAX; i++) left3 += g_aos[i] != NULL;
    int okc = left3 == open3 - 1;
    printf("pcmout close: open outputs %d → %d (its AudioOut slot freed) %s\n", open3, left3, okc ? "ok" : "FAIL");

    // Scenario 4: backend changes from three threads
    setenv("DM_AUDIO", "1", 1);
    for (int i = 0; i < 3; i++) if (h_au_Open(g_o4[i], NULL, NULL, prm)) return 1;
    int real4 = ao(g_o4[0])->au != NULL; unsigned d0 = atomic_load(&g_consumer_dupes);
    signal(SIGALRM, on_alarm); alarm(30);
    int save = dup(2), nul = open("/dev/null", O_WRONLY); fflush(stderr); dup2(nul, 2);   // each suspend logs a line
    pthread_t t4[3]; pthread_create(&t4[0], NULL, toggler, (void *)1u); pthread_create(&t4[1], NULL, toggler, (void *)7u); pthread_create(&t4[2], NULL, suspender, (void *)3u);
    for (int i = 0; i < 3; i++) pthread_join(t4[i], NULL);
    int clean = 1; for (int i = 0; i < 3; i++) { h_au_Stop(g_o4[i]); aout *a = ao(g_o4[i]); clean &= a->backend == BK_NONE && atomic_load(&a->sinks) == 0; }
    fflush(stderr); dup2(save, 2); close(save); close(nul); alarm(0);
    unsigned dupes = atomic_load(&g_consumer_dupes) - d0;
    for (int i = 0; i < 3; i++) h_au_Close(g_o4[i]);
    int ok4 = dupes == 0 && clean;
    printf("backend changes from three threads (%s): a second consumer on one output %u times (want 0), all stopped at the end %d %s\n",
           real4 ? "AudioUnits" : "no output device: silent sinks only", dupes, clean, ok4 ? "ok" : "FAIL");
    int ok5;
    {   // Scenario 5: the sound card callback with DM_AUDIO_MUTE, called directly (no device needed)
        char o5[64]; gbuf b5[2]; static int16_t p5[2][480 * 2], out5[480 * 2]; for (int i = 0; i < 480 * 2; i++) p5[0][i] = p5[1][i] = (int16_t)(1000 + i);
        unsetenv("DM_AUDIO"); if (h_au_Open(o5, NULL, NULL, prm)) return 1;
        aout *a = ao(o5); for (int i = 0; i < 2; i++) { h_au_SetBuf(&b5[i], p5[i], sizeof p5[i], sizeof p5[i]); h_au_Append(o5, &b5[i]); }
        atomic_store(&a->state, STATE_STARTED);   // (no backend: only these calls take blocks)
        AudioBufferList bl = {1, {{2, sizeof out5, out5}}};
        g_audio_mute = 1; memset(out5, 0x55, sizeof out5); au_render(a, NULL, NULL, 0, 480, &bl);
        int zero = 1; for (int i = 0; i < 480 * 2; i++) zero &= out5[i] == 0;
        gbuf *r1 = h_au_Released(o5);
        g_audio_mute = 0; au_render(a, NULL, NULL, 0, 480, &bl);
        int same = !memcmp(out5, p5[1], sizeof out5); gbuf *r2 = h_au_Released(o5);
        atomic_store(&a->state, STATE_STOPPED); h_au_Close(o5);
        printf("muted: all zeros out %d, the block still taken and released %d; not muted: the samples out %d, released %d\n", zero, r1 == &b5[0], same, r2 == &b5[1]);
        ok5 = zero && r1 == &b5[0] && same && r2 == &b5[1];
        printf("DM_AUDIO_MUTE: %s\n", ok5 ? "ok" : "FAIL"); }
    return !ok2 || !ok3 || w4 != 0 || !okc || !ok4 || !ok5;
}
