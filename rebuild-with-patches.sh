#!/usr/bin/env bash
set -euo pipefail

# ─────────────────────────────────────────────────────────────────────────────
# OpenClaw Rebuild-with-Patches
# Clones the installed version, applies open PR patches, builds, swaps dist.
# Usage: ~/.openclaw/my-patches/rebuild-with-patches.sh [--force]
# ─────────────────────────────────────────────────────────────────────────────

PATCHES_DIR="$(cd "$(dirname "$0")" && pwd)"
CONF="$PATCHES_DIR/pr-patches.conf"
OPENCLAW_ROOT="$(npm root -g)/openclaw"
VERSION=$(node -e "console.log(require('$OPENCLAW_ROOT/package.json').version)")
BASE_TAG="v$(echo "$VERSION" | sed 's/-[0-9]*$//')"
WORKDIR="/tmp/openclaw-patch-build-$$"
REPO="https://github.com/openclaw/openclaw.git"

# Handle --discover flag: run discovery first, then rebuild
if [[ "${1:-}" == "--discover" ]]; then
  shift
  bash "$PATCHES_DIR/discover-patches.sh" --all "$@"
  exit $?
fi

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
echo -e "${CYAN}OpenClaw Rebuild-with-Patches${NC}"
echo "  Installed: $VERSION"
echo "  Base tag:  $BASE_TAG"
echo "  Config:    $CONF"
echo ""

# ── Step 0: Read PR list and check which are still open ──────────────────────
if [ ! -f "$CONF" ]; then
  fail "PR config not found: $CONF"
  exit 1
fi

OPEN_PRS=()
MERGED_PRS=()
TOTAL=0

while IFS='|' read -r pr_num description; do
  # Skip comments and empty lines
  [[ "$pr_num" =~ ^[[:space:]]*# ]] && continue
  [[ -z "$pr_num" ]] && continue
  
  pr_num=$(echo "$pr_num" | tr -d ' ')
  description=$(echo "$description" | sed 's/^ *//')
  TOTAL=$((TOTAL + 1))
  
  # Check if PR is still open
  state=$(gh api "repos/openclaw/openclaw/pulls/$pr_num" --jq '.state' 2>/dev/null || echo "unknown")
  merged=$(gh api "repos/openclaw/openclaw/pulls/$pr_num" --jq '.merged' 2>/dev/null || echo "false")
  
  if [ "$merged" = "true" ]; then
    warn "#$pr_num MERGED upstream — $description"
    MERGED_PRS+=("$pr_num")
  elif [ "$state" = "open" ]; then
    ok "#$pr_num open — will patch"
    OPEN_PRS+=("$pr_num")
  else
    warn "#$pr_num state=$state — skipping"
  fi
done < "$CONF"

echo ""
info "Total: $TOTAL PRs, ${#OPEN_PRS[@]} to apply, ${#MERGED_PRS[@]} already merged"

if [ ${#MERGED_PRS[@]} -gt 0 ]; then
  echo ""
  warn "These PRs are now merged upstream. Consider updating openclaw and removing them from $CONF:"
  for pr in "${MERGED_PRS[@]}"; do
    echo "  - #$pr"
  done
fi

if [ ${#OPEN_PRS[@]} -eq 0 ]; then
  ok "No patches needed — all PRs merged or skipped!"
  exit 0
fi

# ── Step 1: Clone at version tag ─────────────────────────────────────────────
echo ""
info "Cloning openclaw at $BASE_TAG..."
rm -rf "$WORKDIR"
git clone --depth 200 --branch "$BASE_TAG" "$REPO" "$WORKDIR" 2>/dev/null
cd "$WORKDIR"
git checkout -b patched-build 2>/dev/null

# ── Step 2: Download and apply PR diffs ──────────────────────────────────────
echo ""
info "Downloading ${#OPEN_PRS[@]} PR diffs..."
mkdir -p /tmp/oc-pr-diffs

# Download all diffs upfront with rate limiting to avoid GitHub throttling
for i in "${!OPEN_PRS[@]}"; do
  pr_num="${OPEN_PRS[$i]}"
  diff_file="/tmp/oc-pr-diffs/${pr_num}.diff"
  if [ ! -s "$diff_file" ] || head -1 "$diff_file" 2>/dev/null | grep -q '<!DOCTYPE'; then
    curl -sL "https://github.com/openclaw/openclaw/pull/${pr_num}.diff" > "$diff_file"
    # Validate: retry once with gh api if curl returned HTML (rate limited)
    if head -1 "$diff_file" 2>/dev/null | grep -q '<!DOCTYPE'; then
      sleep 2
      gh api "repos/openclaw/openclaw/pulls/${pr_num}" --header 'Accept: application/vnd.github.v3.diff' > "$diff_file" 2>/dev/null || true
    fi
  fi
  # Pause every 30 downloads to stay under rate limits
  if [ $(( (i + 1) % 30 )) -eq 0 ]; then
    sleep 3
  fi
done
ok "Downloaded ${#OPEN_PRS[@]} diffs"

APPLIED=0
FAILED=0
FAILED_LIST=()

MANUAL_DIR="$PATCHES_DIR/manual-patches"

for pr_num in "${OPEN_PRS[@]}"; do

  # Strategy 0: Manual patch script takes priority (handcrafted fixes are more reliable
  # than auto-applying diffs that may have TS errors or context drift)
  if ls "$MANUAL_DIR"/${pr_num}-*.sh 1>/dev/null 2>&1; then
    MANUAL_SCRIPT=$(ls "$MANUAL_DIR"/${pr_num}-*.sh | head -1)
    info "#$pr_num using manual patch: $(basename "$MANUAL_SCRIPT")"
    if bash "$MANUAL_SCRIPT" "$WORKDIR" 2>&1 | while read -r line; do echo "    $line"; done; then
      ok "#$pr_num manual patch applied"
      APPLIED=$((APPLIED + 1))
    else
      warn "#$pr_num manual patch FAILED"
      FAILED=$((FAILED + 1))
      FAILED_LIST+=("$pr_num")
    fi
  # Strategy 1: Clean apply
  elif git apply --check "/tmp/oc-pr-diffs/${pr_num}.diff" 2>/dev/null; then
    git apply "/tmp/oc-pr-diffs/${pr_num}.diff"
    ok "#$pr_num applied cleanly"
    APPLIED=$((APPLIED + 1))
  # Strategy 2: Apply excluding test files (test context often drifts)
  elif git apply --check --exclude='*.test.*' --exclude='*.e2e.*' "/tmp/oc-pr-diffs/${pr_num}.diff" 2>/dev/null; then
    git apply --exclude='*.test.*' --exclude='*.e2e.*' "/tmp/oc-pr-diffs/${pr_num}.diff"
    ok "#$pr_num applied (tests excluded)"
    APPLIED=$((APPLIED + 1))
  # Strategy 2b: Exclude CHANGELOG + tests (CHANGELOG context drifts across versions)
  elif git apply --check --exclude='CHANGELOG.md' --exclude='*.test.*' --exclude='*.e2e.*' --exclude='*.live.*' "/tmp/oc-pr-diffs/${pr_num}.diff" 2>/dev/null; then
    git apply --exclude='CHANGELOG.md' --exclude='*.test.*' --exclude='*.e2e.*' --exclude='*.live.*' "/tmp/oc-pr-diffs/${pr_num}.diff"
    ok "#$pr_num applied (changelog+tests excluded)"
    APPLIED=$((APPLIED + 1))
  # Strategy 3: 3-way merge
  elif git apply --check --3way "/tmp/oc-pr-diffs/${pr_num}.diff" 2>/dev/null; then
    git apply --3way "/tmp/oc-pr-diffs/${pr_num}.diff"
    ok "#$pr_num applied with 3way merge"
    APPLIED=$((APPLIED + 1))
  else
    warn "#$pr_num failed to apply (no matching strategy)"
    FAILED=$((FAILED + 1))
    FAILED_LIST+=("$pr_num")
  fi
done

echo ""
info "Applied: $APPLIED, Failed: $FAILED"

if [ $APPLIED -eq 0 ]; then
  fail "No patches applied — aborting build"
  rm -rf "$WORKDIR"
  exit 1
fi

# ── Step 3: Install deps and build ───────────────────────────────────────────
echo ""
info "Installing dependencies..."
pnpm install --frozen-lockfile 2>&1 | tail -2

info "Building..."
BUILD_OUTPUT=$(pnpm build 2>&1)
BUILD_EXIT=$?

if [ $BUILD_EXIT -ne 0 ]; then
  fail "Build failed!"
  echo "$BUILD_OUTPUT" | tail -20
  rm -rf "$WORKDIR"
  exit 1
fi

BUILD_FILES=$(ls dist/ | wc -l | tr -d ' ')
ok "Build complete: $BUILD_FILES files"

# ── Step 4: Backup current dist and swap ─────────────────────────────────────
echo ""
BACKUP_DIR="$PATCHES_DIR/dist-backup-${VERSION}"

if [ -d "$BACKUP_DIR" ]; then
  info "Backup already exists at $BACKUP_DIR"
else
  info "Backing up current dist to $BACKUP_DIR..."
  cp -R "$OPENCLAW_ROOT/dist" "$BACKUP_DIR"
  ok "Backup created"
fi

info "Swapping dist..."
# Clear contents instead of removing dir (parent may be root-owned)
find "$OPENCLAW_ROOT/dist" -mindepth 1 -delete 2>/dev/null || rm -rf "$OPENCLAW_ROOT/dist"/* 2>/dev/null || true
cp -R "$WORKDIR/dist/"* "$OPENCLAW_ROOT/dist/"
ok "Dist replaced with patched build"

# ── Step 5: Verify ───────────────────────────────────────────────────────────
echo ""
info "Verifying entry point..."
if [ -f "$OPENCLAW_ROOT/dist/entry.js" ]; then
  ok "entry.js present"
else
  fail "entry.js MISSING — restoring backup!"
  find "$OPENCLAW_ROOT/dist" -mindepth 1 -delete 2>/dev/null || true
  cp -R "$BACKUP_DIR/"* "$OPENCLAW_ROOT/dist/"
  exit 1
fi

# ── Step 6: Cleanup ──────────────────────────────────────────────────────────
rm -rf "$WORKDIR"
rm -rf /tmp/oc-pr-diffs

# ── Summary ──────────────────────────────────────────────────────────────────
echo ""
echo -e "${CYAN}═══════════════════════════════════════════${NC}"
echo -e "  ${GREEN}Patched build installed${NC}"
echo -e "  Version: $VERSION + ${APPLIED} PR patches"
if [ ${#FAILED_LIST[@]} -gt 0 ]; then
  echo -e "  ${YELLOW}Skipped: ${FAILED_LIST[*]}${NC}"
fi
echo -e "  Backup:  $BACKUP_DIR"
echo -e "${CYAN}═══════════════════════════════════════════${NC}"
echo ""
echo "  Restart gateway: openclaw gateway restart"
echo ""
