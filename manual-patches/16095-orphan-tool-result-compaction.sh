#!/usr/bin/env bash
# PR #16095 — fix: remove orphaned tool_result blocks during compaction
# After compaction removes assistant messages containing tool_use blocks,
# orphaned tool_result blocks can remain, causing Anthropic API 400 errors.
# This adds a post-compaction repair step that re-runs repairToolUseResultPairing.
set +e

SRC="${1:?Usage: $0 <openclaw-source-dir>}"

COMPACT="$SRC/src/agents/pi-embedded-runner/compact.ts"
if [ ! -f "$COMPACT" ]; then
  echo "SKIP: $COMPACT not found"
  exit 0
fi

# ── Idempotency check ──
if grep -q 'post-compact repair' "$COMPACT"; then
  echo "Already applied: 16095-orphan-tool-result-compaction"
  exit 0
fi

# ── 1. Add repairToolUseResultPairing to the import ──
# Change:
#   import { sanitizeToolUseResultPairing } from "../session-transcript-repair.js";
# To:
#   import {
#     repairToolUseResultPairing,
#     sanitizeToolUseResultPairing,
#   } from "../session-transcript-repair.js";

python3 -c "
import re, sys

path = sys.argv[1]
with open(path, 'r') as f:
    content = f.read()

old_import = 'import { sanitizeToolUseResultPairing } from \"../session-transcript-repair.js\";'
new_import = '''import {
  repairToolUseResultPairing,
  sanitizeToolUseResultPairing,
} from \"../session-transcript-repair.js\";'''

if old_import not in content:
    print('WARN: import pattern not found, trying multiline match')
    # Try matching already-multiline import
    old_pattern = r'import\s*\{\s*sanitizeToolUseResultPairing\s*\}\s*from\s*\"\.\.\/session-transcript-repair\.js\";'
    match = re.search(old_pattern, content)
    if match:
        content = content[:match.start()] + new_import + content[match.end():]
    else:
        print('ERROR: Could not find import to patch')
        sys.exit(1)
else:
    content = content.replace(old_import, new_import, 1)

with open(path, 'w') as f:
    f.write(content)
print('OK: import updated')
" "$COMPACT"

if [ $? -ne 0 ]; then
  echo "FAIL: Could not update import in compact.ts"
  exit 1
fi

# ── 2. Add post-compaction repair after session.compact() ──
# Insert after the line containing session.compact (which may be wrapped in compactWithSafetyTimeout)
# The insertion point is right after the compact call, before the "Estimate tokens" comment.

python3 -c "
import sys

path = sys.argv[1]
with open(path, 'r') as f:
    lines = f.readlines()

# Find the line with 'Estimate tokens after compaction'
insert_idx = None
for i, line in enumerate(lines):
    if '// Estimate tokens after compaction' in line:
        insert_idx = i
        break

if insert_idx is None:
    print('ERROR: Could not find insertion point (Estimate tokens comment)')
    sys.exit(1)

# Determine indentation from the comment line
indent = ''
for ch in lines[insert_idx]:
    if ch in (' ', '\t'):
        indent += ch
    else:
        break

repair_block = [
    indent + '// Re-run tool_use/tool_result pairing repair after compaction.\n',
    indent + '// Compaction can remove assistant messages containing tool_use blocks\n',
    indent + '// while leaving orphaned tool_result blocks behind, which causes\n',
    indent + '// Anthropic API 400 errors: \"unexpected tool_use_id found in tool_result blocks\".\n',
    indent + '// See: https://github.com/openclaw/openclaw/issues/15691\n',
    indent + 'if (transcriptPolicy.repairToolUseResultPairing) {\n',
    indent + '  const postCompactRepair = repairToolUseResultPairing(session.messages);\n',
    indent + '  if (postCompactRepair.droppedOrphanCount > 0 || postCompactRepair.moved) {\n',
    indent + '    session.agent.replaceMessages(postCompactRepair.messages);\n',
    indent + '    log.info(\n',
    indent + '      \`[compaction] post-compact repair: dropped \${postCompactRepair.droppedOrphanCount} orphaned tool_result(s), \` +\n',
    indent + '        \`\${postCompactRepair.droppedDuplicateCount} duplicate(s) \` +\n',
    indent + '        \`(sessionKey=\${params.sessionKey ?? params.sessionId})\`,\n',
    indent + '    );\n',
    indent + '  }\n',
    indent + '}\n',
]

lines[insert_idx:insert_idx] = repair_block

with open(path, 'w') as f:
    f.writelines(lines)
print('OK: post-compaction repair block inserted')
" "$COMPACT"

if [ $? -ne 0 ]; then
  echo "FAIL: Could not insert repair block in compact.ts"
  exit 1
fi

echo "DONE: 16095-orphan-tool-result-compaction applied"
