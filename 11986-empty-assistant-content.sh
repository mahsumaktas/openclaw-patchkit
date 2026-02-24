#!/usr/bin/env bash
# PR #11986 - fix: drop empty assistant content blocks from error/aborted API responses
# When an API request fails before producing any output, an assistant message
# with content: [] is left in the session transcript. The Anthropic Messages API
# rejects this, causing a permanent HTTP 400 loop. This patch drops such messages
# during read-time repair (repairToolUseResultPairing).
set -euo pipefail
cd "$1"

FILE="src/agents/session-transcript-repair.ts"

python3 -c "
with open('$FILE', 'r') as f:
    content = f.read()

# Insert empty content check before the existing error/aborted tool_use stripping
old = '''    const stopReason = (assistant as { stopReason?: string }).stopReason;
    if (stopReason === \"error\" || stopReason === \"aborted\") {
      if (Array.isArray(assistant.content)) {'''

new = '''    const stopReason = (assistant as { stopReason?: string }).stopReason;
    if (stopReason === \"error\" || stopReason === \"aborted\") {
      // Drop assistant messages with empty content arrays entirely.
      // These are left behind when an API request fails before producing any output.
      // Keeping them poisons the session: the Anthropic Messages API rejects
      // assistant messages with empty content, causing every subsequent request
      // to fail with HTTP 400 in a permanent loop.
      // See: https://github.com/openclaw/openclaw/issues/11963
      if (Array.isArray(assistant.content) && assistant.content.length === 0) {
        changed = true;
        continue;
      }
      if (Array.isArray(assistant.content)) {'''

if old in content:
    content = content.replace(old, new, 1)
    with open('$FILE', 'w') as f:
        f.write(content)
    print('Applied PR #11986 - drop empty assistant content blocks')
else:
    print('SKIP: pattern not found or already applied')
"
