// iCloud save sync: cloud.m (iCloud container, Mac and iOS) over the file-level core cloudsync.c.
#pragma once
#include <stdint.h>
// Sync one save directory with one cloud directory (cloudsync.c). pat / npat = the units (the game profile's save_sync globs, relative to save).
// allow_down = 0: upload only. ready(pack file name) = 0: that cloud pack is not downloaded yet, its unit is skipped. now_ms = time for deletion markers.
// Returns the number of actions (uploads + downloads + deletions), -1 = bad arguments
int dm_cloud_sync(const char *save, const char *cloud, const char *bak, const char *statef, const char *const *pat, int npat,
                  int allow_down, uint64_t now_ms, int (*ready)(const char *pack));
uint64_t dm_cloud_pack_stamp(const char *pack);                          // a pack's timestamp, 0 = unreadable
int dm_cloud_bak_pack(const char *bak, const char *pack, const char *why);   // copy a pack's unit into the backup; 0 = done

// cloud.m. Boot: one sync before the save is mounted (DM_SAVE), downloads included. Commits: uploaded shortly after (coalesced).
void dm_cloud_boot(void);
void dm_cloud_flush(int background);    // upload what is pending now; background = 1 also holds a background task on iOS until done
int dm_cloud_flush_wait(double sec);    // the same, waiting up to sec seconds (quitting the Mac app); 1 = done or sync off
void dm_cloud_foreground(void);         // back in the foreground
