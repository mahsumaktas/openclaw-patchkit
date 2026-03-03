#!/usr/bin/env bash
# commands/upgrade.sh — Unified upgrade pipeline
# Source: lib/common.sh must already be loaded (by bin/patchkit)
#
# Usage:
#   patchkit upgrade v2026.3.2              # Full upgrade
#   patchkit upgrade v2026.3.2 --dry-run    # Analyze only
#   patchkit upgrade --rollback             # Revert to previous
#   patchkit upgrade --status               # Show current state
#
# 12-Phase Pipeline:
#   1. Pre-flight (disk, auth, version check)
#   2. Snapshot (config, extensions, plists)
#   3. Retirement scan (merged PRs)
#   4. npm install -g (upgrade base)
#   5. Built-in disable (conflicting extensions)
#   6. FIX validate (pattern check)
#   7. Sandbox build (clone + patch + build)
#   8. Config migrate (renames, defaults, plist)
#   9. Atomic swap (dist replacement)
#  10. Plist reconcile (LaunchAgent update)
#  11. Health probe (gateway restart + check)
#  12. Extension verify (load check)

source "$PATCHKIT_ROOT/lib/patch-apply.sh"
source "$PATCHKIT_ROOT/lib/builtin-disable.sh"
source "$PATCHKIT_ROOT/lib/fix-validate.sh"
source "$PATCHKIT_ROOT/lib/config-migrate.sh"
source "$PATCHKIT_ROOT/lib/extension-guard.sh"

REPO="https://github.com/openclaw/openclaw.git"
DIFF_DIR="/tmp/oc-pr-diffs"
UPGRADE_LOG="$HISTORY_DIR/upgrades.jsonl"

cmd_upgrade() {
  local target_tag=""
  local dry_run=false
  local rollback=false
  local show_status=false
  local verbose=false

  # Parse args
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --dry-run)   dry_run=true; shift ;;
      --rollback)  rollback=true; shift ;;
      --status)    show_status=true; shift ;;
      --verbose)   verbose=true; shift ;;
      v*)          target_tag="$1"; shift ;;
      *)           fail "Unknown argument: $1"; return 1 ;;
    esac
  done

  local current_version
  current_version=$(get_openclaw_version)

  # ── --status ────────────────────────────────────────────────────────
  if [ "$show_status" = true ]; then
    _upgrade_status "$current_version"
    return 0
  fi

  # ── --rollback ──────────────────────────────────────────────────────
  if [ "$rollback" = true ]; then
    _upgrade_rollback "$current_version"
    return $?
  fi

  # ── Upgrade requires target ─────────────────────────────────────────
  if [ -z "$target_tag" ]; then
    fail "Usage: patchkit upgrade v2026.X.Y [--dry-run] [--verbose]"
    return 1
  fi

  local target_version="${target_tag#v}"
  local sandbox="/tmp/openclaw-upgrade-$(date +%s)"
  local start_time
  start_time=$(date +%s)

  echo ""
  echo -e "${BOLD}${CYAN}Patchkit Upgrade Pipeline${NC}"
  echo "  Current: v$current_version"
  echo "  Target:  $target_tag"
  echo "  Mode:    $([ "$dry_run" = true ] && echo "DRY RUN" || echo "LIVE")"
  echo ""

  # ══════════════════════════════════════════════════════════════════════
  # PHASE 1: PRE-FLIGHT
  # ══════════════════════════════════════════════════════════════════════
  step "Phase 1: Pre-flight"

  check_disk_space 3 || return 1
  check_gh_auth || return 1

  # Version sanity check
  if [ "$current_version" = "$target_version" ]; then
    warn "Already on v$target_version"
    return 0
  fi

  # Check target tag exists
  if ! gh api "repos/openclaw/openclaw/git/ref/tags/$target_tag" >/dev/null 2>&1; then
    fail "Tag $target_tag not found on GitHub"
    return 1
  fi

  ok "Target tag verified: $target_tag"

  # Upstream change analysis
  info "Analyzing upstream changes..."
  local changed_files_cache="/tmp/oc-upgrade-changes-$$.txt"

  gh api "repos/openclaw/openclaw/compare/v${current_version}...${target_tag}" \
    --jq '.files[].filename' > "$changed_files_cache" 2>/dev/null || {
    warn "GitHub Compare API failed — using git fallback"
    local fallback_dir="/tmp/openclaw-compare-$$"
    git clone --depth 1 --branch "v$current_version" "$REPO" "$fallback_dir/old" 2>/dev/null
    git clone --depth 1 --branch "$target_tag" "$REPO" "$fallback_dir/new" 2>/dev/null
    diff -rq "$fallback_dir/old/src" "$fallback_dir/new/src" 2>/dev/null | \
      sed 's|.*src/|src/|' | awk '{print $1}' > "$changed_files_cache" || true
    rm -rf "$fallback_dir"
  }

  local total_changed
  total_changed=$(wc -l < "$changed_files_cache" | tr -d ' ')
  ok "Upstream: $total_changed files changed"

  if [ "$dry_run" = true ]; then
    info "Dry run — skipping to analysis..."
  fi

  # ══════════════════════════════════════════════════════════════════════
  # PHASE 2: SNAPSHOT
  # ══════════════════════════════════════════════════════════════════════
  step "Phase 2: Snapshot"

  local snapshot_id
  snapshot_id=$(create_snapshot)
  ok "Snapshot: $snapshot_id"

  # ══════════════════════════════════════════════════════════════════════
  # PHASE 3: RETIREMENT SCAN
  # ══════════════════════════════════════════════════════════════════════
  step "Phase 3: Retirement Scan"

  scan_retirements "$verbose"

  local merged_count=${#SCAN_MERGED_PRS[@]}
  if [ "$merged_count" -gt 0 ]; then
    warn "$merged_count PR(s) should be retired before upgrade"
    if [ "$dry_run" = false ]; then
      info "Auto-retiring merged PRs..."
      for pr_num in "${SCAN_MERGED_PRS[@]}"; do
        # Comment out in conf
        if grep -q "^${pr_num}" "$CONF" 2>/dev/null; then
          # Use python for safe in-place edit (macOS sed + symlink issues)
          python3 -c "
import re, sys
conf = sys.argv[1]
pr = sys.argv[2]
with open(conf) as f:
    lines = f.readlines()
with open(conf, 'w') as f:
    for line in lines:
        if line.strip().startswith(pr + '|') or line.strip().startswith(pr + ' '):
            f.write(f'# RETIRED(auto-{__import__(\"datetime\").date.today()}): {line}')
        else:
            f.write(line)
" "$CONF" "$pr_num"
          ok "Retired #$pr_num from conf"
        fi
      done
      # Log
      local merged_json
      merged_json=$(printf '%s\n' "${SCAN_MERGED_PRS[@]}" | python3 -c "import json,sys; print(json.dumps([int(x.strip()) for x in sys.stdin if x.strip()]))")
      log_event "retirement_scan" "{\"merged\": $merged_json, \"version\": \"$target_tag\"}"
    fi
  else
    ok "No merged PRs found — all patches still active"
  fi

  # ══════════════════════════════════════════════════════════════════════
  # PHASE 4: NPM INSTALL (base upgrade)
  # ══════════════════════════════════════════════════════════════════════
  step "Phase 4: Base Upgrade (npm)"

  if [ "$dry_run" = true ]; then
    info "[DRY-RUN] Would run: sudo npm install -g openclaw@$target_version"
  else
    info "Installing openclaw@$target_version..."
    if sudo npm install -g "openclaw@$target_version" 2>&1 | tail -3; then
      local new_version
      new_version=$(get_openclaw_version)
      ok "Base upgraded: v$current_version -> v$new_version"
    else
      fail "npm install failed — live system on v$current_version (unchanged)"
      return 1
    fi
  fi

  # ══════════════════════════════════════════════════════════════════════
  # PHASE 5: BUILT-IN DISABLE
  # ══════════════════════════════════════════════════════════════════════
  step "Phase 5: Built-in Extension Disable"

  if [ "$dry_run" = true ]; then
    info "[DRY-RUN] Would disable built-in extensions"
    verify_builtin_disabled || true
  else
    disable_builtin_extensions
    verify_builtin_disabled || {
      fail "Built-in extensions still active — cannot proceed"
      return 1
    }
  fi

  # ══════════════════════════════════════════════════════════════════════
  # PHASE 6: FIX VALIDATE
  # ══════════════════════════════════════════════════════════════════════
  step "Phase 6: FIX Pattern Validation"

  validate_all_fixes || {
    warn "Some FIX patches need adaptation — they will be skipped during build"
  }

  # ══════════════════════════════════════════════════════════════════════
  # PHASE 7: SANDBOX BUILD
  # ══════════════════════════════════════════════════════════════════════
  step "Phase 7: Sandbox Build"

  if [ "$dry_run" = true ]; then
    info "[DRY-RUN] Would clone $target_tag, apply patches, and build"

    # Show patch overlap analysis (uses changed_files_cache)
    _analyze_patch_overlaps "$changed_files_cache" "$verbose"

    rm -f "$changed_files_cache"
    echo ""
    info "Dry run complete. No changes made."
    return 0
  fi

  info "Cloning $target_tag..."
  git clone --depth 200 --branch "$target_tag" "$REPO" "$sandbox" 2>&1 | tail -1
  cd "$sandbox"
  git checkout -b patched-build 2>/dev/null

  # Download diffs
  local active_prs=()
  while IFS='|' read -r pr_num desc; do
    pr_num=$(echo "$pr_num" | tr -d ' ')
    [[ "$pr_num" =~ ^[[:space:]]*# ]] && continue
    [[ -z "$pr_num" ]] && continue
    [[ "$pr_num" =~ ^[[:space:]]*EXP- ]] && continue
    [[ "$pr_num" =~ ^[[:space:]]*FIX- ]] && continue
    active_prs+=("$pr_num")
  done < "$CONF"

  download_diffs active_prs "$DIFF_DIR" "$verbose"

  # Apply patches
  apply_patches "$sandbox" "$DIFF_DIR" "$verbose"
  local patch_applied=$PA_APPLIED
  local patch_failed=$PA_FAILED

  # Apply FIX scripts
  local fix_count
  fix_count=$(apply_fix_scripts "$sandbox" "$verbose" | tail -1)

  # Apply expansion scripts
  apply_expansion_scripts "$sandbox" "$verbose"

  # Build
  info "Installing dependencies..."
  if ! pnpm install --frozen-lockfile 2>&1 | tail -3; then
    fail "pnpm install failed — aborting"
    rm -rf "$sandbox"
    return 1
  fi

  info "Building..."
  if ! pnpm build 2>&1 | tail -5; then
    fail "Build FAILED — live system untouched"
    rm -rf "$sandbox"
    return 1
  fi

  # Verify build output
  if [ ! -f "$sandbox/dist/index.js" ] && [ ! -f "$sandbox/dist/entry.js" ]; then
    fail "No entry point in dist/ after build — aborting"
    rm -rf "$sandbox"
    return 1
  fi

  ok "Sandbox build successful"

  # ══════════════════════════════════════════════════════════════════════
  # PHASE 8: CONFIG MIGRATE
  # ══════════════════════════════════════════════════════════════════════

  run_config_migration "v$current_version" "$target_tag"

  # ══════════════════════════════════════════════════════════════════════
  # PHASE 9: ATOMIC SWAP
  # ══════════════════════════════════════════════════════════════════════
  step "Phase 9: Atomic Dist Swap"

  local backup_dir="$PATCHKIT_ROOT/dist-backup-${target_version}"

  # Backup current dist
  if [ ! -d "$backup_dir" ]; then
    info "Backing up current dist..."
    cp -R "$OPENCLAW_DIST" "$backup_dir"
    ok "Backup: $backup_dir"
  fi

  # Swap dist contents
  info "Replacing dist..."
  sudo find "$OPENCLAW_DIST" -mindepth 1 -delete 2>/dev/null || true
  sudo cp -R "$sandbox/dist/"* "$OPENCLAW_DIST/"
  sudo chown -R "$(whoami):staff" "$OPENCLAW_DIST" 2>/dev/null || true
  ok "Dist replaced with patched build"

  # ══════════════════════════════════════════════════════════════════════
  # PHASE 10: PLIST RECONCILE
  # ══════════════════════════════════════════════════════════════════════
  step "Phase 10: LaunchAgent Reconcile"

  update_plist_version "$target_tag"
  ok "Plist version updated"

  # ══════════════════════════════════════════════════════════════════════
  # PHASE 11: HEALTH PROBE
  # ══════════════════════════════════════════════════════════════════════
  step "Phase 11: Health Probe"

  stop_gateway || true
  sleep 1
  start_gateway || {
    fail "Gateway failed to start — rolling back!"
    _emergency_rollback "$backup_dir" "$snapshot_id" "$current_version"
    return 1
  }

  # Health check loop
  local health_ok=false
  for i in $(seq 1 12); do
    if ! is_gateway_running; then
      warn "Health check $i/12: gateway not running"
      sleep 5
      continue
    fi

    local http_status
    http_status=$(curl -sk -o /dev/null -w "%{http_code}" "https://127.0.0.1:28643/" 2>/dev/null || echo "000")

    if [ "$http_status" != "000" ]; then
      ok "Health check $i/12: PID alive, HTTPS $http_status"
      health_ok=true
      break
    fi

    warn "Health check $i/12: HTTPS not responding"
    sleep 5
  done

  if [ "$health_ok" = false ]; then
    fail "Gateway failed health checks — rolling back!"
    _emergency_rollback "$backup_dir" "$snapshot_id" "$current_version"
    return 1
  fi

  ok "Gateway healthy on v$target_version"

  # ══════════════════════════════════════════════════════════════════════
  # PHASE 12: EXTENSION VERIFY
  # ══════════════════════════════════════════════════════════════════════

  reinstall_extension_deps
  sleep 3

  # Restart gateway to load extensions with new deps
  if is_gateway_running; then
    stop_gateway || true
    sleep 1
    start_gateway || true
    sleep 5
  fi

  verify_extensions_loaded || warn "Some extensions may need manual verification"

  # ══════════════════════════════════════════════════════════════════════
  # REPORT
  # ══════════════════════════════════════════════════════════════════════
  step "Upgrade Complete"

  local end_time
  end_time=$(date +%s)
  local duration=$((end_time - start_time))

  # Log
  mkdir -p "$HISTORY_DIR"
  python3 -c "
import json, sys, datetime
ts = datetime.datetime.utcnow().strftime('%Y-%m-%dT%H:%M:%SZ')
entry = {'timestamp': ts, 'action': 'upgrade', 'from': sys.argv[1], 'to': sys.argv[2],
         'applied': int(sys.argv[3]), 'failed': int(sys.argv[4]), 'merged': int(sys.argv[5]),
         'health': 'ok', 'duration': int(sys.argv[6]), 'snapshot': sys.argv[7]}
print(json.dumps(entry))
" "v$current_version" "$target_tag" "$patch_applied" "$patch_failed" "$merged_count" "$duration" "$snapshot_id" >> "$UPGRADE_LOG"

  # Discord notification
  notify "Upgrade Complete" "v$current_version -> $target_tag | $patch_applied patches | ${duration}s" "green"

  echo ""
  echo -e "${BOLD}Summary${NC}"
  echo "  From:     v$current_version"
  echo "  To:       $target_tag"
  echo "  Duration: ${duration}s"
  echo "  Patches:  $patch_applied applied, $patch_failed failed"
  echo "  Merged:   $merged_count (auto-retired)"
  echo "  Health:   OK"
  echo "  Snapshot: $snapshot_id"
  echo "  Backup:   $backup_dir"
  echo ""
  echo "  Rollback: patchkit upgrade --rollback"

  # Cleanup
  rm -rf "$sandbox" "$changed_files_cache" "$DIFF_DIR"
}

# ── Internal helpers ──────────────────────────────────────────────────────

_upgrade_status() {
  local current_version="$1"

  echo -e "${BOLD}Patchkit Status${NC}"
  echo "  Version:  v$current_version"
  echo "  Root:     $OPENCLAW_ROOT"

  # Patch counts
  local active_count
  active_count=$(grep -cE '^[0-9]' "$CONF" 2>/dev/null || echo "0")
  local fix_count
  fix_count=$(find "$MANUAL_PATCHES" -maxdepth 1 -name 'FIX-*.sh' 2>/dev/null | wc -l | tr -d ' ')
  echo "  Patches:  $active_count active + $fix_count FIX"

  # Snapshots
  local snapshot_count=0
  if [ -d "$HISTORY_DIR/snapshots" ]; then
    snapshot_count=$(find "$HISTORY_DIR/snapshots" -maxdepth 1 -mindepth 1 -type d 2>/dev/null | wc -l | tr -d ' ')
  fi
  echo "  Snapshots: $snapshot_count"

  # Last upgrade
  if [ -f "$UPGRADE_LOG" ]; then
    local last_upgrade
    last_upgrade=$(tail -1 "$UPGRADE_LOG" 2>/dev/null)
    if [ -n "$last_upgrade" ]; then
      local last_ts last_to
      last_ts=$(echo "$last_upgrade" | python3 -c "import json,sys; print(json.load(sys.stdin).get('timestamp',''))" 2>/dev/null)
      last_to=$(echo "$last_upgrade" | python3 -c "import json,sys; print(json.load(sys.stdin).get('to',''))" 2>/dev/null)
      echo "  Last upgrade: $last_ts -> $last_to"
    fi
  fi

  # Built-in status
  echo ""
  verify_builtin_disabled 2>/dev/null || true

  # Gateway
  echo ""
  if is_gateway_running; then
    ok "Gateway: running"
  else
    warn "Gateway: not running"
  fi
}

_upgrade_rollback() {
  local current_version="$1"

  step "Rollback"

  # Find latest snapshot
  local latest_snapshot
  latest_snapshot=$(ls -1t "$HISTORY_DIR/snapshots/" 2>/dev/null | head -1)

  if [ -z "$latest_snapshot" ]; then
    fail "No snapshots available for rollback"
    return 1
  fi

  # Find latest dist backup
  local latest_backup
  latest_backup=$(ls -1dt "$PATCHKIT_ROOT"/dist-backup-* 2>/dev/null | head -1)

  if [ -z "$latest_backup" ]; then
    fail "No dist backup available for rollback"
    return 1
  fi

  info "Rolling back to snapshot: $latest_snapshot"
  info "Dist backup: $(basename "$latest_backup")"

  # Restore config snapshot
  restore_snapshot "$latest_snapshot"

  # Restore dist
  info "Restoring dist..."
  sudo find "$OPENCLAW_DIST" -mindepth 1 -delete 2>/dev/null || true
  sudo cp -R "$latest_backup/"* "$OPENCLAW_DIST/"
  ok "Dist restored from $(basename "$latest_backup")"

  # Disable builtins (npm install may have restored them)
  disable_builtin_extensions 2>/dev/null || true

  # Restart gateway
  stop_gateway || true
  sleep 1
  start_gateway || warn "Gateway restart failed — manual restart needed"

  # Log
  mkdir -p "$HISTORY_DIR"
  echo "{\"timestamp\":\"$(date -u +%Y-%m-%dT%H:%M:%SZ)\",\"action\":\"rollback\",\"from\":\"v$current_version\",\"snapshot\":\"$latest_snapshot\",\"backup\":\"$(basename "$latest_backup")\"}" >> "$UPGRADE_LOG"

  notify "Rollback" "v$current_version -> $(basename "$latest_backup")" "yellow"
  ok "Rollback complete"
}

_emergency_rollback() {
  local backup_dir="$1"
  local snapshot_id="$2"
  local original_version="$3"

  warn "Emergency rollback initiated..."

  # Restore dist
  if [ -d "$backup_dir" ]; then
    sudo find "$OPENCLAW_DIST" -mindepth 1 -delete 2>/dev/null || true
    sudo cp -R "$backup_dir/"* "$OPENCLAW_DIST/"
    ok "Dist restored from backup"
  fi

  # Restore config snapshot
  if [ -n "$snapshot_id" ]; then
    restore_snapshot "$snapshot_id"
  fi

  # Disable builtins
  disable_builtin_extensions 2>/dev/null || true

  # Restart
  stop_gateway 2>/dev/null || true
  sleep 1
  start_gateway 2>/dev/null || warn "Gateway failed to restart after rollback"

  notify "Emergency Rollback" "Upgrade failed — rolled back to v$original_version" "red"
  fail "Upgrade failed — system rolled back to v$original_version"
}

_analyze_patch_overlaps() {
  local changed_files_cache="$1"
  local verbose="$2"

  if [ ! -f "$changed_files_cache" ]; then
    return 0
  fi

  local clean=0 overlap=0 merged=0

  while IFS='|' read -r pr_num description; do
    pr_num=$(echo "$pr_num" | tr -d ' ')
    [[ "$pr_num" =~ ^[[:space:]]*# ]] && continue
    [[ -z "$pr_num" ]] && continue
    [[ "$pr_num" =~ ^[[:space:]]*EXP- ]] && continue
    [[ "$pr_num" =~ ^[[:space:]]*FIX- ]] && continue

    local pr_merged
    pr_merged=$(gh api "repos/openclaw/openclaw/pulls/$pr_num" --jq '.merged' 2>/dev/null || echo "false")
    if [ "$pr_merged" = "true" ]; then
      merged=$((merged + 1))
      [ "$verbose" = true ] && warn "#$pr_num: MERGED"
      continue
    fi

    # File overlap check
    local pr_files has_overlap=false
    pr_files=$(gh api "repos/openclaw/openclaw/pulls/$pr_num/files" --jq '.[].filename' 2>/dev/null || echo "")
    while IFS= read -r pf; do
      [ -z "$pf" ] && continue
      if grep -qF "$pf" "$changed_files_cache" 2>/dev/null; then
        has_overlap=true
        break
      fi
    done <<< "$pr_files"

    if [ "$has_overlap" = true ]; then
      overlap=$((overlap + 1))
      [ "$verbose" = true ] && warn "#$pr_num: FILE OVERLAP"
    else
      clean=$((clean + 1))
    fi
  done < "$CONF"

  echo ""
  echo -e "  Overlap analysis:"
  echo -e "    Clean:   ${GREEN}$clean${NC}"
  echo -e "    Overlap: ${YELLOW}$overlap${NC}"
  echo -e "    Merged:  ${CYAN}$merged${NC}"
}
