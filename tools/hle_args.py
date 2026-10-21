#!/usr/bin/env python3
"""Host functions the guest calls must take every argument in a register: they run on the thread's host stack (host/hstack.S), so an
argument the guest put on its stack would be read from the wrong place, and Apple's arm64 passes variadic arguments on the stack where
Switch code passes them in registers. Checks the HLE / HLE_FORCE / HLE_FORCE_OPT / NVN_NOPROTO definitions and the host vtables handed to
the guest (static void *const g_*_vt[] = {...}, their functions' definitions): at most 8 integer and 8 floating-point parameters, no
"...", and only parameter types known to travel in one register. NVN functions with a prototype are checked by gfx/tools/gen_protos.py.
Usage: hle_args.py [source ...] (default: the host, graphics and game sources of this repository); exits 1 on a finding."""
import glob, os, re, sys

MACROS = {'HLE': 3, 'HLE_FORCE': 4, 'HLE_FORCE_OPT': 4, 'NVN_NOPROTO': 2}   # index of the first parameter among the macro's arguments
FP = re.compile(r'^(const\s+)?(float|double)$')
SCALAR = re.compile(r'^(const\s+)?(unsigned|signed|int|long|unsigned int|unsigned long|long long|unsigned long long|size_t|ssize_t|ptrdiff_t|'
                    r'u?int(8|16|32|64)_t|uintptr_t|intptr_t|Result|NVNboolean|NVN[A-Za-z]+|\w+_fn)$')


def split_args(src, i):
    """Arguments of the call whose '(' is just before src[i], split at top-level commas; returns (args, index after ')')."""
    depth, args, cur, s = 1, [], '', None
    while depth:
        c = src[i]
        if s:
            cur += c
            if c == '\\': cur += src[i + 1]; i += 1
            elif c == s: s = None
        elif c in '"\'': s = c; cur += c
        elif c in '([{': depth += 1; cur += c
        elif c in ')]}':
            depth -= 1
            if depth: cur += c
        elif c == ',' and depth == 1: args.append(cur.strip()); cur = ''
        else: cur += c
        i += 1
    args.append(cur.strip())
    return args, i


def classify(params):
    """(integer count, floating-point count, problems) of a parameter list"""
    gp = fp = 0; bad = []
    for p in params:
        p = ' '.join(p.split())
        if p in ('', 'void'): continue
        if p == '...': bad.append('variadic ("..."): Apple passes the variable arguments on the stack'); continue
        if '*' in p or '[' in p or '(' in p: gp += 1; continue
        t = re.sub(r'\s+\w+$', '', p) if len(p.split()) > 1 else p
        if FP.match(t): fp += 1
        elif SCALAR.match(t): gp += 1
        else: gp += 1; bad.append(f'parameter type "{t}" not known to travel in one register')
    if gp > 8: bad.append(f'{gp} integer parameters: the 9th is on the stack')
    if fp > 8: bad.append(f'{fp} floating-point parameters: the 9th is on the stack')
    return gp, fp, bad


def strip_comments(src):
    """C comments blanked out, newlines and string literals kept"""
    out, i, s = [], 0, None
    while i < len(src):
        c = src[i]
        if s:
            out.append(c)
            if c == '\\' and i + 1 < len(src): out.append(src[i + 1]); i += 1
            elif c == s: s = None
        elif c in '"\'': s = c; out.append(c)
        elif src.startswith('//', i):
            j = src.find('\n', i); j = len(src) if j < 0 else j
            out.append(' ' * (j - i)); i = j; continue
        elif src.startswith('/*', i):
            j = src.find('*/', i + 2); j = len(src) if j < 0 else j + 2
            out.append(''.join(ch if ch == '\n' else ' ' for ch in src[i:j])); i = j; continue
        else: out.append(c)
        i += 1
    return ''.join(out)


def check_source(path, src):
    src = strip_comments(src)
    found, n = [], 0
    for m in re.finditer(r'\b(' + '|'.join(MACROS) + r')\(', src):
        line_start = src.rfind('\n', 0, m.start()) + 1
        if src[line_start:m.start()].lstrip().startswith('#define'): continue
        args, _ = split_args(src, m.end())
        params = args[MACROS[m.group(1)]:]
        name = args[MACROS[m.group(1)] - 1] if m.group(1) != 'NVN_NOPROTO' else args[0]
        n += 1
        for b in classify(params)[2]: found.append(f'{path}:{src.count(chr(10), 0, m.start()) + 1}: {name}: {b}')
    for m in re.finditer(r'static\s+void\s*\*\s*const\s+(\w+_vt)\s*\[\s*\d*\s*\]\s*=\s*\{([^}]*)\}', src):
        for fn in [f.strip() for f in m.group(2).split(',') if f.strip()]:
            d = re.search(r'^static\s+[\w\s\*]+?\b' + re.escape(fn) + r'\s*\(', src, re.M)
            if not d:
                found.append(f'{path}: {m.group(1)}: no definition of {fn} in this file'); continue
            params, _ = split_args(src, d.end())
            n += 1
            for b in classify(params)[2]: found.append(f'{path}:{src.count(chr(10), 0, d.start()) + 1}: {fn} ({m.group(1)}): {b}')
    return n, found


def main(argv):
    root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    paths = argv[1:] or sorted(set(glob.glob(f'{root}/host/*.[cm]') + glob.glob(f'{root}/gfx/*.[cm]') + glob.glob(f'{root}/gfx/nvn/*.[cm]') +
                                   glob.glob(f'{root}/games/*/*.c')))
    total, problems = 0, []
    for p in paths:
        n, f = check_source(os.path.relpath(p, root) if p.startswith(root) else p, open(p, encoding='utf-8').read())
        total += n; problems += f
    for f in problems: print(f)
    print(f'hle_args: {total} host functions the guest calls, {len(problems)} problem{"" if len(problems) == 1 else "s"}')
    return 1 if problems else 0


if __name__ == '__main__':
    sys.exit(main(sys.argv))
