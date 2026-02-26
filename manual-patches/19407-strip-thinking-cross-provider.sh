#!/usr/bin/env bash
set -euo pipefail
# PR #19407 — fix(agents): strip thinking blocks on cross-provider model switch
# Adds stripNonNativeThinkingBlocks function and integrates into sanitizeSessionHistory
SRC="${1:-.}/src"

OPENAI_FILE="$SRC/agents/pi-embedded-helpers/openai.ts"
HELPERS_FILE="$SRC/agents/pi-embedded-helpers.ts"
GOOGLE_FILE="$SRC/agents/pi-embedded-runner/google.ts"

if grep -q 'stripNonNativeThinkingBlocks' "$OPENAI_FILE" 2>/dev/null; then
  echo "    SKIP: #19407 already applied"
  exit 0
fi

# 1) Add stripNonNativeThinkingBlocks function to openai.ts
python3 - "$OPENAI_FILE" << 'PYEOF'
import sys
path = sys.argv[1]
with open(path, 'r') as f:
    content = f.read()

# Find the location after hasFollowingNonThinkingBlock function closing brace
# The function ends with "return false;\n}\n"
marker = "return false;\n}\n"
idx = content.find(marker)
if idx == -1:
    print("ERROR: Could not find insertion point in openai.ts", file=sys.stderr)
    sys.exit(1)

insert_after = idx + len(marker)

new_function = '''
/**
 * Strip all `type: "thinking"` blocks from assistant messages.
 *
 * When failing over from one provider to another (e.g. Anthropic -> OpenAI),
 * thinking blocks produced by the previous provider remain in session history
 * and can cause 400 errors because the target API didn't produce them and
 * cannot validate their signatures (or doesn't understand them at all).
 *
 * This should be called when the model has changed between providers so that
 * provider-specific thinking blocks don't leak across provider boundaries.
 * All `type: "thinking"` content blocks are removed; assistant messages that
 * become empty after stripping are dropped entirely.
 *
 * See: https://github.com/openclaw/openclaw/issues/19295
 */
export function stripNonNativeThinkingBlocks(messages: AgentMessage[]): AgentMessage[] {
  const out: AgentMessage[] = [];

  for (const msg of messages) {
    if (!msg || typeof msg !== "object") {
      out.push(msg);
      continue;
    }

    const role = (msg as { role?: unknown }).role;
    if (role !== "assistant") {
      out.push(msg);
      continue;
    }

    const assistantMsg = msg as Extract<AgentMessage, { role: "assistant" }>;
    if (!Array.isArray(assistantMsg.content)) {
      out.push(msg);
      continue;
    }

    let changed = false;
    type AssistantContentBlock = (typeof assistantMsg.content)[number];

    const nextContent: AssistantContentBlock[] = [];
    for (const block of assistantMsg.content) {
      if (!block || typeof block !== "object") {
        nextContent.push(block as AssistantContentBlock);
        continue;
      }
      if ((block as { type?: unknown }).type !== "thinking") {
        nextContent.push(block);
        continue;
      }
      // Drop the thinking block.
      changed = true;
    }

    if (!changed) {
      out.push(msg);
      continue;
    }

    if (nextContent.length === 0) {
      continue;
    }

    out.push({ ...assistantMsg, content: nextContent } as AgentMessage);
  }

  return out;
}
'''

content = content[:insert_after] + new_function + content[insert_after:]

with open(path, 'w') as f:
    f.write(content)
PYEOF

# 2) Add export to pi-embedded-helpers.ts
python3 - "$HELPERS_FILE" << 'PYEOF'
import sys
path = sys.argv[1]
with open(path, 'r') as f:
    content = f.read()

old = 'export { downgradeOpenAIReasoningBlocks } from "./pi-embedded-helpers/openai.js";'
new = '''export {
  downgradeOpenAIReasoningBlocks,
  stripNonNativeThinkingBlocks,
} from "./pi-embedded-helpers/openai.js";'''

content = content.replace(old, new)

with open(path, 'w') as f:
    f.write(content)
PYEOF

# 3) Add import and integrate into google.ts sanitizeSessionHistory pipeline
python3 - "$GOOGLE_FILE" << 'PYEOF'
import sys
path = sys.argv[1]
with open(path, 'r') as f:
    content = f.read()

# Add stripNonNativeThinkingBlocks to the import from pi-embedded-helpers.js
old_import = '  downgradeOpenAIReasoningBlocks,\n  isCompactionFailureError,'
new_import = '  downgradeOpenAIReasoningBlocks,\n  isCompactionFailureError,\n  stripNonNativeThinkingBlocks,'
content = content.replace(old_import, new_import)

# Add the thinking block stripping step after sanitizedOpenAI assignment
# Find the line with sanitizedOpenAI assignment end
old_pipeline = '    : sanitizedCompactionUsage;\n\n  if (hasSnapshot && (!priorSnapshot || modelChanged)) {'
new_pipeline = '''    : sanitizedCompactionUsage;

  // Strip all thinking blocks when the model/provider has changed.  Thinking
  // blocks are provider-specific (Anthropic uses unsigned blocks, OpenAI uses
  // rs_-signed blocks) and can cause 400 errors when sent to a provider that
  // didn't produce them.  See #19295.
  const sanitizedThinkingCrossProvider = modelChanged
    ? stripNonNativeThinkingBlocks(sanitizedOpenAI)
    : sanitizedOpenAI;

  if (hasSnapshot && (!priorSnapshot || modelChanged)) {'''
content = content.replace(old_pipeline, new_pipeline)

# Replace sanitizedOpenAI references after the new variable with sanitizedThinkingCrossProvider
# Find the return statements that use sanitizedOpenAI
content = content.replace(
    '    return sanitizedOpenAI;\n  }\n\n  return applyGoogleTurnOrderingFix({\n    messages: sanitizedOpenAI,',
    '    return sanitizedThinkingCrossProvider;\n  }\n\n  return applyGoogleTurnOrderingFix({\n    messages: sanitizedThinkingCrossProvider,'
)

with open(path, 'w') as f:
    f.write(content)
PYEOF

echo "    OK: #19407 fully applied"
