#!/usr/bin/env bash
set -euo pipefail
cd "$1"

PATCH_ID="PR-25093"
MARKER="inputProvenance"

# --- File 1: src/gateway/openai-http.ts ---
# Add senderIsOwner: false + inputProvenance to buildAgentCommandInput
FILE1="src/gateway/openai-http.ts"

if [[ ! -f "$FILE1" ]]; then
  echo "$PATCH_ID: ERROR - $FILE1 not found"
  exit 1
fi

if grep -q "$MARKER" "$FILE1"; then
  echo "$PATCH_ID: $FILE1 already patched (idempotent skip)"
else
  python3 - "$FILE1" << 'PYEOF'
import sys

filepath = sys.argv[1]
with open(filepath, 'r') as f:
    content = f.read()

# Replace senderIsOwner: true with senderIsOwner: false + inputProvenance
old_block = '''    bestEffortDeliver: false as const,
    // HTTP API callers are authenticated operator clients for this gateway context.
    senderIsOwner: true as const,'''

new_block = '''    bestEffortDeliver: false as const,
    senderIsOwner: false as const,
    inputProvenance: {
      kind: "external_user" as const,
      sourceChannel: "openai_http",
      sourceTool: "gateway.openai_http.chat_completions",
    },'''

if old_block not in content:
    print(f"ERROR: Could not find senderIsOwner block in {filepath}", file=sys.stderr)
    sys.exit(1)

content = content.replace(old_block, new_block, 1)

with open(filepath, 'w') as f:
    f.write(content)

print(f"Patched {filepath}")
PYEOF
  echo "$PATCH_ID: Patched $FILE1"
fi

# --- File 2: src/gateway/openresponses-http.ts ---
# Add senderIsOwner: false + inputProvenance to runResponsesAgentCommand
FILE2="src/gateway/openresponses-http.ts"

if [[ ! -f "$FILE2" ]]; then
  echo "$PATCH_ID: ERROR - $FILE2 not found"
  exit 1
fi

if grep -q "$MARKER" "$FILE2"; then
  echo "$PATCH_ID: $FILE2 already patched (idempotent skip)"
else
  python3 - "$FILE2" << 'PYEOF'
import sys

filepath = sys.argv[1]
with open(filepath, 'r') as f:
    content = f.read()

# Replace senderIsOwner: true with senderIsOwner: false + inputProvenance
old_block = '''      bestEffortDeliver: false,
      // HTTP API callers are authenticated operator clients for this gateway context.
      senderIsOwner: true,'''

new_block = '''      bestEffortDeliver: false,
      senderIsOwner: false,
      inputProvenance: {
        kind: "external_user",
        sourceChannel: "openresponses_http",
        sourceTool: "gateway.openresponses_http.responses",
      },'''

if old_block not in content:
    print(f"ERROR: Could not find senderIsOwner block in {filepath}", file=sys.stderr)
    sys.exit(1)

content = content.replace(old_block, new_block, 1)

with open(filepath, 'w') as f:
    f.write(content)

print(f"Patched {filepath}")
PYEOF
  echo "$PATCH_ID: Patched $FILE2"
fi

echo "$PATCH_ID: Done (agent.ts + types.ts already have senderIsOwner in v2026.3.2)"
