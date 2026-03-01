#!/usr/bin/env bash
set -euo pipefail

# migrate-to-symlink.sh — One-time migration to versioned dist + symlink swap
# Moves current dist/ into dist-versions/ and creates dist-active symlink.
# Gateway must be stopped during this step.

OPENCLAW_ROOT="/opt/homebrew/lib/node_modules/openclaw"
DIST="$OPENCLAW_ROOT/dist"
VERSIONS_DIR="$OPENCLAW_ROOT/dist-versions"
VERSION=$(node -e "console.log(require('$OPENCLAW_ROOT/package.json').version)" 2>/dev/null || echo "unknown")

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
echo -e "${CYAN}Patchkit v2 Migration: Symlink Dist Setup${NC}"
echo "  OpenClaw root: $OPENCLAW_ROOT"
echo "  Current version: $VERSION"
echo ""

# Pre-checks
if [ -L "$OPENCLAW_ROOT/dist-active" ]; then
  ok "dist-active symlink already exists — migration already done"
  ls -la "$OPENCLAW_ROOT/dist-active"
  exit 0
fi

if [ ! -d "$DIST" ]; then
  fail "dist/ not found at $DIST"
  exit 1
fi

if [ ! -f "$DIST/index.js" ]; then
  fail "dist/index.js not found — dist appears broken"
  exit 1
fi

# Confirm gateway is stopped
if pgrep -x "openclaw-gateway" > /dev/null 2>&1; then
  warn "Gateway is running. Stop it first:"
  echo "  launchctl bootout gui/\$(id -u)/ai.openclaw.gateway 2>/dev/null || true"
  echo ""
  read -p "Continue anyway? (y/N) " -n 1 -r
  echo
  [[ $REPLY =~ ^[Yy]$ ]] || exit 1
fi

# Create versions dir
info "Creating dist-versions/"
sudo mkdir -p "$VERSIONS_DIR"
sudo chown "$(whoami):staff" "$VERSIONS_DIR"

# Move current dist to versioned directory
TARGET="$VERSIONS_DIR/v${VERSION}-patched"
if [ -d "$TARGET" ]; then
  warn "Target $TARGET already exists, adding timestamp"
  TARGET="${TARGET}-$(date +%s)"
fi

info "Moving dist/ → dist-versions/v${VERSION}-patched/"
sudo mv "$DIST" "$TARGET"

# Create dist-active symlink
info "Creating dist-active → v${VERSION}-patched/"
sudo ln -sfn "$TARGET" "$OPENCLAW_ROOT/dist-active"

# Create backward-compat dist → dist-active symlink
info "Creating dist → dist-active (backward compat)"
sudo ln -sfn "$OPENCLAW_ROOT/dist-active" "$DIST"

ok "Migration complete"
echo ""
echo "  dist/ → dist-active → dist-versions/v${VERSION}-patched/"
echo ""
echo "  Verify: ls -la $OPENCLAW_ROOT/dist"
echo "  Verify: ls -la $OPENCLAW_ROOT/dist-active"
