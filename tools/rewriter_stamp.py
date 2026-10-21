#!/usr/bin/env python3
"""The rewriter's stamp: the first 16 hex digits of the SHA-256 of tools/patch_nso.py followed by the game's rules.py (when it has one).
patch_nso.py writes it into each module's fixups.tsv header (# REWRITER), host/Makefile compiles the same value into the host
(DM_REWRITER_STAMP), and the loader says so when a product was made by another rewriter or other rules (rebuild it with
tools/build_product.sh). Idea from mush8's nxpatch stamp (GPL-3.0, idea only).
Usage: rewriter_stamp.py [rules.py]  → prints the stamp"""
import hashlib, os, sys

def stamp(rules=None):
    h = hashlib.sha256(open(os.path.join(os.path.dirname(os.path.abspath(__file__)), 'patch_nso.py'), 'rb').read())
    if rules: h.update(open(rules, 'rb').read())
    return h.hexdigest()[:16]

if __name__ == '__main__':
    print(stamp(sys.argv[1] if len(sys.argv) > 1 and sys.argv[1] else None))
