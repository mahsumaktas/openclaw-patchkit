#!/usr/bin/env bash
# PR #16995 — fix(telegram): record update ID before processing to prevent crash replay
# When a crash occurs during update processing, the update_id must already be
# persisted so the poller doesn't replay it on restart. Previously, update_id
# was only persisted after processing (in finally). Now we record it immediately
# before calling next(), so crash-replay is prevented.
set +e

SRC="${1:?Usage: $0 <openclaw-source-dir>}"

BOT="$SRC/src/telegram/bot.ts"
if [ ! -f "$BOT" ]; then
  echo "SKIP: $BOT not found"
  exit 0
fi

# ── Idempotency check ──
if grep -q 'Record update_id before processing to prevent crash replay' "$BOT"; then
  echo "Already applied: 16995-telegram-update-id-crash-replay"
  exit 0
fi

# The original PR swaps recordUpdateId(ctx) before await next() in the logging
# middleware. In v2026.2.24, recordUpdateId doesn't exist yet. The equivalent
# fix is to call opts.updateOffset?.onUpdateId(updateId) in the tracking
# middleware *before* await next(), so if a crash occurs during processing
# the update_id has already been persisted.
#
# We insert the early persist call right after pendingUpdateIds.add(updateId).

python3 -c "
import sys

path = sys.argv[1]
with open(path, 'r') as f:
    content = f.read()

old_block = '''  bot.use(async (ctx, next) => {
    const updateId = resolveTelegramUpdateId(ctx);
    if (typeof updateId === \"number\") {
      pendingUpdateIds.add(updateId);
    }
    try {
      await next();'''

new_block = '''  bot.use(async (ctx, next) => {
    const updateId = resolveTelegramUpdateId(ctx);
    if (typeof updateId === \"number\") {
      pendingUpdateIds.add(updateId);
      // Record update_id before processing to prevent crash replay (#16995).
      // If a crash occurs during next(), the update_id is already persisted
      // so the poller won't reprocess it on restart.
      if (highestCompletedUpdateId === null || updateId > highestCompletedUpdateId) {
        highestCompletedUpdateId = updateId;
      }
      maybePersistSafeWatermark();
    }
    try {
      await next();'''

if old_block not in content:
    print('ERROR: Could not find tracking middleware block in bot.ts')
    sys.exit(1)

content = content.replace(old_block, new_block, 1)

with open(path, 'w') as f:
    f.write(content)
print('OK: bot.ts patched — update_id recorded before processing')
" "$BOT"

if [ $? -ne 0 ]; then
  echo "FAIL: Could not patch bot.ts"
  exit 1
fi

echo "DONE: 16995-telegram-update-id-crash-replay applied"
