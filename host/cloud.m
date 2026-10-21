// iCloud save sync, Apple side (iOS app and the Mac app): finds the iCloud container, has the cloud packs downloaded, then runs the file-level core
// (cloudsync.c) over the game profile's save_sync units.
// Boot: dm_cloud_boot runs on the boot thread before the save is mounted, waits up to 5 s, and swaps newer cloud copies into the local save.
// Running: every successful save commit (hle_fs.c Commit) takes a clonefile snapshot of the committed directory (copy on write, nearly free) under the
// save lock; the upload follows UPLOAD_DELAY seconds later on a serial queue, so a burst of commits costs one upload. Going to the background or
// quitting uploads what is pending at once. Uploads never change the local save (allow_down = 0).
// Only the real save is synced: iOS Documents/save; Mac: the app's own save (app_mac.m sets DM_CLOUD_REAL=1 unless DM_APP_SUPPORT points elsewhere).
// Cloud directory: Documents/saves in the app's iCloud container. No iCloud account / iCloud off for the app: no container, sync skipped, one log line.
// User switch: NSUserDefaults "dm.icloud" (missing = on).
// Test switches:
//   DM_TEST_ICLOUD_OFF=1      no sync at all
//   DM_TEST_ICLOUD_DIR=<dir>  a local directory as the cloud (no iCloud); test saves sync too. A relative path is under Documents (Mac: under the
//                             save's parent directory)
//   DM_TEST_ICLOUD_SUB=<name> the container's Documents/<name> as the cloud, for test saves, kept apart from the real one
//   DM_TEST_ICLOUD_FIRST=<gathered>,<listed>,<present>,<online>  fake the first-sync listing check (first_listing_ok)
// iOS app running on a Mac: the real iCloud is off unless DM_REAL_ICLOUD=1 and DM_REAL_ICLOUD_CONFIRM=write-real-cloud are both set — that Mac is
// one more device of the developer's account, and test runs must not reach the real cloud.
#import <Foundation/Foundation.h>
#include <TargetConditionals.h>
#if TARGET_OS_IPHONE
#import <UIKit/UIKit.h>
#endif
#import <Network/Network.h>
#include <sys/clonefile.h>
#include <stdatomic.h>
#include "cloud.h"
#include "game.h"
#include "hle.h"

extern void (*g_dm_save_commit_hook)(const char *commit_dir);
enum { UPLOAD_DELAY = 30 };

static NSString *g_cloud, *g_save, *g_bak, *g_state;   // cloud directory / local save / backup / state file
static dispatch_queue_t g_q;
static uint64_t now_ms(void) { return (uint64_t)([NSDate date].timeIntervalSince1970 * 1000); }

// Is a cloud pack on this device? A file iCloud has not downloaded is a placeholder: ".<name>.icloud" on older systems, the real name with a
// download status other than "current" on newer ones
static int pack_ready(const char *pack) {
    NSString *nm = @(pack);
    if ([NSFileManager.defaultManager fileExistsAtPath:[g_cloud stringByAppendingPathComponent:[NSString stringWithFormat:@".%@.icloud", nm]]]) return 0;
    NSURL *u = [NSURL fileURLWithPath:[g_cloud stringByAppendingPathComponent:nm]]; NSString *st = nil;
    if (![u getResourceValue:&st forKey:NSURLUbiquitousItemDownloadingStatusKey error:nil] || !st) return 1;   // not managed by iCloud (or no such pack)
    return [st isEqualToString:NSURLUbiquitousItemDownloadingStatusCurrent];
}
static int pending_downloads(int start) {   // packs not downloaded yet; start = 1 also asks the system to download them
    int n = 0; NSFileManager *fm = NSFileManager.defaultManager;
    for (NSString *f in [fm contentsOfDirectoryAtPath:g_cloud error:nil] ?: @[]) {
        NSString *nm = f; if ([f hasPrefix:@"."] && [f hasSuffix:@".icloud"]) nm = [f substringWithRange:NSMakeRange(1, f.length - 8)];
        if (![nm hasSuffix:@".pack"] || pack_ready(nm.UTF8String)) continue;
        n++; if (start) [fm startDownloadingUbiquitousItemAtURL:[NSURL fileURLWithPath:[g_cloud stringByAppendingPathComponent:nm]] error:nil];
    }
    return n;
}
// iCloud's own conflicts (two devices wrote the same pack; the system picked one as current, the others are unresolved conflict versions): the copy
// with the newest pack timestamp (when the game last wrote it) becomes current, all others go to the backup. Only when every copy is backed up are
// the conflicts resolved and the other versions removed; otherwise all stay for the next launch
static void take_conflicts(void) {
    NSFileManager *fm = NSFileManager.defaultManager;
    for (NSString *f in [fm contentsOfDirectoryAtPath:g_cloud error:nil] ?: @[]) {
        if ([f hasPrefix:@"."] || ![f hasSuffix:@".pack"]) continue;
        NSURL *u = [NSURL fileURLWithPath:[g_cloud stringByAppendingPathComponent:f]];
        NSArray<NSFileVersion *> *vs = [NSFileVersion unresolvedConflictVersionsOfItemAtURL:u];
        if (!vs.count) continue;
        uint64_t best = dm_cloud_pack_stamp(u.fileSystemRepresentation); NSFileVersion *win = nil; int bad = 0;
        for (NSFileVersion *v in vs) { uint64_t t = dm_cloud_pack_stamp(v.URL.fileSystemRepresentation); if (t > best) { best = t; win = v; } }
        if (win) {
            NSError *e = nil; bad |= dm_cloud_bak_pack(g_bak.fileSystemRepresentation, u.fileSystemRepresentation, "older current iCloud version") != 0;
            if (!bad && ![win replaceItemAtURL:u options:0 error:&e]) { bad = 1; LOG("[red] iCloud sync: %s: putting the newer conflict version in place failed: %s", f.UTF8String, e.localizedDescription.UTF8String ?: "?"); }
        }
        for (NSFileVersion *v in vs) if (v != win) bad |= dm_cloud_bak_pack(g_bak.fileSystemRepresentation, v.URL.fileSystemRepresentation, "iCloud conflict version") != 0;
        if (bad) { LOG("[red] iCloud sync: %s: %lu conflict versions not backed up, kept for the next launch", f.UTF8String, (unsigned long)vs.count); continue; }
        for (NSFileVersion *v in vs) v.resolved = YES;
        NSError *e = nil;
        if (![NSFileVersion removeOtherVersionsOfItemAtURL:u error:&e]) LOG("iCloud sync: %s: conflicts resolved, removing the other versions failed (%s), harmless", f.UTF8String, e.localizedDescription.UTF8String ?: "?");
        LOG("iCloud sync: %s: %lu iCloud conflict versions handled (newest is current, the rest in the backup)", f.UTF8String, (unsigned long)vs.count);
    }
}
// Under file coordination, so a file the iCloud daemon is writing is never read half written
static int run_sync(NSString *save, int down) {
    __block int r = -1; NSError *err = nil;
    [[[NSFileCoordinator alloc] initWithFilePresenter:nil] coordinateWritingItemAtURL:[NSURL fileURLWithPath:g_cloud] options:NSFileCoordinatorWritingForMerging error:&err byAccessor:^(NSURL *u) {
        (void)u; if (down) take_conflicts();
        r = dm_cloud_sync(save.fileSystemRepresentation, g_cloud.fileSystemRepresentation, g_bak.fileSystemRepresentation, g_state.fileSystemRepresentation,
                          dm_game.save_sync, dm_game.save_sync_n, down, now_ms(), pack_ready); }];
    if (err) LOG("[red] iCloud sync: file coordination failed: %s", err.localizedDescription.UTF8String);
    return r;
}
static int sync_on(void) { id v = [NSUserDefaults.standardUserDefaults objectForKey:@"dm.icloud"]; return !v || [v boolValue]; }

// Commits: the newest snapshot waits in g_pend (touched only on g_q) until the delayed upload, a flush, or a newer commit replaces it. A force quit
// loses only the pending snapshot: the next launch sees the local change and uploads it then
static NSString *g_pend;
static uint64_t g_pend_gen;
static _Atomic int g_bg;   // in the background: commits upload at once
static void upload_snap(NSString *snap, const char *why) {   // on g_q
    if (sync_on()) { int n = run_sync(snap, 0); LOG("iCloud sync: %s: %d uploads", why, n); }
    [NSFileManager.defaultManager removeItemAtPath:snap error:nil];
}
static void take_pending(const char *why) {   // on g_q
    NSString *p = g_pend; g_pend = nil;
    if (p) upload_snap(p, why);
}
static void on_commit(const char *commit_dir) {
    static unsigned seq; NSString *snap = [NSString stringWithFormat:@"%@.cloudsnap%u", g_save, ++seq];
    [NSFileManager.defaultManager removeItemAtPath:snap error:nil];
    if (clonefile(commit_dir, snap.fileSystemRepresentation, 0)) { LOG("[red] iCloud sync: save snapshot failed, errno=%d; this commit is not uploaded", errno); return; }
    int now = atomic_load(&g_bg);
    dispatch_async(g_q, ^{
        if (g_pend) [NSFileManager.defaultManager removeItemAtPath:g_pend error:nil];
        g_pend = snap; uint64_t gen = ++g_pend_gen;
        if (now) { take_pending("commit in the background"); return; }
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)UPLOAD_DELAY * NSEC_PER_SEC), g_q, ^{ if (gen == g_pend_gen) take_pending("commit"); });
    });
}
void dm_cloud_flush(int background) {
    if (!g_q) return;   // sync is off
    if (background) atomic_store(&g_bg, 1);
#if TARGET_OS_IPHONE
    __block UIBackgroundTaskIdentifier tk = UIBackgroundTaskInvalid;
    if (background) tk = [UIApplication.sharedApplication beginBackgroundTaskWithName:@"dm.cloud" expirationHandler:^{
        LOG("[red] iCloud sync: background time ran out (what is left uploads at the next launch)"); [UIApplication.sharedApplication endBackgroundTask:tk]; tk = UIBackgroundTaskInvalid; }];
#endif
    dispatch_async(g_q, ^{
        take_pending(background ? "going to the background" : "flush");
#if TARGET_OS_IPHONE
        if (tk != UIBackgroundTaskInvalid) dispatch_async(dispatch_get_main_queue(), ^{ if (tk != UIBackgroundTaskInvalid) { [UIApplication.sharedApplication endBackgroundTask:tk]; tk = UIBackgroundTaskInvalid; } });
#endif
    });
}
int dm_cloud_flush_wait(double sec) {
    if (!g_q) return 1;
    dispatch_semaphore_t done = dispatch_semaphore_create(0);
    dispatch_async(g_q, ^{ take_pending("quitting"); dispatch_semaphore_signal(done); });
    if (dispatch_semaphore_wait(done, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(sec * NSEC_PER_SEC)))) {
        LOG("[red] iCloud sync: upload not finished %.0f s after quitting (what is left uploads at the next launch)", sec); return 0; }
    return 1;
}
void dm_cloud_foreground(void) { atomic_store(&g_bg, 0); }

// The iCloud container, off the main thread (the first call may wait while the system creates it); nil with a log line when unavailable
static NSURL *container(double limit) {
    __block NSURL *ct = nil; dispatch_semaphore_t got = dispatch_semaphore_create(0);
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{ ct = [NSFileManager.defaultManager URLForUbiquityContainerIdentifier:nil]; dispatch_semaphore_signal(got); });
    if (dispatch_semaphore_wait(got, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(limit * NSEC_PER_SEC)))) { LOG("iCloud unavailable: no container after %.0f s, local save only", limit); return nil; }
    if (!ct) LOG("iCloud unavailable: not signed in, or iCloud is off for this app; local save only");
    return ct;
}
static NSString *test_path(const char *e) {   // test switch paths: relative ones are under Documents (Mac: under the save's parent directory)
    if (!e) return nil;
    if (e[0] == '/') return @(e);
#if TARGET_OS_OSX
    return [@(getenv("DM_SAVE") ?: ".").stringByDeletingLastPathComponent stringByAppendingPathComponent:@(e)];
#else
    return [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject stringByAppendingPathComponent:@(e)];
#endif
}
// A device that never synced looks at the cloud listing first: offline on its first launch, the system has not listed the cloud entries yet, the
// cloud directory looks empty, and a plain sync would upload every local unit over the cloud's. So with an empty state file, ask the system for
// its cloud listing (NSMetadataQuery, counted once gathering finished): packs listed → sync only when all of them are on this device (downloaded or
// placeholders); nothing listed → sync only when the network is up (the very first device). Otherwise skip until the next launch.
static int never_synced(NSString *statef) {
    NSString *t = [NSString stringWithContentsOfFile:statef encoding:NSUTF8StringEncoding error:nil];
    return !t || [t rangeOfString:@"\t"].location == NSNotFound;
}
static int first_listing_ok(double deadline) {
    int got = 0, listed = 0, present = 0, net = 0; const char *e = getenv("DM_TEST_ICLOUD_FIRST");
    if (e) sscanf(e, "%d,%d,%d,%d", &got, &listed, &present, &net);
    else {
        __block int g = 0, n = 0, pr = 0; dispatch_semaphore_t sem = dispatch_semaphore_create(0); __block NSMetadataQuery *q = nil; __block id obs = nil;
        dispatch_async(dispatch_get_main_queue(), ^{   // a metadata query needs a thread with a run loop
            q = [NSMetadataQuery new]; q.searchScopes = @[NSMetadataQueryUbiquitousDocumentsScope];
            q.predicate = [NSPredicate predicateWithFormat:@"%K LIKE '*.pack'", NSMetadataItemFSNameKey];
            obs = [NSNotificationCenter.defaultCenter addObserverForName:NSMetadataQueryDidFinishGatheringNotification object:q queue:nil usingBlock:^(NSNotification *note) { (void)note;
                [q disableUpdates]; n = (int)q.resultCount; NSFileManager *fm = NSFileManager.defaultManager;
                for (NSUInteger i = 0; i < q.resultCount; i++) {
                    NSURL *u = [[q resultAtIndex:i] valueForAttribute:NSMetadataItemURLKey]; if (!u) continue;
                    NSString *ph = [u.path.stringByDeletingLastPathComponent stringByAppendingPathComponent:[NSString stringWithFormat:@".%@.icloud", u.lastPathComponent]];
                    if ([fm fileExistsAtPath:u.path] || [fm fileExistsAtPath:ph]) pr++;
                }
                g = 1; [q stopQuery]; [NSNotificationCenter.defaultCenter removeObserver:obs]; dispatch_semaphore_signal(sem); }];
            if (![q startQuery]) { [NSNotificationCenter.defaultCenter removeObserver:obs]; dispatch_semaphore_signal(sem); } });
        double left = deadline - CFAbsoluteTimeGetCurrent(); if (left < 0.5) left = 0.5;
        if (dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(left * NSEC_PER_SEC))))
            dispatch_async(dispatch_get_main_queue(), ^{ if (q) { [q stopQuery]; if (obs) [NSNotificationCenter.defaultCenter removeObserver:obs]; } });
        got = g; listed = n; present = pr;
        __block int ns = 0; dispatch_semaphore_t ps = dispatch_semaphore_create(0); nw_path_monitor_t m = nw_path_monitor_create();
        nw_path_monitor_set_queue(m, dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0));
        nw_path_monitor_set_update_handler(m, ^(nw_path_t path) { if (!ns) { ns = nw_path_get_status(path) == nw_path_status_satisfied ? 1 : 2; dispatch_semaphore_signal(ps); } });
        nw_path_monitor_start(m); dispatch_semaphore_wait(ps, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(NSEC_PER_SEC))); nw_path_monitor_cancel(m); net = ns == 1;
    }
    int ok = got && (listed ? present >= listed : net);
    LOG("iCloud sync: never synced on this device; cloud listing %s, %d packs listed, %d on this device, network %s → %s", got ? "gathered" : "not gathered",
        listed, present, net ? "up" : "down", ok ? "sync" : "skip until the next launch");
    return ok;
}
void dm_cloud_boot(void) {
    const char *sv = getenv("DM_SAVE"), *sub = getenv("DM_TEST_ICLOUD_SUB"), *ldir = getenv("DM_TEST_ICLOUD_DIR");
    if (!sv) return;
    if (!dm_game.save_sync_n) { LOG("iCloud sync: the game profile lists no save_sync units, off"); return; }
    NSString *save = @(sv);
#if TARGET_OS_OSX
    int real = getenv("DM_CLOUD_REAL") != NULL;
#else
    NSString *doc = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
    int real = [save.stringByStandardizingPath isEqualToString:[doc stringByAppendingPathComponent:@"save"].stringByStandardizingPath];
#endif
    if (getenv("DM_TEST_ICLOUD_OFF")) { LOG("iCloud sync: DM_TEST_ICLOUD_OFF, off for this run"); return; }
    if (!real && !sub && !ldir) { LOG("iCloud sync: test save directory, off for this run"); return; }
    if (NSProcessInfo.processInfo.isiOSAppOnMac && !ldir) {
        const char *r1 = getenv("DM_REAL_ICLOUD"), *r2 = getenv("DM_REAL_ICLOUD_CONFIRM");
        if (!(r1 && !strcmp(r1, "1") && r2 && !strcmp(r2, "write-real-cloud"))) { LOG("iCloud sync: iOS app on a Mac, off by default"); return; }
        LOG("[red] iCloud sync: iOS app on a Mac with DM_REAL_ICLOUD: this run uses the real cloud");
    }
    if (!sync_on()) { LOG("iCloud sync: turned off by the user (dm.icloud)"); return; }
    double t0 = CFAbsoluteTimeGetCurrent(), limit = 5.0;
    if (ldir) g_cloud = test_path(ldir);
    else {
        NSURL *ct = container(limit); if (!ct) return;
        NSString *docs = [ct.path stringByAppendingPathComponent:@"Documents"];
        g_cloud = [docs stringByAppendingPathComponent:sub ? @(sub) : @"saves"];
        if (!sub && never_synced([save stringByAppendingString:@".cloudstate"]) && !first_listing_ok(t0 + limit)) return;
    }
    [NSFileManager.defaultManager createDirectoryAtPath:g_cloud withIntermediateDirectories:YES attributes:nil error:nil];
    g_save = save; g_bak = [save stringByAppendingString:@".cloudbak"]; g_state = [save stringByAppendingString:@".cloudstate"];
    // A local test cloud keeps its own state and backup: sharing the real save's would let test runs rewrite the real sync state
    if (ldir) { g_bak = [g_cloud stringByAppendingString:@".cloudbak"]; g_state = [g_cloud stringByAppendingString:@".cloudstate"]; }
    g_q = dispatch_queue_create("dm.cloud", DISPATCH_QUEUE_SERIAL);
    NSString *parent = save.stringByDeletingLastPathComponent, *snappre = [save.lastPathComponent stringByAppendingString:@".cloudsnap"];
    for (NSString *f in [NSFileManager.defaultManager contentsOfDirectoryAtPath:parent error:nil] ?: @[])   // snapshots left by a killed run
        if ([f hasPrefix:snappre]) [NSFileManager.defaultManager removeItemAtPath:[parent stringByAppendingPathComponent:f] error:nil];
    double t1 = CFAbsoluteTimeGetCurrent(); int pend = pending_downloads(1);
    while (pend && CFAbsoluteTimeGetCurrent() - t0 < limit) { usleep(100000); pend = pending_downloads(0); }
    double t2 = CFAbsoluteTimeGetCurrent(); int n = run_sync(save, 1);
    LOG("iCloud sync: boot %.0f ms (container %.0f ms, downloads %.0f ms, sync %.0f ms), %d actions%s, cloud %s", (CFAbsoluteTimeGetCurrent() - t0) * 1000,
        (t1 - t0) * 1000, (t2 - t1) * 1000, (CFAbsoluteTimeGetCurrent() - t2) * 1000, n,
        pend ? [NSString stringWithFormat:@", %d packs still downloading (skipped)", pend].UTF8String : "", ldir ? "local test directory" : sub ? sub : "saves");
    g_dm_save_commit_hook = on_commit;
}
