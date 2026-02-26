#!/usr/bin/env bash
# FIX-A2: fix(discord): prevent ResilientGatewayPlugin maxAttempts=0 uncaught exception
#
# Problem: In src/discord/monitor/provider.lifecycle.ts (v2026.2.24+),
# onAbort() sets maxAttempts=0 and disconnects. Carbon's ResilientGatewayPlugin
# emits an error when maxAttempts is reached, but the one-shot error listener
# on gatewayEmitter may not catch it if gatewayEmitter is stale/undefined.
# Result: "Uncaught exception: Max reconnect attempts (0) reached" crashes gateway.
#
# Fix: Register error handler on gateway.emitter directly (not just cached
# gatewayEmitter), and wrap disconnect in try-catch as defense-in-depth.
#
# Note: In v2026.2.24, onAbort moved from provider.ts → provider.lifecycle.ts
set -euo pipefail

SRC="${1:-.}/src"

# ── Detect target file (moved between versions) ─────────────────────────────
TARGET=""
if [ -f "$SRC/discord/monitor/provider.lifecycle.ts" ]; then
  TARGET="$SRC/discord/monitor/provider.lifecycle.ts"
elif [ -f "$SRC/discord/monitor/provider.ts" ]; then
  TARGET="$SRC/discord/monitor/provider.ts"
else
  echo "    FAIL: FIX-A2 neither provider.lifecycle.ts nor provider.ts found"
  exit 1
fi

# ── Idempotency check ──────────────────────────────────────────────────────
if grep -q 'FIX-A2' "$TARGET" 2>/dev/null; then
  echo "    SKIP: FIX-A2 discord reconnect crash already applied"
  exit 0
fi

# ── Patch target file ─────────────────────────────────────────────────────────
python3 - "$TARGET" << 'PYEOF'
import sys

path = sys.argv[1]
with open(path, 'r') as f:
    content = f.read()

if 'FIX-A2' in content:
    print("    SKIP: FIX-A2 already applied")
    sys.exit(0)

lines = content.split('\n')
new_lines = []
patched_emitter = False
patched_disconnect = False

for i, line in enumerate(lines):
    new_lines.append(line)
    stripped = line.strip()

    # After the gatewayEmitter?.once("error", ...) line, add gateway.emitter listener
    if 'gatewayEmitter?.once("error"' in stripped and not patched_emitter:
        indent = line[:len(line) - len(line.lstrip())]
        new_lines.append(f'{indent}try {{ (gateway as any).emitter?.once("error", () => {{}}); }} catch {{}} // FIX-A2')
        patched_emitter = True

    # Wrap gateway.disconnect() in try-catch (first occurrence only — the onAbort one)
    if 'gateway.disconnect();' in stripped and stripped == 'gateway.disconnect();' and not patched_disconnect:
        indent = line[:len(line) - len(line.lstrip())]
        new_lines[-1] = f'{indent}try {{ gateway.disconnect(); }} catch {{}} // FIX-A2'
        patched_disconnect = True

if patched_emitter or patched_disconnect:
    content = '\n'.join(new_lines)
    with open(path, 'w') as f:
        f.write(content)
    print(f"    OK: FIX-A2 applied (emitter={patched_emitter}, disconnect={patched_disconnect})")
else:
    print("    FAIL: FIX-A2 could not find target patterns in " + path, file=sys.stderr)
    sys.exit(1)
PYEOF

echo "    OK: FIX-A2 discord reconnect crash fix applied"
