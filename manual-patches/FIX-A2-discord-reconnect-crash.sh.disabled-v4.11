#!/usr/bin/env bash
# FIX-A2: fix(discord): prevent ResilientGatewayPlugin maxAttempts=0 uncaught exception
#
# Problem: In src/discord/monitor/provider.lifecycle.ts (v2026.2.24+),
# onAbort() sets maxAttempts=0 and disconnects. Carbon's ResilientGatewayPlugin
# emits an error when maxAttempts is reached, but NO handler is registered on
# carbon's internal EventEmitter. Node.js throws unhandled "error" events as
# uncaught exceptions, crashing the entire gateway process.
#
# Root cause: @buape/carbon creates `this.emitter = new EventEmitter()` but
# never registers an "error" handler. Any `.emit("error", ...)` becomes fatal.
#
# Fix (dual-layer):
#   Layer 1 (source): Register error handler on gateway.emitter + wrap disconnect
#   Layer 2 (carbon): Patch @buape/carbon's GatewayPlugin.js constructor
#     to add a default no-op error handler (done by dist-patches.sh Patch 1b)
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
patched_process = False

for i, line in enumerate(lines):
    new_lines.append(line)
    stripped = line.strip()

    # After the gatewayEmitter?.once("error", ...) line, add gateway.emitter listener
    if 'gatewayEmitter?.once("error"' in stripped and not patched_emitter:
        indent = line[:len(line) - len(line.lstrip())]
        # Register error handler on BOTH the cached emitter AND the gateway's internal emitter
        new_lines.append(f'{indent}// FIX-A2: register no-op error handler on carbon\'s internal emitter')
        new_lines.append(f'{indent}// to prevent Node.js uncaught exception on max reconnect attempts')
        new_lines.append(f'{indent}try {{ (gateway as any).emitter?.on("error", () => {{}}); }} catch {{}} // FIX-A2')
        patched_emitter = True

    # Wrap gateway.disconnect() in try-catch (first occurrence only — the onAbort one)
    if 'gateway.disconnect();' in stripped and stripped == 'gateway.disconnect();' and not patched_disconnect:
        indent = line[:len(line) - len(line.lstrip())]
        new_lines[-1] = f'{indent}try {{ gateway.disconnect(); }} catch {{}} // FIX-A2'
        patched_disconnect = True

# If emitter pattern not found (code structure changed), add process-level safety net
if not patched_emitter:
    # Find the onAbort function and add process handler at the top
    for i, line in enumerate(new_lines):
        if 'onAbort' in line and ('function' in line or '=>' in line or 'async' in line):
            indent = new_lines[i][:len(new_lines[i]) - len(new_lines[i].lstrip())]
            child_indent = indent + '  '
            # Insert after the function opening brace
            for j in range(i, min(i + 5, len(new_lines))):
                if '{' in new_lines[j]:
                    new_lines.insert(j + 1, f'{child_indent}// FIX-A2: prevent uncaught exception from carbon reconnect failure')
                    new_lines.insert(j + 2, f'{child_indent}const _fixA2 = process.listeners("uncaughtException").find((h: any) => h._fixA2);')
                    new_lines.insert(j + 3, f'{child_indent}if (!_fixA2) {{')
                    new_lines.insert(j + 4, f'{child_indent}  const handler = ((err: Error) => {{')
                    new_lines.insert(j + 5, f'{child_indent}    if (err?.message?.includes("Max reconnect attempts")) return;')
                    new_lines.insert(j + 6, f'{child_indent}    throw err;')
                    new_lines.insert(j + 7, f'{child_indent}  }}) as any;')
                    new_lines.insert(j + 8, f'{child_indent}  handler._fixA2 = true;')
                    new_lines.insert(j + 9, f'{child_indent}  process.on("uncaughtException", handler);')
                    new_lines.insert(j + 10, f'{child_indent}}} // FIX-A2')
                    patched_process = True
                    break
            break

if patched_emitter or patched_disconnect or patched_process:
    content = '\n'.join(new_lines)
    with open(path, 'w') as f:
        f.write(content)
    parts = []
    if patched_emitter: parts.append("emitter")
    if patched_disconnect: parts.append("disconnect")
    if patched_process: parts.append("process-handler")
    print(f"    OK: FIX-A2 applied ({', '.join(parts)})")
else:
    # Don't fail — dist-patches.sh Patch 1b provides the safety net
    print("    WARN: FIX-A2 source patterns not found (dist-patches.sh Patch 1b will cover)")
    sys.exit(0)
PYEOF

echo "    OK: FIX-A2 discord reconnect crash fix applied"
