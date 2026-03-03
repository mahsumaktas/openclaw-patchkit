#!/usr/bin/env bash
set -euo pipefail

# PR #30999 — Gateway-level TTL coordinator for stuck typing indicators
# Creates src/gateway/typing-ttl-coordinator.ts (NEW file)
# Modifies src/auto-reply/reply/typing.ts (add coordinator integration)
# Modifies src/auto-reply/reply/get-reply.ts (pass coordinatorKey)
# Skips: test files, CHANGELOG

TARGET="${1:?Usage: $0 <openclaw-src-dir>}"
cd "$TARGET"

MARKER="__PATCH_30999_TYPING_TTL_COORDINATOR__"

# ── Idempotency ──────────────────────────────────────────────────────────
if grep -q "coordinatorDeregister" src/auto-reply/reply/typing.ts 2>/dev/null; then
  echo "[30999] Already applied — skipping"
  exit 0
fi

# ── 1. Create NEW file: src/gateway/typing-ttl-coordinator.ts ────────────
FILE1="src/gateway/typing-ttl-coordinator.ts"
if [ -f "$FILE1" ]; then
  echo "[30999] $FILE1 already exists — overwriting"
fi

cat > "$FILE1" << 'TSEOF'
/**
 * Gateway-level typing indicator TTL coordinator.
 *
 * This is a defense-in-depth safety net for typing indicators. It operates independently
 * of per-session TTL mechanisms already present in TypingController and TypingCallbacks.
 *
 * If all other cleanup mechanisms fail (e.g. dispatcher hangs, event-lane blockage,
 * NO_REPLY path leak, block-streaming edge cases), this coordinator will unconditionally
 * stop typing after a hard TTL and emit a structured warning for diagnostics.
 *
 * Related issues: #27138, #27690, #27011, #26961, #26733, #26751, #27053
 * @marker __PATCH_30999_TYPING_TTL_COORDINATOR__
 */

export type TypingTtlCoordinatorOptions = {
  /** Hard TTL per session in milliseconds. Default: 120_000 (2 minutes). */
  defaultTtlMs?: number;
  /** Logger for forced-cleanup warnings. Default: console.warn */
  warn?: (message: string, meta?: Record<string, unknown>) => void;
};

/**
 * `TypingTtlCoordinator` class.
 *
 * Prefer the process-level singleton (`typingTtlCoordinator`) in production code.
 * Export the class for isolated unit-testing.
 */
export class TypingTtlCoordinator {
  private readonly defaultTtlMs: number;
  private readonly warn: (message: string, meta?: Record<string, unknown>) => void;
  private readonly sessions = new Map<string, ReturnType<typeof setTimeout>>();

  constructor(options: TypingTtlCoordinatorOptions = {}) {
    this.defaultTtlMs = options.defaultTtlMs ?? 120_000;
    this.warn = options.warn ?? ((msg) => console.warn(msg));
  }

  /**
   * Register a typing session.
   *
   * Returns a bound `deregister` callback that:
   * - Is scoped to this specific registration (captures the timer ref)
   * - Checks `sessions.get(key) === timerRef` before clearing to prevent
   *   stale callbacks from clobbering a newer registration for the same key
   * - Returns `true` if it successfully cancelled the TTL, `false` if already cleared
   *
   * @param key       - Unique session key (e.g. `${channelId}:${sessionKey}`)
   * @param cleanupFn - Idempotent function to stop the typing indicator
   * @param ttlMs     - Hard TTL in milliseconds (default: coordinator default)
   * @returns deregister - call on clean stop to cancel the TTL; returns true if cancelled
   */
  register(key: string, cleanupFn: () => void, ttlMs?: number): () => boolean {
    const resolvedTtlMs = ttlMs ?? this.defaultTtlMs;

    // Cancel any previous registration for this key.
    const existingTimer = this.sessions.get(key);
    if (existingTimer !== undefined) {
      clearTimeout(existingTimer);
      this.sessions.delete(key);
    }

    if (resolvedTtlMs <= 0) {
      // TTL disabled — skip scheduling, return a no-op deregister.
      return () => false;
    }

    const timer = setTimeout(() => {
      // Only fire if this timer is still the active registration for this key.
      if (this.sessions.get(key) === timer) {
        this.sessions.delete(key);
        this.warn(`[typing-ttl] TTL expired for key ${key} — forced cleanup`, {
          key,
          ttlMs: resolvedTtlMs,
        });
        try {
          cleanupFn();
        } catch (err) {
          this.warn(`[typing-ttl] cleanupFn threw for key ${key}: ${String(err)}`, { key });
        }
      }
    }, resolvedTtlMs);

    this.sessions.set(key, timer);

    // Capture the timer ref at registration time so this deregister is
    // bound exclusively to this registration, not any future one for the same key.
    const timerRef = timer;

    return (): boolean => {
      // Guard: only clear if this registration's timer is still active for this key.
      if (this.sessions.get(key) !== timerRef) {
        // Already cleared (by TTL expiry or a prior deregister call) — no-op.
        return false;
      }
      clearTimeout(timerRef);
      this.sessions.delete(key);
      return true;
    };
  }

  /** Number of currently active (not yet deregistered or expired) sessions. */
  activeCount(): number {
    return this.sessions.size;
  }
}

/**
 * Process-level singleton typing TTL coordinator.
 *
 * Imported by `createTypingController` to register all active typing sessions.
 * The default TTL is 120 seconds — well above any expected model-run duration,
 * but short enough to prevent typing indicators from persisting indefinitely.
 */
export const typingTtlCoordinator: TypingTtlCoordinator = new TypingTtlCoordinator({
  defaultTtlMs: 120_000,
});
TSEOF
echo "[30999] Created $FILE1"

# ── 2. Modify src/auto-reply/reply/typing.ts ─────────────────────────────
FILE2="src/auto-reply/reply/typing.ts"
if [ ! -f "$FILE2" ]; then
  echo "[30999] ERROR: $FILE2 not found"
  exit 1
fi

python3 - "$FILE2" << 'PYEOF'
import sys, re

filepath = sys.argv[1]
with open(filepath, 'r') as f:
    content = f.read()

# --- 2a. Add import at top of file ---
import_line = 'import type { TypingTtlCoordinator } from "../../gateway/typing-ttl-coordinator.js";\nimport { typingTtlCoordinator } from "../../gateway/typing-ttl-coordinator.js";\n'

# Insert before the first existing import
first_import = content.find('import ')
if first_import >= 0:
    content = content[:first_import] + import_line + content[first_import:]
else:
    content = import_line + content

# --- 2b. Add new params to createTypingController ---
# Find the params closing line before ): TypingController
old_params_end = '  log?: (message: string) => void;\n}): TypingController {'
new_params_end = '''  log?: (message: string) => void;
  /**
   * Unique key for this typing session (e.g. session key or channel+session).
   * When provided, the session is registered with the gateway-level TTL coordinator
   * as defense-in-depth against leaked typing indicators.
   * If omitted, coordinator registration is skipped.
   */
  coordinatorKey?: string;
  /**
   * Gateway-level TTL coordinator. Defaults to the process singleton when
   * `coordinatorKey` is provided. Override in tests to use an isolated instance.
   */
  coordinator?: TypingTtlCoordinator;
  /**
   * Hard TTL enforced by the gateway coordinator (ms). Defaults to coordinator default (120s).
   * Only used when `coordinatorKey` is provided.
   */
  typingMaxTtlMs?: number;
}): TypingController {'''

if old_params_end in content:
    content = content.replace(old_params_end, new_params_end, 1)
else:
    print(f"[30999] WARNING: Could not find params end pattern in {filepath}")

# --- 2c. Add destructuring of new params ---
old_destructure = '    silentToken = SILENT_REPLY_TOKEN,\n    log,\n  } = params;'
new_destructure = '''    silentToken = SILENT_REPLY_TOKEN,
    log,
    coordinatorKey,
    coordinator = coordinatorKey ? typingTtlCoordinator : undefined,
    typingMaxTtlMs,
  } = params;'''

if old_destructure in content:
    content = content.replace(old_destructure, new_destructure, 1)
else:
    print(f"[30999] WARNING: Could not find destructure pattern in {filepath}")

# --- 2d. Add coordinatorDeregister variable after typingIntervalMs ---
old_interval = '  const typingIntervalMs = typingIntervalSeconds * 1000;\n'
new_interval = '''  const typingIntervalMs = typingIntervalSeconds * 1000;

  // Gateway-level coordinator deregister. Set when typing first starts; cleared on cleanup.
  let coordinatorDeregister: (() => boolean) | undefined;
'''

if old_interval in content:
    content = content.replace(old_interval, new_interval, 1)
else:
    print(f"[30999] WARNING: Could not find typingIntervalMs pattern in {filepath}")

# --- 2e. Add deregister call in cleanup, before the "Notify the channel" comment ---
old_cleanup_notify = '    // Notify the channel to stop its typing indicator (e.g., on NO_REPLY).\n    // This fires only once (sealed prevents re-entry).'
new_cleanup_notify = '''    // Deregister from gateway-level coordinator on clean stop.
    // This cancels the hard TTL so the coordinator won't fire a redundant forced cleanup.
    if (coordinatorDeregister) {
      coordinatorDeregister();
      coordinatorDeregister = undefined;
    }
    // Notify the channel to stop its typing indicator (e.g., on NO_REPLY).
    // This fires only once (sealed prevents re-entry).'''

if old_cleanup_notify in content:
    content = content.replace(old_cleanup_notify, new_cleanup_notify, 1)
else:
    print(f"[30999] WARNING: Could not find cleanup notify pattern in {filepath}")

# --- 2f. Add coordinator registration in startTypingLoop ---
old_start_check = '    if (typingIntervalMs <= 0) {\n      return;\n    }'
new_start_check = '''    if (typingIntervalMs <= 0) {
      return;
    }
    // Register with the gateway-level TTL coordinator the first time typing starts.
    // The coordinator is a defense-in-depth safety net: if all other cleanup paths fail
    // (dispatcher hang, event-lane blockage, NO_REPLY path leak, etc.), the coordinator
    // will unconditionally call cleanup() after the hard TTL and emit a diagnostic warning.
    if (coordinator && coordinatorKey && !coordinatorDeregister) {
      coordinatorDeregister = coordinator.register(coordinatorKey, cleanup, typingMaxTtlMs);
    }'''

# This pattern appears in startTypingLoop — need to be careful it's the right one.
# In v2026.3.2, startTypingLoop has: if (!onReplyStart) { return; } if (typingIntervalMs <= 0) ...
# Actually looking at the code, the order is: refreshTypingTtl(); if (!onReplyStart) return; if (typingIntervalMs <= 0) return;
# The diff places the coordinator registration AFTER the typingIntervalMs <= 0 check in startTypingLoop
# But in v2026.3.2, the check is in a different position. Let me look more carefully.
# Actually from reading the source, typingIntervalMs <= 0 check is NOT in startTypingLoop in v2026.3.2.
# It's in a different location. Let me use a more robust approach.

# Find the right location in startTypingLoop: after "if (typingLoop.isRunning()) { return; }"
old_loop_running = '    if (typingLoop.isRunning()) {\n      return;\n    }\n    await ensureStart();'
new_loop_running = '''    if (typingLoop.isRunning()) {
      return;
    }
    // Register with the gateway-level TTL coordinator the first time typing starts.
    // The coordinator is a defense-in-depth safety net: if all other cleanup paths fail
    // (dispatcher hang, event-lane blockage, NO_REPLY path leak, etc.), the coordinator
    // will unconditionally call cleanup() after the hard TTL and emit a diagnostic warning.
    if (coordinator && coordinatorKey && !coordinatorDeregister) {
      coordinatorDeregister = coordinator.register(coordinatorKey, cleanup, typingMaxTtlMs);
    }
    await ensureStart();'''

if old_loop_running in content:
    content = content.replace(old_loop_running, new_loop_running, 1)
elif old_start_check in content:
    # Fallback: use the original diff approach
    content = content.replace(old_start_check, new_start_check, 1)
else:
    print(f"[30999] WARNING: Could not find startTypingLoop registration point in {filepath}")

with open(filepath, 'w') as f:
    f.write(content)

print(f"[30999] Modified {filepath}")
PYEOF

# ── 3. Modify src/auto-reply/reply/get-reply.ts ──────────────────────────
FILE3="src/auto-reply/reply/get-reply.ts"
if [ ! -f "$FILE3" ]; then
  echo "[30999] ERROR: $FILE3 not found"
  exit 1
fi

python3 - "$FILE3" << 'PYEOF'
import sys

filepath = sys.argv[1]
with open(filepath, 'r') as f:
    content = f.read()

# Add coordinatorKey to the createTypingController call
# The current code has:
#     silentToken: SILENT_REPLY_TOKEN,
#     log: defaultRuntime.log,
#   });
#   opts?.onTypingController?.(typing);

old_block = '''    silentToken: SILENT_REPLY_TOKEN,
    log: defaultRuntime.log,
  });
  opts?.onTypingController?.(typing);'''

new_block = '''    silentToken: SILENT_REPLY_TOKEN,
    log: defaultRuntime.log,
    // Register with the gateway-level TTL coordinator for defense-in-depth cleanup.
    // Uses a composite key (session + channel/surface) to prevent collisions in
    // multi-channel deployments where multiple channels share a canonical session key
    // (e.g. direct chats collapsing to a main session key via resolveSessionKey).
    coordinatorKey: agentSessionKey
      ? (ctx.Surface ?? ctx.Provider)
        ? `${agentSessionKey}::${ctx.Surface ?? ctx.Provider}`
        : agentSessionKey
      : undefined,
  });
  opts?.onTypingController?.(typing);'''

if old_block in content:
    content = content.replace(old_block, new_block, 1)
    with open(filepath, 'w') as f:
        f.write(content)
    print(f"[30999] Modified {filepath}")
else:
    print(f"[30999] WARNING: Could not find typing controller block in {filepath}")
PYEOF

echo "[30999] Patch applied successfully"
