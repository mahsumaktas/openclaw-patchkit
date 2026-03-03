#!/usr/bin/env bash
set -euo pipefail
cd "$1"

# PR #14328 — Strip incomplete tool_use blocks from errored/aborted assistant messages
# Two files:
# 1. session-transcript-repair.ts:
#    a. hasToolCallInput: reject blocks with partialJson: true
#    b. repairToolUseResultPairing: strip tool_use from error/aborted messages (keep text)
# 2. pi-embedded-helpers/errors.ts:
#    a. Add isCorruptedToolUsePairingError() detection
#    b. Add friendly error message for corrupted tool_use/tool_result pair

FILE_REPAIR="src/agents/session-transcript-repair.ts"
FILE_ERRORS="src/agents/pi-embedded-helpers/errors.ts"

if [[ ! -f "$FILE_REPAIR" ]]; then
  echo "SKIP #14328: $FILE_REPAIR not found"
  exit 0
fi
if [[ ! -f "$FILE_ERRORS" ]]; then
  echo "SKIP #14328: $FILE_ERRORS not found"
  exit 0
fi

# Idempotency — check for ACTUAL code changes, not just comments containing keywords
if grep -q '"partialJson" in block' "$FILE_REPAIR" 2>/dev/null && grep -q 'isCorruptedToolUsePairingError' "$FILE_ERRORS" 2>/dev/null; then
  echo "SKIP #14328: already patched"
  exit 0
fi

# --- PART 1: session-transcript-repair.ts — hasToolCallInput rejects partialJson ---
python3 - "$FILE_REPAIR" << 'PYEOF'
import sys

filepath = sys.argv[1]
with open(filepath, 'r') as f:
    content = f.read()

changed = False

# 1a. Add partialJson check to hasToolCallInput
if '"partialJson" in block' not in content:
    old_input = '''function hasToolCallInput(block: RawToolCallBlock): boolean {
  const hasInput = "input" in block ? block.input !== undefined && block.input !== null : false;
  const hasArguments =
    "arguments" in block ? block.arguments !== undefined && block.arguments !== null : false;
  return hasInput || hasArguments;
}'''

    new_input = '''function hasToolCallInput(block: RawToolCallBlock): boolean {
  // Blocks flagged as partial (interrupted mid-stream) are never complete.
  if ("partialJson" in block && (block as { partialJson?: unknown }).partialJson === true) {
    return false;
  }
  const hasInput = "input" in block ? block.input !== undefined && block.input !== null : false;
  const hasArguments =
    "arguments" in block ? block.arguments !== undefined && block.arguments !== null : false;
  return hasInput || hasArguments;
}'''

    if old_input not in content:
        print(f"FAIL #14328 part 1a: could not find hasToolCallInput function in {filepath}")
        sys.exit(1)

    content = content.replace(old_input, new_input, 1)
    changed = True
    print(f"OK #14328 part 1a: added partialJson check to hasToolCallInput")
else:
    print(f"SKIP #14328 part 1a: partialJson code check already present")

# 1b. Replace error/aborted handling in repairToolUseResultPairing
# Strip tool_use blocks, keep text content
if 'nonToolContent' not in content:
    old_errored = '''    const stopReason = (assistant as { stopReason?: string }).stopReason;
    if (stopReason === "error" || stopReason === "aborted") {
      out.push(msg);
      continue;
    }'''

    new_errored = '''    // When stopReason is "error" or "aborted", the tool_use blocks may be incomplete
    // (e.g., partialJson: true). Leaving them in the transcript causes permanent 400
    // errors from the Anthropic API ("unexpected tool_use_id found in tool_result blocks")
    // because the incomplete tool_use has no matching tool_result.
    // Strip tool_use blocks entirely; keep any text/thinking content.
    // See: https://github.com/openclaw/openclaw/issues/4597
    // See: https://github.com/openclaw/openclaw/issues/14322
    const stopReason = (assistant as { stopReason?: string }).stopReason;
    if (stopReason === "error" || stopReason === "aborted") {
      if (Array.isArray(assistant.content)) {
        const nonToolContent = assistant.content.filter((block) => !isRawToolCallBlock(block));
        if (nonToolContent.length > 0) {
          out.push({ ...msg, content: nonToolContent } as AgentMessage);
          changed = true;
        } else {
          // Entire message was tool_use blocks with no text \u2014 drop it.
          changed = true;
        }
      } else {
        out.push(msg);
      }
      continue;
    }'''

    if old_errored not in content:
        # Try alternate pattern — maybe already partially modified or comments differ
        # Look for the core pattern
        import re
        pattern = r'(    const stopReason = \(assistant as \{ stopReason\?: string \}\)\.stopReason;\s*\n\s*if \(stopReason === "error" \|\| stopReason === "aborted"\) \{\s*\n\s*)out\.push\(msg\);\s*\n\s*continue;\s*\n\s*\}'
        match = re.search(pattern, content)
        if match:
            replacement = match.group(1) + '''if (Array.isArray(assistant.content)) {
        const nonToolContent = assistant.content.filter((block) => !isRawToolCallBlock(block));
        if (nonToolContent.length > 0) {
          out.push({ ...msg, content: nonToolContent } as AgentMessage);
          changed = true;
        } else {
          // Entire message was tool_use blocks with no text \u2014 drop it.
          changed = true;
        }
      } else {
        out.push(msg);
      }
      continue;
    }'''
            content = content[:match.start()] + replacement + content[match.end():]
            changed = True
            print(f"OK #14328 part 1b: patched error/aborted handling (regex)")
        else:
            print(f"FAIL #14328 part 1b: could not find error/aborted handling in {filepath}")
            sys.exit(1)
    else:
        content = content.replace(old_errored, new_errored, 1)
        changed = True
        print(f"OK #14328 part 1b: patched error/aborted handling")
else:
    print(f"SKIP #14328 part 1b: nonToolContent filter already present")

if changed:
    with open(filepath, 'w') as f:
        f.write(content)

print(f"OK #14328 part 1: session-transcript-repair.ts done")
PYEOF

# --- PART 2: pi-embedded-helpers/errors.ts ---
python3 - "$FILE_ERRORS" << 'PYEOF'
import sys

filepath = sys.argv[1]
with open(filepath, 'r') as f:
    content = f.read()

changed = False

# 2a. Add isCorruptedToolUsePairingError function before isBillingAssistantError
if 'isCorruptedToolUsePairingError' not in content:
    old_billing = 'export function isBillingAssistantError'

    new_fn = '''const CORRUPTED_TOOL_USE_PAIRING_RE = /unexpected tool_use_id found in tool_result blocks/i;

export function isCorruptedToolUsePairingError(raw: string): boolean {
  if (!raw) {
    return false;
  }
  return CORRUPTED_TOOL_USE_PAIRING_RE.test(raw);
}

export function isBillingAssistantError'''

    if old_billing not in content:
        print(f"FAIL #14328 part 2a: could not find isBillingAssistantError in {filepath}")
        sys.exit(1)

    content = content.replace(old_billing, new_fn, 1)
    changed = True
    print(f"OK #14328 part 2a: added isCorruptedToolUsePairingError function")
else:
    print(f"SKIP #14328 part 2a: isCorruptedToolUsePairingError already present")

# 2b. Add friendly error message in formatAssistantErrorText
# Insert before the invalidRequest check
if 'isCorruptedToolUsePairingError(raw)' not in content or 'corrupted tool call pair' not in content:
    old_invalid = '''  const invalidRequest = raw.match(/"type":"invalid_request_error".*?"message":"([^"]+)"/);
  if (invalidRequest?.[1]) {
    return `LLM request rejected: ${invalidRequest[1]}`;
  }'''

    new_invalid = '''  if (isCorruptedToolUsePairingError(raw)) {
    return (
      "Session history contains a corrupted tool call pair (likely from an interrupted response). " +
      "Use /new to start a fresh session."
    );
  }

  const invalidRequest = raw.match(/"type":"invalid_request_error".*?"message":"([^"]+)"/);
  if (invalidRequest?.[1]) {
    return `LLM request rejected: ${invalidRequest[1]}`;
  }'''

    if old_invalid not in content:
        print(f"FAIL #14328 part 2b: could not find invalidRequest block in {filepath}")
        sys.exit(1)

    content = content.replace(old_invalid, new_invalid, 1)
    changed = True
    print(f"OK #14328 part 2b: added corrupted tool_use error message")
else:
    print(f"SKIP #14328 part 2b: corrupted tool_use error message already present")

if changed:
    with open(filepath, 'w') as f:
        f.write(content)

print(f"OK #14328 part 2: errors.ts done")
PYEOF
