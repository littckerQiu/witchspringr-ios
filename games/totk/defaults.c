// Tears of the Kingdom's defaults on the Mac: the TBDR rewrites off (DM_NVN_TBDR=1 turns them on). They save tile loads and stores, which matter on
// the phones' memory bandwidth; on an M5 the dive from the Great Sky Island measured GPU p50 8-10 % lower without them at the same submission time
// (2026-10-19: 3.9 / 6.4 / 4.7 / 6.0 ms against 4.3 / 7.0 / 5.3 / 6.8 at frames 1500 / 1800 / 2100 / 2400), and mid-submission commits only work
// without them. Set before main, ahead of the graphics layer's first look at it.
// The RomFS overlay games/totk/romfs_overlay.py writes (quick-menu backgrounds and the game over flow at 60 fps and up) is served first when it exists
// and DM_ROMFS_OVERLAY does not name another
#include <stdlib.h>
#include <sys/stat.h>
#include <TargetConditionals.h>
#include "game.h"

__attribute__((constructor)) static void totk_defaults(void) {
#if TARGET_OS_OSX
    setenv("DM_NVN_TBDR", "0", 0);   // 0: an explicit setting wins
#endif
    char buf[1024]; struct stat st;
    if (!getenv("DM_ROMFS_OVERLAY") && !stat(dm_game_ws_path("build/totk/romfs_overlay", buf, sizeof buf), &st) && S_ISDIR(st.st_mode)) setenv("DM_ROMFS_OVERLAY", buf, 0);
}
