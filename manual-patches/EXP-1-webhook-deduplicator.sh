#!/usr/bin/env bash
# EXP-1: Generic Webhook Deduplicator Middleware
# Extends the existing infra/dedupe.ts with channel-aware webhook deduplication.
# New file: src/channels/webhook-deduplicator.ts (~120 lines)
# Integrates into: telegram/webhook.ts (HTTP webhook handler)
#
# Note: Discord uses WS gateway (not webhooks), so it doesn't need HTTP dedupe.
# Telegram is the primary webhook-based channel on macOS gateway.
# The middleware is generic — any future webhook channel (LINE, Slack, Google Chat)
# can import and use it.
set -euo pipefail

SRC="${1:-.}/src"

# ── Idempotency check ──────────────────────────────────────────────────────
if [ -f "$SRC/channels/webhook-deduplicator.ts" ]; then
  echo "    SKIP: EXP-1 webhook-deduplicator.ts already exists"
  exit 0
fi

# Verify prerequisites
[ -f "$SRC/infra/dedupe.ts" ] || { echo "FAIL: infra/dedupe.ts not found"; exit 1; }
[ -f "$SRC/telegram/webhook.ts" ] || { echo "FAIL: telegram/webhook.ts not found"; exit 1; }

# ── 1. Create src/channels/webhook-deduplicator.ts ─────────────────────────
cat > "$SRC/channels/webhook-deduplicator.ts" << 'TSEOF'
/**
 * Generic Webhook Deduplicator — channel-agnostic middleware for detecting
 * and dropping replayed/duplicate webhook events.
 *
 * Uses the existing infra/dedupe.ts LRU cache under the hood.
 *
 * Usage:
 *   const dedup = createWebhookDeduplicator();
 *   // In your webhook handler:
 *   if (dedup.isDuplicate({ channel: "telegram", eventId: String(update_id) })) {
 *     return res.status(200).end(); // 200 so the platform doesn't retry
 *   }
 *
 * Each channel constructs its own eventId from the platform's native identifier:
 *   - Telegram: update_id
 *   - LINE: webhookEventId
 *   - Slack: x-slack-request-timestamp + event_id
 *   - Google Chat: space event name + eventTime
 */
import { createDedupeCache, type DedupeCache } from "../infra/dedupe.js";
import { createSubsystemLogger } from "../logging/subsystem.js";

// ── Constants ─────────────────────────────────────────────────────────────
const DEFAULT_TTL_MS = 10 * 60_000; // 10 minutes
const DEFAULT_MAX_ENTRIES = 8192;
const METRICS_LOG_INTERVAL_MS = 5 * 60_000; // log metrics every 5 min

// ── Types ─────────────────────────────────────────────────────────────────
export type WebhookDeduplicatorOptions = {
  ttlMs?: number;
  maxEntries?: number;
  /** If false, the deduplicator is a no-op passthrough. @default true */
  enabled?: boolean;
};

export type DeduplicateEvent = {
  channel: string;
  eventId: string;
  eventType?: string;
};

export type ChannelMetrics = {
  total: number;
  duplicates: number;
  cacheSize: number;
};

export type WebhookDeduplicator = {
  /** Returns true if this event was already seen (duplicate). */
  isDuplicate: (event: DeduplicateEvent) => boolean;
  /** Peek without marking — returns true if already in cache. */
  wasSeen: (event: DeduplicateEvent) => boolean;
  /** Get per-channel metrics snapshot. */
  getMetrics: (channel?: string) => Record<string, ChannelMetrics>;
  /** Reset all state. */
  clear: () => void;
  /** Stop background timers. */
  dispose: () => void;
};

// ── Implementation ────────────────────────────────────────────────────────

const log = createSubsystemLogger("webhook-dedupe");

function buildKey(event: DeduplicateEvent): string {
  const parts = [event.channel, event.eventId];
  if (event.eventType) {
    parts.push(event.eventType);
  }
  return parts.join(":");
}

export function createWebhookDeduplicator(
  options?: WebhookDeduplicatorOptions,
): WebhookDeduplicator {
  const enabled = options?.enabled !== false;
  const ttlMs = Math.max(1000, options?.ttlMs ?? DEFAULT_TTL_MS);
  const maxEntries = Math.max(64, options?.maxEntries ?? DEFAULT_MAX_ENTRIES);

  // Per-channel counters
  const counters = new Map<string, { total: number; duplicates: number }>();
  let cache: DedupeCache | null = null;

  if (enabled) {
    cache = createDedupeCache({ ttlMs, maxSize: maxEntries });
  }

  const ensureCounter = (channel: string) => {
    let c = counters.get(channel);
    if (!c) {
      c = { total: 0, duplicates: 0 };
      counters.set(channel, c);
    }
    return c;
  };

  // Periodic metrics logging
  let metricsTimer: ReturnType<typeof setInterval> | null = null;
  if (enabled) {
    metricsTimer = setInterval(() => {
      for (const [channel, c] of counters) {
        if (c.total === 0) continue;
        const dupeRate = c.total > 0 ? ((c.duplicates / c.total) * 100).toFixed(1) : "0.0";
        log.debug(`channel=${channel} total=${c.total} dupes=${c.duplicates} rate=${dupeRate}%`);
      }
    }, METRICS_LOG_INTERVAL_MS);
    // Unref so it doesn't keep the process alive
    if (metricsTimer && typeof metricsTimer === "object" && "unref" in metricsTimer) {
      (metricsTimer as NodeJS.Timeout).unref();
    }
  }

  return {
    isDuplicate(event: DeduplicateEvent): boolean {
      if (!cache) return false;
      const counter = ensureCounter(event.channel);
      counter.total++;
      const key = buildKey(event);
      // check() returns true if key was already in cache (= duplicate)
      const wasSeen = cache.check(key);
      if (wasSeen) {
        counter.duplicates++;
        log.debug(
          `duplicate webhook event: channel=${event.channel} eventId=${event.eventId}` +
            (event.eventType ? ` type=${event.eventType}` : ""),
        );
      }
      return wasSeen;
    },

    wasSeen(event: DeduplicateEvent): boolean {
      if (!cache) return false;
      return cache.peek(buildKey(event));
    },

    getMetrics(channel?: string): Record<string, ChannelMetrics> {
      const result: Record<string, ChannelMetrics> = {};
      const cacheSize = cache?.size() ?? 0;
      if (channel) {
        const c = counters.get(channel);
        result[channel] = {
          total: c?.total ?? 0,
          duplicates: c?.duplicates ?? 0,
          cacheSize,
        };
      } else {
        for (const [ch, c] of counters) {
          result[ch] = { total: c.total, duplicates: c.duplicates, cacheSize };
        }
      }
      return result;
    },

    clear() {
      cache?.clear();
      counters.clear();
    },

    dispose() {
      if (metricsTimer) {
        clearInterval(metricsTimer);
        metricsTimer = null;
      }
      cache?.clear();
    },
  };
}

// ── Singleton for gateway-wide use ────────────────────────────────────────
let globalDeduplicator: WebhookDeduplicator | null = null;

export function getWebhookDeduplicator(
  options?: WebhookDeduplicatorOptions,
): WebhookDeduplicator {
  if (!globalDeduplicator) {
    globalDeduplicator = createWebhookDeduplicator(options);
  }
  return globalDeduplicator;
}

export function resetWebhookDeduplicatorForTest(): void {
  if (globalDeduplicator) {
    globalDeduplicator.dispose();
    globalDeduplicator = null;
  }
}
TSEOF

echo "    OK: EXP-1 created src/channels/webhook-deduplicator.ts"

# ── 2. Integrate into telegram/webhook.ts ──────────────────────────────────
# The actual webhook.ts uses Grammy's "http" adapter: handler(req, res).
# There's no parsed body.value available before Grammy processes the request.
# Instead, we add a Grammy middleware via bot.use() BEFORE webhookCallback(),
# so duplicate updates are dropped inside Grammy's pipeline.
python3 - "$SRC/telegram/webhook.ts" << 'PYEOF'
import sys, re

path = sys.argv[1]
with open(path, 'r') as f:
    content = f.read()

changed = False

# 2a. Add import for getWebhookDeduplicator
if 'getWebhookDeduplicator' not in content:
    import_line = 'import { getWebhookDeduplicator } from "../channels/webhook-deduplicator.js";'
    # Try specific marker first
    for marker in [
        'import { createTelegramBot } from "./bot.js";',
        'import { createTelegramBot } from "./bot.js"',
    ]:
        if marker in content:
            content = content.replace(marker, marker + '\n' + import_line, 1)
            changed = True
            print("    OK: EXP-1 added import after bot.js")
            break
    else:
        # Fallback: insert after the last import line
        last_import = -1
        for m in re.finditer(r'^import .+;$', content, re.MULTILINE):
            last_import = m.end()
        if last_import > 0:
            content = content[:last_import] + '\n' + import_line + content[last_import:]
            changed = True
            print("    OK: EXP-1 added import (fallback)")
        else:
            print("    FAIL: EXP-1 no import statements found in webhook.ts")
            sys.exit(1)
else:
    print("    SKIP: EXP-1 import already present")

# 2b. Add bot.use() middleware BEFORE webhookCallback() call
# Pattern: const handler = webhookCallback(bot, "http", ...)
# Insert: bot.use() dedupe middleware between bot creation and handler creation
if 'EXP-1' not in content and 'isDuplicate' not in content:
    # Find the webhookCallback line (regex for flexible matching)
    wh_pattern = re.compile(
        r'^(\s*)(const\s+handler\s*=\s*webhookCallback\s*\(\s*bot\s*,)',
        re.MULTILINE,
    )
    m = wh_pattern.search(content)
    if m:
        indent = m.group(1)
        middleware_block = f"""{indent}// -- EXP-1: Webhook deduplication middleware --
{indent}// Runs inside Grammy's pipeline, after body parsing. Drops duplicate updates
{indent}// before they reach any bot handler, using update_id as the dedup key.
{indent}const webhookDedup = getWebhookDeduplicator();
{indent}bot.use(async (ctx, next) => {{
{indent}  if (webhookDedup.isDuplicate({{ channel: "telegram", eventId: String(ctx.update.update_id) }})) {{
{indent}    return; // silently drop duplicate
{indent}  }}
{indent}  await next();
{indent}}});
{indent}// -- end EXP-1 --

"""
        content = content[:m.start()] + middleware_block + content[m.start():]
        changed = True
        print("    OK: EXP-1 added Grammy middleware before webhookCallback")
    else:
        print("    FAIL: EXP-1 could not find webhookCallback() in webhook.ts")
        sys.exit(1)
else:
    print("    SKIP: EXP-1 middleware already present")

if changed:
    with open(path, 'w') as f:
        f.write(content)
    print("    OK: EXP-1 telegram/webhook.ts fully patched")
else:
    print("    SKIP: EXP-1 telegram/webhook.ts already up to date")

PYEOF

# ── 3. Verification ───────────────────────────────────────────────────────
echo ""
echo "  Verifying EXP-1..."
PASS=true

if [ ! -f "$SRC/channels/webhook-deduplicator.ts" ]; then
  echo "    FAIL: webhook-deduplicator.ts not created"
  PASS=false
fi

if ! grep -q 'createWebhookDeduplicator' "$SRC/channels/webhook-deduplicator.ts" 2>/dev/null; then
  echo "    FAIL: createWebhookDeduplicator not found in new file"
  PASS=false
fi

if ! grep -q 'getWebhookDeduplicator' "$SRC/telegram/webhook.ts" 2>/dev/null; then
  echo "    FAIL: deduplicator not integrated into telegram/webhook.ts"
  PASS=false
fi

if ! grep -q 'isDuplicate' "$SRC/telegram/webhook.ts" 2>/dev/null; then
  echo "    FAIL: isDuplicate check not found in telegram/webhook.ts"
  PASS=false
fi

if $PASS; then
  echo "    OK: EXP-1 fully verified"
else
  echo "    FAIL: EXP-1 verification failed"
  exit 1
fi
