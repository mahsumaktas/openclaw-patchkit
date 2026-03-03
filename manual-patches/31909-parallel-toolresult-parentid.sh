#!/usr/bin/env bash
set -euo pipefail
cd "$1"

# PR #31909 — Ensure parallel tool results have correct parentId
# When multiple tool results come from the same assistant message, they should
# all reference the assistant message as parent (not chain to each other).
# Uses sessionManager.branch(assistantEntryId) + sessionManager.getLeafId().
#
# NOTE: v2026.3.2 uses createPendingToolCallState() abstraction instead of raw Map.
# The patch adds assistantEntryId tracking + branch() calls before appending tool results.

FILE="src/agents/session-tool-result-guard.ts"

if [[ ! -f "$FILE" ]]; then
  echo "SKIP #31909: $FILE not found"
  exit 0
fi

# Idempotency
if grep -q 'assistantEntryId' "$FILE" 2>/dev/null; then
  echo "SKIP #31909: already patched (assistantEntryId found)"
  exit 0
fi

python3 - "$FILE" << 'PYEOF'
import sys

filepath = sys.argv[1]
with open(filepath, 'r') as f:
    content = f.read()

# --- PART 1: Add assistantEntryId state variable after pendingState creation ---
old_state = '''  const originalAppend = sessionManager.appendMessage.bind(sessionManager);
  const pendingState = createPendingToolCallState();'''

new_state = '''  const originalAppend = sessionManager.appendMessage.bind(sessionManager);
  // Map from toolCallId -> toolName (for pending tool calls)
  const pendingState = createPendingToolCallState();
  // The entry ID of the assistant message that has pending tool calls.
  // All tool results for this assistant message should have this ID as their parentId.
  let assistantEntryId: string | null = null;'''

if old_state not in content:
    print(f"FAIL #31909 part 1: could not find originalAppend + pendingState block in {filepath}")
    sys.exit(1)

content = content.replace(old_state, new_state, 1)

# --- PART 2: Add branch() call in flushPendingToolResults before each synthetic append ---
old_flush = '''      for (const [id, name] of pendingState.entries()) {
        const synthetic = makeMissingToolResult({ toolCallId: id, toolName: name });
        const flushed = applyBeforeWriteHook('''

new_flush = '''      for (const [id, name] of pendingState.entries()) {
        const synthetic = makeMissingToolResult({ toolCallId: id, toolName: name });
        // Branch to assistant message before appending each synthetic tool result
        // so they all have the assistant as their parent
        if (assistantEntryId) {
          sessionManager.branch(assistantEntryId);
        }
        const flushed = applyBeforeWriteHook('''

if old_flush not in content:
    print(f"FAIL #31909 part 2: could not find flush loop in {filepath}")
    sys.exit(1)

content = content.replace(old_flush, new_flush, 1)

# --- PART 3: Clear assistantEntryId after pendingState.clear() in flushPendingToolResults ---
old_clear = '''    pendingState.clear();
  };'''

new_clear = '''    pendingState.clear();
    assistantEntryId = null;
  };'''

if old_clear not in content:
    print(f"FAIL #31909 part 3: could not find pendingState.clear() in {filepath}")
    sys.exit(1)

content = content.replace(old_clear, new_clear, 1)

# --- PART 4: Add branch() call before originalAppend in toolResult handling ---
# v2026.3.2 has (after #25169 patch or without):
#       if (!persisted) {
#         return undefined;
#       }
#       return originalAppend(persisted as never);
old_append = '''      if (!persisted) {
        return undefined;
      }
      return originalAppend(persisted as never);
    }'''

new_append = '''      if (!persisted) {
        return undefined;
      }
      // FIX: Branch to assistant message before appending tool result.
      // This ensures all tool results from the same assistant message have
      // the assistant message as their parent, not the previous tool result.
      if (assistantEntryId) {
        sessionManager.branch(assistantEntryId);
      }
      const result = originalAppend(persisted as never);
      // Clear assistant entry ID when all pending tool results are done
      if (pendingState.size() === 0) {
        assistantEntryId = null;
      }
      return result;
    }'''

if old_append not in content:
    print(f"FAIL #31909 part 4: could not find toolResult originalAppend block in {filepath}")
    sys.exit(1)

content = content.replace(old_append, new_append, 1)

# --- PART 5: Store assistantEntryId when tool calls are tracked ---
# v2026.3.2 has:
#     if (toolCalls.length > 0) {
#       pendingState.trackToolCalls(toolCalls);
#     }
old_track = '''    if (toolCalls.length > 0) {
      pendingState.trackToolCalls(toolCalls);
    }'''

new_track = '''    if (toolCalls.length > 0) {
      // Store the assistant message's entry ID so tool results can reference it
      assistantEntryId = sessionManager.getLeafId();
      pendingState.trackToolCalls(toolCalls);
    }'''

if old_track not in content:
    print(f"FAIL #31909 part 5: could not find toolCalls tracking block in {filepath}")
    sys.exit(1)

content = content.replace(old_track, new_track, 1)

with open(filepath, 'w') as f:
    f.write(content)

print(f"OK #31909: added parallel tool result parentId fix to {filepath}")
PYEOF
