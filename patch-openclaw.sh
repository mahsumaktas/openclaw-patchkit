#!/usr/bin/env bash
set -euo pipefail

# ─────────────────────────────────────────────────────────────────────────────
# OpenClaw Unified Patch System
# Master orchestrator: runs all patch phases in order.
#
# Usage:
#   patch-openclaw.sh                     # Run all phases
#   patch-openclaw.sh --phase 1|2|3       # Run specific phase
#   patch-openclaw.sh --force             # Force re-run (pass to rebuild)
#   patch-openclaw.sh --skip-restart      # Don't prompt for gateway restart
#   patch-openclaw.sh --dry-run           # Show what would happen
#   patch-openclaw.sh --rollback           # Rollback dist to latest backup
#   patch-openclaw.sh --status            # Show last run report
# ─────────────────────────────────────────────────────────────────────────────

PATCHES_DIR="$(cd "$(dirname "$0")" && pwd)"
OPENCLAW_ROOT="$(npm root -g)/openclaw"
VERSION=$(node -e "console.log(require('$OPENCLAW_ROOT/package.json').version)" 2>/dev/null || echo "unknown")
REPORT_FILE="$PATCHES_DIR/.last-patch-run.json"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

ok()   { echo -e "${GREEN}[OK]${NC} $1"; }
warn() { echo -e "${YELLOW}[!!]${NC} $1"; }
fail() { echo -e "${RED}[FAIL]${NC} $1"; }
info() { echo -e "${CYAN}[..]${NC} $1"; }

# ── Parse args ───────────────────────────────────────────────────────────────
PHASE=""
FORCE_FLAG=""
SKIP_RESTART=false
DRY_RUN=false
SHOW_STATUS=false
ROLLBACK_MODE=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --phase)   PHASE="$2"; shift 2 ;;
    --force)   FORCE_FLAG="--force"; shift ;;
    --skip-restart) SKIP_RESTART=true; shift ;;
    --dry-run) DRY_RUN=true; shift ;;
    --status)  SHOW_STATUS=true; shift ;;
    --rollback) ROLLBACK_MODE=true; shift ;;
    --all)     PHASE=""; shift ;;
    *)         echo "Unknown option: $1"; exit 1 ;;
  esac
done

# ── --status: show last report ───────────────────────────────────────────────
if [ "$SHOW_STATUS" = true ]; then
  if [ ! -f "$REPORT_FILE" ]; then
    echo "No previous patch run found."
    exit 0
  fi
  echo ""
  echo -e "${CYAN}Last Patch Run Report${NC}"
  echo ""
  node -e "
    const r = require('$REPORT_FILE');
    console.log('  Version:  ' + r.version);
    console.log('  Date:     ' + r.timestamp);
    console.log('  Duration: ' + r.duration_seconds + 's');
    console.log('');
    for (const [name, phase] of Object.entries(r.phases)) {
      const icon = phase.status === 'OK' ? '\x1b[32m[OK]\x1b[0m' :
                   phase.status === 'SKIP' ? '\x1b[33m[SKIP]\x1b[0m' :
                   '\x1b[31m[FAIL]\x1b[0m';
      console.log('  ' + icon + ' ' + name + ': ' + phase.summary);
    }
    console.log('');
    const v = r.verification;
    console.log('  Verification: ' + v.passed + '/' + v.total + ' checks passed');
    for (const c of v.checks) {
      const ci = c.passed ? '\x1b[32m[OK]\x1b[0m' : '\x1b[31m[FAIL]\x1b[0m';
      console.log('    ' + ci + ' ' + c.name);
    }
  "
  exit 0
fi

# ── --rollback: restore dist from latest backup ──────────────────────────────
if [ "$ROLLBACK_MODE" = true ]; then
  echo ""
  echo -e "${CYAN}=== ROLLBACK MODE ===${NC}"
  INSTALL_DIR="$OPENCLAW_ROOT"

  # Find latest dist backup
  LATEST_BACKUP=$(ls -td "$INSTALL_DIR/dist-backup-"* 2>/dev/null | head -1)

  if [ -z "$LATEST_BACKUP" ]; then
    fail "No dist backup found for rollback"
    exit 1
  fi

  BACKUP_VERSION=$(basename "$LATEST_BACKUP" | sed 's/dist-backup-//')
  info "Rolling back to: $BACKUP_VERSION"
  info "Backup source: $LATEST_BACKUP"

  # Dist swap (root-owned directory)
  DIST_DIR="$INSTALL_DIR/dist"
  sudo find "$DIST_DIR" -mindepth 1 -delete
  sudo cp -R "$LATEST_BACKUP/." "$DIST_DIR/"

  ok "Dist rolled back to $BACKUP_VERSION"

  # Gateway restart (launchctl, NOT kill -9)
  launchctl kill SIGTERM "gui/$(id -u)/ai.openclaw.gateway" 2>/dev/null || true
  sleep 2
  launchctl kickstart "gui/$(id -u)/ai.openclaw.gateway" 2>/dev/null || true

  # Log rollback
  echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) ROLLBACK to $BACKUP_VERSION" >> "$PATCHES_DIR/retired-patches.log"

  ok "Gateway restarted. Rollback complete."
  echo ""
  exit 0
fi

# ── Header ───────────────────────────────────────────────────────────────────
echo ""
echo -e "${CYAN}OpenClaw Unified Patch System${NC}"
echo "  Version: $VERSION"
echo "  Config:  $PATCHES_DIR/pr-patches.conf"
if [ -n "$PHASE" ]; then
  echo "  Mode:    Phase $PHASE only"
fi
if [ "$DRY_RUN" = true ]; then
  echo -e "  ${YELLOW}DRY RUN — no changes will be made${NC}"
fi
echo ""

START_TIME=$(date +%s)

# Phase results
P1_STATUS="SKIP"; P1_SUMMARY="not run"
P2_STATUS="SKIP"; P2_SUMMARY="not run"
P3_STATUS="SKIP"; P3_SUMMARY="not run"

should_run() {
  [ -z "$PHASE" ] || [ "$PHASE" = "$1" ]
}

# ── Phase 1: Source Rebuild ──────────────────────────────────────────────────
if should_run 1; then
  echo -e "${CYAN}Phase 1: Source Rebuild${NC}"

  if [ "$DRY_RUN" = true ]; then
    local_conf="$PATCHES_DIR/pr-patches.conf"
    pr_count=$(grep -cE '^[0-9]' "$local_conf" 2>/dev/null || echo "0")
    info "Would run rebuild-with-patches.sh ($pr_count PRs in config) $FORCE_FLAG"
    P1_STATUS="DRY"; P1_SUMMARY="$pr_count PRs configured"
  else
    if bash "$PATCHES_DIR/rebuild-with-patches.sh" $FORCE_FLAG; then
      P1_STATUS="OK"
      # Try to extract applied count from rebuild output
      P1_SUMMARY="rebuild completed"
    else
      P1_STATUS="WARN"
      P1_SUMMARY="rebuild had errors (continuing)"
      warn "Phase 1 had errors — continuing with existing dist"
    fi
  fi
  echo ""
fi

# ── Phase 2: Dist Patches ───────────────────────────────────────────────────
if should_run 2; then
  echo -e "${CYAN}Phase 2: Dist Patches${NC}"

  if [ "$DRY_RUN" = true ]; then
    info "Would run dist-patches.sh (TLS probe, self-signed cert, LanceDB deps)"
    P2_STATUS="DRY"; P2_SUMMARY="3 patches configured"
  else
    set +e
    bash "$PATCHES_DIR/dist-patches.sh"
    DIST_EXIT=$?
    set -e

    if [ $DIST_EXIT -eq 0 ]; then
      P2_STATUS="OK"; P2_SUMMARY="all dist patches applied"
    else
      P2_STATUS="WARN"; P2_SUMMARY="$DIST_EXIT patch(es) failed"
      warn "Phase 2: $DIST_EXIT dist patch(es) failed"
    fi
  fi
  echo ""
fi

# ── Phase 3: Extension Patches ──────────────────────────────────────────────
if should_run 3; then
  echo -e "${CYAN}Phase 3: Extension Patches${NC}"
  COG_PATCH="$PATCHES_DIR/manual-patches/cognitive-memory-patch.sh"

  if [ "$DRY_RUN" = true ]; then
    if [ -f "$COG_PATCH" ]; then
      info "Would run cognitive-memory-patch.sh"
    else
      info "cognitive-memory-patch.sh not found — would skip"
    fi
    P3_STATUS="DRY"; P3_SUMMARY="cognitive-memory configured"
  else
    if [ -f "$COG_PATCH" ]; then
      set +e
      bash "$COG_PATCH"
      COG_EXIT=$?
      set -e

      if [ $COG_EXIT -eq 0 ]; then
        P3_STATUS="OK"; P3_SUMMARY="cognitive-memory applied"
      else
        P3_STATUS="FAIL"; P3_SUMMARY="cognitive-memory failed"
        fail "Phase 3: cognitive-memory-patch.sh failed"
      fi
    else
      P3_STATUS="SKIP"; P3_SUMMARY="cognitive-memory-patch.sh not found"
      warn "cognitive-memory-patch.sh not found"
    fi
  fi
  echo ""
fi

# ── Phase 4: Verify & Report ────────────────────────────────────────────────
echo -e "${CYAN}Phase 4: Verification${NC}"

V_PASSED=0
V_TOTAL=5
V_CHECKS="["

run_check() {
  local name="$1"
  local cmd="$2"

  if [ "$DRY_RUN" = true ]; then
    info "Would check: $name"
    [ "$V_CHECKS" != "[" ] && V_CHECKS="$V_CHECKS,"
    V_CHECKS="$V_CHECKS{\"name\":\"$name\",\"passed\":true}"
    V_PASSED=$((V_PASSED + 1))
    return
  fi

  if eval "$cmd" >/dev/null 2>&1; then
    ok "$name"
    [ "$V_CHECKS" != "[" ] && V_CHECKS="$V_CHECKS,"
    V_CHECKS="$V_CHECKS{\"name\":\"$name\",\"passed\":true}"
    V_PASSED=$((V_PASSED + 1))
  else
    fail "$name"
    [ "$V_CHECKS" != "[" ] && V_CHECKS="$V_CHECKS,"
    V_CHECKS="$V_CHECKS{\"name\":\"$name\",\"passed\":false}"
  fi
}

DIST_DIR="$(npm root -g)/openclaw/dist"

run_check "entry.js exists" \
  "[ -f '$DIST_DIR/entry.js' ]"

run_check "TLS probe patched" \
  "grep -q 'tls?.enabled.*\"wss\"' '$DIST_DIR'/daemon-cli*.js 2>/dev/null"

run_check "Self-signed cert patched" \
  "grep -q 'rejectUnauthorized' '$DIST_DIR'/client-*.js 2>/dev/null"

run_check "Cognitive memory patched" \
  "grep -q 'accessCount' '$(npm root -g)/openclaw/extensions/memory-lancedb/index.ts' 2>/dev/null"

run_check "openclaw --version" \
  "openclaw --version"

V_CHECKS="$V_CHECKS]"

END_TIME=$(date +%s)
DURATION=$((END_TIME - START_TIME))

# ── Write report ─────────────────────────────────────────────────────────────
if [ "$DRY_RUN" = false ]; then
  node -e "
    const report = {
      version: '$VERSION',
      timestamp: new Date().toISOString(),
      duration_seconds: $DURATION,
      phases: {
        'Phase 1 (Source Rebuild)': { status: '$P1_STATUS', summary: '$P1_SUMMARY' },
        'Phase 2 (Dist Patches)':  { status: '$P2_STATUS', summary: '$P2_SUMMARY' },
        'Phase 3 (Extensions)':    { status: '$P3_STATUS', summary: '$P3_SUMMARY' }
      },
      verification: {
        passed: $V_PASSED,
        total: $V_TOTAL,
        checks: $V_CHECKS
      }
    };
    require('fs').writeFileSync('$REPORT_FILE', JSON.stringify(report, null, 2));
  "
fi

# ── Summary ──────────────────────────────────────────────────────────────────
echo ""
echo -e "${CYAN}════════════════════════════════════════════════════${NC}"
echo -e "  Phase 1 (Source Rebuild):  ${P1_STATUS} — ${P1_SUMMARY}"
echo -e "  Phase 2 (Dist Patches):   ${P2_STATUS} — ${P2_SUMMARY}"
echo -e "  Phase 3 (Extensions):     ${P3_STATUS} — ${P3_SUMMARY}"
echo -e "  Phase 4 (Verification):   ${V_PASSED}/${V_TOTAL} checks passed"
echo -e "${CYAN}════════════════════════════════════════════════════${NC}"

if [ "$DRY_RUN" = false ] && [ "$SKIP_RESTART" = false ]; then
  echo ""
  echo "  Restart gateway to apply changes:"
  echo "  $ openclaw gateway restart"
fi

echo ""

# Exit non-zero if any verification failed
if [ $V_PASSED -lt $V_TOTAL ]; then
  exit 1
fi
exit 0
