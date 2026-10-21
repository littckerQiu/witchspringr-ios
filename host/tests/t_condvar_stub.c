// Stubs for t_condvar: host facilities of hle_thread.c that the unit test does not use
#include "../dm.h"
#include "../game.h"
struct dm_flags g_flag;
const dm_game_profile dm_game = { .id = "test" };   // virtual cores off (hle_thread.c reads dm_game.virtual_cores)
pthread_key_t g_key18, g_keytls;   // used by thread pausing to read the x18 / tpidr slots (the unit test does not pause threads)
uint64_t g_t0_ns;
void crash_thread_init(void) {}
void guest_thread_init(void) {}
void dm_thread_enter(uint64_t entry, uint64_t arg, uint64_t sp, uint64_t *top) { (void)entry; (void)arg; (void)sp; (void)top; abort(); }
const uint64_t *dm_hstack_record(uint64_t tsd, uint64_t top) { (void)tsd; (void)top; return NULL; }
#ifndef T_OWN_GUEST_SYM   // t_sysevent provides the SDK functions it needs
void *guest_sym(const char *name) { (void)name; return NULL; }
#endif
module_t *module_of(const void *p) { (void)p; return NULL; }
void dm_prof_add(int id, uint64_t ns, uint64_t bytes) { (void)id; (void)ns; (void)bytes; }
#include <mach/mach_time.h>
uint64_t now_ns(void) { static mach_timebase_info_data_t tb; if (!tb.denom) mach_timebase_info(&tb); return mach_absolute_time() * tb.numer / tb.denom; }
uint64_t guest_ns(void) { return now_ns(); }
int dm_detclock_enabled(void) { return 0; }
