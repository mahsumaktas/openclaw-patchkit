#!/usr/bin/env bash
# FIX-A1: fix(gateway-status): pass tlsFingerprint to probeGateway
#
# Problem: probeGateway() creates a GatewayClient without tlsFingerprint.
# When TLS is enabled with a self-signed cert, rejectUnauthorized is never
# set to false, so the WSS probe fails with 1006.
# Meanwhile callGateway() correctly resolves and passes the fingerprint.
#
# Fix:
#   1. src/gateway/probe.ts — accept optional tlsFingerprint, pass to GatewayClient
#   2. src/commands/gateway-status.ts — resolve TLS fingerprint, pass to probeGateway
set -euo pipefail

SRC="${1:-.}/src"

# ── Idempotency check ──────────────────────────────────────────────────────
if grep -q 'tlsFingerprint' "$SRC/gateway/probe.ts" 2>/dev/null; then
  echo "    SKIP: FIX-A1 probe TLS fingerprint already applied"
  exit 0
fi

# ── 1. Patch src/gateway/probe.ts — accept + forward tlsFingerprint ──────
python3 - "$SRC/gateway/probe.ts" << 'PYEOF'
import sys

path = sys.argv[1]
with open(path, 'r') as f:
    content = f.read()

if 'tlsFingerprint' in content:
    print("    SKIP: FIX-A1 probe.ts already has tlsFingerprint")
    sys.exit(0)

# Add tlsFingerprint to the function parameter type
old_params = """export async function probeGateway(opts: {
  url: string;
  auth?: GatewayProbeAuth;
  timeoutMs: number;
}): Promise<GatewayProbeResult> {"""

new_params = """export async function probeGateway(opts: {
  url: string;
  auth?: GatewayProbeAuth;
  tlsFingerprint?: string;
  timeoutMs: number;
}): Promise<GatewayProbeResult> {"""

if old_params not in content:
    print("    FAIL: FIX-A1 cannot find probeGateway function signature", file=sys.stderr)
    sys.exit(1)

content = content.replace(old_params, new_params, 1)

# Add tlsFingerprint to the GatewayClient constructor
old_client = """    const client = new GatewayClient({
      url: opts.url,
      token: opts.auth?.token,
      password: opts.auth?.password,
      scopes: [READ_SCOPE],"""

new_client = """    const client = new GatewayClient({
      url: opts.url,
      token: opts.auth?.token,
      password: opts.auth?.password,
      tlsFingerprint: opts.tlsFingerprint,
      scopes: [READ_SCOPE],"""

if old_client not in content:
    print("    FAIL: FIX-A1 cannot find GatewayClient constructor in probe.ts", file=sys.stderr)
    sys.exit(1)

content = content.replace(old_client, new_client, 1)

with open(path, 'w') as f:
    f.write(content)
print("    OK: FIX-A1 probe.ts patched — tlsFingerprint parameter added")
PYEOF

# ── 2. Patch src/commands/gateway-status.ts — resolve + pass fingerprint ──
python3 - "$SRC/commands/gateway-status.ts" << 'PYEOF'
import sys

path = sys.argv[1]
with open(path, 'r') as f:
    content = f.read()

if 'tlsFingerprint' in content and 'loadGatewayTlsRuntime' in content:
    print("    SKIP: FIX-A1 gateway-status.ts already has TLS fingerprint resolution")
    sys.exit(0)

changed = False

# Add import for loadGatewayTlsRuntime
if 'loadGatewayTlsRuntime' not in content:
    old_import = 'import { probeGateway } from "../gateway/probe.js";'
    new_import = '''import { probeGateway } from "../gateway/probe.js";
import { loadGatewayTlsRuntime } from "../infra/tls/gateway.js";'''
    if old_import in content:
        content = content.replace(old_import, new_import, 1)
        changed = True
        print("    OK: FIX-A1 added loadGatewayTlsRuntime import")
    else:
        print("    WARN: FIX-A1 could not find probe import line")

# Add TLS fingerprint resolution before the probing loop
# Find "const probed = await Promise.all(" and add fingerprint resolution before it
marker = 'const probed = await Promise.all('
if marker in content:
    indent = '        '
    fingerprint_block = f"""// FIX-A1: Resolve TLS fingerprint for self-signed cert probe
{indent}const tlsRuntime = cfg.gateway?.tls?.enabled
{indent}  ? await loadGatewayTlsRuntime(cfg.gateway?.tls)
{indent}  : undefined;
{indent}const probeTlsFingerprint = tlsRuntime?.enabled ? tlsRuntime.fingerprintSha256 : undefined;

{indent}"""
    content = content.replace(marker, fingerprint_block + marker, 1)
    changed = True
    print("    OK: FIX-A1 added TLS fingerprint resolution")

# Pass tlsFingerprint to probeGateway call
old_probe_call = """            const probe = await probeGateway({
              url: target.url,
              auth,
              timeoutMs,
            });"""

new_probe_call = """            const probe = await probeGateway({
              url: target.url,
              auth,
              tlsFingerprint: target.url.startsWith("wss://") ? probeTlsFingerprint : undefined,
              timeoutMs,
            });"""

if old_probe_call in content:
    content = content.replace(old_probe_call, new_probe_call, 1)
    changed = True
    print("    OK: FIX-A1 passing tlsFingerprint to probeGateway")
else:
    print("    WARN: FIX-A1 could not find probeGateway call pattern")

if changed:
    with open(path, 'w') as f:
        f.write(content)
    print("    OK: FIX-A1 gateway-status.ts patched")
else:
    print("    WARN: FIX-A1 no changes made to gateway-status.ts")

PYEOF

echo "    OK: FIX-A1 probe TLS fingerprint fix applied"
