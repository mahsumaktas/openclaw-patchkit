#!/usr/bin/env bash
# PR #23525: fix: include sessionKey in session_start/session_end hook context
set -euo pipefail
cd "$1"

TYPES_FILE="src/plugins/types.ts"
[ -f "$TYPES_FILE" ] || { echo "FAIL: $TYPES_FILE not found"; exit 1; }

python3 << 'PYEOF'
import sys
import re

filepath = "src/plugins/types.ts"
with open(filepath, "r") as f:
    code = f.read()

if "sessionKey" in code and "PluginHookSessionContext" in code:
    m = re.search(r'export type PluginHookSessionContext\s*=\s*\{([^}]+)\}', code)
    if m and 'sessionKey' in m.group(1):
        print("SKIP: #23525 sessionKey already in PluginHookSessionContext")
        sys.exit(0)

marker = "export type PluginHookSessionContext"
if marker not in code:
    print("FAIL: #23525 cannot find PluginHookSessionContext type", file=sys.stderr)
    sys.exit(1)

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

SESSION_FILE="src/auto-reply/reply/session.ts"
[ -f "$SESSION_FILE" ] || { echo "FAIL: $SESSION_FILE not found"; exit 1; }

python3 << 'PYEOF'
import sys
import re

filepath = "src/auto-reply/reply/session.ts"
with open(filepath, "r") as f:
    code = f.read()

pattern = r'(agentId: resolveSessionAgentId\(\{ sessionKey, config: cfg \}\),)\n(\s*\},)'

matches = list(re.finditer(pattern, code))
if not matches:
    if re.search(r'agentId: resolveSessionAgentId.*\n\s*sessionKey,', code):
        print("SKIP: #23525 sessionKey already in hook calls")
        sys.exit(0)
    print("FAIL: #23525 cannot find agentId pattern in hook calls", file=sys.stderr)
    sys.exit(1)

patched_count = 0
for match in reversed(matches):
    after_agentid = code[match.end(1):match.end(1)+50]
    if 'sessionKey,' in after_agentid.split('},')[0]:
        continue

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
