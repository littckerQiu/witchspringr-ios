#!/usr/bin/env python3
"""games/totk/romfs_overlay.py against the game's own RomFS (path as argument; skipped without it): the overlay archive's two
animations show the capture panes from frame 0.0 and nothing else in the archive differs; the game over flow's Event14 ends
its branch and nothing else differs. Negative controls: a game over flow other than the analysed one, and an archive whose
capture keys are not (0.0 hidden, 1.0 shown), are refused. Nothing of the game data is printed."""
import shutil, struct, sys, tempfile, subprocess
from pathlib import Path
import compression.zstd as zstd
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import romfs_overlay as ro

fails = total = 0
def check(name, ok):
    global fails, total
    total += 1; fails += not ok; print(f'{name:<96} {"✓" if ok else "✗"}')

if len(sys.argv) < 2 or not (Path(sys.argv[1]) / ro.FLOW).exists():
    print('no RomFS given: skipped'); sys.exit(0)
romfs = Path(sys.argv[1]); dicts = ro.dictionaries(romfs)
with tempfile.TemporaryDirectory() as td:
    out = Path(td) / 'overlay'
    r = subprocess.run([sys.executable, '-I', str(Path(ro.__file__)), str(romfs), str(out)], capture_output=True, text=True)
    check('the script ran', r.returncode == 0)
    # the archive: the four capture keys at 0.0, everything else as the original
    raw_o = (romfs / ro.ARCHIVE).read_bytes(); raw_p = (out / ro.ARCHIVE).read_bytes()
    d = dicts[zstd.get_frame_info(raw_o).dictionary_id]
    a_o, a_p = zstd.decompress(raw_o, zstd_dict=d), zstd.decompress(raw_p, zstd_dict=d)
    check('archive: same size decompressed', len(a_o) == len(a_p))
    keys = {}
    for member, panes in ro.MEMBERS.items():
        lo, _ = ro.sarc_members(a_p)[member]
        for pane, ko, k in ro.visibility_keys(a_p, lo):
            if pane in panes: keys[(member, pane)] = k
    check('archive: the four capture panes hidden at 0.0 and shown from 0.0', len(keys) == 4 and all(k == [(0.0, 0), (0.0, 1)] for k in keys.values()))
    check('archive: 8 bytes differ (four floats 1.0 -> 0.0)', sum(x != y for x, y in zip(a_o, a_p)) == 8)
    # the flow: Event14's next is none, two bytes differ
    raw_o = (romfs / ro.FLOW).read_bytes(); raw_p = (out / ro.FLOW).read_bytes()
    d = dicts[zstd.get_frame_info(raw_o).dictionary_id]
    f_o, f_p = zstd.decompress(raw_o, zstd_dict=d), zstd.decompress(raw_p, zstd_dict=d)
    e14 = ro.EVENTS + ro.EVENT_SIZE * 7
    check('flow: Event14 next is none (0xffff)', struct.unpack_from('<H', f_p, e14 + 0xa)[0] == ro.NONE)
    check('flow: exactly those 2 bytes differ', [i for i in range(len(f_o)) if f_o[i] != f_p[i]] == [e14 + 0xa, e14 + 0xb])
    check('manifest: two entries', len([l for l in (out / 'manifest.tsv').read_text().splitlines() if not l.startswith('#')]) == 2)
    # negative controls on copies of the two inputs
    fake = Path(td) / 'fake'
    (fake / ro.FLOW).parent.mkdir(parents=True); (fake / 'Pack').mkdir(parents=True); shutil.copy(romfs / 'Pack/ZsDic.pack.zs', fake / 'Pack/ZsDic.pack.zs')
    bad = bytearray(f_o); bad[-1] ^= 1
    (fake / ro.FLOW).write_bytes(zstd.compress(bytes(bad), zstd_dict=d))
    try: ro.patch_game_over(fake, dicts); refused = False
    except AssertionError: refused = True
    check('negative: a game over flow other than the analysed one is refused', refused)
    (fake / ro.ARCHIVE).parent.mkdir(parents=True)
    da = dicts[zstd.get_frame_info((romfs / ro.ARCHIVE).read_bytes()).dictionary_id]
    (fake / ro.ARCHIVE).write_bytes(zstd.compress(a_p, zstd_dict=da))   # already patched: keys are (0.0, 0.0)
    try: ro.patch_layout(fake, dicts); refused = False
    except AssertionError: refused = True
    check('negative: an archive whose capture keys are not (0.0 hidden, 1.0 shown) is refused', refused)
print(f'== {total} checks, {fails} failed =='); sys.exit(fails != 0)
