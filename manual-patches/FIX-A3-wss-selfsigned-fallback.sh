#!/usr/bin/env bash
# FIX-A3: fix(gateway): accept self-signed cert for wss:// even without fingerprint
#
# Problem: GatewayClient only sets rejectUnauthorized=false when tlsFingerprint
# is provided. If resolveGatewayTlsFingerprint() fails or returns undefined
# (e.g., cron tools, timing issues), wss:// connections to self-signed cert
# are rejected with 1006 abnormal closure.
#
# Fix: Add else-if fallback: when wss:// is used but no fingerprint is available,
# still set rejectUnauthorized=false (accept any cert). Less secure than
# fingerprint pinning, but prevents connection failures on local gateway.
set -euo pipefail

SRC="${1:-.}/src"
TARGET="$SRC/gateway/client.ts"

# ── Idempotency check ──────────────────────────────────────────────────────
if grep -q 'FIX-A3' "$TARGET" 2>/dev/null; then
  echo "    SKIP: FIX-A3 wss self-signed fallback already applied"
  exit 0
fi

# ── Patch client.ts ─────────────────────────────────────────────────────────
python3 - "$TARGET" << 'PYEOF'
import sys, re

path = sys.argv[1]
with open(path, 'r') as f:
    content = f.read()

if 'FIX-A3' in content:
    print("    SKIP: FIX-A3 already applied")
    sys.exit(0)

# Find the closing brace of the fingerprint guard block and add else-if
# Pattern: the if block starts with:
#   if (url.startsWith("wss://") && this.opts.tlsFingerprint) {
# We need to find the matching closing brace and add the else-if after it.
#
# Strategy: find all lines, locate the if block, track braces to find its end

lines = content.split('\n')
new_lines = []
in_fingerprint_block = False
brace_depth = 0
block_start_line = -1
patched = False

for i, line in enumerate(lines):
    stripped = line.strip()

    # Detect start of the fingerprint guard block
    if 'url.startsWith("wss://") && this.opts.tlsFingerprint' in stripped and stripped.startswith('if'):
        in_fingerprint_block = True
        brace_depth = 0
        block_start_line = i

    if in_fingerprint_block:
        brace_depth += stripped.count('{') - stripped.count('}')
        if brace_depth <= 0 and block_start_line != i:
            # This is the closing brace of the fingerprint block
            in_fingerprint_block = False
            if not patched:
                indent = line[:len(line) - len(line.lstrip())]
                # Add else-if for wss:// without fingerprint
                new_lines.append(line)
                new_lines.append(f'{indent}else if (url.startsWith("wss://")) {{ // FIX-A3: accept self-signed without fingerprint')
                new_lines.append(f'{indent}  wsOptions.rejectUnauthorized = false;')
                new_lines.append(f'{indent}}}')
                patched = True
                continue

    new_lines.append(line)

if patched:
    content = '\n'.join(new_lines)
    with open(path, 'w') as f:
        f.write(content)
    print("    OK: FIX-A3 applied — else-if fallback for wss:// without fingerprint")
else:
    print("    FAIL: FIX-A3 could not find fingerprint guard block", file=sys.stderr)
    sys.exit(1)
PYEOF

echo "    OK: FIX-A3 wss self-signed fallback applied"
