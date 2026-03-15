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
#
# v2: Rewritten for v2026.3.13 — uses regex anchors instead of exact string
#     matching to survive code churn between versions.
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
import sys, re

path = sys.argv[1]
with open(path, 'r') as f:
    content = f.read()

original = content
changes = 0

# ─── 1) Add MAX_FINDINGS_LENGTH constant after MAX_TIMER_SAFE_TIMEOUT_MS line ───
# Match the MAX_TIMER_SAFE_TIMEOUT_MS declaration regardless of numeric format
# (2_147_000_000, 2147000000, 2147e6, etc.) and insert our constant after it.
# Anchors on the line itself, not on what follows.
timer_pat = re.compile(
    r'(const\s+MAX_TIMER_SAFE_TIMEOUT_MS\s*=\s*[^;]+;[ \t]*\n)',
    re.MULTILINE
)
m = timer_pat.search(content)
if not m:
    print("    FAIL: #32265 MAX_TIMER_SAFE_TIMEOUT_MS declaration not found", file=sys.stderr)
    sys.exit(1)

insert_after = m.end()
constant_block = (
    "\n"
    "/** Hard cap on findings text forwarded in completion messages. */\n"
    "const MAX_FINDINGS_LENGTH = 2000;\n"
    "\n"
)
content = content[:insert_after] + constant_block + content[insert_after:]
changes += 1

# ─── 2) Filter readLatestSubagentOutput fallback loop to assistant-only ───
# The fallback path iterates history.messages and calls extractSubagentOutputText
# on every message, including toolResult/tool roles. We add a role guard.
#
# We match the loop body pattern with flexible whitespace:
#   const messages = Array.isArray(history?.messages) ...
#   for (let i = messages.length - 1; i >= 0; i -= 1) {
#     const msg = messages[i];
#     const text = extractSubagentOutputText(msg);
loop_pat = re.compile(
    r'(?P<indent>[ \t]*)'
    r'const messages = Array\.isArray\(history\?\.messages\) \? history\.messages : \[\];\s*\n'
    r'(?P=indent)for \(let i = messages\.length - 1; i >= 0; i -= 1\) \{\s*\n'
    r'(?P=indent)(?P<inner_indent>[ \t]+)const msg = messages\[i\];\s*\n'
    r'(?P=indent)(?P=inner_indent)const text = extractSubagentOutputText\(msg\);',
    re.MULTILINE
)
m2 = loop_pat.search(content)
if not m2:
    print("    FAIL: #32265 readLatestSubagentOutput fallback loop not found", file=sys.stderr)
    sys.exit(1)

indent = m2.group('indent')
inner = m2.group('inner_indent')

old_loop = m2.group(0)
new_loop = (
    f'{indent}// Security: only extract assistant-role messages in the fallback path.\n'
    f'{indent}// toolResult/tool content may contain raw source code, API keys, or other\n'
    f'{indent}// sensitive data that must not be forwarded to the chat channel.\n'
    f'{indent}const messages = Array.isArray(history?.messages) ? history.messages : [];\n'
    f'{indent}for (let i = messages.length - 1; i >= 0; i -= 1) {{\n'
    f'{indent}{inner}const msg = messages[i];\n'
    f'{indent}{inner}if (!msg || typeof msg !== "object") {{\n'
    f'{indent}{inner}  continue;\n'
    f'{indent}{inner}}}\n'
    f'{indent}{inner}const role = (msg as {{ role?: unknown }}).role;\n'
    f'{indent}{inner}if (role !== "assistant") {{\n'
    f'{indent}{inner}  continue;\n'
    f'{indent}{inner}}}\n'
    f'{indent}{inner}const text = extractSubagentOutputText(msg);'
)

content = content.replace(old_loop, new_loop, 1)
changes += 1

# ─── 3) Truncate oversized findings ───
# Match both "const findings = ..." and "let findings = ..." to be safe,
# and handle flexible indentation/spacing.
findings_pat = re.compile(
    r'(?P<indent>[ \t]*)'
    r'(?:const|let)\s+findings\s*=\s*childCompletionFindings\s*\|\|\s*reply\s*\|\|\s*"\(no output\)"\s*;',
    re.MULTILINE
)
m3 = findings_pat.search(content)
if not m3:
    print("    FAIL: #32265 findings assignment not found", file=sys.stderr)
    sys.exit(1)

fi = m3.group('indent')
old_findings = m3.group(0)
new_findings = (
    f'{fi}let findings = childCompletionFindings || reply || "(no output)";\n'
    f'{fi}// Truncate overly long findings to prevent flooding the chat channel.\n'
    f'{fi}if (findings.length > MAX_FINDINGS_LENGTH) {{\n'
    f'{fi}  findings = findings.slice(0, MAX_FINDINGS_LENGTH) + "\\n\\n[... output truncated]";\n'
    f'{fi}}}'
)

content = content.replace(old_findings, new_findings, 1)
changes += 1

if changes != 3:
    print(f"    FAIL: #32265 expected 3 changes, got {changes}", file=sys.stderr)
    sys.exit(1)

with open(path, 'w') as f:
    f.write(content)
print("    OK: #32265 subagent timeout leak guard applied (3 changes)")
PYEOF

echo "    OK: #32265 prevent subagent timeout from leaking tool results to chat"
