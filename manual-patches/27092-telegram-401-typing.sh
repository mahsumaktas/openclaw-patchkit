#!/usr/bin/env bash
# Issue #27092: fix(telegram): stop typing keepalive immediately on first error
#
# Problem: When Telegram returns 401 (Unauthorized) or 403 (Forbidden) on
# sendChatAction, the typing keepalive loop retries (default maxConsecutiveFailures=2),
# which hammers the API with known-bad credentials.
#
# Fix: Set maxConsecutiveFailures: 1 in the Telegram createTypingCallbacks call.
# v2026.2.26's startGuard mechanism already handles failure counting and loop stop —
# we just need to lower the threshold from 2 to 1 for Telegram.
#
# Changes:
#   1. src/telegram/bot-message-dispatch.ts — add maxConsecutiveFailures: 1
set -euo pipefail

SRC="${1:-.}/src"
FILE="$SRC/telegram/bot-message-dispatch.ts"
[ -f "$FILE" ] || { echo "    FAIL: $FILE not found"; exit 1; }

# ── Idempotency check ──────────────────────────────────────────────────────
if grep -q 'maxConsecutiveFailures' "$FILE" 2>/dev/null; then
  echo "    SKIP: #27092 already applied"
  exit 0
fi

python3 - "$FILE" << 'PYEOF'
import sys

filepath = sys.argv[1]
with open(filepath, "r") as f:
    code = f.read()

old = """\
  const typingCallbacks = createTypingCallbacks({
    start: sendTyping,
    onStartError: (err) => {
      logTypingFailure({
        log: logVerbose,
        channel: "telegram",
        target: String(chatId),
        error: err,
      });
    },
  });"""

new = """\
  const typingCallbacks = createTypingCallbacks({
    start: sendTyping,
    onStartError: (err) => {
      logTypingFailure({
        log: logVerbose,
        channel: "telegram",
        target: String(chatId),
        error: err,
      });
    },
    // Stop typing immediately on first error (e.g. 401/403 auth failures)
    // to avoid hammering Telegram API with known-bad credentials (#27092)
    maxConsecutiveFailures: 1,
  });"""

if old not in code:
    print("    FAIL: #27092 createTypingCallbacks call not found in bot-message-dispatch.ts", file=sys.stderr)
    sys.exit(1)

code = code.replace(old, new, 1)

with open(filepath, "w") as f:
    f.write(code)
print("    OK: #27092 bot-message-dispatch.ts patched (maxConsecutiveFailures: 1)")

PYEOF

echo "    OK: #27092 fully applied"
