#!/usr/bin/env bash
set -euo pipefail
cd "$1"

# PR #25169 — Drop toolResult with empty/blank call_id
# Two changes:
# 1. tool-call-id.ts: extractToolResultId() now trims and rejects blank strings
# 2. session-tool-result-guard.ts: Early return for missing/blank toolCallId in guardedAppend

FILE_TOOLID="src/agents/tool-call-id.ts"
FILE_GUARD="src/agents/session-tool-result-guard.ts"

if [[ ! -f "$FILE_TOOLID" ]]; then
  echo "SKIP #25169: $FILE_TOOLID not found"
  exit 0
fi
if [[ ! -f "$FILE_GUARD" ]]; then
  echo "SKIP #25169: $FILE_GUARD not found"
  exit 0
fi

# Idempotency
if grep -q 'const readId' "$FILE_TOOLID" 2>/dev/null || grep -q 'trimmed\.length > 0' "$FILE_TOOLID" 2>/dev/null; then
  echo "SKIP #25169 tool-call-id: already patched"
else
  # --- PART 1: tool-call-id.ts — rewrite extractToolResultId to trim/reject blank ---
  python3 - "$FILE_TOOLID" << 'PYEOF'
import sys

filepath = sys.argv[1]
with open(filepath, 'r') as f:
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
    print(f"FAIL #25169 tool-call-id: could not find extractToolResultId function in {filepath}")
    sys.exit(1)

content = content.replace(old, new, 1)

with open(filepath, 'w') as f:
    f.write(content)

print(f"OK #25169 part 1: patched extractToolResultId in {filepath}")
PYEOF
fi

# --- PART 2: session-tool-result-guard.ts — drop toolResult with missing id ---
if grep -q 'Drop malformed tool results' "$FILE_GUARD" 2>/dev/null; then
  echo "SKIP #25169 guard: already patched"
  exit 0
fi

python3 - "$FILE_GUARD" << 'PYEOF'
import sys

filepath = sys.argv[1]
with open(filepath, 'r') as f:
    content = f.read()

# v2026.3.2 has:
#     if (nextRole === "toolResult") {
#       const id = extractToolResultId(nextMessage as Extract<AgentMessage, { role: "toolResult" }>);
#       const toolName = id ? pendingState.getToolName(id) : undefined;
#       if (id) {
#         pendingState.delete(id);
#       }

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
    print(f"FAIL #25169 guard: could not find toolResult handling block in {filepath}")
    sys.exit(1)

content = content.replace(old, new, 1)

with open(filepath, 'w') as f:
    f.write(content)

print(f"OK #25169 part 2: added empty toolCallId guard in {filepath}")
PYEOF
