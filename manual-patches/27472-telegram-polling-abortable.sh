#!/usr/bin/env bash
# PR #27472 — fix(telegram): ensure polling initialization is abortable and retries
# v2026.3.8: polling logic moved from monitor.ts to polling-session.ts
# Two changes in polling-session.ts:
# 1. Pass abort signal to deleteWebhook in #ensureWebhookCleanup
# 2. Pre-initialize bot (bot.init) with abort signal before handing to runner
#    in #runPollingCycle, with retry on recoverable network errors
set +e

SRC="${1:?Usage: $0 <openclaw-source-dir>}"

# v2026.3.8+ uses polling-session.ts; older versions use monitor.ts
POLLING="$SRC/src/telegram/polling-session.ts"
MONITOR="$SRC/src/telegram/monitor.ts"

if [ -f "$POLLING" ]; then
  TARGET="$POLLING"
elif [ -f "$MONITOR" ]; then
  TARGET="$MONITOR"
else
  echo "SKIP: neither polling-session.ts nor monitor.ts found"
  exit 0
fi

# ── Idempotency check ──
if grep -q 'bot\.init' "$TARGET"; then
  echo "Already applied: 27472-telegram-polling-abortable"
  exit 0
fi

# ── Apply patches via single python script ──
python3 - "$TARGET" << 'PYEOF'
import sys, os

path = sys.argv[1]
basename = os.path.basename(path)
with open(path, 'r') as f:
    content = f.read()

changed = False

# ── 1. Pass abort signal to deleteWebhook ──
# polling-session.ts pattern (class method, uses this.opts)
old_webhook_ps = 'fn: () => bot.api.deleteWebhook({ drop_pending_updates: false }),'
# monitor.ts pattern (standalone function, uses opts)
old_webhook_mon = 'fn: () => bot.api.deleteWebhook({ drop_pending_updates: false }),'

if old_webhook_ps in content:
    # Detect which context we're in based on abort signal access
    if 'this.opts.abortSignal' in content:
        # polling-session.ts class context
        new_webhook = 'fn: () => bot.api.deleteWebhook({ drop_pending_updates: false }, this.opts.abortSignal as Parameters<(typeof bot)["init"]>[0]),'
    else:
        # monitor.ts standalone context
        new_webhook = 'fn: () => bot.api.deleteWebhook({ drop_pending_updates: false }, opts.abortSignal as Parameters<(typeof bot)["init"]>[0]),'
    content = content.replace(old_webhook_ps, new_webhook, 1)
    changed = True
    print(f"OK: deleteWebhook abort signal added in {basename}")
else:
    print(f"ERROR: Could not find deleteWebhook pattern in {basename}")
    sys.exit(1)

# ── 2. Add bot.init with abort signal before runner ──
# polling-session.ts: runner created in #runPollingCycle
marker_ps = '    const runner = run(bot, this.opts.runnerOptions);'
# monitor.ts: runner created inline
marker_mon = '      const runner = run(bot, runnerOptions);'

if marker_ps in content:
    # polling-session.ts class context
    init_block = '''    // Pre-initialize the bot with abort signal support before handing it
    // to the grammY runner. The runner calls bot.init() internally but
    // does not forward the abort signal, so a hanging getMe() would
    // block indefinitely. Initializing here ensures the runner skips
    // its own init() call (bot is already initialized) and allows the
    // abort signal to cancel a stuck getMe() request.
    const grammySignal = this.opts.abortSignal as Parameters<(typeof bot)["init"]>[0];
    try {
      await withTelegramApiErrorLogging({
        operation: "getMe",
        runtime: this.opts.runtime,
        fn: () => bot.init(grammySignal),
      });
    } catch (err) {
      const shouldRetry = await this.#waitBeforeRetryOnRecoverableSetupError(
        err,
        "Telegram bot init failed",
      );
      return shouldRetry ? "continue" : "exit";
    }

'''
    content = content.replace(marker_ps, init_block + marker_ps, 1)
    changed = True
    print(f"OK: bot.init block inserted before runner in {basename}")
elif marker_mon in content:
    # monitor.ts standalone context
    init_block = '''      // Pre-initialize the bot with abort signal support before handing it
      // to the grammY runner. The runner calls bot.init() internally but
      // does not forward the abort signal, so a hanging getMe() would
      // block indefinitely. Initializing here ensures the runner skips
      // its own init() call (bot is already initialized) and allows the
      // abort signal to cancel a stuck getMe() request.
      // Cast the native AbortSignal to the grammY-compatible type.
      const grammySignal = opts.abortSignal as Parameters<(typeof bot)["init"]>[0];
      try {
        await withTelegramApiErrorLogging({
          operation: "getMe",
          runtime: opts.runtime,
          fn: () => bot.init(grammySignal),
        });
      } catch (err) {
        const shouldRetry = await waitBeforeRetryOnRecoverableSetupError(
          err,
          "Telegram bot init failed",
        );
        if (!shouldRetry) {
          return "exit";
        }
        return "continue";
      }

'''
    content = content.replace(marker_mon, init_block + marker_mon, 1)
    changed = True
    print(f"OK: bot.init block inserted before runner in {basename}")
else:
    print(f"ERROR: Could not find runner creation marker in {basename}")
    sys.exit(1)

if changed:
    with open(path, 'w') as f:
        f.write(content)

print(f"DONE: 27472-telegram-polling-abortable applied to {basename}")
PYEOF

if [ $? -ne 0 ]; then
  echo "FAIL: 27472-telegram-polling-abortable"
  exit 1
fi

echo "DONE: 27472-telegram-polling-abortable applied"
