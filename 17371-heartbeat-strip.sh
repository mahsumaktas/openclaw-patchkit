#!/usr/bin/env bash
# PR #17371 - fix(heartbeat): always strip HEARTBEAT_OK token from reply
# Previously, HEARTBEAT_OK stripping was gated behind !params.isHeartbeat,
# meaning heartbeat replies could leak the token to users.
# This patch always strips the token but only logs when not a heartbeat.
set -euo pipefail
cd "$1"

FILE="src/auto-reply/reply/agent-runner-execution.ts"

# Replace: remove the !params.isHeartbeat guard from the includes check
sed -i.bak 's/if (!params\.isHeartbeat && text?\.includes("HEARTBEAT_OK"))/if (text?.includes("HEARTBEAT_OK"))/' "$FILE"

# Replace: wrap log message in isHeartbeat guard instead
sed -i.bak '/if (stripped\.didStrip && !didLogHeartbeatStrip) {/{
n
s/didLogHeartbeatStrip = true;/didLogHeartbeatStrip = true;/
n
s|logVerbose("Stripped stray HEARTBEAT_OK token from reply");|if (!params.isHeartbeat) {\n              logVerbose("Stripped stray HEARTBEAT_OK token from reply");\n            }|
}' "$FILE"

rm -f "${FILE}.bak"
echo "Applied PR #17371 - heartbeat strip"
