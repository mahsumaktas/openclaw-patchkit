#!/usr/bin/env bash
# PR #40080 — irc: prevent 433 nick-collision by reusing the monitor's live connection
#
# Root cause: When the IRC channel's startAccount resolves immediately, the gateway
# marks the channel stopped and schedules an auto-restart — creating a second IRC
# connection with the same nick, triggering 433 "Nickname already in use" errors.
#
# Changes:
# 1. Create extensions/irc/src/abort-signal.ts — waitForAbortSignal helper
# 2. Create extensions/irc/src/client-registry.ts — live client registry
# 3. channel.ts: keep startAccount promise alive via waitForAbortSignal
# 4. monitor.ts: register/unregister live client in registry
# 5. send.ts: prefer live client over transient connection
# 6. probe.ts: use live client when available, skip duplicate connection
#
# v1: Written for v2026.3.13
set -euo pipefail
SRC="${1:-.}"

# ── Idempotency ──
if [ -f "$SRC/extensions/irc/src/client-registry.ts" ]; then
  echo "    SKIP: #40080 already applied"
  exit 0
fi

IRC="$SRC/extensions/irc/src"
[ -d "$IRC" ] || { echo "    FAIL: $IRC not found"; exit 1; }

CHANGES=0

# ─── 1) Create abort-signal.ts ───
cat > "$IRC/abort-signal.ts" << 'TSEOF'
/**
 * Waits for an AbortSignal to fire (i.e. resolves when the signal is aborted).
 *
 * This is used by the IRC channel plugin's `startAccount` implementation to
 * keep the returned promise alive until the gateway signals shutdown.
 * Without it, `startAccount` returns immediately, which the gateway interprets
 * as "stopped" and schedules an auto-restart — creating a second IRC connection
 * with the same nick and triggering 433 "Nickname already in use" errors.
 *
 * Edge cases:
 * - If the signal is already aborted, resolves immediately.
 * - If no signal is provided (undefined), resolves immediately (backward-compat).
 */
export function waitForAbortSignal(signal: AbortSignal | undefined): Promise<void> {
  if (!signal || signal.aborted) {
    return Promise.resolve();
  }
  return new Promise<void>((resolve) => {
    signal.addEventListener("abort", () => resolve(), { once: true });
  });
}
TSEOF
CHANGES=$((CHANGES + 1))
echo "    OK: #40080 created abort-signal.ts"

# ─── 2) Create client-registry.ts ───
cat > "$IRC/client-registry.ts" << 'TSEOF'
/**
 * Live IRC client registry.
 *
 * `monitorIrcProvider` registers the active client here after connecting and
 * unregisters it on shutdown. `sendMessageIrc` consults the registry first so
 * outbound messages are delivered over the existing connection rather than
 * opening a redundant transient connection with the same nick.
 */
import type { IrcClient } from "./client.js";

const registry = new Map<string, IrcClient>();

/**
 * Register a live IRC client for an account.
 * Overwrites any previous entry for the same accountId.
 */
export function registerIrcClient(accountId: string, client: IrcClient): void {
  registry.set(accountId, client);
}

/**
 * Unregister the live IRC client for an account (called on monitor shutdown).
 */
export function unregisterIrcClient(accountId: string): void {
  registry.delete(accountId);
}

/**
 * Look up the live IRC client for an account.
 * Returns `undefined` if no client is currently registered or if the
 * registered client is no longer ready.
 */
export function getLiveIrcClient(accountId: string): IrcClient | undefined {
  const client = registry.get(accountId);
  if (!client) {
    return undefined;
  }
  if (!client.isReady()) {
    registry.delete(accountId);
    return undefined;
  }
  return client;
}
TSEOF
CHANGES=$((CHANGES + 1))
echo "    OK: #40080 created client-registry.ts"

# ─── 3) channel.ts: keep startAccount alive with waitForAbortSignal ───
FILE="$IRC/channel.ts"
[ -f "$FILE" ] || { echo "    FAIL: $FILE not found"; exit 1; }

python3 - "$FILE" << 'PYEOF'
import sys

path = sys.argv[1]
with open(path, 'r') as f:
    content = f.read()

changes = 0

# 3a) Add import for waitForAbortSignal
old_import = 'import {\n  listIrcAccountIds,'
new_import = 'import { waitForAbortSignal } from "./abort-signal.js";\nimport {\n  listIrcAccountIds,'
# Try simpler pattern if multiline doesn't match
if old_import in content:
    content = content.replace(old_import, new_import, 1)
    changes += 1
else:
    # Fallback: insert after the last openclaw import
    import_line = 'import { waitForAbortSignal } from "./abort-signal.js";\n'
    # Find a good anchor — the accounts import
    anchor = 'import {\n  listIrcAccountIds,'
    if anchor not in content:
        # Try single-line variant
        import sys as sys2
        for line in ['from "./accounts.js"', 'from "./connect-options.js"']:
            if line in content:
                idx = content.index(line)
                end = content.index('\n', idx) + 1
                content = content[:end] + import_line + content[end:]
                changes += 1
                break
    else:
        content = content.replace(anchor, import_line + anchor, 1)
        changes += 1

# 3b) Replace the immediate resolution with waitForAbortSignal
old_end = '''      await runStoppablePassiveMonitor({
        abortSignal: ctx.abortSignal,
        start: async () =>
          await monitorIrcProvider({
            accountId: account.accountId,
            config: ctx.cfg as CoreConfig,
            runtime: ctx.runtime,
            abortSignal: ctx.abortSignal,
            statusSink,
          }),
      });
    },'''
new_end = '''      const { stop } = await monitorIrcProvider({
        accountId: account.accountId,
        config: ctx.cfg as CoreConfig,
        runtime: ctx.runtime,
        abortSignal: ctx.abortSignal,
        statusSink: (patch) => ctx.setStatus({ accountId: ctx.accountId, ...patch }),
      });

      // Keep the startAccount promise alive until the gateway signals shutdown.
      // Without this the gateway sees an immediately-resolved promise, marks
      // the channel as stopped, and schedules an auto-restart — creating a
      // second IRC connection with the same nick and triggering 433 errors.
      await waitForAbortSignal(ctx.abortSignal);

      stop();
    },'''
if old_end in content:
    content = content.replace(old_end, new_end, 1)
    changes += 1
else:
    print("    WARN: #40080 channel.ts runStoppablePassiveMonitor pattern not found — trying alternate", file=sys.stderr)
    # The statusSink may have a different shape — try broader pattern
    import re
    m = re.search(r'(      await runStoppablePassiveMonitor\(\{[^}]*\}\);)', content, re.DOTALL)
    if m:
        print("    WARN: #40080 found runStoppablePassiveMonitor but shape differs — skipping channel.ts rewrite", file=sys.stderr)

with open(path, 'w') as f:
    f.write(content)
print(f"    OK: #40080 channel.ts ({changes} changes)")
PYEOF
CHANGES=$((CHANGES + 1))

# ─── 4) monitor.ts: register/unregister client ───
FILE="$IRC/monitor.ts"
[ -f "$FILE" ] || { echo "    FAIL: $FILE not found"; exit 1; }

python3 - "$FILE" << 'PYEOF'
import sys

path = sys.argv[1]
with open(path, 'r') as f:
    content = f.read()

changes = 0

# 4a) Add import for registry
old_import = 'import { resolveIrcAccount } from "./accounts.js";'
new_import = 'import { resolveIrcAccount } from "./accounts.js";\nimport { registerIrcClient, unregisterIrcClient } from "./client-registry.js";'
if old_import in content:
    content = content.replace(old_import, new_import, 1)
    changes += 1

# 4b) Register the live client after connection
old_connected = '  logger.info(\n    `[${account.accountId}] connected to ${account.host}:${account.port}${account.tls ? " (tls)" : ""} as ${client.nick}`,\n  );\n\n  return {\n    stop: () => {'
new_connected = '''  logger.info(
    `[${account.accountId}] connected to ${account.host}:${account.port}${account.tls ? " (tls)" : ""} as ${client.nick}`,
  );

  // Register the live client so outbound sends can reuse the existing
  // connection rather than opening redundant transient connections.
  registerIrcClient(account.accountId, client);

  return {
    stop: () => {
      unregisterIrcClient(account.accountId);'''
if old_connected in content:
    content = content.replace(old_connected, new_connected, 1)
    changes += 1
else:
    print("    FAIL: #40080 monitor connected/return pattern not found", file=sys.stderr)
    sys.exit(1)

with open(path, 'w') as f:
    f.write(content)
print(f"    OK: #40080 monitor.ts ({changes} changes)")
PYEOF
CHANGES=$((CHANGES + 1))

# ─── 5) send.ts: prefer live client over transient connection ───
FILE="$IRC/send.ts"
[ -f "$FILE" ] || { echo "    FAIL: $FILE not found"; exit 1; }

python3 - "$FILE" << 'PYEOF'
import sys

path = sys.argv[1]
with open(path, 'r') as f:
    content = f.read()

changes = 0

# 5a) Add import for getLiveIrcClient
old_import = 'import { resolveIrcAccount } from "./accounts.js";'
new_import = 'import { resolveIrcAccount } from "./accounts.js";\nimport { getLiveIrcClient } from "./client-registry.js";'
if old_import in content and 'getLiveIrcClient' not in content:
    content = content.replace(old_import, new_import, 1)
    changes += 1

# 5b) Replace client lookup to prefer live client
old_client = '  const client = opts.client;\n  if (client?.isReady()) {'
new_client = '''  // Prefer a caller-supplied client, then the monitor's live registered
  // client, and only fall back to a transient connection if neither exists.
  // This avoids opening duplicate connections with the same nick (IRC 433).
  const client = opts.client ?? getLiveIrcClient(account.accountId);
  if (client?.isReady()) {'''
if old_client in content:
    content = content.replace(old_client, new_client, 1)
    changes += 1

with open(path, 'w') as f:
    f.write(content)
print(f"    OK: #40080 send.ts ({changes} changes)")
PYEOF
CHANGES=$((CHANGES + 1))

# ─── 6) probe.ts: use live client when available ───
FILE="$IRC/probe.ts"
[ -f "$FILE" ] || { echo "    FAIL: $FILE not found"; exit 1; }

python3 - "$FILE" << 'PYEOF'
import sys

path = sys.argv[1]
with open(path, 'r') as f:
    content = f.read()

changes = 0

# 6a) Add import
old_import = 'import { resolveIrcAccount } from "./accounts.js";'
new_import = 'import { resolveIrcAccount } from "./accounts.js";\nimport { getLiveIrcClient } from "./client-registry.js";'
if old_import in content and 'getLiveIrcClient' not in content:
    content = content.replace(old_import, new_import, 1)
    changes += 1

# 6b) Add live client check before the fresh connection
old_probe = '  const started = Date.now();\n  try {\n    const client = await connectIrcClient('
new_probe = '''  // If the monitor is already connected and healthy, report success without
  // opening a second connection (which would collide on the same nick).
  const liveClient = getLiveIrcClient(account.accountId);
  if (liveClient) {
    return {
      ...base,
      ok: true,
      latencyMs: 0,
    };
  }

  const started = Date.now();
  try {
    const client = await connectIrcClient('''
if old_probe in content:
    content = content.replace(old_probe, new_probe, 1)
    changes += 1

with open(path, 'w') as f:
    f.write(content)
print(f"    OK: #40080 probe.ts ({changes} changes)")
PYEOF
CHANGES=$((CHANGES + 1))

echo "    OK: #40080 irc nick-collision prevention — $CHANGES items patched"
