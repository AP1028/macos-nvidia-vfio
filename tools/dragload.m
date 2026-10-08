// dragload.m — generate compositor load autonomously, and measure it.
//
// Opens a window with Metal-rendered content and moves it continuously for N
// seconds, then reports what the compositor achieved. This reproduces the load
// of dragging a window without needing a human, so every experiment can be
// measured the same way.
//
// Usage: dragload <seconds> [size] [fps-report]
//   Reports: compositor flips/s (read from the driver's sysctl before and after),
//   its own redraw rate, and elapsed wall time.
//
// Run it inside the GUI session:  launchctl asuser $(id -u) ./dragload 20

#import <Cocoa/Cocoa.h>
#import <Metal/Metal.h>
#import <QuartzCore/QuartzCore.h>
#include <mach/mach_time.h>
#include <sys/sysctl.h>

static double now_s(void) {
    static mach_timebase_info_data_t tb;
    if (!tb.denom) mach_timebase_info(&tb);
    return (double)mach_absolute_time() * tb.numer / tb.denom / 1e9;
}
static long long sysctl_q(const char *name) {
    long long v = -1; size_t l = sizeof v;
    if (sysctlbyname(name, &v, &l, NULL, 0) != 0) return -1;
    return v;
}

@interface View : NSView
@property (nonatomic) id<MTLDevice> dev;
@property (nonatomic) id<MTLCommandQueue> q;
@property (nonatomic) NSUInteger frames;
@end

@implementation View
- (BOOL)wantsUpdateLayer { return YES; }
- (void)updateLayer {
    // Draw through Metal so the content is a real GPU surface, like a window's.
    if (!_q) { _dev = MTLCreateSystemDefaultDevice(); _q = [_dev newCommandQueue]; }
    id<CAMetalDrawable> d = [(CAMetalLayer *)self.layer nextDrawable];
    if (d) {
        MTLRenderPassDescriptor *rp = [MTLRenderPassDescriptor renderPassDescriptor];
        rp.colorAttachments[0].texture = d.texture;
        rp.colorAttachments[0].loadAction = MTLLoadActionClear;
        rp.colorAttachments[0].storeAction = MTLStoreActionStore;
        rp.colorAttachments[0].clearColor = MTLClearColorMake(0.1 + 0.8 * (double)(_frames % 60) / 60.0,
                                                             0.2, 0.6, 1.0);
        id<MTLCommandBuffer> cb = [_q commandBuffer];
        id<MTLRenderCommandEncoder> e = [cb renderCommandEncoderWithDescriptor:rp];
        [e endEncoding];
        [cb presentDrawable:d];
        [cb commit];
        _frames++;
    }
}
- (void)layout { ((CAMetalLayer *)self.layer).drawableSize = self.bounds.size; }
- (CALayer *)makeBackingLayer { CAMetalLayer *l = [CAMetalLayer layer]; l.device = MTLCreateSystemDefaultDevice(); l.pixelFormat = MTLPixelFormatBGRA8Unorm; return l; }
@end

int main(int argc, char **argv) {
    @autoreleasepool {
        double secs = argc > 1 ? atof(argv[1]) : 20.0;
        int size    = argc > 2 ? atoi(argv[2]) : 900;

        [NSApplication sharedApplication];
        [NSApp setActivationPolicy:NSApplicationActivationPolicyAccessory];

        NSRect r = NSMakeRect(200, 200, size, size);
        NSWindow *w = [[NSWindow alloc] initWithContentRect:r
                                                  styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable
                                                    backing:NSBackingStoreBuffered
                                                      defer:NO];
        [w setTitle:@"dragload"];
        View *v = [[View alloc] initWithFrame:r];
        [w setContentView:v];
        [w makeKeyAndOrderFront:nil];
        [w setLevel:NSFloatingWindowLevel];        // stay visible over others
        [NSApp activateIgnoringOtherApps:YES];

        long long flip0 = sysctl_q("debug.nvrmfb_flip_n");
        long long park0 = -1;
        double t0 = now_s();
        NSUInteger moves = 0;
        NSRect screen = [[NSScreen mainScreen] frame];

        while (now_s() - t0 < secs) {
            @autoreleasepool {
                // Move the window like a drag: a smooth path across the screen.
                double t = now_s() - t0;
                double x = screen.size.width  * 0.5 + sin(t * 1.2) * screen.size.width  * 0.35;
                double y = screen.size.height * 0.5 + cos(t * 0.9) * screen.size.height * 0.30;
                [w setFrameOrigin:NSMakePoint(x, y)];
                [v setNeedsDisplay:YES];                 // force a redraw -> GPU surface churn
                [v displayIfNeeded];
                [w displayIfNeeded];
                [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.001]];
                moves++;
            }
        }
        double dt = now_s() - t0;
        long long flip1 = sysctl_q("debug.nvrmfb_flip_n");
        printf("dragload: %.1f s, %lu moves (%.1f/s), %lu redraws (%.1f/s)\n",
               dt, (unsigned long)moves, moves / dt, (unsigned long)v.frames, v.frames / dt);
        printf("  compositor flips during load: %lld  ->  %.1f fps\n",
               flip1 - flip0, (double)(flip1 - flip0) / dt);
        (void)park0;
        return 0;
    }
}
