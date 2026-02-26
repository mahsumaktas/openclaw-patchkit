#!/usr/bin/env bash
# PR #19177: fix: use parseAgentSessionKey instead of fragile split
# Replaces sessionKey?.split(":")[0] with parseAgentSessionKey(sessionKey)?.agentId
# in compact.ts and commands-core.ts
set -euo pipefail
cd "$1"

CHANGED=0

# 1. compact.ts: add import + replace split
FILE="src/agents/pi-embedded-runner/compact.ts"
if [ -f "$FILE" ]; then
  if ! grep -q 'parseAgentSessionKey' "$FILE"; then
    python3 << 'PYEOF'
import sys

filepath = "src/agents/pi-embedded-runner/compact.ts"
with open(filepath, "r") as f:
    code = f.read()

changed = False

# Add import after the existing session-key import
marker = 'import { isCronSessionKey, isSubagentSessionKey } from "../../routing/session-key.js";'
if marker in code:
    code = code.replace(
        marker,
        marker + '\nimport { parseAgentSessionKey } from "../../sessions/session-key-utils.js";',
        1
    )
    changed = True
else:
    print("FAIL: #19177 cannot find session-key import in compact.ts", file=sys.stderr)
    sys.exit(1)

# Replace fragile split
old = 'agentId: params.sessionKey?.split(":")[0] ?? "main"'
new = 'agentId: parseAgentSessionKey(params.sessionKey)?.agentId ?? "main"'
if old in code:
    code = code.replace(old, new)
    changed = True
else:
    print("FAIL: #19177 split pattern not found in compact.ts", file=sys.stderr)
    sys.exit(1)

if changed:
    with open(filepath, "w") as f:
        f.write(code)
    print("OK: #19177 compact.ts patched")

PYEOF
    CHANGED=$((CHANGED + 1))
  else
    echo "SKIP: compact.ts already patched"
  fi
fi

# 2. commands-core.ts: add import + replace split
FILE="src/auto-reply/reply/commands-core.ts"
if [ -f "$FILE" ]; then
  if ! grep -q 'parseAgentSessionKey' "$FILE"; then
    python3 << 'PYEOF'
import sys

filepath = "src/auto-reply/reply/commands-core.ts"
with open(filepath, "r") as f:
    code = f.read()

changed = False

# Add import after resolveSendPolicy import
marker = 'import { resolveSendPolicy } from "../../sessions/send-policy.js";'
if marker in code:
    code = code.replace(
        marker,
        marker + '\nimport { parseAgentSessionKey } from "../../sessions/session-key-utils.js";',
        1
    )
    changed = True
else:
    print("FAIL: #19177 cannot find resolveSendPolicy import in commands-core.ts", file=sys.stderr)
    sys.exit(1)

# Replace fragile split
old = 'agentId: params.sessionKey?.split(":")[0] ?? "main"'
new = 'agentId: parseAgentSessionKey(params.sessionKey)?.agentId ?? "main"'
if old in code:
    code = code.replace(old, new)
    changed = True
else:
    print("FAIL: #19177 split pattern not found in commands-core.ts", file=sys.stderr)
    sys.exit(1)

if changed:
    with open(filepath, "w") as f:
        f.write(code)
    print("OK: #19177 commands-core.ts patched")

PYEOF
    CHANGED=$((CHANGED + 1))
  else
    echo "SKIP: commands-core.ts already patched"
  fi
fi

echo "Done: $CHANGED files patched for #19177"
