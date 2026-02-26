#!/usr/bin/env bash
# PR #24737: fix(telegram): record sent messages for reaction own mode filtering
# Adds a grammY API transformer that calls recordSentMessage() for all outgoing
# messages, so wasSentByBot() correctly identifies bot-sent messages when
# reactionNotifications is set to "own".
#
# Changes (source only, skipping CHANGELOG and tests):
#   1. src/telegram/bot.ts — add import for recordSentMessage
#   2. src/telegram/bot.ts — add API transformer after apiThrottler()
set -euo pipefail
cd "$1"

FILE="src/telegram/bot.ts"
[ -f "$FILE" ] || { echo "FAIL: $FILE not found"; exit 1; }

python3 << 'PYEOF'
import sys

filepath = "src/telegram/bot.ts"
with open(filepath, "r") as f:
    code = f.read()

changed = False

# --- Change 1: Add import for recordSentMessage ---
if "recordSentMessage" not in code:
    # Find the import of resolveTelegramFetch (last import before the export block)
    marker = 'import { resolveTelegramFetch } from "./fetch.js";'
    if marker not in code:
        print("FAIL: #24737 cannot find resolveTelegramFetch import marker", file=sys.stderr)
        sys.exit(1)
    code = code.replace(
        marker,
        marker + '\nimport { recordSentMessage } from "./sent-message-cache.js";',
        1
    )
    changed = True
    print("OK: #24737 added recordSentMessage import")
else:
    print("SKIP: #24737 recordSentMessage import already present")

# --- Change 2: Add API transformer after apiThrottler() ---
transformer_code = '''  // Track all outgoing messages so reaction "own" mode can identify bot-sent messages.
  // Without this, wasSentByBot() always returns false for messages sent via bot.api.sendMessage()
  // directly (e.g. delivery, native commands), causing "own" mode to silently drop all reactions.
  bot.api.config.use(async (prev, method, payload, signal) => {
    const result = await prev(method, payload, signal);
    if (result.ok) {
      const p = payload as Record<string, unknown> | undefined;
      const r = result.result as unknown as Record<string, unknown> | undefined;
      if (p && typeof p.chat_id !== "undefined" && r && typeof r.message_id === "number") {
        recordSentMessage(p.chat_id as number | string, r.message_id);
      }
    }
    return result;
  });'''

if 'Track all outgoing messages so reaction "own" mode' in code:
    print("SKIP: #24737 API transformer already present")
else:
    # Insert after bot.api.config.use(apiThrottler());
    throttler_line = "bot.api.config.use(apiThrottler());"
    if throttler_line not in code:
        print("FAIL: #24737 cannot find apiThrottler() call", file=sys.stderr)
        sys.exit(1)
    code = code.replace(
        throttler_line,
        throttler_line + "\n" + transformer_code,
        1
    )
    changed = True
    print("OK: #24737 added API transformer for sent message tracking")

if changed:
    with open(filepath, "w") as f:
        f.write(code)
    print("OK: #24737 bot.ts patched successfully")
else:
    print("SKIP: #24737 all changes already applied")

PYEOF
