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
#
# NOTE (v2026.3.13): probeGateway signature changed — includeDetails? was added.
# GatewayClient constructor no longer has scopes/password on the same line.
# This version handles both old and new signatures.
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
import re

path = sys.argv[1]
with open(path, "r") as f:
    content = f.read()

if "tlsFingerprint" in content:
    print("    SKIP: FIX-A1 probe.ts already has tlsFingerprint")
    sys.exit(0)

changed = False

# ── Add tlsFingerprint to the function parameter type ──
# v2026.3.13 signature:
#   export async function probeGateway(opts: {
#     url: string;
#     auth?: GatewayProbeAuth;
#     timeoutMs: number;
#     includeDetails?: boolean;
#   }): Promise<GatewayProbeResult> {
#
# We insert tlsFingerprint?: string; before timeoutMs.

# Try v2026.3.13 form (with includeDetails)
old_sig_v313 = """export async function probeGateway(opts: {
  url: string;
  auth?: GatewayProbeAuth;
  timeoutMs: number;
  includeDetails?: boolean;
}): Promise<GatewayProbeResult> {"""

new_sig_v313 = """export async function probeGateway(opts: {
  url: string;
  auth?: GatewayProbeAuth;
  tlsFingerprint?: string;
  timeoutMs: number;
  includeDetails?: boolean;
}): Promise<GatewayProbeResult> {"""

# Try older form (without includeDetails)
old_sig_old = """export async function probeGateway(opts: {
  url: string;
  auth?: GatewayProbeAuth;
  timeoutMs: number;
}): Promise<GatewayProbeResult> {"""

new_sig_old = """export async function probeGateway(opts: {
  url: string;
  auth?: GatewayProbeAuth;
  tlsFingerprint?: string;
  timeoutMs: number;
}): Promise<GatewayProbeResult> {"""

if old_sig_v313 in content:
    content = content.replace(old_sig_v313, new_sig_v313, 1)
    changed = True
    print("    OK: FIX-A1 added tlsFingerprint to probeGateway (v2026.3.13 signature)")
elif old_sig_old in content:
    content = content.replace(old_sig_old, new_sig_old, 1)
    changed = True
    print("    OK: FIX-A1 added tlsFingerprint to probeGateway (classic signature)")
else:
    # Fallback: regex-based insertion
    match = re.search(
        r'(export async function probeGateway\(opts: \{[^}]*?)(  timeoutMs: number;)',
        content,
        re.DOTALL,
    )
    if match:
        insert_point = match.start(2)
        content = content[:insert_point] + "  tlsFingerprint?: string;\n" + content[insert_point:]
        changed = True
        print("    OK: FIX-A1 added tlsFingerprint to probeGateway (regex fallback)")
    else:
        print("    FAIL: FIX-A1 cannot find probeGateway function signature", file=sys.stderr)
        sys.exit(1)

# ── Add tlsFingerprint to the GatewayClient constructor ──
# v2026.3.13 form:
#     const client = new GatewayClient({
#       url: opts.url,
#       token: opts.auth?.token,
#       password: opts.auth?.password,
#       scopes: [READ_SCOPE],
#
# Insert tlsFingerprint: opts.tlsFingerprint, after password line.

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

if old_client in content:
    content = content.replace(old_client, new_client, 1)
    changed = True
    print("    OK: FIX-A1 added tlsFingerprint to GatewayClient constructor")
else:
    # Fallback: insert after password line in GatewayClient constructor
    match = re.search(
        r'(new GatewayClient\(\{[^}]*?password: opts\.auth\?\.password,\n)',
        content,
        re.DOTALL,
    )
    if match:
        insert_at = match.end()
        indent = "      "
        content = content[:insert_at] + indent + "tlsFingerprint: opts.tlsFingerprint,\n" + content[insert_at:]
        changed = True
        print("    OK: FIX-A1 added tlsFingerprint to GatewayClient (regex fallback)")
    else:
        print("    FAIL: FIX-A1 cannot find GatewayClient constructor in probe.ts", file=sys.stderr)
        sys.exit(1)

if changed:
    with open(path, "w") as f:
        f.write(content)
    print("    OK: FIX-A1 probe.ts patched")
else:
    print("    FAIL: FIX-A1 no changes made to probe.ts", file=sys.stderr)
    sys.exit(1)
PYEOF

# ── 2. Patch src/commands/gateway-status.ts — resolve + pass fingerprint ──
python3 - "$SRC/commands/gateway-status.ts" << 'PYEOF'
import sys
import re

path = sys.argv[1]
with open(path, "r") as f:
    content = f.read()

if "tlsFingerprint" in content and "loadGatewayTlsRuntime" in content:
    print("    SKIP: FIX-A1 gateway-status.ts already has TLS fingerprint resolution")
    sys.exit(0)

changed = False

# ── Add import for loadGatewayTlsRuntime ──
if "loadGatewayTlsRuntime" not in content:
    # Try to find the probeGateway import line
    probe_import = 'import { probeGateway } from "../gateway/probe.js";'
    if probe_import in content:
        new_import = probe_import + '\nimport { loadGatewayTlsRuntime } from "../infra/tls/gateway.js";'
        content = content.replace(probe_import, new_import, 1)
        changed = True
        print("    OK: FIX-A1 added loadGatewayTlsRuntime import")
    else:
        print("    WARN: FIX-A1 could not find probe import line — trying regex")
        match = re.search(r'(import \{ probeGateway \} from ["\']\.\.\/gateway\/probe\.js["\'];)', content)
        if match:
            new_import = match.group(0) + '\nimport { loadGatewayTlsRuntime } from "../infra/tls/gateway.js";'
            content = content.replace(match.group(0), new_import, 1)
            changed = True
            print("    OK: FIX-A1 added loadGatewayTlsRuntime import (regex)")
        else:
            print("    WARN: FIX-A1 could not add import — manual review needed")

# ── Add TLS fingerprint resolution before the probing loop ──
# Find "const probed = await Promise.all(" and add fingerprint resolution before it
marker = "const probed = await Promise.all("
if marker in content and "probeTlsFingerprint" not in content:
    # Determine indentation by finding the marker's indent
    marker_pos = content.find(marker)
    # Walk backwards to find line start
    line_start = content.rfind("\n", 0, marker_pos) + 1
    indent = content[line_start:marker_pos]

    fingerprint_block = (
        f"// FIX-A1: Resolve TLS fingerprint for self-signed cert probe\n"
        f"{indent}const tlsRuntime = cfg.gateway?.tls?.enabled\n"
        f"{indent}  ? await loadGatewayTlsRuntime(cfg.gateway?.tls)\n"
        f"{indent}  : undefined;\n"
        f"{indent}const probeTlsFingerprint = tlsRuntime?.enabled ? tlsRuntime.fingerprintSha256 : undefined;\n"
        f"\n"
        f"{indent}"
    )
    content = content.replace(marker, fingerprint_block + marker, 1)
    changed = True
    print("    OK: FIX-A1 added TLS fingerprint resolution")

# ── Pass tlsFingerprint to probeGateway call ──
# v2026.3.13 form:
#             const probe = await probeGateway({
#               url: target.url,
#               auth,
#               timeoutMs,
#             });

old_probe = """            const probe = await probeGateway({
              url: target.url,
              auth,
              timeoutMs,
            });"""

new_probe = """            const probe = await probeGateway({
              url: target.url,
              auth,
              tlsFingerprint: target.url.startsWith("wss://") ? probeTlsFingerprint : undefined,
              timeoutMs,
            });"""

if old_probe in content:
    content = content.replace(old_probe, new_probe, 1)
    changed = True
    print("    OK: FIX-A1 passing tlsFingerprint to probeGateway")
else:
    # Try regex fallback for different indentation
    match = re.search(
        r'(const probe = await probeGateway\(\{\s*\n'
        r'\s*url: target\.url,\s*\n'
        r'\s*auth,\s*\n)'
        r'(\s*timeoutMs,)',
        content,
    )
    if match:
        indent_match = re.search(r'\n(\s+)auth,', match.group(0))
        prop_indent = indent_match.group(1) if indent_match else "              "
        insert_line = f"{prop_indent}tlsFingerprint: target.url.startsWith(\"wss://\") ? probeTlsFingerprint : undefined,\n"
        content = content[:match.start(2)] + insert_line + content[match.start(2):]
        changed = True
        print("    OK: FIX-A1 passing tlsFingerprint to probeGateway (regex fallback)")
    else:
        print("    WARN: FIX-A1 could not find probeGateway call pattern — manual review needed")

if changed:
    with open(path, "w") as f:
        f.write(content)
    print("    OK: FIX-A1 gateway-status.ts patched")
else:
    print("    WARN: FIX-A1 no changes made to gateway-status.ts")

PYEOF

echo "    OK: FIX-A1 probe TLS fingerprint fix applied"
