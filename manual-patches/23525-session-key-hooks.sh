#!/usr/bin/env bash
# PR #23525: fix: include sessionKey in session_start/session_end hook context
# Adds sessionKey to PluginHookSessionContext type and passes it in both
# runSessionEnd and runSessionStart calls in session.ts.
#
# Changes (source only, skipping tests):
#   1. src/plugins/types.ts — add sessionKey?: string to PluginHookSessionContext
#   2. src/auto-reply/reply/session.ts — add sessionKey to runSessionEnd context
#   3. src/auto-reply/reply/session.ts — add sessionKey to runSessionStart context
set -euo pipefail
cd "$1"

# ============================================================
# Change 1: Add sessionKey to PluginHookSessionContext type
# ============================================================
TYPES_FILE="src/plugins/types.ts"
[ -f "$TYPES_FILE" ] || { echo "FAIL: $TYPES_FILE not found"; exit 1; }

python3 << 'PYEOF'
import sys

filepath = "src/plugins/types.ts"
with open(filepath, "r") as f:
    code = f.read()

if "sessionKey" in code and "PluginHookSessionContext" in code:
    # Check if sessionKey is already in the PluginHookSessionContext type
    import re
    # Find the type block
    m = re.search(r'export type PluginHookSessionContext\s*=\s*\{([^}]+)\}', code)
    if m and 'sessionKey' in m.group(1):
        print("SKIP: #23525 sessionKey already in PluginHookSessionContext")
        sys.exit(0)

# Find the sessionId line inside PluginHookSessionContext and add sessionKey after it
marker = "export type PluginHookSessionContext"
if marker not in code:
    print("FAIL: #23525 cannot find PluginHookSessionContext type", file=sys.stderr)
    sys.exit(1)

# The type has: agentId?: string; sessionId: string; — add sessionKey after sessionId
old_pattern = "  sessionId: string;\n};"
# We need to find this pattern within the PluginHookSessionContext block
# Use a more targeted approach
import re
pattern = r'(export type PluginHookSessionContext\s*=\s*\{[^}]*sessionId:\s*string;)\s*(\n\};)'
match = re.search(pattern, code)
if not match:
    print("FAIL: #23525 cannot match PluginHookSessionContext structure", file=sys.stderr)
    sys.exit(1)

code = code[:match.start()] + match.group(1) + "\n  sessionKey?: string;" + match.group(2) + code[match.end():]

with open(filepath, "w") as f:
    f.write(code)
print("OK: #23525 added sessionKey to PluginHookSessionContext")

PYEOF

# ============================================================
# Change 2 & 3: Add sessionKey to hook calls in session.ts
# ============================================================
SESSION_FILE="src/auto-reply/reply/session.ts"
[ -f "$SESSION_FILE" ] || { echo "FAIL: $SESSION_FILE not found"; exit 1; }

python3 << 'PYEOF'
import sys
import re

filepath = "src/auto-reply/reply/session.ts"
with open(filepath, "r") as f:
    code = f.read()

changed = False

# We need to add `sessionKey,` after each `agentId: resolveSessionAgentId(...)` line
# that appears inside .runSessionEnd() and .runSessionStart() calls.
#
# The pattern is:
#   agentId: resolveSessionAgentId({ sessionKey, config: cfg }),
# followed by closing brace + comma/paren — we add sessionKey before the closing.
#
# Strategy: find all occurrences of the agentId line within hook context objects
# and add sessionKey after them if not already present.

# Pattern: matches the agentId line within hook call context objects
# We look for: agentId: resolveSessionAgentId({ sessionKey, config: cfg }),\n            },
# and replace with: agentId: resolveSessionAgentId({ sessionKey, config: cfg }),\n              sessionKey,\n            },

pattern = r'(agentId: resolveSessionAgentId\(\{ sessionKey, config: cfg \}\),)\n(\s*\},)'

matches = list(re.finditer(pattern, code))
if not matches:
    # Check if already applied
    if re.search(r'agentId: resolveSessionAgentId.*\n\s*sessionKey,', code):
        print("SKIP: #23525 sessionKey already in hook calls")
        sys.exit(0)
    print("FAIL: #23525 cannot find agentId pattern in hook calls", file=sys.stderr)
    sys.exit(1)

# Count how many need patching (those without sessionKey right after)
patched_count = 0
# Process from end to start to preserve positions
for match in reversed(matches):
    after_agentid = code[match.end(1):match.end(1)+50]
    if 'sessionKey,' in after_agentid.split('},')[0]:
        continue  # Already has sessionKey

    # Get the indentation of the agentId line
    agentid_line_start = code.rfind('\n', 0, match.start(1)) + 1
    agentid_indent = ''
    for ch in code[agentid_line_start:]:
        if ch in ' \t':
            agentid_indent += ch
        else:
            break

    replacement = match.group(1) + "\n" + agentid_indent + "sessionKey," + "\n" + match.group(2)
    code = code[:match.start()] + replacement + code[match.end():]
    patched_count += 1

if patched_count > 0:
    with open(filepath, "w") as f:
        f.write(code)
    print(f"OK: #23525 added sessionKey to {patched_count} hook call(s) in session.ts")
else:
    print("SKIP: #23525 sessionKey already in all hook calls")

PYEOF
