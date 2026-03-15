#!/usr/bin/env bash
# PR #24764 — fix(failover): classify subscription/plan unavailability as billing
# Some providers return errors like "not available for this subscription" or
# "feature is not available for your plan" which are effectively billing/tier
# gating issues but weren't classified as such. Without this, failover doesn't
# trigger and the user sees a raw API error.
#
# v2026.3.13 fix: the billing patterns are in failover-matches.ts (not errors.ts).
# The old script matched an exact billing array that no longer exists in v2026.3.13.
# v2026.3.13 has an updated billing array with "insufficient usd or diem balance"
# and /requires?\s+more\s+credits/i entries that weren't in v2026.3.8.
# New approach: append the two regex patterns after the last entry in the billing array.
set -euo pipefail

SRC="${1:-.}/src"

FILE="$SRC/agents/pi-embedded-helpers/failover-matches.ts"
if [ ! -f "$FILE" ]; then
  echo "    FAIL: #24764 target file not found: $FILE"
  exit 1
fi

# Idempotency check
if grep -q 'not.*available.*subscription\|#24764' "$FILE"; then
  echo "    SKIP: #24764 already applied"
  exit 0
fi

python3 - "$FILE" << 'PYEOF'
import sys

path = sys.argv[1]
with open(path, 'r') as f:
    content = f.read()

# v2026.3.13 billing array ends with:
#     /requires?\s+more\s+credits/i,
#   ],
# We insert two new regex patterns before the closing ],
# The last entry in the billing array is /requires?\s+more\s+credits/i,

old_tail = r'''    /requires?\s+more\s+credits/i,
  ],'''

new_tail = r'''    /requires?\s+more\s+credits/i,
    // #24764: subscription/plan/tier feature-gating -> billing failover
    /not (?:yet )?available (?:for|on) (?:this|your) (?:subscription|plan|tier)/i,
    /(?:feature|model|beta) (?:is )?not (?:yet )?(?:available|enabled|supported) (?:for|on)/i,
  ],'''

if old_tail not in content:
    # Fallback: try to find the billing array closing bracket by another path.
    # Look for the last line before ],  inside the billing block
    import re
    # Find the billing: [ ... ], block
    m = re.search(r'(  billing: \[.*?)(  \],)', content, re.DOTALL)
    if not m:
        print("    FAIL: #24764 cannot locate billing array in failover-matches.ts")
        sys.exit(1)
    billing_block = m.group(1)
    billing_close = m.group(2)
    # Insert before the closing ],
    new_entries = (
        '    // #24764: subscription/plan/tier feature-gating -> billing failover\n'
        '    /not (?:yet )?available (?:for|on) (?:this|your) (?:subscription|plan|tier)/i,\n'
        '    /(?:feature|model|beta) (?:is )?not (?:yet )?(?:available|enabled|supported) (?:for|on)/i,\n'
    )
    content = content.replace(
        billing_block + billing_close,
        billing_block + new_entries + billing_close,
        1
    )
else:
    content = content.replace(old_tail, new_tail, 1)

with open(path, 'w') as f:
    f.write(content)

print("    OK: #24764 added subscription/plan unavailability patterns to billing failover")
PYEOF
