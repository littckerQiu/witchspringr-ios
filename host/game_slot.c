// One game at a time on this Mac (after MacNativeGames' game_slot.c, MIT): two games need about twice the memory and share one GPU, so neither's
// frame times mean anything, and there exhausted memory made the GPU driver panic the kernel four times. Agents' test runs and the player's own
// launches both start games, so the rule is kept here, once per host start. The holder keeps an exclusive flock(2) on <slot dir>/lock for the life
// of its process (the kernel drops it when the process exits or crashes, so a dead holder blocks nobody) and writes <slot dir>/holder (pid, owner,
// command). A start for the player (the .app, or DM_SLOT_OWNER=user) stops an agent's run that holds the slot with SIGTERM and takes it; any other
// start waits for the slot. The slot directory is DM_SLOT_DIR, else ~/Library/Caches/dm-game-slot (shared by every checkout); DM_SLOT=0 skips it.
// The iOS app has the device to itself: nothing to do there. Checked by host/tests/t_gameslot.c
#include <TargetConditionals.h>
#include <stddef.h>
#if TARGET_OS_IPHONE
int dm_game_slot_acquire(const char *what) { (void)what; return 0; }
#else
#include "dm.h"
#include <errno.h>
#include <fcntl.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/file.h>
#include <sys/stat.h>
#include <unistd.h>
static int g_slot_fd = -1;   // held open for the life of the process
int dm_game_slot_acquire(const char *what) {
    const char *e = getenv("DM_SLOT"); if (e && !strcmp(e, "0")) return 0;
    char dir[1024], lock[1100], holder[1100];
    const char *d = getenv("DM_SLOT_DIR"), *home = getenv("HOME");
    if (d && *d) snprintf(dir, sizeof dir, "%s", d); else snprintf(dir, sizeof dir, "%s/Library/Caches/dm-game-slot", home ? home : "/tmp");
    mkdir(dir, 0755);
    snprintf(lock, sizeof lock, "%s/lock", dir); snprintf(holder, sizeof holder, "%s/holder", dir);
    int fd = open(lock, O_RDWR | O_CREAT | O_CLOEXEC, 0644);
    if (fd < 0) { LOG("[red] game slot: cannot open %s: %s (running without it)", lock, strerror(errno)); return -1; }
    const char *ow = getenv("DM_SLOT_OWNER"); int user = (ow && !strcmp(ow, "user")) || getenv("DM_APP");
    if (flock(fd, LOCK_EX | LOCK_NB)) {
        char info[512] = ""; FILE *f = fopen(holder, "r"); if (f) { size_t n = fread(info, 1, sizeof info - 1, f); info[n] = 0; fclose(f); }
        for (char *c = info; *c; c++) if (*c == '\n') *c = ' ';
        int hpid = 0; const char *p = strstr(info, "pid="); if (p) hpid = atoi(p + 4);
        int huser = strstr(info, "owner=user") != NULL;
        if (user && !huser && hpid > 1) { LOG("game slot: a run for the player takes the slot: stopping the holder (%s) with SIGTERM", info); kill(hpid, SIGTERM); }
        else LOG("game slot: another game holds the slot (%s); waiting for it to exit (DM_SLOT=0 skips the slot)", info[0] ? info : "no holder file");
        if (flock(fd, LOCK_EX)) { LOG("[red] game slot: flock failed: %s (running without it)", strerror(errno)); close(fd); return -1; }
        LOG("game slot: free now, taken");
    }
    FILE *f = fopen(holder, "w");
    if (f) { fprintf(f, "pid=%d owner=%s what=%s\n", (int)getpid(), user ? "user" : "agent", what ? what : "?"); fclose(f); }
    g_slot_fd = fd;
    return 1;
}
#endif
