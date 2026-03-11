#!/usr/bin/env bash
# PR #14328 — fix: strip incomplete tool_use blocks to prevent 400 loops
# 3 files: session-transcript-repair.ts, pi-embedded-helpers/errors.ts, (tests skipped)
#
# Changes:
# 1. hasToolCallInput: add partialJson check (blocks with partialJson=true are incomplete)
# 2. repairToolUseResultPairing: strip tool_use blocks from errored/aborted messages
#    (keep text content, drop entire message if only tool_use blocks)
# 3. errors.ts: add isCorruptedToolUsePairingError + formatAssistantErrorText handler
set -euo pipefail
SRC="${1:-.}/src"

REPAIR="$SRC/agents/session-transcript-repair.ts"
ERRORS="$SRC/agents/pi-embedded-helpers/errors.ts"

# ── Idempotency ──
if grep -q '"partialJson" in block' "$REPAIR" 2>/dev/null; then
  echo "    SKIP: #14328 already applied"
  exit 0
fi

# ── File checks ──
[ -f "$REPAIR" ] || { echo "    FAIL: #14328 $REPAIR not found"; exit 1; }
[ -f "$ERRORS" ] || { echo "    FAIL: #14328 $ERRORS not found"; exit 1; }

# ── 1. Add partialJson check to hasToolCallInput ──
python3 - "$REPAIR" << 'PYEOF'
import sys

path = sys.argv[1]
with open(path, 'r') as f:
    content = f.read()

# Part 1a: Add partialJson check to hasToolCallInput
old_input = '''function hasToolCallInput(block: RawToolCallBlock): boolean {
  const hasInput = "input" in block ? block.input !== undefined && block.input !== null : false;'''

new_input = '''function hasToolCallInput(block: RawToolCallBlock): boolean {
  // Blocks flagged as partial (interrupted mid-stream) are never complete.
  if ("partialJson" in block && (block as { partialJson?: unknown }).partialJson === true) {
    return false;
  }
  const hasInput = "input" in block ? block.input !== undefined && block.input !== null : false;'''

if old_input not in content:
    print("    FAIL: #14328 cannot find hasToolCallInput function", file=sys.stderr)
    sys.exit(1)

content = content.replace(old_input, new_input, 1)

# Part 1b: In repairToolUseResultPairing, replace the stopReason block that just pushes msg
# with one that strips tool_use blocks and keeps text content.
# If #38320 is already applied, the stopReason block is replaced with structural checks
# and this step is no longer needed (the partialJson check in hasToolCallInput is sufficient).
old_stop = '''    const stopReason = (assistant as { stopReason?: string }).stopReason;
    if (stopReason === "error" || stopReason === "aborted") {
      out.push(msg);
      continue;
    }'''

new_stop = '''    // When stopReason is "error" or "aborted", the tool_use blocks may be incomplete
    // (e.g., partialJson: true). Leaving them in the transcript causes permanent 400
    // errors from the Anthropic API ("unexpected tool_use_id found in tool_result blocks")
    // because the incomplete tool_use has no matching tool_result.
    // Strip tool_use blocks entirely; keep any text/thinking content.
    // See: https://github.com/openclaw/openclaw/issues/14322
    const stopReason = (assistant as { stopReason?: string }).stopReason;
    if (stopReason === "error" || stopReason === "aborted") {
      if (Array.isArray(assistant.content)) {
        const nonToolContent = assistant.content.filter((block) => !isRawToolCallBlock(block));
        if (nonToolContent.length > 0) {
          out.push({ ...msg, content: nonToolContent } as AgentMessage);
          changed = true;
        } else {
          // Entire message was tool_use blocks with no text — drop it.
          changed = true;
        }
      } else {
        out.push(msg);
      }
      continue;
    }'''

if old_stop in content:
    content = content.replace(old_stop, new_stop, 1)
    print("    OK: #14328 part 1b: stopReason block replaced with tool_use stripping")
elif 'extractRepairableToolCallsFromAssistant' in content:
    # #38320 already applied — the stopReason block is gone, structural checks handle it.
    # The partialJson check in hasToolCallInput (part 1a) is still the key fix here.
    print("    SKIP: #14328 part 1b: #38320 already replaced stopReason block with structural checks")
else:
    print("    FAIL: #14328 cannot find stopReason block in repairToolUseResultPairing", file=sys.stderr)
    sys.exit(1)

with open(path, 'w') as f:
    f.write(content)
print("    OK: #14328 session-transcript-repair.ts — partialJson check + tool_use stripping")
PYEOF

# ── 2. Add isCorruptedToolUsePairingError to errors.ts ──
python3 - "$ERRORS" << 'PYEOF'
import sys

path = sys.argv[1]
with open(path, 'r') as f:
    content = f.read()

# Part 2a: Add isCorruptedToolUsePairingError function after isMissingToolCallInputError
old_missing = '''export function isMissingToolCallInputError(raw: string): boolean {
  if (!raw) {
    return false;
  }
  return TOOL_CALL_INPUT_MISSING_RE.test(raw) || TOOL_CALL_INPUT_PATH_RE.test(raw);
}'''

new_missing = '''export function isMissingToolCallInputError(raw: string): boolean {
  if (!raw) {
    return false;
  }
  return TOOL_CALL_INPUT_MISSING_RE.test(raw) || TOOL_CALL_INPUT_PATH_RE.test(raw);
}

const CORRUPTED_TOOL_USE_PAIRING_RE = /unexpected tool_use_id found in tool_result blocks/i;

export function isCorruptedToolUsePairingError(raw: string): boolean {
  if (!raw) {
    return false;
  }
  return CORRUPTED_TOOL_USE_PAIRING_RE.test(raw);
}'''

if old_missing not in content:
    print("    FAIL: #14328 cannot find isMissingToolCallInputError", file=sys.stderr)
    sys.exit(1)

content = content.replace(old_missing, new_missing, 1)

# Part 2b: Add corrupted tool use pairing error handler in formatAssistantErrorText
old_fmt = '''  if (isMissingToolCallInputError(raw)) {
    return (
      "Session history looks corrupted (tool call input missing). " +
      "Use /new to start a fresh session. " +
      "If this keeps happening, reset the session or delete the corrupted session transcript."
    );
  }'''

new_fmt = '''  if (isMissingToolCallInputError(raw)) {
    return (
      "Session history looks corrupted (tool call input missing). " +
      "Use /new to start a fresh session. " +
      "If this keeps happening, reset the session or delete the corrupted session transcript."
    );
  }

  if (isCorruptedToolUsePairingError(raw)) {
    return (
      "Session history contains a corrupted tool call pair (likely from an interrupted response). " +
      "Use /new to start a fresh session."
    );
  }'''

if old_fmt not in content:
    print("    FAIL: #14328 cannot find isMissingToolCallInputError handler in formatAssistantErrorText", file=sys.stderr)
    sys.exit(1)

content = content.replace(old_fmt, new_fmt, 1)

with open(path, 'w') as f:
    f.write(content)
print("    OK: #14328 errors.ts — isCorruptedToolUsePairingError added")
PYEOF

echo "    OK: #14328 strip incomplete tool_use applied"
