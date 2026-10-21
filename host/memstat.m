// Memory accounting: when DM_MEMSTAT=<tsv path> is set, one line is logged per second (common to Mac / iOS).
//   Totals: phys_footprint (task_info TASK_VM_INFO, which the iOS memory limit is based on), os_proc_available_memory (iOS only), Metal currentAllocatedSize
//   Breakdown: walk this process's VM regions (vm_region_recurse_64, VM_REGION_SUBMAP_INFO_64), classify by region, and for each class record
//         virtual = address space size (reserved-only counts too), resident = pages_resident, charged = dirty pages + compressed/swapped-out pages, deduplicated by VM object (≈ the part that goes into phys_footprint)
//         dedup key = (object id, offset within the object); reason for dedup: Metal wraps the guest memory pool with "no copy", so the same object is mapped in several places (share_mode TRUESHARED, ref_count>1), and summing region by region would double count;
// measured on Mac, after per-object dedup Σcharged is 2,139 MiB against phys_footprint 2,111 MiB (+1.3%)
//   Classes: guest (the whole guest address space block, including the SetHeapSize heap, alias, stacks; data read from RomFS through pread also lands here), code (embedded / loaded module images),
//         malloc (host heap), gpu (IOAccelerator / IOSurface / Metal tagged regions), stack, file (file mappings), other
//   The part where charged ≠ phys_footprint (GPU private memory accounted by IOKit is not in any VM region) is listed separately as "unattributed" = footprint − Σcharged.
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#include <TargetConditionals.h>
#include <mach/mach.h>
#include <mach/vm_statistics.h>
#if TARGET_OS_IPHONE
#include <os/proc.h>
#endif
#include "dm.h"

void svc_guest_range(uint8_t **base, size_t *size);
void dm_alias_stat(size_t *mapped_mb, size_t *host_mb);
unsigned long long mtl_gpu_allocated_mb(void);
void mtl_mem_census(char *out, size_t n);
void svc_guest_layout(uint8_t **alias, size_t *alias_n, uint8_t **stack, size_t *stack_n, uint8_t **heap, size_t *heap_n);
// guest = the rest of the guest address space block; g_alias / g_stack / g_heap = its alias region, stack region and heap (a VM region is counted
// where it starts: the kernel may merge neighbouring regions with the same attributes across a boundary)
enum { C_GUEST, C_CODE, C_MALLOC, C_GPU, C_STACK, C_FILE, C_OTHER, C_GALIAS, C_GSTACK, C_GHEAP, NC };
static const char *k_cls[NC] = {"guest", "code", "malloc", "gpu", "stack", "file", "other", "g_alias", "g_stack", "g_heap"};

static int classify(vm_address_t a, const vm_region_submap_info_data_64_t *in) {
    uint8_t *gb; size_t gs; svc_guest_range(&gb, &gs);
    if (gb && a >= (vm_address_t)gb && a < (vm_address_t)gb + gs) {
        uint8_t *al, *st, *hp; size_t aln, stn, hpn; svc_guest_layout(&al, &aln, &st, &stn, &hp, &hpn); uint8_t *p = (uint8_t *)a;
        return p >= al && p < al + aln ? C_GALIAS : p >= st && p < st + stn ? C_GSTACK : p >= hp && p < hp + hpn ? C_GHEAP : C_GUEST;
    }
    for (int i = 0; i < g_nmod; i++)
        if (a >= (vm_address_t)g_mod[i].base && a < (vm_address_t)g_mod[i].base + g_mod[i].size) return C_CODE;
    switch (in->user_tag) {
        case VM_MEMORY_MALLOC: case VM_MEMORY_MALLOC_SMALL: case VM_MEMORY_MALLOC_LARGE: case VM_MEMORY_MALLOC_HUGE:
        case VM_MEMORY_MALLOC_TINY: case VM_MEMORY_MALLOC_LARGE_REUSABLE: case VM_MEMORY_MALLOC_LARGE_REUSED:
        case VM_MEMORY_MALLOC_NANO: case VM_MEMORY_MALLOC_MEDIUM: return C_MALLOC;
        case VM_MEMORY_IOACCELERATOR: case VM_MEMORY_IOSURFACE: case VM_MEMORY_IOKIT: return C_GPU;
        case VM_MEMORY_STACK: return C_STACK;
    }
    if (in->external_pager) return C_FILE;
    return C_OTHER;
}

// DM_MEMSTAT_DUMP=seconds: at that second, write every VM region ≥1 MiB line by line to <tsv>.regions (for diagnosing the accounting method)
static void dump_regions(const char *path) {
    FILE *f = fopen(path, "w"); if (!f) return;
    fprintf(f, "start\tsize_MiB\tclass\tuser_tag\tshare_mode\tobj_id\tref_count\tresident_MiB\tdirty_MiB\tswapped_MiB\tfile\n");
    vm_address_t a = 0; vm_size_t sz; natural_t depth = 0; vm_size_t pg = vm_page_size;
    for (;;) {
        vm_region_submap_info_data_64_t in; mach_msg_type_number_t cnt = VM_REGION_SUBMAP_INFO_COUNT_64;
        if (vm_region_recurse_64(mach_task_self(), &a, &sz, &depth, (vm_region_recurse_info_t)&in, &cnt) != KERN_SUCCESS) break;
        if (in.is_submap) { depth++; continue; }
        if (((uint64_t)in.pages_resident * pg >> 20) >= 1 || sz >= (64ull << 20))
            fprintf(f, "%#lx\t%lu\t%s\t%u\t%u\t%#x\t%u\t%llu\t%llu\t%llu\t%d\n", a, sz >> 20, k_cls[classify(a, &in)], in.user_tag, in.share_mode,
                    in.object_id, in.ref_count, (uint64_t)in.pages_resident * pg >> 20, (uint64_t)in.pages_dirtied * pg >> 20, (uint64_t)in.pages_swapped_out * pg >> 20, in.external_pager);
        a += sz;
    }
    fclose(f);
}

// Walk this process's VM regions: virtual / resident / charged per class (charged counts each object once). Serialized: the dedup table is shared
// by the per-second sample and the low-memory watch
static void walk(uint64_t virt[NC], uint64_t res[NC], uint64_t bill[NC]) {
    static pthread_mutex_t mu = PTHREAD_MUTEX_INITIALIZER; pthread_mutex_lock(&mu);
    static uint32_t seen[1 << 16]; static uint32_t gen; gen++; if (!gen) { memset(seen, 0, sizeof seen); gen = 1; }   // Objects already counted in this sample (open addressing)
    vm_address_t a = 0; vm_size_t sz; natural_t depth = 0; vm_size_t pg = vm_page_size;
    for (;;) {
        vm_region_submap_info_data_64_t in; mach_msg_type_number_t cnt = VM_REGION_SUBMAP_INFO_COUNT_64;
        if (vm_region_recurse_64(mach_task_self(), &a, &sz, &depth, (vm_region_recurse_info_t)&in, &cnt) != KERN_SUCCESS) break;
        if (in.is_submap) { depth++; continue; }
        int c = classify(a, &in);
        virt[c] += sz; res[c] += (uint64_t)in.pages_resident * pg;
        if (!in.external_pager) {                             // File pages are reclaimable and do not count toward footprint
            static uint64_t key[1 << 16];                     // Key = (object id, offset within the object): the pieces of one object split apart by mprotect cover different pages and must not be merged
            uint64_t k = (uint64_t)in.object_id << 32 ^ (in.offset >> 14);
            uint32_t h = (uint32_t)((k * 0x9E3779B97F4A7C15ull) >> 48), dup = 0;
            while (seen[h] == gen) { if (key[h] == k) { dup = 1; break; } h = (h + 1) & 0xFFFF; }
            if (!dup) { seen[h] = gen; key[h] = k; bill[c] += ((uint64_t)in.pages_dirtied + in.pages_swapped_out) * pg; }
        }
        a += sz; continue;
    }
    pthread_mutex_unlock(&mu);
}

static void sample(FILE *f, double t, id<MTLDevice> dev) {
    task_vm_info_data_t vi; mach_msg_type_number_t n = TASK_VM_INFO_COUNT;
    uint64_t fp = task_info(mach_task_self(), TASK_VM_INFO, (task_info_t)&vi, &n) == KERN_SUCCESS ? vi.phys_footprint : 0;
    uint64_t avail = 0;
#if TARGET_OS_IPHONE
    avail = os_proc_available_memory();
#endif
    uint64_t virt[NC] = {0}, res[NC] = {0}, bill[NC] = {0};
    walk(virt, res, bill);
    uint64_t sum = 0; for (int c = 0; c < NC; c++) sum += bill[c];
    size_t am, ah; dm_alias_stat(&am, &ah);
    fprintf(f, "%.0f\t%llu\t%llu\t%llu\t%llu\t%llu\t%lld\t%lld", t, fp >> 20, avail >> 20, (unsigned long long)(dev.currentAllocatedSize >> 20),
            vi.internal >> 20, vi.compressed >> 20, (vi.ledger_tag_graphics_footprint + vi.ledger_tag_graphics_footprint_compressed) >> 20,
            (long long)(vi.limit_bytes_remaining >> 20));
    for (int c = 0; c < NC; c++) fprintf(f, "\t%llu/%llu/%llu", virt[c] >> 20, res[c] >> 20, bill[c] >> 20);
    fprintf(f, "\t%llu\t%lld\t%zu\t%zu\t%llu\n", sum >> 20, ((int64_t)fp - (int64_t)sum) >> 20, am, ah, (unsigned long long)dm_nvn_frame_count());
    fflush(f);
}

static void *memstat_thread(void *p) {
    FILE *f = fopen((const char *)p, "w");
    if (!f) { LOG("memstat: cannot open %s", (const char *)p); return NULL; }
    fprintf(f, "# MiB; kernel ledgers internal / compressed / graphics / headroom; class columns = virtual/resident/charged (objects counted once); charged_total = Σ private charged; unattributed = phys_footprint − charged_total; "
               "alias_mapped / alias_hostpages = alias region mapped by the game / host pages that mapping keeps in use; frame = NVN frames presented\ns\tphys_footprint\tavailable\tmetal_alloc\tinternal\tcompressed\tgraphics\theadroom");
    for (int c = 0; c < NC; c++) fprintf(f, "\t%s", k_cls[c]);
    fprintf(f, "\tcharged_total\tunattributed\talias_mapped\talias_hostpages\tframe\n");
    id<MTLDevice> dev = MTLCreateSystemDefaultDevice();   // The same device object as the graphics backend (the system default device singleton)
    uint64_t t0 = now_ns();
    const char *ds = getenv("DM_MEMSTAT_DUMP"); int dump_at = ds ? atoi(ds) : -1;
    char dp[1100]; snprintf(dp, sizeof dp, "%s.regions", (const char *)p);
    for (int sec = 0;; sec++) { sample(f, (now_ns() - t0) / 1e9, dev); if (sec == dump_at) dump_regions(dp); sleep(1); }
    return NULL;
}

__attribute__((constructor)) static void memstat_start(void) {
    const char *p = getenv("DM_MEMSTAT");
    if (!p || !*p) return;
    char *path = strdup(p);
#if TARGET_OS_IPHONE
    if (*p != '/') { size_t n = strlen(getenv("HOME")) + strlen(p) + 16; path = malloc(n); snprintf(path, n, "%s/Documents/%s", getenv("HOME"), p); }   // Relative name → the container's Documents (the container path is not known before launch)
#endif
    pthread_t th; pthread_create(&th, NULL, memstat_thread, path); pthread_detach(th);
}

// ---------- Low-memory watch: always on on iOS; on the Mac only with DM_TEST_MEM_LIMIT_MB=<MB>, which stands in for the iOS limit (limit − footprint) ----------
// The system kills a process that crosses its memory limit with SIGKILL and may save no report at all, and the memory line is printed every 300
// frames at most: a spike inside one scene load goes unrecorded (an iPad session ended this way two minutes into a trial's loading). This thread
// reads the distance to the limit every 50 ms and logs one line each time it falls below the next step, re-arming a step once the distance is back
// 256 MB above it. While below 1024 MB, dm_mem_low() lets the memory line ignore its line cap.
#include <stdatomic.h>
static _Atomic int g_mem_low;
int dm_mem_low(void) { return atomic_load(&g_mem_low); }
static void *memwatch_thread(void *p) {
    long test_limit = (long)(intptr_t)p;
    static const long step[] = {1024, 768, 512, 384, 256, 192, 128, 64}; enum { NSTEP = sizeof step / sizeof *step };
    int armed[NSTEP]; for (int i = 0; i < NSTEP; i++) armed[i] = 1;
    long last_fp = 0;
    for (;;) {
        usleep(50000);
        task_vm_info_data_t vi; mach_msg_type_number_t n = TASK_VM_INFO_COUNT;
        long fp = task_info(mach_task_self(), TASK_VM_INFO, (task_info_t)&vi, &n) == KERN_SUCCESS ? (long)(vi.phys_footprint >> 20) : 0, left;
#if TARGET_OS_IPHONE
        (void)test_limit; left = (long)(os_proc_available_memory() >> 20);
        if (!left) continue;   // no reading (not limited)
#else
        left = test_limit - fp;
#endif
        atomic_store(&g_mem_low, left < 1024);
        for (int i = 0; i < NSTEP; i++) {
            if (!armed[i] && left > step[i] + 256) armed[i] = 1;
            if (!armed[i] || left >= step[i]) continue;
            int j = i; while (j + 1 < NSTEP && left < step[j + 1]) armed[j++] = 0;   // a jump past several steps logs once, for the lowest
            armed[j] = 0;
            size_t am, ah; dm_alias_stat(&am, &ah);
            LOG("memory low: %ld MB left to the system memory limit (below %ld MB) at frame %llu, %.1f s: footprint %ld MB (%+ld MB in the last 50 ms), Metal allocated %llu MB, "
                "alias region mapped %zu MB in %zu MB of host pages", left, step[j], (unsigned long long)dm_nvn_frame_count(), (now_ns() - g_t0_ns) / 1e9,
                fp, last_fp ? fp - last_fp : 0, mtl_gpu_allocated_mb(), am, ah);
            // What the footprint is made of right now (one region walk, a few ms): charged per class; "GPU private" = footprint not in any VM region (Metal private storage)
            uint64_t virt[NC] = {0}, res[NC] = {0}, bill[NC] = {0}, sum = 0; walk(virt, res, bill); for (int c = 0; c < NC; c++) sum += bill[c];
            n = TASK_VM_INFO_COUNT; long fp2 = task_info(mach_task_self(), TASK_VM_INFO, (task_info_t)&vi, &n) == KERN_SUCCESS ? (long)(vi.phys_footprint >> 20) : fp;
            LOG("memory low: breakdown: footprint %ld MB = guest %llu (alias region %llu, stack region %llu, heap %llu) + malloc %llu + code %llu + GPU-tagged regions %llu + other %llu + GPU private %lld MB; graphics ledger %llu MB, compressed %llu MB",
                fp2, (bill[C_GUEST] + bill[C_GALIAS] + bill[C_GSTACK] + bill[C_GHEAP]) >> 20, bill[C_GALIAS] >> 20, bill[C_GSTACK] >> 20, bill[C_GHEAP] >> 20, bill[C_MALLOC] >> 20, bill[C_CODE] >> 20, bill[C_GPU] >> 20, (bill[C_STACK] + bill[C_FILE] + bill[C_OTHER]) >> 20,
                (long long)fp2 - (long long)(sum >> 20), (vi.ledger_tag_graphics_footprint + vi.ledger_tag_graphics_footprint_compressed) >> 20, vi.compressed >> 20);
            char census[1024]; mtl_mem_census(census, sizeof census); LOG("memory low: Metal objects: %s", census);
            break;
        }
        last_fp = fp;
    }
    return NULL;
}
__attribute__((constructor)) static void memwatch_start(void) {
    long limit = 0;
#if !TARGET_OS_IPHONE
    const char *e = getenv("DM_TEST_MEM_LIMIT_MB"); if (!e || (limit = atol(e)) <= 0) return;
#endif
    pthread_t th; pthread_create(&th, NULL, memwatch_thread, (void *)(intptr_t)limit); pthread_detach(th);
}

// ---------- Per-thread CPU: DM_THRCPU=<tsv path>[,interval in seconds (default 10)] (common to Mac / iOS; on iOS a relative name → the container's Documents) ----------
// Every interval, walk all threads of this process (task_threads), take the thread name and user + system CPU time (ns) from THREAD_EXTENDED_INFO, and difference them by thread id:
// each line is "seconds, thread id, thread name, CPU% (100 = one core)"; the last line is "seconds, -, total, CPU%". Used for heat attribution (which thread eats CPU); enable together with DM_HEAT to compare against thermal state.
#include <mach/thread_info.h>
#define THR_MAX 512
static void *thrcpu_thread(void *p) {
    char path[1024]; int iv = 10; { const char *c = strchr((const char *)p, ','); snprintf(path, sizeof path, "%.*s", c ? (int)(c - (const char *)p) : (int)strlen(p), (const char *)p); if (c) iv = atoi(c + 1); }
    FILE *f = fopen(path, "w"); if (!f) return NULL;
    fprintf(f, "s\tthread\tname\tCPU%%\n"); fflush(f);
    static uint64_t ids[THR_MAX], last[THR_MAX]; int n = 0; uint64_t t0 = now_ns(), tl = t0;
    for (;;) {
        sleep(iv); uint64_t t = now_ns(); double dt = (t - tl) / 1e9, tot = 0; tl = t;
        thread_act_array_t th; mach_msg_type_number_t nt = 0;
        if (task_threads(mach_task_self(), &th, &nt) != KERN_SUCCESS) continue;
        for (mach_msg_type_number_t i = 0; i < nt; i++) {
            thread_extended_info_data_t ei; mach_msg_type_number_t c1 = THREAD_EXTENDED_INFO_COUNT;
            thread_identifier_info_data_t ii; mach_msg_type_number_t c2 = THREAD_IDENTIFIER_INFO_COUNT;
            if (thread_info(th[i], THREAD_EXTENDED_INFO, (thread_info_t)&ei, &c1) == KERN_SUCCESS && thread_info(th[i], THREAD_IDENTIFIER_INFO, (thread_info_t)&ii, &c2) == KERN_SUCCESS) {
                uint64_t cpu = ei.pth_user_time + ei.pth_system_time; int k = 0; while (k < n && ids[k] != ii.thread_id) k++;
                if (k == n && n < THR_MAX) { ids[n] = ii.thread_id; last[n] = cpu; n++; }   // New thread: only record the baseline this round
                else if (k < n) { double pct = (cpu - last[k]) / 1e9 / dt * 100; last[k] = cpu; tot += pct;
                    if (pct >= 0.5) { char gn[96]; int thr_name_of(pthread_t, char *, size_t); pthread_t pt = pthread_from_mach_thread_np(th[i]);
                        const char *nm = pt && thr_name_of(pt, gn, sizeof gn) ? gn : ei.pth_name[0] ? ei.pth_name : "-";   // Guest thread: handle + guest name; host thread: pthread name
                        fprintf(f, "%.0f\t%llu\t%s\t%.1f\n", (t - t0) / 1e9, ii.thread_id, nm, pct); } }
            }
            mach_port_deallocate(mach_task_self(), th[i]);
        }
        vm_deallocate(mach_task_self(), (vm_address_t)th, nt * sizeof *th);
        fprintf(f, "%.0f\t-\ttotal\t%.1f\n", (t - t0) / 1e9, tot); fflush(f);
    }
    return NULL;
}
__attribute__((constructor)) static void thrcpu_start(void) {
    const char *p = getenv("DM_THRCPU");
    if (!p || !*p) return;
    char *spec = strdup(p);
#if TARGET_OS_IPHONE
    if (*p != '/') { size_t n = strlen(getenv("HOME")) + strlen(p) + 16; spec = malloc(n); snprintf(spec, n, "%s/Documents/%s", getenv("HOME"), p); }
#endif
    pthread_t th; pthread_create(&th, NULL, thrcpu_thread, spec); pthread_detach(th);
}
