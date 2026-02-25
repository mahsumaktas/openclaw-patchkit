#!/usr/bin/env bash
# PR #21896 - fix(cron): disable messaging tool when delivery.mode is none
set -euo pipefail
cd "$1"

FILE="src/cron/isolated-agent/run.ts"

if grep -q 'disableMessageTool: deliveryRequested || deliveryPlan\.mode === "none"' "$FILE" 2>/dev/null; then
  echo "SKIP: PR #21896 already applied in $FILE"
  exit 0
fi

if ! grep -q 'disableMessageTool: deliveryRequested,' "$FILE" 2>/dev/null; then
  echo "FAIL: Cannot find original 'disableMessageTool: deliveryRequested,' in $FILE"
  exit 1
fi

sed -i.bak 's/disableMessageTool: deliveryRequested,/disableMessageTool: deliveryRequested || deliveryPlan.mode === "none",/' "$FILE"
rm -f "$FILE.bak"

echo "OK: PR #21896 applied \u2014 disableMessageTool now also true when deliveryPlan.mode is \"none\""
