#!/usr/bin/env bash
set -euo pipefail
# PR #10197 — fix: add missing allowAgents to agent defaults subagents schema
# Adds allowAgents?: string[] to AgentDefaultsConfig type and Zod schema
SRC="${1:-.}/src"

TYPES_FILE="$SRC/config/types.agent-defaults.ts"
SCHEMA_FILE="$SRC/config/zod-schema.agent-defaults.ts"

if grep -q 'allowAgents' "$TYPES_FILE" 2>/dev/null; then
  echo "    SKIP: #10197 already applied"
  exit 0
fi

# 1) Add allowAgents property to AgentDefaultsConfig type
python3 - "$TYPES_FILE" << 'PYEOF'
import sys
path = sys.argv[1]
with open(path, 'r') as f:
    lines = f.readlines()

out = []
for line in lines:
    out.append(line)
    if 'archiveAfterMinutes?' in line and 'number' in line:
        indent = '    '
        out.append(f'{indent}/** Allow spawning sub-agents under other agent ids. Use "*" to allow any. */\n')
        out.append(f'{indent}allowAgents?: string[];\n')

with open(path, 'w') as f:
    f.writelines(out)
PYEOF

# 2) Add allowAgents to Zod schema
python3 - "$SCHEMA_FILE" << 'PYEOF'
import sys
path = sys.argv[1]
with open(path, 'r') as f:
    lines = f.readlines()

out = []
for line in lines:
    out.append(line)
    if 'archiveAfterMinutes:' in line and '.number()' in line and '.optional()' in line:
        # Find the indentation from the current line
        indent = line[:len(line) - len(line.lstrip())]
        out.append(f'{indent}allowAgents: z.array(z.string()).optional(),\n')

with open(path, 'w') as f:
    f.writelines(out)
PYEOF

echo "    OK: #10197 fully applied"
