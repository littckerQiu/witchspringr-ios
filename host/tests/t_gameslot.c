// One game at a time (game_slot.c), with processes as the host has them: a second start waits until the holder exits (here a child holding the slot
// for 400 ms); a start for the player stops an agent's run that holds the slot (SIGTERM) and takes it at once; a dead holder blocks nobody; DM_SLOT=0
// skips the slot (the negative control: it does not wait).
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>
int dm_game_slot_acquire(const char *what);
static int n, fail;
#define CHECK(c, ...) do { n++; if (c) printf("  ✓ "); else { fail++; printf("  ✗ "); } printf(__VA_ARGS__); printf("\n"); } while (0)
static double now(void) { return clock_gettime_nsec_np(CLOCK_UPTIME_RAW) / 1e9; }
static pid_t holder(const char *owner, int hold_ms, int pipefd) {   // a child that takes the slot, says so through the pipe, holds it, exits
    pid_t p = fork();
    if (!p) { if (owner) setenv("DM_SLOT_OWNER", owner, 1); else unsetenv("DM_SLOT_OWNER");
              dm_game_slot_acquire("t_gameslot child"); char c = 1; write(pipefd, &c, 1); usleep(hold_ms * 1000); _exit(0); }
    return p;
}
int main(void) {
    char dir[1024]; const char *td = getenv("TMPDIR"); snprintf(dir, sizeof dir, "%s/t_gameslot.XXXXXX", td ? td : "/private/tmp");
    if (!mkdtemp(dir)) { perror("mkdtemp"); return 1; }
    setenv("DM_SLOT_DIR", dir, 1); unsetenv("DM_APP"); unsetenv("DM_SLOT");
    int pf[2]; pipe(pf); char c;
    // 1. an agent's second start waits for the first to exit
    pid_t h = holder(NULL, 400, pf[1]); read(pf[0], &c, 1);
    pid_t w = fork();
    if (!w) { unsetenv("DM_SLOT_OWNER"); double t0 = now(); dm_game_slot_acquire("t_gameslot waiter"); double d = now() - t0; _exit(d >= 0.3 && d < 2.0 ? 0 : 1); }
    int st; waitpid(w, &st, 0); waitpid(h, NULL, 0);
    CHECK(WIFEXITED(st) && WEXITSTATUS(st) == 0, "a second start waits until the holder exits (about 0.4 s)");
    // 2. a start for the player stops an agent's run holding the slot and takes it at once
    h = holder(NULL, 10000, pf[1]); read(pf[0], &c, 1);
    w = fork();
    if (!w) { setenv("DM_SLOT_OWNER", "user", 1); double t0 = now(); dm_game_slot_acquire("t_gameslot player"); _exit(now() - t0 < 1.0 ? 0 : 1); }
    waitpid(w, &st, 0); int hs; waitpid(h, &hs, 0);
    CHECK(WIFEXITED(st) && WEXITSTATUS(st) == 0, "a start for the player takes the slot within a second");
    CHECK(WIFSIGNALED(hs) && WTERMSIG(hs) == SIGTERM, "... after stopping the agent's run with SIGTERM");
    // 3. a dead holder (SIGKILL) blocks nobody
    h = holder(NULL, 10000, pf[1]); read(pf[0], &c, 1); kill(h, SIGKILL); waitpid(h, NULL, 0);
    double t0 = now(); dm_game_slot_acquire("t_gameslot after a crash");
    CHECK(now() - t0 < 0.2, "a holder killed outright left the slot free (%.3f s)", now() - t0);
    char cmd[1100]; snprintf(cmd, sizeof cmd, "rm -rf '%s'", dir); system(cmd);
    printf("t_gameslot: %d checks, %d failed\n", n, fail); return fail != 0;
}
