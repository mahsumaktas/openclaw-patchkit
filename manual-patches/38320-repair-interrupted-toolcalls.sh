#!/usr/bin/env bash
# PR #38320 — fix(agents): repair structurally complete interrupted tool calls
#
# Core issue: When stopReason is "error" or "aborted", the code skips ALL tool
# call extraction — even for structurally complete, persisted tool calls. This
# means valid tool_use blocks that have id + name + input/arguments never get
# their synthetic tool_result, corrupting the transcript for strict providers.
#
# Fix: Replace the blanket stopReason skip with structural completeness checks.
# A new `toRepairableToolCall` function validates each block individually:
# only blocks with a valid id, name, and input/arguments are extracted.
# Partial/incomplete blocks (missing fields) are silently skipped.
#
# Changes:
# 1. session-transcript-repair.ts:
#    a. Import ToolCallLike type from tool-call-id.js
#    b. Add toRepairableToolCall() — per-block structural completeness check
#    c. Add extractRepairableToolCallsFromAssistant() export
#    d. repairToolUseResultPairing: remove stopReason skip, use new extractor
# 2. session-tool-result-guard.ts:
#    a. Import extractRepairableToolCallsFromAssistant from session-transcript-repair
#    b. Remove extractToolCallsFromAssistant import from tool-call-id
#    c. Use extractRepairableToolCallsFromAssistant in guardedAppend
set -euo pipefail
SRC="${1:-.}/src"

REPAIR_FILE="$SRC/agents/session-transcript-repair.ts"
GUARD_FILE="$SRC/agents/session-tool-result-guard.ts"

# --- File existence checks ---
[ -f "$REPAIR_FILE" ] || { echo "    FAIL: #38320 $REPAIR_FILE not found"; exit 1; }
[ -f "$GUARD_FILE" ]  || { echo "    FAIL: #38320 $GUARD_FILE not found"; exit 1; }

# --- Idempotency check ---
if grep -q 'toRepairableToolCall' "$REPAIR_FILE" 2>/dev/null; then
  echo "    SKIP: #38320 already applied"
  exit 0
fi

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
# Current: import { extractToolCallsFromAssistant, extractToolResultId } from "./tool-call-id.js";
# Target:  import type { ToolCallLike } from "./tool-call-id.js";
#          import { extractToolResultId } from "./tool-call-id.js";

old_import = 'import { extractToolCallsFromAssistant, extractToolResultId } from "./tool-call-id.js";'
new_import = '''import type { ToolCallLike } from "./tool-call-id.js";
import { extractToolResultId } from "./tool-call-id.js";'''

if old_import in content:
    content = content.replace(old_import, new_import, 1)
    changed = True
    print("    OK: #38320 part 1a: updated tool-call-id imports")
else:
    # Maybe extractToolCallsFromAssistant was already removed by another patch
    if 'extractToolCallsFromAssistant' not in content and 'extractToolResultId' in content:
        if 'ToolCallLike' not in content:
            # Add type import before the existing extractToolResultId import
            old_result_import = 'import { extractToolResultId } from "./tool-call-id.js";'
            if old_result_import in content:
                new_result_import = 'import type { ToolCallLike } from "./tool-call-id.js";\n' + old_result_import
                content = content.replace(old_result_import, new_result_import, 1)
                changed = True
                print("    OK: #38320 part 1a: added ToolCallLike type import")
            else:
                print("    FAIL: #38320 part 1a: cannot find extractToolResultId import", file=sys.stderr)
                sys.exit(1)
        else:
            print("    SKIP: #38320 part 1a: ToolCallLike already imported")
    else:
        print("    FAIL: #38320 part 1a: unexpected import layout", file=sys.stderr)
        sys.exit(1)

# 1b. Add toRepairableToolCall function after hasToolCallName
# Insert right after the hasToolCallName function

old_after_name = '''function hasToolCallName(block: ToolCallBlock): boolean {
  return hasNonEmptyStringField(block.name);
}

function makeMissingToolResult'''

new_after_name = '''function hasToolCallName(block: ToolCallBlock): boolean {
  return hasNonEmptyStringField(block.name);
}

function toRepairableToolCall(block: ToolCallBlock): ToolCallLike | null {
  if (!hasToolCallInput(block) || !hasToolCallId(block) || !hasToolCallName(block)) {
    return null;
  }

  const id =
    typeof block.id === "string" && block.id.trim().length > 0
      ? block.id.trim()
      : null;
  if (!id) {
    return null;
  }

  return {
    id,
    name:
      typeof block.name === "string" && block.name.trim().length > 0
        ? block.name.trim()
        : undefined,
  };
}

function makeMissingToolResult'''

if old_after_name in content:
    content = content.replace(old_after_name, new_after_name, 1)
    changed = True
    print("    OK: #38320 part 1b: added toRepairableToolCall function")
else:
    print("    FAIL: #38320 part 1b: could not find hasToolCallName + makeMissingToolResult boundary", file=sys.stderr)
    sys.exit(1)

# 1c. Add extractRepairableToolCallsFromAssistant export before sanitizeToolUseResultPairing
old_sanitize = 'export function sanitizeToolUseResultPairing(messages: AgentMessage[]): AgentMessage[] {'

new_extract_fn = '''export function extractRepairableToolCallsFromAssistant(
  message: Extract<AgentMessage, { role: "assistant" }>,
): ToolCallLike[] {
  if (!Array.isArray(message.content)) {
    return [];
  }

  const toolCalls: ToolCallLike[] = [];
  for (const block of message.content) {
    if (!isToolCallBlock(block)) {
      continue;
    }
    const next = toRepairableToolCall(block);
    if (next) {
      toolCalls.push(next);
    }
  }
  return toolCalls;
}

export function sanitizeToolUseResultPairing(messages: AgentMessage[]): AgentMessage[] {'''

if old_sanitize in content:
    content = content.replace(old_sanitize, new_extract_fn, 1)
    changed = True
    print("    OK: #38320 part 1c: added extractRepairableToolCallsFromAssistant")
else:
    print("    FAIL: #38320 part 1c: could not find sanitizeToolUseResultPairing marker", file=sys.stderr)
    sys.exit(1)

# 1d. In repairToolUseResultPairing: remove stopReason skip, use extractRepairableToolCallsFromAssistant
old_skip = '''    const assistant = msg as Extract<AgentMessage, { role: "assistant" }>;

    // Skip tool call extraction for aborted or errored assistant messages.
    // When stopReason is "error" or "aborted", the tool_use blocks may be incomplete
    // (e.g., partialJson: true) and should not have synthetic tool_results created.
    // Creating synthetic results for incomplete tool calls causes API 400 errors:
    // "unexpected tool_use_id found in tool_result blocks"
    // See: https://github.com/openclaw/openclaw/issues/4597
    const stopReason = (assistant as { stopReason?: string }).stopReason;
    if (stopReason === "error" || stopReason === "aborted") {
      out.push(msg);
      continue;
    }

    const toolCalls = extractToolCallsFromAssistant(assistant);'''

new_skip = '''    const assistant = msg as Extract<AgentMessage, { role: "assistant" }>;

    // Repair is based on structural completeness, not stopReason alone.
    // Interrupted assistant turns can still contain fully-formed persisted tool calls
    // that need synthetic tool results to keep the transcript valid, while partial
    // streamed fragments are ignored here because they fail the structural checks.
    const toolCalls = extractRepairableToolCallsFromAssistant(assistant);'''

if old_skip in content:
    content = content.replace(old_skip, new_skip, 1)
    changed = True
    print("    OK: #38320 part 1d: replaced stopReason skip with structural check")
else:
    # Maybe part of the comment is slightly different (e.g. from PR #14328 patch)
    # Try a looser match: look for the stopReason block + extractToolCallsFromAssistant
    import re
    pattern = (
        r'(    const assistant = msg as Extract<AgentMessage, \{ role: "assistant" \}>;)\s*\n'
        r'(?:\s*//[^\n]*\n)*'  # optional comment lines
        r'\s*const stopReason = \(assistant as \{ stopReason\?: string \}\)\.stopReason;\s*\n'
        r'\s*if \(stopReason === "error" \|\| stopReason === "aborted"\) \{[^}]*\}\s*\n'
        r'\s*const toolCalls = extractToolCallsFromAssistant\(assistant\);'
    )
    match = re.search(pattern, content)
    if match:
        content = content[:match.start()] + new_skip + content[match.end():]
        changed = True
        print("    OK: #38320 part 1d: replaced stopReason skip with structural check (regex)")
    else:
        print("    FAIL: #38320 part 1d: could not find stopReason skip block", file=sys.stderr)
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

# 2a. Update imports:
# - Add extractRepairableToolCallsFromAssistant from session-transcript-repair
# - Remove extractToolCallsFromAssistant from tool-call-id (keep extractToolResultId)

# Handle the session-transcript-repair import
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
else:
    # Maybe already has multi-line import
    if 'extractRepairableToolCallsFromAssistant' in content:
        print("    SKIP: #38320 part 2a: extractRepairableToolCallsFromAssistant already imported")
    else:
        print("    FAIL: #38320 part 2a: could not find session-transcript-repair import", file=sys.stderr)
        sys.exit(1)

# Handle the tool-call-id import — remove extractToolCallsFromAssistant
old_toolcall_import = 'import { extractToolCallsFromAssistant, extractToolResultId } from "./tool-call-id.js";'
new_toolcall_import = 'import { extractToolResultId } from "./tool-call-id.js";'

if old_toolcall_import in content:
    content = content.replace(old_toolcall_import, new_toolcall_import, 1)
    changed = True
    print("    OK: #38320 part 2a: removed extractToolCallsFromAssistant from tool-call-id import")
else:
    if 'extractToolCallsFromAssistant' not in content:
        print("    SKIP: #38320 part 2a: extractToolCallsFromAssistant already removed from tool-call-id")
    else:
        print("    FAIL: #38320 part 2a: unexpected tool-call-id import layout", file=sys.stderr)
        sys.exit(1)

# 2b. Replace extractToolCallsFromAssistant call with extractRepairableToolCallsFromAssistant
old_call = '''    const toolCalls =
      nextRole === "assistant"
        ? extractToolCallsFromAssistant(nextMessage as Extract<AgentMessage, { role: "assistant" }>)
        : [];'''

new_call = '''    const toolCalls =
      nextRole === "assistant"
        ? extractRepairableToolCallsFromAssistant(
            nextMessage as Extract<AgentMessage, { role: "assistant" }>,
          )
        : [];'''

if old_call in content:
    content = content.replace(old_call, new_call, 1)
    changed = True
    print("    OK: #38320 part 2b: replaced extractToolCallsFromAssistant call")
else:
    if 'extractRepairableToolCallsFromAssistant' in content and 'extractToolCallsFromAssistant' not in content:
        print("    SKIP: #38320 part 2b: already using extractRepairableToolCallsFromAssistant")
    else:
        # Try with stopReason guard pattern (from PR #14328 variant)
        import re
        pattern = (
            r'    const toolCalls =\s*\n'
            r'\s*nextRole === "assistant"[^?]*\?\s*extractToolCallsFromAssistant\('
            r'nextMessage as Extract<AgentMessage, \{ role: "assistant" \}>\)'
            r'\s*:\s*\[\];'
        )
        match = re.search(pattern, content)
        if match:
            content = content[:match.start()] + new_call + content[match.end():]
            changed = True
            print("    OK: #38320 part 2b: replaced extractToolCallsFromAssistant call (regex)")
        else:
            print("    FAIL: #38320 part 2b: could not find extractToolCallsFromAssistant call site", file=sys.stderr)
            sys.exit(1)

if changed:
    with open(path, 'w') as f:
        f.write(content)

print("    OK: #38320 part 2: session-tool-result-guard.ts done")
PYEOF

echo "    OK: #38320 repair structurally complete interrupted tool calls applied (2 files)"
