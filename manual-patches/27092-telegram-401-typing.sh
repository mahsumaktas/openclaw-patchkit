#!/usr/bin/env bash
# Issue #27092: fix(telegram): stop typing keepalive on 401/403 auth errors
# When Telegram returns 401 (Unauthorized) or 403 (Forbidden) on sendChatAction,
# the typing keepalive loop keeps firing indefinitely, hammering the API and
# potentially triggering permanent bot bans. This patch:
#   1. typing.ts — adds optional shouldAbortOnError callback; stops keepalive if true
#   2. bot-message-dispatch.ts — wires shouldAbortOnError to detect 401/403 from Grammy
# Compatible with both vanilla v2026.2.24 and #27021-patched typing.ts.
set -euo pipefail

SRC="${1:-.}/src"

# ── Idempotency check ──────────────────────────────────────────────────────
if grep -q 'shouldAbortOnError' "$SRC/channels/typing.ts" 2>/dev/null; then
  echo "    SKIP: #27092 already applied"
  exit 0
fi

# ── 1. typing.ts: add shouldAbortOnError support ──────────────────────────
python3 - "$SRC/channels/typing.ts" << 'PYEOF'
import sys
path = sys.argv[1]
with open(path, 'r') as f:
    src = f.read()
original = src

# 1a) Add shouldAbortOnError parameter to createTypingCallbacks.
#     Two variants: with #27021 applied (maxKeepaliveMs present) or vanilla.
old1_with_27021 = """\
  maxKeepaliveMs?: number;
}): TypingCallbacks {"""

new1_with_27021 = """\
  maxKeepaliveMs?: number;
  /**
   * Optional predicate called when start() throws. If it returns true,
   * the keepalive loop is immediately stopped to prevent further API calls.
   * Use this to detect fatal errors (e.g. 401/403 auth failures) that
   * should not be retried.
   */
  shouldAbortOnError?: (err: unknown) => boolean;
}): TypingCallbacks {"""

old1_vanilla = """\
  keepaliveIntervalMs?: number;
}): TypingCallbacks {"""

new1_vanilla = """\
  keepaliveIntervalMs?: number;
  /**
   * Optional predicate called when start() throws. If it returns true,
   * the keepalive loop is immediately stopped to prevent further API calls.
   * Use this to detect fatal errors (e.g. 401/403 auth failures) that
   * should not be retried.
   */
  shouldAbortOnError?: (err: unknown) => boolean;
}): TypingCallbacks {"""

if old1_with_27021 in src:
    src = src.replace(old1_with_27021, new1_with_27021, 1)
elif old1_vanilla in src:
    src = src.replace(old1_vanilla, new1_vanilla, 1)
else:
    print("    FAIL: #27092 marker 1 (param) not found in typing.ts")
    sys.exit(1)

# 1b) Modify fireStart to check shouldAbortOnError and stop keepalive.
old2 = """\
  const fireStart = async () => {
    try {
      await params.start();
    } catch (err) {
      params.onStartError(err);
    }
  };"""

new2 = """\
  const fireStart = async () => {
    try {
      await params.start();
    } catch (err) {
      if (params.shouldAbortOnError?.(err)) {
        keepaliveLoop.stop();
      }
      params.onStartError(err);
    }
  };"""

if old2 not in src:
    print("    FAIL: #27092 marker 2 (fireStart) not found in typing.ts")
    sys.exit(1)
src = src.replace(old2, new2, 1)

if src == original:
    print("    FAIL: #27092 no changes were made to typing.ts")
    sys.exit(1)

with open(path, 'w') as f:
    f.write(src)
print("    OK: #27092 typing.ts patched (shouldAbortOnError support)")
PYEOF

# ── 2. bot-message-dispatch.ts: wire shouldAbortOnError for 401/403 ──────
python3 - "$SRC/telegram/bot-message-dispatch.ts" << 'PYEOF'
import sys
path = sys.argv[1]
with open(path, 'r') as f:
    src = f.read()
original = src

old3 = """\
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

new3 = """\
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
    shouldAbortOnError: (err) => {
      // Stop keepalive on 401 Unauthorized / 403 Forbidden — the bot token
      // is revoked or Telegram flagged the bot. Continuing would cause a
      // death spiral of failed requests that accelerates a permanent ban.
      if (!err || typeof err !== "object") {
        return false;
      }
      const code =
        (err as { error_code?: number }).error_code ??
        (err as { errorCode?: number }).errorCode;
      return code === 401 || code === 403;
    },
  });"""

if old3 not in src:
    print("    FAIL: #27092 marker 3 (createTypingCallbacks call) not found in bot-message-dispatch.ts")
    sys.exit(1)
src = src.replace(old3, new3, 1)

if src == original:
    print("    FAIL: #27092 no changes were made to bot-message-dispatch.ts")
    sys.exit(1)

with open(path, 'w') as f:
    f.write(src)
print("    OK: #27092 bot-message-dispatch.ts patched (401/403 typing abort)")
PYEOF

echo "    OK: #27092 fully applied"
