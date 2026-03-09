#!/usr/bin/env bash
# PR #32265 — fix(agents): prevent subagent timeout from leaking tool results to chat
# When a subagent times out, readLatestSubagentOutput() may return raw tool results
# (including source code, API keys, etc.) instead of just assistant messages.
# Also, findings text can be excessively long, flooding the chat channel.
#
# Changes:
# 1. Add MAX_FINDINGS_LENGTH constant (2000 chars)
# 2. Filter readLatestSubagentOutput to only extract from assistant messages
# 3. Truncate oversized findings text
set -euo pipefail
SRC="${1:-.}/src"

FILE="$SRC/agents/subagent-announce.ts"

# Idempotency check
if grep -q 'MAX_FINDINGS_LENGTH' "$FILE" 2>/dev/null; then
  echo "    SKIP: #32265 already applied"
  exit 0
fi

[ -f "$FILE" ] || { echo "    FAIL: $FILE not found"; exit 1; }

python3 - "$FILE" << 'PYEOF'
import sys

path = sys.argv[1]
with open(path, 'r') as f:
    content = f.read()

# 1) Add MAX_FINDINGS_LENGTH constant after MAX_TIMER_SAFE_TIMEOUT_MS
old_const = 'const MAX_TIMER_SAFE_TIMEOUT_MS = 2_147_000_000;\nlet subagentRegistryRuntimePromise'
new_const = '''const MAX_TIMER_SAFE_TIMEOUT_MS = 2_147_000_000;

/** Hard cap on findings text forwarded in completion messages. */
const MAX_FINDINGS_LENGTH = 2000;

let subagentRegistryRuntimePromise'''

if old_const not in content:
    print("    FAIL: #32265 MAX_TIMER constant not found", file=sys.stderr)
    sys.exit(1)
content = content.replace(old_const, new_const, 1)

# 2) Filter readLatestSubagentOutput to only assistant messages
old_loop = '''  const messages = Array.isArray(history?.messages) ? history.messages : [];
  for (let i = messages.length - 1; i >= 0; i -= 1) {
    const msg = messages[i];
    const text = extractSubagentOutputText(msg);'''

new_loop = '''  // Security: only extract assistant-role messages in the fallback path.
  // toolResult/tool content may contain raw source code, API keys, or other
  // sensitive data that must not be forwarded to the chat channel.
  const messages = Array.isArray(history?.messages) ? history.messages : [];
  for (let i = messages.length - 1; i >= 0; i -= 1) {
    const msg = messages[i];
    if (!msg || typeof msg !== "object") {
      continue;
    }
    const role = (msg as { role?: unknown }).role;
    if (role !== "assistant") {
      continue;
    }
    const text = extractSubagentOutputText(msg);'''

if old_loop not in content:
    print("    FAIL: #32265 readLatestSubagentOutput loop not found", file=sys.stderr)
    sys.exit(1)
content = content.replace(old_loop, new_loop, 1)

# 3) Truncate oversized findings
old_findings = '    const findings = childCompletionFindings || reply || "(no output)";'
new_findings = '''    let findings = childCompletionFindings || reply || "(no output)";
    // Truncate overly long findings to prevent flooding the chat channel.
    if (findings.length > MAX_FINDINGS_LENGTH) {
      findings = findings.slice(0, MAX_FINDINGS_LENGTH) + "\\n\\n[... output truncated]";
    }'''

if old_findings not in content:
    print("    FAIL: #32265 findings const not found", file=sys.stderr)
    sys.exit(1)
content = content.replace(old_findings, new_findings, 1)

with open(path, 'w') as f:
    f.write(content)
print("    OK: #32265 subagent timeout leak guard applied")
PYEOF

echo "    OK: #32265 prevent subagent timeout from leaking tool results to chat"
