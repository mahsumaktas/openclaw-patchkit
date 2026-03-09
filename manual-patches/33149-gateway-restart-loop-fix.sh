#!/usr/bin/env bash
# PR #33149 — Gateway: fix restart-loop by terminating wss clients before close
# and triggering supervisor restart on Linux
#
# Core issue: wss.close() blocks indefinitely when clients don't send close frames,
# preventing httpServer.close() from releasing the TCP port. New gateway starts fail
# with EADDRINUSE, creating an infinite restart loop.
#
# Changes:
# 1. server-close.ts: Force-terminate WS clients before wss.close() +
#    use closeAllConnections instead of closeIdleConnections
# 2. process-respawn.ts: Call triggerOpenClawRestart for ALL supervised environments
#    (not just launchd/schtasks) so Linux systemd also gets a clean restart
set -euo pipefail
SRC="${1:-.}/src"

CLOSE_FILE="$SRC/gateway/server-close.ts"
RESPAWN_FILE="$SRC/infra/process-respawn.ts"

# Idempotency check
if grep -q 'ws.terminate()' "$CLOSE_FILE" 2>/dev/null; then
  echo "    SKIP: #33149 already applied"
  exit 0
fi

[ -f "$CLOSE_FILE" ]   || { echo "    FAIL: $CLOSE_FILE not found"; exit 1; }
[ -f "$RESPAWN_FILE" ] || { echo "    FAIL: $RESPAWN_FILE not found"; exit 1; }

# 1) server-close.ts: Force-terminate WS clients + closeAllConnections
python3 - "$CLOSE_FILE" << 'PYEOF'
import sys

path = sys.argv[1]
with open(path, 'r') as f:
    content = f.read()

# 1a) Add ws.terminate() loop before wss.close()
old_wss = '    await new Promise<void>((resolve) => params.wss.close(() => resolve()));'

new_wss = '''    // Force-terminate any WS connections that did not close gracefully (e.g.
    // connections still in the upgrade handshake, or clients that silently
    // dropped without sending a close frame back).  Without this, wss.close()
    // blocks indefinitely because it waits for all clients to disconnect.
    // A hung wss.close() prevents httpServer.close() from ever being reached,
    // leaving the TCP listening socket bound — the upstream process holds the
    // port and every new gateway process fails with EADDRINUSE, creating an
    // infinite restart loop (see issue #33103).
    for (const ws of params.wss.clients) {
      try {
        ws.terminate();
      } catch {
        /* ignore */
      }
    }
    await new Promise<void>((resolve) => params.wss.close(() => resolve()));'''

if old_wss not in content:
    print("    FAIL: #33149 wss.close pattern not found", file=sys.stderr)
    sys.exit(1)

content = content.replace(old_wss, new_wss, 1)

# 1b) Replace closeIdleConnections with closeAllConnections (Node 18.2+)
old_close = '      if (typeof httpServer.closeIdleConnections === "function") {\n        httpServer.closeIdleConnections();'

new_close = '''      // closeAllConnections (Node 18.2+) is more thorough than closeIdleConnections:
      // it destroys every connection so httpServer.close() resolves immediately
      // without waiting for keep-alive connections to time out on their own.
      if (typeof httpServer.closeAllConnections === "function") {
        httpServer.closeAllConnections();
      } else if (typeof httpServer.closeIdleConnections === "function") {
        httpServer.closeIdleConnections();'''

if old_close not in content:
    # Maybe closeAllConnections type def already exists but logic doesn't
    print("    WARN: #33149 closeIdleConnections pattern not found (may already be partially applied)")
else:
    content = content.replace(old_close, new_close, 1)

    # Also need to add closeAllConnections to the type definition
    old_type = '''      const httpServer = server as HttpServer & {
        closeIdleConnections?: () => void;
      };'''
    new_type = '''      const httpServer = server as HttpServer & {
        closeIdleConnections?: () => void;
        closeAllConnections?: () => void;
      };'''
    if old_type in content:
        content = content.replace(old_type, new_type, 1)

with open(path, 'w') as f:
    f.write(content)
print("    OK: #33149 server-close.ts patched (ws.terminate + closeAllConnections)")
PYEOF

# 2) process-respawn.ts: Call triggerOpenClawRestart for ALL supervised environments
python3 - "$RESPAWN_FILE" << 'PYEOF'
import sys

path = sys.argv[1]
with open(path, 'r') as f:
    content = f.read()

# v2026.3.7 only calls triggerOpenClawRestart for launchd/schtasks
old_block = '''  const supervisor = detectRespawnSupervisor(process.env);
  if (supervisor) {
    if (supervisor === "launchd" || supervisor === "schtasks") {
      const restart = triggerOpenClawRestart();
      if (!restart.ok) {
        return {
          mode: "failed",
          detail: restart.detail ?? `${restart.method} restart failed`,
        };
      }
    }
    return { mode: "supervised" };
  }'''

new_block = '''  const supervisor = detectRespawnSupervisor(process.env);
  if (supervisor) {
    // Actively trigger a supervisor restart rather than relying solely on
    // Restart= policy to pick up the exit.  This also runs
    // cleanStaleGatewayProcessesSync() first to remove any upstream process
    // still holding the port - a key guard against the restart-loop (#33103).
    const restart = triggerOpenClawRestart();
    // On unsupported platforms, triggerOpenClawRestart() returns ok: false with
    // detail "unsupported platform restart". Treat that as supervised so we exit
    // cleanly; only treat other failures as mode "failed".
    if (!restart.ok && restart.detail !== "unsupported platform restart") {
      return {
        mode: "failed",
        detail: restart.detail ?? `${restart.method} restart failed`,
      };
    }
    return { mode: "supervised" };
  }'''

if old_block in content:
    content = content.replace(old_block, new_block, 1)
    with open(path, 'w') as f:
        f.write(content)
    print("    OK: #33149 process-respawn.ts patched (all supervisors get triggerOpenClawRestart)")
else:
    print("    WARN: #33149 process-respawn.ts pattern not found (may need manual check)")
PYEOF

echo "    OK: #33149 gateway restart-loop fix applied"
