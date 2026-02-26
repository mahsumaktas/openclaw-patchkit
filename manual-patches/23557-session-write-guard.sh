#!/usr/bin/env bash
# PR #23557: fix: catch session JSONL write failures instead of crashing
# Wraps originalAppend calls in safeAppend try/catch in session-tool-result-guard.ts
set -euo pipefail
cd "$1"

FILE="src/agents/session-tool-result-guard.ts"
[ -f "$FILE" ] || { echo "FAIL: $FILE not found"; exit 1; }

if grep -q 'safeAppend' "$FILE"; then
  echo "SKIP: #23557 safeAppend already present"
  exit 0
fi

python3 << 'PYEOF'
import sys

filepath = "src/agents/session-tool-result-guard.ts"
with open(filepath, "r") as f:
    code = f.read()

# 1. Add safeAppend function after "return msg;" line that closes persistMessage
safe_append_code = '''
  const safeAppend = (
    message: Parameters<typeof originalAppend>[0],
  ): ReturnType<typeof originalAppend> | undefined => {
    try {
      return originalAppend(message);
    } catch (err) {
      const file =
        (sessionManager as { getSessionFile?: () => string | null }).getSessionFile?.() ??
        "unknown";
      const reason = err instanceof Error ? err.message : String(err);
      console.error(
        `[session-guard] session write failed (${reason}); message dropped (file: ${file})`,
      );
      return undefined;
    }
  };
'''

# Find insertion point: after the flushPendingToolResults function definition
# We insert before "const flushPendingToolResults"
marker = "  const flushPendingToolResults = () => {"
if marker not in code:
    print("FAIL: #23557 cannot find flushPendingToolResults marker", file=sys.stderr)
    sys.exit(1)

code = code.replace(marker, safe_append_code + "\n" + marker, 1)

# 2. Replace all 3 originalAppend calls with safeAppend (but NOT the definition/bind line)
# Pattern: "originalAppend(flushed as never)" -> "safeAppend(flushed as never)"
# Pattern: "originalAppend(persisted as never)" -> "safeAppend(persisted as never)"
# Pattern: "originalAppend(finalMessage as never)" -> "safeAppend(finalMessage as never)"
count = 0
for old, new in [
    ("originalAppend(flushed as never)", "safeAppend(flushed as never)"),
    ("originalAppend(persisted as never)", "safeAppend(persisted as never)"),
    ("originalAppend(finalMessage as never)", "safeAppend(finalMessage as never)"),
]:
    if old in code:
        code = code.replace(old, new)
        count += 1

if count != 3:
    print(f"WARN: #23557 expected 3 replacements, got {count}", file=sys.stderr)

with open(filepath, "w") as f:
    f.write(code)

print(f"OK: #23557 session-tool-result-guard.ts patched ({count} calls wrapped)")

PYEOF
