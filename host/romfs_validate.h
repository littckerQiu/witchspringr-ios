// Checks that a copied RomFS is complete and of the expected version (romfs_validate.c).
#ifndef DM_ROMFS_VALIDATE_H
#define DM_ROMFS_VALIDATE_H
#include <stddef.h>
// dir = the RomFS root (Data/ under it). Returns 1 when complete; why gets the reason it is not, or a one-line summary when it is
int dm_romfs_validate(const char *dir, char *why, size_t why_n);
// Full report for the user: key files present / total and the Data totals; returns the number of problems (0 = complete)
int dm_romfs_report(const char *dir, char *out, size_t out_n);
#endif
