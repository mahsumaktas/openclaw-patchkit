#!/usr/bin/env bash
# PR #25381: fix(agents): preserve thinking blocks in latest assistant during compaction
#
# SELECTIVE: Only thinking.ts core fix from 12-file PR.
# Other files (provider refactor, telegram dice, orphan cleanup) are separate features.
#
# Core fix: dropThinkingBlocks() was stripping ALL thinking blocks from assistant
# messages. Anthropic API requires thinking blocks in the LATEST assistant message
# to remain intact. Removing them causes API 400:
# "thinking or redacted_thinking blocks in the latest assistant message cannot be modified"
#
# Changes:
#   1. src/agents/pi-embedded-runner/thinking.ts — find latest assistant, skip stripping
set -euo pipefail
cd "$1"

FILE="src/agents/pi-embedded-runner/thinking.ts"
[ -f "$FILE" ] || { echo "FAIL: $FILE not found"; exit 1; }

# ── Idempotency gate ─────────────────────────────────────────────────────────
if grep -q 'latestAssistantIndex' "$FILE" 2>/dev/null; then
  echo "SKIP: #25381 already applied (latestAssistantIndex found)"
  exit 0
fi

python3 << 'PYEOF'
import sys

filepath = "src/agents/pi-embedded-runner/thinking.ts"
with open(filepath, "r") as f:
    code = f.read()

# ── Update JSDoc comment ─────────────────────────────────────────────────────
old_doc = '/**\n * Strip all `type: "thinking"` content blocks from assistant messages.'
new_doc = '''/**
 * Strip `type: "thinking"` content blocks from assistant messages, EXCEPT
 * the latest assistant message.
 *
 * Anthropic's API requires that thinking/redacted_thinking blocks in the
 * latest assistant message remain exactly as received - they cannot be
 * modified or removed. Stripping them causes API 400 errors:
 * "thinking or redacted_thinking blocks in the latest assistant message cannot be modified"'''

if old_doc in code:
    code = code.replace(old_doc, new_doc, 1)
    print("OK: #25381 JSDoc updated")
else:
    print("WARN: #25381 JSDoc marker not found, continuing with logic change")

# ── Core fix: add latestAssistantIndex + skip latest assistant ────────────────
# Replace the function body from "export function dropThinkingBlocks"
old_body = '''export function dropThinkingBlocks(messages: AgentMessage[]): AgentMessage[] {
  let touched = false;
  const out: AgentMessage[] = [];
  for (const msg of messages) {
    if (!isAssistantMessageWithContent(msg)) {
      out.push(msg);
      continue;
    }'''

new_body = '''export function dropThinkingBlocks(messages: AgentMessage[]): AgentMessage[] {
  let latestAssistantIndex = -1;
  for (let i = messages.length - 1; i >= 0; i -= 1) {
    if (isAssistantMessageWithContent(messages[i])) {
      latestAssistantIndex = i;
      break;
    }
  }

  let touched = false;
  const out: AgentMessage[] = [];
  for (let i = 0; i < messages.length; i += 1) {
    const msg = messages[i];
    if (!isAssistantMessageWithContent(msg)) {
      out.push(msg);
      continue;
    }
    if (i === latestAssistantIndex) {
      out.push(msg);
      continue;
    }'''

if old_body in code:
    code = code.replace(old_body, new_body, 1)
    with open(filepath, "w") as f:
        f.write(code)
    print("OK: #25381 thinking.ts patched — latest assistant thinking blocks preserved")
else:
    print("FAIL: #25381 cannot find dropThinkingBlocks function body", file=sys.stderr)
    sys.exit(1)

PYEOF
