#!/usr/bin/env bash
set -euo pipefail

# ─────────────────────────────────────────────────────────────────────────────
# OpenClaw Dist Patches
# Applies sed/node-based fixes to compiled JS in dist/.
# Called by patch-openclaw.sh as Phase 2.
#
# PRs:
#   - TLS probe fix:        https://github.com/openclaw/openclaw/pull/22682
#   - Self-signed cert fix: https://github.com/openclaw/openclaw/pull/22682
#   - LanceDB deps fix:     https://github.com/openclaw/openclaw/pull/22692
#
# Usage: ~/.openclaw/my-patches/dist-patches.sh
# Exit code = number of failed patches (0 = all OK)
# ─────────────────────────────────────────────────────────────────────────────

OPENCLAW_ROOT="$(npm root -g)/openclaw"
DIST="$OPENCLAW_ROOT/dist"
EXT="$OPENCLAW_ROOT/extensions/memory-lancedb/node_modules"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

ok()   { echo -e "${GREEN}[OK]${NC} $1"; }
warn() { echo -e "${YELLOW}[!!]${NC} $1"; }
fail() { echo -e "${RED}[FAIL]${NC} $1"; }

echo ""
echo "OpenClaw Dist Patches"
echo "  $(openclaw --version 2>/dev/null || echo 'version unknown')"
echo ""

APPLIED=0
SKIPPED=0
FAILED=0

# ─────────────────────────────────────────────────────────────────────
# PATCH 1: TLS-aware probe URLs in gateway status (PR #22682)
# ─────────────────────────────────────────────────────────────────────
echo "-- Patch 1: Gateway TLS probe fix (PR #22682) --"

patch_daemon_cli() {
  local file="$1"
  local name
  name="$(basename "$file")"

  if grep -q 'tls?.enabled.*"wss"' "$file" 2>/dev/null; then
    ok "$name: already patched"
    SKIPPED=$((SKIPPED + 1))
    return
  fi

  if ! grep -q 'probeUrlOverride.*ws://' "$file" 2>/dev/null; then
    warn "$name: probe pattern not found"
    SKIPPED=$((SKIPPED + 1))
    return
  fi

  sed -i.bak 's|const probeUrl = probeUrlOverride ?? `ws://\${probeHost}:\${daemonPort}`;|const _proto = daemonCfg.gateway?.tls?.enabled ? "wss" : "ws"; const probeUrl = probeUrlOverride ?? `\${_proto}://\${probeHost}:\${daemonPort}`;|g' "$file"
  rm -f "${file}.bak"
  ok "$name: patched"
  APPLIED=$((APPLIED + 1))
}

patch_gateway_cli() {
  local file="$1"
  local name
  name="$(basename "$file")"

  if grep -q 'tls?.enabled.*"wss"' "$file" 2>/dev/null; then
    ok "$name: already patched"
    SKIPPED=$((SKIPPED + 1))
    return
  fi

  local changed=false

  # resolveTargets: localLoopback URL
  if grep -q 'url: `ws://127.0.0.1:\${resolveGatewayPort(cfg)}`' "$file" 2>/dev/null; then
    sed -i.bak 's|url: `ws://127\.0\.0\.1:\${resolveGatewayPort(cfg)}`|url: `\${cfg.gateway?.tls?.enabled ? "wss" : "ws"}://127.0.0.1:\${resolveGatewayPort(cfg)}`|g' "$file"
    rm -f "${file}.bak"
    changed=true
  fi

  # buildNetworkHints: localLoopbackUrl + localTailnetUrl
  if grep -q 'localLoopbackUrl: `ws://127.0.0.1:\${port}`' "$file" 2>/dev/null; then
    sed -i.bak 's|localLoopbackUrl: `ws://127\.0\.0\.1:\${port}`|localLoopbackUrl: `\${cfg.gateway?.tls?.enabled ? "wss" : "ws"}://127.0.0.1:\${port}`|g' "$file"
    rm -f "${file}.bak"
    changed=true
  fi
  if grep -q '`ws://\${tailnetIPv4}:\${port}`' "$file" 2>/dev/null; then
    sed -i.bak 's|`ws://\${tailnetIPv4}:\${port}`|`\${cfg.gateway?.tls?.enabled ? "wss" : "ws"}://\${tailnetIPv4}:\${port}`|g' "$file"
    rm -f "${file}.bak"
    changed=true
  fi

  # SSH tunnel URL
  if grep -q 'url: `ws://127.0.0.1:\${tunnel.localPort}`' "$file" 2>/dev/null; then
    sed -i.bak 's|url: `ws://127\.0\.0\.1:\${tunnel\.localPort}`|url: `\${cfg.gateway?.tls?.enabled ? "wss" : "ws"}://127.0.0.1:\${tunnel.localPort}`|g' "$file"
    rm -f "${file}.bak"
    changed=true
  fi

  # Discovery beacon wsUrl
  if grep -q 'return host ? `ws://\${host}:\${port}` : null' "$file" 2>/dev/null; then
    sed -i.bak 's|return host ? `ws://\${host}:\${port}` : null|const _s = cfg.gateway?.tls?.enabled ? "wss" : "ws"; return host ? `\${_s}://\${host}:\${port}` : null|g' "$file"
    rm -f "${file}.bak"
    changed=true
  fi

  # discover --json wsUrl (register.ts compiled)
  if grep -q 'wsUrl: host ? `ws://\${host}:\${port}` : null' "$file" 2>/dev/null; then
    sed -i.bak 's|wsUrl: host ? `ws://\${host}:\${port}` : null|wsUrl: (() => { const _s = cfg.gateway?.tls?.enabled ? "wss" : "ws"; return host ? `\${_s}://\${host}:\${port}` : null; })()|g' "$file"
    rm -f "${file}.bak"
    changed=true
  fi

  if [ "$changed" = true ]; then
    ok "$name: patched"
    APPLIED=$((APPLIED + 1))
  else
    warn "$name: no matching patterns"
    SKIPPED=$((SKIPPED + 1))
  fi
}

# Apply to daemon-cli files
for f in "$DIST"/daemon-cli*.js; do
  [ -f "$f" ] && patch_daemon_cli "$f"
done

# Apply to gateway-cli files
for f in "$DIST"/gateway-cli*.js; do
  [ -f "$f" ] && patch_gateway_cli "$f"
done

# ─────────────────────────────────────────────────────────────────────
# PATCH 2: GatewayClient self-signed cert acceptance (PR #22682)
# ─────────────────────────────────────────────────────────────────────
echo ""
echo "-- Patch 2: GatewayClient self-signed cert fix (PR #22682) --"

for client_file in "$DIST"/client-*.js; do
  [ -f "$client_file" ] || continue
  name="$(basename "$client_file")"

  # Check for any variant of our patch (with or without fingerprint guard)
  if grep -q 'else if (url.startsWith("wss://")' "$client_file" 2>/dev/null; then
    ok "$name: already patched"
    SKIPPED=$((SKIPPED + 1))
    continue
  fi

  if ! grep -q 'if (url.startsWith("wss://") && this.opts.tlsFingerprint)' "$client_file" 2>/dev/null; then
    warn "$name: pattern not found"
    SKIPPED=$((SKIPPED + 1))
    continue
  fi

  # Use node for reliable multi-line patching
  node -e "
    const fs = require('fs');
    let code = fs.readFileSync('$client_file', 'utf8');
    const marker = '}) as any;';
    const search = marker + '\n\t\t}';
    const replace = marker + '\n\t\t} else if (url.startsWith(\"wss://\")) {\n\t\t\twsOptions.rejectUnauthorized = false;\n\t\t}';
    if (code.includes('else if (url.startsWith(\"wss://\"))')) { process.exit(0); }
    // Try tab-indented variant
    if (code.includes(search)) {
      code = code.replace(search, replace);
    } else {
      // Try single-tab variant
      const s2 = marker + '\n\t}';
      const r2 = marker + '\n\t} else if (url.startsWith(\"wss://\")) {\n\t\twsOptions.rejectUnauthorized = false;\n\t}';
      code = code.replace(s2, r2);
    }
    fs.writeFileSync('$client_file', code);
  "

  if grep -q 'else if (url.startsWith("wss://"))' "$client_file" 2>/dev/null; then
    ok "$name: patched"
    APPLIED=$((APPLIED + 1))
  else
    fail "$name: patch did not apply cleanly"
    FAILED=$((FAILED + 1))
  fi
done

# ─────────────────────────────────────────────────────────────────────
# PATCH 3: LanceDB missing dependencies (PR #22692)
# ─────────────────────────────────────────────────────────────────────
echo ""
echo "-- Patch 3: LanceDB missing runtime deps (PR #22692) --"

if [ ! -d "$OPENCLAW_ROOT/extensions/memory-lancedb" ]; then
  warn "memory-lancedb extension not found, skipping"
  SKIPPED=$((SKIPPED + 1))
elif [ -d "$EXT/@lancedb/lancedb/node_modules/apache-arrow" ] || [ -d "$EXT/apache-arrow" ]; then
  ok "LanceDB deps: already installed"
  SKIPPED=$((SKIPPED + 1))
else
  echo "   Installing missing LanceDB dependencies..."

  TMPDIR_LANCE=$(mktemp -d)

  (
    cd "$TMPDIR_LANCE"
    npm init -y --silent >/dev/null 2>&1

    # Detect platform native binding name
    NATIVE_PKG="@lancedb/lancedb-$(node -e "
      const p = process.platform === 'darwin' ? 'darwin' : process.platform === 'win32' ? 'win32' : 'linux';
      const a = process.arch === 'arm64' ? 'arm64' : 'x64';
      const s = p === 'win32' ? 'msvc' : p === 'darwin' ? '' : 'gnu';
      console.log([p,a,s].filter(Boolean).join('-'));
    ")"

    npm install --silent \
      "apache-arrow@18.1.0" \
      "flatbuffers@^24.3.25" \
      "reflect-metadata@^0.2.2" \
      "${NATIVE_PKG}@0.26.2" 2>/dev/null
  )

  # Copy .ignored lancedb to proper path if needed
  if [ -d "$EXT/.ignored/@lancedb/lancedb" ] && [ ! -d "$EXT/@lancedb/lancedb" ]; then
    mkdir -p "$EXT/@lancedb"
    cp -RL "$EXT/.ignored/@lancedb/lancedb" "$EXT/@lancedb/lancedb"
    ok "Copied lancedb from .ignored/ to proper path"
  fi

  LANCE_NM="$EXT/@lancedb/lancedb/node_modules"
  if [ -d "$EXT/@lancedb/lancedb" ]; then
    mkdir -p "$LANCE_NM/@lancedb"

    for dep in apache-arrow flatbuffers reflect-metadata; do
      if [ -d "$TMPDIR_LANCE/node_modules/$dep" ]; then
        cp -r "$TMPDIR_LANCE/node_modules/$dep" "$LANCE_NM/"
        ok "Installed $dep"
      fi
    done

    for native_dir in "$TMPDIR_LANCE"/node_modules/@lancedb/lancedb-*; do
      [ -d "$native_dir" ] || continue
      cp -r "$native_dir" "$LANCE_NM/@lancedb/"
      ok "Installed $(basename "$native_dir")"
    done

    # Patch exports field
    LANCE_PKG="$EXT/@lancedb/lancedb/package.json"
    if [ -f "$LANCE_PKG" ] && ! grep -q '"./dist/arrow"' "$LANCE_PKG" 2>/dev/null; then
      node -e "
        const fs = require('fs');
        const pkg = JSON.parse(fs.readFileSync('$LANCE_PKG', 'utf8'));
        if (pkg.exports && !pkg.exports['./dist/arrow']) {
          pkg.exports['./dist/arrow'] = './dist/arrow.js';
          fs.writeFileSync('$LANCE_PKG', JSON.stringify(pkg, null, 2));
        }
      " && ok "Patched exports field (./dist/arrow)"
    fi

    APPLIED=$((APPLIED + 1))
  else
    fail "Could not find @lancedb/lancedb module"
    FAILED=$((FAILED + 1))
  fi

  rm -rf "$TMPDIR_LANCE"
fi

# ─────────────────────────────────────────────────────────────────────
# Summary
# ─────────────────────────────────────────────────────────────────────
echo ""
echo "-- Dist Patches Summary --"
echo -e "   Applied: ${GREEN}${APPLIED}${NC}  Skipped: ${YELLOW}${SKIPPED}${NC}  Failed: ${RED}${FAILED}${NC}"

exit $FAILED
