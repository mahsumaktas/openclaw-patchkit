#!/usr/bin/env bash
set -euo pipefail

# ─────────────────────────────────────────────────────────────────────────────
# OpenClaw Rebuild-with-Patches
# Clones the installed version, applies open PR patches, builds, swaps dist.
# Usage: ~/.openclaw/my-patches/rebuild-with-patches.sh [--force] [--verbose]
# ─────────────────────────────────────────────────────────────────────────────

PATCHES_DIR="$(cd "$(dirname "$0")" && pwd)"
CONF="$PATCHES_DIR/pr-patches.conf"
OPENCLAW_ROOT="$(npm root -g)/openclaw"
VERSION=$(node -e "console.log(require('$OPENCLAW_ROOT/package.json').version)")
BASE_TAG="v$(echo "$VERSION" | sed 's/-[0-9]*$//')"
WORKDIR="/tmp/openclaw-patch-build-$$"
REPO="https://github.com/openclaw/openclaw.git"

# Handle flags
VERBOSE=false
if [[ "${1:-}" == "--discover" ]]; then
  shift
  bash "$PATCHES_DIR/discover-patches.sh" --all "$@"
  exit $?
fi
if [[ "${1:-}" == "--verbose" ]] || [[ "${2:-}" == "--verbose" ]]; then
  VERBOSE=true
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
SKIPPED_PRS=()
RETIRED_COUNT=0
TOTAL=0

while IFS='|' read -r pr_num description; do
  # Skip comments, empty lines, and expansion entries
  [[ "$pr_num" =~ ^[[:space:]]*# ]] && continue
  [[ -z "$pr_num" ]] && continue
  [[ "$pr_num" =~ ^[[:space:]]*EXP- ]] && continue
  [[ "$pr_num" =~ ^[[:space:]]*FIX- ]] && continue

  pr_num=$(echo "$pr_num" | tr -d ' ')
  description=$(echo "$description" | sed 's/^ *//')
  TOTAL=$((TOTAL + 1))

  # If a manual patch script exists, always include (handles internal issues without upstream PRs)
  if ls "$PATCHES_DIR/manual-patches/${pr_num}-"*.sh 1>/dev/null 2>&1; then
    state=$(gh api "repos/openclaw/openclaw/pulls/$pr_num" --jq '.state' 2>/dev/null || echo "unknown")
    if [ "$state" = "open" ] || [ "$state" = "unknown" ]; then
      [ "$VERBOSE" = true ] && ok "#$pr_num manual script — will patch"
      OPEN_PRS+=("$pr_num")
    elif [ "$(gh api "repos/openclaw/openclaw/pulls/$pr_num" --jq '.merged' 2>/dev/null || echo "false")" = "true" ]; then
      _manual_name=$(ls "$PATCHES_DIR/manual-patches/${pr_num}-"*.sh 2>/dev/null | head -1 | xargs basename 2>/dev/null || echo 'n/a')
      warn "[RETIRED] PR #$pr_num merged upstream — skipping (manual: $_manual_name)"
      MERGED_PRS+=("$pr_num")
      # Log retirement
      MERGED_SHA=$(gh api "repos/openclaw/openclaw/pulls/$pr_num" --jq '.merge_commit_sha' 2>/dev/null | head -c 7)
      echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) RETIRED #$pr_num merged_sha:${MERGED_SHA:-unknown} desc:${description:-}" \
        >> "$PATCHES_DIR/retired-patches.log"
      # Mark in conf file
      if grep -q "^${pr_num}" "$CONF" 2>/dev/null; then
        sed -i.retirement-bak "s/^${pr_num}/# RETIRED($(date +%Y-%m-%d)): ${pr_num}/" "$CONF"
      fi
      RETIRED_COUNT=$((RETIRED_COUNT + 1))
    else
      [ "$VERBOSE" = true ] && ok "#$pr_num manual script — will patch"
      OPEN_PRS+=("$pr_num")
    fi
    continue
  fi

  # Check if PR is still open (upstream only)
  state=$(gh api "repos/openclaw/openclaw/pulls/$pr_num" --jq '.state' 2>/dev/null || echo "unknown")
  merged=$(gh api "repos/openclaw/openclaw/pulls/$pr_num" --jq '.merged' 2>/dev/null || echo "false")

  if [ "$merged" = "true" ]; then
    warn "[RETIRED] PR #$pr_num merged upstream — skipping"
    MERGED_PRS+=("$pr_num")
    # Log retirement
    MERGED_SHA=$(gh api "repos/openclaw/openclaw/pulls/$pr_num" --jq '.merge_commit_sha' 2>/dev/null | head -c 7)
    echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) RETIRED #$pr_num merged_sha:${MERGED_SHA:-unknown} desc:${description:-}" \
      >> "$PATCHES_DIR/retired-patches.log"
    # Mark in conf file
    if grep -q "^${pr_num}" "$CONF" 2>/dev/null; then
      sed -i.retirement-bak "s/^${pr_num}/# RETIRED($(date +%Y-%m-%d)): ${pr_num}/" "$CONF"
    fi
    RETIRED_COUNT=$((RETIRED_COUNT + 1))
  elif [ "$state" = "open" ]; then
    [ "$VERBOSE" = true ] && ok "#$pr_num open — will patch"
    OPEN_PRS+=("$pr_num")
  else
    [ "$VERBOSE" = true ] && warn "#$pr_num state=$state — skipping"
    SKIPPED_PRS+=("$pr_num")
  fi
done < "$CONF"

echo ""
info "Total: $TOTAL PRs | ${#OPEN_PRS[@]} open | ${#MERGED_PRS[@]} merged | ${#SKIPPED_PRS[@]} skipped"

if [ ${#MERGED_PRS[@]} -gt 0 ]; then
  warn "Retired (merged upstream): ${MERGED_PRS[*]} — logged to retired-patches.log"
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
DL_OK=0; DL_FAIL=0
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
  # Track download success
  if [ -s "$diff_file" ] && ! head -1 "$diff_file" 2>/dev/null | grep -q '<!DOCTYPE'; then
    DL_OK=$((DL_OK + 1))
  else
    DL_FAIL=$((DL_FAIL + 1))
    [ "$VERBOSE" = true ] && warn "#$pr_num diff download failed (404 or rate limited)"
  fi
  # Pause every 30 downloads to stay under rate limits
  if [ $(( (i + 1) % 30 )) -eq 0 ]; then
    sleep 3
  fi
done
if [ $DL_FAIL -gt 0 ]; then
  ok "Downloaded $DL_OK/${#OPEN_PRS[@]} diffs ($DL_FAIL failed — manual-only PRs)"
else
  ok "Downloaded ${#OPEN_PRS[@]} diffs"
fi

APPLIED=0
FAILED=0
FAILED_LIST=()
STRATEGY_COUNTS=([0]=0 [1]=0 [2]=0 [3]=0 [4]=0)  # manual, clean, excl-test, excl-cl+test, 3way

MANUAL_DIR="$PATCHES_DIR/manual-patches"

for pr_num in "${OPEN_PRS[@]}"; do

  # Strategy 0: Manual patch script takes priority (handcrafted fixes are more reliable
  # than auto-applying diffs that may have TS errors or context drift)
  if ls "$MANUAL_DIR"/${pr_num}-*.sh 1>/dev/null 2>&1; then
    MANUAL_SCRIPT=$(ls "$MANUAL_DIR"/${pr_num}-*.sh | head -1)
    [ "$VERBOSE" = true ] && info "#$pr_num manual: $(basename "$MANUAL_SCRIPT")"
    if bash "$MANUAL_SCRIPT" "$WORKDIR" 2>&1 | { if [ "$VERBOSE" = true ]; then while read -r line; do echo "    $line"; done; else cat >/dev/null; fi; }; then
      [ "$VERBOSE" = true ] && ok "#$pr_num manual patch applied"
      APPLIED=$((APPLIED + 1)); STRATEGY_COUNTS[0]=$((STRATEGY_COUNTS[0] + 1))
    else
      warn "#$pr_num manual patch FAILED ($(basename "$MANUAL_SCRIPT"))"
      FAILED=$((FAILED + 1))
      FAILED_LIST+=("$pr_num")
    fi
  # Strategy 1: Clean apply
  elif git apply --check "/tmp/oc-pr-diffs/${pr_num}.diff" 2>/dev/null; then
    git apply "/tmp/oc-pr-diffs/${pr_num}.diff"
    [ "$VERBOSE" = true ] && ok "#$pr_num applied cleanly"
    APPLIED=$((APPLIED + 1)); STRATEGY_COUNTS[1]=$((STRATEGY_COUNTS[1] + 1))
  # Strategy 2: Apply excluding test files (test context often drifts)
  elif git apply --check --exclude='*.test.*' --exclude='*.e2e.*' "/tmp/oc-pr-diffs/${pr_num}.diff" 2>/dev/null; then
    git apply --exclude='*.test.*' --exclude='*.e2e.*' "/tmp/oc-pr-diffs/${pr_num}.diff"
    [ "$VERBOSE" = true ] && ok "#$pr_num applied (tests excluded)"
    APPLIED=$((APPLIED + 1)); STRATEGY_COUNTS[2]=$((STRATEGY_COUNTS[2] + 1))
  # Strategy 2b: Exclude CHANGELOG + tests (CHANGELOG context drifts across versions)
  elif git apply --check --exclude='CHANGELOG.md' --exclude='*.test.*' --exclude='*.e2e.*' --exclude='*.live.*' "/tmp/oc-pr-diffs/${pr_num}.diff" 2>/dev/null; then
    git apply --exclude='CHANGELOG.md' --exclude='*.test.*' --exclude='*.e2e.*' --exclude='*.live.*' "/tmp/oc-pr-diffs/${pr_num}.diff"
    [ "$VERBOSE" = true ] && ok "#$pr_num applied (changelog+tests excluded)"
    APPLIED=$((APPLIED + 1)); STRATEGY_COUNTS[3]=$((STRATEGY_COUNTS[3] + 1))
  # Strategy 3: 3-way merge
  elif git apply --check --3way "/tmp/oc-pr-diffs/${pr_num}.diff" 2>/dev/null; then
    git apply --3way "/tmp/oc-pr-diffs/${pr_num}.diff"
    [ "$VERBOSE" = true ] && ok "#$pr_num applied with 3way merge"
    APPLIED=$((APPLIED + 1)); STRATEGY_COUNTS[4]=$((STRATEGY_COUNTS[4] + 1))
  else
    warn "#$pr_num failed to apply (no matching strategy)"
    FAILED=$((FAILED + 1))
    FAILED_LIST+=("$pr_num")
  fi
done

echo ""
# Build compact strategy breakdown
STRAT_PARTS=""
[ "${STRATEGY_COUNTS[0]}" -gt 0 ] && STRAT_PARTS="${STRAT_PARTS}${STRATEGY_COUNTS[0]} manual, "
[ "${STRATEGY_COUNTS[1]}" -gt 0 ] && STRAT_PARTS="${STRAT_PARTS}${STRATEGY_COUNTS[1]} clean, "
[ "${STRATEGY_COUNTS[2]}" -gt 0 ] && STRAT_PARTS="${STRAT_PARTS}${STRATEGY_COUNTS[2]} excl-test, "
[ "${STRATEGY_COUNTS[3]}" -gt 0 ] && STRAT_PARTS="${STRAT_PARTS}${STRATEGY_COUNTS[3]} excl-cl+test, "
[ "${STRATEGY_COUNTS[4]}" -gt 0 ] && STRAT_PARTS="${STRAT_PARTS}${STRATEGY_COUNTS[4]} 3way, "
STRAT_PARTS="${STRAT_PARTS%, }"  # trim trailing comma

ok "Applied: $APPLIED/$((APPLIED + FAILED)) ($STRAT_PARTS)"
if [ $FAILED -gt 0 ]; then
  warn "Failed: ${FAILED_LIST[*]}"
fi

if [ $APPLIED -eq 0 ]; then
  fail "No patches applied — aborting build"
  rm -rf "$WORKDIR"
  exit 1
fi

# ── Step 2a-fix: Apply FIX-* manual patch scripts ─────────────────────────────
FIX_APPLIED=0
FIX_FAILED=0
FIX_SCRIPTS=("$MANUAL_DIR"/FIX-*-*.sh)

if [ -f "${FIX_SCRIPTS[0]}" ]; then
  echo ""
  info "Applying ${#FIX_SCRIPTS[@]} fix scripts..."
  for fix_script in "${FIX_SCRIPTS[@]}"; do
    fix_name=$(basename "$fix_script" .sh)
    if bash "$fix_script" "$WORKDIR" 2>&1 | { if [ "$VERBOSE" = true ]; then while read -r line; do echo "    $line"; done; else cat >/dev/null; fi; }; then
      [ "$VERBOSE" = true ] && ok "$fix_name applied"
      FIX_APPLIED=$((FIX_APPLIED + 1))
    else
      warn "$fix_name FAILED"
      FIX_FAILED=$((FIX_FAILED + 1))
    fi
  done
  ok "Fixes: $FIX_APPLIED/${#FIX_SCRIPTS[@]} applied"
fi

# ── Step 2b: Apply expansion scripts ─────────────────────────────────────────
EXP_APPLIED=0
EXP_FAILED=0
EXP_FAILED_LIST=()
EXP_SCRIPTS=("$MANUAL_DIR"/EXP-*-*.sh)

if [ -f "${EXP_SCRIPTS[0]}" ]; then
  echo ""
  info "Applying ${#EXP_SCRIPTS[@]} expansion scripts..."
  for exp_script in "${EXP_SCRIPTS[@]}"; do
    exp_name=$(basename "$exp_script" .sh)
    if bash "$exp_script" "$WORKDIR" 2>&1 | { if [ "$VERBOSE" = true ]; then while read -r line; do echo "    $line"; done; else cat >/dev/null; fi; }; then
      [ "$VERBOSE" = true ] && ok "$exp_name applied"
      EXP_APPLIED=$((EXP_APPLIED + 1))
    else
      warn "$exp_name FAILED"
      EXP_FAILED=$((EXP_FAILED + 1))
      EXP_FAILED_LIST+=("$exp_name")
    fi
  done
  ok "Expansions: $EXP_APPLIED/${#EXP_SCRIPTS[@]} applied"
  if [ $EXP_FAILED -gt 0 ]; then
    warn "Failed: ${EXP_FAILED_LIST[*]}"
  fi
fi

# ── Step 3: Install deps and build ───────────────────────────────────────────
echo ""
info "Installing dependencies..."
set +e
if [ "$VERBOSE" = true ]; then
  pnpm install --frozen-lockfile 2>&1 | tail -5
  INSTALL_EXIT=${PIPESTATUS[0]}
else
  pnpm install --frozen-lockfile >/dev/null 2>&1
  INSTALL_EXIT=$?
fi
set -e

if [ "$INSTALL_EXIT" -ne 0 ]; then
  fail "pnpm install failed (exit $INSTALL_EXIT)"
  rm -rf "$WORKDIR"
  exit 1
fi
ok "Dependencies installed"

# Fix ownership after pnpm install — rolldown bundler needs write access
# pnpm install creates root-owned node_modules when running under sudo
if [ "$(id -u)" -eq 0 ] && [ -n "${SUDO_USER:-}" ]; then
  chown -R "$SUDO_USER" "$WORKDIR"
fi

info "Building..."
set +e
BUILD_OUTPUT=$(pnpm build 2>&1)
BUILD_EXIT=$?
set -e

if [ $BUILD_EXIT -ne 0 ]; then
  fail "Build failed! Last 20 lines:"
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
echo -e "  Version: $VERSION + ${APPLIED} PR patches + ${FIX_APPLIED:-0} fixes + ${EXP_APPLIED:-0} expansions"
if [ "$RETIRED_COUNT" -gt 0 ]; then
  echo -e "  ${YELLOW}Retired (merged upstream): $RETIRED_COUNT${NC}"
fi
if [ ${#FAILED_LIST[@]} -gt 0 ]; then
  echo -e "  ${YELLOW}Skipped: ${FAILED_LIST[*]}${NC}"
fi
if [ "${EXP_FAILED:-0}" -gt 0 ]; then
  echo -e "  ${YELLOW}Expansion failures: $EXP_FAILED${NC}"
fi
echo -e "  Backup:  $BACKUP_DIR"
echo -e "${CYAN}═══════════════════════════════════════════${NC}"
echo ""
echo "  Restart gateway: openclaw gateway restart"
echo ""
