#!/usr/bin/env bash
set -euo pipefail

# ─────────────────────────────────────────────────────────────────────────────
# OpenClaw Post-Build Patches (Phase 2)
# Applies dist-level fixes + LanceDB deps + cognitive-memory in a single pass.
# Called by patch-openclaw.sh as Phase 2 (requires sudo).
#
# Patches:
#   1. TLS probe URLs          — ws:// → wss:// when TLS enabled (PR #22682)
#   2. Self-signed cert        — rejectUnauthorized for wss:// (PR #22682)
#   3. LanceDB dependencies    — native bindings for memory extension (PR #22692)
#   4. Cognitive memory        — activation scoring, decay, semantic dedup
#
# Usage: sudo bash dist-patches.sh
# Exit code = number of failed patches (0 = all OK)
# ─────────────────────────────────────────────────────────────────────────────

# npm root -g can resolve to Cellar symlink; prefer /opt/homebrew/lib if it exists
_npm_root="$(npm root -g)/openclaw"
if [ -d "/opt/homebrew/lib/node_modules/openclaw/dist" ]; then
  OPENCLAW_ROOT="/opt/homebrew/lib/node_modules/openclaw"
elif [ -d "$_npm_root/dist" ]; then
  OPENCLAW_ROOT="$_npm_root"
else
  echo "ERROR: Cannot find OpenClaw dist directory" >&2
  exit 1
fi
DIST="$OPENCLAW_ROOT/dist"
EXT_DIR="$HOME/.openclaw/extensions/memory-lancedb"
PATCHES_DIR="$(cd "$(dirname "$0")" && pwd)"
BACKUP_DIR="$PATCHES_DIR/manual-patches/cognitive-memory-backup"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

ok()   { echo -e "${GREEN}[OK]${NC} $1"; }
warn() { echo -e "${YELLOW}[!!]${NC} $1"; }
fail() { echo -e "${RED}[FAIL]${NC} $1"; }
info() { echo -e "${CYAN}[..]${NC} $1"; }

echo ""
echo -e "${CYAN}OpenClaw Post-Build Patches${NC}"
echo "  Version: $(openclaw --version 2>/dev/null || echo 'unknown')"
echo "  Dist:    $DIST"
echo ""

APPLIED=0
SKIPPED=0
FAILED=0

# ─────────────────────────────────────────────────────────────────────
# PATCH 1: TLS-aware probe URLs (PR #22682)
# Dynamic: finds files by grep, not hardcoded names
# ─────────────────────────────────────────────────────────────────────
echo "-- Patch 1: Gateway TLS probe URLs --"

TLS_NEEDED=0
TLS_DONE=0

for f in "$DIST"/daemon-cli*.js "$DIST"/gateway-cli*.js; do
  [ -f "$f" ] || continue
  name="$(basename "$f")"

  # Already patched by Phase 1 rebuild?
  if grep -q 'tls?.enabled.*"wss"' "$f" 2>/dev/null; then
    ok "$name: already patched (from rebuild)"
    SKIPPED=$((SKIPPED + 1))
    TLS_DONE=$((TLS_DONE + 1))
    continue
  fi

  # Has unpatched ws:// probe URL?
  if grep -q 'probeUrlOverride.*`ws://' "$f" 2>/dev/null || \
     grep -q 'url: `ws://127' "$f" 2>/dev/null || \
     grep -q 'localLoopbackUrl: `ws://' "$f" 2>/dev/null; then
    TLS_NEEDED=$((TLS_NEEDED + 1))

    # Apply sed patches (same logic as before but dynamic)
    if sed -i.bak \
      -e 's|probeUrlOverride ?? `ws://\${probeHost}:\${daemonPort}`|probeUrlOverride ?? `\${daemonCfg.gateway?.tls?.enabled ? "wss" : "ws"}://\${probeHost}:\${daemonPort}`|g' \
      -e 's|url: `ws://127\.0\.0\.1:\${resolveGatewayPort(cfg)}`|url: `\${cfg.gateway?.tls?.enabled ? "wss" : "ws"}://127.0.0.1:\${resolveGatewayPort(cfg)}`|g' \
      -e 's|localLoopbackUrl: `ws://127\.0\.0\.1:\${port}`|localLoopbackUrl: `\${cfg.gateway?.tls?.enabled ? "wss" : "ws"}://127.0.0.1:\${port}`|g' \
      -e 's|`ws://\${tailnetIPv4}:\${port}`|`\${cfg.gateway?.tls?.enabled ? "wss" : "ws"}://\${tailnetIPv4}:\${port}`|g' \
      -e 's|url: `ws://127\.0\.0\.1:\${tunnel\.localPort}`|url: `\${cfg.gateway?.tls?.enabled ? "wss" : "ws"}://127.0.0.1:\${tunnel.localPort}`|g' \
      "$f" 2>/dev/null; then
      rm -f "${f}.bak"
      ok "$name: patched"
      APPLIED=$((APPLIED + 1))
    else
      rm -f "${f}.bak"
      fail "$name: sed patch failed"
      FAILED=$((FAILED + 1))
    fi
  else
    ok "$name: no ws:// patterns (clean)"
    SKIPPED=$((SKIPPED + 1))
  fi
done

if [ $TLS_DONE -gt 0 ] && [ $TLS_NEEDED -eq 0 ]; then
  info "TLS probe: all files already patched by Phase 1 rebuild"
fi

# ─────────────────────────────────────────────────────────────────────
# PATCH 1b: Carbon GatewayPlugin uncaught exception fix (FIX-A2)
# @buape/carbon emits "error" on EventEmitter without a handler,
# causing Node.js uncaught exception on max reconnect attempts.
# This registers a default no-op error handler to prevent the crash.
# ─────────────────────────────────────────────────────────────────────
echo ""
echo "-- Patch 1b: Carbon GatewayPlugin error handler (FIX-A2) --"

CARBON_GW="$OPENCLAW_ROOT/node_modules/@buape/carbon/dist/src/plugins/gateway/GatewayPlugin.js"
if [ ! -f "$CARBON_GW" ]; then
  warn "Carbon GatewayPlugin.js not found, skipping"
  SKIPPED=$((SKIPPED + 1))
elif grep -q 'FIX-A2' "$CARBON_GW" 2>/dev/null; then
  ok "Carbon GatewayPlugin.js: already patched"
  SKIPPED=$((SKIPPED + 1))
else
  if sed -i.bak \
    's|this.emitter = new EventEmitter();|this.emitter = new EventEmitter(); this.emitter.on("error", () => {}); /* FIX-A2: prevent uncaught exception */|' \
    "$CARBON_GW" 2>/dev/null; then
    rm -f "${CARBON_GW}.bak"
    if grep -q 'FIX-A2' "$CARBON_GW" 2>/dev/null; then
      ok "Carbon GatewayPlugin.js: patched (no-op error handler)"
      APPLIED=$((APPLIED + 1))
    else
      fail "Carbon GatewayPlugin.js: sed ran but pattern not found"
      FAILED=$((FAILED + 1))
    fi
  else
    rm -f "${CARBON_GW}.bak"
    fail "Carbon GatewayPlugin.js: sed patch failed"
    FAILED=$((FAILED + 1))
  fi
fi

# ─────────────────────────────────────────────────────────────────────
# PATCH 2: Self-signed cert acceptance for wss:// (PR #22682)
# Adds rejectUnauthorized=false for wss:// connections without fingerprint
# ─────────────────────────────────────────────────────────────────────
echo ""
echo "-- Patch 2: Self-signed cert for wss:// --"

for client_file in "$DIST"/client-*.js; do
  [ -f "$client_file" ] || continue
  name="$(basename "$client_file")"

  # Already has our else-if clause?
  if grep -q 'else if (url.startsWith("wss://"))' "$client_file" 2>/dev/null; then
    ok "$name: already patched"
    SKIPPED=$((SKIPPED + 1))
    continue
  fi

  # Has the fingerprint guard block? (our injection point)
  if ! grep -q 'if (url.startsWith("wss://") && this.opts.tlsFingerprint)' "$client_file" 2>/dev/null; then
    # Phase 1 rebuild may have changed the structure — check if rejectUnauthorized exists at all
    if grep -q 'rejectUnauthorized' "$client_file" 2>/dev/null; then
      ok "$name: cert handling present (from rebuild)"
      SKIPPED=$((SKIPPED + 1))
    else
      warn "$name: no cert handling found"
      SKIPPED=$((SKIPPED + 1))
    fi
    continue
  fi

  # Apply the else-if patch using node for reliable multi-line matching
  # Note: || true prevents set -e from killing the script if pattern not found
  CERT_APPLIED=false
  node -e "
    const fs = require('fs');
    let code = fs.readFileSync('$client_file', 'utf8');
    const variants = [
      { search: '}) as any;\\n\\t\\t}', replace: '}) as any;\\n\\t\\t} else if (url.startsWith(\"wss://\")) {\\n\\t\\t\\twsOptions.rejectUnauthorized = false;\\n\\t\\t}' },
      { search: '}) as any;\\n\\t}', replace: '}) as any;\\n\\t} else if (url.startsWith(\"wss://\")) {\\n\\t\\twsOptions.rejectUnauthorized = false;\\n\\t}' },
    ];
    let applied = false;
    for (const v of variants) {
      if (code.includes(v.search)) {
        code = code.replace(v.search, v.replace);
        applied = true;
        break;
      }
    }
    if (applied) fs.writeFileSync('$client_file', code);
    process.exit(applied ? 0 : 1);
  " 2>/dev/null && CERT_APPLIED=true || true

  if [ "$CERT_APPLIED" = true ] && grep -q 'else if (url.startsWith("wss://"))' "$client_file" 2>/dev/null; then
    ok "$name: patched"
    APPLIED=$((APPLIED + 1))
  else
    # FIX-A3 source patch should have added the else-if; if not, add via dist
    # Try alternate injection: after the closing brace of the fingerprint block
    node -e "
      const fs = require('fs');
      let code = fs.readFileSync('$client_file', 'utf8');
      // Find the fingerprint guard closing pattern and add else-if
      const patterns = [
        { s: /(\t\t\})\n(\t\tconst ws)/,  r: '\$1 else if (url.startsWith(\"wss://\")) {\n\t\t\twsOptions.rejectUnauthorized = false;\n\t\t}\n\$2' },
        { s: /(\t\})\n(\t\tconst ws)/,     r: '\$1 else if (url.startsWith(\"wss://\")) {\n\t\twsOptions.rejectUnauthorized = false;\n\t}\n\$2' },
      ];
      let applied = false;
      for (const p of patterns) {
        if (p.s.test(code)) { code = code.replace(p.s, p.r); applied = true; break; }
      }
      if (applied) fs.writeFileSync('$client_file', code);
      process.exit(applied ? 0 : 1);
    " 2>/dev/null && {
      ok "$name: patched (alt injection)"
      APPLIED=$((APPLIED + 1))
    } || {
      warn "$name: fingerprint guard present but else-if injection failed"
      SKIPPED=$((SKIPPED + 1))
    }
  fi
done

# ─────────────────────────────────────────────────────────────────────
# PATCH 3: LanceDB native dependencies (PR #22692)
# Installs @lancedb/lancedb + native bindings into extension node_modules
# ─────────────────────────────────────────────────────────────────────
echo ""
echo "-- Patch 3: LanceDB native dependencies --"

if [ ! -d "$EXT_DIR" ]; then
  warn "memory-lancedb extension not found, skipping"
  SKIPPED=$((SKIPPED + 1))
else
  EXT_NM="$EXT_DIR/node_modules"

  # Test if LanceDB can actually be imported FROM the extension dir
  # (must match Phase 4 verification which also tests from extension dir)
  LANCE_WORKS=false
  if (cd "$EXT_DIR" && node -e "import('@lancedb/lancedb').then(() => process.exit(0)).catch(() => process.exit(1))" 2>/dev/null); then
    LANCE_WORKS=true
  fi

  if [ "$LANCE_WORKS" = true ]; then
    ok "LanceDB: already installed and importable"
    SKIPPED=$((SKIPPED + 1))
  else
    info "LanceDB: installing dependencies..."

    # Detect platform native binding
    NATIVE_PKG=$(node -e "
      const p = process.platform === 'darwin' ? 'darwin' : process.platform === 'win32' ? 'win32' : 'linux';
      const a = process.arch === 'arm64' ? 'arm64' : 'x64';
      console.log('@lancedb/lancedb-' + p + '-' + a);
    " 2>/dev/null || echo "@lancedb/lancedb-darwin-arm64")

    # Get required version from extension's package.json
    LANCE_VER=$(node -e "
      const pkg = require('$EXT_DIR/package.json');
      console.log(pkg.dependencies['@lancedb/lancedb'] || '^0.26.2');
    " 2>/dev/null || echo "^0.26.2")

    info "Target: @lancedb/lancedb@$LANCE_VER + $NATIVE_PKG"

    # Install directly into extension node_modules
    LANCE_INSTALL_OK=false
    (
      cd "$EXT_DIR"
      npm install --no-save --no-audit --no-fund \
        "@lancedb/lancedb@$LANCE_VER" \
        "$NATIVE_PKG@${LANCE_VER#^}" \
        "apache-arrow@>=17.0.0" \
        "flatbuffers@>=24.0.0" 2>&1 | tail -3
    ) && LANCE_INSTALL_OK=true

    if [ "$LANCE_INSTALL_OK" = true ]; then
      # Verify import works
      if (cd "$EXT_DIR" && node -e "import('@lancedb/lancedb').then(() => { console.log('LanceDB import OK'); process.exit(0); }).catch(e => { console.error('Import failed:', e.message); process.exit(1); })" 2>&1); then
        ok "LanceDB: installed and verified"
        APPLIED=$((APPLIED + 1))
      else
        warn "LanceDB: installed but import verification failed"
        APPLIED=$((APPLIED + 1))
      fi
    else
      fail "LanceDB: npm install failed"
      FAILED=$((FAILED + 1))
    fi
  fi
fi

# ─────────────────────────────────────────────────────────────────────
# PATCH 4: Cognitive Memory Enhancement
# Activation scoring, confidence gating, semantic dedup, category decay
# ─────────────────────────────────────────────────────────────────────
echo ""
echo "-- Patch 4: Cognitive memory enhancement --"

if [ ! -d "$EXT_DIR" ]; then
  warn "memory-lancedb extension not found, skipping"
  SKIPPED=$((SKIPPED + 1))
elif [ ! -d "$BACKUP_DIR" ]; then
  fail "Cognitive memory backup dir not found: $BACKUP_DIR"
  FAILED=$((FAILED + 1))
else
  CM_INDEX="$EXT_DIR/index.ts"
  CM_CONFIG="$EXT_DIR/config.ts"

  # Check if already applied (accessCount is a unique marker)
  if grep -q 'accessCount' "$CM_INDEX" 2>/dev/null; then
    ok "Cognitive memory: already applied"
    SKIPPED=$((SKIPPED + 1))
  else
    # Backup originals if not already backed up
    if [ ! -f "$BACKUP_DIR/index.ts.original" ]; then
      mkdir -p "$BACKUP_DIR" 2>/dev/null || true
      cp "$CM_INDEX" "$BACKUP_DIR/index.ts.original" 2>/dev/null || true
      [ -f "$CM_CONFIG" ] && cp "$CM_CONFIG" "$BACKUP_DIR/config.ts.original" 2>/dev/null || true
      info "Backed up originals"
    fi

    # Apply patched versions
    CM_OK=true
    if [ -f "$BACKUP_DIR/index.ts.patched" ]; then
      cp "$BACKUP_DIR/index.ts.patched" "$CM_INDEX" || CM_OK=false
    else
      fail "Missing: $BACKUP_DIR/index.ts.patched"
      CM_OK=false
    fi

    if [ -f "$BACKUP_DIR/config.ts.patched" ]; then
      cp "$BACKUP_DIR/config.ts.patched" "$CM_CONFIG" || CM_OK=false
    fi

    if [ "$CM_OK" = true ] && grep -q 'accessCount' "$CM_INDEX" 2>/dev/null; then
      ok "Cognitive memory: applied (activation, decay, dedup, gating)"
      APPLIED=$((APPLIED + 1))
    else
      fail "Cognitive memory: patch application failed"
      FAILED=$((FAILED + 1))
    fi
  fi
fi

# ─────────────────────────────────────────────────────────────────────
# PATCH 5: Disable #28258 stream wrapper (safety net)
# wrapAnthropicStreamWithRecovery strips response.result() from the
# stream object, causing agent-loop.js:187 crash-loop.
# This patch comments out the wrapper call if present in any dist file.
# ─────────────────────────────────────────────────────────────────────
echo ""
echo "-- Patch 5: Disable #28258 stream wrapper (safety net) --"

P5_DISABLED=0
P5_CLEAN=0
WRAPPER_PATTERN='if (params.provider === "anthropic") activeSession.agent.streamFn = wrapAnthropicStreamWithRecovery'
WRAPPER_DISABLED='/* DISABLED #28258 */ //'

for f in "$DIST"/*.js; do
  [ -f "$f" ] || continue
  if grep -q "$WRAPPER_PATTERN" "$f" 2>/dev/null; then
    # Check if already disabled
    if grep -q "DISABLED #28258" "$f" 2>/dev/null; then
      P5_CLEAN=$((P5_CLEAN + 1))
      continue
    fi
    sed -i.bak "s|$WRAPPER_PATTERN|$WRAPPER_DISABLED $WRAPPER_PATTERN|g" "$f" 2>/dev/null
    rm -f "${f}.bak"
    P5_DISABLED=$((P5_DISABLED + 1))
  fi
done

if [ $P5_DISABLED -gt 0 ]; then
  ok "#28258 wrapper disabled in $P5_DISABLED file(s)"
  APPLIED=$((APPLIED + P5_DISABLED))
elif [ $P5_CLEAN -gt 0 ]; then
  ok "#28258 wrapper: already disabled ($P5_CLEAN files)"
  SKIPPED=$((SKIPPED + 1))
else
  ok "#28258 wrapper: not present in dist (clean)"
  SKIPPED=$((SKIPPED + 1))
fi

# ─────────────────────────────────────────────────────────────────────
# Patch 6: Fix session-recovery dropping valid messages with unsigned thinking
# Root cause: Sonnet 4.6 low-thinking sends thinking blocks without 'signature'
# field. assessLastAssistantMessage() treats these as "incomplete-thinking" and
# drops the entire assistant message — causing Oracle to re-answer questions.
# Fix: Only drop if unsigned thinking exists WITHOUT any non-thinking content.
# ─────────────────────────────────────────────────────────────────────

echo "-- Patch 6: Fix unsigned thinking drop (repeat-answer bug) --"

P6_FIXED=0
P6_CLEAN=0
HELPERS_PATTERN='if (hasUnsignedThinking) return "incomplete-thinking";'
HELPERS_FIXED='if (hasUnsignedThinking \&\& !hasNonThinkingContent) return "incomplete-thinking";'

for f in "$DIST"/pi-embedded-helpers-*.js; do
  [ -f "$f" ] || continue
  if grep -qF 'if (hasUnsignedThinking) return "incomplete-thinking";' "$f" 2>/dev/null; then
    sed -i.bak 's/if (hasUnsignedThinking) return "incomplete-thinking";/if (hasUnsignedThinking \&\& !hasNonThinkingContent) return "incomplete-thinking";/g' "$f" 2>/dev/null
    rm -f "${f}.bak"
    P6_FIXED=$((P6_FIXED + 1))
  elif grep -qF 'hasUnsignedThinking && !hasNonThinkingContent' "$f" 2>/dev/null; then
    P6_CLEAN=$((P6_CLEAN + 1))
  fi
done

if [ $P6_FIXED -gt 0 ]; then
  ok "Unsigned thinking drop fixed in $P6_FIXED file(s)"
  APPLIED=$((APPLIED + P6_FIXED))
elif [ $P6_CLEAN -gt 0 ]; then
  ok "Unsigned thinking fix: already applied ($P6_CLEAN files)"
  SKIPPED=$((SKIPPED + 1))
else
  warn "Unsigned thinking pattern not found in dist"
  SKIPPED=$((SKIPPED + 1))
fi

# ─────────────────────────────────────────────────────────────────────
# Summary
# ─────────────────────────────────────────────────────────────────────
echo ""
echo "-- Post-Build Patches Summary --"
echo -e "   Applied: ${GREEN}${APPLIED}${NC}  Skipped: ${YELLOW}${SKIPPED}${NC}  Failed: ${RED}${FAILED}${NC}"

if [ $FAILED -eq 0 ]; then
  echo -e "   ${GREEN}All patches OK${NC}"
fi

exit $FAILED
