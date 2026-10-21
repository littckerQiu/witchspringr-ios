// A module's rodata read-only after relocation (loader.c; MacNativeGames' loader seals it the same way, MIT): the console maps rodata read-only, so
// a stray write into game constants faults at the writer instead of corrupting them for a later reader. Host pages are 16 KB and the segments 4 KB
// aligned, so a page shared with text keeps read + execute and a page shared with data stays writable: only the pages wholly inside
// [RO_OFF, DATA_OFF), and below the key page, are sealed. Returns the sealed range (empty when rodata spans no whole page). Checked by
// tests/t_guest_mem.c
#pragma once
#include <stdint.h>
#include <sys/mman.h>
static inline int dm_rodata_seal(uint8_t *base, uint64_t text_end, uint64_t ro_off, uint64_t data_off, uint64_t key_page_off, uint64_t *lo, uint64_t *hi) {
    uint64_t a = (ro_off + 0x3FFF) & ~0x3FFFull, rx = (text_end + 0x3FFF) & ~0x3FFFull, b = data_off & ~0x3FFFull;
    if (a < rx) a = rx;
    if (key_page_off && b > key_page_off) b = key_page_off;
    *lo = a; *hi = b > a ? b : a;
    return b > a ? mprotect(base + a, b - a, PROT_READ) : 0;
}
