#!/usr/bin/env bash
# PR #17375 — fix(session): don't carry stale model info into reset welcome
# On session reset, the old model/modelProvider values were copied into the
# new session entry. If the user changed their default model between sessions,
# the stale model reference would be shown in the welcome message.
# Fix: omit model and modelProvider from the reset entry so the gateway
# resolves fresh defaults on next connect.
set -euo pipefail

SRC="${1:?Usage: $0 <openclaw-source-dir>}/src"

FILE="$SRC/gateway/server-methods/sessions.ts"
if [ ! -f "$FILE" ]; then
  echo "    FAIL: #17375 target file not found: $FILE"
  exit 1
fi

# Idempotency check — if model/modelProvider lines are already removed,
# we look for the absence of both lines in the reset nextEntry block.
if grep -q '// #17375: omit stale model' "$FILE"; then
  echo "    SKIP: #17375 already applied"
  exit 0
fi

python3 - "$FILE" << 'PYEOF'
import sys

path = sys.argv[1]
with open(path, 'r') as f:
    content = f.read()

old = """\
        thinkingLevel: entry?.thinkingLevel,
        verboseLevel: entry?.verboseLevel,
        reasoningLevel: entry?.reasoningLevel,
        responseUsage: entry?.responseUsage,
        model: entry?.model,
        modelProvider: entry?.modelProvider,
        contextTokens: entry?.contextTokens,"""

new = """\
        thinkingLevel: entry?.thinkingLevel,
        verboseLevel: entry?.verboseLevel,
        reasoningLevel: entry?.reasoningLevel,
        responseUsage: entry?.responseUsage,
        // #17375: omit stale model/modelProvider so gateway resolves fresh defaults
        contextTokens: entry?.contextTokens,"""

if old not in content:
    print("    FAIL: #17375 pattern not found in sessions.ts")
    sys.exit(1)

content = content.replace(old, new, 1)

with open(path, 'w') as f:
    f.write(content)

print("    OK: #17375 removed stale model/modelProvider from reset entry")
PYEOF
