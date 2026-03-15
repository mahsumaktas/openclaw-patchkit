#!/usr/bin/env bash
# PR #27142 — fix: drop thinking blocks for Anthropic to prevent session corruption
#
# Anthropic sends both `type: "thinking"` and `type: "redacted_thinking"` blocks
# in assistant responses.  The base dropThinkingBlocks() only checks for
# `type === "thinking"`, letting redacted_thinking blocks survive into session
# history.  These corrupt blocks cause Anthropic API 400 errors:
#   "thinking or redacted_thinking blocks ... cannot be modified"
#
# v2026.3.13 already enables dropThinkingBlocks for Anthropic providers via
# shouldDropThinkingBlocksForModel (dropThinkingBlockModelHints: ["claude"]),
# so the transcript-policy.ts change from the original PR is already upstream.
#
# NOTE: This script runs BEFORE #39919 (strip-thinking-nonlatest.sh) which also
# touches thinking.ts. #39919 detects the THINKING_BLOCK_TYPES we insert here
# and skips its own insertion. The two scripts are compatible in any order.
#
# This patch applies the remaining thinking.ts changes:
#   1. Add THINKING_BLOCK_TYPES constant (Set of ["thinking", "redacted_thinking"])
#   2. Update dropThinkingBlocks to use THINKING_BLOCK_TYPES.has() instead of
#      the single `=== "thinking"` check
#   3. Update JSDoc to document both block types
set -euo pipefail
SRC="${1:-.}/src"

THINKING_FILE="$SRC/agents/pi-embedded-runner/thinking.ts"

[ -f "$THINKING_FILE" ] || { echo "    FAIL: $THINKING_FILE not found"; exit 1; }

# ── Idempotency check ─────────────────────────────────────────────────────
if grep -q 'THINKING_BLOCK_TYPES' "$THINKING_FILE" 2>/dev/null; then
  echo "    SKIP: #27142 already applied (THINKING_BLOCK_TYPES found)"
  exit 0
fi

python3 - "$THINKING_FILE" << 'PYEOF'
import sys

path = sys.argv[1]
with open(path, 'r') as f:
    content = f.read()

changed = False

# ── Step 1: Add THINKING_BLOCK_TYPES constant ─────────────────────────────
# Insert after the closing brace of isAssistantMessageWithContent function,
# right before the dropThinkingBlocks JSDoc.
old_jsdoc = '/**\n * Strip all `type: "thinking"` content blocks from assistant messages.'
thinking_const = 'const THINKING_BLOCK_TYPES: ReadonlySet<string> = new Set(["thinking", "redacted_thinking"]);\n\n'

if old_jsdoc in content:
    content = content.replace(old_jsdoc, thinking_const + '/**\n * Strip all `type: "thinking"` and `type: "redacted_thinking"` content blocks\n * from assistant messages.', 1)
    changed = True
else:
    # Fallback: try without the JSDoc update (maybe JSDoc was already changed)
    alt_jsdoc = '/**\n * Strip all `type: "thinking"` and `type: "redacted_thinking"` content blocks'
    if alt_jsdoc in content:
        content = content.replace(alt_jsdoc, thinking_const + alt_jsdoc, 1)
        changed = True
    else:
        # Last resort: insert before "export function dropThinkingBlocks"
        marker = 'export function dropThinkingBlocks'
        if marker in content:
            content = content.replace(marker, thinking_const + marker, 1)
            changed = True
        else:
            print("    FAIL: #27142 cannot find insertion point for THINKING_BLOCK_TYPES", file=sys.stderr)
            sys.exit(1)

# ── Step 2: Update the block type check inside dropThinkingBlocks ──────────
# Original: block.type === "thinking" (single type)
# Patched:  THINKING_BLOCK_TYPES.has(block.type) (set lookup)
#
# The exact source shape varies slightly across versions, so we try multiple
# patterns from most specific to least specific.

# v2026.3.11-3.13 shape (single-line if):
old_check_v1 = 'if (block && typeof block === "object" && (block as { type?: unknown }).type === "thinking") {'
new_check_v1 = 'if (\n        block &&\n        typeof block === "object" &&\n        THINKING_BLOCK_TYPES.has((block as { type?: string }).type ?? "")\n      ) {'

if old_check_v1 in content:
    content = content.replace(old_check_v1, new_check_v1, 1)
    changed = True
else:
    # Try indented version (6 spaces)
    old_check_v2 = '      if (block && typeof block === "object" && (block as { type?: unknown }).type === "thinking") {'
    new_check_v2 = '      if (\n        block &&\n        typeof block === "object" &&\n        THINKING_BLOCK_TYPES.has((block as { type?: string }).type ?? "")\n      ) {'
    if old_check_v2 in content:
        content = content.replace(old_check_v2, new_check_v2, 1)
        changed = True
    else:
        # Try with .type === "thinking" as a broader match
        import re
        pattern = r'if\s*\(\s*block\s*&&\s*typeof\s+block\s*===\s*"object"\s*&&\s*\(block\s+as\s*\{\s*type\?\s*:\s*unknown\s*\}\s*\)\.type\s*===\s*"thinking"\s*\)\s*\{'
        replacement = 'if (\n        block &&\n        typeof block === "object" &&\n        THINKING_BLOCK_TYPES.has((block as { type?: string }).type ?? "")\n      ) {'
        new_content, n = re.subn(pattern, replacement, content, count=1)
        if n > 0:
            content = new_content
            changed = True
        else:
            print("    FAIL: #27142 cannot find thinking block type check to replace", file=sys.stderr)
            sys.exit(1)

if not changed:
    print("    FAIL: #27142 no changes were made", file=sys.stderr)
    sys.exit(1)

with open(path, 'w') as f:
    f.write(content)
print("    OK: #27142 thinking.ts patched — THINKING_BLOCK_TYPES + redacted_thinking support")
PYEOF

echo "    OK: #27142 applied — dropThinkingBlocks now handles redacted_thinking"
