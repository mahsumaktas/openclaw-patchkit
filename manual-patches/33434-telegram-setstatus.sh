#!/usr/bin/env bash
# PR #33434 — fix(telegram): add setStatus integration for health monitoring
#
# The gateway's stale-event threshold can restart a healthy Telegram provider
# when no inbound events arrive for a while. This patch threads a setStatus
# callback through the Telegram stack so every incoming update resets
# lastEventAt / lastInboundAt, preventing false-positive restarts.
#
# Files patched (production only — tests excluded):
#   1. extensions/telegram/src/channel.ts  — pass setStatus from ctx into monitorTelegramProvider
#   2. src/telegram/bot.ts                 — add setStatus to TelegramBotOptions + health middleware
#   3. src/telegram/monitor.ts             — add setStatus to MonitorTelegramOpts + forward it
#   4. src/telegram/webhook.ts             — add setStatus to startTelegramWebhook opts + forward it
set -euo pipefail

WORKDIR="${1:-.}"

CHANNEL="$WORKDIR/extensions/telegram/src/channel.ts"
BOT="$WORKDIR/src/telegram/bot.ts"
MONITOR="$WORKDIR/src/telegram/monitor.ts"
WEBHOOK="$WORKDIR/src/telegram/webhook.ts"

# ── Idempotency check ──
if grep -q 'setStatus' "$BOT" 2>/dev/null; then
  echo "    SKIP: #33434 already applied"
  exit 0
fi

# ── File existence checks ──
[ -f "$CHANNEL" ] || { echo "    FAIL: $CHANNEL not found"; exit 1; }
[ -f "$BOT" ]     || { echo "    FAIL: $BOT not found"; exit 1; }
[ -f "$MONITOR" ] || { echo "    FAIL: $MONITOR not found"; exit 1; }
[ -f "$WEBHOOK" ] || { echo "    FAIL: $WEBHOOK not found"; exit 1; }

# ── 1. channel.ts: pass setStatus from ctx into monitorTelegramProvider call ──
python3 - "$CHANNEL" << 'PYEOF'
import sys

path = sys.argv[1]
with open(path, 'r') as f:
    content = f.read()

# The monitorTelegramProvider call ends with });  — we insert setStatus
# before the closing });  We anchor on webhookPort (or webhookCertPath if present).
# Find the last property before }); in the monitorTelegramProvider call.
# Try webhookCertPath first (v2026.3.8+), then webhookPort (older).
if 'webhookCertPath: account.config.webhookCertPath,' in content:
    anchor = 'webhookCertPath: account.config.webhookCertPath,'
elif 'webhookPort: account.config.webhookPort,' in content:
    anchor = 'webhookPort: account.config.webhookPort,'
else:
    print("    FAIL: #33434 channel.ts — cannot find anchor property in monitorTelegramProvider call", file=sys.stderr)
    sys.exit(1)

new_anchor = anchor + '\n        setStatus: (patch) => ctx.setStatus({ accountId: account.accountId, ...patch }),'

content = content.replace(anchor, new_anchor, 1)

with open(path, 'w') as f:
    f.write(content)
print("    OK: #33434 channel.ts patched (setStatus forwarded to monitorTelegramProvider)")
PYEOF

# ── 2. bot.ts: add setStatus to TelegramBotOptions type + health middleware ──
python3 - "$BOT" << 'PYEOF'
import sys

path = sys.argv[1]
with open(path, 'r') as f:
    content = f.read()

changed = False

# 2a) Add setStatus to TelegramBotOptions type
# Find the closing }; of the type — anchor on the last known field before };
# The PR adds it after the optional timing config block that ends with };
# We look for the end of TelegramBotOptions — the "};" right after the config block.
# Pattern: a line with just "  };" followed by another "};" which closes the type.
# More robust: find the textFragmentGapMs line and its parent closing braces.
type_anchor = '    textFragmentGapMs?: number;\n  };\n};'
if type_anchor in content:
    new_type = '    textFragmentGapMs?: number;\n  };\n  setStatus?: (patch: Record<string, unknown>) => void;\n};'
    content = content.replace(type_anchor, new_type, 1)
    changed = True
    print("    OK: #33434 bot.ts — setStatus added to TelegramBotOptions")
else:
    # Fallback: try to find just the type closing
    # Look for mediaGroupFlushMs pattern
    alt_anchor = '    mediaGroupFlushMs?: number;\n  };\n};'
    if alt_anchor in content:
        new_alt = '    mediaGroupFlushMs?: number;\n  };\n  setStatus?: (patch: Record<string, unknown>) => void;\n};'
        content = content.replace(alt_anchor, new_alt, 1)
        changed = True
        print("    OK: #33434 bot.ts — setStatus added to TelegramBotOptions (alt anchor)")
    else:
        print("    FAIL: #33434 bot.ts — cannot find TelegramBotOptions closing pattern", file=sys.stderr)
        sys.exit(1)

# 2b) Add health monitoring middleware before bot.use(sequentialize(...))
seq_anchor = '  bot.use(sequentialize(getTelegramSequentialKey));'
if seq_anchor not in content:
    print("    FAIL: #33434 bot.ts — cannot find sequentialize anchor", file=sys.stderr)
    sys.exit(1)

health_middleware = '''  // Track inbound events for health monitoring so the gateway doesn't
  // restart a healthy provider after the stale-event threshold.
  if (opts.setStatus) {
    const statusSink = opts.setStatus;
    bot.use(async (ctx, next) => {
      try {
        const now = Date.now();
        statusSink({ lastEventAt: now, lastInboundAt: now });
      } catch {
        // Status tracking must never break message processing.
      }
      await next();
    });
  }

'''

content = content.replace(seq_anchor, health_middleware + seq_anchor, 1)
changed = True

with open(path, 'w') as f:
    f.write(content)
print("    OK: #33434 bot.ts patched (setStatus type + health middleware)")
PYEOF

# ── 3. monitor.ts: add setStatus to MonitorTelegramOpts + forward in both modes ──
python3 - "$MONITOR" << 'PYEOF'
import sys

path = sys.argv[1]
with open(path, 'r') as f:
    content = f.read()

changed = False

# 3a) Add setStatus to MonitorTelegramOpts type
# Anchor on the last field before the closing };
# The PR adds it after webhookUrl or proxyFetch
for type_field in ['webhookUrl?: string;', 'proxyFetch?: typeof fetch;']:
    if type_field in content:
        new_field = type_field + '\n  setStatus?: (patch: Record<string, unknown>) => void;'
        # Only replace if setStatus not already in content
        content = content.replace(type_field, new_field, 1)
        changed = True
        print(f"    OK: #33434 monitor.ts — setStatus added to MonitorTelegramOpts (after {type_field})")
        break
else:
    print("    FAIL: #33434 monitor.ts — cannot find MonitorTelegramOpts type anchor", file=sys.stderr)
    sys.exit(1)

# 3b) Forward setStatus in webhook mode (startTelegramWebhook call)
# Anchor: publicUrl: opts.webhookUrl,
webhook_anchor = 'publicUrl: opts.webhookUrl,'
if webhook_anchor in content:
    new_webhook = 'publicUrl: opts.webhookUrl,\n        setStatus: opts.setStatus,'
    content = content.replace(webhook_anchor, new_webhook, 1)
    changed = True
    print("    OK: #33434 monitor.ts — setStatus forwarded to startTelegramWebhook")
else:
    print("    WARN: #33434 monitor.ts — publicUrl anchor not found for webhook mode")

# 3c) Forward setStatus in polling mode (createTelegramBot call)
# Anchor: onUpdateId: persistUpdateId,
# This is inside the createTelegramBot({ ... }) call in polling mode
polling_anchor = 'onUpdateId: persistUpdateId,'
if polling_anchor in content:
    # We need to check context — this should be inside the updateOffset block
    # The line after this in the object closes the updateOffset sub-object with },
    # and we want to add setStatus after the updateOffset block, before });
    # Actually looking at the diff more carefully:
    #   lastUpdateId,
    #   onUpdateId: persistUpdateId,
    # },
    # + setStatus: opts.setStatus,
    # });
    close_pattern = 'onUpdateId: persistUpdateId,\n          },'
    if close_pattern in content:
        new_close = 'onUpdateId: persistUpdateId,\n          },\n          setStatus: opts.setStatus,'
        content = content.replace(close_pattern, new_close, 1)
        changed = True
        print("    OK: #33434 monitor.ts — setStatus forwarded to createTelegramBot (polling)")
    else:
        # Try alternative indentation
        close_pattern2 = 'onUpdateId: persistUpdateId,\n            },'
        if close_pattern2 in content:
            new_close2 = 'onUpdateId: persistUpdateId,\n            },\n            setStatus: opts.setStatus,'
            content = content.replace(close_pattern2, new_close2, 1)
            changed = True
            print("    OK: #33434 monitor.ts — setStatus forwarded to createTelegramBot (polling, alt indent)")
        else:
            print("    WARN: #33434 monitor.ts — polling createTelegramBot closing pattern not found")
else:
    print("    WARN: #33434 monitor.ts — onUpdateId anchor not found for polling mode")

if changed:
    with open(path, 'w') as f:
        f.write(content)
    print("    OK: #33434 monitor.ts patched")
else:
    print("    FAIL: #33434 monitor.ts — no changes applied", file=sys.stderr)
    sys.exit(1)
PYEOF

# ── 4. webhook.ts: add setStatus to opts type + forward to createTelegramBot ──
python3 - "$WEBHOOK" << 'PYEOF'
import sys

path = sys.argv[1]
with open(path, 'r') as f:
    content = f.read()

changed = False

# 4a) Add setStatus to startTelegramWebhook opts type
# Anchor on the last known field: publicUrl?: string;
for opts_field in ['publicUrl?: string;', 'healthPath?: string;']:
    if opts_field in content:
        new_opts = opts_field + '\n  setStatus?: (patch: Record<string, unknown>) => void;'
        content = content.replace(opts_field, new_opts, 1)
        changed = True
        print(f"    OK: #33434 webhook.ts — setStatus added to startTelegramWebhook opts (after {opts_field})")
        break
else:
    print("    FAIL: #33434 webhook.ts — cannot find opts type anchor", file=sys.stderr)
    sys.exit(1)

# 4b) Forward setStatus to createTelegramBot call
# Anchor: accountId: opts.accountId,
bot_anchor = 'accountId: opts.accountId,'
if bot_anchor in content:
    new_bot = 'accountId: opts.accountId,\n    setStatus: opts.setStatus,'
    content = content.replace(bot_anchor, new_bot, 1)
    changed = True
    print("    OK: #33434 webhook.ts — setStatus forwarded to createTelegramBot")
else:
    print("    FAIL: #33434 webhook.ts — accountId anchor not found in createTelegramBot call", file=sys.stderr)
    sys.exit(1)

if changed:
    with open(path, 'w') as f:
        f.write(content)
    print("    OK: #33434 webhook.ts patched")
PYEOF

echo "    OK: #33434 telegram setStatus health monitoring applied"
