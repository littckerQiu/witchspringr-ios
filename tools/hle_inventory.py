# HLE audit list: extracts all HLE_FORCE / HLE entries under host plus the libc passthrough table and svc dispatch, and outputs TSV (category, file, line, mangled name, C name, reason, function body line count, body features)
# Body features are only a coarse screening hint (e.g. "only return RES_OK"); the three-way classification (full / simplified / cut) must be decided manually after reading each body.
# Usage: hle_inventory.py [output tsv]
import re, sys, glob, os
H = os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', 'host')
rows = []
def body_of(src, start):
    i = src.index('{', start); d = 0
    for j in range(i, len(src)):
        if src[j] == '{': d += 1
        elif src[j] == '}':
            d -= 1
            if not d: return src[i:j + 1]
    return ''
def feat(b):
    s = re.sub(r'\s+', ' ', b)
    f = []
    if re.fullmatch(r'\{ ?(\(void\)[^;]*; ?)*return (RES_OK|0|RES_FAIL|0x[0-9a-fA-F]+u?|1|true|false); ?\}', s): f.append('returns-constant')
    if 'RES_FAIL' in s: f.append('has-failure-return')
    if re.search(r'LOG\(|die\(', s): f.append('has-log/abort')
    if len(s) < 60: f.append('very-short')
    return ','.join(f)
for fn in sorted(glob.glob(os.path.join(H, 'hle_*.c'))):
    src = open(fn, encoding='utf-8').read()
    for m in re.finditer(r'\bHLE_FORCE\(\s*"([^"]+)"\s*,\s*"((?:[^"\\]|\\.)*)"\s*,\s*([^,]+),\s*(\w+)', src):
        b = body_of(src, m.end()); rows.append(('FORCE', os.path.basename(fn), src[:m.start()].count('\n') + 1, m.group(1), m.group(4), m.group(2), b.count('\n') + 1, feat(b)))
    for m in re.finditer(r'(?<![_A-Z])HLE\(\s*"([^"]+)"\s*,\s*([^,]+),\s*(\w+)', src):
        b = body_of(src, m.end()); rows.append(('HLE', os.path.basename(fn), src[:m.start()].count('\n') + 1, m.group(1), m.group(3), '', b.count('\n') + 1, feat(b)))
src = open(os.path.join(H, 'hle_table.c'), encoding='utf-8').read()
for n in re.findall(r'\bL\((\w+)\)', src): rows.append(('LIBC', 'hle_table.c', 0, n, n, 'libc passthrough', 0, ''))
out = sys.argv[1] if len(sys.argv) > 1 else '/dev/stdout'
with open(out, 'w', encoding='utf-8') as f:
    f.write('category\tfile\tline\tmangled_name\tc_name\treason\tbody_lines\tfeatures\n')
    for r in rows: f.write('\t'.join(map(str, r)) + '\n')
from collections import Counter
print('entries', len(rows), Counter(r[0] for r in rows), file=sys.stderr)
print('returns-constant / very-short:', sum(1 for r in rows if 'returns-constant' in r[7]), file=sys.stderr)
