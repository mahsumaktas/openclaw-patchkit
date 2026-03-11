#!/usr/bin/env bash
# PR #38320 — fix(agents): repair structurally complete interrupted tool calls
#
# Core change: Replace blanket stopReason skip with per-block structural checks.
# Adds toRepairableToolCall() + extractRepairableToolCallsFromAssistant() to
# session-transcript-repair.ts, then wires it into session-tool-result-guard.ts
# so that even aborted/errored assistant messages get synthetic tool_results
# for their structurally complete tool calls.
#
# Files:
#   1. session-transcript-repair.ts:
#      a. Add ToolCallLike type import from tool-call-id.js
#      b. Add toRepairableToolCall() function
#      c. Add extractRepairableToolCallsFromAssistant() export
#      d. repairToolUseResultPairing: use extractRepairableToolCallsFromAssistant
#   2. session-tool-result-guard.ts:
#      a. Import extractRepairableToolCallsFromAssistant from session-transcript-repair
#      b. Remove extractToolCallsFromAssistant from tool-call-id import
#      c. Use extractRepairableToolCallsFromAssistant in guardedAppend
set -euo pipefail
SRC="${1:-.}/src"

REPAIR_FILE="$SRC/agents/session-transcript-repair.ts"
GUARD_FILE="$SRC/agents/session-tool-result-guard.ts"

# --- Idempotency check ---
if grep -q 'extractRepairableToolCallsFromAssistant' "$REPAIR_FILE" 2>/dev/null; then
  echo "    SKIP: #38320 already applied"
  exit 0
fi

# --- File existence checks ---
[ -f "$REPAIR_FILE" ] || { echo "    FAIL: #38320 $REPAIR_FILE not found"; exit 1; }
[ -f "$GUARD_FILE" ]  || { echo "    FAIL: #38320 $GUARD_FILE not found"; exit 1; }

# ============================================================
# PART 1: session-transcript-repair.ts
# ============================================================
python3 - "$REPAIR_FILE" << 'PYEOF'
import sys

path = sys.argv[1]
with open(path, 'r') as f:
    content = f.read()

changed = False

# 1a. Add ToolCallLike type import from tool-call-id.js
old_import = 'import { extractToolCallsFromAssistant, extractToolResultId } from "./tool-call-id.js";'
new_import = '''import type { ToolCallLike } from "./tool-call-id.js";
import { extractToolCallsFromAssistant, extractToolResultId } from "./tool-call-id.js";'''

if old_import in content:
    content = content.replace(old_import, new_import, 1)
    changed = True
    print("    OK: #38320 part 1a: added ToolCallLike type import")
elif 'ToolCallLike' in content:
    print("    SKIP: #38320 part 1a: ToolCallLike already imported")
else:
    print("    FAIL: #38320 part 1a: unexpected import layout", file=sys.stderr)
    sys.exit(1)

# 1b. Add toRepairableToolCall() function before makeMissingToolResult
old_before_make = '''function makeMissingToolResult(params: {
  toolCallId: string;
  toolName?: string;
}): Extract<AgentMessage, { role: "toolResult" }> {'''

new_before_make = '''function toRepairableToolCall(
  block: RawToolCallBlock,
  allowedToolNames: Set<string> | null,
): ToolCallLike | null {
  if (
    !hasToolCallInput(block) ||
    !hasToolCallId(block) ||
    !hasToolCallName(block, allowedToolNames)
  ) {
    return null;
  }

  const id = trimNonEmptyString(block.id);
  if (!id) {
    return null;
  }

  return {
    id,
    name: trimNonEmptyString(block.name),
  };
}

function makeMissingToolResult(params: {
  toolCallId: string;
  toolName?: string;
}): Extract<AgentMessage, { role: "toolResult" }> {'''

if old_before_make in content:
    content = content.replace(old_before_make, new_before_make, 1)
    changed = True
    print("    OK: #38320 part 1b: added toRepairableToolCall function")
else:
    print("    FAIL: #38320 part 1b: could not find makeMissingToolResult boundary", file=sys.stderr)
    sys.exit(1)

# 1c. Add extractRepairableToolCallsFromAssistant export after sanitizeToolCallInputs
old_sanitize = '''export function sanitizeToolCallInputs(
  messages: AgentMessage[],
  options?: ToolCallInputRepairOptions,
): AgentMessage[] {
  return repairToolCallInputs(messages, options).messages;
}'''

new_sanitize = '''export function sanitizeToolCallInputs(
  messages: AgentMessage[],
  options?: ToolCallInputRepairOptions,
): AgentMessage[] {
  return repairToolCallInputs(messages, options).messages;
}

export function extractRepairableToolCallsFromAssistant(
  message: Extract<AgentMessage, { role: "assistant" }>,
  options?: ToolCallInputRepairOptions,
): ToolCallLike[] {
  if (!Array.isArray(message.content)) {
    return [];
  }

  const allowedToolNames = normalizeAllowedToolNames(options?.allowedToolNames);
  const toolCalls: ToolCallLike[] = [];
  for (const block of message.content) {
    if (!isRawToolCallBlock(block)) {
      continue;
    }
    const next = toRepairableToolCall(block, allowedToolNames);
    if (next) {
      toolCalls.push(next);
    }
  }
  return toolCalls;
}'''

if old_sanitize in content:
    content = content.replace(old_sanitize, new_sanitize, 1)
    changed = True
    print("    OK: #38320 part 1c: added extractRepairableToolCallsFromAssistant")
else:
    print("    FAIL: #38320 part 1c: could not find sanitizeToolCallInputs", file=sys.stderr)
    sys.exit(1)

# 1d. In repairToolUseResultPairing: replace stopReason skip with structural check
# This handles BOTH the original v2026.3.8 code AND the post-#14328 patched code.

new_repair = (
    '    const assistant = msg as Extract<AgentMessage, { role: "assistant" }>;\n'
    '\n'
    '    // Repair is based on structural completeness, not stopReason alone.\n'
    '    // Interrupted assistant turns can still contain fully-formed persisted tool calls\n'
    '    // that need synthetic tool results to keep the transcript valid, while partial\n'
    '    // streamed fragments are ignored here because they fail the structural checks.\n'
    '    const toolCalls = extractRepairableToolCallsFromAssistant(assistant);'
)

# Pattern A: post-#14328 (with nonToolContent filter + #14322 reference)
old_repair_post14328 = (
    '    const assistant = msg as Extract<AgentMessage, { role: "assistant" }>;\n'
    '\n'
)

# Find the block from "const assistant" up to and including "const toolCalls = extractToolCallsFromAssistant"
import re
# Match everything from "const assistant" through the stopReason block to "const toolCalls = extractToolCallsFromAssistant"
pattern = re.compile(
    r'(    const assistant = msg as Extract<AgentMessage, \{ role: "assistant" \}>;\n)'
    r'(.*?)'
    r'(    const toolCalls = extractToolCallsFromAssistant\(assistant\);)',
    re.DOTALL
)

m = pattern.search(content)
if m:
    full_match = m.group(0)
    content = content.replace(full_match, new_repair, 1)
    changed = True
    print("    OK: #38320 part 1d: replaced stopReason skip with structural check")
else:
    print("    FAIL: #38320 part 1d: could not find stopReason skip + extractToolCallsFromAssistant block", file=sys.stderr)
    sys.exit(1)

if changed:
    with open(path, 'w') as f:
        f.write(content)

print("    OK: #38320 part 1: session-transcript-repair.ts done")
PYEOF

# ============================================================
# PART 2: session-tool-result-guard.ts
# ============================================================
python3 - "$GUARD_FILE" << 'PYEOF'
import sys

path = sys.argv[1]
with open(path, 'r') as f:
    content = f.read()

changed = False

# 2a. Update imports
old_repair_import = 'import { makeMissingToolResult, sanitizeToolCallInputs } from "./session-transcript-repair.js";'
new_repair_import = '''import {
  extractRepairableToolCallsFromAssistant,
  makeMissingToolResult,
  sanitizeToolCallInputs,
} from "./session-transcript-repair.js";'''

if old_repair_import in content:
    content = content.replace(old_repair_import, new_repair_import, 1)
    changed = True
    print("    OK: #38320 part 2a: updated session-transcript-repair import")
elif 'extractRepairableToolCallsFromAssistant' in content:
    print("    SKIP: #38320 part 2a: already imported")
else:
    print("    FAIL: #38320 part 2a: could not find session-transcript-repair import", file=sys.stderr)
    sys.exit(1)

# Remove extractToolCallsFromAssistant from tool-call-id import
old_toolcall_import = 'import { extractToolCallsFromAssistant, extractToolResultId } from "./tool-call-id.js";'
new_toolcall_import = 'import { extractToolResultId } from "./tool-call-id.js";'

if old_toolcall_import in content:
    content = content.replace(old_toolcall_import, new_toolcall_import, 1)
    changed = True
    print("    OK: #38320 part 2a: removed extractToolCallsFromAssistant from tool-call-id import")
elif 'extractToolCallsFromAssistant' not in content:
    print("    SKIP: #38320 part 2a: extractToolCallsFromAssistant already removed")
else:
    print("    FAIL: #38320 part 2a: unexpected tool-call-id import layout", file=sys.stderr)
    sys.exit(1)

# 2b. Replace the stopReason-guarded call with extractRepairableToolCallsFromAssistant
old_call = '''    // Skip tool call extraction for aborted/errored assistant messages.
    // When stopReason is "error" or "aborted", the tool_use blocks may be incomplete
    // and should not have synthetic tool_results created. Creating synthetic results
    // for incomplete tool calls causes API 400 errors:
    // "unexpected tool_use_id found in tool_result blocks"
    // This matches the behavior in repairToolUseResultPairing (session-transcript-repair.ts)
    const stopReason = (nextMessage as { stopReason?: string }).stopReason;
    const toolCalls =
      nextRole === "assistant" && stopReason !== "aborted" && stopReason !== "error"
        ? extractToolCallsFromAssistant(nextMessage as Extract<AgentMessage, { role: "assistant" }>)
        : [];'''

new_call = '''    const toolCalls =
      nextRole === "assistant"
        ? extractRepairableToolCallsFromAssistant(
            nextMessage as Extract<AgentMessage, { role: "assistant" }>,
            {
              allowedToolNames: opts?.allowedToolNames,
            },
          )
        : [];'''

if old_call in content:
    content = content.replace(old_call, new_call, 1)
    changed = True
    print("    OK: #38320 part 2b: replaced extractToolCallsFromAssistant call")
elif 'extractRepairableToolCallsFromAssistant' in content and 'extractToolCallsFromAssistant' not in content:
    print("    SKIP: #38320 part 2b: already using extractRepairableToolCallsFromAssistant")
else:
    print("    FAIL: #38320 part 2b: could not find extractToolCallsFromAssistant call site", file=sys.stderr)
    sys.exit(1)

if changed:
    with open(path, 'w') as f:
        f.write(content)

print("    OK: #38320 part 2: session-tool-result-guard.ts done")
PYEOF

echo "    OK: #38320 repair structurally complete interrupted tool calls applied (2 files)"
