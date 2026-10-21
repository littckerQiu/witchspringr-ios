#!/usr/bin/env python3
# project.yml for a free (personal team) developer account: drop the six entitlements such a team cannot sign (increased memory limit, extended
# virtual addressing, sustained execution, the three iCloud keys). Every one must be found, or the spec changed and this script must follow.
# Usage: project_free.py <in yml> <out yml>
import re, sys
src, dst = sys.argv[1:3]
ENT = re.compile(r'^ *com\.apple\.developer\.(kernel\.increased-memory-limit|kernel\.extended-virtual-addressing|sustained-execution|'
                 r'icloud-container-identifiers|icloud-services|ubiquity-container-identifiers):')
L = open(src, encoding='utf-8').read().split('\n')
out = [l for l in L if not ENT.match(l)]
if len(L) - len(out) != 6: sys.exit(f'project_free.py: removed {len(L) - len(out)} entitlement lines, expected 6 (did project.yml change?)')
open(dst, 'w', encoding='utf-8').write('\n'.join(out))
