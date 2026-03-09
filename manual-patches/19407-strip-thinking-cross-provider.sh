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
# v2026.3.2: openai export block is now multi-line and includes
# downgradeOpenAIFunctionCallReasoningPairs as well.  Match the actual source
# shape rather than the old single-line form.
python3 - "$HELPERS_FILE" << 'PYEOF'
import sys, re
path = sys.argv[1]
with open(path, 'r') as f:
    content = f.read()

# Already patched guard
if 'stripNonNativeThinkingBlocks' in content:
    print("    SKIP step-2: stripNonNativeThinkingBlocks already exported")
    sys.exit(0)

# v2026.3.2 shape: multi-line export block with downgradeOpenAIFunctionCallReasoningPairs
# We inject stripNonNativeThinkingBlocks as an additional export in that same block.
# Pattern matches the closing of the openai.js re-export block regardless of how many
# names are listed inside it.
pattern = r'(export \{[^}]*\bdowngradeOpenAIReasoningBlocks\b[^}]*\} from "\./pi-embedded-helpers/openai\.js";)'

def add_export(m):
    block = m.group(1)
    # Insert before the closing brace
    return block.replace(
        '} from "./pi-embedded-helpers/openai.js";',
        '  stripNonNativeThinkingBlocks,\n} from "./pi-embedded-helpers/openai.js";'
    )

new_content, n = re.subn(pattern, add_export, content, flags=re.DOTALL)
if n == 0:
    print("ERROR: could not find openai.js re-export block in pi-embedded-helpers.ts", file=sys.stderr)
    sys.exit(1)

with open(path, 'w') as f:
    f.write(new_content)
PYEOF

# 3) Add import and integrate into google.ts sanitizeSessionHistory pipeline
# v2026.3.2: import block now includes downgradeOpenAIFunctionCallReasoningPairs
# before downgradeOpenAIReasoningBlocks, and the sanitizedOpenAI assignment wraps
# both functions.  Return sites use !policy.applyGoogleTurnOrdering guard (no
# applyGoogleTurnOrderingFix call in the early-return path in older code).
python3 - "$GOOGLE_FILE" << 'PYEOF'
import sys, re
path = sys.argv[1]
with open(path, 'r') as f:
    content = f.read()

# Already patched guard
if 'stripNonNativeThinkingBlocks' in content:
    print("    SKIP step-3: google.ts already patched")
    sys.exit(0)

# ── Step 3a: inject stripNonNativeThinkingBlocks into the import block ────────
# Match the pi-embedded-helpers.js named-import block (multi-line).
# We add stripNonNativeThinkingBlocks after the last existing import name.
pattern_import = r'(import \{[^}]*\bdowngradeOpenAIReasoningBlocks\b[^}]*\} from "\.\./pi-embedded-helpers\.js";)'

def patch_import(m):
    block = m.group(1)
    return block.replace(
        '} from "../pi-embedded-helpers.js";',
        '  stripNonNativeThinkingBlocks,\n} from "../pi-embedded-helpers.js";'
    )

content, n = re.subn(pattern_import, patch_import, content, flags=re.DOTALL)
if n == 0:
    print("ERROR: could not find pi-embedded-helpers.js import block in google.ts", file=sys.stderr)
    sys.exit(1)

# ── Step 3b: inject the cross-provider strip step after sanitizedOpenAI ───────
# The sanitizedOpenAI assignment ends with `: sanitizedCompactionUsage;`
# followed by a blank line and `if (hasSnapshot && (!priorSnapshot || modelChanged)) {`
# This shape is stable across v2026.2.x and v2026.3.x.
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

if old_pipeline not in content:
    print("ERROR: could not find sanitizedOpenAI pipeline anchor in google.ts", file=sys.stderr)
    sys.exit(1)

content = content.replace(old_pipeline, new_pipeline, 1)

# ── Step 3c: replace sanitizedOpenAI with sanitizedThinkingCrossProvider ──────
# v2026.3.2 uses !policy.applyGoogleTurnOrdering guard for early return.
# Match both the early-return and the applyGoogleTurnOrderingFix call sites.
# We do a targeted replacement only AFTER the insertion point so we don't
# accidentally rename the variable declaration itself.
split_marker = 'const sanitizedThinkingCrossProvider = modelChanged'
before, after = content.split(split_marker, 1)

after = after.replace('return sanitizedOpenAI;', 'return sanitizedThinkingCrossProvider;')
after = after.replace('messages: sanitizedOpenAI,', 'messages: sanitizedThinkingCrossProvider,')

content = before + split_marker + after

with open(path, 'w') as f:
    f.write(content)
PYEOF

echo "    OK: #19407 fully applied"
