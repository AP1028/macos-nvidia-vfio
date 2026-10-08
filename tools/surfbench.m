// surfbench.m — measure the latency of the compositor's surface path.
//
// WindowServer's composited frames come from IOSurfaces that the accelerator
// adopts (nvaccel_iop_src_surf counts them). So: create an IOSurface, bind it to
// a Metal texture (which forces the driver to adopt it), time the pair, release.
//
// Usage: surfbench <count> <width> <height> [keep]
//   keep = 1 keeps every surface alive (fills VRAM, provokes the grant budget)
//
// The framebuffer's grant counters (debug.nvrmfb_vram_grants / _mapped_bytes)
// should move if this really exercises nvAllocVram -- check them around a run.

#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import <IOSurface/IOSurface.h>
#include <mach/mach_time.h>

static double now_ms(void) {
    static mach_timebase_info_data_t tb;
    if (!tb.denom) mach_timebase_info(&tb);
    return (double)mach_absolute_time() * tb.numer / tb.denom / 1e6;
}

static int cmp(const void *a, const void *b) {
    double x = *(const double *)a, y = *(const double *)b;
    return (x > y) - (x < y);
}

int main(int argc, char **argv) {
    @autoreleasepool {
        int count    = argc > 1 ? atoi(argv[1]) : 60;
        int W        = argc > 2 ? atoi(argv[2]) : 3440;
        int H        = argc > 3 ? atoi(argv[3]) : 1440;
        int keep     = argc > 4 ? atoi(argv[4]) : 0;

        id<MTLDevice> dev = MTLCreateSystemDefaultDevice();
        if (!dev) { printf("no Metal device\n"); return 1; }
        printf("device: %s\n", [[dev name] UTF8String]);
        printf("%d x %dx%d surfaces, keep=%d\n", count, W, H, keep);

        NSMutableArray *alive = [NSMutableArray array];
        double *t = calloc(count, sizeof(double));
        int made = 0, failed = 0;

        for (int i = 0; i < count; i++) {
            double t0 = now_ms();

            NSDictionary *p = @{
                (id)kIOSurfaceWidth:           @(W),
                (id)kIOSurfaceHeight:          @(H),
                (id)kIOSurfaceBytesPerElement: @(4),
                (id)kIOSurfaceBytesPerRow:     @(W * 4),
                (id)kIOSurfacePixelFormat:     @(0x42475241),   // 'BGRA'
                (id)kIOSurfaceIsGlobal:        @YES,
            };
            IOSurfaceRef s = IOSurfaceCreate((CFDictionaryRef)p);
            if (!s) { failed++; t[i] = now_ms() - t0; continue; }

            MTLTextureDescriptor *d =
                [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm
                                                                   width:W height:H mipmapped:NO];
            d.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead;
            d.storageMode = MTLStorageModeManaged;
            id<MTLTexture> tex = [dev newTextureWithDescriptor:d iosurface:s plane:0];
            if (!tex) { CFRelease(s); failed++; t[i] = now_ms() - t0; continue; }

            double dt = now_ms() - t0;
            t[i] = dt;
            made++;
            if (keep) { [alive addObject:@[ (__bridge id)s, tex ]]; }
            else      { CFRelease(s); }        // tex holds its own reference
        }

        qsort(t, count, sizeof(double), cmp);
        double sum = 0, max = 0;
        int over50 = 0, over200 = 0;
        for (int i = 0; i < count; i++) { sum += t[i]; if (t[i] > max) max = t[i];
                                          if (t[i] > 50) over50++; if (t[i] > 200) over200++; }
        printf("made %d, failed %d\n", made, failed);
        printf("  min    %8.2f ms\n", t[0]);
        printf("  median %8.2f ms\n", t[count / 2]);
        printf("  p90    %8.2f ms\n", t[(int)(count * 0.90)]);
        printf("  p99    %8.2f ms\n", t[(int)(count * 0.99) < count ? (int)(count * 0.99) : count - 1]);
        printf("  max    %8.2f ms\n", max);
        printf("  mean   %8.2f ms\n", sum / count);
        printf("  >50ms: %d   >200ms: %d\n", over50, over200);
        if (keep) printf("  holding %lu surfaces\n", (unsigned long)[alive count]);
        return 0;
    }
}
