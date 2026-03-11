#!/usr/bin/env bash
# PR #25169 — fix: drop toolResult with empty/blank call_id to prevent session corruption
# 2 files: tool-call-id.ts, session-tool-result-guard.ts
#
# Changes:
# 1. tool-call-id.ts: extractToolResultId gets readId helper that trims and rejects blank
# 2. session-tool-result-guard.ts: early return undefined for missing/blank toolCallId
set -euo pipefail
SRC="${1:-.}/src"

TOOL_ID="$SRC/agents/tool-call-id.ts"
GUARD="$SRC/agents/session-tool-result-guard.ts"

# ── Idempotency ──
if grep -q 'const readId' "$TOOL_ID" 2>/dev/null; then
  echo "    SKIP: #25169 already applied"
  exit 0
fi

# ── File checks ──
[ -f "$TOOL_ID" ] || { echo "    FAIL: #25169 $TOOL_ID not found"; exit 1; }
[ -f "$GUARD" ] || { echo "    FAIL: #25169 $GUARD not found"; exit 1; }

# ── 1. Rewrite extractToolResultId with readId helper ──
python3 - "$TOOL_ID" << 'PYEOF'
import sys

path = sys.argv[1]
with open(path, 'r') as f:
    content = f.read()

old = '''export function extractToolResultId(
  msg: Extract<AgentMessage, { role: "toolResult" }>,
): string | null {
  const toolCallId = (msg as { toolCallId?: unknown }).toolCallId;
  if (typeof toolCallId === "string" && toolCallId) {
    return toolCallId;
  }
  const toolUseId = (msg as { toolUseId?: unknown }).toolUseId;
  if (typeof toolUseId === "string" && toolUseId) {
    return toolUseId;
  }
  return null;
}'''

new = '''export function extractToolResultId(
  msg: Extract<AgentMessage, { role: "toolResult" }>,
): string | null {
  const readId = (value: unknown): string | null => {
    if (typeof value !== "string") {
      return null;
    }
    const trimmed = value.trim();
    return trimmed.length > 0 ? trimmed : null;
  };

  const toolCallId = readId((msg as { toolCallId?: unknown }).toolCallId);
  if (toolCallId) {
    return toolCallId;
  }
  const toolUseId = readId((msg as { toolUseId?: unknown }).toolUseId);
  if (toolUseId) {
    return toolUseId;
  }
  return null;
}'''

if old not in content:
    print("    FAIL: #25169 cannot find extractToolResultId function", file=sys.stderr)
    sys.exit(1)

content = content.replace(old, new, 1)

with open(path, 'w') as f:
    f.write(content)
print("    OK: #25169 tool-call-id.ts — readId with trim/reject")
PYEOF

# ── 2. Add blank callId guard to session-tool-result-guard.ts ──
python3 - "$GUARD" << 'PYEOF'
import sys

path = sys.argv[1]
with open(path, 'r') as f:
    content = f.read()

old = '''    if (nextRole === "toolResult") {
      const id = extractToolResultId(nextMessage as Extract<AgentMessage, { role: "toolResult" }>);
      const toolName = id ? pendingState.getToolName(id) : undefined;
      if (id) {
        pendingState.delete(id);
      }'''

new = '''    if (nextRole === "toolResult") {
      const id = extractToolResultId(nextMessage as Extract<AgentMessage, { role: "toolResult" }>);
      if (!id) {
        // Drop malformed tool results (missing/blank toolCallId/toolUseId) so they don't poison
        // persisted session transcripts and break strict providers during history replay.
        return undefined;
      }
      const toolName = id ? pendingState.getToolName(id) : undefined;
      pendingState.delete(id);'''

if old not in content:
    print("    FAIL: #25169 cannot find toolResult handling block in guard", file=sys.stderr)
    sys.exit(1)

content = content.replace(old, new, 1)

with open(path, 'w') as f:
    f.write(content)
print("    OK: #25169 session-tool-result-guard.ts — blank callId guard")
PYEOF

echo "    OK: #25169 blank call_id drop applied"
