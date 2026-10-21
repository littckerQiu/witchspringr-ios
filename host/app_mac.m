// macOS app form (double-clicked .app): when the host is packaged as <name>.app (tools/mac_app.sh), prepare what the command line would set:
//   a window; saves in ~/Library/Application Support/<game id>/save (apart from development workspaces and test saves);
//   the game's RomFS folder chosen by the user on first launch (kept in the preferences; a folder that fails the RomFS check gets a clear error and
//   another try); the rewritten program files (product) inside Contents/Resources/product; the log in ~/Library/Logs/<game id>/host.log.
// Command line starts (with arguments, or not inside an .app) are left exactly as they are.
#import <Cocoa/Cocoa.h>
#include <sys/stat.h>
#include "hle.h"
#include "game.h"
#include "romfs_validate.h"

static NSString *const kRomfsKey = @"RomfsDir";

// The RomFS root inside a chosen folder: the folder itself or its RomFS / romfs subfolder, checked against the game profile (romfs_validate.c)
static NSString *romfs_root(NSString *dir, NSString **why) {
    char w[512] = "";
    for (NSString *sub in @[@"", @"RomFS", @"romfs"]) {
        NSString *d = sub.length ? [dir stringByAppendingPathComponent:sub] : dir;
        if (dm_romfs_validate(d.fileSystemRepresentation, w, sizeof w)) return d;
    }
    if (why) *why = [NSString stringWithFormat:@"\"%@\" is not the RomFS of %@ %@: %@", dir.lastPathComponent, @(dm_game.title), @(dm_game.version), @(w)];
    return nil;
}
static void alert(NSString *title, NSString *text) {
    NSAlert *a = [NSAlert new]; a.messageText = title; a.informativeText = text; [a addButtonWithTitle:@"OK"]; [a runModal];
}
// Ask for the RomFS folder until a valid one is chosen; nil when cancelled
static NSString *pick_romfs(NSString *first_why) {
    NSString *why = first_why;
    for (;;) {
        NSOpenPanel *p = [NSOpenPanel openPanel];
        p.canChooseDirectories = YES; p.canChooseFiles = NO; p.allowsMultipleSelection = NO; p.prompt = @"Use";
        p.message = why ? [NSString stringWithFormat:@"%@\nChoose the RomFS folder again.", why] : [NSString stringWithFormat:@"Choose the RomFS folder of %@ %@.", @(dm_game.title), @(dm_game.version)];
        if ([p runModal] != NSModalResponseOK) return nil;
        NSString *w = nil, *r = romfs_root(p.URL.path, &w);
        if (r) return r;
        alert(@"Not a RomFS folder", w); why = w;
    }
}
// An item of the package (product / msl): Contents/Resources/<name> if present, otherwise the "name=local path" line of Resources/paths.txt
// (mac_app.sh can leave out content derived from the game and point at what this machine built)
static NSString *res_item(NSString *name) {
    NSFileManager *fm = NSFileManager.defaultManager; NSString *rp = NSBundle.mainBundle.resourcePath, *d = [rp stringByAppendingPathComponent:name];
    if ([fm fileExistsAtPath:d]) return d;
    NSString *txt = [NSString stringWithContentsOfFile:[rp stringByAppendingPathComponent:@"paths.txt"] encoding:NSUTF8StringEncoding error:nil];
    for (NSString *ln in [txt componentsSeparatedByString:@"\n"]) { NSString *pre = [name stringByAppendingString:@"="]; if ([ln hasPrefix:pre]) { d = [ln substringFromIndex:pre.length]; return [fm fileExistsAtPath:d] ? d : nil; } }
    return nil;
}
// Called first thing in main(). As an .app it prepares the environment and arguments and returns 1; otherwise returns 0 and changes nothing
int dm_app_bootstrap(int *argc, char ***argv) {
    @autoreleasepool {
        NSString *bp = NSBundle.mainBundle.bundlePath;
        if (*argc > 1 || ![bp.pathExtension isEqualToString:@"app"]) return 0;
        NSFileManager *fm = NSFileManager.defaultManager;
#ifdef DM_NVN_M3
        NSString *app = [NSString stringWithFormat:@"%s-m3", dm_game.id];   // the older-API build keeps its own saves and logs
#else
        NSString *app = @(dm_game.id);
#endif
        NSString *sup = [NSSearchPathForDirectoriesInDomains(NSApplicationSupportDirectory, NSUserDomainMask, YES).firstObject stringByAppendingPathComponent:app];
        if (getenv("DM_APP_SUPPORT")) sup = @(getenv("DM_APP_SUPPORT"));   // test: saves etc. in a given directory, leaving the user's own alone
        NSString *logd = [[NSSearchPathForDirectoriesInDomains(NSLibraryDirectory, NSUserDomainMask, YES).firstObject stringByAppendingPathComponent:@"Logs"] stringByAppendingPathComponent:app];
        NSString *save = [sup stringByAppendingPathComponent:@"save"], *temp = [sup stringByAppendingPathComponent:@"temp"];
        for (NSString *d in @[sup, logd, save, temp]) [fm createDirectoryAtPath:d withIntermediateDirectories:YES attributes:nil error:nil];
        // No terminal when double-clicked: the log goes to a file, the previous one is kept
        NSString *lf = [logd stringByAppendingPathComponent:@"host.log"];
        [fm removeItemAtPath:[logd stringByAppendingPathComponent:@"host.prev.log"] error:nil];
        [fm moveItemAtPath:lf toPath:[logd stringByAppendingPathComponent:@"host.prev.log"] error:nil];
        if (!isatty(2)) { freopen(lf.fileSystemRepresentation, "w", stderr); setvbuf(stderr, NULL, _IOLBF, 0); }
        // No system window restoration: after a forced quit it would show a modal "reopen windows?" dialog that blocks input to the game window.
        // Same as launching with -ApplePersistenceIgnoreState YES; must be set before NSApplication exists
        [NSUserDefaults.standardUserDefaults setVolatileDomain:@{ @"ApplePersistenceIgnoreState": @YES } forName:NSArgumentDomain];
        [NSApplication sharedApplication]; [NSApp setActivationPolicy:NSApplicationActivationPolicyRegular]; [NSApp activateIgnoringOtherApps:YES];
        NSString *prod = res_item(@"product");
        if (!prod || ![fm fileExistsAtPath:[prod stringByAppendingPathComponent:@"main.patched.bin"]]) {
            alert(@"The app is incomplete", @"The rewritten program files (product) are missing from the app. Rebuild it with tools/mac_app.sh."); exit(1);
        }
        NSUserDefaults *ud = NSUserDefaults.standardUserDefaults;
        NSString *saved = [ud stringForKey:kRomfsKey], *why = nil, *rom = saved ? romfs_root(saved, &why) : nil;
        if (getenv("DM_APP_ROMFS")) {   // test (nobody to click the dialog): the RomFS folder directly; a wrong one is logged and exits, nothing is stored
            rom = romfs_root(@(getenv("DM_APP_ROMFS")), &why);
            if (!rom) { LOG("[red] app: DM_APP_ROMFS is not a valid RomFS: %s", why.UTF8String); exit(2); }
        } else if (!rom) {
            rom = pick_romfs(saved ? [NSString stringWithFormat:@"The RomFS folder chosen before is no longer valid: %@", why] : nil);
            if (!rom) { LOG("app: no RomFS folder chosen, exiting"); exit(0); }
            [ud setObject:rom forKey:kRomfsKey];
        }
        if (!getenv("DM_APP_SUPPORT")) setenv("DM_CLOUD_REAL", "1", 1);   // iCloud sync (cloud.m) only for the user's real save directory
        setenv("DM_WINDOW", "1", 1); setenv("DM_APP", "1", 1);
        if (!getenv("DM_AUDIO")) setenv("DM_AUDIO", "1", 1);   // the app plays sound (the command line host defaults to a silent sink)
        setenv("DM_SAVE", save.fileSystemRepresentation, 1); setenv("DM_TEMP", temp.fileSystemRepresentation, 1);
        setenv("DM_ROMFS", rom.fileSystemRepresentation, 1); setenv("DM_ROOT", sup.fileSystemRepresentation, 1);
        NSString *rp = NSBundle.mainBundle.resourcePath, *shmap = [rp stringByAppendingPathComponent:@"shader_map.tsv"];   // shader map (c1_full.tsv sits next to it)
        if ([fm fileExistsAtPath:shmap]) setenv("DM_NVN_SHMAP", shmap.fileSystemRepresentation, 1);
        NSString *msl = res_item(@"msl");   // compiled shader library (msl/b-<chain version>/)
        if (msl) setenv("DM_MSL_DIR", msl.fileSystemRepresentation, 1);
        NSString *font = res_item(@"sysfont");   // system shared fonts, if the game uses nn::pl
        if (font) setenv("DM_SYSFONT", font.fileSystemRepresentation, 1);
        // Arguments: product directory + the profile's modules
        static char *av[2 + 8]; int n = 0; av[n++] = (*argv)[0]; av[n++] = strdup(prod.fileSystemRepresentation);
        static char mods[256]; strlcpy(mods, dm_game.modules, sizeof mods);
        for (char *s, *t = strtok_r(mods, " ", &s); t && n < 9; t = strtok_r(NULL, " ", &s)) av[n++] = t;
        av[n] = NULL; *argv = av; *argc = n;
        LOG("app: save %s; RomFS %s; program files %s; log %s", save.UTF8String, rom.UTF8String, prod.UTF8String, lf.UTF8String);
        return 1;
    }
}
