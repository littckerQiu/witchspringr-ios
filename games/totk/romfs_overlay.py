#!/usr/bin/env python3
"""Tears of the Kingdom 1.4.3: RomFS overlay files for the native frame rates (the host serves them first, DM_ROMFS_OVERLAY).

1. UI/LayoutArchive/Common.Product.140.Nin_NX_NVN.blarc.zs, members anim/ShortCutBG_00_In.bflan (panes C_CaptureBG_00,
   C_CaptureClearBG_00, P_CaptureClearBG_00) and anim/AutoBuilder_00_In.bflan (C_CaptureBG_00): the weapon / shield /
   material quick menus take the game picture for their background when these panes become visible at animation frame
   1.0. UI animations advance 0.5 frames a game frame at 60 fps, so the capture lands after the world has stopped
   drawing and the background is black. The visibility keys move to frame 0.0: the capture takes the live world.
2. Event/EventFlow/DmF_SY_GameOver.bfevfl.zs: after Retry / Quit the game over flow requests GameOverPause (Event14)
   and then waits one frame (Event25, EventWait Frames 1). With a real-time frame step below one frame (60 fps and up)
   the wait needs several frames, the pause freezes it after the first and the menu never goes away. Event14 now ends
   its branch (its next-event index from Event25 to none). Pinned to the analysed file by its SHA-256.

Findings and offsets from MacNativeGames' scripts/make_romfs_patches.py (ly05010419/MacNativeGames, MIT), written anew
here: SARC / BFLAN / BFEVFL are parsed and every change is checked (only the intended bytes differ, the zstd frame keeps
its dictionary and size, a decompression gives the patched bytes back).

Input: the game's RomFS folder (game.json workspace.romfs). Output: <out>/<path> and <out>/manifest.tsv (path, size,
SHA-256 of the overlay, SHA-256 of the original). Game data stays in the ignored work folder; nothing of it is printed.
"""
import argparse, hashlib, json, struct, sys
from pathlib import Path
import compression.zstd as zstd

ARCHIVE = 'UI/LayoutArchive/Common.Product.140.Nin_NX_NVN.blarc.zs'
MEMBERS = {'anim/ShortCutBG_00_In.bflan': ('C_CaptureBG_00', 'C_CaptureClearBG_00', 'P_CaptureClearBG_00'),
           'anim/AutoBuilder_00_In.bflan': ('C_CaptureBG_00',)}
FLOW = 'Event/EventFlow/DmF_SY_GameOver.bfevfl.zs'
FLOW_SHA256 = 'c59975494fb30063b7a339fd66bbde8b456b11c73a5b4332bc070d63ece66b7d'   # the decompressed file the event offsets below come from
EVENTS, EVENT_SIZE = 0x1f0, 0x28   # BFEVFL events: name reference at +0, type at +8, next event at +0xa
NONE = 0xffff


def sarc_members(data):
    """name -> (start, end) of every SARC member"""
    assert data[:4] == b'SARC' and data[6:8] == b'\xff\xfe', 'not a little-endian SARC'
    header, size, start = struct.unpack_from('<HxxII', data, 4)
    assert size == len(data) and data[header:header + 4] == b'SFAT'
    count = struct.unpack_from('<H', data, header + 6)[0]
    names = header + 12 + count * 16
    assert data[names:names + 4] == b'SFNT'
    names += 8
    out = {}
    for i in range(count):
        _, attribute, lo, hi = struct.unpack_from('<4I', data, header + 12 + i * 16)
        at = names + (attribute & 0xffffff) * 4
        out[data[at:data.index(0, at, start)].decode()] = (start + lo, start + hi)
    return out


def visibility_keys(data, base):
    """(pane, offset of its first key, [(frame, value)]) of every FLVI step track of the BFLAN at data[base:]"""
    assert data[base:base + 4] == b'FLAN' and data[base + 4:base + 6] == b'\xff\xfe', 'not a little-endian BFLAN'
    pos, out = base + 0x14, []
    for _ in range(struct.unpack_from('<H', data, base + 0x10)[0]):
        magic, size = data[pos:pos + 4], struct.unpack_from('<I', data, pos + 4)[0]
        if magic == b'pai1':
            count, table = struct.unpack_from('<H', data, pos + 14)[0], pos + struct.unpack_from('<I', data, pos + 16)[0]
            for e in range(count):
                eo = pos + struct.unpack_from('<I', data, table + 4 * e)[0]
                pane = data[eo:eo + 28].split(b'\0')[0].decode()
                for t in range(data[eo + 28]):
                    to = eo + struct.unpack_from('<I', data, eo + 32 + 4 * t)[0]
                    if data[to:to + 4] != b'FLVI':
                        continue
                    for g in range(data[to + 4]):
                        go = to + struct.unpack_from('<I', data, to + 8 + 4 * g)[0]
                        assert data[go + 2] == 1, 'visibility tracks are step curves'
                        ko = go + struct.unpack_from('<I', data, go + 8)[0]
                        n = struct.unpack_from('<H', data, go + 4)[0]
                        out.append((pane, ko, [struct.unpack_from('<fH', data, ko + 8 * k) for k in range(n)]))
        pos += size
    return out


def dictionaries(romfs):
    pack = zstd.decompress((romfs / 'Pack/ZsDic.pack.zs').read_bytes())
    out = {}
    for lo, hi in sarc_members(pack).values():
        d = zstd.ZstdDict(pack[lo:hi]); out[d.dict_id] = d
    return out


def recompress(original_raw, patched, dicts):
    info = zstd.get_frame_info(original_raw)
    d = dicts[info.dictionary_id]
    data = zstd.compress(bytes(patched), level=19, zstd_dict=d)
    check = zstd.get_frame_info(data)
    assert check.dictionary_id == info.dictionary_id and check.decompressed_size == len(patched), 'recompressed frame differs in dictionary or size'
    assert zstd.decompress(data, zstd_dict=d) == bytes(patched), 'recompressed frame does not give the patched bytes back'
    return data


def patch_layout(romfs, dicts):
    raw = (romfs / ARCHIVE).read_bytes()
    info = zstd.get_frame_info(raw)
    original = zstd.decompress(raw, zstd_dict=dicts[info.dictionary_id])
    blarc = bytearray(original)
    members = sarc_members(blarc)
    changed = {}
    for member, panes in MEMBERS.items():
        lo, hi = members[member]
        done = []
        for pane, ko, keys in visibility_keys(blarc, lo):
            if pane not in panes:
                continue
            assert keys == [(0.0, 0), (1.0, 1)], f'{member} {pane}: visibility keys are not hidden at 0, shown at 1'
            struct.pack_into('<f', blarc, ko + 8, 0.0)
            done.append(pane)
        assert sorted(done) == sorted(panes), f'{member}: panes found {done}'
        changed[member] = done
    diff = [i for i in range(len(original)) if original[i] != blarc[i]]
    assert diff and all(any(members[m][0] <= i < members[m][1] for m in MEMBERS) for i in diff), 'bytes outside the two animations changed'
    return raw, recompress(raw, blarc, dicts), {'members': changed, 'changed_bytes': len(diff)}


def patch_game_over(romfs, dicts):
    raw = (romfs / FLOW).read_bytes()
    info = zstd.get_frame_info(raw)
    flow = bytearray(zstd.decompress(raw, zstd_dict=dicts[info.dictionary_id]))
    assert hashlib.sha256(flow).hexdigest() == FLOW_SHA256, f'{FLOW} is not the analysed file'

    def event(i):
        e = EVENTS + EVENT_SIZE * i
        ref = struct.unpack_from('<Q', flow, e)[0]
        n = struct.unpack_from('<H', flow, ref)[0]
        return e, flow[ref + 2:ref + 2 + n].decode(), flow[e + 8], struct.unpack_from('<H', flow, e + 0xa)[0]
    e14, name14, type14, next14 = event(7)
    _, name25, type25, next25 = event(25)
    assert (name14, type14, next14) == ('Event14', 0, 25) and (name25, type25, next25) == ('Event25', 0, NONE), 'game over flow layout differs'
    struct.pack_into('<H', flow, e14 + 0xa, NONE)
    return raw, recompress(raw, flow, dicts), {'event': 'Event14 next: Event25 (wait one frame) -> none', 'changed_bytes': 2}


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('romfs', type=Path, help='the RomFS folder of 1.4.3')
    ap.add_argument('out', type=Path, help='overlay folder to write')
    a = ap.parse_args()
    dicts = dictionaries(a.romfs)
    lines = []
    for path, fn in ((ARCHIVE, patch_layout), (FLOW, patch_game_over)):
        raw, data, what = fn(a.romfs, dicts)
        target = a.out / path
        target.parent.mkdir(parents=True, exist_ok=True)
        tmp = target.with_suffix(target.suffix + '.tmp'); tmp.write_bytes(data); tmp.replace(target)
        lines.append('\t'.join([path, str(len(data)), hashlib.sha256(data).hexdigest(), hashlib.sha256(raw).hexdigest()]))
        print(json.dumps(dict(status='pass', path=path, size=len(data), **what)))
    (a.out / 'manifest.tsv').write_text('# path\tsize\tsha256\toriginal_sha256 (games/totk/romfs_overlay.py)\n' + '\n'.join(lines) + '\n')


if __name__ == '__main__':
    sys.exit(main())
