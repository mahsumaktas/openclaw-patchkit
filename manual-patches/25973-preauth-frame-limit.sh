#!/usr/bin/env bash
# PR #25973: security(gateway): reject oversized pre-auth websocket frames
# Pre-auth WS frame'lere 64 KiB limit koyarak CPU/memory baski saldirisini engelliyor.
# 3 dosya: server-constants.ts (+10), message-handler.ts (+51/-1)
set -euo pipefail

SRC="${1:-.}/src"

# ── Idempotency check ──────────────────────────────────────────────────────
if grep -q 'getMaxPreAuthFrameBytes' "$SRC/gateway/server-constants.ts" 2>/dev/null; then
  echo "    SKIP: #25973 already applied"
  exit 0
fi

# ── 1. server-constants.ts: add DEFAULT_MAX_PREAUTH_FRAME_BYTES + getter ──
python3 - "$SRC/gateway/server-constants.ts" << 'PYEOF'
import sys
path = sys.argv[1]
with open(path, 'r') as f:
    content = f.read()

# Insert after getHandshakeTimeoutMs closing brace
marker = "  return DEFAULT_HANDSHAKE_TIMEOUT_MS;\n};"
insertion = """  return DEFAULT_HANDSHAKE_TIMEOUT_MS;
};
export const DEFAULT_MAX_PREAUTH_FRAME_BYTES = 64 * 1024;
export const getMaxPreAuthFrameBytes = () => {
  if (process.env.VITEST && process.env.OPENCLAW_TEST_MAX_PREAUTH_FRAME_BYTES) {
    const parsed = Number(process.env.OPENCLAW_TEST_MAX_PREAUTH_FRAME_BYTES);
    if (Number.isFinite(parsed) && parsed > 0) {
      return parsed;
    }
  }
  return DEFAULT_MAX_PREAUTH_FRAME_BYTES;
};"""

if marker in content:
    content = content.replace(marker, insertion)
    with open(path, 'w') as f:
        f.write(content)
    print("    OK: #25973 server-constants.ts patched")
else:
    print("    WARN: marker not found in server-constants.ts, trying alt")
    # Alt: insert before TICK_INTERVAL_MS
    alt_marker = "export const TICK_INTERVAL_MS"
    if alt_marker in content:
        block = """export const DEFAULT_MAX_PREAUTH_FRAME_BYTES = 64 * 1024;
export const getMaxPreAuthFrameBytes = () => {
  if (process.env.VITEST && process.env.OPENCLAW_TEST_MAX_PREAUTH_FRAME_BYTES) {
    const parsed = Number(process.env.OPENCLAW_TEST_MAX_PREAUTH_FRAME_BYTES);
    if (Number.isFinite(parsed) && parsed > 0) {
      return parsed;
    }
  }
  return DEFAULT_MAX_PREAUTH_FRAME_BYTES;
};
"""
        content = content.replace(alt_marker, block + alt_marker)
        with open(path, 'w') as f:
            f.write(content)
        print("    OK: #25973 server-constants.ts patched (alt)")
    else:
        print("    FAIL: cannot find insertion point")
        sys.exit(1)
PYEOF

# ── 2. message-handler.ts: add import + rawDataByteLength + guard ─────────
python3 - "$SRC/gateway/server/ws-connection/message-handler.ts" << 'PYEOF'
import sys
path = sys.argv[1]
with open(path, 'r') as f:
    content = f.read()

# 2a. Add getMaxPreAuthFrameBytes to import from server-constants
# Find the import block from server-constants
import re

# Check if already imported
if 'getMaxPreAuthFrameBytes' in content:
    print("    OK: #25973 import already present")
else:
    # Find import from server-constants and add getMaxPreAuthFrameBytes
    pattern = r'(import\s*\{[^}]*)(}\s*from\s*["\']\.\.\/\.\.\/server-constants\.js["\'])'
    match = re.search(pattern, content, re.DOTALL)
    if match:
        imports = match.group(1)
        closing = match.group(2)
        # Add getMaxPreAuthFrameBytes before closing brace
        if imports.rstrip().endswith(','):
            new_imports = imports + '\n  getMaxPreAuthFrameBytes,\n' + closing
        else:
            new_imports = imports.rstrip() + ',\n  getMaxPreAuthFrameBytes,\n' + closing
        content = content[:match.start()] + new_imports + content[match.end():]
        print("    OK: #25973 import added")
    else:
        # Try simpler pattern
        simple = 'from "../../server-constants.js";'
        if simple in content:
            content = content.replace(
                simple,
                simple.replace('";', '";\nimport { getMaxPreAuthFrameBytes } from "../../server-constants.js";')
            )
            print("    OK: #25973 import added (simple)")
        else:
            print("    WARN: could not add import, trying inline")

# 2b. Add rawDataByteLength function before attachGatewayWsMessageHandler
raw_fn = '''function rawDataByteLength(data: WebSocket.RawData): number {
  if (typeof data === "string") {
    return Buffer.byteLength(data, "utf8");
  }
  if (Buffer.isBuffer(data)) {
    return data.byteLength;
  }
  if (Array.isArray(data)) {
    let total = 0;
    for (const chunk of data) {
      if (Buffer.isBuffer(chunk)) {
        total += chunk.byteLength;
        continue;
      }
      if (chunk instanceof ArrayBuffer) {
        total += chunk.byteLength;
        continue;
      }
      total += Buffer.byteLength(String(chunk), "utf8");
    }
    return total;
  }
  if (data instanceof ArrayBuffer) {
    return data.byteLength;
  }
  return Buffer.byteLength(String(data), "utf8");
}

'''

if 'rawDataByteLength' not in content:
    marker = 'export function attachGatewayWsMessageHandler'
    if marker in content:
        content = content.replace(marker, raw_fn + marker)
        print("    OK: #25973 rawDataByteLength function added")
    else:
        print("    FAIL: attachGatewayWsMessageHandler not found")
        sys.exit(1)
else:
    print("    OK: #25973 rawDataByteLength already present")

# 2c. Add pre-auth frame size guard in message handler
# Insert after "if (isClosed()) { return; }" in the message handler
guard = '''    const preAuthClient = getClient();
    if (!preAuthClient) {
      const preAuthFrameBytes = rawDataByteLength(data);
      const maxPreAuthFrameBytes = getMaxPreAuthFrameBytes();
      if (preAuthFrameBytes > maxPreAuthFrameBytes) {
        setHandshakeState("failed");
        setCloseCause("preauth-frame-too-large", {
          preAuthFrameBytes,
          maxPreAuthFrameBytes,
        });
        logWsControl.warn(
          `pre-auth frame too large conn=${connId} remote=${remoteAddr ?? "?"} bytes=${preAuthFrameBytes} limit=${maxPreAuthFrameBytes}`,
        );
        close(1009, "pre-auth frame too large");
        return;
      }
    }
'''

if 'preauth-frame-too-large' not in content:
    # Find the isClosed check followed by rawDataToString
    check_pattern = r'(if \(isClosed\(\)\) \{\s*return;\s*\})'
    matches = list(re.finditer(check_pattern, content))
    if matches:
        # Use the last match (the one in the message handler, not handshake)
        last_match = matches[-1]
        insert_pos = last_match.end()
        content = content[:insert_pos] + '\n' + guard + content[insert_pos:]
        print("    OK: #25973 pre-auth frame guard added")
    else:
        print("    FAIL: isClosed() guard not found")
        sys.exit(1)
else:
    print("    OK: #25973 pre-auth frame guard already present")

with open(path, 'w') as f:
    f.write(content)

print("    OK: #25973 message-handler.ts fully patched")
PYEOF

echo "    OK: #25973 pre-auth frame limit fully applied"
