#!/usr/bin/env bash
# PR #27472 — fix(telegram): ensure polling initialization is abortable and retries
# Three changes:
# 1. Pass abort signal to deleteWebhook so it can be cancelled on shutdown
# 2. Pre-initialize bot (bot.init) with abort signal before handing to runner,
#    with retry on recoverable network errors
# 3. Retry bot creation on recoverable errors (already handled via continue in v2026.2.24)
set +e

SRC="${1:?Usage: $0 <openclaw-source-dir>}"

MONITOR="$SRC/src/telegram/monitor.ts"
if [ ! -f "$MONITOR" ]; then
  echo "SKIP: $MONITOR not found"
  exit 0
fi

# ── Idempotency check ──
if grep -q 'bot\.init' "$MONITOR"; then
  echo "Already applied: 27472-telegram-polling-abortable"
  exit 0
fi

# ── 1. Pass abort signal to deleteWebhook ──
python3 -c "
import sys

path = sys.argv[1]
with open(path, 'r') as f:
    content = f.read()

old_webhook = 'fn: () => bot.api.deleteWebhook({ drop_pending_updates: false }),'
new_webhook = 'fn: () => bot.api.deleteWebhook({ drop_pending_updates: false }, opts.abortSignal as Parameters<(typeof bot)[\"init\"]>[0]),'

if old_webhook not in content:
    print('ERROR: Could not find deleteWebhook pattern in monitor.ts')
    sys.exit(1)

content = content.replace(old_webhook, new_webhook, 1)

with open(path, 'w') as f:
    f.write(content)
print('OK: deleteWebhook abort signal added')
" "$MONITOR"

if [ $? -ne 0 ]; then
  echo "FAIL: Could not patch deleteWebhook"
  exit 1
fi

# ── 2. Add bot.init with abort signal and retry before runner ──
# Insert between webhookCleared block and runner creation

python3 -c "
import sys

path = sys.argv[1]
with open(path, 'r') as f:
    content = f.read()

# Find the insertion point: after webhook cleanup, before runner creation
marker = '      const runner = run(bot, runnerOptions);'

if marker not in content:
    print('ERROR: Could not find runner creation marker in monitor.ts')
    sys.exit(1)

init_block = '''      // Pre-initialize the bot with abort signal support before handing it
      // to the grammY runner. The runner calls bot.init() internally but
      // does not forward the abort signal, so a hanging getMe() would
      // block indefinitely. Initializing here ensures the runner skips
      // its own init() call (bot is already initialized) and allows the
      // abort signal to cancel a stuck getMe() request.
      // Cast the native AbortSignal to the grammY-compatible type.
      const grammySignal = opts.abortSignal as Parameters<(typeof bot)[\"init\"]>[0];
      try {
        await withTelegramApiErrorLogging({
          operation: \"getMe\",
          runtime: opts.runtime,
          fn: () => bot.init(grammySignal),
        });
      } catch (err) {
        const shouldRetry = await waitBeforeRetryOnRecoverableSetupError(
          err,
          \"Telegram bot init failed\",
        );
        if (!shouldRetry) {
          return \"exit\";
        }
        return \"continue\";
      }

'''

content = content.replace(marker, init_block + marker, 1)

with open(path, 'w') as f:
    f.write(content)
print('OK: bot.init block inserted before runner')
" "$MONITOR"

if [ $? -ne 0 ]; then
  echo "FAIL: Could not insert bot.init block"
  exit 1
fi

echo "DONE: 27472-telegram-polling-abortable applied"
