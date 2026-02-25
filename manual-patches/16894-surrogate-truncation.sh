#!/usr/bin/env bash
# PR #16894: Fix text truncation splitting surrogate pairs (emoji/CJK)
# Replaces .slice(0, N) with truncateUtf16Safe(value, N) in 3 files
# Also fixes truncateLine in shared/subagents-format.ts (renamed from subagents-tool.ts in this version)
set -euo pipefail
cd "$1"

CHANGED=0

# 1. web-fetch-utils.ts: add import + replace slice
FILE="src/agents/tools/web-fetch-utils.ts"
if [ -f "$FILE" ]; then
  # Add import at top if not already present
  if ! grep -q 'truncateUtf16Safe' "$FILE"; then
    sed -i '' '1s/^/import { truncateUtf16Safe } from "\.\.\/\.\.\/utils.js";\n/' "$FILE"
    sed -i '' 's/return { text: value\.slice(0, maxChars), truncated: true };/return { text: truncateUtf16Safe(value, maxChars), truncated: true };/' "$FILE"
    echo "OK: web-fetch-utils.ts patched"
    CHANGED=$((CHANGED + 1))
  else
    echo "SKIP: web-fetch-utils.ts already patched"
  fi
fi

# 2. channel-metadata.ts: add import + replace slice
FILE="src/security/channel-metadata.ts"
if [ -f "$FILE" ]; then
  if ! grep -q 'truncateUtf16Safe' "$FILE"; then
    sed -i '' '1s/^/import { truncateUtf16Safe } from "\.\.\/utils.js";\n/' "$FILE"
    sed -i '' 's/const trimmed = value\.slice(0, Math\.max(0, maxChars - 3))\.trimEnd();/const trimmed = truncateUtf16Safe(value, Math.max(0, maxChars - 3)).trimEnd();/' "$FILE"
    echo "OK: channel-metadata.ts patched"
    CHANGED=$((CHANGED + 1))
  else
    echo "SKIP: channel-metadata.ts already patched"
  fi
fi

# 3. shared/subagents-format.ts: truncateLine uses .slice — fix it
# (In v2026.2.22, the function moved from subagents-tool.ts to shared/subagents-format.ts)
FILE="src/shared/subagents-format.ts"
if [ -f "$FILE" ]; then
  if ! grep -q 'truncateUtf16Safe' "$FILE"; then
    sed -i '' '1s/^/import { truncateUtf16Safe } from "\.\.\/utils.js";\n/' "$FILE"
    sed -i '' 's/return `${value\.slice(0, maxLength)\.trimEnd()}\.\.\./return `${truncateUtf16Safe(value, maxLength).trimEnd()}.../' "$FILE"
    echo "OK: subagents-format.ts patched"
    CHANGED=$((CHANGED + 1))
  else
    echo "SKIP: subagents-format.ts already patched"
  fi
fi

echo "Done: $CHANGED files patched for #16894"
