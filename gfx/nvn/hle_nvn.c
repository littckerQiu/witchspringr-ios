// NVN interface layer: takes over the nvnBootstrapLoader imported by main; the NVN driver in sdk is not executed at all.
// All 523 NVN names return counting thunks (nvn_thunks.S), and the thunks forward to the implementations here:
//   - those with semantics (device / memory pools / textures and samplers / queue / window / sync / events / command buffer memory) are implemented per NVN semantics, and the objects are real;
//   - those that only change GPU state and have no CPU-visible result (state objects, bindings, draws, clears...) are recorded as commands and replayed at submit;
//   - the rest (the 307 that main only loads but never calls + those without a prototype in the header) go to nvn_unimpl_entry: reports a failure and prints the name when called.
// GPU address = CPU address (memory pools use the real memory given by the game, also built as zero-copy MTLBuffer). Commands are recorded into the command memory given by the game and replayed at submit into a
// Metal command buffer (nvn_mtl.m): buffer copies / uniform updates go through blit (GPU ordering), event value writes / counters are written after the GPU completes;
// sync object = submit fence value, and waits are released only after the GPU completes.
// Every implementation gets a compile-time signature check against the prototypes in nvn_protos.h (NVNboolean parameters are received as uint32_t, only the low 8 bits are looked at).
// Environment switches: DM_NVN_FRAMES=N prints the call table per frame for the first N frames (default 3); DM_NVN_TSV=path writes the per-frame call table and timing to a TSV (DM_NVN_TSV_CALLS=0 writes timing only); DM_SLOWFRAME=1 writes only the per-frame breakdown of dropped frames to the log; DM_NVN_LOG=1 logs object creation.
#include "../../host/hle.h"
#include "nvn_protos.h"
#include "nvn_count.h"
#include "nvn_tex.h"
#include "nvn_mtl.h"
#include "nvn_pace.h"
#include "../../host/front.h"
#include "../../host/game.h"
#include "nvn_dirty.h"
#include <mach/mach_time.h>
#include <mach/mach.h>
#include <TargetConditionals.h>
#include <unistd.h>
#if TARGET_OS_OSX
#define DM_MEM_CAP_DEFAULT_GB 24
#else
#define DM_MEM_CAP_DEFAULT_GB 0
#endif
#include <pthread/qos.h>
#include <sys/resource.h>
#include <mach/thread_policy.h>
#include <assert.h>
#include <stdatomic.h>
#include <mach-o/getsect.h>
#include <mach-o/ldsyms.h>

// ---------- Slot table, thunks, unimplemented stubs ----------
typedef struct { _Atomic uint64_t cnt; void *fn; } nvn_slot_t;
nvn_slot_t nvn_slot[NVN_NFUNC];                 // The thunk accesses it by i*16; the layout must not change
_Static_assert(sizeof(nvn_slot_t) == 16, "the thunk addresses slots with a 16-byte stride");
extern void *nvn_thunk[NVN_NFUNC];
extern const char *nvn_names[NVN_NFUNC];
extern void nvn_unimpl_entry(void);
extern void nvn_prof_entry(void);
void *nvn_real[NVN_NFUNC];               // DM_NVN_PROF: the real implementation called by the timing wrapper
_Atomic uint64_t nvn_prof_ticks[NVN_NFUNC]; // DM_NVN_PROF: cumulative time of each function (cntvct counts)
static uint8_t g_unimpl_seen[NVN_NFUNC];

uint64_t nvn_unimpl_c(nvn_slot_t *slot, uint64_t x0, uint64_t x1, uint64_t x2, uint64_t lr, uint64_t x8) {
    unsigned i = (unsigned)(slot - nvn_slot);
    if (!g_unimpl_seen[i]) {   // Report once (set to 1, no increment: a uint8 increment wraps and re-reports after 256 calls)
        g_unimpl_seen[i] = 1;
        module_t *m = module_of((void *)lr);
        LOG("[red] unimplemented NVN function called: %s (x0=%#llx x1=%#llx x2=%#llx x8=%#llx) call site %s+%#llx", nvn_names[i], x0, x1, x2, x8,
            m ? m->name : "?", m ? lr - (uint64_t)m->base : lr);
    }
    return 0;
}

typedef struct { const char *name; void *fn; } nvn_impl;
#define NVN(name, ret, ...)                                                                       \
    static ret h_##name(__VA_ARGS__);                                                             \
    static const NVNT_##name chk_##name __attribute__((unused)) = h_##name;                       \
    __attribute__((used, section("__DATA,swnvn"))) static const nvn_impl e_##name = {#name, (void *)h_##name}; \
    static ret h_##name(__VA_ARGS__)
// Newer interfaces without prototypes: no signature check
#define NVN_NOPROTO(name, ret, ...)                                                               \
    static ret h_##name(__VA_ARGS__);                                                             \
    __attribute__((used, section("__DATA,swnvn"))) static const nvn_impl e_##name = {#name, (void *)h_##name}; \
    static ret h_##name(__VA_ARGS__)

static int g_log;
uint64_t nvn_new_serial(void) { static _Atomic uint64_t n; return ++n; }
static unsigned g_nsem;                          // Number of semantic implementations (filled by nvn_init_slots)
#define OLOG(...) do { if (g_log) LOG("[nvn] " __VA_ARGS__); } while (0)

static void nvn_init_slots(void) {
    static int done; if (done) return; done = 1;
    g_log = getenv("DM_NVN_LOG") != NULL;
    unsigned long sz;
    const nvn_impl *im = (const nvn_impl *)getsectiondata(&_mh_execute_header, "__DATA", "swnvn", &sz);
    unsigned nim = im ? (unsigned)(sz / sizeof *im) : 0, hit = 0;
    for (unsigned i = 0; i < NVN_NFUNC; i++) nvn_slot[i].fn = (void *)nvn_unimpl_entry;
    for (unsigned k = 0; k < nim; k++) {
        unsigned i = 0;
        while (i < NVN_NFUNC && strcmp(nvn_names[i], im[k].name)) i++;
        if (i == NVN_NFUNC) die("NVN implementation %s is not in main's name table", im[k].name);
        nvn_slot[i].fn = im[k].fn; hit++;
    }
    g_nsem = hit;
}

static void *nvn_lookup(const char *name) {
    nvn_init_slots();
    for (unsigned i = 0; i < NVN_NFUNC; i++)
        if (!strcmp(nvn_names[i], name)) return nvn_thunk[i];
    // Not a failure: the game looks up names this host's table does not have (manosaba: 13 newer ones, e.g. the *Deferred binds, each looked up
    // twice at startup) and copes with NULL. Logged once per name, not red; a call to a name the table has but the host does not implement is red
    // (nvn_unimpl_c)
    static char seen[64][64]; static int nseen; static pthread_mutex_t mu = PTHREAD_MUTEX_INITIALIZER;
    pthread_mutex_lock(&mu);
    int again = 0; for (int i = 0; i < nseen; i++) if (name && !strcmp(seen[i], name)) again = 1;
    if (!again && name && nseen < 64) snprintf(seen[nseen++], sizeof seen[0], "%s", name);
    pthread_mutex_unlock(&mu);
    if (!again) LOG("[nvn] address lookup of %s: not in this host's NVN table, answered NULL", name ? name : "(null)");
    return NULL;
}

// nvnBootstrapLoader is imported by main (defined in sdk); after it is forcibly taken over, the NVN driver in sdk is no longer referenced
HLE_FORCE("nvnBootstrapLoader", "the whole NVN graphics interface is replaced by the host null device (backed by Metal); the sdk NVN driver does not run",
          void *, h_nvnBootstrapLoader, const char *name) { return nvn_lookup(name); }

// ---------- Boolean parameters: Switch callers do not extend them, only look at the low 8 bits ----------
#define B(x) ((x) & 0xff)

#include "nvn_obj.h"
#include "nvn_hmap.h"

// ---------- Device ----------
NVN(nvnDeviceBuilderSetDefaults, void, NVNdeviceBuilder *b) { memset(b, 0, sizeof(dev_builder_t)); }
NVN(nvnDeviceBuilderSetFlags, void, NVNdeviceBuilder *b, int f) { ((dev_builder_t *)b)->flags = f; }
NVN(nvnDeviceInitialize, NVNboolean, NVNdevice *d, const NVNdeviceBuilder *b) {
    dev_t_ *o = (dev_t_ *)d; memset(o, 0, sizeof *o);
    o->magic = MAGIC('D', 'E', 'V', 0); o->flags = ((const dev_builder_t *)b)->flags;
    if (!dm_game.nvn_c2.ntex) die("game profile %s has no nvn_c2 (c[2] handle table layout of its shaders)", dm_game.id);
    void mtl_set_c2_layout(int tex, int ntex, int samp, int nsamp); mtl_set_c2_layout(dm_game.nvn_c2.tex, dm_game.nvn_c2.ntex, dm_game.nvn_c2.samp, dm_game.nvn_c2.nsamp);
    void mtl_set_depth_mode(int m); mtl_set_depth_mode(dm_game.nvn_depth_mode);
    OLOG("DeviceInitialize %p flags=%#x", (void *)d, o->flags);
    return 1;
}
NVN(nvnDeviceFinalize, void, NVNdevice *d) { ((dev_t_ *)d)->magic = 0; }
NVN(nvnDeviceGetProcAddress, PFNNVNGENERICFUNCPTRPROC, const NVNdevice *d, const char *name) {
    (void)d; return (PFNNVNGENERICFUNCPTRPROC)nvn_lookup(name);
}

// Device properties: values measured on Tegra X1 (nnheaders nvn_DeviceConstantsNX.h, obtained by calling nvnDeviceGetInteger item by item on SMO)
static const int g_devinfo[] = {
    [0x00] = 0, [0x01] = 0,      // API version: from the game profile (device_api), see nvnDeviceGetInteger
    [0x02] = 14, [0x03] = 65536, [0x04] = 256, [0x05] = 8, [0x06] = 16, [0x07] = 4, [0x08] = 16, [0x09] = 32,
    [0x0A] = 16, [0x0B] = 4, [0x0C] = 4, [0x0D] = 4, [0x0E] = 16, [0x0F] = 32, [0x10] = 32, [0x11] = 256, [0x12] = 256,
    [0x13] = 4, [0x14] = 8, [0x15] = 512, [0x16] = 256, [0x17] = 2, [0x18] = 256, [0x19] = 4096, [0x1A] = 131072,
    [0x1B] = 16, [0x1C] = 1536, [0x1D] = 1024, [0x1E] = 64, [0x1F] = 1536, [0x20] = 65535, [0x21] = 65535, [0x22] = 65535,
    [0x23] = 8, [0x24] = 1048576, [0x25] = 4096, [0x26] = 16, [0x27] = 4096, [0x28] = 1, [0x29] = 1, [0x2A] = 1,
    [0x2B] = 262144, [0x2C] = 15, [0x2D] = 2048, [0x2E] = 1, [0x2F] = 1, [0x30] = 14, [0x31] = 5, [0x32] = 1, [0x33] = 8,
    [0x34] = 8, [0x35] = 4, [0x36] = 32, [0x37] = 128, [0x38] = 32, [0x39] = 128, [0x3A] = 65536, [0x3B] = 1, [0x3C] = 4,
    [0x3D] = 16384, [0x3E] = 134217728, [0x3F] = 2048, [0x40] = 16384, [0x41] = 16384, [0x42] = 1, [0x43] = 1, [0x44] = 1,
    [0x45] = 1, [0x46] = 5, [0x47] = 1, [0x48] = 1, [0x49] = 1, [0x4A] = 1, [0x4B] = 1, [0x4C] = 1, [0x4D] = 16,
    [0x4E] = 1024, [0x4F] = 32, [0x50] = 4096, [0x51] = 65536, [0x52] = 65536, [0x53] = 256, [0x54] = 16384,
    [0x55] = 262144, [0x56] = 4096, [0x57] = 1, [0x58] = 4, [0x59] = 2, [0x5A] = 0, [0x5B] = 4096, [0x5C] = 16384,
    [0x5D] = 4096, [0x5E] = 128, [0x5F] = 4096,
};
NVN(nvnDeviceGetInteger, void, const NVNdevice *d, NVNdeviceInfo what, int *out) {
    (void)d;
    unsigned w = (unsigned)what;
    // 0x5F separate sampler binding count and 0x60/0x61 are not in the table measured on SMO: 0x5F is given 4096 per the sampler pool limit, unverified; 0x60/0x61 report a failure and return 0
    if (w >= sizeof g_devinfo / sizeof *g_devinfo) { LOG("[red] nvnDeviceGetInteger unknown item %#x, returning 0", w); *out = 0; return; }
    *out = g_devinfo[w];
    // API version (game.json device_api, default 55.15; DM_NVN_API=major.minor overrides): manosaba reads it without comparing (main 0x173cbd8, 53.311
    // kept from before, unverified); TotK requires major == 55 and minor >= 15 (main 0xbe0438) and otherwise creates no device, which crashes right
    // after (main 0xb9e658). Same field and default as nxnative's device_api (seedds, MIT)
    if (w <= 1) {
        static int api[2] = {-1, -1};
        if (api[0] < 0) {
            const char *e = getenv("DM_NVN_API");
            if (!e || sscanf(e, "%d.%d", &api[0], &api[1]) != 2) { api[0] = dm_game.nvn_api_major; api[1] = dm_game.nvn_api_minor; }
        }
        *out = api[w];
    }
    OLOG("DeviceGetInteger %#x -> %d", w, *out);
}
NVN(nvnDeviceGetImageHandle, NVNimageHandle, const NVNdevice *d, int id) { (void)d; return (NVNimageHandle)id; }
NVN(nvnDeviceRegisterFastClearColor, NVNboolean, NVNdevice *d, const float *c, NVNformat f) { (void)d; (void)c; (void)f; return 1; }   // a fast-clear hint for the console's compression: accepted, nothing to do (nxnative)
NVN(nvnDeviceRegisterFastClearDepth, NVNboolean, NVNdevice *d, float z) { (void)d; (void)z; return 1; }   // same, for depth (TotK main 0xcc8e38)
// Combined texture handle = texture ID | sampler ID << 20, the encoding of the separate handles; the replay layer takes the sampler from the high bits
// of a texture slot where the shader needs one (nvn_mtl.m NVN_RB_SAMPT). From nxnative (seedds, MIT); TotK main 0x2d34cc
NVN(nvnDeviceGetTextureHandle, NVNtextureHandle, const NVNdevice *d, int tex, int samp) { (void)d; return (NVNtextureHandle)((uint64_t)(uint32_t)tex | (uint64_t)(uint32_t)samp << 20); }
// Counter timestamps are written by the replay layer as 19.2 MHz ticks of the guest clock (nvn_mtl.m gpu_ticks: guest_ns × 12 / 625); these convert back to
// and read the same clock, so a counter timestamp, the current time and the guest's system tick can be subtracted from each other (nxnative found
// returning the raw ticks gave garbage; Tears of the Kingdom's frame-rate controller subtracts the system tick, see gpu_ticks)
NVN(nvnDeviceGetTimestampInNanoseconds, uint64_t, const NVNdevice *d, const NVNcounterData *c) { (void)d; return c->timestamp * 625 / 12; }
NVN(nvnDeviceGetCurrentTimestampInNanoseconds, uint64_t, const NVNdevice *d) { (void)d; return guest_ns() * 12 / 625 * 625 / 12; }
// Separate texture / sampler handles: value = descriptor index (the sampler index goes in bit 20 and above, consistent with the bit layout of combined handles)
NVN(nvnDeviceGetSeparateTextureHandle, NVNseparateTextureHandle, const NVNdevice *d, int id) { (void)d; return (NVNseparateTextureHandle){(uint64_t)id}; }
NVN(nvnDeviceGetSeparateSamplerHandle, NVNseparateSamplerHandle, const NVNdevice *d, int id) { (void)d; return (NVNseparateSamplerHandle){(uint64_t)id << 20}; }
NVN(nvnDeviceInstallDebugCallback, void, NVNdevice *d, const PFNNVNDEBUGCALLBACKPROC cb, void *data, uint32_t enable) {
    dev_t_ *o = (dev_t_ *)d; o->dbg_cb = B(enable) ? (void *)cb : NULL; o->dbg_data = data;
}
NVN(nvnDeviceSetWindowOriginMode, void, NVNdevice *d, NVNwindowOriginMode m) { ((dev_t_ *)d)->origin = m; LOG("[nvn] window origin %s", m ? "upper left (same as D3D / Metal)" : "lower left (GL)"); }
// The shaders were built for the profile's convention (game.json depth_mode; near=-w gets z remapped in every vertex shader): another one draws at wrong depths
NVN(nvnDeviceSetDepthMode, void, NVNdevice *d, NVNdepthMode m) {
    ((dev_t_ *)d)->depth_mode = m; LOG("[nvn] depth mode %s", m ? "near=0 (same as D3D / Metal)" : "near=-w (GL)");
    if ((int)m != dm_game.nvn_depth_mode) LOG("[red] the game sets depth mode %d, its shaders were built for %d (game.json depth_mode): geometry lands at wrong depths or is clipped", (int)m, dm_game.nvn_depth_mode);
}
NVN(nvnDeviceFinalizeCommandHandle, void, NVNdevice *d, NVNcommandHandle h) { (void)d; (void)h; }

// ---------- Memory pools ----------
NVN(nvnMemoryPoolBuilderSetDefaults, void, NVNmemoryPoolBuilder *b) { memset(b, 0, sizeof(pool_builder_t)); }
NVN(nvnMemoryPoolBuilderSetDevice, void, NVNmemoryPoolBuilder *b, NVNdevice *d) { ((pool_builder_t *)b)->dev = d; }
NVN(nvnMemoryPoolBuilderSetStorage, void, NVNmemoryPoolBuilder *b, void *m, size_t n) { ((pool_builder_t *)b)->mem = m; ((pool_builder_t *)b)->size = n; }
NVN(nvnMemoryPoolBuilderSetFlags, void, NVNmemoryPoolBuilder *b, int f) { ((pool_builder_t *)b)->flags = f; }
NVN(nvnMemoryPoolInitialize, NVNboolean, NVNmemoryPool *p, const NVNmemoryPoolBuilder *b) {
    const pool_builder_t *s = (const pool_builder_t *)b; pool_t *o = (pool_t *)p;
    o->magic = MAGIC('P', 'O', 'O', 'L'); o->flags = s->flags; o->mem = s->mem; o->size = s->size;
    if (o->mem) { mtl_pool_add(o->mem, o->size); nvn_dirty_add_range(o->mem, o->size); }
    if (!o->mem && !(o->flags & 0x200)) LOG("[red] MemoryPoolInitialize: non-virtual pool has no storage flags=%#x size=%#llx", o->flags, o->size);
    OLOG("MemoryPool %p mem=%p size=%#llx flags=%#x", (void *)p, (void *)o->mem, o->size, o->flags);
    return 1;
}
NVN(nvnMemoryPoolFinalize, void, NVNmemoryPool *p) {
    pool_t *o = (pool_t *)p;
    if (o->mem && !(o->flags & 0x200)) { nvn_dirty_remove_range(o->mem); mtl_pool_del(o->mem); }   // a virtual pool's storage belongs to a physical pool (MapVirtual)
    o->magic = 0;
}
// Virtual pool (flags 0x200): a GPU address range without storage; MapVirtual maps pages of physical pools into it. A request is 0x28 bytes: {physical pool,
// physical offset, virtual offset, size, storage class}. When every request has the same base (same physical pool, same physical offset - virtual offset), the
// virtual pool's storage points straight at that memory of the physical pool, which is what one set of physical pages is on the console, and buffer / Metal
// lookups land on the block the physical pool registered. Mappings with different bases (truly sparse) are not implemented: reported, fails.
// From nxnative's hle_nvn.c (seedds, MIT); TotK main 0x8d04dc maps one at startup
typedef struct { NVNmemoryPool *phys; int64_t poff, voff; uint64_t size; int32_t storage_class, _pad; } map_req;
_Static_assert(sizeof(map_req) == 0x28, "NVNmappingRequest");
NVN(nvnMemoryPoolMapVirtual, NVNboolean, NVNmemoryPool *p, int n, const NVNmappingRequest *rq) {
    pool_t *o = (pool_t *)p; const map_req *r = (const map_req *)rq;
    for (int i = 0; i < n; i++) {
        const pool_t *ph = (const pool_t *)r[i].phys;
        if (!ph) continue;   // unmapping (no physical pool): the storage is kept
        if (!ph->mem) { LOG("[red] MapVirtual: physical pool %p has no storage", (const void *)ph); return 0; }
        if (r[i].voff < 0 || (uint64_t)r[i].voff + r[i].size > o->size || (uint64_t)r[i].poff + r[i].size > ph->size) {
            LOG("[red] MapVirtual: request out of range (virtual %#llx+%#llx / pool %#llx, physical %#llx / pool %#llx)", (unsigned long long)r[i].voff,
                (unsigned long long)r[i].size, (unsigned long long)o->size, (unsigned long long)r[i].poff, (unsigned long long)ph->size);
            return 0;
        }
        uint8_t *base = ph->mem + r[i].poff - r[i].voff;
        if (o->mem && o->mem != base) { LOG("[red] MapVirtual: sparse mapping not implemented: virtual pool %p is on %p, this request wants %p", (void *)o, (void *)o->mem, (void *)base); return 0; }
        if (!o->mem) LOG("[nvn] MapVirtual: virtual pool %p (%#llx bytes) uses physical pool %p + %#llx", (void *)o, (unsigned long long)o->size, (const void *)ph, (unsigned long long)(r[i].poff - r[i].voff));
        o->mem = base;
    }
    return 1;
}
NVN(nvnMemoryPoolFlushMappedRange, void, const NVNmemoryPool *p, ptrdiff_t off, size_t n) { (void)p; (void)off; (void)n; }
NVN(nvnMemoryPoolGetBufferAddress, NVNbufferAddress, const NVNmemoryPool *p) { return (NVNbufferAddress)((const pool_t *)p)->mem; }
// Pool memory is the real memory given by the game (same address for CPU and GPU), so mapping returns the original pointer; cache maintenance has nothing to do
NVN(nvnMemoryPoolMap, void *, const NVNmemoryPool *p) { return ((const pool_t *)p)->mem; }
void mtl_pool_invalidate(const pool_t *p, uint64_t off, uint64_t n);   // the CPU is about to read what the GPU wrote: GPU results of this range are written back (nvn_mtl.m)
NVN(nvnMemoryPoolInvalidateMappedRange, void, const NVNmemoryPool *p, ptrdiff_t off, size_t n) { if (off >= 0) mtl_pool_invalidate((const pool_t *)p, (uint64_t)off, n); }
NVN(nvnMemoryPoolGetSize, size_t, const NVNmemoryPool *p) { return ((const pool_t *)p)->size; }
NVN(nvnMemoryPoolGetFlags, NVNmemoryPoolFlags, const NVNmemoryPool *p) { return (NVNmemoryPoolFlags)((const pool_t *)p)->flags; }
NVN(nvnMemoryPoolBuilderGetSize, size_t, const NVNmemoryPoolBuilder *b) { return ((const pool_builder_t *)b)->size; }
NVN(nvnMemoryPoolBuilderGetFlags, NVNmemoryPoolFlags, const NVNmemoryPoolBuilder *b) { return (NVNmemoryPoolFlags)((const pool_builder_t *)b)->flags; }

// ---------- Buffers: a range inside a pool, address = pool memory + offset ----------
#define BB(b) ((buf_builder_t *)(b))
#define BF(b) ((const buf_t *)(b))
NVN(nvnBufferBuilderSetDefaults, void, NVNbufferBuilder *b) { NVNdevice *d = BB(b)->dev; memset(b, 0, sizeof(buf_builder_t)); BB(b)->dev = d; }
NVN(nvnBufferBuilderSetDevice, void, NVNbufferBuilder *b, NVNdevice *d) { BB(b)->dev = d; }
NVN(nvnBufferBuilderSetStorage, void, NVNbufferBuilder *b, NVNmemoryPool *p, ptrdiff_t off, size_t n) { BB(b)->pool = (pool_t *)p; BB(b)->off = off; BB(b)->size = n; }
NVN(nvnBufferBuilderGetMemoryOffset, ptrdiff_t, const NVNbufferBuilder *b) { return ((const buf_builder_t *)b)->off; }
NVN(nvnBufferBuilderGetSize, size_t, const NVNbufferBuilder *b) { return ((const buf_builder_t *)b)->size; }
NVN(nvnBufferInitialize, NVNboolean, NVNbuffer *b, const NVNbufferBuilder *bb) {
    const buf_builder_t *s = (const buf_builder_t *)bb; buf_t *o = (buf_t *)b;
    if (!s->pool || !s->pool->mem) { LOG("[red] BufferInitialize: pool %p has no storage (virtual pools not supported) off=%#llx size=%#llx", (void *)s->pool, (long long)s->off, s->size); return 0; }
    if ((uint64_t)s->off + s->size > s->pool->size) { LOG("[red] BufferInitialize out of pool bounds: off=%#llx size=%#llx pool_size=%#llx", (long long)s->off, s->size, s->pool->size); return 0; }
    *o = (buf_t){MAGIC('B', 'U', 'F', 0), s->pool, s->off, s->size, s->pool->mem + s->off, nvn_new_serial()};
    OLOG("Buffer %p pool=%p off=%#llx size=%#llx", (void *)b, (void *)s->pool, (long long)s->off, s->size);
    return 1;
}
NVN(nvnBufferFinalize, void, NVNbuffer *b) { ((buf_t *)b)->magic = 0; }
NVN(nvnBufferMap, void *, const NVNbuffer *b) { return BF(b)->mem; }
NVN(nvnBufferGetAddress, NVNbufferAddress, const NVNbuffer *b) { return (NVNbufferAddress)BF(b)->mem; }
NVN(nvnBufferFlushMappedRange, void, const NVNbuffer *b, ptrdiff_t off, size_t n) { (void)b; (void)off; (void)n; }
NVN(nvnBufferInvalidateMappedRange, void, const NVNbuffer *b, ptrdiff_t off, size_t n) { (void)b; (void)off; (void)n; }
NVN(nvnBufferGetMemoryPool, NVNmemoryPool *, const NVNbuffer *b) { return (NVNmemoryPool *)BF(b)->pool; }
NVN(nvnBufferGetMemoryOffset, ptrdiff_t, const NVNbuffer *b) { return BF(b)->off; }
NVN(nvnBufferGetSize, size_t, const NVNbuffer *b) { return BF(b)->size; }
NVN(nvnBufferGetDebugID, uint64_t, const NVNbuffer *b) { return BF(b)->serial; }

// ---------- Descriptor pools ----------
NVN(nvnTexturePoolInitialize, NVNboolean, NVNtexturePool *tp, const NVNmemoryPool *p, ptrdiff_t off, int n) {
    *(dpool_t *)tp = (dpool_t){(const pool_t *)p, off, n}; OLOG("TexturePool n=%d", n); mtl_set_tex_pool_n(n); return 1;
}
NVN(nvnTexturePoolFinalize, void, NVNtexturePool *tp) { (void)tp; }
// Textures Metal cannot create are skipped at replay (nvn_mtl.m tex_desc), and objects registered without being initialized textures hold no valid description:
// log them with the game's call site (first 32) to find which code builds them.
static void tex_diag(const char *what, int id, const tex_t *o, const char *why, uint64_t lr) {
    static _Atomic int n; if (atomic_fetch_add(&n, 1) >= 32) return;
    module_t *m = module_of((void *)lr);
    LOG("[nvn] [red] %s: %s: id %d ser %llu magic %#x target %d format %#x flags %#x samples %d size %ux%ux%u levels %u, call site %s+%#llx",
        what, why, id, o->serial, o->magic, o->d.target, o->d.format, o->d.flags, o->d.samples, o->d.width, o->d.height, o->d.depth, o->d.levels,
        m ? m->name : "?", m ? lr - (uint64_t)m->base : lr);
}
static void tex_reg_check(const char *what, int id, const NVNtexture *t, uint64_t lr) {
    const tex_t *o = (const tex_t *)t; if (!o) return;
    const char *why = o->magic != MAGIC('T', 'E', 'X', 0) ? "not an initialized texture" : nvn_texdesc_metal_check(&o->d);
    if (why) tex_diag(what, id, o, why, lr);
}
NVN(nvnTexturePoolRegisterTexture, void, const NVNtexturePool *tp, int id, const NVNtexture *t, const NVNtextureView *v) {
    (void)tp; tex_reg_check("RegisterTexture", id, t, DM_GUEST_RA()); mtl_reg_tex(id, (const tex_t *)t, (const view_t *)v);
}
// Image descriptors live in the texture pool alongside texture descriptors, in the same ID space (the replay layer's image slots fetch textures from the same registration table, see nvn_mtl.m NVN_RB_IMG)
NVN(nvnTexturePoolRegisterImage, void, const NVNtexturePool *tp, int id, const NVNtexture *t, const NVNtextureView *v) {
    (void)tp; tex_reg_check("RegisterImage", id, t, DM_GUEST_RA()); mtl_reg_tex(id, (const tex_t *)t, (const view_t *)v);
}
NVN(nvnSamplerPoolInitialize, NVNboolean, NVNsamplerPool *sp, const NVNmemoryPool *p, ptrdiff_t off, int n) {
    *(dpool_t *)sp = (dpool_t){(const pool_t *)p, off, n}; OLOG("SamplerPool n=%d", n); return 1;
}
NVN(nvnSamplerPoolFinalize, void, NVNsamplerPool *sp) { (void)sp; }
NVN(nvnSamplerPoolRegisterSampler, void, const NVNsamplerPool *sp, int id, const NVNsampler *s) { (void)sp; mtl_reg_samp(id, &((const samp_t *)s)->p); }

// ---------- Textures ----------
#define TB(b) ((tex_builder_t *)(b))
NVN(nvnTextureBuilderSetDefaults, void, NVNtextureBuilder *b) {
    NVNdevice *dev = TB(b)->dev; memset(b, 0, sizeof(tex_builder_t)); TB(b)->dev = dev;
    TB(b)->d.target = NVN_TEXTURE_TARGET_2D; TB(b)->d.width = TB(b)->d.height = TB(b)->d.depth = TB(b)->d.levels = 1;
}
NVN(nvnTextureBuilderSetDevice, void, NVNtextureBuilder *b, NVNdevice *d) { TB(b)->dev = d; }
NVN(nvnTextureBuilderSetFlags, void, NVNtextureBuilder *b, int f) { TB(b)->d.flags = f; }
NVN(nvnTextureBuilderSetTarget, void, NVNtextureBuilder *b, NVNtextureTarget t) { TB(b)->d.target = t; }
NVN(nvnTextureBuilderSetWidth, void, NVNtextureBuilder *b, int v) { TB(b)->d.width = v; }
NVN(nvnTextureBuilderSetHeight, void, NVNtextureBuilder *b, int v) { TB(b)->d.height = v; }
NVN(nvnTextureBuilderSetDepth, void, NVNtextureBuilder *b, int v) { TB(b)->d.depth = v; }
NVN(nvnTextureBuilderSetSize1D, void, NVNtextureBuilder *b, int w) { TB(b)->d.width = w; TB(b)->d.height = TB(b)->d.depth = 1; }
NVN(nvnTextureBuilderSetSize2D, void, NVNtextureBuilder *b, int w, int h) { TB(b)->d.width = w; TB(b)->d.height = h; TB(b)->d.depth = 1; }
NVN(nvnTextureBuilderSetSize3D, void, NVNtextureBuilder *b, int w, int h, int d) { TB(b)->d.width = w; TB(b)->d.height = h; TB(b)->d.depth = d; }
NVN(nvnTextureBuilderSetSwizzle, void, NVNtextureBuilder *b, NVNtextureSwizzle r, NVNtextureSwizzle g, NVNtextureSwizzle bl, NVNtextureSwizzle a) {
    nvn_texdesc *d = &TB(b)->d; d->swz[0] = (uint8_t)r; d->swz[1] = (uint8_t)g; d->swz[2] = (uint8_t)bl; d->swz[3] = (uint8_t)a;
    d->swz_set = !(r == NVN_TEXTURE_SWIZZLE_R && g == NVN_TEXTURE_SWIZZLE_G && bl == NVN_TEXTURE_SWIZZLE_B && a == NVN_TEXTURE_SWIZZLE_A);
}
NVN(nvnTextureBuilderSetDepthStencilMode, void, NVNtextureBuilder *b, NVNtextureDepthStencilMode m) { TB(b)->d.ds_mode = (uint8_t)m; }
NVN(nvnTextureBuilderGetStorageClass, NVNstorageClass, const NVNtextureBuilder *b) { (void)b; return 0; }   // the host has no storage classes (nxnative)
NVN(nvnTextureBuilderSetLevels, void, NVNtextureBuilder *b, int v) { TB(b)->d.levels = v; }
NVN(nvnTextureBuilderSetFormat, void, NVNtextureBuilder *b, NVNformat f) { TB(b)->d.format = f; }
NVN(nvnTextureBuilderSetSamples, void, NVNtextureBuilder *b, int s) { TB(b)->d.samples = s; }
NVN(nvnTextureBuilderSetStride, void, NVNtextureBuilder *b, ptrdiff_t s) { TB(b)->d.stride = (uint32_t)s; }
NVN(nvnTextureBuilderSetStorage, void, NVNtextureBuilder *b, NVNmemoryPool *p, ptrdiff_t off) { { uint64_t lr = DM_GUEST_RA(); module_t *m = module_of((void *)lr); OLOG("TextureBuilderSetStorage b=%p pool=%p off=%#llx lr=%s+%#llx", (void *)b, (void *)p, (long long)off, m ? m->name : "?", m ? lr - (uint64_t)m->base : lr); } TB(b)->pool = (pool_t *)p; TB(b)->off = off; }
// The SDK reference says the console ignores this pointer: packaged data is expected to be in the texture's pool storage already (only the Windows
// reference implementation converts and copies it). Tears of the Kingdom calls it
NVN(nvnTextureBuilderSetPackagedTextureData, void, NVNtextureBuilder *b, const void *data) { (void)b; (void)data; }
NVN(nvnTextureBuilderSetPackagedTextureLayout, void, NVNtextureBuilder *b, const NVNpackagedTextureLayout *l) {
    TB(b)->has_layout = l != NULL; if (l) memcpy(TB(b)->layout, l->layout, 8);
    TB(b)->d.pkg_block_h = l ? l->layout[0] + 1 : 0;
}
NVN(nvnTextureBuilderGetFlags, NVNtextureFlags, const NVNtextureBuilder *b) { return (NVNtextureFlags)((const tex_builder_t *)b)->d.flags; }
#define CTB(b) (&((const tex_builder_t *)(b))->d)
static void get_swz(const nvn_texdesc *d, NVNtextureSwizzle *r, NVNtextureSwizzle *g, NVNtextureSwizzle *b, NVNtextureSwizzle *a) {
    *r = d->swz_set ? (NVNtextureSwizzle)d->swz[0] : NVN_TEXTURE_SWIZZLE_R; *g = d->swz_set ? (NVNtextureSwizzle)d->swz[1] : NVN_TEXTURE_SWIZZLE_G;
    *b = d->swz_set ? (NVNtextureSwizzle)d->swz[2] : NVN_TEXTURE_SWIZZLE_B; *a = d->swz_set ? (NVNtextureSwizzle)d->swz[3] : NVN_TEXTURE_SWIZZLE_A;
}
NVN(nvnTextureBuilderGetTarget, NVNtextureTarget, const NVNtextureBuilder *b) { return (NVNtextureTarget)CTB(b)->target; }
NVN(nvnTextureBuilderGetWidth, int, const NVNtextureBuilder *b) { return (int)CTB(b)->width; }
NVN(nvnTextureBuilderGetHeight, int, const NVNtextureBuilder *b) { return (int)CTB(b)->height; }
NVN(nvnTextureBuilderGetDepth, int, const NVNtextureBuilder *b) { return (int)CTB(b)->depth; }
NVN(nvnTextureBuilderGetLevels, int, const NVNtextureBuilder *b) { return (int)CTB(b)->levels; }
NVN(nvnTextureBuilderGetFormat, NVNformat, const NVNtextureBuilder *b) { return (NVNformat)CTB(b)->format; }
NVN(nvnTextureBuilderGetSamples, int, const NVNtextureBuilder *b) { return CTB(b)->samples; }
NVN(nvnTextureBuilderGetSwizzle, void, const NVNtextureBuilder *b, NVNtextureSwizzle *r, NVNtextureSwizzle *g, NVNtextureSwizzle *bl, NVNtextureSwizzle *a) { get_swz(CTB(b), r, g, bl, a); }
NVN(nvnTextureBuilderGetDepthStencilMode, NVNtextureDepthStencilMode, const NVNtextureBuilder *b) { return (NVNtextureDepthStencilMode)CTB(b)->ds_mode; }
NVN(nvnTextureBuilderGetStride, ptrdiff_t, const NVNtextureBuilder *b) { return (ptrdiff_t)CTB(b)->stride; }
NVN(nvnTextureBuilderGetMemoryOffset, ptrdiff_t, const NVNtextureBuilder *b) { return ((const tex_builder_t *)b)->off; }
// ZCull (compressed storage of the depth-culling hardware): no Metal equivalent; the host never reads or writes this buffer (Save / RestoreZCullData are empty implementations), the size only affects the game's own memory accounting.
// It must not be 0: Unity builds the pool from "sum of texture sizes + ZCull size" and carves it with its own allocator (main+0x99d6c0), which allocates size 0 as 1 byte (csinc),
// so it takes 1 byte after the depth texture, pushes the following swapchain textures out by the 0x200 alignment gap, and the third one gets no space (offset -1). Report 0x1000: positive and a multiple of the ZCull allocation alignment (0x1000), leaving no gap.
// The real device's exact value is unverified (it depends on the texture size); the host does not use this memory, so the smallest granularity that keeps the accounting consistent is taken.
#define ZCULL_SIZE 0x1000
NVN(nvnTextureBuilderGetZCullStorageSize, size_t, const NVNtextureBuilder *b) { (void)b; return ZCULL_SIZE; }
#define CTB_(b) (&((const tex_builder_t *)(b))->d)
static uint64_t g_layout_logged;
static void log_layout(const tex_builder_t *b, const nvn_texlayout *L) {
    if (b->has_layout && g_layout_logged++ < 16)
        LOG("[nvn] packaged texture %ux%ux%u levels %u format %#x target %d layout bytes %02x%02x%02x%02x%02x%02x%02x%02x → block height log2=%u (from layout byte 0) size %#llx",
            b->d.width, b->d.height, b->d.depth, b->d.levels, b->d.format, b->d.target, b->layout[0], b->layout[1], b->layout[2],
            b->layout[3], b->layout[4], b->layout[5], b->layout[6], b->layout[7], L->tileH, L->size);
}
NVN(nvnTextureBuilderGetStorageSize, size_t, const NVNtextureBuilder *b) {
    nvn_texlayout L; nvn_tex_layout(&((const tex_builder_t *)b)->d, &L);
    if (!L.bpb) LOG("[red] TextureBuilderGetStorageSize: unknown format %#x", ((const tex_builder_t *)b)->d.format);
    log_layout((const tex_builder_t *)b, &L);
    OLOG("TextureBuilderGetStorageSize b=%p %ux%u fmt %#x flags %#x → %#llx", (const void *)b, CTB_(b)->width, CTB_(b)->height, CTB_(b)->format, CTB_(b)->flags, L.size);
    return L.size;
}
NVN(nvnTextureBuilderGetStorageAlignment, size_t, const NVNtextureBuilder *b) {
    nvn_texlayout L; nvn_tex_layout(&((const tex_builder_t *)b)->d, &L);
    OLOG("TextureBuilderGetStorageAlignment b=%p %ux%u fmt %#x → %#x", (const void *)b, CTB_(b)->width, CTB_(b)->height, CTB_(b)->format, L.align);
    return L.align;
}
#define TX(t) ((tex_t *)(t))
#define CTX(t) ((const tex_t *)(t))
#define tex_snap(t) mtl_tex_snap(CTX(t))   // recorded commands point at a host copy of the texture (nvn_mtl.m)
NVN(nvnTextureInitialize, NVNboolean, NVNtexture *t, const NVNtextureBuilder *b) {
    const tex_builder_t *s = (const tex_builder_t *)b; tex_t *o = TX(t);
    OLOG("TextureInitialize t=%p b=%p builder.off=%#llx", (void *)t, (const void *)b, (long long)s->off);
    { static int red; if (s->d.ds_mode && !red++) LOG("[red] TextureInitialize: depth-stencil texture sampled as stencil (ds_mode=%d): Metal stencil view not implemented, still sampling depth", s->d.ds_mode); }
    memset(o, 0, sizeof *o);
    o->magic = MAGIC('T', 'E', 'X', 0); o->d = s->d; o->pool = s->pool; o->off = s->off;
    o->has_layout = s->has_layout; memcpy(o->layout, s->layout, 8);
    { nvn_texlayout L; nvn_tex_layout(&o->d, &L); o->size = (uint32_t)L.size; o->layer_size = (uint32_t)L.layer_size; if (L.size >> 32) LOG("[red] TextureInitialize: storage %#llx exceeds 4 GB", L.size); }
    o->mem = s->pool && s->pool->mem ? s->pool->mem + s->off : NULL;
    o->serial = nvn_new_serial();
    mtl_tex_live(o);   // the texture now at this storage (a registration of a finalized one there follows it: nvn_mtl.m tex_by_id)
    { const char *why = !o->d.format ? "format 0" : nvn_texdesc_metal_check(&o->d); if (why) tex_diag("TextureInitialize", -1, o, why, DM_GUEST_RA()); }
    if (g_log && o->d.width == 1920 && o->d.height == 1080) { const uint8_t *q = (const uint8_t *)t; char hx[0xC0 * 2 + 1]; for (int i = 0; i < 0xC0; i++) snprintf(hx + 2 * i, 3, "%02x", q[i]); LOG("[nvn] Texture %p 0xC0 bytes: %s", (void *)t, hx); }
    OLOG("Texture %p ser %llu %ux%ux%u lv%u fmt=%#x tgt=%d flags=%#x size=%#llx mem=%p", (void *)t, o->serial, o->d.width, o->d.height, o->d.depth,
         o->d.levels, o->d.format, o->d.target, o->d.flags, (unsigned long long)o->size, (void *)o->mem);
    return 1;
}
NVN(nvnTextureFinalize, void, NVNtexture *t) { OLOG("TextureFinalize %p ser %llu", (void *)t, TX(t)->serial); mtl_tex_release(TX(t)); TX(t)->magic = 0; }
NVN(nvnTextureGetFlags, NVNtextureFlags, const NVNtexture *t) { return (NVNtextureFlags)CTX(t)->d.flags; }
NVN(nvnTextureGetWidth, int, const NVNtexture *t) { return (int)CTX(t)->d.width; }
NVN(nvnTextureGetHeight, int, const NVNtexture *t) { return (int)CTX(t)->d.height; }
NVN(nvnTextureGetDepth, int, const NVNtexture *t) { return (int)CTX(t)->d.depth; }
NVN(nvnTextureGetStorageSize, int, const NVNtexture *t) { return (int)CTX(t)->size; }
NVN(nvnTextureGetTarget, NVNtextureTarget, const NVNtexture *t) { return (NVNtextureTarget)CTX(t)->d.target; }
NVN(nvnTextureGetLevels, int, const NVNtexture *t) { return (int)CTX(t)->d.levels; }
NVN(nvnTextureGetFormat, NVNformat, const NVNtexture *t) { return (NVNformat)CTX(t)->d.format; }
NVN(nvnTextureGetSamples, int, const NVNtexture *t) { return CTX(t)->d.samples; }
NVN(nvnTextureGetSwizzle, void, const NVNtexture *t, NVNtextureSwizzle *r, NVNtextureSwizzle *g, NVNtextureSwizzle *b, NVNtextureSwizzle *a) { get_swz(&CTX(t)->d, r, g, b, a); }
NVN(nvnTextureGetDepthStencilMode, NVNtextureDepthStencilMode, const NVNtexture *t) { return (NVNtextureDepthStencilMode)CTX(t)->d.ds_mode; }
NVN(nvnTextureGetStride, ptrdiff_t, const NVNtexture *t) { return (ptrdiff_t)CTX(t)->d.stride; }
NVN(nvnTextureGetMemoryOffset, ptrdiff_t, const NVNtexture *t) { return CTX(t)->off; }
// nvn.h declares a by-value NVNmemoryPool return (a DWARF reconstruction error); it actually returns a pointer: at call site main+0x9c07c4 (2.0.4b) x8 holds the function address before the call,
// not an indirect result pointer, and the returned x0 is passed straight to nvnMemoryPoolMap as the pool pointer
NVN_NOPROTO(nvnTextureGetMemoryPool, const NVNmemoryPool *, const NVNtexture *t) { return (const NVNmemoryPool *)CTX(t)->pool; }
NVN(nvnTextureGetDebugID, uint64_t, const NVNtexture *t) { return CTX(t)->serial; }
NVN(nvnTextureGetZCullStorageSize, size_t, const NVNtexture *t) { (void)t; return ZCULL_SIZE; }
NVN(nvnTextureCompare, NVNboolean, const NVNtexture *a, const NVNtexture *b) {
    const tex_t *x = CTX(a), *y = CTX(b);
    return !memcmp(&x->d, &y->d, sizeof x->d) && x->mem == y->mem;
}
// No prototype in the header; call sites such as main 0x174899c compare the return value with 1 and set some status bit 0x100 if not equal. Meaning unverified; return 1 for now
NVN_NOPROTO(nvnTextureGetRawStorageClass, int, const NVNtexture *t) { (void)t; return 1; }
#define VW(v) ((view_t *)(v))
NVN(nvnTextureViewSetDefaults, void, NVNtextureView *v) { memset(v, 0, sizeof(view_t)); }
NVN(nvnTextureViewSetLevels, void, NVNtextureView *v, int base, int n) { VW(v)->set_levels = 1; VW(v)->base_level = base; VW(v)->nlevels = n; }
NVN(nvnTextureViewSetLayers, void, NVNtextureView *v, int min, int n) { VW(v)->set_layers = 1; VW(v)->min_layer = min; VW(v)->nlayers = n; }
NVN(nvnTextureViewSetFormat, void, NVNtextureView *v, NVNformat f) { VW(v)->set_format = 1; VW(v)->format = f; }
NVN(nvnTextureViewSetTarget, void, NVNtextureView *v, NVNtextureTarget t) { VW(v)->set_target = 1; VW(v)->target = t; }
// View swizzle (TotK main 0x531d20): a view property set explicitly replaces the texture's, and only the ones left unset come from the texture
// (NVN reference, nvn::TextureView), so even an identity swizzle set here overrides a swizzled texture. Applied where the texture pool entry's
// view is built (nvn_mtl.m tex_by_id). Stencil mode is not modelled (TotK sets depth only)
NVN(nvnTextureViewSetSwizzle, void, NVNtextureView *v, NVNtextureSwizzle r, NVNtextureSwizzle g, NVNtextureSwizzle bl, NVNtextureSwizzle a) {
    if ((unsigned)r > 5 || (unsigned)g > 5 || (unsigned)bl > 5 || (unsigned)a > 5) { LOG("[red] TextureViewSetSwizzle %d %d %d %d: not a swizzle value, ignored", (int)r, (int)g, (int)bl, (int)a); return; }
    VW(v)->set_swz = 1; VW(v)->swz_r = r; VW(v)->swz_g = g; VW(v)->swz_b = bl; VW(v)->swz_a = a;
}
NVN(nvnTextureViewSetDepthStencilMode, void, NVNtextureView *v, NVNtextureDepthStencilMode m) {
    (void)v; if (m) { static int once; if (!once++) LOG("[red] TextureViewSetDepthStencilMode %d: views read depth", (int)m); }
}
NVN(nvnTextureViewGetLayers, NVNboolean, const NVNtextureView *v, int *min, int *n) {
    const view_t *o = (const view_t *)v; *min = o->min_layer; *n = o->nlayers; return o->set_layers;
}
NVN(nvnTextureGetViewOffset, ptrdiff_t, const NVNtexture *t, const NVNtextureView *v) {
    const tex_t *o = CTX(t); const view_t *w = (const view_t *)v;
    if (!w) return 0;
    uint64_t off = w->set_levels ? nvn_tex_level_offset(&o->d, (unsigned)w->base_level) : 0;
    if (w->set_layers) off += (uint64_t)w->min_layer * o->layer_size;
    return (ptrdiff_t)off;
}
// CPU texture read (NVN ReadTexels): for packaged textures the pool memory is the ground truth (de-layout and read directly); GPU-written textures are read back from the MTLTexture (nvn_mtl.m)
static void read_texels(const tex_t *o, const view_t *v, const NVNcopyRegion *r, uint8_t *dst, ptrdiff_t row, ptrdiff_t img) {
    int bw, bh, bpb = nvn_fmt_bpb(o->d.format, &bw, &bh);
    uint32_t wb = (uint32_t)((r->width + bw - 1) / bw) * bpb, hb = (uint32_t)(r->height + bh - 1) / bh;
    if (!row) row = wb;
    if (!img) img = row * hb;
    unsigned level = v && v->set_levels ? (unsigned)v->base_level : 0, layer0 = v && v->set_layers ? (unsigned)v->min_layer : 0;
    mtl_read_texels(o, level, layer0, r, dst, (size_t)row, (size_t)img);
}
// One thread at a time in the Metal layer: its submission state (current command buffer, blit encoder, render state) and the texel paths are not
// locked against each other. Manosaba calls SubmitCommands / PresentTexture / Read|WriteTexels from one thread, TotK writes texels from its
// ModuleSystemWorker threads while the Presentation Thread submits (a crash inside a copy encoder at a scene load had been seen on the Mac with the
// earlier check-only version), so these entries take one recursive lock. The first wait is logged once, naming both threads.
__attribute__((weak)) int thr_name_of(pthread_t pt, char *out, size_t n) { (void)pt; (void)out; (void)n; return 0; }   // host hle_thread.c (guest thread names); the graphics unit tests have none
// A guest thread waiting here (GPU, display, replay, shader loading) gives its virtual core back meanwhile (host hle_thread.c, game.json virtual_cores; as
// MacNativeGames' NVN_BLOCKING). Weak defaults for the graphics unit tests, which have no guest threads
__attribute__((weak)) int dm_core_away(void) { return 0; }
__attribute__((weak)) void dm_core_back(int *away) { (void)away; }
#define NVN_BLOCKING() __attribute__((cleanup(dm_core_back))) int nvn_core_away_ = dm_core_away()
static pthread_mutex_t g_gfx_mu; static pthread_once_t g_gfx_mu_once = PTHREAD_ONCE_INIT;
static uint64_t g_gfx_tid; static const char *g_gfx_what; static char g_gfx_name[96];   // the holder (written under the lock)
static void gfx_mu_init(void) { pthread_mutexattr_t a; pthread_mutexattr_init(&a); pthread_mutexattr_settype(&a, PTHREAD_MUTEX_RECURSIVE); pthread_mutex_init(&g_gfx_mu, &a); pthread_mutexattr_destroy(&a); }
static void gfx_mt_enter(const char *what) {
    pthread_once(&g_gfx_mu_once, gfx_mu_init);
    if (pthread_mutex_trylock(&g_gfx_mu)) {
        static _Atomic int said;
        if (!atomic_exchange(&said, 1)) {   // the holder's fields may be mid-update: diagnostics only
            uint64_t me; pthread_threadid_np(NULL, &me); char nm[96] = "-"; thr_name_of(pthread_self(), nm, sizeof nm);
            LOG("[nvn] %s on thread %llu (%s) waits for %s on thread %llu (%s): Metal layer entries are serialized", what, (unsigned long long)me, nm, g_gfx_what ? g_gfx_what : "?", (unsigned long long)g_gfx_tid, g_gfx_name);
        }
        pthread_mutex_lock(&g_gfx_mu);
    }
    pthread_threadid_np(NULL, &g_gfx_tid); g_gfx_what = what; if (!thr_name_of(pthread_self(), g_gfx_name, sizeof g_gfx_name)) strcpy(g_gfx_name, "-");
}
static void gfx_mt_leave(void) { pthread_mutex_unlock(&g_gfx_mu); }
NVN(nvnTextureReadTexels, void, const NVNtexture *t, const NVNtextureView *v, const NVNcopyRegion *r, void *dst) {
    gfx_mt_enter("ReadTexels"); read_texels(CTX(t), (const view_t *)v, r, dst, 0, 0); gfx_mt_leave();
}
NVN(nvnTextureReadTexelsStrided, void, const NVNtexture *t, const NVNtextureView *v, const NVNcopyRegion *r, void *dst, ptrdiff_t row, ptrdiff_t img) {
    gfx_mt_enter("ReadTexelsStrided"); read_texels(CTX(t), (const view_t *)v, r, dst, row, img); gfx_mt_leave();
}
NVN(nvnTextureInvalidateTexels, void, const NVNtexture *t, const NVNtextureView *v, const NVNcopyRegion *r) { (void)t; (void)v; (void)r; }
// CPU texture write (NVN WriteTexels): stride 0 = tightly packed (same as ReadTexels)
static void write_texels(const tex_t *o, const view_t *v, const NVNcopyRegion *r, const uint8_t *src, ptrdiff_t row, ptrdiff_t img) {
    int bw, bh, bpb = nvn_fmt_bpb(o->d.format, &bw, &bh);
    uint32_t wb = (uint32_t)((r->width + bw - 1) / bw) * bpb, hb = (uint32_t)(r->height + bh - 1) / bh;
    if (!row) row = wb;
    if (!img) img = row * hb;
    unsigned level = v && v->set_levels ? (unsigned)v->base_level : 0, layer0 = v && v->set_layers ? (unsigned)v->min_layer : 0;
    mtl_write_texels(o, level, layer0, r, src, (size_t)row, (size_t)img);
}
NVN(nvnTextureWriteTexels, void, const NVNtexture *t, const NVNtextureView *v, const NVNcopyRegion *r, const void *src) {
    gfx_mt_enter("WriteTexels"); write_texels(CTX(t), (const view_t *)v, r, src, 0, 0); gfx_mt_leave();
}
NVN(nvnTextureWriteTexelsStrided, void, const NVNtexture *t, const NVNtextureView *v, const NVNcopyRegion *r, const void *src, ptrdiff_t row, ptrdiff_t img) {
    gfx_mt_enter("WriteTexelsStrided"); write_texels(CTX(t), (const view_t *)v, r, src, row, img); gfx_mt_leave();
}
NVN(nvnTextureFlushTexels, void, const NVNtexture *t, const NVNtextureView *v, const NVNcopyRegion *r) { (void)t; (void)v; (void)r; }

// ---------- Samplers ----------
#define SB(b) (&((samp_builder_t *)(b))->p)
NVN(nvnSamplerBuilderSetDefaults, void, NVNsamplerBuilder *b) {
    NVNdevice *dev = ((samp_builder_t *)b)->dev; memset(b, 0, sizeof(samp_builder_t)); ((samp_builder_t *)b)->dev = dev;
    samp_par *o = SB(b);
    o->minf = NVN_MIN_FILTER_NEAREST_MIPMAP_LINEAR; o->magf = NVN_MAG_FILTER_LINEAR;   // GL defaults
    o->ws = o->wt = o->wr = NVN_WRAP_MODE_REPEAT; o->cmp_func = NVN_COMPARE_FUNC_LESS;
    o->lod_min = -1000.f; o->lod_max = 1000.f; o->aniso = 1.f;
}
NVN(nvnSamplerBuilderSetDevice, void, NVNsamplerBuilder *b, NVNdevice *d) { ((samp_builder_t *)b)->dev = d; }
NVN(nvnSamplerBuilderSetMinMagFilter, void, NVNsamplerBuilder *b, NVNminFilter mi, NVNmagFilter ma) { SB(b)->minf = mi; SB(b)->magf = ma; }
NVN(nvnSamplerBuilderSetWrapMode, void, NVNsamplerBuilder *b, NVNwrapMode s, NVNwrapMode t, NVNwrapMode r) { SB(b)->ws = s; SB(b)->wt = t; SB(b)->wr = r; }
NVN(nvnSamplerBuilderSetLodClamp, void, NVNsamplerBuilder *b, float lo, float hi) { SB(b)->lod_min = lo; SB(b)->lod_max = hi; }
NVN(nvnSamplerBuilderSetLodBias, void, NVNsamplerBuilder *b, float v) { SB(b)->lod_bias = v; }
NVN(nvnSamplerBuilderSetCompare, void, NVNsamplerBuilder *b, NVNcompareMode m, NVNcompareFunc f) { SB(b)->cmp_mode = m; SB(b)->cmp_func = f; }
NVN(nvnSamplerBuilderSetBorderColor, void, NVNsamplerBuilder *b, const float *c) { memcpy(SB(b)->border, c, 16); }
// Min / max reduction: MTLSamplerDescriptor.reductionMode from macOS / iOS 26 (samp_by_id; GirlNet's Persona 5 Royal branch 0293081, lordran-native
// 0a35532). Before that it averages, reported once there
NVN(nvnSamplerBuilderSetReductionFilter, void, NVNsamplerBuilder *b, NVNsamplerReduction r) {
    if ((unsigned)r > NVN_SAMPLER_REDUCTION_MAX) { LOG("[red] SamplerBuilderSetReductionFilter %d: not a reduction, averaging", (int)r); r = NVN_SAMPLER_REDUCTION_AVERAGE; }
    SB(b)->reduction = (uint8_t)r;
}
NVN(nvnSamplerBuilderSetMaxAnisotropy, void, NVNsamplerBuilder *b, float v) { SB(b)->aniso = v; }
NVN(nvnSamplerBuilderSetLodSnap, void, NVNsamplerBuilder *b, float v) { (void)b; (void)v; }   // No Metal equivalent, ignored
NVN(nvnSamplerBuilderGetMinMagFilter, void, const NVNsamplerBuilder *b, NVNminFilter *mi, NVNmagFilter *ma) {
    const samp_par *o = &((const samp_builder_t *)b)->p; *mi = (NVNminFilter)o->minf; *ma = (NVNmagFilter)o->magf;
}
NVN(nvnSamplerBuilderGetWrapMode, void, const NVNsamplerBuilder *b, NVNwrapMode *s, NVNwrapMode *t, NVNwrapMode *r) {
    const samp_par *o = &((const samp_builder_t *)b)->p; *s = (NVNwrapMode)o->ws; *t = (NVNwrapMode)o->wt; *r = (NVNwrapMode)o->wr;
}
NVN(nvnSamplerInitialize, NVNboolean, NVNsampler *s, const NVNsamplerBuilder *b) {
    samp_t *o = (samp_t *)s; o->magic = MAGIC('S', 'M', 'P', 0); o->p = ((const samp_builder_t *)b)->p; return 1;
}
NVN(nvnSamplerFinalize, void, NVNsampler *s) { ((samp_t *)s)->magic = 0; }

// ---------- Programs ----------
NVN(nvnProgramInitialize, NVNboolean, NVNprogram *p, NVNdevice *d) {
    (void)d; memset(p, 0, sizeof(prog_t)); ((prog_t *)p)->magic = MAGIC('P', 'R', 'O', 'G'); return 1;
}
NVN(nvnProgramFinalize, void, NVNprogram *p) { mtl_prog_release((prog_t *)p); ((prog_t *)p)->magic = 0; }
// Shader key = the first 8 bytes of sha256(the 0x880-byte control section + the code area), the code area being the length at control +0x704 read
// from data. The replay layer looks libraries up by it (16 hex digits); the offline tools name captures by it (shmap_from_capture.py, dmsh_build.py,
// engines/unity/shader_extract.py). The control section alone does not identify a shader: it holds sizes and resource counts but no hash of the
// code. Tears of the Kingdom showed 488 more code areas than its 2704 control sections in the first minute from boot, among them its bloom
// upsampling shader (sample × c[3][0x60]) behind the same control section as one that adds c[3][0x20]; the build kept whichever was captured
// first, so the bloom added a matrix row of an earlier pass and the title picture turned red. Same definition as nxnative's keys_hash (seedds, MIT).
#include <CommonCrypto/CommonDigest.h>
#include <sys/stat.h>
static void shader_key(const NVNshaderData *sd, uint8_t key[8]) {
    uint32_t len = *(const uint32_t *)((const uint8_t *)sd->control + 0x704);
    uint8_t md[CC_SHA256_DIGEST_LENGTH]; CC_SHA256_CTX h; CC_SHA256_Init(&h);
    CC_SHA256_Update(&h, sd->control, 0x880);
    if (sd->data && len && len < (1u << 24)) CC_SHA256_Update(&h, (const void *)(uintptr_t)sd->data, len);
    CC_SHA256_Final(md, &h); memcpy(key, md, 8);
}
// DM_SHDUMP=directory (sampling for offline translation): for each new shader write <key>.ctl (the 0x880-byte control section) and <key>.data (from data: 0x30 + the length recorded at control +0x704 + 0x100 bytes).
static void shdump(const NVNshaderData *sd) {
    static const char *dir; static int init; if (!init) { dir = getenv("DM_SHDUMP"); init = 1; if (dir) mkdir(dir, 0755); }
    if (!dir || !sd->control) return;
    uint8_t md[8]; shader_key(sd, md); char key[17]; for (int i = 0; i < 8; i++) snprintf(key + 2 * i, 3, "%02x", md[i]);
    char p[1200]; snprintf(p, sizeof p, "%s/%s.ctl", dir, key);
    if (!access(p, F_OK)) return;
    uint32_t len = *(const uint32_t *)((const uint8_t *)sd->control + 0x704);
    FILE *f = fopen(p, "wb"); if (!f) return; fwrite(sd->control, 1, 0x880, f); fclose(f);
    snprintf(p, sizeof p, "%s/%s.data", dir, key);
    if ((f = fopen(p, "wb"))) { fwrite((const void *)sd->data, 1, 0x30 + (size_t)len + 0x100, f); fclose(f); }
}
// Shader stage: a graphics code area starts with the 78563412 marker + 0x30 header, then the first SPH word has type bits 0–4 (1 = VTG, 2 = pixel) and shader type bits 10–13 (1 = vertex, 5 = pixel);
// no marker = compute (data is bare instructions). Same test as the offline shmap_from_capture.py / dmsh_build.py. Needed when BindProgram attaches a program per stage bit (see nvn_mtl.m prog_bind)
static uint8_t shader_stage(const NVNshaderData *sd) {
    const uint8_t *d = (const uint8_t *)sd->data; if (!d) return 0xff;
    if (*(const uint32_t *)d != 0x12345678u) return 5;
    uint32_t w0 = *(const uint32_t *)(d + 0x30);
    if ((w0 & 0x1f) == 1 && ((w0 >> 10) & 0xf) == 1) return 0;
    if ((w0 & 0x1f) == 2 && ((w0 >> 10) & 0xf) == 5) return 1;
    static int red; if (!red++) LOG("[red] ProgramSetShaders: SPH first word %#x is not vertex / pixel (tessellation / geometry shaders not supported)", w0);
    return 0xff;
}
NVN(nvnProgramSetShaders, NVNboolean, NVNprogram *p, int n, const NVNshaderData *sd) {
    NVN_BLOCKING();   // loads / builds shader libraries
    prog_t *o = (prog_t *)p;
    if (n < 0 || n > 6) { LOG("[red] ProgramSetShaders: stage count %d", n); return 0; }
    for (int i = 0; i < n; i++) shdump(&sd[i]);
    mtl_prog_release(o); o->nstage = n; o->serial = nvn_new_serial();
    for (int i = 0; i < n; i++) { shader_key(&sd[i], o->key[i]); o->kstage[i] = shader_stage(&sd[i]); }
    // DM_SHDUMP also records which vertex and pixel shaders the game puts in one program (<dir>/pairs.tsv, one "vertex key<TAB>pixel key" line per
    // new pair): the offline build pads a vertex shader with the outputs its paired pixel shaders read but it does not write (dmsh_build.py vs_pad;
    // Metal refuses to link such a pair). Duplicates are filtered here as long as the process runs; the build deduplicates the file anyway
    { static const char *dir; static int init; static nvn_hmap seen; static pthread_mutex_t mu = PTHREAD_MUTEX_INITIALIZER;
      if (!init) { dir = getenv("DM_SHDUMP"); init = 1; }
      int vs = -1, ps = -1; for (int i = 0; i < n; i++) { if (o->kstage[i] == 0) vs = i; else if (o->kstage[i] == 1) ps = i; }
      if (dir && vs >= 0 && ps >= 0) {
          uint8_t k[16]; memcpy(k, o->key[vs], 8); memcpy(k + 8, o->key[ps], 8);
          pthread_mutex_lock(&mu); if (!seen.klen) nvn_hm_init(&seen, 16);
          if (!nvn_hm_get(&seen, k)) { nvn_hm_put(&seen, k, (void *)1);
              char pth[1200]; snprintf(pth, sizeof pth, "%s/pairs.tsv", dir); FILE *f = fopen(pth, "a");
              if (f) { for (int j = 0; j < 8; j++) fprintf(f, "%02x", o->key[vs][j]); fputc('\t', f); for (int j = 0; j < 8; j++) fprintf(f, "%02x", o->key[ps][j]); fputc('\n', f); fclose(f); } }
          pthread_mutex_unlock(&mu); } }
    OLOG("ProgramSetShaders %p n=%d data0=%#llx", (void *)p, n, n ? (unsigned long long)sd[0].data : 0ull);
    return 1;
}

// ---------- Sync / events ----------
// nvnProgramSetShadersExt (NVN 55; TotK main 0x72ff70): each stage is 0x18 bytes = NVNshaderData {data, control} + one 8-byte extension field. The host
// identifies stages by the control section and does not use the extension: converted to plain NVNshaderData for SetShaders. From nxnative (seedds, MIT)
typedef struct { NVNbufferAddress data; const void *control; uint64_t ext; } shader_data_ext;
NVN_NOPROTO(nvnProgramSetShadersExt, NVNboolean, NVNprogram *p, int n, const shader_data_ext *sd) {
    if (n < 0 || n > 6) { LOG("[red] ProgramSetShadersExt: %d stages", n); return 0; }
    NVNshaderData plain[6];
    for (int i = 0; i < n; i++) {
        plain[i].data = sd[i].data; plain[i].control = sd[i].control;
        if (sd[i].ext) { static int once; if (!once++) LOG("[nvn] ProgramSetShadersExt: extension field %#llx not used by the host", (unsigned long long)sd[i].ext); }
    }
    return h_nvnProgramSetShaders(p, n, plain);
}
NVN(nvnSyncInitialize, NVNboolean, NVNsync *s, NVNdevice *d) { (void)d; *(sync_t *)s = (sync_t){MAGIC('S', 'Y', 'N', 'C'), 0, 0}; return 1; }
NVN(nvnSyncFinalize, void, NVNsync *s) { ((sync_t *)s)->magic = 0; }
// Fence = "all commands previously submitted to the queue have completed": record the fence value of the most recent submit
NVN(nvnQueueFenceSync, void, NVNqueue *q, NVNsync *s, NVNsyncCondition c, int f) { (void)q; (void)c; (void)f; ((sync_t *)s)->fenced = 1; ((sync_t *)s)->fence = mtl_last_fence(); }
// A sync object that was never fenced waits until timeout, as on a real device; a fenced one is released only after the GPU has actually completed up to that fence value
NVN(nvnSyncWait, NVNsyncWaitResult, const NVNsync *s, uint64_t timeout) {
    NVN_BLOCKING();
    const sync_t *o = (const sync_t *)s;
    if (!o->fenced) return NVN_SYNC_WAIT_RESULT_TIMEOUT_EXPIRED;
    if (mtl_wait(o->fence, 0)) return NVN_SYNC_WAIT_RESULT_ALREADY_SIGNALED;
    return mtl_wait(o->fence, timeout) ? NVN_SYNC_WAIT_RESULT_CONDITION_SATISFIED : NVN_SYNC_WAIT_RESULT_TIMEOUT_EXPIRED;
}
NVN(nvnEventBuilderSetDefaults, void, NVNeventBuilder *b) { memset(b, 0, sizeof(ev_builder_t)); }
NVN(nvnEventBuilderSetStorage, void, NVNeventBuilder *b, const NVNmemoryPool *p, int64_t off) { *(ev_builder_t *)b = (ev_builder_t){(const pool_t *)p, off}; }
NVN(nvnEventInitialize, NVNboolean, NVNevent *e, const NVNeventBuilder *b) {
    const ev_builder_t *s = (const ev_builder_t *)b;
    if (!s->pool || !s->pool->mem) { LOG("[red] EventInitialize: no storage"); return 0; }
    *(ev_t *)e = (ev_t){MAGIC('E', 'V', 'N', 'T'), (volatile uint32_t *)(s->pool->mem + s->off)}; return 1;
}
NVN(nvnEventFinalize, void, NVNevent *e) { ((ev_t *)e)->magic = 0; }
NVN(nvnEventGetValue, uint32_t, const NVNevent *e) { return *((const ev_t *)e)->val; }
static void ev_signal(const ev_t *e, int mode, uint32_t v) { if (mode == NVN_EVENT_SIGNAL_MODE_ADD) *e->val += v; else *e->val = v; }
NVN(nvnEventSignal, void, NVNevent *e, NVNeventSignalMode m, uint32_t v) { ev_signal((const ev_t *)e, m, v); }

// ---------- Queue ----------
#define QB(b) ((queue_builder_t *)(b))
NVN(nvnQueueBuilderSetDefaults, void, NVNqueueBuilder *b) {
    NVNdevice *dev = QB(b)->dev; memset(b, 0, sizeof(queue_builder_t)); QB(b)->dev = dev;
    QB(b)->cmd_sz = 65536; QB(b)->comp_sz = 262144; QB(b)->ctl_sz = 16384; QB(b)->flush = 4096;   // Device defaults
}
NVN(nvnQueueBuilderSetDevice, void, NVNqueueBuilder *b, NVNdevice *d) { QB(b)->dev = d; }
NVN(nvnQueueBuilderSetFlags, void, NVNqueueBuilder *b, int f) { QB(b)->flags = f; }
NVN(nvnQueueBuilderSetCommandMemorySize, void, NVNqueueBuilder *b, size_t n) { QB(b)->cmd_sz = n; }
NVN(nvnQueueBuilderSetComputeMemorySize, void, NVNqueueBuilder *b, size_t n) { QB(b)->comp_sz = n; }
NVN(nvnQueueBuilderSetControlMemorySize, void, NVNqueueBuilder *b, size_t n) { QB(b)->ctl_sz = n; }
NVN(nvnQueueBuilderSetCommandFlushThreshold, void, NVNqueueBuilder *b, size_t n) { QB(b)->flush = n; }
// Queue memory: the sum of the command + compute + control blocks rounded to 4 KiB (the host does not use it; the game only needs to allocate this size)
NVN(nvnQueueBuilderGetQueueMemorySize, size_t, const NVNqueueBuilder *b) {
    const queue_builder_t *o = (const queue_builder_t *)b;
    return (o->cmd_sz + o->comp_sz + o->ctl_sz + 4095) & ~(size_t)4095;
}
NVN(nvnQueueBuilderSetQueueMemory, void, NVNqueueBuilder *b, void *m, size_t n) { QB(b)->mem = m; QB(b)->mem_sz = n; }
NVN(nvnQueueInitialize, NVNboolean, NVNqueue *q, const NVNqueueBuilder *b) {
    *(queue_t *)q = (queue_t){MAGIC('Q', 'U', 'E', 'U'), ((const queue_builder_t *)b)->dev, 0};
    OLOG("QueueInitialize %p", (void *)q); return 1;
}
NVN(nvnQueueFinalize, void, NVNqueue *q) { ((queue_t *)q)->magic = 0; }
NVN(nvnQueueGetError, NVNqueueGetErrorResult, NVNqueue *q, NVNqueueErrorInfo *info) {
    (void)q; if (info) memset(info, 0, sizeof *info); return NVN_QUEUE_GET_ERROR_RESULT_GPU_NO_ERROR;
}
NVN(nvnQueueFlush, void, NVNqueue *q) { (void)q; }
// The queue waits on a sync object on the GPU: the host has a single Metal queue executing in submit order and the fence comes from an earlier submission, so the wait holds by construction
NVN(nvnQueueWaitSync, NVNboolean, NVNqueue *q, const NVNsync *s) { (void)q; (void)s; return 1; }
NVN(nvnQueueFinish, void, NVNqueue *q) {
    NVN_BLOCKING(); (void)q; gfx_mt_enter("QueueFinish"); mtl_finish(); gfx_mt_leave(); }

// ---------- Command buffer: record into the game's command memory, perform CPU-visible side effects at submit ----------
#define CB(c) ((cmd_t *)(c))
#define OP_RESERVE 24                             // Always keep enough room at the segment end for one JUMP / END

NVN(nvnCommandBufferInitialize, NVNboolean, NVNcommandBuffer *c, NVNdevice *d) {
    memset(c, 0, sizeof(cmd_t)); CB(c)->magic = MAGIC('C', 'M', 'D', 'B'); CB(c)->dev = d; return 1;
}
NVN(nvnCommandBufferFinalize, void, NVNcommandBuffer *c) { CB(c)->magic = 0; }
NVN(nvnCommandBufferSetMemoryCallback, void, NVNcommandBuffer *c, PFNNVNCOMMANDBUFFERMEMORYCALLBACKPROC cb) { CB(c)->cb = cb; }
// bool argument: only the low 8 bits count (Switch callers do not extend it)
NVN_NOPROTO(nvnCommandBufferSetCommandMemoryCallbackEnabled, void, NVNcommandBuffer *c, unsigned on) { CB(c)->cb_off = !(on & 0xff); }
NVN(nvnCommandBufferSetMemoryCallbackData, void, NVNcommandBuffer *c, void *d) { CB(c)->cb_data = d; }
static uint8_t *align8(uint8_t *p) { return (uint8_t *)(((uintptr_t)p + 7) & ~(uintptr_t)7); }
// Diagnostic DM_NVN_CMDSTAT=1: every 300 frames log one line of command recording usage -- how many bytes / records were recorded per frame, how large a command memory segment the game gives each time, how many out-of-memory callbacks per frame, how many host-supplied segments,
// and the count and bytes of each command type (to find "how much larger our records are than real-device commands"). Counts only; does not change recording / replay
static struct { int on; uint64_t bytes, recs, grants, grant_bytes, grant_min, grant_max, cbs, hostseg, op_n[64], op_b[64], frame0, waste; } g_cs = { .on = -1 };
static pthread_mutex_t g_cs_mu = PTHREAD_MUTEX_INITIALIZER;
uint64_t dm_nvn_frame_count(void);
static int cs_on(void) { if (g_cs.on < 0) g_cs.on = getenv("DM_NVN_CMDSTAT") != NULL; return g_cs.on; }
static void cs_op(uint32_t op, uint32_t size) { if (!cs_on() || op >= 64) return; pthread_mutex_lock(&g_cs_mu); g_cs.op_n[op]++; g_cs.op_b[op] += size; pthread_mutex_unlock(&g_cs_mu); }
static void cs_dump(void) {   // Called once per frame (at present)
    if (!cs_on()) return; uint64_t f = dm_nvn_frame_count(); if (f - g_cs.frame0 < 300) return;
    pthread_mutex_lock(&g_cs_mu); double n = (double)(f - g_cs.frame0); char top[700]; int k = 0; uint8_t used[64] = {0};
    for (int r = 0; r < 8; r++) { int bi = -1; for (int i = 0; i < 64; i++) if (!used[i] && g_cs.op_b[i] && (bi < 0 || g_cs.op_b[i] > g_cs.op_b[bi])) bi = i; if (bi < 0) break; used[bi] = 1;
        k += snprintf(top + k, sizeof top - k, " op%d: %.0f recs x %.0f bytes=%.1f KB;", bi, g_cs.op_n[bi] / n, (double)g_cs.op_b[bi] / (double)g_cs.op_n[bi], g_cs.op_b[bi] / n / 1024.0); }
    LOG("[nvn] command memory up to frame %llu: recorded per frame %.1f KB / %.0f recs; game segments per frame %.2f, avg %.1f KB each (min %.1f / max %.1f); out-of-memory callbacks per frame %.2f; host segments per frame %.3f; segment tails discarded on switch per frame %.1f KB | per frame:%s",
        (unsigned long long)f, g_cs.bytes / n / 1024.0, g_cs.recs / n, g_cs.grants / n, g_cs.grants ? g_cs.grant_bytes / (double)g_cs.grants / 1024.0 : 0, g_cs.grant_min / 1024.0, g_cs.grant_max / 1024.0, g_cs.cbs / n, g_cs.hostseg / n, g_cs.waste / n / 1024.0, top);
    int on = g_cs.on; memset(&g_cs, 0, sizeof g_cs); g_cs.on = on; g_cs.frame0 = f; pthread_mutex_unlock(&g_cs_mu);
}
static void put_hdr(uint8_t *p, uint32_t op, uint32_t size) { op_hdr h = {op, size}; memcpy(p, &h, sizeof h); if (op) cs_op(op, size); }
// While recording, link the old segment to the next one with a JUMP at the write position. The JUMP counts as used: the game places what it
// records next after the bytes GetCommandMemoryUsed reports, and a JUMP left outside them was overwritten (its target first: the case where only
// END went on to the next segment reported 8 bytes less than the recording took)
static void cmd_link(cmd_t *o, uint8_t *to) {
    if (cs_on() && o->end > o->cur) { pthread_mutex_lock(&g_cs_mu); g_cs.waste += (uint64_t)(o->end - o->cur); pthread_mutex_unlock(&g_cs_mu); }
    put_hdr(o->cur, OP_JUMP, 16); memcpy(o->cur + 8, &to, 8); o->used += 16;
}
// New segment of the game's command memory
static void cmd_new_segment(cmd_t *o, uint8_t *mem, size_t n) {
    uint8_t *start = align8(mem), *end = mem + n;
    if (o->recording && o->cur) cmd_link(o, start);
    o->cur = start; o->end = end;
}
// Host-supplied segment when the game's own command memory runs out: when the game's out-of-memory callback cannot allocate from its command memory pool, it calls AddCommandMemory with an empty pool (p = NULL, n = 0)
// (opening the advanced stats page on the level 88 sorceress save: many list items in one frame, and the original implementation segfaulted here reading NULL+8). Our records are larger than real-device NVN commands, so the budget the game reserved for real-device usage is not necessarily enough,
// so this is not an error state of the game but something we must catch: provide a segment of host memory to keep recording; the segment is replayed in place at submit.
// Reclaim follows the game's command memory, not a frame count (nxnative, seedds, MIT): a game may keep a recorded command handle and CALL it every frame until it records it again, so a segment reclaimed
// 8 frames after lending was rewritten while still in use (nxnative saw it in Super Mario Bros. Wonder). A segment is linked from one place, the JUMP the recording wrote when it ran out of room, and lives
// as long as that JUMP: it sits in the game's command memory (or in the host segment the recording overflowed from) within the bytes GetCommandMemoryUsed reported, which the game writes over only once
// the recording is dead. So a segment is free once its JUMP is gone: overwritten, in a memory pool that no longer exists, or in a host segment that is free or was taken again. A segment a recording began
// in (an empty pool given before BeginRecording) has no JUMP and is kept. Reclaiming when the game merely gave out memory overlapping the recording (until 2026-10-18) freed live segments: Tears of the
// Kingdom gives each per-draw recording a 512-byte window at slot + used, which reaches into the next slots' recordings; a later recording took the segment, and its binds became the tail of a cached
// draw handle the game calls every other frame (in the prologue the wrong skeleton buffer, and Zelda's cloak and face alternated). The pool grows on demand; abort only beyond HOSTSEG_CAP in total.
#define HOSTSEG_SZ (256u << 10)
#define HOSTSEG_CAP (1u << 30)
uint64_t dm_nvn_frame_count(void);
// jump_at: the JUMP linking it (0 = none); parent: the host segment that JUMP is in (-1 = game memory) and that segment's gen at the time (gen counts takes)
typedef struct { uint8_t *mem; uintptr_t jump_at; int busy, parent; uint32_t gen, parent_gen; } hostseg_t;
static hostseg_t *g_hostseg; static int g_nhostseg, g_caphostseg;
static uint64_t g_hostseg_freed;   // segments found free because their JUMP was gone
static pthread_mutex_t g_hostseg_mu = PTHREAD_MUTEX_INITIALIZER;
static int hostseg_linked(int i, int depth) {   // g_hostseg_mu held
    const hostseg_t *s = &g_hostseg[i];
    if (!s->busy) return 0;
    if (!s->jump_at) return 1;
    if (s->parent >= 0) { if (depth > 64 || g_hostseg[s->parent].gen != s->parent_gen || !hostseg_linked(s->parent, depth + 1)) return 0; }
    else if (!mtl_pool_has(s->jump_at, 16)) return 0;   // its pool is gone (and the memory may be too: read only inside a live pool)
    op_hdr h; uint64_t to; memcpy(&h, (const void *)s->jump_at, sizeof h); memcpy(&to, (const void *)(s->jump_at + 8), 8);
    return h.op == OP_JUMP && h.size == 16 && to == (uint64_t)(uintptr_t)s->mem;
}
// Continue o in a host segment: a free one, else one whose JUMP is gone, else a new one; linked from the write position under the lock (no other
// thread sees it taken but not yet linked)
static void cmd_host_segment(cmd_t *o) {
    static unsigned total; uint64_t f = dm_nvn_frame_count();
    uintptr_t at = o->recording && o->cur ? (uintptr_t)o->cur : 0;
    pthread_mutex_lock(&g_hostseg_mu);
    int parent = -1, k = -1;
    for (int i = 0; i < g_nhostseg && at; i++) if (at >= (uintptr_t)g_hostseg[i].mem && at < (uintptr_t)g_hostseg[i].mem + HOSTSEG_SZ) { parent = i; break; }
    for (int i = 0; i < g_nhostseg && k < 0; i++) if (!g_hostseg[i].busy) k = i;
    if (k < 0)   // sweep: free every segment whose JUMP is gone (a segment freed here frees the ones it links at the next sweep)
        for (int i = 0; i < g_nhostseg; i++) if (i != parent && g_hostseg[i].busy && !hostseg_linked(i, 0)) { g_hostseg[i].busy = 0; g_hostseg_freed++; if (k < 0) k = i; }
    if (k < 0 && (uint64_t)(g_nhostseg + 1) * HOSTSEG_SZ <= HOSTSEG_CAP) {
        if (g_nhostseg == g_caphostseg) { g_caphostseg = g_caphostseg ? g_caphostseg * 2 : 64; g_hostseg = realloc(g_hostseg, sizeof *g_hostseg * (size_t)g_caphostseg); }
        uint8_t *m = malloc(HOSTSEG_SZ); if (!m) die("NVN command memory: host segment allocation failed");
        g_hostseg[g_nhostseg] = (hostseg_t){ m, 0, 0, -1, 0, 0 }; k = g_nhostseg++;
    }
    if (k < 0) die("NVN command memory: game pool empty and %u MB of host segments all linked from live recordings", HOSTSEG_CAP >> 20);
    hostseg_t *s = &g_hostseg[k];
    s->busy = 1; s->gen++; s->jump_at = at; s->parent = parent; s->parent_gen = parent >= 0 ? g_hostseg[parent].gen : 0;
    uint8_t *m = s->mem;
    if (at) cmd_link(o, m);
    unsigned t = ++total; int n = g_nhostseg; uint64_t freed = g_hostseg_freed;
    pthread_mutex_unlock(&g_hostseg_mu);
    o->cur = m; o->end = m + HOSTSEG_SZ;
    if (t == 1 || t % 1024 == 0) LOG("[nvn] game command memory short, host segment supplied (total %u, frame %llu, pool %d x %u KB, %llu freed by their JUMP being gone)", t, (unsigned long long)f, n, HOSTSEG_SZ >> 10, (unsigned long long)freed);
}
NVN(nvnCommandBufferAddCommandMemory, void, NVNcommandBuffer *c, const NVNmemoryPool *p, ptrdiff_t off, size_t n) {
    const pool_t *pl = (const pool_t *)p;
    if (!pl || n < 64) { if (cs_on()) { pthread_mutex_lock(&g_cs_mu); g_cs.hostseg++; pthread_mutex_unlock(&g_cs_mu); } cmd_host_segment(CB(c)); return; }
    if (!pl->mem) { LOG("[red] AddCommandMemory: pool has no CPU storage"); return; }
    if (cs_on()) { pthread_mutex_lock(&g_cs_mu); g_cs.grants++; g_cs.grant_bytes += n; if (!g_cs.grant_min || n < g_cs.grant_min) g_cs.grant_min = n; if (n > g_cs.grant_max) g_cs.grant_max = n; pthread_mutex_unlock(&g_cs_mu); }
    cmd_new_segment(CB(c), pl->mem + off, n);
}
NVN(nvnCommandBufferAddControlMemory, void, NVNcommandBuffer *c, void *m, size_t n) { (void)c; (void)m; (void)n; }
// Get space for one record; if not enough, call back into the game per the NVN convention to add command memory
static uint8_t *cmd_alloc(cmd_t *o, uint32_t size) {
    size = (size + 7) & ~7u;
    for (int tries = 0; !o->cur || o->cur + size + OP_RESERVE > o->end; tries++) {
        // Callback turned off (TotK main 0xbb5a0): the game sized this buffer's memory for console commands, which are smaller than our records, and will not be
        // asked for more; the host supplies a segment, as for an empty pool
        // or the callback cannot supply enough (newer-SDK games hand out small chunks sized for console commands): continue in a host segment (nxnative)
        if (o->cb_off || !o->cb || tries == 2) {
            if (size + OP_RESERVE > HOSTSEG_SZ) die("NVN record of %u bytes does not fit a host segment", size);
            if (!o->cb_off) { static int once; if (!once++) LOG("[nvn] command memory: the game's callback cannot supply enough (cb=%p, %u bytes needed), host segments instead", (void *)o->cb, size + OP_RESERVE); }
            cmd_host_segment(o); break;
        }
        if (cs_on()) { pthread_mutex_lock(&g_cs_mu); g_cs.cbs++; pthread_mutex_unlock(&g_cs_mu); }
        o->cb((NVNcommandBuffer *)o, NVN_COMMAND_BUFFER_MEMORY_EVENT_OUT_OF_COMMAND_MEMORY, size + OP_RESERVE, o->cb_data);
    }
    if (cs_on()) { pthread_mutex_lock(&g_cs_mu); g_cs.bytes += size; g_cs.recs++; pthread_mutex_unlock(&g_cs_mu); }
    o->used += size;
    uint8_t *p = o->cur; o->cur += size; put_hdr(p, 0, size); return p;
}
NVN(nvnCommandBufferBeginRecording, void, NVNcommandBuffer *c) {
    cmd_t *o = CB(c);
    if (o->recording) LOG("[red] BeginRecording re-entered");
    o->recording = 1; o->used = 0;
    uint8_t *p = cmd_alloc(o, 8); put_hdr(p, OP_BEGIN, 8); o->begin = p;
}
// Memory used by this recording (TotK main 0x8c7ccc asks after recording; nxnative found that a game treats 0 as an empty recording): record bytes over all
// segments and the JUMPs linking them (cmd_link); the host uses no control memory
NVN(nvnCommandBufferGetCommandMemoryUsed, size_t, const NVNcommandBuffer *c) { const cmd_t *m = (const cmd_t *)c; return m->begin ? (size_t)m->used : 0; }
NVN(nvnCommandBufferGetControlMemoryUsed, size_t, const NVNcommandBuffer *c) { (void)c; return 0; }
NVN(nvnCommandBufferEndRecording, NVNcommandHandle, NVNcommandBuffer *c) {
    cmd_t *o = CB(c);
    uint8_t *p = cmd_alloc(o, 8); put_hdr(p, OP_END, 8);
    o->recording = 0;
    return (NVNcommandHandle)o->begin;
}
NVN(nvnCommandBufferIsRecording, NVNboolean, const NVNcommandBuffer *c) { return ((const cmd_t *)c)->recording != 0; }
NVN(nvnCommandBufferCopyCommands, void, NVNcommandBuffer *c, int n, const NVNcommandHandle *h) {
    for (int i = 0; i < n; i++) { uint8_t *p = cmd_alloc(CB(c), 16); put_hdr(p, OP_CALL, 16); memcpy(p + 8, &h[i], 8); }
}
NVN(nvnCommandBufferCallCommands, void, NVNcommandBuffer *c, int n, const NVNcommandHandle *h) { h_nvnCommandBufferCopyCommands(c, n, h); }   // the replay treats CALL and COPY alike (nxnative); TotK main 0x2d4058
NVN(nvnCommandBufferSignalEvent, void, NVNcommandBuffer *c, const NVNevent *e, NVNeventSignalMode m, NVNeventSignalLocation loc, int flags, uint32_t v) {
    (void)loc; (void)flags;
    uint8_t *p = cmd_alloc(CB(c), 24); put_hdr(p, OP_SIGNAL_EVENT, 24);
    const ev_t *ev = (const ev_t *)e; volatile uint32_t *val = ev->val; uint32_t mm = m;
    memcpy(p + 8, &val, 8); memcpy(p + 16, &mm, 4); memcpy(p + 20, &v, 4);
}
NVN(nvnCommandBufferResetCounter, void, NVNcommandBuffer *c, NVNcounterType t) {
    uint8_t *p = cmd_alloc(CB(c), 16); put_hdr(p, OP_RESET_COUNTER, 16); uint64_t tt = t; memcpy(p + 8, &tt, 8);
}
NVN(nvnCommandBufferReportCounter, void, NVNcommandBuffer *c, NVNcounterType t, NVNbufferAddress a) {
    uint8_t *p = cmd_alloc(CB(c), 24); put_hdr(p, OP_REPORT_COUNTER, 24); uint64_t tt = t; memcpy(p + 8, &tt, 8); memcpy(p + 16, &a, 8);
}
NVN(nvnCommandBufferCopyBufferToBuffer, void, NVNcommandBuffer *c, NVNbufferAddress src, NVNbufferAddress dst, size_t n, int flags) {
    (void)flags;
    uint8_t *p = cmd_alloc(CB(c), 32); put_hdr(p, OP_COPY_B2B, 32); uint64_t nn = n;
    memcpy(p + 8, &src, 8); memcpy(p + 16, &dst, 8); memcpy(p + 24, &nn, 8);
}
// uniform update: the data is copied into command memory at record time (NVN semantics: the caller may modify the original data after recording) and written into the buffer at submit
NVN(nvnCommandBufferUpdateUniformBuffer, void, NVNcommandBuffer *c, NVNbufferAddress buf, size_t bufsz, ptrdiff_t off, size_t n, const void *data) {
    { static int dbg = -1; if (dbg < 0) dbg = getenv("DM_NVN_UBLOG") != NULL;   // diagnostic: the raw arguments
      if (dbg) LOG("[ub] UpdateUniformBuffer buffer=%#llx size=%#zx offset=%#tx n=%#zx", (unsigned long long)buf, bufsz, off, n); }
    uint32_t sz = (uint32_t)(24 + n);
    uint8_t *p = cmd_alloc(CB(c), sz); put_hdr(p, OP_UPDATE_UB, (sz + 7) & ~7u);
    uint64_t dst = buf + off, nn = n; memcpy(p + 8, &dst, 8); memcpy(p + 16, &nn, 8); memcpy(p + 24, data, n);
}

// ---------- Render commands: parameters are recorded into command memory in the payload format of nvn_obj.h; for replay see nvn_mtl.m ----------
static void *rec(NVNcommandBuffer *c, uint32_t op, size_t payload) {
    uint32_t sz = (uint32_t)((8 + payload + 7) & ~(size_t)7);
    uint8_t *p = cmd_alloc(CB(c), sz); put_hdr(p, op, sz);
    memset(p + 8, 0, sz - 8);
    return p + 8;
}
#define REC(c, OP, T) ((T *)rec((c), (OP), sizeof(T)))
// Binding records with arrays are allocated by the actual count: prefix fields + n elements (the replay side reads only the first n). Previously they were recorded at fixed length for the maximum count (bind vertex buffers 272 bytes, bind textures / samplers 280 bytes,
// while there are usually only 1–2 in practice), and the empty tail took 40–50% of the command bytes per frame; the advanced stats page of the level 88 sorceress recorded 12.5 MB per frame, using up the game's own command memory pool (about 105 segments x 128 KB per frame)
#define RECN(c, OP, T, ARR, N) ((T *)rec((c), (OP), offsetof(T, ARR) + sizeof(((T *)0)->ARR[0]) * (size_t)(N)))
static void copy_view(view_t *dst, uint8_t *has, const NVNtextureView *v) { *has = v != NULL; if (v) *dst = *(const view_t *)v; }
NVN(nvnCommandBufferSetRenderTargets, void, NVNcommandBuffer *c, int n, const NVNtexture *const *ct, const NVNtextureView *const *cv,
    const NVNtexture *dt, const NVNtextureView *dv) {
    if (n < 0 || n > 8) { LOG("[red] SetRenderTargets: count %d", n); n = n < 0 ? 0 : 8; }
    { static int rl = -1; if (rl < 0) { const char *e = getenv("DM_RTLOG"); rl = e ? atoi(e) : 0; }   // Diagnostics: arguments of the first N SetRenderTargets calls
      if (rl > 0) { rl--; char b[512]; int k = snprintf(b, sizeof b, "SetRT n=%d", n);
        for (int i = 0; i < n && k < 400; i++) { const tex_t *t = ct ? (const tex_t *)ct[i] : NULL;
            k += snprintf(b + k, sizeof b - k, " c%d=%p", i, (const void *)t); if (t) k += snprintf(b + k, sizeof b - k, "(ser %llu %ux%u fmt %#x mg %#x mem %p pool %p off %#llx)", t->serial, t->d.width, t->d.height, t->d.format, t->magic, (void *)t->mem, (void *)t->pool, (long long)t->off); }
        const tex_t *d = (const tex_t *)dt; k += snprintf(b + k, sizeof b - k, " d=%p", (const void *)d); if (d) snprintf(b + k, sizeof b - k, "(ser %llu %ux%u fmt %#x)", d->serial, d->d.width, d->d.height, d->d.format);
        LOG("[nvn] %s", b);
        if (n > 0 && ct && ct[0] && !((const tex_t *)ct[0])->serial) { static int dumped; if (!dumped++) { const uint8_t *q = (const uint8_t *)ct[0]; char hx[0xC0 * 2 + 1];
            for (int i = 0; i < 0xC0; i++) snprintf(hx + 2 * i, 3, "%02x", q[i]); LOG("[nvn] SetRT color object at index 0, 0xC0 bytes: %s", hx); } } } }

    p_set_rt *r = REC(c, OP_SET_RT, p_set_rt); r->n = n;
    for (int i = 0; i < n; i++) { r->color[i] = ct ? tex_snap(ct[i]) : NULL; copy_view(&r->cview[i], &r->has_cview[i], cv ? cv[i] : NULL); }
    r->depth = tex_snap(dt); copy_view(&r->dview, &r->has_dview, dv);
}
NVN(nvnCommandBufferClearColor, void, NVNcommandBuffer *c, int index, const float *rgba, int mask) {
    p_clear_color *r = REC(c, OP_CLEAR_COLOR, p_clear_color); r->index = index; r->mask = mask; memcpy(r->rgba, rgba, 16);
}
NVN(nvnCommandBufferClearDepthStencil, void, NVNcommandBuffer *c, float depth, uint32_t dmask, int stencil, int smask) {
    p_clear_ds *r = REC(c, OP_CLEAR_DS, p_clear_ds); *r = (p_clear_ds){depth, (int)B(dmask), stencil, smask};
}
NVN(nvnCommandBufferSetViewports, void, NVNcommandBuffer *c, int first, int n, const float *v) {
    if (n < 0 || first + n > 16) { LOG("[red] SetViewports first=%d n=%d", first, n); return; }
    p_viewports *r = REC(c, OP_VIEWPORTS, p_viewports); r->first = first; r->n = n;
    for (int i = 0; i < n; i++) memcpy(r->v[i], v + 4 * i, 16);
}
// Integer single viewport = viewport 0 (same as SetViewports(0, 1, {x, y, w, h}))
NVN(nvnCommandBufferSetViewport, void, NVNcommandBuffer *c, int x, int y, int w, int h) {
    p_viewports *r = REC(c, OP_VIEWPORTS, p_viewports); r->first = 0; r->n = 1;
    r->v[0][0] = (float)x; r->v[0][1] = (float)y; r->v[0][2] = (float)w; r->v[0][3] = (float)h;
}
NVN(nvnCommandBufferSetDepthClamp, void, NVNcommandBuffer *c, uint32_t en) { REC(c, OP_DEPTH_CLAMP, p_depth_clamp)->enable = B(en) != 0; }
NVN(nvnCommandBufferSetPrimitiveRestart, void, NVNcommandBuffer *c, uint32_t en, int index) { p_prim_restart *r = REC(c, OP_PRIM_RESTART, p_prim_restart); r->enable = B(en) != 0; r->index = (uint32_t)index; }   // replay: nvn_mtl.m draw
// Conservative rasterization: no Metal equivalent. Disabling it (Unity's normal case) needs nothing; enabling it is reported red
NVN(nvnCommandBufferSetConservativeRasterEnable, void, NVNcommandBuffer *c, uint32_t en) {
    (void)c; static int red; if (B(en) && !red++) LOG("[red] CommandBufferSetConservativeRasterEnable 1: Metal has no conservative rasterization, drawing with normal rasterization");
}
// Not modelled yet, reported red once when they would change what is drawn: render enable (plain and conditional on a query result) draws always,
// rasterizer discard is ignored. The tiled cache calls are hints for the console's binning rasterizer with no Metal counterpart. (nxnative)
NVN(nvnCommandBufferSetRenderEnable, void, NVNcommandBuffer *c, uint32_t en) { *REC(c, OP_RENDER_ENABLE, p_render_enable) = (p_render_enable){B(en) ? 1 : 0, 0}; }
NVN(nvnCommandBufferSetRenderEnableConditional, void, NVNcommandBuffer *c, NVNconditionalRenderMode m, NVNbufferAddress a) {
    *REC(c, OP_RENDER_ENABLE, p_render_enable) = (p_render_enable){m == NVN_CONDITIONAL_RENDER_MODE_RENDER_IF_EQUAL ? 2 : 3, a};
}
NVN(nvnCommandBufferSetRasterizerDiscard, void, NVNcommandBuffer *c, uint32_t en) {
    (void)c; static int red; if (B(en) && !red++) LOG("[red] CommandBufferSetRasterizerDiscard 1: not modelled, fragments are still drawn");
}
NVN(nvnCommandBufferSetTiledCacheAction, void, NVNcommandBuffer *c, NVNtiledCacheAction a) { (void)c; (void)a; }
NVN(nvnCommandBufferSetTiledCacheTileSize, void, NVNcommandBuffer *c, int w, int h) { (void)c; (void)w; (void)h; }
NVN(nvnCommandBufferSetScissor, void, NVNcommandBuffer *c, int x, int y, int w, int h) { *REC(c, OP_SCISSOR, p_scissor) = (p_scissor){x, y, w, h}; }
NVN(nvnCommandBufferSetDepthRange, void, NVNcommandBuffer *c, float n, float f) { *REC(c, OP_DEPTH_RANGE, p_depth_range) = (p_depth_range){n, f}; }
// The program's shaders as of recording: the console copies them into the command stream, and a game may give the same NVNprogram other shaders
// (ProgramSetShaders again) before the recording is submitted or while it is still replayed. Tears of the Kingdom does (2142 SetShaders), and the
// replay layer, which read the keys through the program pointer at submit, ran a bloom upsample with another program's pixel shader: it read the
// vertex shader's matrix row as its bias and painted the title screen red. So the record points to an immutable copy of the key set, one per
// distinct set, with its own serial (the replay layer resolves programs by serial). Programs without keys (unit-test objects) are recorded as they are
static const prog_t *prog_snapshot(const prog_t *p) {
    if (!p || !p->nstage) return p;
    uint8_t k[1 + 6 * 8 + 6] = {0}; k[0] = (uint8_t)p->nstage; memcpy(k + 1, p->key, sizeof p->key); memcpy(k + 1 + 48, p->kstage, sizeof p->kstage);
    static nvn_hmap snaps; static pthread_mutex_t mu = PTHREAD_MUTEX_INITIALIZER;
    pthread_mutex_lock(&mu);
    if (!snaps.klen) nvn_hm_init(&snaps, sizeof k);
    prog_t *c = nvn_hm_get(&snaps, k);
    if (!c) { c = malloc(sizeof *c); *c = *p; c->magic = MAGIC('P', 'R', 'G', 'S'); c->serial = nvn_new_serial(); nvn_hm_put(&snaps, k, c); }
    pthread_mutex_unlock(&mu);
    return c;
}
NVN(nvnCommandBufferBindProgram, void, NVNcommandBuffer *c, const NVNprogram *p, int stages) {
    *REC(c, OP_BIND_PROGRAM, p_bind_program) = (p_bind_program){prog_snapshot((const prog_t *)p), stages};
}
static void bind_state(NVNcommandBuffer *c, int kind, const void *st, size_t n) { p_bind_state *r = REC(c, OP_BIND_STATE, p_bind_state); r->kind = kind; memcpy(r->bytes, st, n); }
NVN(nvnCommandBufferBindBlendState, void, NVNcommandBuffer *c, const NVNblendState *st) { bind_state(c, 0, st, sizeof(blend_st)); }
NVN(nvnCommandBufferBindColorState, void, NVNcommandBuffer *c, const NVNcolorState *st) { bind_state(c, 1, st, sizeof(color_st)); }
NVN(nvnCommandBufferSetAlphaRef, void, NVNcommandBuffer *c, float ref) { bind_state(c, 6, &ref, sizeof ref); }   // the alpha test's reference (nvn_mtl.m alpha_fn)
NVN(nvnCommandBufferBindChannelMaskState, void, NVNcommandBuffer *c, const NVNchannelMaskState *st) { bind_state(c, 2, st, sizeof(chmask_st)); }
NVN(nvnCommandBufferBindMultisampleState, void, NVNcommandBuffer *c, const NVNmultisampleState *st) { bind_state(c, 3, st, sizeof(ms_st)); }
NVN(nvnCommandBufferBindPolygonState, void, NVNcommandBuffer *c, const NVNpolygonState *st) { bind_state(c, 4, st, sizeof(poly_st)); }
NVN(nvnCommandBufferBindDepthStencilState, void, NVNcommandBuffer *c, const NVNdepthStencilState *st) { bind_state(c, 5, st, sizeof(ds_st)); }
NVN(nvnCommandBufferBindVertexAttribState, void, NVNcommandBuffer *c, int n, const NVNvertexAttribState *st) {
    if (n < 0 || n > 16) { LOG("[red] BindVertexAttribState n=%d", n); return; }
    p_bind_vattr *r = RECN(c, OP_BIND_VATTR, p_bind_vattr, st, n); r->first = 0; r->n = n; memcpy(r->st, st, 4 * n);
}
NVN(nvnCommandBufferBindVertexStreamState, void, NVNcommandBuffer *c, int n, const NVNvertexStreamState *st) {
    if (n < 0 || n > 16) { LOG("[red] BindVertexStreamState n=%d", n); return; }
    p_bind_vstream *r = RECN(c, OP_BIND_VSTREAM, p_bind_vstream, st, n); r->first = 0; r->n = n; memcpy(r->st, st, 8 * n);
}
NVN(nvnCommandBufferBindVertexBuffers, void, NVNcommandBuffer *c, int first, int n, const NVNbufferRange *rg) {
    if (n < 0 || first + n > 16) { LOG("[red] BindVertexBuffers first=%d n=%d", first, n); return; }
    p_bind_vbuf *r = RECN(c, OP_BIND_VBUF, p_bind_vbuf, r, n); r->first = first; r->n = n; memcpy(r->r, rg, sizeof *rg * n);
}
NVN(nvnCommandBufferBindUniformBuffer, void, NVNcommandBuffer *c, NVNshaderStage st, int i, NVNbufferAddress a, size_t n) {
    { static int dbg = -1; if (dbg < 0) dbg = getenv("DM_NVN_UBLOG") != NULL; if (dbg) LOG("[ub] BindUniformBuffer stage %d slot %d %#llx size %#zx", (int)st, i, (unsigned long long)a, n); }
    *REC(c, OP_BIND_UBO, p_bind_buf) = (p_bind_buf){st, i, a, n};
}
NVN(nvnCommandBufferBindUniformBuffers, void, NVNcommandBuffer *c, NVNshaderStage st, int first, int n, const NVNbufferRange *rg) {
    for (int i = 0; i < n; i++) *REC(c, OP_BIND_UBO, p_bind_buf) = (p_bind_buf){st, first + i, rg[i].address, rg[i].size};
}
NVN(nvnCommandBufferBindVertexBuffer, void, NVNcommandBuffer *c, int i, NVNbufferAddress a, size_t n) { NVNbufferRange r = {a, n}; h_nvnCommandBufferBindVertexBuffers(c, i, 1, &r); }   // single form (nxnative)
NVN(nvnCommandBufferBindStorageBuffer, void, NVNcommandBuffer *c, NVNshaderStage st, int i, NVNbufferAddress a, size_t n) {
    *REC(c, OP_BIND_SSBO, p_bind_buf) = (p_bind_buf){st, i, a, n};
}
NVN(nvnCommandBufferBindStorageBuffers, void, NVNcommandBuffer *c, NVNshaderStage st, int first, int n, const NVNbufferRange *rg) {
    for (int i = 0; i < n; i++) *REC(c, OP_BIND_SSBO, p_bind_buf) = (p_bind_buf){st, first + i, rg[i].address, rg[i].size};
}
static p_bind_handles *bind_handles(NVNcommandBuffer *c, int op, int st, int first, int n, const uint64_t *h) {
    if (n < 0 || n > 32) { LOG("[red] bind handle count %d", n); return NULL; }
    p_bind_handles *r = RECN(c, op, p_bind_handles, h, n); r->stage = st; r->first = first; r->n = n; r->defer = 0; r->src = 0; memcpy(r->h, h, 8 * n);
    return r;
}
// Deferred binding: the GPU reads the handles at h when it executes the command, not at recording. TotK main 0x895e8 binds one texture this way through the
// pointer the game got from GetProcAddress; nxnative found BotW's engine binds every texture so and fills / replaces the handle after recording (a copy taken
// at recording gave texture 0 everywhere: the whole 3D picture black). The address is recorded and replay reads it (nvn_mtl.m bh_fresh). From nxnative (seedds, MIT)
NVN_NOPROTO(nvnCommandBufferBindTexturesDeferred, void, NVNcommandBuffer *c, NVNshaderStage st, int first, int n, const NVNtextureHandle *h) {
    p_bind_handles *r = bind_handles(c, OP_BIND_TEX, st, first, n, (const uint64_t *)h);
    if (r && h) { r->defer = 1; r->src = (uint64_t)(uintptr_t)h; }
}
// Image (writable texture): handle = texture pool index (GetImageHandle returns it as-is; the game does not call RegisterImage, images and textures share registration)
NVN(nvnCommandBufferBindImages, void, NVNcommandBuffer *c, NVNshaderStage st, int first, int n, const NVNimageHandle *h) {
    bind_handles(c, OP_BIND_IMG, st, first, n, (const uint64_t *)h);
}
NVN(nvnCommandBufferBindSeparateTextures, void, NVNcommandBuffer *c, NVNshaderStage st, int first, int n, const NVNseparateTextureHandle *h) {
    bind_handles(c, OP_BIND_TEX, st, first, n, (const uint64_t *)h);
}
NVN(nvnCommandBufferBindSeparateSamplers, void, NVNcommandBuffer *c, NVNshaderStage st, int first, int n, const NVNseparateSamplerHandle *h) {
    bind_handles(c, OP_BIND_SAMP, st, first, n, (const uint64_t *)h);
}
NVN(nvnCommandBufferBindTexture, void, NVNcommandBuffer *c, NVNshaderStage st, int i, NVNtextureHandle h) { uint64_t v = (uint64_t)h; bind_handles(c, OP_BIND_TEX, st, i, 1, &v); }   // combined handle, as is (nxnative)
NVN(nvnCommandBufferBindSeparateTexture, void, NVNcommandBuffer *c, NVNshaderStage st, int i, NVNseparateTextureHandle h) {
    bind_handles(c, OP_BIND_TEX, st, i, 1, &h.value);
}
NVN(nvnCommandBufferBindSeparateSampler, void, NVNcommandBuffer *c, NVNshaderStage st, int i, NVNseparateSamplerHandle h) {
    bind_handles(c, OP_BIND_SAMP, st, i, 1, &h.value);
}
// Line width: Metal draws lines one pixel wide; anything else is reported once (TotK main 0x83a28)
NVN(nvnCommandBufferSetLineWidth, void, NVNcommandBuffer *c, float w) { (void)c; if (w != 1.0f) { static int once; if (!once++) LOG("[nvn] SetLineWidth %.2f: lines are drawn 1 pixel wide", w); } }
NVN(nvnCommandBufferSetStencilValueMask, void, NVNcommandBuffer *c, NVNface f, int m) { *REC(c, OP_STENCIL, p_stencil) = (p_stencil){f, m, 0, 0, 0}; }
NVN(nvnCommandBufferSetStencilMask, void, NVNcommandBuffer *c, NVNface f, int m) { *REC(c, OP_STENCIL, p_stencil) = (p_stencil){f, 0, m, 0, 1}; }
NVN(nvnCommandBufferSetStencilRef, void, NVNcommandBuffer *c, NVNface f, int v) { *REC(c, OP_STENCIL, p_stencil) = (p_stencil){f, 0, 0, v, 2}; }
NVN(nvnCommandBufferSetPolygonOffsetClamp, void, NVNcommandBuffer *c, float fa, float un, float cl) {
    *REC(c, OP_POLY_OFFSET, p_poly_offset) = (p_poly_offset){fa, un, cl};
}
NVN(nvnCommandBufferDrawArrays, void, NVNcommandBuffer *c, NVNdrawPrimitive pr, int first, int n) { *REC(c, OP_DRAW, p_draw) = (p_draw){pr, first, n, 1, 0}; }
// Parameter order (mode, first, count, baseInstance, instanceCount): NVN reference nvn::CommandBuffer::DrawArraysInstanced
NVN(nvnCommandBufferDrawArraysInstanced, void, NVNcommandBuffer *c, NVNdrawPrimitive pr, int first, int n, int bi, int inst) { *REC(c, OP_DRAW, p_draw) = (p_draw){pr, first, n, inst, bi}; }
NVN(nvnCommandBufferDrawElementsInstanced, void, NVNcommandBuffer *c, NVNdrawPrimitive pr, NVNindexType it, int n, NVNbufferAddress ib,
    int bv, int bi, int inst) {
    *REC(c, OP_DRAW_IDX, p_draw_idx) = (p_draw_idx){pr, it, n, bv, bi, inst, ib};
}
NVN(nvnCommandBufferDrawElements, void, NVNcommandBuffer *c, NVNdrawPrimitive pr, NVNindexType it, int n, NVNbufferAddress ib) { h_nvnCommandBufferDrawElementsInstanced(c, pr, it, n, ib, 0, 0, 1); }
NVN(nvnCommandBufferDrawElementsBaseVertex, void, NVNcommandBuffer *c, NVNdrawPrimitive pr, NVNindexType it, int n, NVNbufferAddress ib, int bv) {
    *REC(c, OP_DRAW_IDX, p_draw_idx) = (p_draw_idx){pr, it, n, bv, 0, 1, ib};
}
NVN(nvnCommandBufferDispatchCompute, void, NVNcommandBuffer *c, int x, int y, int z) {
    // The thunk is a tail jump (br), so the return address here is the call site in the game
    *REC(c, OP_DISPATCH, p_dispatch) = (p_dispatch){x, y, z, DM_GUEST_RA()};
}
NVN(nvnCommandBufferBarrier, void, NVNcommandBuffer *c, int bits) { *(int32_t *)rec(c, OP_BARRIER, 8) = bits; }
NVN(nvnCommandBufferSetTexturePool, void, NVNcommandBuffer *c, const NVNtexturePool *p) { REC(c, OP_SET_TEX_POOL, p_set_pool)->pool = (const dpool_t *)p; }
NVN(nvnCommandBufferSetSamplerPool, void, NVNcommandBuffer *c, const NVNsamplerPool *p) { REC(c, OP_SET_SAMP_POOL, p_set_pool)->pool = (const dpool_t *)p; }

NVN(nvnCommandBufferCopyBufferToTexture, void, NVNcommandBuffer *c, NVNbufferAddress src, const NVNtexture *t, const NVNtextureView *v,
    const NVNcopyRegion *r, int flags) {
    p_copy_b2t *o = REC(c, OP_COPY_B2T, p_copy_b2t); o->src = src; o->tex = tex_snap(t); copy_view(&o->view, &o->has_view, v); o->r = *r; o->flags = flags;
}
NVN(nvnCommandBufferCopyTextureToBuffer, void, NVNcommandBuffer *c, const NVNtexture *t, const NVNtextureView *v, const NVNcopyRegion *r,
    NVNbufferAddress dst, int flags) {
    p_copy_b2t *o = REC(c, OP_COPY_T2B, p_copy_b2t); o->src = dst; o->tex = tex_snap(t); copy_view(&o->view, &o->has_view, v); o->r = *r; o->flags = flags;
}
// Clear a texture region with the given value (float / unsigned integer versions; mask = channel write mask)
NVN(nvnCommandBufferClearTexture, void, NVNcommandBuffer *c, const NVNtexture *t, const NVNtextureView *v, const NVNcopyRegion *r, const float *rgba, int mask) {
    p_clear_tex *o = REC(c, OP_CLEAR_TEX, p_clear_tex); o->tex = tex_snap(t); copy_view(&o->view, &o->has_view, v); o->r = *r; o->mask = mask; o->is_uint = 0; memcpy(o->c.f, rgba, 16);
}
NVN(nvnCommandBufferClearTextureui, void, NVNcommandBuffer *c, const NVNtexture *t, const NVNtextureView *v, const NVNcopyRegion *r, const uint32_t *rgba, int mask) {
    p_clear_tex *o = REC(c, OP_CLEAR_TEX, p_clear_tex); o->tex = tex_snap(t); copy_view(&o->view, &o->has_view, v); o->r = *r; o->mask = mask; o->is_uint = 1; memcpy(o->c.u, rgba, 16);
}
NVN(nvnCommandBufferCopyTextureToTexture, void, NVNcommandBuffer *c, const NVNtexture *s, const NVNtextureView *sv, const NVNcopyRegion *sr,
    const NVNtexture *d, const NVNtextureView *dv, const NVNcopyRegion *dr, int flags) {
    p_copy_t2t *o = REC(c, OP_COPY_T2T, p_copy_t2t); o->src = tex_snap(s); o->dst = tex_snap(d);
    copy_view(&o->sv, &o->has_sv, sv); copy_view(&o->dv, &o->has_dv, dv); o->sr = *sr; o->dr = *dr; o->flags = flags;
}
NVN(nvnCommandBufferSetCopyRowStride, void, NVNcommandBuffer *c, ptrdiff_t st) { REC(c, OP_COPY_STRIDE, p_copy_stride)->stride = st; }
NVN(nvnCommandBufferSetCopyImageStride, void, NVNcommandBuffer *c, ptrdiff_t st) { REC(c, OP_COPY_IMAGE_STRIDE, p_copy_stride)->stride = st; }
NVN(nvnCommandBufferSetBlendColor, void, NVNcommandBuffer *c, const float *v) { memcpy(REC(c, OP_BLEND_COLOR, p_blend_color)->rgba, v, 16); }

// ---------- State objects: packed in place (nvn_obj.h) ----------
#define ST(T, x) ((T *)(x))
NVN(nvnBlendStateSetDefaults, void, NVNblendState *s) { *ST(blend_st, s) = (blend_st){0, NVN_BLEND_FUNC_ONE, NVN_BLEND_FUNC_ZERO, NVN_BLEND_FUNC_ONE, NVN_BLEND_FUNC_ZERO, NVN_BLEND_EQUATION_ADD, NVN_BLEND_EQUATION_ADD}; }
NVN(nvnBlendStateSetBlendTarget, void, NVNblendState *s, int t) { ST(blend_st, s)->target = t; }
NVN(nvnBlendStateSetBlendFunc, void, NVNblendState *s, NVNblendFunc sr, NVNblendFunc dr, NVNblendFunc sa, NVNblendFunc da) {
    blend_st *o = ST(blend_st, s); o->src_rgb = sr; o->dst_rgb = dr; o->src_a = sa; o->dst_a = da;
}
NVN(nvnBlendStateSetBlendEquation, void, NVNblendState *s, NVNblendEquation er, NVNblendEquation ea) { ST(blend_st, s)->eq_rgb = er; ST(blend_st, s)->eq_a = ea; }
NVN(nvnColorStateSetDefaults, void, NVNcolorState *s) { *ST(color_st, s) = (color_st){0, NVN_LOGIC_OP_COPY, NVN_ALPHA_FUNC_ALWAYS}; }
// Logic ops / alpha test: Metal has neither (alpha test needs shader discard). Stored as given; a non-default value is reported red until the translation chain and replay layer handle it
NVN(nvnColorStateSetLogicOp, void, NVNcolorState *s, NVNlogicOp op) {
    ST(color_st, s)->logic_op = op;
    static int red; if (op != NVN_LOGIC_OP_COPY && !red++) LOG("[red] ColorStateSetLogicOp %d: Metal has no logic ops, not implemented in replay", (int)op);
}
NVN(nvnColorStateSetAlphaTest, void, NVNcolorState *s, NVNalphaFunc f) {   // Metal has no alpha test: fragment shaders carry it (dmsh_build.py alpha_test, nvn_mtl.m alpha_fn)
    ST(color_st, s)->alpha_func = f;
    static int once; if (f != NVN_ALPHA_FUNC_ALWAYS && !once++) LOG("ColorStateSetAlphaTest %d: the first alpha test (fragment shaders are specialized per comparison and reference)", (int)f);
}
NVN(nvnColorStateSetBlendEnable, void, NVNcolorState *s, int i, uint32_t en) {
    color_st *o = ST(color_st, s); if (i < 0 || i > 7) return;
    o->blend_en = B(en) ? (o->blend_en | 1u << i) : (o->blend_en & ~(1u << i));
}
NVN(nvnChannelMaskStateSetDefaults, void, NVNchannelMaskState *s) { ST(chmask_st, s)->mask = 0xffffffffu; }
NVN(nvnChannelMaskStateSetChannelMask, void, NVNchannelMaskState *s, int i, uint32_t r, uint32_t g, uint32_t b, uint32_t a) {
    if (i < 0 || i > 7) return;
    uint32_t m = (B(r) ? 1 : 0) | (B(g) ? 2 : 0) | (B(b) ? 4 : 0) | (B(a) ? 8 : 0);
    chmask_st *o = ST(chmask_st, s); o->mask = (o->mask & ~(0xfu << (4 * i))) | m << (4 * i);
}
NVN(nvnMultisampleStateSetDefaults, void, NVNmultisampleState *s) { memset(s, 0, sizeof(ms_st)); ST(ms_st, s)->enable = 1; }
NVN(nvnMultisampleStateSetMultisampleEnable, void, NVNmultisampleState *s, uint32_t e) { ST(ms_st, s)->enable = B(e) != 0; }
NVN(nvnMultisampleStateSetSamples, void, NVNmultisampleState *s, int n) { ST(ms_st, s)->samples = (uint8_t)n; }
NVN(nvnMultisampleStateSetAlphaToCoverageEnable, void, NVNmultisampleState *s, uint32_t e) { ST(ms_st, s)->a2c = B(e) != 0; }
NVN(nvnMultisampleStateSetSampleLocationsEnable, void, NVNmultisampleState *s, uint32_t e) { ST(ms_st, s)->sl_en = B(e) != 0; }
NVN(nvnMultisampleStateSetSampleLocations, void, NVNmultisampleState *s, int start, int n, const float *v) { (void)s; (void)start; (void)n; (void)v; }
NVN(nvnPolygonStateSetDefaults, void, NVNpolygonState *s) { *ST(poly_st, s) = (poly_st){NVN_FACE_NONE, NVN_FRONT_FACE_CCW, NVN_POLYGON_MODE_FILL, 0}; }
NVN(nvnPolygonStateSetCullFace, void, NVNpolygonState *s, NVNface f) { ST(poly_st, s)->cull = f; }
NVN(nvnPolygonStateSetFrontFace, void, NVNpolygonState *s, NVNfrontFace f) { ST(poly_st, s)->front = f; }
NVN(nvnPolygonStateSetPolygonMode, void, NVNpolygonState *s, NVNpolygonMode m) { ST(poly_st, s)->mode = m; }
NVN(nvnPolygonStateSetPolygonOffsetEnables, void, NVNpolygonState *s, int e) { ST(poly_st, s)->offset_en = e; }
NVN(nvnDepthStencilStateSetDefaults, void, NVNdepthStencilState *s) {
    *ST(ds_st, s) = (ds_st){0, 1, NVN_DEPTH_FUNC_LESS, 0, NVN_STENCIL_FUNC_ALWAYS, NVN_STENCIL_FUNC_ALWAYS,
                            NVN_STENCIL_OP_KEEP, NVN_STENCIL_OP_KEEP, NVN_STENCIL_OP_KEEP, NVN_STENCIL_OP_KEEP, NVN_STENCIL_OP_KEEP, NVN_STENCIL_OP_KEEP};
}
NVN(nvnDepthStencilStateSetDepthTestEnable, void, NVNdepthStencilState *s, uint32_t e) { ST(ds_st, s)->dt = B(e) != 0; }
NVN(nvnDepthStencilStateSetDepthWriteEnable, void, NVNdepthStencilState *s, uint32_t e) { ST(ds_st, s)->dw = B(e) != 0; }
NVN(nvnDepthStencilStateSetDepthFunc, void, NVNdepthStencilState *s, NVNdepthFunc f) { ST(ds_st, s)->df = f; }
NVN(nvnDepthStencilStateSetStencilTestEnable, void, NVNdepthStencilState *s, uint32_t e) { ST(ds_st, s)->st = B(e) != 0; }
NVN(nvnDepthStencilStateSetStencilFunc, void, NVNdepthStencilState *s, NVNface f, NVNstencilFunc fn) {
    ds_st *o = ST(ds_st, s); if (f & NVN_FACE_FRONT) o->sf_f = fn; if (f & NVN_FACE_BACK) o->sf_b = fn;
}
NVN(nvnDepthStencilStateSetStencilOp, void, NVNdepthStencilState *s, NVNface f, NVNstencilOp fail, NVNstencilOp zfail, NVNstencilOp zpass) {
    ds_st *o = ST(ds_st, s);
    if (f & NVN_FACE_FRONT) { o->fail_f = fail; o->zfail_f = zfail; o->zpass_f = zpass; }
    if (f & NVN_FACE_BACK) { o->fail_b = fail; o->zfail_b = zfail; o->zpass_b = zpass; }
}
NVN(nvnVertexAttribStateSetDefaults, void, NVNvertexAttribState *s) { *ST(va_st, s) = (va_st){0, 0, 0}; }
NVN(nvnVertexAttribStateSetFormat, void, NVNvertexAttribState *s, NVNformat f, ptrdiff_t off) {
    if (off < 0 || off >= (1 << 19)) LOG("[red] vertex attribute offset %td exceeds the packed range", off);
    ST(va_st, s)->fmt = f; ST(va_st, s)->offset = (uint32_t)off;
}
NVN(nvnVertexAttribStateSetStreamIndex, void, NVNvertexAttribState *s, int i) { ST(va_st, s)->stream = i; }
NVN(nvnVertexStreamStateSetDefaults, void, NVNvertexStreamState *s) { *ST(vs_st, s) = (vs_st){0, 0}; }
NVN(nvnVertexStreamStateSetStride, void, NVNvertexStreamState *s, ptrdiff_t st) { ST(vs_st, s)->stride = (uint32_t)st; }
NVN(nvnVertexStreamStateSetDivisor, void, NVNvertexStreamState *s, int d) { ST(vs_st, s)->divisor = d; }

static _Atomic uint64_t g_sub_wall_ns, g_sub_cpu_ns, g_sub_instr;   // Wall clock / this thread's CPU time / this thread's retired instruction count for submit (excluding present) (taken away per frame)
static _Atomic uint64_t g_cum_sub_instr, g_cum_sub_cpu_ns;   // Cumulative versions of the above (the "translation" summary row every 300 frames takes the difference; on a real device read through the log port: instructions per draw / submit CPU per frame)
extern int thread_selfcounts(int type, void *buf, size_t nbytes);   // This thread's cumulative {instructions, cycles} (libSystem private interface, present on both Mac and iOS)
static uint64_t thr_instr(void) { uint64_t c[2] = {0, 0}; thread_selfcounts(1, c, sizeof c); return c[0]; }
// Supplementary readings for the submit path (on a real device Metal 4 instruction count is -18% while submit CPU time is +49%; need to tell apart kernel mode, execution efficiency, or frequency throttling):
// this thread's cycle count (the second item of the same interface), kernel-mode CPU time (THREAD_BASIC_INFO), wall clock
static void thr_counts(uint64_t *instr, uint64_t *cyc) { uint64_t c[2] = {0, 0}; thread_selfcounts(1, c, sizeof c); *instr = c[0]; *cyc = c[1]; }
static uint64_t thr_sys_ns(void) {
    thread_basic_info_data_t bi; mach_msg_type_number_t n = THREAD_BASIC_INFO_COUNT; mach_port_t me = mach_thread_self(); uint64_t r = 0;
    if (thread_info(me, THREAD_BASIC_INFO, (thread_info_t)&bi, &n) == KERN_SUCCESS) r = (uint64_t)bi.system_time.seconds * 1000000000ull + (uint64_t)bi.system_time.microseconds * 1000ull;
    mach_port_deallocate(mach_task_self(), me); return r;
}
static _Atomic uint64_t g_cum_sub_cyc, g_cum_sub_sys_ns, g_cum_sub_wall_ns;
static int frame_rec(void);
static _Atomic uint64_t g_nvn_ns;   // Host time spent in submit / present this frame (replay encoding + present), used by the timing instrumentation

// ---------- Lifecycle: dm_gfx_suspend (called before iOS goes to the background; equivalent to Switch suspend) ----------
// on=1: subsequent submits / presents block until on=0; before returning, wait for in-progress submit / present calls to exit and for all in-flight GPU work to complete (iOS requires no GPU work in the background).
static pthread_mutex_t g_susp_mu = PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t g_susp_cv = PTHREAD_COND_INITIALIZER;
static int g_susp, g_inflight_api;
static void gfx_enter(void) { pthread_mutex_lock(&g_susp_mu); while (g_susp) pthread_cond_wait(&g_susp_cv, &g_susp_mu); g_inflight_api++; pthread_mutex_unlock(&g_susp_mu); }
static void gfx_leave(void) { pthread_mutex_lock(&g_susp_mu); g_inflight_api--; pthread_cond_broadcast(&g_susp_cv); pthread_mutex_unlock(&g_susp_mu); }
void dm_gfx_suspend(int on) {
    pthread_mutex_lock(&g_susp_mu);
    g_susp = on != 0;
    if (on) while (g_inflight_api) pthread_cond_wait(&g_susp_cv, &g_susp_mu);
    else pthread_cond_broadcast(&g_susp_cv);
    pthread_mutex_unlock(&g_susp_mu);
    if (on) { mtl_drain(); LOG("[nvn] graphics suspended: in-flight GPU work drained"); } else LOG("[nvn] graphics resumed");
}
// DM_TEST_WORK_MS=<ms> (a test of the pacing, plan item 53): the frame's first submission waits until <ms> after the previous present, as a game whose
// own work takes that long; Tears of the Kingdom's frame-rate controller counts it (a wait in the present would not be: it measures to before it)
static void sleep_until_ns(uint64_t dl);
static _Atomic uint64_t g_test_work_from;   // the last present's time; taken by the frame's first submission
static int test_work_ms(void) { static int ms = -1; if (ms < 0) { const char *e = getenv("DM_TEST_WORK_MS"); ms = e ? atoi(e) : 0; if (ms > 0) LOG("[nvn] DM_TEST_WORK_MS=%d: each frame's work made to take that long (a test)", ms); } return ms; }
NVN(nvnQueueSubmitCommands, void, NVNqueue *q, int n, const NVNcommandHandle *h) {
    if (test_work_ms() > 0) { uint64_t from = atomic_exchange(&g_test_work_from, 0); if (from) sleep_until_ns(from + (uint64_t)test_work_ms() * 1000000ull); }
    NVN_BLOCKING();
    gfx_enter(); gfx_mt_enter("SubmitCommands");
    uint64_t t0 = now_ns(), c0 = clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID), i0, y0, s0 = thr_sys_ns(); thr_counts(&i0, &y0);
    ((queue_t *)q)->submits++;
    mtl_sub_begin();
    mtl_sub_index((const uint64_t *)h, n);
    mtl_sub_snapshot((const uint64_t *)h, n);
    for (int i = 0; i < n; i++) { mtl_exec_rest((const uint64_t *)h + i + 1, n - i - 1); mtl_exec((const uint8_t *)h[i]); }
    mtl_exec_rest(NULL, 0);
    mtl_sub_commit();
    uint64_t dw = now_ns() - t0;
    atomic_fetch_add(&g_nvn_ns, dw); atomic_fetch_add(&g_sub_wall_ns, dw);
    uint64_t i1, y1; thr_counts(&i1, &y1); uint64_t dc = clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID) - c0, di = i1 - i0;
    atomic_fetch_add(&g_cum_sub_cyc, y1 - y0); atomic_fetch_add(&g_cum_sub_sys_ns, thr_sys_ns() - s0); atomic_fetch_add(&g_cum_sub_wall_ns, dw);
    atomic_fetch_add(&g_sub_cpu_ns, dc); atomic_fetch_add(&g_cum_sub_cpu_ns, dc);
    atomic_fetch_add(&g_sub_instr, di); atomic_fetch_add(&g_cum_sub_instr, di);
    gfx_mt_leave(); gfx_leave();
}

// Commands that only affect GPU state / only execute on the GPU: the null device only counts them (the thunk has already counted)
static void nvn_nop(void) {}
// Depth bounds are not modelled: disabling them is fine, enabling them is reported once (the draws are not rejected by the bounds)
static int g_depth_bounds_red;
NVN(nvnCommandBufferSetDepthBounds, void, NVNcommandBuffer *cb, uint32_t enable, float n, float f) {
    (void)cb; if (enable && !g_depth_bounds_red++) LOG("[red] CommandBufferSetDepthBounds enabled (%g..%g): depth bounds are not modelled, ignored", n, f);
}
// SetPatchSize, MultiDrawArrays / ElementsIndirectCount, DispatchComputeIndirect and DownsampleTextureView used to be listed here, so a game calling
// them lost draws, dispatches or a downsample without a line: they go to the red-reporting stub now (upstream d2r-mobile 44a6770; nxnative has
// DispatchComputeIndirect / DrawElementsIndirect and Downsample as a resolve, for when a game calls them). SetDepthBounds is below
static const char *const g_nops[] = {
    "nvnCommandBufferWaitSync",    // A GPU-side wait on a sync object (CPU waits go through nvnSyncWait, which really waits on the fence). Sync objects come only
                                   // from QueueFenceSync and WindowAcquireTexture, whose fence value is "the highest already submitted when recorded", and the
                                   // command buffer holding WaitSync is submitted after it to the same queue. There is one Metal command stream queue
                                   // (stream_queue_once in nvn_mtl.m): Metal 4 puts a "wait for all earlier stages on the queue" barrier at the start of each
                                   // encoder, and the older API tracks every resource (useResource for argument block references), so both are already in
                                   // order and a no-op is correct. A second queue (async compute, say) would make this a real wait
    "nvnCommandBufferSetShaderScratchMemory",
    "nvnCommandBufferPushDebugGroupDynamic",
    "nvnCommandBufferPopDebugGroup",
    "nvnCommandBufferInsertDebugMarkerDynamic",
    "nvnCommandBufferWaitEvent",   // Waits for an earlier SignalEvent in the same command stream or a CPU EventSignal. One queue executes in order and the GPU
                                   // never passes earlier commands, so a no-op is correct (waiting for a signal issued later would hang a real Switch too)
    "nvnWindowFinalize",
    "nvnCommandBufferSaveZCullData", "nvnCommandBufferRestoreZCullData",   // ZCull: see the textures section
    "nvnCommandBufferSetPointSize",   // Point size comes from the shader's [[point_size]] output (handled by the translation chain)
    // Debug labels: only shown by graphics debuggers
    "nvnDeviceSetDebugLabel", "nvnQueueSetDebugLabel", "nvnWindowSetDebugLabel", "nvnProgramSetDebugLabel",
    "nvnMemoryPoolSetDebugLabel", "nvnTexturePoolSetDebugLabel", "nvnSamplerPoolSetDebugLabel", "nvnBufferSetDebugLabel",
    "nvnTextureSetDebugLabel", "nvnSamplerSetDebugLabel", "nvnCommandBufferSetDebugLabel", "nvnSyncSetDebugLabel",
};
__attribute__((constructor)) static void nvn_nops_register(void) {
    // Empty implementations overwrite the unimplemented stubs after the slot table is initialized; a misspelled name (not in main's name table) reports a failure and aborts at startup
    nvn_init_slots();
    for (unsigned k = 0; k < sizeof g_nops / sizeof *g_nops; k++) {
        unsigned i = 0;
        while (i < NVN_NFUNC && strcmp(nvn_names[i], g_nops[k])) i++;
        if (i == NVN_NFUNC) die("NVN no-op name %s is not in main's name table", g_nops[k]);
        if (nvn_slot[i].fn != (void *)nvn_unimpl_entry) die("NVN %s has an implementation and is also listed as a no-op", g_nops[k]);
        nvn_slot[i].fn = (void *)nvn_nop;
    }
    unsigned nnop = sizeof g_nops / sizeof *g_nops;
    // DM_NVN_PROF=1: implemented functions (except unimplemented stubs and present: present includes the display-link wait and is counted separately) get a timing wrapper, used to break down the time spent in the "translation layer recording phase"
    if (getenv("DM_NVN_PROF"))
        for (unsigned i = 0; i < NVN_NFUNC; i++)
            if (nvn_slot[i].fn != (void *)nvn_unimpl_entry && strcmp(nvn_names[i], "nvnQueuePresentTexture")) { nvn_real[i] = nvn_slot[i].fn; nvn_slot[i].fn = (void *)nvn_prof_entry; }
    LOG("[nvn] null device: %u names, %u implemented (%u semantic + %u no-op), the remaining %u go to the red-reporting stub",
        NVN_NFUNC, g_nsem + nnop, g_nsem, nnop, NVN_NFUNC - g_nsem - nnop);
}

// ---------- Window / present ----------
#define WB(b) ((win_builder_t *)(b))
NVN(nvnWindowBuilderSetDefaults, void, NVNwindowBuilder *b) { NVNdevice *dev = WB(b)->dev; memset(b, 0, sizeof(win_builder_t)); WB(b)->dev = dev; WB(b)->interval = 1; }
NVN(nvnWindowBuilderSetDevice, void, NVNwindowBuilder *b, NVNdevice *d) { WB(b)->dev = d; }
NVN(nvnWindowBuilderSetNativeWindow, void, NVNwindowBuilder *b, NVNnativeWindow w) { WB(b)->native = w; }
NVN(nvnWindowBuilderSetTextures, void, NVNwindowBuilder *b, int n, NVNtexture *const *t) {
    if (n < 0 || n > 4) { LOG("[red] WindowBuilderSetTextures: count %d", n); n = n < 0 ? 0 : 4; }
    WB(b)->ntex = n; for (int i = 0; i < n; i++) WB(b)->tex[i] = t[i];
}
NVN(nvnWindowBuilderSetPresentInterval, void, NVNwindowBuilder *b, int v) { WB(b)->interval = v; }
// No prototype in the header. Signature from the call site main+0x9c9218 (2.0.4b): x0 = builder, w1 = count (ldr w1), return value unused
NVN_NOPROTO(nvnWindowBuilderSetNumActiveTextures, void, NVNwindowBuilder *b, int n) { WB(b)->nactive = n; }
NVN(nvnWindowInitialize, NVNboolean, NVNwindow *w, const NVNwindowBuilder *b) {
    const win_builder_t *s = (const win_builder_t *)b; win_t *o = (win_t *)w;
    memset(o, 0, sizeof *o); o->magic = MAGIC('W', 'I', 'N', 'D'); o->native = s->native; o->ntex = s->ntex; o->interval = s->interval;
    o->nactive = s->nactive > 0 && s->nactive <= s->ntex ? s->nactive : 0;
    if (s->nactive && !o->nactive) LOG("[red] WindowInitialize: active texture count %d exceeds the %d-texture swap chain, using all", s->nactive, s->ntex);
    memcpy(o->tex, s->tex, sizeof o->tex);
    for (int i = 0; i < o->ntex; i++) if (o->tex[i]) mtl_xv_window_tex(CTX(o->tex[i])->serial);
    LOG("[nvn] WindowInitialize swap chain %d textures, interval %d, first %dx%d format %#x", o->ntex, o->interval,
        o->ntex ? (int)CTX(o->tex[0])->d.width : 0, o->ntex ? (int)CTX(o->tex[0])->d.height : 0, o->ntex ? CTX(o->tex[0])->d.format : 0);
    return 1;
}
NVN(nvnWindowGetPresentInterval, int, const NVNwindow *w) { return ((const win_t *)w)->interval; }
__attribute__((weak)) void dm_backtrace(uint64_t fp) { (void)fp; }   // host crash.c (guest frame chain); none in the graphics unit tests
// The caller is logged with the change: Tears of the Kingdom's frame-rate controller picks 2 (30 fps) or 3 (20 fps) itself
NVN(nvnWindowSetPresentInterval, void, NVNwindow *w, int v) {
    if (((win_t *)w)->interval != v) { LOG("[nvn] game set present interval %d → %d", ((win_t *)w)->interval, v); dm_backtrace((uint64_t)__builtin_frame_address(0)); }
    ((win_t *)w)->interval = v;
}
NVN(nvnWindowSetCrop, void, NVNwindow *w, int x, int y, int ww, int hh) {
    win_t *o = (win_t *)w; int v[4] = {x, y, ww, hh};
    if (memcmp(o->crop, v, sizeof v)) LOG("[nvn] WindowCrop %d,%d %dx%d", x, y, ww, hh);
    memcpy(o->crop, v, sizeof v);
    dm_touch_screen(ww, hh);
}
static void trow(uint64_t f, const char *name, double v);
static void set_time_constraint(uint64_t period_ns);
static void rt_comp_tick(uint64_t period_ns);
static double g_rt_comp_ms;   // Currently declared real-time computation amount (ms; 0 = not declared)
static double g_rt_period_ms;
static void sleep_until_ns(uint64_t dl);
static uint64_t present_period(const win_t *o);
__attribute__((weak)) void dm_main_yield_stats(uint64_t *n, uint64_t *ns) { *n = 0; *ns = 0; }   // The host's hle_thread.c provides the ground truth; 0 in graphics unit tests
__attribute__((weak)) uint32_t dm_guest_work_qos(unsigned *count) { if (count) *count = 0; return QOS_CLASS_UNSPECIFIED; }
extern uint32_t mtl_present_qos(void);
static uint64_t g_frame;
static uint64_t g_acq_wait_ns, g_pq_wait_ns;   // Accumulated display-link wait / wait for the present queue to return inside acquire, recorded per frame at present (there can be several acquires within one frame)
uint64_t dm_nvn_frame_count(void) { return g_frame; }
extern uint64_t g_t0_ns;   // Host process start point (main.c; same base as the UIMSG timestamps)
static int g_display_mode;   // present_cfg (tentative definition: the variable is defined with the present rate further down)
static int g_uncapped;       // present_cfg: our own clock paces the game (nvn_uncapped_hz), not the display link
NVN(nvnWindowAcquireTexture, NVNwindowAcquireTextureResult, NVNwindow *w, NVNsync *s, int *idx) {
    NVN_BLOCKING();
    win_t *o = (win_t *)w;
    int nuse = o->nactive ? o->nactive : o->ntex;
    *idx = nuse ? o->next++ % nuse : 0;
    // Vsync blocks here (real-device NVN: when all textures in the swapchain are waiting for display, wait for the next one to be released), not in present -- the game often calls present while holding a lock
    uint64_t at = *idx < 4 ? o->avail[*idx] : 0, now = dm_detclock_enabled() ? guest_ns() : now_ns(), wait = at > now ? at - now : 0;
    if (!dm_detclock_enabled()) {   // Register the acquire thread as a time-constraint thread (no longer registered only when it "arrived early": it must also declare itself when it is constantly behind in the hot state)
        static uint64_t rt_period; uint64_t period = present_period(o);
        if (period && rt_period != period) { rt_period = period; set_time_constraint(period); }
        rt_comp_tick(period);
        if (mtl_link_active() && !g_uncapped) { void mtl_link_set_interval(int n); mtl_link_set_interval(g_display_mode ? 1 : o->interval);   // game interval mode: as many ticks as the interval (it waited one: 60 fps at interval 2, the game ran twice as fast)
            if (!mtl_link_wait_tick(period ? 2 * period : 33333333ull) && wait) sleep_until_ns(at); }   // DM_PRESENT_LINK: pacing fully follows the display link (wait for the next display-link tick when running fast, go immediately when behind); our own 60 Hz clock is only the fallback when no display-link tick arrives
        else if (wait) sleep_until_ns(at);
    } else {   // DM_DETCLOCK_PACE=1 (used by the screenshot gate): while the guest clock advances per frame, each frame's wall clock is no shorter than one step -- frame count and in-game time are deterministic, and the background loading thread has at least one step of wall clock available per frame;
               // When the machine is fully loaded frames only get slower and the background only gets more wall clock, so the picture captured at "the Nth frame after the message" is independent of load
        static int pace = -1; static uint64_t step, last;
        if (pace < 0) { const char *e = getenv("DM_DETCLOCK_PACE"), *d = getenv("DM_DETCLOCK"); step = d ? strtoull(d, 0, 0) : 0; pace = e && atoi(e) && step; }
        if (pace) { if (last && now_ns() < last + step) sleep_until_ns(last + step); last = now_ns(); }
    }
    g_acq_wait_ns += wait; trow(g_frame, "@late_ms", wait ? (now_ns() - at) / 1e6 : 0);
    // The previous present of this texture has not yet been processed by the present thread (display cannot keep up, a whole swapchain round behind): wait for it to be returned, then hand it to the game to draw
    uint64_t tk = *idx < 4 ? o->ticket[*idx] : 0;
    if (tk) { uint64_t w0 = now_ns(); mtl_present_wait(tk); g_pq_wait_ns += now_ns() - w0; }
    // The acquire sync means "the display path no longer reads this texture": mtl_present_wait above waited for its last present to be committed, and
    // every later use of the texture is ordered after that present on the one Metal queue. Fencing it to the newest submission instead held the game's
    // CPU here until the whole previous frame had run, so the replay of a frame and the GPU work of the one before never overlapped (MacNativeGames,
    // MIT: TOTK_ACQ_SYNC). DM_NVN_ACQ_SYNC=newest restores that (A/B)
    if (s) { static int newest = -1; if (newest < 0) { const char *e = getenv("DM_NVN_ACQ_SYNC"); newest = e && !strcmp(e, "newest"); if (newest) LOG("[nvn] DM_NVN_ACQ_SYNC=newest: the acquire sync waits for the newest submission"); }
             ((sync_t *)s)->fenced = 1; ((sync_t *)s)->fence = newest ? mtl_last_fence() : 0; }
    return NVN_WINDOW_ACQUIRE_TEXTURE_RESULT_SUCCESS;
}

// Frame boundary: on each present, print / write to disk the call count of each NVN function for this frame
static uint64_t g_prev[NVN_NFUNC];
static FILE *g_tsv;
static void dump_frame(void) {
    static int inited, nframes = 3, calls = 1;
    if (!inited) {
        inited = 1;
        const char *e = getenv("DM_NVN_FRAMES"); if (e) nframes = atoi(e);
        const char *c = getenv("DM_NVN_TSV_CALLS"); if (c) calls = atoi(c);   // 0 = write only the @ timing rows (pulling files from a real device has a size limit, and the call-count rows take about 2/3)
        const char *t = getenv("DM_NVN_TSV"); if (t && !(g_tsv = fopen(t, "w"))) LOG("[red] cannot open %s", t);
        if (g_tsv) fprintf(g_tsv, "# kind: nvn-per-frame  when name is an NVN function name, value = call count; names starting with @ are timing probes (ms / count)\nframe\tname\tvalue\n");
    }
    uint64_t total = 0; unsigned nfn = 0;
    char line[8192]; size_t o = 0; line[0] = 0;
    for (unsigned i = 0; i < NVN_NFUNC; i++) {
        uint64_t c = atomic_load(&nvn_slot[i].cnt), d = c - g_prev[i];
        g_prev[i] = c;
        if (!d) continue;
        total += d; nfn++;
        if (g_tsv && calls) fprintf(g_tsv, "%llu\t%s\t%llu\n", g_frame, nvn_names[i], d);
        if (g_frame <= (uint64_t)nframes && o < sizeof line - 96) o += snprintf(line + o, sizeof line - o, " %s=%llu", nvn_names[i] + 3, d);
    }
    if (g_tsv) fflush(g_tsv);
    if (g_frame <= (uint64_t)nframes) LOG("[nvn] %s %llu: %u functions, %llu calls |%s", g_frame ? "frame" : "init", g_frame, nfn, total, line);
    else if (g_frame % 300 == 0) LOG("[nvn] frame %llu: %u functions, %llu calls", g_frame, nfn, total);
    g_frame++; cs_dump();
    // Every 300 frames read resident memory and hand it to the graphics layer to print the memory readout line (mtl_mem_stat, low frequency, capped). Memory watchdog: when resident memory exceeds the cap, log a failure and exit on its own. On by default only on the Mac host (24 GB: runaway host memory
    // drags the whole machine into a kernel panic, which happened twice with other programs on the same machine), or set for tests with DM_MEM_CAP_GB=<integer>; the player's iOS app has no cap (exiting before the system kills it is pointless and only adds another kind of crash)
    if (g_frame % 300 == 0) { task_vm_info_data_t vi; mach_msg_type_number_t cnt = TASK_VM_INFO_COUNT;
        if (task_info(mach_task_self(), TASK_VM_INFO, (task_info_t)&vi, &cnt) == KERN_SUCCESS) { unsigned long long mb = (unsigned long long)(vi.phys_footprint >> 20); unsigned long long ht = 0, hf = 0, hm = 0; int dm_guest_heap_stat(unsigned long long *, unsigned long long *, unsigned long long *); int hok = dm_guest_heap_stat(&ht, &hf, &hm);
            void mtl_mem_stat(unsigned long long, unsigned long long, int, unsigned long long, unsigned long long, unsigned long long); mtl_mem_stat(g_frame, mb, hok, ht, hf, hm);
            static long cap = -1; if (cap < 0) { const char *e = getenv("DM_MEM_CAP_GB"); cap = e ? atol(e) : DM_MEM_CAP_DEFAULT_GB; }
            if (cap > 0 && mb > (unsigned long long)cap * 1024) { LOG("[red] memory watchdog: resident %llu MB exceeds the %ld GB cap (frame %llu), exiting", mb, cap, (unsigned long long)g_frame); _exit(86); } } }
    dm_guest_frame_tick();   // Deterministic guest clock (DM_DETCLOCK, host hle_os.c): each present advances a fixed step; a no-op when not enabled
}
// ---------- Timing instrumentation (per-frame rows written to DM_NVN_TSV: frame / @metric / value; every 300 frames a summary of p50 / p95 / max) ----------
#define TWIN 300
static double g_tw[6][TWIN]; static unsigned g_tn[6];
static double g_pres_iv[TWIN]; static unsigned g_presn;   // Present interval (ms; -1 = dropped by the system, 0 = no reading)
__attribute__((weak)) double dm_brightness_now(void) { return -1; }
__attribute__((weak)) void dm_yield_top(char *out, size_t n) { if (n) snprintf(out, n, "none"); }   // hle_thread.c's when linked (not in the graphics unit tests)
__attribute__((weak)) void dm_thread_cpu(char *out, size_t n, double secs) { (void)secs; if (n) snprintf(out, n, "-"); }   // hle_thread.c: guest-thread CPU by Switch priority; none in graphics unit tests
__attribute__((weak)) void dm_perf_present(double iv_ms) { (void)iv_ms; }   // Default (unit tests); strong definition in the host's diag.c: always-on performance record perf.txt
uint64_t dm_nvn_sub_cpu_ns(void) { return atomic_load(&g_cum_sub_cpu_ns); }   // Cumulative CPU nanoseconds of submit (excluding present)
__attribute__((weak)) int dm_thermal_now(void) { return -1; }   // Default (Mac); overridden by iOS front_ios.m   // default (Mac); the strong definition in the iOS front end front_ios.m overrides it
// Per-frame ring for the long-frame log (GPU time only arrives 8 frames late, so store first and judge later)
#define LFN 16
typedef struct { uint64_t f; double fr, nv, t_s, make_ms, up_mb, up_ms; unsigned pso, lib, up, rup; int ls; } lf_rec;   // ls: whether the loading screen was covering the picture when this frame was presented
static lf_rec g_lf[LFN];
__attribute__((weak)) void dm_longframe_note(const char *what) { LOG("[long frame] %s", what); }   // Default (graphics unit tests); the strong definition in the host's diag.c adds scene context and writes perf.txt
extern void mtl_create_ns(uint64_t *lib_ns, uint64_t *pso_ns); extern uint64_t mtl_upload_bytes(void); extern void mtl_pkg_stats(uint64_t *uploads, uint64_t *reuploads);
static const char *const g_tname[6] = {"frame time", "frame work", "NVN submit+present", "GPU", "translation record phase", "translation submit phase"};
static void tpush(int k, double v) { g_tw[k][g_tn[k]++ % TWIN] = v; }
// Thermal attribution (iOS DM_HEAT): per-frame GPU milliseconds are kept in a separate ring, taking the mean / p95 "since the last read" (at most the last HRN frames), without interfering with the timing summary's 300-frame window
#define HRN 1024
static double g_hr[HRN]; static uint64_t g_hn, g_hn_read;
static int dcmp(const void *a, const void *b);
void nvn_gpu_recent(double *avg, double *p95, unsigned *n) {
    uint64_t hi = g_hn, lo = g_hn_read > hi ? hi : g_hn_read; if (hi - lo > HRN) lo = hi - HRN; g_hn_read = hi;
    unsigned c = (unsigned)(hi - lo); static double v[HRN]; double s = 0;
    for (unsigned i = 0; i < c; i++) { v[i] = g_hr[(lo + i) % HRN]; s += v[i]; }
    qsort(v, c, sizeof *v, dcmp); *n = c; *avg = c ? s / c : -1; *p95 = c ? v[(c * 95) / 100 < c ? (c * 95) / 100 : c - 1] : -1;
}
static int dcmp(const void *a, const void *b) { double x = *(const double *)a, y = *(const double *)b; return (x > y) - (x < y); }
// Power over the window since the last summary, for the whole process (nxnative's power line, MIT): CPU energy (task_energy, nJ on Apple silicon)
// in watts and per frame, CPU time (100 = one core) and its share on performance cores, wakeups per second, and the guest threads that yielded most;
// then render-target traffic per frame (attachment bytes loaded and stored, passes loading and storing everything, stores DM_NVN_UNWRITTEN_DC saved)
// and guest-thread CPU by Switch priority (nxnative 451e118); samples-passed reports and resets a frame, the slots a report adds up (since the last
// reset) and those folded when their visibility buffer was used again (nvn_mtl.m vis_recycle)
void mtl_counter_stats(uint64_t rep[32], uint64_t rst[32]);
void mtl_vis_state(int *open, uint64_t *folded);
void mtl_counts(uint64_t out[13]);
void mtl_pkg_age(uint64_t out[5]);
void mtl_fbx_stats(uint64_t out[3]);
__attribute__((weak)) void dm_gate_counts(uint64_t out[4]) { memset(out, 0, 4 * sizeof *out); }   // host/hle.c; the graphics unit tests link without it
static void power_line(uint64_t frame) {
    static uint64_t pt, pe, pcpu, pp, piw, pf, pld, pst, pfu, pudc, prep, prst, pfold, pc[13], pg[4], pfx[3]; static mach_timebase_info_data_t tb; if (!tb.denom) mach_timebase_info(&tb);
    static int counts = -1; if (counts < 0) counts = getenv("DM_NVN_COUNTS") && strcmp(getenv("DM_NVN_COUNTS"), "0");
    task_power_info_v2_data_t pw; mach_msg_type_number_t n = TASK_POWER_INFO_V2_COUNT;
    if (task_info(mach_task_self(), TASK_POWER_INFO_V2, (task_info_t)&pw, &n) != KERN_SUCCESS) return;
    uint64_t t = now_ns(), cpu = (pw.cpu_energy.total_user + pw.cpu_energy.total_system) * tb.numer / tb.denom, p = pw.task_ptime * tb.numer / tb.denom;
    uint64_t e = pw.task_energy, iw = pw.cpu_energy.task_interrupt_wakeups;
    char yt[192]; dm_yield_top(yt, sizeof yt);
    if (pt && t > pt) { double s = (t - pt) / 1e9, nf = frame > pf ? (double)(frame - pf) : 1;
        LOG("[nvn] power up to frame %llu: CPU energy %.2f W, %.1f mJ a frame (%.1f frames/s); CPU %.0f%% (100 = one core), %.0f%% of it on performance cores; %.0f wakeups/s; most yields: %s",
            frame, (e - pe) / 1e9 / s, (e - pe) / 1e6 / nf, nf / s, (cpu - pcpu) / 1e7 / s, cpu > pcpu ? 100.0 * (double)(p - pp) / (double)(cpu - pcpu) : 0, (iw - piw) / s, yt);
        uint64_t ld, st, fu, udc = mtl_udc_saved_bytes(); mtl_bw(&ld, &st, &fu);
        LOG("[nvn] render targets up to frame %llu: %.1f MB loaded / %.1f MB stored a frame, %.1f passes a frame load and store everything, %.1f MB a frame of stores saved (DM_NVN_UNWRITTEN_DC)",
            frame, (ld - pld) / 1048576.0 / nf, (st - pst) / 1048576.0 / nf, (fu - pfu) / nf, (udc - pudc) / 1048576.0 / nf);
        char tc[400]; dm_thread_cpu(tc, sizeof tc, s);
        LOG("[nvn] threads up to frame %llu: guest CPU %s", frame, tc);
        uint64_t rep[32], rst[32], fold; int open; mtl_counter_stats(rep, rst); mtl_vis_state(&open, &fold);
        if (rep[NVN_COUNTER_TYPE_SAMPLES_PASSED] > prep || rst[NVN_COUNTER_TYPE_SAMPLES_PASSED] > prst)
            LOG("[nvn] occlusion up to frame %llu: %.1f reports / %.1f resets a frame, %d slots in the open count, %.1f folded a frame", frame,
                (rep[NVN_COUNTER_TYPE_SAMPLES_PASSED] - prep) / nf, (rst[NVN_COUNTER_TYPE_SAMPLES_PASSED] - prst) / nf, open, (fold - pfold) / nf);
        { uint64_t fx[3]; mtl_fbx_stats(fx);
          if (fx[0] > pfx[0] || fx[2] > pfx[2]) LOG("[nvn] attachment copies up to frame %llu: %.1f draws a frame sample what their pass draws, %.1f copies, %.1f not copied (merged, layered or range pass)",
                                                   frame, (fx[0] - pfx[0]) / nf, (fx[1] - pfx[1]) / nf, (fx[2] - pfx[2]) / nf); }
        if (counts) { uint64_t c[13], g[4]; mtl_counts(c); dm_gate_counts(g);   // DM_NVN_COUNTS (plan items 42-45)
            LOG("[nvn] counts up to frame %llu, a frame: %.1f draws sample the levels and layers their own pass draws (%.1f after other draws of the Metal pass, %.1f of them after a barrier); "
                "%.1f timestamp reports, %.2f submissions with two or more; %.1f ClearTexture; %.1f render passes without a draw; a second: %.0f counter reads, %.0f svcs",
                frame, (c[0] - pc[0]) / nf, (c[1] - pc[1]) / nf, (c[2] - pc[2]) / nf, (c[3] - pc[3]) / nf, (c[4] - pc[4]) / nf, (c[5] - pc[5]) / nf, (c[6] - pc[6]) / nf,
                (g[1] + g[2] - pg[1] - pg[2]) / s, (g[0] - pg[0]) / s);
            LOG("[nvn] counts up to frame %llu, a frame: %.1f passes with draws, %.1f of them draw only a top-left part (%.1f more with a clear on load), %.2f%% (%.2f%%) of all their pixels outside it",
                frame, (c[7] - pc[7]) / nf, (c[8] - pc[8]) / nf, (c[11] - pc[11]) / nf, c[9] > pc[9] ? 100.0 * (double)(c[10] - pc[10]) / (double)(c[9] - pc[9]) : 0,
                c[9] > pc[9] ? 100.0 * (double)(c[12] - pc[12]) / (double)(c[9] - pc[9]) : 0);
            uint64_t ag[5]; mtl_pkg_age(ag);
            LOG("[nvn] counts up to frame %llu: %llu CPU-filled textures, %.1f MB used in the last 30 submissions, %.1f MB 31-300 ago, %.1f MB 301-1800 ago, %.1f MB longer",
                frame, (unsigned long long)ag[4], ag[0] / 1048576.0, ag[1] / 1048576.0, ag[2] / 1048576.0, ag[3] / 1048576.0); } }
    else { char tc[400]; dm_thread_cpu(tc, sizeof tc, 1); }   // the first call only takes the baselines
    pt = t; pe = e; pcpu = cpu; pp = p; piw = iw; pf = frame; mtl_bw(&pld, &pst, &pfu); pudc = mtl_udc_saved_bytes();
    { uint64_t rep[32], rst[32]; int open; mtl_counter_stats(rep, rst); mtl_vis_state(&open, &pfold); prep = rep[NVN_COUNTER_TYPE_SAMPLES_PASSED]; prst = rst[NVN_COUNTER_TYPE_SAMPLES_PASSED]; }
    if (counts) { mtl_counts(pc); dm_gate_counts(pg); }
    mtl_fbx_stats(pfx);
}
static void tsummary(uint64_t frame) {
    char line[1024]; size_t o = 0;
    for (int k = 0; k < 6; k++) {
        unsigned n = g_tn[k] < TWIN ? g_tn[k] : TWIN; if (!n) continue;
        double v[TWIN]; memcpy(v, g_tw[k], n * sizeof *v); qsort(v, n, sizeof *v, dcmp);
        o += snprintf(line + o, sizeof line - o, " %s p50 %.2f / p95 %.2f / max %.2f ms (%u frames);", g_tname[k], v[n / 2], v[(n * 95) / 100 < n ? (n * 95) / 100 : n - 1], v[n - 1], n);
    }
    LOG("[nvn] timing up to frame %llu:%s", frame, line);
    power_line(frame);
    { unsigned n = g_tn[0] < TWIN ? g_tn[0] : TWIN, over = 0; double v[TWIN];   // frame interval gets its own line (M1 baseline): number of frames > 16.7 ms in this window and p99
      if (n) { memcpy(v, g_tw[0], n * sizeof *v); qsort(v, n, sizeof *v, dcmp); for (unsigned i = 0; i < n; i++) over += v[i] > 16.7;
        LOG("[nvn] frame interval up to frame %llu: >16.7ms %u / %u frames, p99 %.2f ms", frame, over, n, v[(n * 99) / 100 < n ? (n * 99) / 100 : n - 1]); } }
    { unsigned n = g_presn < TWIN ? g_presn : TWIN, k = 0, drop = 0, discard = 0; double v[TWIN];   // on-screen present: dropped frame = interval > 16.7 × 1.5 ms or discarded
      for (unsigned i = 0; i < n; i++) { double x = g_pres_iv[i]; if (x < 0) { drop++; discard++; } else if (x > 0) { v[k++] = x; drop += x > 25.0; } }
      task_vm_info_data_t vi; mach_msg_type_number_t vc = TASK_VM_INFO_COUNT; double fp = task_info(mach_task_self(), TASK_VM_INFO, (task_info_t)&vi, &vc) == KERN_SUCCESS ? vi.phys_footprint / 1048576.0 : -1;
      double br = dm_brightness_now();   // footprint / brightness are carried on the on-screen present row: does not depend on the tick-entry observation gate (camp runs have it too)
      if (k) { qsort(v, k, sizeof *v, dcmp); LOG("[nvn] on-screen present up to frame %llu: %u frames, dropped %u (discarded %u), p99 %.2f ms; footprint %.0f MiB; brightness %.2f; thermal %d", frame, k + discard, drop, discard, v[(k * 99) / 100 < k ? (k * 99) / 100 : k - 1], fp, br, dm_thermal_now()); }
      g_presn = 0; }
    { static uint64_t pi, pc, pd, pf; uint64_t ci = atomic_load(&g_cum_sub_instr), cc = atomic_load(&g_cum_sub_cpu_ns), ps_, dr_; mtl_stats(&ps_, &dr_);   // translation layer
      if (pf && frame > pf && dr_ > pd) LOG("[nvn] translation up to frame %llu: %.0f instructions per draw, per-frame submit %.2f M instructions / CPU %.3f ms, %.0f draws per frame", frame,
          (double)(ci - pi) / (double)(dr_ - pd), (ci - pi) / 1e6 / (double)(frame - pf), (cc - pc) / 1e6 / (double)(frame - pf), (double)(dr_ - pd) / (double)(frame - pf));
      { static uint64_t py, pk, pw; uint64_t cy = atomic_load(&g_cum_sub_cyc), ck = atomic_load(&g_cum_sub_sys_ns), cw = atomic_load(&g_cum_sub_wall_ns);
        if (pf && frame > pf && ci > pi && cy > py) { double nf = (double)(frame - pf), cyc = (double)(cy - py), cpu = (double)(cc - pc);
          qos_class_t qc = QOS_CLASS_UNSPECIFIED; int rp = 0; pthread_get_qos_class_np(pthread_self(), &qc, &rp);
          uint64_t aw = 0, ag = 0; int an = 0; void mtl_alloc_stats(uint64_t *, uint64_t *, int *); mtl_alloc_stats(&aw, &ag, &an);
          static uint64_t pyn, pyns; uint64_t yn = 0, yns = 0; dm_main_yield_stats(&yn, &yns);
          LOG("[nvn] translation detail up to frame %llu: per-frame submit cycles %.2f M (%.2f cycles per instruction), CPU %.3f ms of which kernel %.3f ms, wall %.3f ms; avg clock %.2f GHz (cycles / CPU time); this thread QoS %#x; allocator pools %d, cumulative GPU waits %llu; real-time declared computation %.2f ms; main thread yields per frame %.0f / %.3f ms", frame,
              cyc / 1e6 / nf, cyc / (double)(ci - pi), cpu / 1e6 / nf, (double)(ck - pk) / 1e6 / nf, (double)(cw - pw) / 1e6 / nf, cpu > 0 ? cyc / cpu : 0, (unsigned)qc, an, (unsigned long long)aw, g_rt_comp_ms, (double)(yn - pyn) / nf, (double)(yns - pyns) / 1e6 / nf); pyn = yn; pyns = yns; }
        if (frame % 300 == 0) { unsigned wn = 0; uint32_t wq = dm_guest_work_qos(&wn); thread_extended_info_data_t xi; mach_msg_type_number_t xc = THREAD_EXTENDED_INFO_COUNT; int okx = thread_info(pthread_mach_thread_np(pthread_self()), THREAD_EXTENDED_INFO, (thread_info_t)&xi, &xc) == KERN_SUCCESS;
            thread_time_constraint_policy_data_t tp; mach_msg_type_number_t tc = THREAD_TIME_CONSTRAINT_POLICY_COUNT; boolean_t def = 0; int rt_live = thread_policy_get(pthread_mach_thread_np(pthread_self()), THREAD_TIME_CONSTRAINT_POLICY, (thread_policy_t)&tp, &tc, &def) == KERN_SUCCESS && !def;   // def = 1: the real-time policy is not in effect (never set / revoked)
            LOG("[nvn] thread policy: main thread real-time computation %.2f ms / period %.2f ms, real-time policy %s, current priority %d (base %d, sched policy %d); worker threads %u, QoS %#x; present QoS %#x", g_rt_comp_ms, g_rt_period_ms, rt_live ? "active" : "inactive", okx ? xi.pth_curpri : -1, okx ? xi.pth_priority : -1, okx ? xi.pth_policy : -1, wn, wq, mtl_present_qos()); }
        py = cy; pk = ck; pw = cw; }
      pi = ci; pc = cc; pd = dr_; pf = frame; }
    uint64_t up, re, fa, pr; mtl_pkg_stats(&up, &re); nvn_dirty_stats(&fa, &pr);
    LOG("[nvn] packaged textures: first uploads %llu, re-uploads on pool content change %llu; write-protect faults %llu, pages unprotected before host writes %llu; missed detections %llu (cumulative)", up, re, fa, pr, mtl_pkg_miss());
    memset(g_tn, 0, sizeof g_tn);
}
// DM_SLOWFRAME=1 (test switch, read over the log port on a real device): per-frame timings are first stored in a ring of the last 16 frames; dropped frames are judged 8 frames late (GPU / on-screen present times are back by then),
// and only for dropped frames is one line "[slowframe]\t<frame number>\t@<name>=<value>..." written to the log, plus one denominator line every 300 frames. No per-frame file is written: the log tee fsyncs every line, and writing line by line would disturb the readings
#define SRN 16
static struct { uint64_t f; int n; const char *k[64]; double v[64]; } g_sr[SRN];
static int g_slow = -1;
static int slow_on(void) { if (g_slow < 0) g_slow = getenv("DM_SLOWFRAME") != NULL; return g_slow; }
static int frame_rec(void) { return g_tsv || slow_on(); }
static void trow(uint64_t f, const char *name, double v) {
    if (g_tsv) fprintf(g_tsv, "%llu\t%s\t%.3f\n", f, name, v);
    if (slow_on()) { __typeof__(g_sr[0]) *r = &g_sr[f % SRN]; if (r->f != f) { r->f = f; r->n = 0; } if (r->n < 64) { r->k[r->n] = name; r->v[r->n++] = v; } }
}
static double srow(uint64_t f, const char *name, double dflt) {
    __typeof__(g_sr[0]) *r = &g_sr[f % SRN];
    if (r->f == f) for (int i = 0; i < r->n; i++) if (!strcmp(r->k[i], name)) return r->v[i];
    return dflt;
}
// Dropped-frame definition: on-screen present interval > 16.7×1.5 ms or −1; without a window (no on-screen present time) fall back to the present call interval
static void slow_emit(uint64_t f) {
    static uint64_t judged, slow;
    double pm = srow(f, "@presented_ms", 0), fr = srow(f, "@frame_ms", 0), lim = 1000.0 / 60 * 1.5;
    int has = mtl_has_window(), bad = has ? (pm > lim || pm < 0) : fr > lim;
    if (has ? pm != 0 : fr != 0) judged++;
    if (bad) {
        slow++;
        char b[4096]; size_t o = snprintf(b, sizeof b, "[slowframe]\t%llu", f);
        __typeof__(g_sr[0]) *r = &g_sr[f % SRN];
        for (int i = 0; i < r->n && o < sizeof b - 64; i++) o += snprintf(b + o, sizeof b - o, "\t%s=%.3f", r->k[i], r->v[i]);
        double m = 0; for (uint64_t p = f >= 3 ? f - 3 : 0; p < f; p++) { double x = srow(p, "@frame_ms", 0); if (x > m) m = x; }
        snprintf(b + o, sizeof b - o, "\t@prev3_max_frame_ms=%.3f", m);
        fprintf(stderr, "%s\n", b);
    }
    if (f % 300 == 0) fprintf(stderr, "[slowframe]\t#\tup to frame %llu\tjudged=%llu\tslow=%llu\tcriterion=%s\n", f, judged, slow, has ? "on-screen present interval" : "present call interval (no window)");
}
// Declaration for the time-constraint (real-time) thread: period = present period, constraint = period, computation = the CPU time this thread actually needs per frame.
// The computation used to be hard-coded at 2 ms, while the game main thread (game logic + recording + submit replay) takes about 10 ms per frame when hot - a 5× gap between declared and actual:
// a real-time thread that exceeds its declared computation gets demoted by the system, and the performance controller also sets frequency from the declaration (this declaration is how the system learns the frame deadline and the workload).
// DM_RT_COMP=<ms> fixes the declaration; default auto = every 120 frames take the p90 of this thread's per-frame CPU time and re-declare if it differs from the declared value by > 15% (capped at 0.9 × period).
static void set_time_constraint_comp(uint64_t period_ns, uint64_t comp_ns) {
    static mach_timebase_info_data_t tb; if (!tb.denom) mach_timebase_info(&tb);
    if (comp_ns < 1000000ull) comp_ns = 1000000ull; if (comp_ns > period_ns * 9 / 10) comp_ns = period_ns * 9 / 10;
    thread_time_constraint_policy_data_t p = {
        .period = (uint32_t)(period_ns * tb.denom / tb.numer), .computation = (uint32_t)(comp_ns * tb.denom / tb.numer),
        .constraint = (uint32_t)(period_ns * tb.denom / tb.numer), .preemptible = 1};
    kern_return_t kr = thread_policy_set(pthread_mach_thread_np(pthread_self()), THREAD_TIME_CONSTRAINT_POLICY, (thread_policy_t)&p, THREAD_TIME_CONSTRAINT_POLICY_COUNT);
    if (kr == KERN_SUCCESS) { g_rt_comp_ms = comp_ns / 1e6; g_rt_period_ms = period_ns / 1e6; }
    LOG("[nvn] present thread time-constraint policy (period %.3f ms, computation %.3f ms) %s", period_ns / 1e6, comp_ns / 1e6, kr == KERN_SUCCESS ? "set" : "failed to set");
}
static int rt_comp_fixed_ms(void) { static int v = -2; if (v == -2) { const char *e = getenv("DM_RT_COMP"); v = e && *e && strcmp(e, "auto") ? atoi(e) : -1; } return v; }   // −1 = auto
static void set_time_constraint(uint64_t period_ns) { int f = rt_comp_fixed_ms(); set_time_constraint_comp(period_ns, f > 0 ? (uint64_t)f * 1000000ull : 2000000ull); }   // first time: the fixed value, or auto's starting value of 2 ms
// Called every frame at acquire: records this thread's CPU time since the last call; in auto mode re-declares based on p90
static void rt_comp_tick(uint64_t period_ns) {
    if (rt_comp_fixed_ms() > 0 || !period_ns || !g_rt_comp_ms) return;
    static uint64_t last; static double win[120]; static int n;
    uint64_t c = clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID); if (!last) { last = c; return; }
    win[n++] = (double)(c - last) / 1e6; last = c;
    if (n < 120) return;
    double v[120]; memcpy(v, win, sizeof v); qsort(v, 120, sizeof *v, dcmp); n = 0;
    double p90 = v[107], comp = p90 * 1.25, cap = period_ns * 0.9 / 1e6; if (comp > cap) comp = cap; if (comp < 1) comp = 1;
    if (comp > g_rt_comp_ms * 1.15 || comp < g_rt_comp_ms * 0.85) set_time_constraint_comp(period_ns, (uint64_t)(comp * 1e6));
}
static void sleep_until_ns(uint64_t dl) {   // absolute time on the monotonic clock
    static mach_timebase_info_data_t tb; if (!tb.denom) mach_timebase_info(&tb);
    uint64_t now = now_ns(); if (dl <= now) return;
    mach_wait_until(mach_absolute_time() + (dl - now) * tb.denom / tb.numer);
}
// Present is fixed at 60 Hz: the adaptive mechanism stepped down at frame 60 in 24/24 real-device logs and never came back up, so for this phase 60 fps is the hard floor.
// DM_PRESENT_HZ=30..120 sets the rate one present interval stands for (the display link ticks at it): only for a game whose step follows the measured
// frame time (Tears of the Kingdom with its real-time frame step, games/totk/frame_step.c); a game that steps per frame runs at rate / 60 speed.
// DM_PRESENT_HZ=0 (uncapped frame rate) serves only as an explicit performance profiling switch: some of the game's UI logic counts frames (with the same save, uncapped gives
// 4181 SaveIndicatorPanel entries and capped at 60 fps gives 0, which matches the ground truth), so uncapped is a semantically wrong way to run and must not be used as a criterion / cross-check / default. Unit tests set it directly with nvn_present_config
static int g_hz = -1, g_display_mode;
void nvn_present_config(int hz, int display_mode) { g_hz = hz; g_display_mode = display_mode; }
static void present_cfg(const win_t *o) {
    if (g_hz >= 0) return;
    // With a window the default is still display interval mode; without a window the default is game mode. Environment variables can override the fixed 60 Hz.
    int scr = mtl_display_hz();
    const char *e = getenv("DM_PRESENT_HZ"); g_hz = e ? atoi(e) : 60;
    if (g_hz > 0 && (g_hz < 30 || g_hz > 120)) { LOG("[nvn] [red] DM_PRESENT_HZ=%d outside 30..120: 60", g_hz); g_hz = 60; }
    if (g_hz > 0) { void mtl_link_set_rate(int hz); mtl_link_set_rate(g_hz); }
    { int uc = nvn_uncapped_hz(dm_game_realtime_step(), e, getenv("DM_UNCAPPED"), getenv("DM_UNCAPPED_HZ"), scr);
      if (uc) { g_uncapped = 1; g_hz = uc; void mtl_link_set_rate(int hz); mtl_link_set_rate(scr > 0 ? scr : 60);
          LOG("[nvn] uncapped pacing (DM_UNCAPPED=0 turns it off): the game does not wait for the display, our clock paces it at up to %d fps (DM_UNCAPPED_HZ); "
              "the display (%d Hz) shows the newest finished frame at each refresh", uc, scr); } }
    if (!g_hz) LOG("[nvn] [warning] DM_PRESENT_HZ=0: uncapped frame rate, frame pacing differs from a real device and UI logic may diverge (for performance profiling only; not valid for criteria / cross-checks)");
    // Cut (intentional deviation from the original game's behavior): with DM_PRESENT_INTERVAL=display the present interval set by the game is not followed and one frame is presented per display-link tick,
    // with a fixed hard floor of 60 fps; the logic stays at 25 ticks, and the client's frame-counted UI logic is unaffected -
    // with the same save and the same input, the UI message streams of the two modes match message by message. Proof (before character select): r9 game / display 60 ×3 / display 120 ×2, 6 groups in total, uicmp consistent
    // (the save indicator is exempted as a timing race), and the timing differences of key messages are within game mode's own noise band; proof after entering a run is still missing, pending action script coverage
    // A game whose step is per frame (Tears of the Kingdom: its controller picks interval 2 or 3 and every frame advances 1/30 or 1/20 s) runs twice
    // as fast in display mode: game.json present_interval "game" keeps the game's interval with a window too
    const char *m = getenv("DM_PRESENT_INTERVAL"); g_display_mode = m ? !strcmp(m, "display") : scr > 0 && !dm_game.present_game_interval;
    LOG("[nvn] present rate %d Hz, interval mode %s (game-set present interval %d; %s)", g_hz, g_display_mode ? "display (one frame per tick, cut)" : "game (original semantics)", o->interval,
        scr > 0 ? (dm_game.present_game_interval && !m ? "window, game.json present_interval game" : "window") : "no window");
}
static uint64_t present_period(const win_t *o) {
    present_cfg(o);
    int itv = g_display_mode ? 1 : o->interval > 0 ? o->interval : 1, hz = g_hz;
    return hz > 0 ? (uint64_t)itv * 1000000000ull / (uint64_t)hz : 0;
}
int (*g_nvn_loadscreen_up)(void);   // optional game hook: is a loading screen up right now (waits for the pipeline warm-up there; marks long frames hidden behind it)
__attribute__((weak)) void dm_movie_tick(void) {}   // host hle_movie.c: hands paced movie frames over, one per game frame; none in the graphics unit tests
__attribute__((weak)) void dm_game_present(void) {}   // game hook (host/game.h): every present, on the game's thread; none in the graphics unit tests
__attribute__((weak)) int dm_game_realtime_step(void) { return 0; }   // game hook (host/game.h): the game's step follows the measured frame time
NVN(nvnQueuePresentTexture, void, NVNqueue *q, NVNwindow *w, int idx) {
    dm_game_present();
    dm_movie_tick();   // before the core is given away: it signals the game's movie events (guest code)
    NVN_BLOCKING();
    (void)q; win_t *o = (win_t *)w; o->presents++;
    static uint64_t prev_in, prev_out, prev_pass, prev_draw;
    // Loading screen on first entering a run: if the background pipeline warm-up has not finished, wait for it here (the loading screen stays a bit longer), so that after entering the run no pipelines are compiled on the fly on the submit thread. When warm-up finished long ago this passes with a single check
    { static int gate;
      if (!gate && g_nvn_loadscreen_up && g_nvn_loadscreen_up()) { gate = 1; int ms = mtl_warm_wait(15000); if (ms) LOG("[nvn] run-entry loading screen waited %d ms for pipeline warm-up", ms); } }
    present_cfg(o);
    gfx_enter();
    uint64_t t0 = now_ns();
    gfx_mt_enter("PresentTexture");
    if (idx >= 0 && idx < o->ntex && idx < 4) o->ticket[idx] = mtl_present(CTX(o->tex[idx]), present_period(o) / 1e9, o->crop);   // enqueue only, return immediately
    gfx_mt_leave();
    gfx_leave();
    atomic_fetch_add(&g_nvn_ns, now_ns() - t0);
    uint64_t f = g_frame, ps, dr; mtl_stats(&ps, &dr);
    if (nvn_real[0] || nvn_real[1]) {   // DM_NVN_PROF: record phase = time of all implemented functions except submit; submit phase = QueueSubmitCommands
        static unsigned isub = ~0u; static mach_timebase_info_data_t tb; if (!tb.denom) mach_timebase_info(&tb);
        if (isub == ~0u) for (isub = 0; isub < NVN_NFUNC && strcmp(nvn_names[isub], "nvnQueueSubmitCommands"); isub++) {}
        uint64_t rec = 0, sub = 0;
        static uint64_t acc[NVN_NFUNC];
        for (unsigned i = 0; i < NVN_NFUNC; i++) { uint64_t t = atomic_exchange(&nvn_prof_ticks[i], 0); acc[i] += t; if (i == isub) sub = t; else rec += t; }
        if ((g_frame + 1) % TWIN == 0) {   // every 300 frames list the 5 most time-consuming functions
            char line[1024]; size_t o = 0;
            for (int k = 0; k < 5; k++) { unsigned best = 0; for (unsigned i = 1; i < NVN_NFUNC; i++) if (acc[i] > acc[best]) best = i;
                if (!acc[best]) break; o += snprintf(line + o, sizeof line - o, " %s %.2f ms;", nvn_names[best] + 3, acc[best] * tb.numer / tb.denom / 1e6); acc[best] = 0; }
            LOG("[nvn] translation layer top 5 by time (last 300 frames total):%s", line); memset(acc, 0, sizeof acc);
        }
        trow(g_frame, "@rec_ms", rec * tb.numer / tb.denom / 1e6); trow(g_frame, "@submit_ms", sub * tb.numer / tb.denom / 1e6);
        tpush(4, rec * tb.numer / tb.denom / 1e6); tpush(5, sub * tb.numer / tb.denom / 1e6);
    }
    if (prev_in) {
        double fr = (t0 - prev_in) / 1e6, wk = (t0 - prev_out) / 1e6, nv = atomic_exchange(&g_nvn_ns, 0) / 1e6;
        tpush(0, fr); tpush(1, wk); tpush(2, nv);
        trow(f, "@frame_ms", fr); trow(f, "@work_ms", wk); trow(f, "@nvn_ms", nv);
        // Slow-frame attribution (taken only when DM_NVN_TSV is on): this frame's present-thread CPU time (−1 if the thread changed), CPU of all threads in the process, acquire wait accumulated per frame, present call time (same base as the GPU / on-screen present times: ms since process start)
        trow(f, "@wait_ms", g_acq_wait_ns / 1e6); trow(f, "@pq_wait_ms", g_pq_wait_ns / 1e6);
        if (frame_rec()) {
            static pthread_t pth; static uint64_t pcpu, pproc;
            uint64_t c = clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID); pthread_t th = pthread_self();
            trow(f, "@cpu_ms", pcpu && pthread_equal(th, pth) ? (c - pcpu) / 1e6 : -1); pth = th; pcpu = c;
            struct rusage ru; getrusage(RUSAGE_SELF, &ru);
            uint64_t pc = (uint64_t)(ru.ru_utime.tv_sec + ru.ru_stime.tv_sec) * 1000000000ull + (uint64_t)(ru.ru_utime.tv_usec + ru.ru_stime.tv_usec) * 1000ull;
            if (pproc) trow(f, "@proc_cpu_ms", (pc - pproc) / 1e6); pproc = pc;
            trow(f, "@call_ms", (t0 - g_t0_ns) / 1e6);
        }
        trow(f, "@passes", (double)(ps - prev_pass)); trow(f, "@draws", (double)(dr - prev_draw));
        static uint64_t pl, pst, pf, pudc; uint64_t l, st, fu; mtl_bw(&l, &st, &fu);
        trow(f, "@rt_load_mb", (l - pl) / 1048576.0); trow(f, "@rt_store_mb", (st - pst) / 1048576.0); trow(f, "@pass_full_rw", (double)(fu - pf));
        uint64_t udc = mtl_udc_saved_bytes(); trow(f, "@unwritten_dc_mb", (udc - pudc) / 1048576.0);
        pl = l; pst = st; pf = fu; pudc = udc;
        static uint64_t pae, par; uint64_t ae_, ar_; mtl_args_stats(&ae_, &ar_);
        trow(f, "@args_enc", (double)(ae_ - pae)); trow(f, "@args_reuse", (double)(ar_ - par)); pae = ae_; par = ar_;
        static uint64_t puc, pus; uint64_t uc_, us_; mtl_use_stats(&uc_, &us_);
        static uint64_t pdo; uint64_t do_ = mtl_ds_omit(); trow(f, "@ds_omit", (double)(do_ - pdo)); pdo = do_;
        trow(f, "@use_call", (double)(uc_ - puc)); trow(f, "@use_skip", (double)(us_ - pus)); puc = uc_; pus = us_;
        static uint64_t pfa, pre_; uint64_t fa_, pr_, up_, re_; nvn_dirty_stats(&fa_, &pr_); mtl_pkg_stats(&up_, &re_);
        trow(f, "@faults", (double)(fa_ - pfa)); trow(f, "@reuploads", (double)(re_ - pre_)); pfa = fa_; pre_ = re_;
        static uint64_t pmc, pmp, pmn; uint64_t mc_, mpg_, mn_; nvn_dirty_mp_stats(&mc_, &mpg_, &mn_);
        trow(f, "@mprotect_calls", (double)(mc_ - pmc)); trow(f, "@mprotect_pages", (double)(mpg_ - pmp)); trow(f, "@mprotect_ms", (mn_ - pmn) / 1e6); pmc = mc_; pmp = mpg_; pmn = mn_;
        double up_ms = mtl_upload_ns_take() / 1e6; trow(f, "@upload_ms", up_ms);
        trow(f, "@upload_gpu_ms", mtl_upload_gpu_ns_take() / 1e6);
        // Accounting: number of synchronous creations on the submit thread this frame + a timestamp on the same clock as UIMSG (offline, frames are split into front end / loading / in-run by the loading screen intervals)
        static uint64_t plib, ppso; uint64_t lib_, pso_; mtl_create_stats(&lib_, &pso_);
        trow(f, "@lib_new", (double)(lib_ - plib)); trow(f, "@pso_new", (double)(pso_ - ppso));
        {   // long-frame log: this frame's items are first recorded into the ring; whether to print is decided 8 frames later, once the GPU time has arrived (see below)
            static uint64_t plns, ppns, pup, prup, pub; uint64_t lns, pns, up, rup, ub; mtl_create_ns(&lns, &pns); mtl_pkg_stats(&up, &rup); ub = mtl_upload_bytes();
            lf_rec *r = &g_lf[f % LFN]; r->f = f; r->fr = fr; r->nv = nv; r->ls = g_nvn_loadscreen_up ? g_nvn_loadscreen_up() : 0; r->t_s = (now_ns() - g_t0_ns) / 1e9; r->pso = (unsigned)(pso_ - ppso); r->lib = (unsigned)(lib_ - plib);
            r->make_ms = ((lns - plns) + (pns - ppns)) / 1e6; r->up = (unsigned)(up - pup); r->rup = (unsigned)(rup - prup); r->up_mb = (ub - pub) / 1048576.0; r->up_ms = up_ms;
            plns = lns; ppns = pns; pup = up; prup = rup; pub = ub;
        }
        plib = lib_; ppso = pso_;
        trow(f, "@t_s", (now_ns() - g_t0_ns) / 1e9);
        trow(f, "@drawable_ms", mtl_drawable_ns_take() / 1e6);
        trow(f, "@sub_wall_ms", atomic_exchange(&g_sub_wall_ns, 0) / 1e6); trow(f, "@sub_cpu_ms", atomic_exchange(&g_sub_cpu_ns, 0) / 1e6); trow(f, "@sub_instr", (double)atomic_exchange(&g_sub_instr, 0));
    } else atomic_store(&g_nvn_ns, 0);
    g_acq_wait_ns = g_pq_wait_ns = 0;
    if (f >= 8) { double g = mtl_gpu_ms(f - 8); if (g >= 0) { tpush(3, g); trow(f - 8, "@gpu_ms", g); trow(f - 8, "@gpu_sum_ms", mtl_gpu_sum_ms(f - 8)); g_hr[g_hn++ % HRN] = g; }   // GPU time is taken 8 frames late (already completed)
        { lf_rec *r = &g_lf[(f - 8) % LFN];   // long-frame log (on by default, DM_LONGFRAME=0 turns it off): a line is printed only when the whole frame > 20 ms or GPU > 16.7 ms, and it is clearly above recent conditions
          static int on = -1; if (on < 0) { const char *e = getenv("DM_LONGFRAME"); on = !(e && !strcmp(e, "0")); }
          // "Long" is relative to recent conditions: when running steadily at 30 fps (menus / windowless host) or under sustained overload, every frame is > 20 ms; those are not long frames and must not flood the log - a frame has to be 40% above the sliding mean of the last 16 frames to count
          static double ef = 16.7, eg = 8; int lf = r->fr > 20.0 && r->fr > 1.4 * ef, lg = g > 16.7 && g > 1.3 * eg;
          if (r->f == f - 8) { ef += ((r->fr < 3 * ef ? r->fr : 3 * ef) - ef) / 16; eg += ((g < 3 * eg ? g : 3 * eg) - eg) / 16; }
          if (on && r->f == f - 8 && f - 8 > 0 && (lf || lg)) { char b[512];
              snprintf(b, sizeof b, "frame %llu (%.2f s) whole frame %.1f ms, submit+present %.1f ms, GPU %.1f ms; new pipelines %u + shader libraries %u, %.1f ms total; texture uploads: first %u + re-uploads %u, %.1f MB / %.1f ms",
                       (unsigned long long)r->f, r->t_s, r->fr, r->nv, g, r->pso, r->lib, r->make_ms, r->up, r->rup, r->up_mb, r->up_ms);
              // Visibility: during the time a long frame "comes out late", what stays on screen is the previous frame; if the previous frame was a loading screen (or this frame itself is one), all the player sees is the loading screen staying a bit longer, with no motion interrupted
              const lf_rec *pv = &g_lf[(f - 9) % LFN]; int hidden = r->ls || (f >= 9 && pv->f == f - 9 && pv->ls);
              if (hidden) strlcat(b, "; behind loading screen, not visible", sizeof b);
              dm_longframe_note(b); } }
        uint64_t g0, g1; if (frame_rec() && mtl_gpu_span(f - 8, &g0, &g1)) { trow(f - 8, "@gpu_beg_ms", (g0 - g_t0_ns) / 1e6); trow(f - 8, "@gpu_end_ms", (g1 - g_t0_ns) / 1e6); } }
    prev_in = t0; prev_pass = ps; prev_draw = dr;
    dump_frame();
    if (g_frame % TWIN == 0) tsummary(g_frame);
    mtl_set_frame(g_frame);
    // Real-device semantics: present only enqueues and returns immediately; this frame's display time is scheduled by the pacer, and the texture can be acquired again only at "display time + one period" (blocking in AcquireTexture)
    uint64_t period = present_period(o), now = dm_detclock_enabled() ? guest_ns() : now_ns();
    if (test_work_ms() > 0) atomic_store(&g_test_work_from, now_ns());
    nvn_pacer pc = {o->pace};
    uint64_t slot = now + nvn_pace(&pc, now, period);
    o->pace = pc.target;
    if (idx >= 0 && idx < 4) o->avail[idx] = period ? slot + period : 0;
    static uint64_t prev_slot; if (prev_slot && period) trow(f, "@display_ms", (slot - prev_slot) / 1e6); prev_slot = slot;   // display interval between two adjacent frames on screen (this is the one to look at for dropped frames)
    // Actual presentation interval (windowed mode): taken 8 presents late (the presented callback has arrived by then), as the difference between the n-th and the (n−1)-th; −1 = discarded
    if (o->presents > 9) { uint64_t n = o->presents - 8; double a_ = mtl_presented_time(n), b_ = mtl_presented_time(n - 1);
        if (a_ < 0) trow(f - 8, "@presented_ms", -1); else if (a_ > 0 && b_ > 0) trow(f - 8, "@presented_ms", (a_ - b_) * 1e3);
        g_pres_iv[g_presn++ % TWIN] = a_ < 0 ? -1 : (a_ > 0 && b_ > 0 ? (a_ - b_) * 1e3 : 0);
        { double iv_ = a_ < 0 ? -1 : (a_ > 0 && b_ > 0 ? (a_ - b_) * 1e3 : 0); mtl_ub_present(iv_); }   // same-process alternating measurement (DM_NVN_UB) tallies on-screen present intervals per phase; when off it is just one atomic read
        dm_perf_present(a_ < 0 ? -1 : (a_ > 0 && b_ > 0 ? (a_ - b_) * 1e3 : 0));   // on-screen present intervals are also kept in a separate ring; tsummary reports dropped frames every 300 frames (M1 criterion)
        if (a_ > 0) trow(f - 8, "@pres_at_ms", a_ * 1e3 - g_t0_ns / 1e6); }   // on-screen present time (ms since process start; presentedTime shares a time base with mach_absolute_time)
    if (f >= 8 && slow_on()) slow_emit(f - 8);
    prev_out = now_ns();
}
