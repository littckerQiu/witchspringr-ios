// Mac front end. With DM_WINDOW=1: a window (CAMetalLayer for the graphics backend) with keyboard, mouse and gamepad input; the guest runs on a
// large-stack thread and the main thread belongs to AppKit. Without DM_WINDOW the guest runs on the current thread (windowless runs and tests).
// Keys (Nintendo layout): WASD left stick, arrow keys D-pad, J=A K=B U=X I=Y, Q=L E=R, Z=ZL C=ZR, F / G = press left / right stick, Return or = : +,
// Tab : −, Space : A. Mouse: left button = a finger on the touchscreen, right button = B, wheel = right stick up / down.
#import <Cocoa/Cocoa.h>
#include <sys/sysctl.h>
#import <QuartzCore/QuartzCore.h>
#import <Metal/Metal.h>
#import <ImageIO/ImageIO.h>
#include "cloud.h"
#include "dm.h"
#include "dm_input.h"
#include "front.h"
#include "game.h"
#include "hle.h"
#include <signal.h>

static CAMetalLayer *g_layer;
static NSWindow *g_win;
static NSView *g_view;
static double g_aspect = 16.0 / 9;   // game picture aspect ratio, from the profile's screen size

// Where the game picture sits in the view: fitted by its aspect ratio (the whole view when they match, black bars otherwise)
static NSRect game_rect(void) {
    NSSize b = g_view.bounds.size; CGFloat w = b.width, h = b.height;
    if (fabs(w / h / g_aspect - 1) < 0.003) { }   // within 0.3% (window height rounding): fill
    else if (w > h * g_aspect) w = round(h * g_aspect); else h = round(w / g_aspect);
    return NSMakeRect(floor((b.width - w) / 2), floor((b.height - h) / 2), w, h);
}
static void layout_game(void) {
    NSRect r = game_rect(); if (NSEqualRects(r, g_layer.frame)) return;
    CGFloat sc = g_view.window.backingScaleFactor ?: 2;   // a sublayer's drawableSize does not follow its frame by itself
    [CATransaction begin]; [CATransaction setDisableActions:YES]; g_layer.frame = r; g_layer.contentsScale = sc; g_layer.drawableSize = CGSizeMake(round(r.size.width * sc), round(r.size.height * sc)); [CATransaction commit];
    LOG("window: content %.0fx%.0f, game picture %.0fx%.0f at (%.0f,%.0f)", g_view.bounds.size.width, g_view.bounds.size.height, r.size.width, r.size.height, r.origin.x, r.origin.y);
}
// Quit (window close / Cmd-Q / menu): upload the saves to iCloud if sync is on, then shut down in order
static void app_quit(const char *why) {
    static int once; if (once++) return;
    { uint64_t dm_audio_render_calls(void); LOG("window: quit (%s); audio callbacks so far %llu", why, (unsigned long long)dm_audio_render_calls()); }
    dm_cloud_flush_wait(10);   // returns at once when sync is off
    dm_host_shutdown(why);
}
static void show_keys(void) {
    NSAlert *a = [NSAlert new]; a.messageText = @"Controls";
    a.informativeText = @"Mouse: left button = touch, right button = B, wheel = scroll (right stick)\n"
                         "WASD = left stick, arrow keys = D-pad\nJ = A, K = B, U = X, I = Y, Space = A\nQ = L, E = R, Z = ZL, C = ZR\n"
                         "F / G = press left / right stick\nReturn or = = +, Tab = −\nA connected game controller works as well.";
    [a addButtonWithTitle:@"OK"]; [a runModal];
}
// Help → Share Log…: zip this run's and the previous run's log (~/Library/Logs/<game>/host.log, host.prev.log) with a version note, ask where to save it
// (Desktop by default) and select it in Finder. Nothing is uploaded; no saves are included; the home directory prefix in the logs becomes ~.
// to non-NULL = test (DM_TEST_SHARELOG): no panel, write to that path. Returns nil on success, otherwise the reason
static NSString *share_logs(NSString *to) {
    NSFileManager *fm = NSFileManager.defaultManager; NSString *home = NSHomeDirectory(), *logd = [[home stringByAppendingPathComponent:@"Library/Logs"] stringByAppendingPathComponent:@(dm_game.id)];
    NSDictionary *inf = NSBundle.mainBundle.infoDictionary; NSString *build = [inf[@"CFBundleVersion"] description] ?: @"0", *ver = [inf[@"CFBundleShortVersionString"] description] ?: @"?";
    NSDateFormatter *df = [NSDateFormatter new]; df.dateFormat = @"yyyyMMdd-HHmm"; NSString *name = [NSString stringWithFormat:@"%s-logs-%@-%@", dm_game.id, build, [df stringFromDate:NSDate.date]];
    NSString *tmp = [NSTemporaryDirectory() stringByAppendingPathComponent:[NSString stringWithFormat:@"dm_share_%d", getpid()]], *dir = [tmp stringByAppendingPathComponent:name];
    [fm removeItemAtPath:tmp error:nil]; if (![fm createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil]) return @"mkdir";
    fflush(stderr);
    NSData *hb = [home dataUsingEncoding:NSUTF8StringEncoding]; NSData *tilde = [@"~" dataUsingEncoding:NSUTF8StringEncoding];
    NSData *(^scrub)(NSData *) = ^NSData *(NSData *d) { if (!d || hb.length < 2) return d; NSMutableData *o = [NSMutableData dataWithCapacity:d.length]; NSRange all = NSMakeRange(0, d.length), r;
        while ((r = [d rangeOfData:hb options:0 range:all]).location != NSNotFound) { [o appendData:[d subdataWithRange:NSMakeRange(all.location, r.location - all.location)]]; [o appendData:tilde]; all = NSMakeRange(NSMaxRange(r), d.length - NSMaxRange(r)); }
        [o appendData:[d subdataWithRange:all]]; return o; };
    int n = 0; for (NSString *f in @[@"host.log", @"host.prev.log"]) { NSData *d = [NSData dataWithContentsOfFile:[logd stringByAppendingPathComponent:f] options:NSDataReadingMappedIfSafe error:nil]; if (d) { [scrub(d) writeToFile:[dir stringByAppendingPathComponent:f] atomically:YES]; n++; } }
    NSString *bt = [NSString stringWithContentsOfFile:[NSBundle.mainBundle.resourcePath stringByAppendingPathComponent:@"build.txt"] encoding:NSUTF8StringEncoding error:nil] ?: @"";
    char hw[64] = "?"; size_t hn = sizeof hw; sysctlbyname("hw.model", hw, &hn, NULL, 0); NSProcessInfo *pi = NSProcessInfo.processInfo;
    NSString *info = [NSString stringWithFormat:@"%@ %@ (macOS) %@ (%@)\n%@\n%@\nmacOS %@\n%@  %.0f GB\n%@\n", @(dm_game.title), @(dm_game.version), ver, build, inf[@"CFBundleIdentifier"] ?: @"",
        [bt stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet], pi.operatingSystemVersionString, @(hw), pi.physicalMemory / 1073741824.0,
        [NSLocale.preferredLanguages componentsJoinedByString:@","]];
    [[scrub([info dataUsingEncoding:NSUTF8StringEncoding]) copy] writeToFile:[dir stringByAppendingPathComponent:@"info.txt"] atomically:YES];
    NSString *zip = [tmp stringByAppendingPathComponent:[name stringByAppendingString:@".zip"]];
    NSTask *t = [NSTask new]; t.executableURL = [NSURL fileURLWithPath:@"/usr/bin/ditto"]; t.arguments = @[@"-c", @"-k", @"--keepParent", dir, zip]; NSError *err = nil;
    if (![t launchAndReturnError:&err]) { [fm removeItemAtPath:tmp error:nil]; return err.localizedDescription ?: @"ditto"; } [t waitUntilExit];
    if (t.terminationStatus != 0 || ![fm fileExistsAtPath:zip]) { [fm removeItemAtPath:tmp error:nil]; return [NSString stringWithFormat:@"ditto %d", t.terminationStatus]; }
    NSURL *dst = to ? [NSURL fileURLWithPath:to] : nil;
    if (!dst) { NSSavePanel *sp = [NSSavePanel savePanel]; sp.nameFieldStringValue = zip.lastPathComponent; sp.directoryURL = [fm URLsForDirectory:NSDesktopDirectory inDomains:NSUserDomainMask].firstObject; sp.canCreateDirectories = YES;
        if ([sp runModal] != NSModalResponseOK) { [fm removeItemAtPath:tmp error:nil]; LOG("share log: cancelled"); return nil; } dst = sp.URL; }
    [fm removeItemAtURL:dst error:nil]; BOOL ok = [fm moveItemAtPath:zip toPath:dst.path error:&err]; [fm removeItemAtPath:tmp error:nil];
    if (!ok) return err.localizedDescription ?: @"move";
    LOG("share log: saved (%d logs + version note, %llu bytes)", n, [[fm attributesOfItemAtPath:dst.path error:nil] fileSize]);
    if (!to) [NSWorkspace.sharedWorkspace activateFileViewerSelectingURLs:@[dst]];
    return nil;
}
static void share_logs_ui(void) {
    NSString *e = share_logs(nil); if (!e) return;
    LOG("[red] share log: packing failed: %s", e.UTF8String);
    NSAlert *a = [NSAlert new]; a.messageText = @"Could not pack the logs"; a.informativeText = e; [a addButtonWithTitle:@"OK"]; [a runModal];
}
@interface DmWinCtl : NSObject <NSWindowDelegate> @end
@implementation DmWinCtl
- (BOOL)windowShouldClose:(NSWindow *)w { (void)w; app_quit("window closed"); return NO; }
- (void)windowDidResize:(NSNotification *)n { (void)n; layout_game(); }
- (void)windowDidChangeBackingProperties:(NSNotification *)n { (void)n; layout_game(); }
- (void)quit:(id)s { (void)s; app_quit("menu quit"); }
- (void)keys:(id)s { (void)s; show_keys(); }
- (void)share:(id)s { (void)s; share_logs_ui(); }
@end
static uint64_t g_btn;
static int g_w, g_a, g_s, g_d;
static int g_wheel;   // +1 / −1 = right stick pushed up / down for a moment (lists scroll with the right stick)

void *front_metal_layer(void) { return (__bridge void *)g_layer; }

static void push(void) {
    int32_t lx = (g_d - g_a) * 32767, ly = (g_w - g_s) * 32767;
    dm_input_set(g_btn, lx, ly, 0, g_wheel * 32767);
}
static int key_bit(unsigned short code) {
    switch (code) {
        case 38: return 0;  case 40: return 1;  case 32: return 2;  case 34: return 3;    // J K U I → A B X Y
        case 3: return 4;   case 5: return 5;                                            // F G → press stick
        case 12: return 6;  case 14: return 7;  case 6: return 8;   case 8: return 9;    // Q E Z C → L R ZL ZR
        case 36: return 10; case 24: case 69: return 10; case 48: return 11;             // Return / = / keypad + → +, Tab → −
        case 49: return 0;                                                               // Space → A
        case 123: return 12; case 126: return 13; case 124: return 14; case 125: return 15; // ← ↑ → ↓
    }
    return -1;
}
static void on_key(NSEvent *e, int down) {
    unsigned short c = e.keyCode;
    switch (c) { case 13: g_w = down; break; case 0: g_a = down; break; case 1: g_s = down; break; case 2: g_d = down; break; }
    int b = key_bit(c);
    if (b >= 0) g_btn = down ? (g_btn | 1ull << b) : (g_btn & ~(1ull << b));
    push();
}

typedef struct { void (*fn)(void); } guest_arg;
static void *guest_tramp(void *p) {
    static char alt[65536];   // the signal alternate stack is per thread: crash reports must work on the guest thread too
    stack_t ss = {.ss_sp = alt, .ss_size = sizeof alt}; sigaltstack(&ss, 0);
    ((guest_arg *)p)->fn(); LOG("guest thread ended"); exit(0);
}

// Unattended tests (no one to click): DM_TEST_WINSIZE=WxH sets the content size; DM_TEST_FULLSCREEN_AT=<s>[;<s>...] toggles full screen;
// DM_TEST_PRESENT_SHOT=<s>:<path>[;...] saves the next presented picture as PNG (what is on screen, bars included, nvn_mtl.m mtl_grab_next_present);
// DM_TEST_NSMOUSE=<file> posts real NSEvents, one per line "<s> down|move|up x,y", "<s> dbl x,y", "<s> dragto x,y" (from the last down),
//   "<s> key <keycode>", "<s> type <text>" (x,y = point in the content area, origin top left); DM_TEST_SHARELOG=<path> packs the logs there at 8 s;
// DM_TEST_QUIT_AT=<s> quits.
static NSPoint g_test_last;
static void tests_start(NSWindow *win, NSView *v) {
    const char *e; int w, h;
    if ((e = getenv("DM_TEST_WINSIZE")) && sscanf(e, "%dx%d", &w, &h) == 2) { [win setContentSize:NSMakeSize(w, h)]; layout_game(); }
    if ((e = getenv("DM_TEST_FULLSCREEN_AT"))) for (const char *q = e; q && *q; q = strchr(q, ';') ? strchr(q, ';') + 1 : NULL)
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(atof(q) * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ [win toggleFullScreen:nil]; });
    if ((e = getenv("DM_TEST_PRESENT_SHOT"))) { void mtl_grab_next_present(void (^cb)(CGImageRef img));
        for (NSString *it in [@(e) componentsSeparatedByString:@";"]) { NSRange c = [it rangeOfString:@":"]; if (c.location == NSNotFound) continue;
            double at = [it substringToIndex:c.location].doubleValue; NSString *path = [it substringFromIndex:c.location + 1];
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(at * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                NSSize vb = v.bounds.size; NSRect gr = game_rect();
                mtl_grab_next_present(^(CGImageRef img) { if (!img) { LOG("[red] DM_TEST_PRESENT_SHOT: nothing captured for %s", path.UTF8String); return; }
                    CGImageDestinationRef d = CGImageDestinationCreateWithURL((__bridge CFURLRef)[NSURL fileURLWithPath:path], (__bridge CFStringRef)@"public.png", 1, NULL);
                    if (d) { CGImageDestinationAddImage(d, img, NULL); CGImageDestinationFinalize(d); CFRelease(d); }
                    LOG("DM_TEST_PRESENT_SHOT: %s %zux%zu (content %.0fx%.0f, game picture %.0fx%.0f at (%.0f,%.0f))", path.UTF8String, CGImageGetWidth(img), CGImageGetHeight(img),
                        vb.width, vb.height, gr.size.width, gr.size.height, gr.origin.x, gr.origin.y); }); }); } }
    if ((e = getenv("DM_TEST_NSMOUSE"))) { NSString *txt = [NSString stringWithContentsOfFile:@(e) encoding:NSUTF8StringEncoding error:nil]; NSTimeInterval t0 = NSProcessInfo.processInfo.systemUptime; int n = 0;
        dispatch_queue_t tq = dispatch_queue_create("dm.test.nsevent", DISPATCH_QUEUE_SERIAL);   // not the main queue: a modal dialog runs its loop inside a main-queue block
        for (NSString *ln in [txt componentsSeparatedByString:@"\n"]) { double sec, x = 0, y = 0; char op[8];
            if (sscanf(ln.UTF8String, "%lf %7s %lf,%lf", &sec, op, &x, &y) < 2 || ln.UTF8String[0] == '#') continue; n++;
            if (!strcmp(op, "key") || !strcmp(op, "type")) {   // key <keycode>: press, release 0.08 s later; type <text>: insert text through the responder chain
                int ty = !strcmp(op, "type"); char word[64] = ""; if (ty) sscanf(ln.UTF8String, "%*lf %*7s %63s", word); NSString *chars = ty ? @(word) : (x == 36 ? @"\r" : @"");
                if (ty) {
                    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(sec * NSEC_PER_SEC)), tq, ^{ CFRunLoopPerformBlock(CFRunLoopGetMain(), kCFRunLoopCommonModes, ^{
                        NSWindow *kw = NSApp.keyWindow; BOOL ok = [NSApp sendAction:@selector(insertText:) to:nil from:chars];
                        LOG("DM_TEST_NSMOUSE: %.2f s typed \"%s\" (key window: %s, %s)", NSProcessInfo.processInfo.systemUptime - t0, chars.UTF8String, kw == win ? "game" : kw ? "dialog" : "none", ok ? "received" : "not received"); });
                        CFRunLoopWakeUp(CFRunLoopGetMain()); });
                    continue; }
                for (int dn = 1; dn >= 0; dn--) dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)((sec + (dn ? 0 : 0.08)) * NSEC_PER_SEC)), tq, ^{ NSWindow *kw = NSApp.keyWindow;
                    if (dn) LOG("DM_TEST_NSMOUSE: %.2f s key code %d (key window: %s)", NSProcessInfo.processInfo.systemUptime - t0, (int)x, kw == win ? "game" : kw ? "other" : "none");
                    [NSApp postEvent:[NSEvent keyEventWithType:dn ? NSEventTypeKeyDown : NSEventTypeKeyUp location:NSZeroPoint modifierFlags:0 timestamp:NSProcessInfo.processInfo.systemUptime windowNumber:(kw ?: win).windowNumber context:nil characters:chars charactersIgnoringModifiers:chars isARepeat:NO keyCode:(unsigned short)x] atStart:NO]; });
                continue; }
            if (!strcmp(op, "dbl") || !strcmp(op, "dragto")) {   // dbl: two clicks 0.15 s apart; dragto: drag from the last down point in 12 steps over 0.6 s, then release
                int dbl = !strcmp(op, "dbl");
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(sec * NSEC_PER_SEC)), tq, ^{ __block NSPoint from, to; dispatch_sync(dispatch_get_main_queue(), ^{ from = g_test_last; to = NSMakePoint(x, v.bounds.size.height - y); if (dbl) from = to; g_test_last = to; });
                    NSEvent *(^mk)(NSEventType, NSPoint, int) = ^(NSEventType t, NSPoint p, int cc) { __block NSPoint wp; dispatch_sync(dispatch_get_main_queue(), ^{ wp = [v convertPoint:p toView:nil]; });
                        return [NSEvent mouseEventWithType:t location:wp modifierFlags:0 timestamp:NSProcessInfo.processInfo.systemUptime windowNumber:win.windowNumber context:nil eventNumber:0 clickCount:cc pressure:t == NSEventTypeLeftMouseUp ? 0 : 1]; };
                    LOG("DM_TEST_NSMOUSE: %.2f s %s (%.0f,%.0f)", NSProcessInfo.processInfo.systemUptime - t0, dbl ? "double click" : "drag to", x, y);
                    if (dbl) { for (int i = 0; i < 2; i++) { [NSApp postEvent:mk(NSEventTypeLeftMouseDown, to, i + 1) atStart:NO]; usleep(60000); [NSApp postEvent:mk(NSEventTypeLeftMouseUp, to, i + 1) atStart:NO]; usleep(150000); } }
                    else { for (int i = 1; i <= 12; i++) { [NSApp postEvent:mk(NSEventTypeLeftMouseDragged, NSMakePoint(from.x + (to.x - from.x) * i / 12, from.y + (to.y - from.y) * i / 12), 1) atStart:NO]; usleep(50000); } usleep(200000); [NSApp postEvent:mk(NSEventTypeLeftMouseUp, to, 1) atStart:NO]; } });
                continue; }
            NSEventType ty = !strcmp(op, "down") ? NSEventTypeLeftMouseDown : !strcmp(op, "up") ? NSEventTypeLeftMouseUp : NSEventTypeLeftMouseDragged; int has = !strcmp(op, "up") ? 0 : 1;
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(sec * NSEC_PER_SEC)), tq, ^{ static NSPoint last;
                if (has) { last = NSMakePoint(x, v.bounds.size.height - y); g_test_last = last; }   // content point → window coordinates (origin bottom left)
                NSEvent *ev = [NSEvent mouseEventWithType:ty location:[v convertPoint:last toView:nil] modifierFlags:0 timestamp:NSProcessInfo.processInfo.systemUptime windowNumber:win.windowNumber context:nil eventNumber:0 clickCount:1 pressure:ty == NSEventTypeLeftMouseUp ? 0 : 1];
                LOG("DM_TEST_NSMOUSE: %.2f s %s (%.0f,%.0f)", NSProcessInfo.processInfo.systemUptime - t0, ty == NSEventTypeLeftMouseDown ? "down" : ty == NSEventTypeLeftMouseUp ? "up" : "drag", last.x, v.bounds.size.height - last.y);
                [NSApp postEvent:ev atStart:NO]; }); }
        LOG("DM_TEST_NSMOUSE: %d events queued", n); }
    if ((e = getenv("DM_TEST_SHARELOG"))) { NSString *to = @(e); dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(8 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        NSString *er = share_logs(to); LOG("DM_TEST_SHARELOG: packed to %s at 8 s -> %s", to.lastPathComponent.UTF8String, er ? er.UTF8String : "OK"); }); }
    if ((e = getenv("DM_TEST_QUIT_AT"))) dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(atof(e) * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ app_quit("DM_TEST_QUIT_AT"); });
}

// DM_TEST_BG=<start s>,<duration s>[;...]: the iPhone's "to the background and back" at those times (plan item 51; the order and log lines of
// front_ios.m's front_ios_focus_event, so tools/lifecycle_check.py reads a Mac run and an iPhone's boot.txt alike): resign active, background (focus
// 3, audio paused, guest clock frozen, graphics suspended), back to the foreground, active. On a queue of its own: a windowless run has no main queue
static void test_bg_event(int ev) {
    static const char *k[] = {"sceneWillResignActive", "sceneDidEnterBackground", "sceneWillEnterForeground", "sceneDidBecomeActive"};
    LOG("front: %s (guest clock %.3f s, audio callbacks %llu)", k[ev], guest_ns() / 1e9, (unsigned long long)dm_audio_render_calls());
    switch (ev) {
    case 0: dm_focus_set(2); break;
    case 1: dm_focus_set(3); dm_audio_suspend(1); guest_clock_freeze_for(1, 1); dm_gfx_suspend(1); break;
    case 2: dm_gfx_suspend(0); guest_clock_freeze_for(1, 0); dm_audio_suspend(0); dm_focus_set(2); break;
    case 3: dm_focus_set(1); break;
    }
}
static void test_bg_start(void) {
    const char *tb = getenv("DM_TEST_BG"); double at, dur;
    dispatch_queue_t q = dispatch_queue_create("dm.test_bg", DISPATCH_QUEUE_SERIAL);
    for (const char *tp = tb; tp && sscanf(tp, "%lf,%lf", &at, &dur) == 2; tp = strchr(tp, ';') ? strchr(tp, ';') + 1 : NULL) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(at * 1e9)), q, ^{ LOG("front: DM_TEST_BG enter background"); test_bg_event(0); test_bg_event(1); });
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)((at + dur) * 1e9)), q, ^{ LOG("front: DM_TEST_BG return"); test_bg_event(2); test_bg_event(3); });
    }
}

void front_run(void (*guest)(void)) {
    test_bg_start();
    if (!getenv("DM_WINDOW")) { guest(); return; }
    @autoreleasepool {
        if (dm_game.screen_w > 0 && dm_game.screen_h > 0) g_aspect = (double)dm_game.screen_w / dm_game.screen_h;
        [NSApplication sharedApplication];
        [NSApp setActivationPolicy:NSApplicationActivationPolicyRegular];
        NSRect r = NSMakeRect(0, 0, 1280, floor(1280 / g_aspect));
        NSWindow *win = [[NSWindow alloc] initWithContentRect:r styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable | NSWindowStyleMaskResizable
                                                      backing:NSBackingStoreBuffered defer:NO];
        win.title = @(dm_game.title); win.restorable = NO; g_win = win;
        NSView *v = win.contentView; g_view = v;
        v.wantsLayer = YES; v.layer.backgroundColor = CGColorGetConstantColor(kCGColorBlack);
        win.collectionBehavior = NSWindowCollectionBehaviorFullScreenPrimary; win.contentMinSize = NSMakeSize(640, floor(640 / g_aspect));
        static DmWinCtl *ctl; ctl = [DmWinCtl new]; win.delegate = ctl;
        g_layer = [CAMetalLayer layer];
        g_layer.device = MTLCreateSystemDefaultDevice();
        g_layer.pixelFormat = MTLPixelFormatBGRA8Unorm;
        g_layer.contentsScale = win.backingScaleFactor;
        [v.layer addSublayer:g_layer]; layout_game();
        [win center];
        {   // menu bar: app (Quit Cmd-Q) / View (Full Screen Ctrl-Cmd-F) / Help (controls, share log)
            NSMenu *bar = [NSMenu new];
            NSMenu *(^add)(NSString *) = ^NSMenu *(NSString *t) { NSMenuItem *it = [NSMenuItem new]; [bar addItem:it]; NSMenu *m = [[NSMenu alloc] initWithTitle:t]; it.submenu = m; return m; };
            [[add(@"") addItemWithTitle:[NSString stringWithFormat:@"Quit %@", @(dm_game.title)] action:@selector(quit:) keyEquivalent:@"q"] setTarget:ctl];
            NSMenuItem *fs = [add(@"View") addItemWithTitle:@"Toggle Full Screen" action:@selector(toggleFullScreen:) keyEquivalent:@"f"]; fs.keyEquivalentModifierMask = NSEventModifierFlagControl | NSEventModifierFlagCommand;
            NSMenu *hm = add(@"Help"); [[hm addItemWithTitle:@"Controls" action:@selector(keys:) keyEquivalent:@""] setTarget:ctl]; [[hm addItemWithTitle:@"Share Log…" action:@selector(share:) keyEquivalent:@""] setTarget:ctl];
            NSApp.mainMenu = bar;
        }
        dm_gamepad_start();   // game controllers (ios/Sources/dm_gamepad.m, shared with iOS)
        [win makeKeyAndOrderFront:nil];
        [NSApp activateIgnoringOtherApps:YES];
        [NSEvent addLocalMonitorForEventsMatchingMask:NSEventMaskKeyDown | NSEventMaskKeyUp handler:^NSEvent *(NSEvent *e) {
            if (e.window != win) return e;                                 // other windows (the text input dialog) get their keys
            if (e.modifierFlags & NSEventModifierFlagCommand) return e;    // Cmd shortcuts go to the menu
            if (!e.isARepeat) on_key(e, e.type == NSEventTypeKeyDown);
            return nil;                                                    // swallowed: no system beep
        }];
        // Left button = finger 0 on the touchscreen (front.h dm_touch_set) at the normalized position in the game picture
        [NSEvent addLocalMonitorForEventsMatchingMask:NSEventMaskLeftMouseDown | NSEventMaskLeftMouseDragged | NSEventMaskLeftMouseUp handler:^NSEvent *(NSEvent *e) {
            if (e.window != win) return e;
            if (e.type == NSEventTypeLeftMouseUp) { dm_touch_set(NULL, 0); return nil; }
            NSPoint p = [v convertPoint:e.locationInWindow fromView:nil]; NSRect gr = game_rect();
            if (gr.size.width <= 0 || gr.size.height <= 0) return e;
            float nx = (float)((p.x - gr.origin.x) / gr.size.width), ny = (float)(1.0 - (p.y - gr.origin.y) / gr.size.height);   // AppKit origin bottom left, touch origin top left
            if (e.type == NSEventTypeLeftMouseDown && (nx < 0 || nx > 1 || ny < 0 || ny > 1)) return nil;   // on the black bars: not a touch
            dm_touch t = {0, nx < 0 ? 0 : nx > 1 ? 1 : nx, ny < 0 ? 0 : ny > 1 ? 1 : ny};
            dm_touch_set(&t, 1); return nil;
        }];
        [NSEvent addLocalMonitorForEventsMatchingMask:NSEventMaskRightMouseDown | NSEventMaskRightMouseUp handler:^NSEvent *(NSEvent *e) {
            if (e.window != win) return e;
            if (e.type == NSEventTypeRightMouseDown) g_btn |= DM_BTN_B; else g_btn &= ~(uint64_t)DM_BTN_B;
            push(); return nil;
        }];
        [NSEvent addLocalMonitorForEventsMatchingMask:NSEventMaskScrollWheel handler:^NSEvent *(NSEvent *e) {
            if (e.window != win || e.scrollingDeltaY == 0) return e;
            static int gen; int my = ++gen; g_wheel = e.scrollingDeltaY > 0 ? 1 : -1; push();
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.12 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ if (my == gen) { g_wheel = 0; push(); } });
            return nil;
        }];
        if (getenv("DM_APP") && !getenv("DM_APP_ROMFS") && ![NSUserDefaults.standardUserDefaults boolForKey:@"KeysShown"]) { show_keys(); [NSUserDefaults.standardUserDefaults setBool:YES forKey:@"KeysShown"]; }   // once on first launch
        tests_start(win, v);
        // Lifecycle (hle.h): focus lost → 2, regained → 1; minimized → 3 with audio paused and the GPU suspended, restored → resumed
        NSNotificationCenter *nc = NSNotificationCenter.defaultCenter;
        [nc addObserverForName:NSWindowDidResignKeyNotification object:win queue:nil usingBlock:^(NSNotification *n) { (void)n; if (!win.miniaturized && !dm_game.unfocused_in_focus) dm_focus_set(2); g_btn = 0; g_w = g_a = g_s = g_d = 0; push(); dm_gamepad_reset(); }];   // release events of held keys will not arrive
        [nc addObserverForName:NSWindowDidBecomeKeyNotification object:win queue:nil usingBlock:^(NSNotification *n) { (void)n; dm_focus_set(1); }];
        [nc addObserverForName:NSWindowDidMiniaturizeNotification object:win queue:nil usingBlock:^(NSNotification *n) { (void)n; dm_focus_set(3); dm_audio_suspend(1); dm_gfx_suspend(1); }];
        [nc addObserverForName:NSWindowDidDeminiaturizeNotification object:win queue:nil usingBlock:^(NSNotification *n) { (void)n; dm_gfx_suspend(0); dm_audio_suspend(0); dm_focus_set(win.isKeyWindow || dm_game.unfocused_in_focus ? 1 : 2); }];
        // A window wholly covered by others gets no display-link callbacks: its presents would queue and the game wait on them (false stall lines on a
        // test Mac whose game window another window covered; upstream d2r-mobile afad65c). While the occlusion state lacks Visible, presents are dropped
        // (mtl_present_discard, as in the iOS background save wait); game logic, audio and focus go on. DM_OCCL=0 turns it off. DM_TEST_COVER=<s>,<len>
        // covers the game window with an opaque window at s seconds for len seconds (a check, not for play)
        { const char *e = getenv("DM_OCCL"); int on = !(e && !strcmp(e, "0"));
          [nc addObserverForName:NSWindowDidChangeOcclusionStateNotification object:win queue:nil usingBlock:^(NSNotification *n) { (void)n;
              int hidden = !(win.occlusionState & NSWindowOcclusionStateVisible); void mtl_present_discard(int on);
              LOG("window: %s (covered-window handling %s)", hidden ? "wholly covered / not visible" : "visible again", on ? "on" : "off, DM_OCCL=0");
              if (on) mtl_present_discard(hidden); }];
          double at = 0, dur = 0;
          if ((e = getenv("DM_TEST_COVER")) && sscanf(e, "%lf,%lf", &at, &dur) == 2 && at > 0 && dur > 0)
              dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(at * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                  NSWindow *c = [[NSWindow alloc] initWithContentRect:NSInsetRect(win.frame, -40, -40) styleMask:NSWindowStyleMaskBorderless backing:NSBackingStoreBuffered defer:NO];
                  c.opaque = YES; c.backgroundColor = NSColor.grayColor; c.releasedWhenClosed = NO; [c orderFrontRegardless];
                  LOG("DM_TEST_COVER: covered for %.1f s", dur);
                  dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(dur * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ [c orderOut:nil]; LOG("DM_TEST_COVER: uncovered"); });
              }); }
        // Guest thread: 64 MiB stack (the console main thread stack comes from the npdm; the host gives plenty)
        static guest_arg ga; ga.fn = guest;
        pthread_attr_t a; pthread_attr_init(&a); pthread_attr_setstacksize(&a, 64u << 20);
        pthread_t th; if (pthread_create(&th, &a, guest_tramp, &ga)) die("pthread_create guest");
        [NSApp run];
    }
}

// Software keyboard (front.h): the main thread shows an NSAlert with a text field, the guest thread waits for it. Windowless: -1 (treated as cancel)
int front_text_input(const char *title, const char *sub, const char *guide, const char *initial, int max_chars, char *out, int out_cap) {
    if (!g_layer) return -1;
    __block int r = 0;
    __block NSString *text = nil;
    dispatch_sync(dispatch_get_main_queue(), ^{
        NSAlert *a = [NSAlert new];
        a.messageText = title && *title ? @(title) : @"Input";
        a.informativeText = [NSString stringWithFormat:@"%@%@%@", sub ? @(sub) : @"", sub && *sub && guide && *guide ? @"\n" : @"", guide ? @(guide) : @""];
        [a addButtonWithTitle:@"OK"]; [a addButtonWithTitle:@"Cancel"];
        NSTextField *f = [[NSTextField alloc] initWithFrame:NSMakeRect(0, 0, 300, 24)];
        f.stringValue = initial ? @(initial) : @"";
        if (guide && *guide) f.placeholderString = @(guide);
        a.accessoryView = f; [a layout]; a.window.initialFirstResponder = f;
        f.target = a.buttons.firstObject; f.action = @selector(performClick:);   // Return in the field = OK
        CFRunLoopPerformBlock(CFRunLoopGetMain(), kCFRunLoopCommonModes, ^{ [a.window makeFirstResponder:f]; });   // initialFirstResponder alone does not focus the field
        r = [a runModal] == NSAlertFirstButtonReturn;
        [g_win makeKeyAndOrderFront:nil];
        text = f.stringValue;
    });
    if (!r) return 0;
    (void)max_chars;   // truncation (in UTF-16 units) happens in hle_swkbd.c
    snprintf(out, out_cap, "%s", text.UTF8String);
    return 1;
}
