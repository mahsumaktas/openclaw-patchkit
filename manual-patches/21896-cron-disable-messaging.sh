#!/usr/bin/env bash
# PR #21896 - fix(cron): disable messaging tool when delivery.mode is none
# When delivery.mode is "none", the agent messaging tool should be disabled
# even if deliveryRequested is false. This prevents cron output from being
# accidentally sent to Telegram or other channels.
set -euo pipefail
cd "$1"

FILE="src/cron/isolated-agent/run.ts"

# Idempotent check: skip if already patched
if grep -q 'disableMessageTool: deliveryRequested || deliveryPlan\.mode === "none"' "$FILE" 2>/dev/null; then
  echo "SKIP: PR #21896 already applied in $FILE"
  exit 0
fi

# Verify the original line exists before patching
if ! grep -q 'disableMessageTool: deliveryRequested,' "$FILE" 2>/dev/null; then
  echo "FAIL: Cannot find original 'disableMessageTool: deliveryRequested,' in $FILE"
  exit 1
fi

# Apply the change: add deliveryPlan.mode === "none" condition
sed -i.bak 's/disableMessageTool: deliveryRequested,/disableMessageTool: deliveryRequested || deliveryPlan.mode === "none",/' "$FILE"
rm -f "$FILE.bak"

echo "OK: PR #21896 applied — disableMessageTool now also true when deliveryPlan.mode is \"none\""
