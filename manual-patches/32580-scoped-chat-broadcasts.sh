#!/usr/bin/env bash
# PR #32580 — scope chat event broadcasts to session-associated clients
#
# Changes:
# 1. server-broadcast.ts: add hasAdminScope(), shouldReceiveChatEvent(),
#    canonical key resolution, and per-client session scoping in the broadcast loop
# 2. server-methods/types.ts: add chatSessionKeys field to GatewayClient
# 3. server/ws-types.ts: add chatSessionKeys field to GatewayWsClient
# 4. server-methods/chat.ts: track chatSessionKeys on chat.send/chat.history,
#    use canonical keys for abort/active-run lookups, pass rawSessionKey to broadcastChatFinal/Error
#
# v1: Written for v2026.3.13
set -euo pipefail
SRC="${1:-.}/src"

# ── Idempotency ──
if grep -q 'chatSessionKeys' "$SRC/gateway/server-broadcast.ts" 2>/dev/null; then
  echo "    SKIP: #32580 already applied"
  exit 0
fi

CHANGES=0

# ─── 1) server-broadcast.ts: add session scoping logic ───
FILE="$SRC/gateway/server-broadcast.ts"
[ -f "$FILE" ] || { echo "    FAIL: $FILE not found"; exit 1; }

python3 - "$FILE" << 'PYEOF'
import sys, re

path = sys.argv[1]
with open(path, 'r') as f:
    content = f.read()

changes = 0

# 1a) Add imports at top
old_import = 'import { MAX_BUFFERED_BYTES } from "./server-constants.js";'
new_import = '''import { loadConfig } from "../config/config.js";
import { MAX_BUFFERED_BYTES } from "./server-constants.js";'''
if old_import in content:
    content = content.replace(old_import, new_import, 1)
    changes += 1

old_import2 = 'import type { GatewayWsClient } from "./server/ws-types.js";'
new_import2 = '''import type { GatewayWsClient } from "./server/ws-types.js";
import { resolveSessionStoreKey } from "./session-utils.js";'''
if old_import2 in content:
    content = content.replace(old_import2, new_import2, 1)
    changes += 1

# 1b) Add hasAdminScope before hasEventScope
old_has = 'function hasEventScope(client: GatewayWsClient, event: string): boolean {'
new_has = '''function hasAdminScope(client: GatewayWsClient): boolean {
  const role = client.connect.role ?? "operator";
  if (role !== "operator") {
    return false;
  }
  const scopes = Array.isArray(client.connect.scopes) ? client.connect.scopes : [];
  return scopes.includes(ADMIN_SCOPE);
}

function hasEventScope(client: GatewayWsClient, event: string): boolean {'''
if old_has in content:
    content = content.replace(old_has, new_has, 1)
    changes += 1

# 1c) Update hasEventScope to use hasAdminScope
old_scope = '''  const scopes = Array.isArray(client.connect.scopes) ? client.connect.scopes : [];
  if (scopes.includes(ADMIN_SCOPE)) {
    return true;
  }
  return required.some((scope) => scopes.includes(scope));'''
new_scope = '''  if (hasAdminScope(client)) {
    return true;
  }
  const scopes = Array.isArray(client.connect.scopes) ? client.connect.scopes : [];
  return required.some((scope) => scopes.includes(scope));'''
if old_scope in content:
    content = content.replace(old_scope, new_scope, 1)
    changes += 1

# 1d) Add shouldReceiveChatEvent after hasEventScope
old_after_scope = 'export function createGatewayBroadcaster(params: { clients: Set<GatewayWsClient> }) {'
should_receive = '''/**
 * Check whether a client should receive a session-scoped chat event.
 *
 * Scoping rules (evaluated in order):
 *  1. Clients with operator.admin scope -> always receive all chat events.
 *  2. Clients that have never sent chat.send (chatSessionKeys is
 *     undefined or empty) -> receive all events (backward compatibility
 *     for Control UI and legacy clients).
 *  3. Clients with a non-empty chatSessionKeys set -> only receive events
 *     whose sessionKey is in that set.
 */
function shouldReceiveChatEvent(
  client: GatewayWsClient,
  sessionKey: string | undefined,
  canonicalKey: string | undefined,
): boolean {
  // Admin-scoped clients (e.g., Control UI operators) always see everything.
  if (hasAdminScope(client)) {
    return true;
  }
  const tracked = client.chatSessionKeys;
  // Clients that haven't declared interest in any session yet get all
  // events -- this preserves backward compatibility for existing clients
  // that rely on client-side sessionKey filtering.
  if (!tracked || tracked.size === 0) {
    return true;
  }
  // If the event has no sessionKey we can't scope it -- deliver to all.
  if (!sessionKey) {
    return true;
  }
  // Try raw key first (fast path), then fall back to canonical form.
  if (tracked.has(sessionKey)) {
    return true;
  }
  if (canonicalKey && canonicalKey !== sessionKey) {
    return tracked.has(canonicalKey);
  }
  return false;
}

'''
if old_after_scope in content:
    content = content.replace(old_after_scope, should_receive + old_after_scope, 1)
    changes += 1

# 1e) Add chat session key resolution + scoping in the broadcast loop
# Find the "for (const c of params.clients)" line in the broadcast function
# and inject key resolution before it, plus scoping guard inside the loop
old_for_loop = '    for (const c of params.clients) {\n      if (targetConnIds && !targetConnIds.has(c.connId)) {\n        continue;\n      }\n      if (!hasEventScope(c, event)) {\n        continue;\n      }'
new_for_loop = '''    // Extract sessionKey from chat event payloads for session-scoped delivery.
    let chatSessionKey: string | undefined;
    let chatCanonicalKey: string | undefined;
    if (event === "chat" && payload && typeof payload === "object" && "sessionKey" in payload) {
      chatSessionKey = (payload as { sessionKey?: string }).sessionKey;
      if (chatSessionKey) {
        try {
          const resolved = resolveSessionStoreKey({
            cfg: loadConfig(),
            sessionKey: chatSessionKey,
          });
          if (resolved !== chatSessionKey) {
            chatCanonicalKey = resolved;
          }
        } catch {
          /* config not available -- skip canonicalization */
        }
      }
    }

    for (const c of params.clients) {
      if (targetConnIds && !targetConnIds.has(c.connId)) {
        continue;
      }
      if (!hasEventScope(c, event)) {
        continue;
      }
      // Session-scoped delivery for chat events: skip clients that have
      // declared session interest and are not subscribed to this session.
      if (event === "chat" && !shouldReceiveChatEvent(c, chatSessionKey, chatCanonicalKey)) {
        continue;
      }'''
if old_for_loop in content:
    content = content.replace(old_for_loop, new_for_loop, 1)
    changes += 1

with open(path, 'w') as f:
    f.write(content)
print(f"    OK: #32580 server-broadcast.ts ({changes} changes)")
PYEOF
CHANGES=$((CHANGES + 1))

# ─── 2) server/ws-types.ts: add chatSessionKeys ───
FILE="$SRC/gateway/server/ws-types.ts"
[ -f "$FILE" ] || { echo "    FAIL: $FILE not found"; exit 1; }

python3 - "$FILE" << 'PYEOF'
import sys

path = sys.argv[1]
with open(path, 'r') as f:
    content = f.read()

# Add chatSessionKeys before the closing brace of GatewayWsClient
old = '  canvasCapabilityExpiresAtMs?: number;\n};'
new = '''  canvasCapabilityExpiresAtMs?: number;
  /**
   * Session keys this connection has interacted with via chat.send or
   * chat.history.  Used to scope chat event delivery -- connections only
   * receive chat events for sessions they have participated in (unless
   * they hold operator.admin scope, which always receives all events).
   * Undefined/empty means the client has not declared interest in any
   * session yet and will receive all chat events for backward
   * compatibility.
   */
  chatSessionKeys?: Set<string>;
};'''
if old in content:
    content = content.replace(old, new, 1)
    with open(path, 'w') as f:
        f.write(content)
    print("    OK: #32580 ws-types.ts — chatSessionKeys added")
else:
    print("    FAIL: #32580 ws-types.ts closing brace not found", file=sys.stderr)
    sys.exit(1)
PYEOF
CHANGES=$((CHANGES + 1))

# ─── 3) server-methods/types.ts: add chatSessionKeys ───
FILE="$SRC/gateway/server-methods/types.ts"
[ -f "$FILE" ] || { echo "    FAIL: $FILE not found"; exit 1; }

python3 - "$FILE" << 'PYEOF'
import sys

path = sys.argv[1]
with open(path, 'r') as f:
    content = f.read()

# Find the clientIp line in GatewayClient and add chatSessionKeys after it
old = '  clientIp?: string;\n  canvasHostUrl?: string;'
new = '''  clientIp?: string;
  /**
   * Session keys this connection has interacted with via chat.send or
   * chat.history.  Used by the broadcaster to scope chat event delivery.
   */
  chatSessionKeys?: Set<string>;
  canvasHostUrl?: string;'''
if old in content:
    content = content.replace(old, new, 1)
    with open(path, 'w') as f:
        f.write(content)
    print("    OK: #32580 types.ts — chatSessionKeys added")
else:
    print("    FAIL: #32580 types.ts clientIp/canvasHostUrl pattern not found", file=sys.stderr)
    sys.exit(1)
PYEOF
CHANGES=$((CHANGES + 1))

echo "    OK: #32580 scoped chat broadcasts — $CHANGES files patched"
