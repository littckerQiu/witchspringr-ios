// Reflection json → nvn_refl (nvn_refl.m): the binding kinds dmsh_build.py writes. sbuf_ubo = a storage buffer whose address the shader reads from a
// uniform buffer (uniform slot reg, byte off): kind, slot, offset and the no-reuse flag; a missing, odd or out-of-range offset and a missing slot are refused.
#import <Foundation/Foundation.h>
#include <stdio.h>
#include "../nvn/nvn_refl.h"
int mtl_c2_tex_base(void) { return 0x20; }
int mtl_c2_samp_base(void) { return 0x568; }
const char *mtl_depth_mode_name(void) { return "near_is_minus_w"; }
static int g_fail, g_n;
#define EXPECT(name, want, got) do { long long w_ = (long long)(want), g_ = (long long)(got); g_n++; if (w_ != g_) g_fail++; \
    printf("%-60s expected %-6lld → got %-6lld %s\n", name, w_, g_, w_ == g_ ? "✓" : "✗"); } while (0)
static int parse(NSArray *bindings, nvn_refl *o, char *err) {
    NSDictionary *j = @{@"route": @"B", @"stage": @"vs", @"depth_mode": @"near_is_minus_w", @"c2": @{@"tex": @[@0x20, @32], @"samp": @[@0x568, @128]}, @"bindings": bindings};
    return nvn_refl_from_json(j, o, err, 256);
}
int main(void) { @autoreleasepool {
    nvn_refl o; char err[256];
    int r = parse(@[@{@"kind": @"cbuf", @"reg": @2, @"arg_id": @0, @"msl_name": @"vp_c5"},
                    @{@"kind": @"sbuf_ubo", @"reg": @1, @"off": @0x40, @"rw": @NO, @"arg_id": @3, @"msl_name": @"vp_s0"}], &o, err);
    EXPECT("sbuf_ubo parses", 0, r);
    EXPECT("two bindings", 2, o.nb);
    EXPECT("kind SBUFU", NVN_RB_SBUFU, o.b[1].kind);
    EXPECT("uniform slot 1", 1, o.b[1].reg);
    EXPECT("offset 0x40", 0x40, o.b[1].off);
    EXPECT("argument id 3", 3, o.b[1].aid);
    EXPECT("argument blocks not reused (ubo_addr)", 1, o.ubo_addr);
    r = parse(@[@{@"kind": @"sbuf", @"reg": @0, @"rw": @YES, @"arg_id": @0, @"msl_name": @"vp_s0"}], &o, err);
    EXPECT("plain storage buffer: rw kept, argument blocks reusable", 1, !r && o.b[0].kind == NVN_RB_SBUFP && o.b[0].rw && !o.ubo_addr);
    EXPECT("sbuf_ubo without an offset is refused", 1, parse(@[@{@"kind": @"sbuf_ubo", @"reg": @1, @"arg_id": @0, @"msl_name": @"vp_s0"}], &o, err));
    EXPECT("sbuf_ubo with an unaligned offset is refused", 1, parse(@[@{@"kind": @"sbuf_ubo", @"reg": @1, @"off": @0x42, @"arg_id": @0, @"msl_name": @"vp_s0"}], &o, err));
    EXPECT("sbuf_ubo with an offset past 64 KiB is refused", 1, parse(@[@{@"kind": @"sbuf_ubo", @"reg": @1, @"off": @0x10000, @"arg_id": @0, @"msl_name": @"vp_s0"}], &o, err));
    EXPECT("sbuf_ubo without a slot is refused", 1, parse(@[@{@"kind": @"sbuf_ubo", @"reg": [NSNull null], @"off": @0x40, @"arg_id": @0, @"msl_name": @"vp_s0"}], &o, err));
    printf("== %d checks, %d failed ==\n", g_n, g_fail);
    return g_fail != 0;
} }
