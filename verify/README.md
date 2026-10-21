# verify — rewrite equivalence

The rewriter (`tools/patch_nso.py`) changes a few thousand instructions per module so the game's code can run under Apple's kernel. This directory
checks that the rewritten modules behave exactly like the originals, without running the game: structurally (word by word), per rewrite site,
per function, and for the host gates. It needs the dumped ExeFS and the product, nothing else, and takes seconds.

```sh
pip install -r tools/requirements.txt          # capstone, lz4, unicorn
verify/regress.sh                              # the profile's product and modules (DM_GAME, DM_ROOT)
verify/regress.sh --fresh --fuzz               # rebuild the product first, also run the function fuzzer
```

The last line is `REGRESS OK|FAIL <product>`, exit code 1 on any failure; the log is `$DM_ROOT/run/verify/dm/regress_<time>.log`. Options:
`--struct-only` (skip `equiv.py`), `--fuzz` (add `fnfuzz.py`), `--fresh` (rebuild the product with `tools/build_product.sh` into
`run/verify/dm/fresh/`, verify that, and report which files differ from the given product). Environment: `DM_PY` (default
`$DM_ROOT/build/cache/dm/venv/bin/python`), `DM_NSO_DIR`, `SEED`, `JOBS`, `LLVM_BIN`.

## The checks

| Tool | What it verifies |
|---|---|
| `structck.py` | **Structure**, without executing anything: outside cuts, non-code segments are byte-identical to the original; the changed code words are exactly the rewrite sites; an independent disassembler (Xcode's `llvm-objdump`, or `LLVM_BIN`) recounts every instruction that must be rewritten, none missed or extra; the patch area holds none of them; every host gate, observation gate and parameter gate equals its template and matches `gates.tsv`; temporary registers in patch blocks are saved and restored in the red zone; every trampoline exits only to a legal place; cuts that add host calls have a valid form. The numbered list is in the file header |
| `equiv.py` | **Per site**: in Unicorn, from many random states, the original instruction(s) and the patch block are executed and everything is compared (general and vector registers, flags, sp, memory writes, end address, faults). Conditional branches inside windows are forced both ways. A mutation self-check breaks a sample of patch blocks; every one must be caught |
| `fnfuzz.py` | **Per function** (`--fuzz`): every function containing a rewrite site runs whole in the original and in the rewritten image from the same random input, until return, an import call, a host gate, a fault or a budget; final registers and written memory are compared. Leftover red-zone scratch that a later frame has not initialized yet is not a difference. Also has a mutation self-check |
| `gatefn/` | **Host gates**: a test bench built from the host's current `host/entry.S` runs every gate in `gates.tsv` and checks the register write-back contract |
| `nsoimg.py` | NSO → memory image, shared by the tools above |

What these prove is that the rewrite preserves behavior. Whether the host's services and the graphics layer behave like the console is a
different question, answered by running the game (`host/`, `gfx/` tests, screenshots).
