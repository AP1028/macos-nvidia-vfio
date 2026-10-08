// shaderbench.m — measure the first-use shader cost through the translator.
//
// The pipeline is Metal -> AIR -> SPIR-V -> NVK/NAK -> GPU, and the plugin caches
// each stage (aircache / spvcache / linkcache). A cache MISS pays the full
// translation + compile. That is a one-time cost per distinct shader, which is
// the shape of "the first drag stalls for ~0.5 s, then it is smooth".
//
// Usage: shaderbench <count> [compute|render]
//   Each iteration compiles a DISTINCT shader (a varying constant), so every one
//   is a guaranteed cache miss. Timings are per compile.

#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
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
        int count = argc > 1 ? atoi(argv[1]) : 20;
        int render = argc > 2 && !strcmp(argv[2], "render");
        id<MTLDevice> dev = MTLCreateSystemDefaultDevice();
        if (!dev) { printf("no device\n"); return 1; }
        printf("device: %s   mode: %s   n=%d\n", [[dev name] UTF8String],
               render ? "render" : "compute", count);

        double *t = calloc(count, sizeof(double));
        int ok = 0, fail = 0;

        for (int i = 0; i < count; i++) {
            double t0 = now_ms();
            NSError *__autoreleasing err = nil;
            NSString *src;

            if (!render) {
                // Distinct compute kernel per iteration -> cache miss every time.
                src = [NSString stringWithFormat:
                    @"#include <metal_stdlib>\nusing namespace metal;\n"
                     "kernel void k(device float*o, uint i[[thread_position_in_grid]]){"
                     "  float x = (float)i * %d.0f;"
                     "  for (int j=0;j<8;j++) x = fma(x, 1.0001f, %d.0f);"
                     "  o[i] = x; }\n", i + 1, i + 3];
            } else {
                // Distinct fragment shader -> the shape the compositor uses.
                src = [NSString stringWithFormat:
                    @"#include <metal_stdlib>\nusing namespace metal;\n"
                     "struct V { float4 p [[position]]; float2 uv; };\n"
                     "fragment float4 f(V in [[stage_in]], texture2d<float> t [[texture(0)]],"
                     " sampler s [[sampler(0)]]) {"
                     "  float4 c = t.sample(s, in.uv);"
                     "  return c * %d.0f + %d.0f; }\n", (i % 7) + 1, (i % 5) + 1];
            }

            id<MTLLibrary> lib = [dev newLibraryWithSource:src options:nil error:&err];
            if (!lib) { fail++; t[i] = now_ms() - t0; continue; }
            id<MTLFunction> fn = [lib newFunctionWithName:render ? @"f" : @"k"];
            if (!fn) { fail++; t[i] = now_ms() - t0; continue; }

            id obj = render
                ? (id)[dev newRenderPipelineStateWithDescriptor:
                        ({ MTLRenderPipelineDescriptor *d = [MTLRenderPipelineDescriptor new];
                           d.vertexFunction = fn; d.fragmentFunction = fn;
                           d.colorAttachments[0].pixelFormat = MTLPixelFormatBGRA8Unorm; d; })
                                             error:&err]
                : (id)[dev newComputePipelineStateWithFunction:fn error:&err];
            if (!obj) { fail++; t[i] = now_ms() - t0; continue; }

            t[i] = now_ms() - t0;
            ok++;
        }

        qsort(t, count, sizeof(double), cmp);
        double sum = 0, max = 0; int over100 = 0;
        for (int i = 0; i < count; i++) { sum += t[i]; if (t[i] > max) max = t[i]; if (t[i] > 100) over100++; }
        printf("compiled %d, failed %d\n", ok, fail);
        printf("  min    %8.1f ms\n", t[0]);
        printf("  median %8.1f ms\n", t[count / 2]);
        printf("  p90    %8.1f ms\n", t[(int)(count * 0.9)]);
        printf("  max    %8.1f ms\n", max);
        printf("  mean   %8.1f ms\n", sum / count);
        printf("  >100ms: %d\n", over100);
        return 0;
    }
}
