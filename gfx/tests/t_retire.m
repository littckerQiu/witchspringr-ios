// A retired Metal object is really freed when the submit thread drains it (nvn_mtl.m mtl_sub_begin: defer_drain and the drains next to it run in
// their own autorelease pool). The game's submit thread has no pool of its own, so whatever those drains autoreleased stayed alive for good
// (nxnative 0fc0ce4: Metroid Dread's GPU memory grew by gigabytes). Checked with a weak reference, on a thread without a pool, with the
// object's release due before the submission starts (as when the completion handler lost the race to drain it).
#include "../nvn/nvn_mtl.m"
void *front_metal_layer(void) { return NULL; }
module_t *module_of(const void *p) { (void)p; return NULL; }
module_t g_mod[MAX_MOD]; int g_nmod;
void svc_thread_dump(void) {}
uint64_t now_ns(void) { return bp_now(); }
static int fail, count;
#define EXPECT(name, want, got) do { long long w=(want), g=(got); count++; printf("%-72s expected %-4lld → got %-4lld %s\n", name, w, g, w==g?"✓":"✗"); fail += w != g; } while (0)
static int g_alive_after_drain = -1, g_alive_before = -1, g_alive_after_commit = -1; static __weak id<MTLBuffer> g_w;
static void *submit_thread(void *arg) {   // no autorelease pool here, as on a guest thread
    (void)arg;
    __weak id<MTLBuffer> w;
    @autoreleasepool {   // made and retired inside a pool, as in a submission
        id<MTLBuffer> b = [g_dev newBufferWithLength:65536 options:MTLResourceStorageModeShared]; res_add(b); w = b; defer_obj_release(b);
        pthread_mutex_lock(&g_deferred_mu); ((NvDeferredRelease *)g_deferred.lastObject)->fence = 0; pthread_mutex_unlock(&g_deferred_mu);   // due now
    }
    g_alive_before = w != nil;
    mtl_sub_begin();
    g_alive_after_drain = w != nil;
    mtl_wait(mtl_sub_commit(), 5000000000ull);
    g_alive_after_commit = w != nil; g_w = w;
    return NULL;
}
int main(void) { @autoreleasepool {
    setvbuf(stdout, NULL, _IONBF, 0); mtl_init();
    mtl_sub_begin(); mtl_wait(mtl_sub_commit(), 5000000000ull);   // one submission first: the device and the queue exist
    pthread_t t; pthread_create(&t, NULL, submit_thread, NULL); pthread_join(t, NULL);
    EXPECT("the retired buffer is alive until the drain", 1, g_alive_before);
    EXPECT("drained at the start of a submission on a thread without a pool: freed", 0, g_alive_after_drain);
    EXPECT("after that submission has completed", 0, g_alive_after_commit);
    EXPECT("after the thread exited", 0, g_w != nil);
    printf("== %d checks, %d failed ==\n", count, fail); return fail != 0;
} }
