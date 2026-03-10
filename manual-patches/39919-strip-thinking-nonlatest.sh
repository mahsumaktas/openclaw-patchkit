#!/usr/bin/env bash
# PR #39919 — fix: strip thinking/redacted_thinking blocks from non-latest
# assistant messages for Anthropic
#
# Anthropic requires thinking/redacted_thinking blocks in the latest assistant
# message to be byte-identical to the original API response. Compaction and
# session serialization can corrupt these blocks, causing API rejections.
# This patch strips them from all non-latest assistant messages (where they
# may be safely omitted) and also upgrades dropThinkingBlocks to handle
# redacted_thinking blocks via a shared isThinkingBlock helper.
#
# Changes:
# 1. thinking.ts: Add THINKING_BLOCK_TYPES, isThinkingBlock helper,
#    isAssistantMessageWithContent, stripThinkingFromNonLatestAssistant;
#    update dropThinkingBlocks to use isThinkingBlock
# 2. google.ts: Import stripThinkingFromNonLatestAssistant, add Anthropic
#    provider detection, insert strip step before dropThinkingBlocks
set -euo pipefail
SRC="${1:-.}/src"

THINKING_FILE="$SRC/agents/pi-embedded-runner/thinking.ts"
GOOGLE_FILE="$SRC/agents/pi-embedded-runner/google.ts"

# Idempotency check
if grep -q 'stripThinkingFromNonLatestAssistant' "$THINKING_FILE" 2>/dev/null; then
  echo "    SKIP: #39919 already applied"
  exit 0
fi

[ -f "$THINKING_FILE" ] || { echo "    FAIL: $THINKING_FILE not found"; exit 1; }
[ -f "$GOOGLE_FILE" ]   || { echo "    FAIL: $GOOGLE_FILE not found"; exit 1; }

# 1) thinking.ts: Add helpers + isThinkingBlock + stripThinkingFromNonLatestAssistant
#    + update dropThinkingBlocks to handle redacted_thinking via isThinkingBlock
python3 - "$THINKING_FILE" << 'PYEOF'
import sys

path = sys.argv[1]
with open(path, 'r') as f:
    content = f.read()

# ── Step 1a: Add AssistantMessage type, THINKING_BLOCK_TYPES, isThinkingBlock,
#             and isAssistantMessageWithContent after the AssistantContentBlock type ──
old_types = 'type AssistantContentBlock = Extract<AgentMessage, { role: "assistant" }>["content"][number];'

new_types = '''type AssistantContentBlock = Extract<AgentMessage, { role: "assistant" }>["content"][number];
type AssistantMessage = Extract<AgentMessage, { role: "assistant" }>;

/** Block types that Anthropic considers immutable once returned. */
const THINKING_BLOCK_TYPES: ReadonlySet<string> = new Set(["thinking", "redacted_thinking"]);

function isThinkingBlock(block: unknown): boolean {
  if (!block || typeof block !== "object") {
    return false;
  }
  const type = (block as { type?: unknown }).type;
  return typeof type === "string" && THINKING_BLOCK_TYPES.has(type);
}

export function isAssistantMessageWithContent(message: AgentMessage): message is AssistantMessage {
  return (
    !!message &&
    typeof message === "object" &&
    message.role === "assistant" &&
    Array.isArray(message.content)
  );
}'''

if old_types not in content:
    print("    FAIL: #39919 AssistantContentBlock type pattern not found in thinking.ts", file=sys.stderr)
    sys.exit(1)

content = content.replace(old_types, new_types, 1)

# ── Step 1b: Update dropThinkingBlocks docstring ──
old_doc = '''/**
 * Strip all `type: "thinking"` content blocks from assistant messages.'''

new_doc = '''/**
 * Strip all `type: "thinking"` and `type: "redacted_thinking"` content blocks
 * from assistant messages.'''

if old_doc in content:
    content = content.replace(old_doc, new_doc, 1)

# ── Step 1c: Update dropThinkingBlocks inline check to use isThinkingBlock ──
old_check = '      if (block && typeof block === "object" && (block as { type?: unknown }).type === "thinking") {'

new_check = '      if (isThinkingBlock(block)) {'

if old_check not in content:
    print("    FAIL: #39919 dropThinkingBlocks inline check pattern not found", file=sys.stderr)
    sys.exit(1)

content = content.replace(old_check, new_check, 1)

# ── Step 1d: Add stripThinkingFromNonLatestAssistant at end of file ──
new_function = '''

/**
 * Strip `thinking` and `redacted_thinking` blocks from all assistant messages
 * **except** the latest (last) assistant message in the array.
 *
 * Anthropic requires that thinking/redacted_thinking blocks in the latest
 * assistant message remain byte-identical to the original API response.
 * Blocks in non-latest assistant messages may be omitted entirely.
 *
 * This prevents compaction or session serialization from corrupting thinking
 * blocks that are later rejected by the Anthropic API.
 *
 * Returns the original array reference when nothing was changed.
 */
export function stripThinkingFromNonLatestAssistant(messages: AgentMessage[]): AgentMessage[] {
  // Find the index of the last assistant message with array content.
  let lastAssistantIndex = -1;
  for (let i = messages.length - 1; i >= 0; i--) {
    if (isAssistantMessageWithContent(messages[i])) {
      lastAssistantIndex = i;
      break;
    }
  }

  // Nothing to do if there is zero or one assistant message.
  if (lastAssistantIndex <= 0) {
    return messages;
  }

  let touched = false;
  const out: AgentMessage[] = [];

  for (let i = 0; i < messages.length; i++) {
    const msg = messages[i];

    // Skip non-assistant or the latest assistant — keep them as-is.
    if (i === lastAssistantIndex || !isAssistantMessageWithContent(msg)) {
      out.push(msg);
      continue;
    }

    const nextContent: AssistantContentBlock[] = [];
    let changed = false;
    for (const block of msg.content) {
      if (isThinkingBlock(block)) {
        touched = true;
        changed = true;
        continue;
      }
      nextContent.push(block);
    }

    if (!changed) {
      out.push(msg);
      continue;
    }

    const content =
      nextContent.length > 0 ? nextContent : [{ type: "text", text: "" } as AssistantContentBlock];
    out.push({ ...msg, content });
  }

  return touched ? out : messages;
}
'''

content = content.rstrip('\n') + '\n' + new_function

with open(path, 'w') as f:
    f.write(content)
print("    OK: #39919 thinking.ts patched (isThinkingBlock + stripThinkingFromNonLatestAssistant)")
PYEOF

# 2) google.ts: Import stripThinkingFromNonLatestAssistant + add Anthropic strip step
python3 - "$GOOGLE_FILE" << 'PYEOF'
import sys

path = sys.argv[1]
with open(path, 'r') as f:
    content = f.read()

# ── Step 2a: Add stripThinkingFromNonLatestAssistant to import from ./thinking.js ──
old_import = 'import { dropThinkingBlocks } from "./thinking.js";'
new_import = 'import { dropThinkingBlocks, stripThinkingFromNonLatestAssistant } from "./thinking.js";'

if old_import not in content:
    print("    FAIL: #39919 thinking.js import pattern not found in google.ts", file=sys.stderr)
    sys.exit(1)

content = content.replace(old_import, new_import, 1)

# ── Step 2b: Insert Anthropic provider detection + strip step before dropThinkingBlocks ──
# Current pipeline:
#   const droppedThinking = policy.dropThinkingBlocks
#     ? dropThinkingBlocks(sanitizedImages)
#     : sanitizedImages;
# After patch:
#   const isAnthropicProvider = ...
#   const strippedNonLatestThinking = isAnthropicProvider ? strip...(sanitizedImages) : sanitizedImages;
#   const droppedThinking = policy.dropThinkingBlocks
#     ? dropThinkingBlocks(strippedNonLatestThinking)
#     : strippedNonLatestThinking;

old_pipeline = '''  const droppedThinking = policy.dropThinkingBlocks
    ? dropThinkingBlocks(sanitizedImages)
    : sanitizedImages;'''

new_pipeline = '''  // For Anthropic models, strip thinking/redacted_thinking blocks from all
  // non-latest assistant messages. Anthropic requires these blocks to be
  // byte-identical to the original response in the latest assistant message,
  // but allows omitting them from older messages. Compaction and session
  // serialization can corrupt these blocks, causing API rejections.
  const isAnthropicProvider =
    params.modelApi === "anthropic-messages" ||
    params.modelApi === "bedrock-converse-stream" ||
    (params.provider ?? "").toLowerCase() === "anthropic" ||
    (params.provider ?? "").toLowerCase() === "amazon-bedrock";
  const strippedNonLatestThinking = isAnthropicProvider
    ? stripThinkingFromNonLatestAssistant(sanitizedImages)
    : sanitizedImages;
  const droppedThinking = policy.dropThinkingBlocks
    ? dropThinkingBlocks(strippedNonLatestThinking)
    : strippedNonLatestThinking;'''

if old_pipeline not in content:
    print("    FAIL: #39919 dropThinkingBlocks pipeline pattern not found in google.ts", file=sys.stderr)
    sys.exit(1)

content = content.replace(old_pipeline, new_pipeline, 1)

with open(path, 'w') as f:
    f.write(content)
print("    OK: #39919 google.ts patched (Anthropic provider detection + stripThinkingFromNonLatestAssistant)")
PYEOF

echo "    OK: #39919 strip thinking from non-latest assistant messages applied"
