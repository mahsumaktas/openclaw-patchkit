#!/usr/bin/env bash
# PR #11986 — fix: drop empty assistant content blocks from error/aborted API responses
# Prevents session death spiral: API error leaves content:[] → permanent 400 loop
# NOTE: #14328 (Wave 3) modifies the same stopReason block before us — handle both patterns
set -euo pipefail
cd "$1"

FILE="src/agents/session-transcript-repair.ts"
if ! [ -f "$FILE" ]; then echo "SKIP: $FILE not found"; exit 0; fi
if grep -q 'assistant.content.length === 0' "$FILE"; then echo "SKIP: #11986 already applied"; exit 0; fi

python3 - "$FILE" << 'PYEOF'
import sys

with open(sys.argv[1], "r") as f:
    content = f.read()

applied = False

# Case A: Post-#14328 pattern (tool_use filtering already present)
# #14328 replaces the simple out.push(msg) with Array.isArray content filtering
old_a = '    if (stopReason === "error" || stopReason === "aborted") {\n      if (Array.isArray(assistant.content)) {'
new_a = '''    if (stopReason === "error" || stopReason === "aborted") {
      // Drop assistant messages with empty content arrays (death spiral prevention).
      // See: https://github.com/openclaw/openclaw/issues/11963
      if (Array.isArray(assistant.content) && assistant.content.length === 0) {
        changed = true;
        continue;
      }
      if (Array.isArray(assistant.content)) {'''

if old_a in content:
    content = content.replace(old_a, new_a, 1)
    applied = True
    print("OK: #11986 applied (post-#14328 pattern)")

# Case B: Original v2026.2.26 pattern (simple out.push)
if not applied:
    old_b = '''    if (stopReason === "error" || stopReason === "aborted") {
      out.push(msg);
      continue;
    }'''
    new_b = '''    if (stopReason === "error" || stopReason === "aborted") {
      if (Array.isArray(assistant.content) && assistant.content.length === 0) {
        changed = true;
        continue;
      }
      out.push(msg);
      continue;
    }'''
    if old_b in content:
        content = content.replace(old_b, new_b, 1)
        applied = True
        print("OK: #11986 applied (original pattern)")

if not applied:
    print("ERROR: cannot find stopReason error/aborted block (neither post-#14328 nor original)")
    sys.exit(1)

with open(sys.argv[1], "w") as f:
    f.write(content)
PYEOF
