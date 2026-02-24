#!/usr/bin/env bash
# PR #22901: Guard NaN reserveTokens in compaction safeguard
# Adds || 0 fallback to prevent NaN from Math.floor(undefined)
set -euo pipefail

FILE="src/agents/pi-extensions/compaction-safeguard.ts"
[ -f "$FILE" ] || { echo "SKIP: $FILE not found"; exit 1; }

# Replace both occurrences
sed -i '' \
  's/Math\.floor(preparation\.settings\.reserveTokens))/Math.floor(preparation.settings.reserveTokens || 0))/g' \
  "$FILE"

COUNT=$(grep -c 'reserveTokens || 0' "$FILE" 2>/dev/null || echo 0)
if [ "$COUNT" -ge 2 ]; then
  echo "OK: #22901 applied ($COUNT replacements)"
else
  echo "WARN: #22901 expected 2 replacements, got $COUNT"
fi
