"""System register accesses the rewriter leaves as they are (tools/patch_nso.py). It rewrites TPIDR_EL0, TPIDRRO_EL0, CNTPCT_EL0, CNTVCT_EL0 and
CTR_EL0; any other MRS / MSR of a system register is allowed only when user mode may access it on the Switch and on Apple systems alike and reads
the same there: NZCV, FPCR, FPSR, DCZID_EL0. Anything else would SIGILL here or give another value (CNTFRQ_EL0: Apple's 24 MHz against the console's
19.2), so the rewrite stops on it (mush8's nxpatch refuses system registers outside a short list; GPL-3.0, idea only). Checked by
tools/tests/t_sysreg.py; Tears of the Kingdom's and manosaba's modules hold none of the others."""
ALLOWED = {'nzcv', 'fpcr', 'fpsr', 'dczid_el0'}

def is_sysreg_access(w):
    """MRS / MSR (register) of a system register: op0 = 2 or 3; not SYS (DC, IC, AT, TLBI) and not MSR (immediate) to PSTATE"""
    return w & 0xFFD00000 == 0xD5100000

def refused(w, md, addr=0):
    """None when the word is no system register access or one of ALLOWED; otherwise the instruction text (the caller stops the rewrite)"""
    if not is_sysreg_access(w): return None
    for ins in md.disasm(w.to_bytes(4, 'little'), addr):
        ops = [x.strip() for x in ins.op_str.split(',')]
        reg = ops[-1] if ins.mnemonic == 'mrs' else ops[0]
        return None if reg in ALLOWED else f'{ins.mnemonic} {ins.op_str}'
    return f'undecodable system register access {w:#010x}'
