#!/usr/bin/env bash
# Issue #18446: /healthz returns HTML instead of JSON
# The /healthz endpoint falls through to the Control UI SPA catch-all,
# returning index.html instead of JSON. This breaks monitoring tools.
# Fix: add explicit /healthz route in handleRequest before any other handler.
set -euo pipefail

SRC="${1:-.}/src"

# ── Idempotency check ──────────────────────────────────────────────────────
if grep -q '"/healthz"' "$SRC/gateway/server-http.ts" 2>/dev/null; then
  echo "    SKIP: #18446 already applied"
  exit 0
fi

# ── 1. Add VERSION import + /healthz handler to server-http.ts ─────────────
python3 - "$SRC/gateway/server-http.ts" << 'PYEOF'
import sys

path = sys.argv[1]
with open(path, 'r') as f:
    content = f.read()

# 1a. Add VERSION import after the "ws" import line
import_marker = 'import type { WebSocketServer } from "ws";'
if import_marker not in content:
    print("    FAIL: #18446 cannot find ws import marker in server-http.ts")
    sys.exit(1)

version_import = 'import { VERSION } from "../version.js";'
content = content.replace(
    import_marker,
    import_marker + '\n' + version_import,
    1,
)

# 1b. Add /healthz handler at the top of the try block in handleRequest,
#     before loadConfig() — no auth, no config needed for health checks.
handler_marker = '    try {\n      const configSnapshot = loadConfig();'
if handler_marker not in content:
    print("    FAIL: #18446 cannot find try/loadConfig marker in server-http.ts")
    sys.exit(1)

healthz_handler = '''    try {
      // #18446: explicit /healthz handler — must precede all other routes
      // so it never falls through to the SPA catch-all.
      const healthPath = new URL(req.url ?? "/", "http://localhost").pathname;
      if (healthPath === "/healthz") {
        sendJson(res, 200, {
          status: "ok",
          version: VERSION,
          uptime: process.uptime(),
        });
        return;
      }

      const configSnapshot = loadConfig();'''

content = content.replace(handler_marker, healthz_handler, 1)

with open(path, 'w') as f:
    f.write(content)

print("    OK: #18446 /healthz JSON handler added to server-http.ts")
PYEOF

echo "    OK: #18446 fully applied"
