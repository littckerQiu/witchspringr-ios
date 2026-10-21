#!/usr/bin/env python3
"""tools/sysreg.py: which system register accesses the rewrite lets through. Words assembled by hand from the Arm encodings (MRS 0xD5300000 |
o0:op1:CRn:CRm:op2 << 5 | Rt; MSR 0xD5100000 | ...): NZCV, FPCR, FPSR, DCZID_EL0 pass; CNTFRQ_EL0 and MIDR_EL1 are refused; DC CIVAC (SYS) and
MSR DAIFSet (immediate) are not system register accesses here. Run with the workspace Python (capstone)."""
import os, sys
sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), '..'))
import sysreg
from capstone import Cs, CS_ARCH_ARM64, CS_MODE_ARM
md = Cs(CS_ARCH_ARM64, CS_MODE_ARM)
def mrs(op0, op1, crn, crm, op2, rt=0): return 0xD5300000 | (op0 - 2) << 19 | op1 << 16 | crn << 12 | crm << 8 | op2 << 5 | rt
def msr(op0, op1, crn, crm, op2, rt=0): return 0xD5100000 | (op0 - 2) << 19 | op1 << 16 | crn << 12 | crm << 8 | op2 << 5 | rt
fails = total = 0
def check(name, ok):
    global fails, total
    total += 1; fails += not ok; print(f'{name:<70} {"✓" if ok else "✗"}')
check('mrs x0, nzcv passes', sysreg.refused(mrs(3, 3, 4, 2, 0), md) is None)
check('msr fpcr, x1 passes', sysreg.refused(msr(3, 3, 4, 4, 0, 1), md) is None)
check('mrs x2, fpsr passes', sysreg.refused(mrs(3, 3, 4, 4, 1, 2), md) is None)
check('mrs x3, dczid_el0 passes', sysreg.refused(mrs(3, 3, 0, 0, 7, 3), md) is None)
r = sysreg.refused(mrs(3, 3, 14, 0, 0, 4), md); check(f'mrs x4, cntfrq_el0 refused ({r})', r is not None and 'cntfrq_el0' in r)
r = sysreg.refused(mrs(3, 0, 0, 0, 0, 5), md); check(f'mrs x5, midr_el1 refused ({r})', r is not None and 'midr_el1' in r)
check('dc civac, x0 (SYS) is no system register access here', not sysreg.is_sysreg_access(0xD50B7E20) and sysreg.refused(0xD50B7E20, md) is None)
check('msr daifset, #2 (immediate) is no system register access here', not sysreg.is_sysreg_access(0xD50342DF))
check('an ordinary instruction (add x0, x1, x2) is none', sysreg.refused(0x8B020020, md) is None)
print(f'== {total} checks, {fails} failed =='); sys.exit(fails != 0)
