#!/usr/bin/env bash
# PR #40413 — discord: persist hello-stall counter and add escalation across health-monitor restarts
#
# Changes:
# 1. channel-health-monitor.ts:
#    - Add STABLE_THRESHOLD_MS, ESCALATION_THRESHOLD, MAX_BACKOFF_EXPONENT, MAX_COOLDOWN_MS constants
#    - Add consecutiveRestarts + healthySince to RestartRecord
#    - Add onBeforeRestart + onChannelStable callbacks to ChannelHealthMonitorDeps
#    - Stability tracking: reset counter after 5min healthy
#    - Exponential backoff on cooldown
#    - Escalation callback after N consecutive restarts
#    - Record lastRestartAt on failure to prevent rapid retry
#
# NOTE: The Discord provider.lifecycle.ts changes (persistent state Map, forceCleanRestart)
# require files that don't exist in v2026.3.13 (extensions/discord/src/monitor/).
# This script patches only the channel-health-monitor.ts which IS present.
# The Discord-specific lifecycle hooks would need to be wired when the monitor/ dir is introduced.
#
# v1: Written for v2026.3.13
set -euo pipefail
SRC="${1:-.}/src"

# ── Idempotency ──
if grep -q 'ESCALATION_THRESHOLD' "$SRC/gateway/channel-health-monitor.ts" 2>/dev/null; then
  echo "    SKIP: #40413 already applied"
  exit 0
fi

FILE="$SRC/gateway/channel-health-monitor.ts"
[ -f "$FILE" ] || { echo "    FAIL: $FILE not found"; exit 1; }

python3 - "$FILE" << 'PYEOF'
import sys, re

path = sys.argv[1]
with open(path, 'r') as f:
    content = f.read()

changes = 0

# ─── 1) Add constants before RestartRecord type ───
old_restart_record = 'type RestartRecord = {\n  lastRestartAt: number;\n  restartsThisHour: { at: number }[];'
new_restart_record = '''/** How long a channel must stay healthy after a restart before we consider it stable. */
const STABLE_THRESHOLD_MS = 5 * 60_000;
/** After this many consecutive restarts without stability, escalate (e.g. fresh IDENTIFY). */
const ESCALATION_THRESHOLD = 3;
/** Max backoff multiplier exponent for exponential cooldown. */
const MAX_BACKOFF_EXPONENT = 3;
/** Hard cap on exponential cooldown (60 minutes). */
const MAX_COOLDOWN_MS = 60 * 60_000;

type RestartRecord = {
  lastRestartAt: number;
  restartsThisHour: { at: number }[];
  /** Number of health-monitor restarts without the channel becoming stable. */
  consecutiveRestarts: number;
  /** Timestamp of the first healthy check after a restart. */
  healthySince?: number;'''
if old_restart_record in content:
    content = content.replace(old_restart_record, new_restart_record, 1)
    changes += 1
else:
    print("    FAIL: #40413 RestartRecord type not found", file=sys.stderr)
    sys.exit(1)

# ─── 2) Add onBeforeRestart + onChannelStable to deps type ───
old_deps_abort = '  abortSignal?: AbortSignal;\n};'
new_deps_abort = '''  abortSignal?: AbortSignal;
  /**
   * Called before restarting a channel that has failed multiple consecutive
   * health-monitor restarts without becoming stable.
   */
  onBeforeRestart?: (params: {
    channelId: ChannelId;
    accountId: string;
    consecutiveRestarts: number;
  }) => void;
  /** Called when a previously-restarted channel has been healthy long enough
   *  to be considered stable. */
  onChannelStable?: (params: { channelId: ChannelId; accountId: string }) => void;
};'''
if old_deps_abort in content:
    content = content.replace(old_deps_abort, new_deps_abort, 1)
    changes += 1
else:
    print("    FAIL: #40413 abortSignal deps pattern not found", file=sys.stderr)
    sys.exit(1)

# ─── 3) Destructure onBeforeRestart + onChannelStable from deps ───
old_destructure = '    abortSignal,\n  } = deps;'
new_destructure = '''    abortSignal,
    onBeforeRestart,
    onChannelStable,
  } = deps;'''
if old_destructure in content:
    content = content.replace(old_destructure, new_destructure, 1)
    changes += 1
else:
    print("    FAIL: #40413 destructure pattern not found", file=sys.stderr)
    sys.exit(1)

# ─── 4) Add consecutiveRestarts to record initialization ───
old_init = '            lastRestartAt: 0,\n            restartsThisHour: [],'
new_init = '            lastRestartAt: 0,\n            restartsThisHour: [],\n            consecutiveRestarts: 0,'
if old_init in content:
    content = content.replace(old_init, new_init, 1)
    changes += 1
else:
    print("    FAIL: #40413 record init pattern not found", file=sys.stderr)
    sys.exit(1)

# ─── 5) Replace health.healthy continue + cooldown check with stability tracking + backoff ───
# Original pattern:
#   if (health.healthy) {
#     continue;
#   }
#   ... record ...
#   if (now - record.lastRestartAt <= cooldownMs) {
old_healthy = '''          if (health.healthy) {
            continue;
          }

          const key = rKey(channelId, accountId);
          const record = restartRecords.get(key) ?? {
            lastRestartAt: 0,
            restartsThisHour: [],
            consecutiveRestarts: 0,
          };

          if (now - record.lastRestartAt <= cooldownMs) {'''
new_healthy = '''          const key = rKey(channelId, accountId);
          const record = restartRecords.get(key) ?? {
            lastRestartAt: 0,
            restartsThisHour: [],
            consecutiveRestarts: 0,
          };

          // Stability check: if the channel is healthy and has been continuously
          // healthy for STABLE_THRESHOLD_MS, reset the consecutive counter.
          if (health.healthy) {
            if (record.consecutiveRestarts > 0 && !record.healthySince) {
              record.healthySince = now;
              restartRecords.set(key, record);
            }
            if (
              record.consecutiveRestarts > 0 &&
              record.healthySince &&
              now - record.healthySince >= STABLE_THRESHOLD_MS
            ) {
              log.info?.(
                `[${channelId}:${accountId}] health-monitor: channel stable after ${record.consecutiveRestarts} restart(s), resetting counter`,
              );
              record.consecutiveRestarts = 0;
              record.healthySince = undefined;
              restartRecords.set(key, record);
              onChannelStable?.({ channelId: channelId as ChannelId, accountId });
            }
            continue;
          }

          // Channel is unhealthy -- clear the healthy-window timestamp.
          if (record.healthySince !== undefined) {
            record.healthySince = undefined;
            restartRecords.set(key, record);
          }

          // Apply exponential backoff: base cooldown x 2^min(consecutiveRestarts, cap)
          const backoffExponent = Math.min(record.consecutiveRestarts, MAX_BACKOFF_EXPONENT);
          const effectiveCooldownMs = Math.min(cooldownMs * 2 ** backoffExponent, MAX_COOLDOWN_MS);

          if (now - record.lastRestartAt <= effectiveCooldownMs) {'''
if old_healthy in content:
    content = content.replace(old_healthy, new_healthy, 1)
    changes += 1
else:
    print("    FAIL: #40413 healthy/cooldown pattern not found", file=sys.stderr)
    sys.exit(1)

# ─── 6) Add consecutive tracking + escalation before the restart call ───
old_reason = '          const reason = resolveChannelRestartReason(status, health);\n\n          log.info?.(`[${channelId}:${accountId}] health-monitor: restarting (reason: ${reason})`);'
new_reason = '''          const reason = resolveChannelRestartReason(status, health);
          const nextConsecutive = record.consecutiveRestarts + 1;

          log.info?.(
            `[${channelId}:${accountId}] health-monitor: restarting (reason: ${reason}, consecutive: ${nextConsecutive})`,
          );

          // Optimistically increment consecutiveRestarts before the restart attempt.
          record.consecutiveRestarts = nextConsecutive;
          restartRecords.set(key, record);

          // Escalation: after N consecutive restarts without stability, notify
          // the caller so it can take channel-specific recovery action.
          if (nextConsecutive >= ESCALATION_THRESHOLD && onBeforeRestart) {
            onBeforeRestart({
              channelId: channelId as ChannelId,
              accountId,
              consecutiveRestarts: nextConsecutive,
            });
          }'''
if old_reason in content:
    content = content.replace(old_reason, new_reason, 1)
    changes += 1
else:
    print("    FAIL: #40413 restart reason log pattern not found", file=sys.stderr)
    sys.exit(1)

# ─── 7) Record lastRestartAt on failure ───
# Find the catch block after the restart try and add lastRestartAt recording
old_catch = '''            log.error?.(
              `[${channelId}:${accountId}] health-monitor: restart failed: ${String(err)}`,
            );'''
new_catch = '''            log.error?.(
              `[${channelId}:${accountId}] health-monitor: restart failed: ${String(err)}`,
            );
            // Record the attempt time even on failure so the exponential
            // cooldown is respected on the next check cycle.
            record.lastRestartAt = now;
            restartRecords.set(key, record);'''
if old_catch in content:
    content = content.replace(old_catch, new_catch, 1)
    changes += 1
else:
    print("    WARN: #40413 restart failed catch pattern not found — non-critical", file=sys.stderr)

with open(path, 'w') as f:
    f.write(content)
print(f"    OK: #40413 channel-health-monitor.ts ({changes} changes)")
PYEOF

echo "    OK: #40413 discord hello-stall persistence and escalation applied"
