#!/usr/bin/env bash
set -euo pipefail
cd "$1"

PATCH_ID="PR-31991"

# --- File 1: extensions/telegram/src/channel.ts ---
# Switch outbound chunker from chunkMarkdownText to markdownToTelegramHtmlChunks
# Add textMode: "html" to sendText
FILE1="extensions/telegram/src/channel.ts"

if [[ ! -f "$FILE1" ]]; then
  echo "$PATCH_ID: ERROR - $FILE1 not found"
  exit 1
fi

MARKER1="markdownToTelegramHtmlChunks"
if grep -q "$MARKER1" "$FILE1"; then
  echo "$PATCH_ID: $FILE1 already patched (idempotent skip)"
else
  python3 - "$FILE1" << 'PYEOF'
import sys

filepath = sys.argv[1]
with open(filepath, 'r') as f:
    content = f.read()

# 1. Replace chunker from text.chunkMarkdownText to telegram.markdownToTelegramHtmlChunks
old_chunker = "chunker: (text, limit) => getTelegramRuntime().channel.text.chunkMarkdownText(text, limit),"
new_chunker = "chunker: (text, limit) =>\n      getTelegramRuntime().channel.telegram.markdownToTelegramHtmlChunks(text, limit),"

if old_chunker not in content:
    print(f"ERROR: Could not find chunker line in {filepath}", file=sys.stderr)
    sys.exit(1)

content = content.replace(old_chunker, new_chunker, 1)

# 2. Add textMode: "html" to sendText call options
# Find the send call in sendText and add textMode: "html"
old_send = '''      const result = await send(to, text, {
        verbose: false,
        messageThreadId,'''

new_send = '''      const result = await send(to, text, {
        verbose: false,
        textMode: "html",
        messageThreadId,'''

if old_send not in content:
    print(f"ERROR: Could not find sendText send call in {filepath}", file=sys.stderr)
    sys.exit(1)

content = content.replace(old_send, new_send, 1)

with open(filepath, 'w') as f:
    f.write(content)

print(f"Patched {filepath}")
PYEOF
  echo "$PATCH_ID: Patched $FILE1"
fi

# --- File 2: src/plugins/runtime/runtime-channel.ts ---
# Add markdownToTelegramHtmlChunks to telegram runtime channel object
FILE2="src/plugins/runtime/runtime-channel.ts"

if [[ ! -f "$FILE2" ]]; then
  echo "$PATCH_ID: ERROR - $FILE2 not found"
  exit 1
fi

MARKER2="markdownToTelegramHtmlChunks"
if grep -q "$MARKER2" "$FILE2"; then
  echo "$PATCH_ID: $FILE2 already patched (idempotent skip)"
else
  python3 - "$FILE2" << 'PYEOF'
import sys

filepath = sys.argv[1]
with open(filepath, 'r') as f:
    content = f.read()

# 1. Add import for markdownToTelegramHtmlChunks
# Find an existing telegram import to add near
import_anchor = 'import { sendMessageTelegram, sendPollTelegram } from "../../telegram/send.js";'
if import_anchor not in content:
    # Try alternate import patterns
    import_anchor = 'import { probeTelegram } from "../../telegram/probe.js";'

if import_anchor not in content:
    print(f"ERROR: Could not find telegram import anchor in {filepath}", file=sys.stderr)
    sys.exit(1)

new_import_line = 'import { markdownToTelegramHtmlChunks } from "../../telegram/format.js";\n' + import_anchor
content = content.replace(import_anchor, new_import_line, 1)

# 2. Add markdownToTelegramHtmlChunks to telegram object
old_telegram = '''    telegram: {
      auditGroupMembership: auditTelegramGroupMembership,
      collectUnmentionedGroupIds: collectTelegramUnmentionedGroupIds,
      probeTelegram,'''

new_telegram = '''    telegram: {
      auditGroupMembership: auditTelegramGroupMembership,
      collectUnmentionedGroupIds: collectTelegramUnmentionedGroupIds,
      markdownToTelegramHtmlChunks,
      probeTelegram,'''

if old_telegram not in content:
    print(f"ERROR: Could not find telegram runtime object in {filepath}", file=sys.stderr)
    sys.exit(1)

content = content.replace(old_telegram, new_telegram, 1)

with open(filepath, 'w') as f:
    f.write(content)

print(f"Patched {filepath}")
PYEOF
  echo "$PATCH_ID: Patched $FILE2"
fi

# --- File 3: src/plugins/runtime/types-channel.ts ---
# Add markdownToTelegramHtmlChunks type to telegram section
FILE3="src/plugins/runtime/types-channel.ts"

if [[ ! -f "$FILE3" ]]; then
  echo "$PATCH_ID: ERROR - $FILE3 not found"
  exit 1
fi

MARKER3="markdownToTelegramHtmlChunks"
if grep -q "$MARKER3" "$FILE3"; then
  echo "$PATCH_ID: $FILE3 already patched (idempotent skip)"
else
  python3 - "$FILE3" << 'PYEOF'
import sys

filepath = sys.argv[1]
with open(filepath, 'r') as f:
    content = f.read()

# Add markdownToTelegramHtmlChunks type to telegram section
old_telegram_type = '''  telegram: {
    auditGroupMembership: typeof import("../../telegram/audit.js").auditTelegramGroupMembership;
    collectUnmentionedGroupIds: typeof import("../../telegram/audit.js").collectTelegramUnmentionedGroupIds;
    probeTelegram: typeof import("../../telegram/probe.js").probeTelegram;'''

new_telegram_type = '''  telegram: {
    auditGroupMembership: typeof import("../../telegram/audit.js").auditTelegramGroupMembership;
    collectUnmentionedGroupIds: typeof import("../../telegram/audit.js").collectTelegramUnmentionedGroupIds;
    markdownToTelegramHtmlChunks: typeof import("../../telegram/format.js").markdownToTelegramHtmlChunks;
    probeTelegram: typeof import("../../telegram/probe.js").probeTelegram;'''

if old_telegram_type not in content:
    print(f"ERROR: Could not find telegram type section in {filepath}", file=sys.stderr)
    sys.exit(1)

content = content.replace(old_telegram_type, new_telegram_type, 1)

with open(filepath, 'w') as f:
    f.write(content)

print(f"Patched {filepath}")
PYEOF
  echo "$PATCH_ID: Patched $FILE3"
fi

echo "$PATCH_ID: Done"
