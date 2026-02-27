#!/usr/bin/env bash
# PR #26555 — fix(security): ignore Discord embed preview text in agent input
# Removes embed text injection from resolveDiscordMessageText,
# resolveDiscordSnapshotMessageText, and resolveDiscordThreadStarter.
# Embed metadata (titles/descriptions) can come from remote URLs and must
# stay untrusted unless explicitly requested via web tools.
set -euo pipefail
SRC="${1:-.}/src"

MSG_FILE="$SRC/discord/monitor/message-utils.ts"
THR_FILE="$SRC/discord/monitor/threading.ts"

# Idempotency check
if grep -q 'Security hardening: never ingest embed preview' "$MSG_FILE" 2>/dev/null; then
  echo "    SKIP: #26555 already applied"
  exit 0
fi

# 1) message-utils.ts: Remove embed text from resolveDiscordMessageText
python3 - "$MSG_FILE" << 'PYEOF'
import sys
path = sys.argv[1]
with open(path, 'r') as f:
    content = f.read()

# Remove embedText variable and its use in resolveDiscordMessageText
old = '''  const embedText = resolveDiscordEmbedText(
    (message.embeds?.[0] as { title?: string | null; description?: string | null } | undefined) ??
      null,
  );
  const baseText =
    message.content?.trim() ||
    buildDiscordMediaPlaceholder({
      attachments: message.attachments ?? undefined,
      stickers: resolveDiscordMessageStickers(message),
    }) ||
    embedText ||
    options?.fallbackText?.trim() ||
    "";'''

new = '''  const baseText =
    message.content?.trim() ||
    buildDiscordMediaPlaceholder({
      attachments: message.attachments ?? undefined,
      stickers: resolveDiscordMessageStickers(message),
    }) ||
    // Security hardening: never ingest embed preview text into agent input.
    // Embed metadata (titles/descriptions) can come from remote URLs and must
    // stay untrusted unless explicitly requested via web tools.
    options?.fallbackText?.trim() ||
    "";'''

if old not in content:
    print("    FAIL: #26555 message-utils.ts resolveDiscordMessageText pattern not found", file=sys.stderr)
    sys.exit(1)

content = content.replace(old, new, 1)

# Remove embedText from resolveDiscordSnapshotMessageText
old2 = '''  const embedText = resolveDiscordEmbedText(snapshot.embeds?.[0]);
  return content || attachmentText || embedText || "";'''

new2 = '''  // Security hardening: forwarded snapshots must not pull embed preview text.
  // Only explicit user-authored content and media placeholders are included.
  return content || attachmentText || "";'''

if old2 not in content:
    print("    FAIL: #26555 message-utils.ts resolveDiscordSnapshotMessageText pattern not found", file=sys.stderr)
    sys.exit(1)

content = content.replace(old2, new2, 1)

with open(path, 'w') as f:
    f.write(content)
PYEOF

# 2) threading.ts: Remove resolveDiscordEmbedText import and usage
python3 - "$THR_FILE" << 'PYEOF'
import sys
path = sys.argv[1]
with open(path, 'r') as f:
    content = f.read()

# Remove resolveDiscordEmbedText from import
old_import = '''import {
  resolveDiscordChannelInfo,
  resolveDiscordEmbedText,
  resolveDiscordMessageChannelId,
} from "./message-utils.js";'''

new_import = '''import { resolveDiscordChannelInfo, resolveDiscordMessageChannelId } from "./message-utils.js";'''

if old_import not in content:
    print("    FAIL: #26555 threading.ts import pattern not found", file=sys.stderr)
    sys.exit(1)

content = content.replace(old_import, new_import, 1)

# Replace embedText usage in resolveDiscordThreadStarter
old_usage = '''    const content = starter.content?.trim() ?? "";
    const embedText = resolveDiscordEmbedText(starter.embeds?.[0]);
    const text = content || embedText;'''

new_usage = '''    // Security hardening: never treat embed preview metadata as trusted input.
    const text = starter.content?.trim() ?? "";'''

if old_usage not in content:
    print("    FAIL: #26555 threading.ts embedText usage pattern not found", file=sys.stderr)
    sys.exit(1)

content = content.replace(old_usage, new_usage, 1)

with open(path, 'w') as f:
    f.write(content)
PYEOF

echo "    OK: #26555 Discord embed preview text ignored in agent input (2 files)"
