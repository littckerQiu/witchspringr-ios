// On-screen log: the last lines of the app's log drawn over the game while playing. Switched in the Settings app → <this app>:
//   dm.log_overlay       show it (default off)
//   dm.log_overlay_red   only lines with "[red] "
//   dm.log_overlay_lines how many lines (default 14)
// The log itself stays a plain file that stderr writes directly (a crash backtrace must reach it even when no other thread runs again); the overlay
// reads that file through its own descriptor, 4 times a second, only while shown. The view takes no touches: they reach the game underneath.
#import <UIKit/UIKit.h>
#include <fcntl.h>
#include <sys/stat.h>
#include <unistd.h>

int dm_log_fd(void);   // main.m: the log file stderr writes

enum { RING = 64, LINE_MAX_CHARS = 220 };
@interface DmLogOverlay : NSObject
@property (strong) UILabel *label;
@property (strong) NSTimer *timer;
@property (strong) NSMutableArray<NSString *> *ring;
@property (strong) NSMutableData *partial;
@property int fd;
@property off_t off;
@end

static DmLogOverlay *g_ov;

@implementation DmLogOverlay
- (void)settingsChanged {
    NSUserDefaults *d = NSUserDefaults.standardUserDefaults;
    BOOL on = [d boolForKey:@"dm.log_overlay"];
    self.label.hidden = !on;
    if (on && !self.timer) {
        self.timer = [NSTimer scheduledTimerWithTimeInterval:0.25 target:self selector:@selector(tick) userInfo:nil repeats:YES];
        [self tick];
    } else if (!on && self.timer) { [self.timer invalidate]; self.timer = nil; }
}
// The log file is renamed when the session becomes the foreground one (boot.launch.txt → boot.txt); an open descriptor follows the rename
- (void)openLog {
    if (self.fd >= 0) return;
    char path[PATH_MAX]; int lf = dm_log_fd();
    if (lf < 0 || fcntl(lf, F_GETPATH, path) != 0) return;
    self.fd = open(path, O_RDONLY);
    struct stat st; self.off = self.fd >= 0 && !fstat(self.fd, &st) && st.st_size > 16384 ? st.st_size - 16384 : 0;   // start near the end
}
- (void)readNew {
    [self openLog]; if (self.fd < 0) return;
    char buf[16384]; ssize_t n;
    while ((n = pread(self.fd, buf, sizeof buf, self.off)) > 0) {
        self.off += n; [self.partial appendBytes:buf length:(NSUInteger)n];
        const char *p = self.partial.bytes, *end = p + self.partial.length, *s = p;
        for (const char *q = p; q < end; q++) {
            if (*q != '\n') continue;
            NSString *l = [[NSString alloc] initWithBytes:s length:(NSUInteger)(q - s) encoding:NSUTF8StringEncoding];
            if (l.length) {
                if ([l hasPrefix:@"[dm] "]) l = [l substringFromIndex:5];
                if (l.length > LINE_MAX_CHARS) l = [[l substringToIndex:LINE_MAX_CHARS] stringByAppendingString:@"…"];
                [self.ring addObject:l]; if (self.ring.count > RING) [self.ring removeObjectAtIndex:0];
            }
            s = q + 1;
        }
        [self.partial replaceBytesInRange:NSMakeRange(0, (NSUInteger)(s - p)) withBytes:NULL length:0];
    }
}
- (void)tick {
    [self readNew];
    NSUserDefaults *d = NSUserDefaults.standardUserDefaults;
    BOOL red_only = [d boolForKey:@"dm.log_overlay_red"];
    NSInteger want = [d integerForKey:@"dm.log_overlay_lines"]; if (want <= 0) want = 14;
    NSMutableArray<NSString *> *shown = [NSMutableArray array];
    for (NSString *l in self.ring.reverseObjectEnumerator) {
        if (red_only && ![l containsString:@"[red] "]) continue;
        [shown insertObject:l atIndex:0]; if ((NSInteger)shown.count >= want) break;
    }
    UIFont *font = [UIFont monospacedSystemFontOfSize:9 weight:UIFontWeightRegular];
    NSMutableParagraphStyle *ps = [NSMutableParagraphStyle new]; ps.lineBreakMode = NSLineBreakByTruncatingTail;
    NSMutableAttributedString *t = [NSMutableAttributedString new];
    for (NSString *l in shown) {
        UIColor *c = [l containsString:@"[red] "] ? [UIColor colorWithRed:1 green:0.45 blue:0.45 alpha:1] : UIColor.whiteColor;
        [t appendAttributedString:[[NSAttributedString alloc] initWithString:[l stringByAppendingString:@"\n"]
                                                                  attributes:@{NSFontAttributeName: font, NSForegroundColorAttributeName: c, NSParagraphStyleAttributeName: ps}]];
    }
    self.label.attributedText = t;
    UIView *sv = self.label.superview; UIEdgeInsets in = sv.safeAreaInsets;
    CGFloat w = sv.bounds.size.width - in.left - in.right - 8, h = MIN(sv.bounds.size.height * 0.6, ceil(font.lineHeight * (CGFloat)shown.count) + 6);
    self.label.frame = CGRectMake(in.left + 4, in.top + 4, w, h);
    [sv bringSubviewToFront:self.label];
}
@end

// Called once the game view exists (main.m); the overlay is a subview of it that never takes touches
void dm_log_overlay_attach(UIView *view) {
    if (g_ov) { [view addSubview:g_ov.label]; return; }   // the game view was rebuilt (Retry after missing data)
    g_ov = [DmLogOverlay new]; g_ov.fd = -1; g_ov.ring = [NSMutableArray array]; g_ov.partial = [NSMutableData data];
    UILabel *l = [UILabel new]; l.numberOfLines = 0; l.userInteractionEnabled = NO; l.hidden = YES;
    l.backgroundColor = [UIColor colorWithWhite:0 alpha:0.55]; l.layer.cornerRadius = 4; l.clipsToBounds = YES;
    [view addSubview:l]; g_ov.label = l;
    [NSNotificationCenter.defaultCenter addObserver:g_ov selector:@selector(settingsChanged) name:NSUserDefaultsDidChangeNotification object:nil];
    [g_ov settingsChanged];
}
// The scene became active again (the setting may have been changed in the Settings app meanwhile)
void dm_log_overlay_refresh(void) { [g_ov settingsChanged]; }
