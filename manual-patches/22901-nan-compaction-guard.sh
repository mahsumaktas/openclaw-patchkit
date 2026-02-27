#!/usr/bin/env bash
# PR #22901 — fix: guard against NaN reserveTokens in compaction safeguard
# Adds || 0 fallback to prevent NaN propagation from undefined reserveTokens
set -euo pipefail
cd "$1"

FILE="src/agents/pi-extensions/compaction-safeguard.ts"
if ! [ -f "$FILE" ]; then echo "SKIP: $FILE not found"; exit 0; fi
if grep -q 'reserveTokens || 0' "$FILE"; then echo "SKIP: #22901 already applied"; exit 0; fi

python3 - "$FILE" << 'PYEOF'
import sys

with open(sys.argv[1], "r") as f:
    content = f.read()

old = "Math.floor(preparation.settings.reserveTokens))"
new = "Math.floor(preparation.settings.reserveTokens || 0))"

count = content.count(old)
if count == 0:
    print("ERROR: cannot find reserveTokens pattern")
    sys.exit(1)

content = content.replace(old, new)

with open(sys.argv[1], "w") as f:
    f.write(content)

print(f"OK: #22901 applied — NaN guard on {count} reserveTokens occurrence(s)")
PYEOF
