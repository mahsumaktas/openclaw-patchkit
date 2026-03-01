#!/usr/bin/env bash
set -euo pipefail

# ─────────────────────────────────────────────────────────────────────────────
# OpenClaw Upgrade Pipeline v2
#
# Single-command upgrade with sandbox build, atomic swap, and health probe.
# Replaces: patch-openclaw.sh + dist-patches.sh + pre-upgrade-check.sh
#
# Usage:
#   upgrade-openclaw.sh v2026.2.27              # Full upgrade
#   upgrade-openclaw.sh v2026.2.27 --dry-run    # Analyze only
#   upgrade-openclaw.sh --rollback              # Revert to previous version
#   upgrade-openclaw.sh --status                # Show current state
#   upgrade-openclaw.sh --list-versions         # Show available rollback targets
#
# Requires: git, node, pnpm, gh (GitHub CLI)
# ─────────────────────────────────────────────────────────────────────────────

PATCHES_DIR="$(cd "$(dirname "$0")" && pwd)"
OPENCLAW_ROOT="/opt/homebrew/lib/node_modules/openclaw"
VERSIONS_DIR="$OPENCLAW_ROOT/dist-versions"
ACTIVE_LINK="$OPENCLAW_ROOT/dist-active"
CONF="$PATCHES_DIR/pr-patches.conf"
REPO="https://github.com/openclaw/openclaw.git"
LOG_FILE="$PATCHES_DIR/upgrade-log.jsonl"
NOTIFY_SCRIPT="$PATCHES_DIR/notify.sh"
RUNTIME_PATCHES="$PATCHES_DIR/runtime-patches"

CURRENT_VERSION=$(node -e "console.log(require('$OPENCLAW_ROOT/package.json').version)" 2>/dev/null || echo "unknown")

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

ok()   { echo -e "${GREEN}[OK]${NC} $1"; }
warn() { echo -e "${YELLOW}[!!]${NC} $1"; }
fail() { echo -e "${RED}[FAIL]${NC} $1"; }
info() { echo -e "${CYAN}[..]${NC} $1"; }
step() { echo -e "\n${BOLD}${CYAN}── $1 ──${NC}"; }

# ── Parse args ───────────────────────────────────────────────────────────────
TARGET_TAG=""
DRY_RUN=false
ROLLBACK=false
SHOW_STATUS=false
LIST_VERSIONS=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run)       DRY_RUN=true; shift ;;
    --rollback)      ROLLBACK=true; shift ;;
    --status)        SHOW_STATUS=true; shift ;;
    --list-versions) LIST_VERSIONS=true; shift ;;
    v*)              TARGET_TAG="$1"; shift ;;
    *)               echo "Usage: upgrade-openclaw.sh [vX.Y.Z] [--dry-run|--rollback|--status|--list-versions]"; exit 1 ;;
  esac
done

# ── --status ─────────────────────────────────────────────────────────────────
if [ "$SHOW_STATUS" = true ]; then
  echo -e "${CYAN}Patchkit v2 Status${NC}"
  echo "  Current version: $CURRENT_VERSION"
  if [ -L "$ACTIVE_LINK" ]; then
    echo "  Active dist: $(readlink "$ACTIVE_LINK")"
  fi
  echo "  Versions available:"
  ls -1 "$VERSIONS_DIR" 2>/dev/null | while read -r v; do
    if [ "$(readlink "$ACTIVE_LINK" 2>/dev/null)" = "$VERSIONS_DIR/$v" ]; then
      echo "    * $v (ACTIVE)"
    else
      echo "      $v"
    fi
  done
  echo "  Runtime patches: $(ls "$RUNTIME_PATCHES"/*.js 2>/dev/null | wc -l | tr -d ' ') loaded"
  echo "  Active PR patches: $(grep -cE '^[0-9]' "$CONF" 2>/dev/null || echo 0)"
  if [ -f "$LOG_FILE" ]; then
    echo "  Last upgrade: $(tail -1 "$LOG_FILE" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('timestamp','unknown') + ' → ' + d.get('target','unknown'))" 2>/dev/null || echo 'unknown')"
  fi
  exit 0
fi

# ── --list-versions ──────────────────────────────────────────────────────────
if [ "$LIST_VERSIONS" = true ]; then
  ls -1t "$VERSIONS_DIR" 2>/dev/null || echo "No versions found"
  exit 0
fi

# ── --rollback ───────────────────────────────────────────────────────────────
if [ "$ROLLBACK" = true ]; then
  step "Rollback"
  CURRENT_ACTIVE="$(readlink "$ACTIVE_LINK" 2>/dev/null || echo '')"
  CURRENT_NAME="$(basename "$CURRENT_ACTIVE")"

  # Find previous version (not current)
  PREV=""
  for v in $(ls -1t "$VERSIONS_DIR" 2>/dev/null); do
    if [ "$VERSIONS_DIR/$v" != "$CURRENT_ACTIVE" ]; then
      PREV="$VERSIONS_DIR/$v"
      break
    fi
  done

  if [ -z "$PREV" ]; then
    fail "No previous version found for rollback"
    exit 1
  fi

  info "Rolling back: $CURRENT_NAME → $(basename "$PREV")"
  sudo ln -sfn "$PREV" "${ACTIVE_LINK}-tmp"
  sudo mv "${ACTIVE_LINK}-tmp" "$ACTIVE_LINK"
  ok "Symlink updated"

  info "Restarting gateway..."
  launchctl kickstart -k "gui/$(id -u)/ai.openclaw.gateway" 2>/dev/null || \
    warn "Could not restart gateway — restart manually"

  ok "Rollback complete → $(basename "$PREV")"

  # Log
  echo "{\"timestamp\":\"$(date -u +%Y-%m-%dT%H:%M:%SZ)\",\"action\":\"rollback\",\"from\":\"$CURRENT_NAME\",\"to\":\"$(basename "$PREV")\"}" >> "$LOG_FILE"
  exit 0
fi

# ── Upgrade requires target tag ──────────────────────────────────────────────
if [ -z "$TARGET_TAG" ]; then
  echo "Usage: upgrade-openclaw.sh v2026.2.27 [--dry-run]"
  exit 1
fi

TARGET_VERSION="${TARGET_TAG#v}"
SANDBOX="/tmp/openclaw-upgrade-$(date +%s)"
START_TIME=$(date +%s)

echo ""
echo -e "${BOLD}${CYAN}OpenClaw Upgrade Pipeline v2${NC}"
echo "  Current: v$CURRENT_VERSION"
echo "  Target:  $TARGET_TAG"
echo "  Sandbox: $SANDBOX"
echo "  Dry run: $DRY_RUN"
echo ""

# ═══════════════════════════════════════════════════════════════════════════
# PHASE 1: PRE-FLIGHT
# ═══════════════════════════════════════════════════════════════════════════
step "Phase 1: Pre-flight Analysis"

PATCH_CLEAN=0
PATCH_CONFLICT=0
PATCH_MERGED=0
PATCH_FIX=0

# Get changed files between versions
info "Fetching upstream changes: v$CURRENT_VERSION → $TARGET_TAG"
CHANGED_FILES_CACHE="$SANDBOX-changes.txt"
mkdir -p "$(dirname "$CHANGED_FILES_CACHE")"

gh api "repos/openclaw/openclaw/compare/v${CURRENT_VERSION}...${TARGET_TAG}" \
  --jq '.files[].filename' > "$CHANGED_FILES_CACHE" 2>/dev/null || {
  warn "GitHub Compare API failed or >300 files — using git fallback"
  FALLBACK_DIR="/tmp/openclaw-compare-$$"
  git clone --depth 1 --branch "v$CURRENT_VERSION" "$REPO" "$FALLBACK_DIR/old" 2>/dev/null
  git clone --depth 1 --branch "$TARGET_TAG" "$REPO" "$FALLBACK_DIR/new" 2>/dev/null
  diff -rq "$FALLBACK_DIR/old/src" "$FALLBACK_DIR/new/src" 2>/dev/null | \
    sed 's|.*src/|src/|' | awk '{print $1}' > "$CHANGED_FILES_CACHE" || true
  rm -rf "$FALLBACK_DIR"
}

TOTAL_CHANGED=$(wc -l < "$CHANGED_FILES_CACHE" | tr -d ' ')
info "Upstream changed files: $TOTAL_CHANGED"

# Check each active patch
while IFS='|' read -r pr_num description; do
  pr_num=$(echo "$pr_num" | tr -d ' ')
  [[ "$pr_num" =~ ^#.*$ ]] && continue
  [[ -z "$pr_num" ]] && continue
  [[ "$pr_num" =~ ^FIX- ]] && { PATCH_FIX=$((PATCH_FIX + 1)); continue; }
  [[ "$pr_num" =~ ^EXP- ]] && continue

  # Check if merged
  PR_STATE=$(gh api "repos/openclaw/openclaw/pulls/$pr_num" --jq '.state + "|" + (.merged | tostring)' 2>/dev/null || echo "unknown|false")
  if [[ "$PR_STATE" == *"|true" ]]; then
    PATCH_MERGED=$((PATCH_MERGED + 1))
    warn "PR #$pr_num: MERGED upstream — should retire"
    continue
  fi

  # Check file overlap
  PR_FILES=$(gh api "repos/openclaw/openclaw/pulls/$pr_num/files" --jq '.[].filename' 2>/dev/null || echo "")
  OVERLAP=false
  while IFS= read -r pf; do
    [ -z "$pf" ] && continue
    if grep -qF "$pf" "$CHANGED_FILES_CACHE" 2>/dev/null; then
      OVERLAP=true
      break
    fi
  done <<< "$PR_FILES"

  if [ "$OVERLAP" = true ]; then
    PATCH_CONFLICT=$((PATCH_CONFLICT + 1))
    warn "PR #$pr_num: FILE OVERLAP — may need manual review"
  else
    PATCH_CLEAN=$((PATCH_CLEAN + 1))
  fi
done < "$CONF"

echo ""
echo -e "  Pre-flight results:"
echo -e "    Clean:    ${GREEN}$PATCH_CLEAN${NC}"
echo -e "    Conflict: ${YELLOW}$PATCH_CONFLICT${NC}"
echo -e "    Merged:   ${CYAN}$PATCH_MERGED${NC}"
echo -e "    FIX:      $PATCH_FIX"

if [ "$DRY_RUN" = true ]; then
  echo ""
  info "Dry run complete. No changes made."
  rm -f "$CHANGED_FILES_CACHE"
  exit 0
fi

# ═══════════════════════════════════════════════════════════════════════════
# PHASE 2: SANDBOX BUILD
# ═══════════════════════════════════════════════════════════════════════════
step "Phase 2: Sandbox Build"

info "Cloning $TARGET_TAG into sandbox..."
git clone --depth 200 --branch "$TARGET_TAG" "$REPO" "$SANDBOX" 2>&1 | tail -1
cd "$SANDBOX"
git checkout -b patched-build

# Apply patches using rebuild logic (extracted from rebuild-with-patches.sh)
APPLIED=0
SKIPPED=0
FAILED_PATCHES=()

info "Applying patches from $CONF..."

while IFS='|' read -r pr_num description; do
  pr_num=$(echo "$pr_num" | tr -d ' ')
  [[ "$pr_num" =~ ^#.*$ ]] && continue
  [[ -z "$pr_num" ]] && continue
  [[ "$pr_num" =~ ^FIX- ]] && continue
  [[ "$pr_num" =~ ^EXP- ]] && continue

  # Strategy 0: Manual script
  MANUAL_SCRIPT=$(ls "$PATCHES_DIR/manual-patches/${pr_num}-"*.sh 2>/dev/null | head -1)
  if [ -n "$MANUAL_SCRIPT" ]; then
    if bash "$MANUAL_SCRIPT" "$SANDBOX" 2>/dev/null; then
      ok "#$pr_num: manual script"
      APPLIED=$((APPLIED + 1))
    else
      warn "#$pr_num: manual script FAILED — skipping"
      FAILED_PATCHES+=("$pr_num")
    fi
    continue
  fi

  # Download diff
  DIFF_FILE="/tmp/pr-${pr_num}.diff"
  if ! curl -sL "https://github.com/openclaw/openclaw/pull/${pr_num}.diff" -o "$DIFF_FILE" 2>/dev/null; then
    if ! gh api "repos/openclaw/openclaw/pulls/$pr_num" --jq '.diff_url' 2>/dev/null | xargs curl -sL -o "$DIFF_FILE" 2>/dev/null; then
      warn "#$pr_num: diff download failed — skipping"
      FAILED_PATCHES+=("$pr_num")
      continue
    fi
  fi

  # Strategy 1: Clean apply
  if git apply --check "$DIFF_FILE" 2>/dev/null && git apply "$DIFF_FILE" 2>/dev/null; then
    ok "#$pr_num: clean apply"
    APPLIED=$((APPLIED + 1))
    continue
  fi

  # Strategy 2: Exclude tests
  if git apply --check --exclude='*.test.*' --exclude='*.e2e.*' "$DIFF_FILE" 2>/dev/null && \
     git apply --exclude='*.test.*' --exclude='*.e2e.*' "$DIFF_FILE" 2>/dev/null; then
    ok "#$pr_num: exclude-test"
    APPLIED=$((APPLIED + 1))
    continue
  fi

  # Strategy 2b: Exclude changelog+tests
  if git apply --check --exclude='*.test.*' --exclude='*.e2e.*' --exclude='CHANGELOG.md' --exclude='*.live.*' "$DIFF_FILE" 2>/dev/null && \
     git apply --exclude='*.test.*' --exclude='*.e2e.*' --exclude='CHANGELOG.md' --exclude='*.live.*' "$DIFF_FILE" 2>/dev/null; then
    ok "#$pr_num: exclude-changelog+test"
    APPLIED=$((APPLIED + 1))
    continue
  fi

  # Strategy 3: 3-way merge
  if git apply --3way "$DIFF_FILE" 2>/dev/null; then
    ok "#$pr_num: 3way merge"
    APPLIED=$((APPLIED + 1))
    continue
  fi

  warn "#$pr_num: ALL strategies failed — skipping"
  FAILED_PATCHES+=("$pr_num")
done < "$CONF"

# Apply FIX scripts
for fix_script in "$PATCHES_DIR/manual-patches"/FIX-*.sh; do
  [ -f "$fix_script" ] || continue
  FIX_NAME=$(basename "$fix_script" .sh)
  if bash "$fix_script" "$SANDBOX" 2>/dev/null; then
    ok "$FIX_NAME: applied"
    APPLIED=$((APPLIED + 1))
  else
    warn "$FIX_NAME: FAILED"
    FAILED_PATCHES+=("$FIX_NAME")
  fi
done

echo ""
echo -e "  Patch results: ${GREEN}$APPLIED applied${NC}, ${RED}${#FAILED_PATCHES[@]} failed${NC}"
if [ ${#FAILED_PATCHES[@]} -gt 0 ]; then
  echo -e "  Failed: ${FAILED_PATCHES[*]}"
fi

# Build
step "Building..."
info "pnpm install..."
pnpm install --frozen-lockfile 2>&1 | tail -3

info "pnpm build..."
if ! pnpm build 2>&1 | tail -5; then
  fail "BUILD FAILED — aborting. Live system untouched."
  rm -rf "$SANDBOX"
  exit 1
fi

# Verify build output
if [ ! -f "$SANDBOX/dist/index.js" ]; then
  fail "dist/index.js not found after build — aborting."
  rm -rf "$SANDBOX"
  exit 1
fi
ok "Build successful"

# ═══════════════════════════════════════════════════════════════════════════
# PHASE 3: LanceDB DEPS (only if needed)
# ═══════════════════════════════════════════════════════════════════════════
step "Phase 3: Extension Dependencies"

EXT_DIR="$HOME/.openclaw/extensions/memory-lancedb"
if [ -d "$EXT_DIR" ]; then
  if (cd "$EXT_DIR" && node -e "import('@lancedb/lancedb').then(() => process.exit(0)).catch(() => process.exit(1))" 2>/dev/null); then
    ok "LanceDB: already installed and importable"
  else
    info "LanceDB: reinstalling native deps..."
    (cd "$EXT_DIR" && npm install --no-save --no-audit --no-fund 2>&1 | tail -3) && \
      ok "LanceDB: installed" || warn "LanceDB: install failed (non-fatal)"
  fi
else
  info "memory-lancedb extension not found — skipping"
fi

# ═══════════════════════════════════════════════════════════════════════════
# PHASE 4: ATOMIC SWAP
# ═══════════════════════════════════════════════════════════════════════════
step "Phase 4: Atomic Swap"

TARGET_DIST="$VERSIONS_DIR/v${TARGET_VERSION}-patched"

if [ -d "$TARGET_DIST" ]; then
  warn "Target exists, adding timestamp suffix"
  TARGET_DIST="${TARGET_DIST}-$(date +%s)"
fi

info "Copying build output → $(basename "$TARGET_DIST")"
sudo mkdir -p "$VERSIONS_DIR"
sudo cp -R "$SANDBOX/dist" "$TARGET_DIST"
sudo chown -R "$(whoami):staff" "$TARGET_DIST"

info "Atomic symlink swap..."
sudo ln -sfn "$TARGET_DIST" "${ACTIVE_LINK}-tmp"
sudo mv "${ACTIVE_LINK}-tmp" "$ACTIVE_LINK"
ok "Swap complete: dist-active → $(basename "$TARGET_DIST")"

# Trim old versions (keep max 3)
VERSION_COUNT=$(ls -1 "$VERSIONS_DIR" 2>/dev/null | wc -l | tr -d ' ')
if [ "$VERSION_COUNT" -gt 3 ]; then
  info "Trimming old versions (keeping 3)..."
  ls -1t "$VERSIONS_DIR" | tail -n +4 | while read -r old; do
    FULL_PATH="$VERSIONS_DIR/$old"
    # Never delete the active version
    if [ "$(readlink "$ACTIVE_LINK")" != "$FULL_PATH" ]; then
      sudo rm -rf "$FULL_PATH"
      info "Removed: $old"
    fi
  done
fi

# ═══════════════════════════════════════════════════════════════════════════
# PHASE 5: HEALTH PROBE
# ═══════════════════════════════════════════════════════════════════════════
step "Phase 5: Health Probe"

PREV_ACTIVE="$(ls -1t "$VERSIONS_DIR" | grep -v "$(basename "$TARGET_DIST")" | head -1)"

info "Restarting gateway..."
launchctl kickstart -k "gui/$(id -u)/ai.openclaw.gateway" 2>/dev/null || \
  warn "launchctl kickstart failed — try manual restart"

# Wait for gateway to start
sleep 3

HEALTH_OK=false
for i in $(seq 1 12); do
  # Check PID
  if ! pgrep -x "openclaw-gateway" > /dev/null 2>&1; then
    warn "Health check $i/12: gateway not running"
    sleep 5
    continue
  fi

  # Check HTTP
  HTTP_STATUS=$(curl -s -o /dev/null -w "%{http_code}" "http://127.0.0.1:28643/" 2>/dev/null || echo "000")
  if [ "$HTTP_STATUS" = "000" ]; then
    warn "Health check $i/12: HTTP not responding"
    sleep 5
    continue
  fi

  ok "Health check $i/12: PID alive, HTTP $HTTP_STATUS"
  HEALTH_OK=true
  break
done

if [ "$HEALTH_OK" = false ]; then
  fail "Gateway failed health checks — rolling back"
  if [ -n "$PREV_ACTIVE" ]; then
    sudo ln -sfn "$VERSIONS_DIR/$PREV_ACTIVE" "${ACTIVE_LINK}-tmp"
    sudo mv "${ACTIVE_LINK}-tmp" "$ACTIVE_LINK"
    launchctl kickstart -k "gui/$(id -u)/ai.openclaw.gateway" 2>/dev/null || true
    warn "Rolled back to $PREV_ACTIVE"
  fi
  EXIT_CODE=1
else
  ok "Gateway healthy on v$TARGET_VERSION"
  EXIT_CODE=0
fi

# ═══════════════════════════════════════════════════════════════════════════
# PHASE 6: REPORT
# ═══════════════════════════════════════════════════════════════════════════
step "Phase 6: Report"

END_TIME=$(date +%s)
DURATION=$((END_TIME - START_TIME))

# JSONL log
LOG_ENTRY=$(cat <<LOGEOF
{"timestamp":"$(date -u +%Y-%m-%dT%H:%M:%SZ)","action":"upgrade","from":"v$CURRENT_VERSION","target":"$TARGET_TAG","applied":$APPLIED,"failed":${#FAILED_PATCHES[@]},"merged":$PATCH_MERGED,"conflict":$PATCH_CONFLICT,"health":"$([ "$HEALTH_OK" = true ] && echo ok || echo failed)","duration_seconds":$DURATION,"failed_patches":["$(IFS='","'; echo "${FAILED_PATCHES[*]}")"]}
LOGEOF
)
echo "$LOG_ENTRY" >> "$LOG_FILE"

# Discord notification
if [ -f "$NOTIFY_SCRIPT" ]; then
  EMOJI=$([ "$HEALTH_OK" = true ] && echo "white_check_mark" || echo "x")
  bash "$NOTIFY_SCRIPT" ":${EMOJI}: **OpenClaw Upgrade** v$CURRENT_VERSION → $TARGET_TAG
Applied: $APPLIED | Failed: ${#FAILED_PATCHES[@]} | Merged: $PATCH_MERGED
Duration: ${DURATION}s | Health: $([ "$HEALTH_OK" = true ] && echo OK || echo FAILED)" 2>/dev/null || true
fi

# Summary
echo ""
echo -e "${BOLD}Upgrade Summary${NC}"
echo "  From:     v$CURRENT_VERSION"
echo "  To:       $TARGET_TAG"
echo "  Duration: ${DURATION}s"
echo "  Applied:  $APPLIED"
echo "  Failed:   ${#FAILED_PATCHES[@]}"
echo "  Merged:   $PATCH_MERGED"
echo "  Health:   $([ "$HEALTH_OK" = true ] && echo -e "${GREEN}OK${NC}" || echo -e "${RED}FAILED${NC}")"

# Cleanup sandbox
rm -rf "$SANDBOX" "$CHANGED_FILES_CACHE"

exit ${EXIT_CODE:-0}
