#!/usr/bin/env bash
# PR #31909 — fix(agents): ensure parallel tool results have correct parentId
# 1 file: session-tool-result-guard.ts (tests skipped)
#
# Problem: When multiple tool results come from the same assistant message,
# they get chained parentIds (assistant -> result1 -> result2) instead of
# all pointing to the assistant message. This causes Anthropic API 400 errors.
#
# Fix: Track assistantEntryId, branch to it before appending each tool result.
# Uses pendingState API (v2026.3.8).
set -euo pipefail
SRC="${1:-.}/src"

GUARD="$SRC/agents/session-tool-result-guard.ts"

# ── Idempotency ──
if grep -q 'assistantEntryId' "$GUARD" 2>/dev/null; then
  echo "    SKIP: #31909 already applied"
  exit 0
fi

# ── File checks ──
[ -f "$GUARD" ] || { echo "    FAIL: #31909 $GUARD not found"; exit 1; }

python3 - "$GUARD" << 'PYEOF'
import sys

path = sys.argv[1]
with open(path, 'r') as f:
    content = f.read()

# Part 1: Add assistantEntryId variable after pendingState creation
old_pending = '''  const originalAppend = sessionManager.appendMessage.bind(sessionManager);
  const pendingState = createPendingToolCallState();
  const persistMessage = (message: AgentMessage) => {'''

new_pending = '''  const originalAppend = sessionManager.appendMessage.bind(sessionManager);
  const pendingState = createPendingToolCallState();
  // The entry ID of the assistant message that has pending tool calls.
  // All tool results for this assistant message should have this ID as their parentId.
  let assistantEntryId: string | null = null;
  const persistMessage = (message: AgentMessage) => {'''

if old_pending not in content:
    print("    FAIL: #31909 cannot find pendingState creation block", file=sys.stderr)
    sys.exit(1)

content = content.replace(old_pending, new_pending, 1)

# Part 2: In flushPendingToolResults, branch to assistant before each synthetic result
old_flush = '''    if (allowSyntheticToolResults) {
      for (const [id, name] of pendingState.entries()) {
        const synthetic = makeMissingToolResult({ toolCallId: id, toolName: name });
        const flushed = applyBeforeWriteHook('''

new_flush = '''    if (allowSyntheticToolResults) {
      for (const [id, name] of pendingState.entries()) {
        const synthetic = makeMissingToolResult({ toolCallId: id, toolName: name });
        // Branch to assistant message before appending each synthetic tool result
        // so they all have the assistant as their parent
        if (assistantEntryId) {
          sessionManager.branch(assistantEntryId);
        }
        const flushed = applyBeforeWriteHook('''

if old_flush not in content:
    print("    FAIL: #31909 cannot find flushPendingToolResults synthetic block", file=sys.stderr)
    sys.exit(1)

content = content.replace(old_flush, new_flush, 1)

# Part 3: Clear assistantEntryId after flush
old_clear = '''    pendingState.clear();
  };

  const clearPendingToolResults = () => {'''

new_clear = '''    pendingState.clear();
    assistantEntryId = null;
  };

  const clearPendingToolResults = () => {'''

if old_clear not in content:
    print("    FAIL: #31909 cannot find pendingState.clear() in flush", file=sys.stderr)
    sys.exit(1)

content = content.replace(old_clear, new_clear, 1)

# Part 4: In guardedAppend toolResult section, branch to assistant before append
# Handle both pre-#38320 and post-#38320 layout
old_append_pre = '''      if (!persisted) {
        return undefined;
      }
      return originalAppend(persisted as never);
    }

    // Skip tool call extraction for aborted/errored assistant messages.'''

old_append_post = '''      if (!persisted) {
        return undefined;
      }
      return originalAppend(persisted as never);
    }

    const toolCalls ='''

branch_insert = '''      if (!persisted) {
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
    }
'''

if old_append_pre in content:
    content = content.replace(old_append_pre, branch_insert + '\n    // Skip tool call extraction for aborted/errored assistant messages.', 1)
elif old_append_post in content:
    content = content.replace(old_append_post, branch_insert + '\n    const toolCalls =', 1)
else:
    print("    FAIL: #31909 cannot find toolResult originalAppend block", file=sys.stderr)
    sys.exit(1)

# Part 5: Store assistantEntryId when tracking tool calls
old_track = '''    if (toolCalls.length > 0) {
      pendingState.trackToolCalls(toolCalls);
    }'''

new_track = '''    if (toolCalls.length > 0) {
      // Store the assistant message's entry ID so tool results can reference it
      assistantEntryId = sessionManager.getLeafId();
      pendingState.trackToolCalls(toolCalls);
    }'''

if old_track not in content:
    print("    FAIL: #31909 cannot find trackToolCalls block", file=sys.stderr)
    sys.exit(1)

content = content.replace(old_track, new_track, 1)

with open(path, 'w') as f:
    f.write(content)
print("    OK: #31909 session-tool-result-guard.ts — assistantEntryId + branch()")
PYEOF

echo "    OK: #31909 parallel tool results parentId fix applied"
