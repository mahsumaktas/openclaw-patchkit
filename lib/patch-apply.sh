#!/usr/bin/env bash
# lib/patch-apply.sh — 5-strategy patch application engine
# Source: lib/common.sh must be loaded first
#
# Extracted from rebuild-with-patches.sh and upgrade-openclaw.sh
# into a shared library for reuse across CLI commands.
#
# Usage:
#   source lib/common.sh
#   source lib/patch-apply.sh
#   download_diffs OPEN_PRS_ARRAY DIFF_DIR
#   apply_patches SANDBOX_DIR DIFF_DIR OPEN_PRS_ARRAY

# ── Diff Download ─────────────────────────────────────────────────────────

download_diffs() {
  local _prs_name=$1
  local diff_dir="$2"
  local verbose="${3:-false}"

  # Bash 3.2 compatible: eval to copy array from variable name
  eval "local _prs=(\"\${${_prs_name}[@]}\")"
  local _prs_count=${#_prs[@]}

  mkdir -p "$diff_dir"

  local dl_ok=0 dl_fail=0
  local i=0
  for pr_num in "${_prs[@]}"; do
    local diff_file="$diff_dir/${pr_num}.diff"

    # Skip if already downloaded and valid
    if [ -s "$diff_file" ] && ! head -1 "$diff_file" 2>/dev/null | grep -q '<!DOCTYPE'; then
      dl_ok=$((dl_ok + 1))
      i=$((i + 1))
      continue
    fi

    # Primary: curl
    curl -sL "https://github.com/openclaw/openclaw/pull/${pr_num}.diff" > "$diff_file" 2>/dev/null

    # Fallback: gh api (if curl returned HTML — rate limited)
    if head -1 "$diff_file" 2>/dev/null | grep -q '<!DOCTYPE'; then
      sleep 2
      gh api "repos/openclaw/openclaw/pulls/${pr_num}" \
        --header 'Accept: application/vnd.github.v3.diff' > "$diff_file" 2>/dev/null || true
    fi

    if [ -s "$diff_file" ] && ! head -1 "$diff_file" 2>/dev/null | grep -q '<!DOCTYPE'; then
      dl_ok=$((dl_ok + 1))
    else
      dl_fail=$((dl_fail + 1))
      [ "$verbose" = true ] && warn "#$pr_num diff download failed"
    fi

    # Rate limit: pause every 30 downloads
    i=$((i + 1))
    if [ $(( i % 30 )) -eq 0 ]; then
      sleep 3
    fi
  done

  if [ $dl_fail -gt 0 ]; then
    info "Downloaded $dl_ok/$_prs_count diffs ($dl_fail failed)"
  else
    ok "Downloaded $_prs_count diffs"
  fi

  echo "$dl_ok"
}

# ── 6-Strategy Patch Application ──────────────────────────────────────────
#
# Strategy 0: Manual patch script (highest priority)
# Strategy 1: Clean git apply
# Strategy 2: Exclude test files (*.test.*, *.e2e.*)
# Strategy 3: Exclude changelog + test + live files
# Strategy 4: Fuzz -C1 + exclude test/CL/docs (shifted context lines)
# Strategy 5: 3-way merge (fallback)

apply_single_patch() {
  local pr_num="$1"
  local sandbox_dir="$2"
  local diff_dir="$3"
  local verbose="${4:-false}"

  local diff_file="$diff_dir/${pr_num}.diff"

  # Strategy 0: Manual script
  local manual_script
  manual_script=$(ls "$MANUAL_PATCHES"/${pr_num}-*.sh 2>/dev/null | head -1)
  if [ -n "$manual_script" ]; then
    if bash "$manual_script" "$sandbox_dir" 2>/dev/null; then
      [ "$verbose" = true ] && ok "#$pr_num manual script"
      echo "manual"
      return 0
    else
      [ "$verbose" = true ] && warn "#$pr_num manual script FAILED"
      echo "failed"
      return 1
    fi
  fi

  # Need diff file for remaining strategies
  if [ ! -s "$diff_file" ]; then
    [ "$verbose" = true ] && warn "#$pr_num no diff available"
    echo "failed"
    return 1
  fi

  # Use -C to apply in sandbox_dir without changing CWD
  local git_apply="git -C $sandbox_dir apply"

  # Strategy 1: Clean apply
  if $git_apply --check "$diff_file" 2>/dev/null; then
    $git_apply "$diff_file" 2>/dev/null
    [ "$verbose" = true ] && ok "#$pr_num clean apply"
    echo "clean"
    return 0
  fi

  # Strategy 2: Exclude test files
  if $git_apply --check --exclude='*.test.*' --exclude='*.e2e.*' "$diff_file" 2>/dev/null; then
    $git_apply --exclude='*.test.*' --exclude='*.e2e.*' "$diff_file" 2>/dev/null
    [ "$verbose" = true ] && ok "#$pr_num exclude-test"
    echo "exclude-test"
    return 0
  fi

  # Strategy 3: Exclude changelog + test + live
  if $git_apply --check --exclude='CHANGELOG.md' --exclude='*.test.*' --exclude='*.e2e.*' --exclude='*.live.*' "$diff_file" 2>/dev/null; then
    $git_apply --exclude='CHANGELOG.md' --exclude='*.test.*' --exclude='*.e2e.*' --exclude='*.live.*' "$diff_file" 2>/dev/null
    [ "$verbose" = true ] && ok "#$pr_num exclude-cl+test"
    echo "exclude-cl+test"
    return 0
  fi

  # Strategy 4: Fuzz -C1 + exclude test/changelog/docs (context lines shifted but target valid)
  if $git_apply --check -C1 --exclude='CHANGELOG.md' --exclude='*.test.*' --exclude='*.e2e.*' --exclude='*.live.*' --exclude='docs/*' "$diff_file" 2>/dev/null; then
    $git_apply -C1 --exclude='CHANGELOG.md' --exclude='*.test.*' --exclude='*.e2e.*' --exclude='*.live.*' --exclude='docs/*' "$diff_file" 2>/dev/null
    [ "$verbose" = true ] && ok "#$pr_num fuzz-C1"
    echo "fuzz-C1"
    return 0
  fi

  # Strategy 5: 3-way merge
  if $git_apply --check --3way "$diff_file" 2>/dev/null; then
    $git_apply --3way "$diff_file" 2>/dev/null
    [ "$verbose" = true ] && ok "#$pr_num 3way merge"
    echo "3way"
    return 0
  fi

  [ "$verbose" = true ] && warn "#$pr_num ALL strategies failed"
  echo "failed"
  return 1
}

# Apply all patches from conf file
# Returns: sets global PA_APPLIED, PA_FAILED, PA_FAILED_LIST, PA_STRATEGY_COUNTS
apply_patches() {
  local sandbox_dir="$1"
  local diff_dir="$2"
  local verbose="${3:-false}"

  PA_APPLIED=0
  PA_FAILED=0
  PA_FAILED_LIST=()
  # Strategy counters (bash 3.2 compatible — no associative arrays)
  local _sc_manual=0 _sc_clean=0 _sc_exctest=0 _sc_exccl=0 _sc_fuzzc1=0 _sc_3way=0

  # Read active PRs from conf
  local active_prs=()
  while IFS='|' read -r pr_num description; do
    pr_num=$(echo "$pr_num" | tr -d ' ')
    [[ "$pr_num" =~ ^[[:space:]]*# ]] && continue
    [[ -z "$pr_num" ]] && continue
    [[ "$pr_num" =~ ^[[:space:]]*EXP- ]] && continue
    [[ "$pr_num" =~ ^[[:space:]]*FIX- ]] && continue
    active_prs+=("$pr_num")
  done < "$CONF"

  info "Applying ${#active_prs[@]} patches..."

  for pr_num in "${active_prs[@]}"; do
    local strategy
    strategy=$(apply_single_patch "$pr_num" "$sandbox_dir" "$diff_dir" "$verbose") || true

    if [ "$strategy" = "failed" ]; then
      PA_FAILED=$((PA_FAILED + 1))
      PA_FAILED_LIST+=("$pr_num")
    else
      PA_APPLIED=$((PA_APPLIED + 1))
      case "$strategy" in
        manual)         _sc_manual=$((_sc_manual + 1)) ;;
        clean)          _sc_clean=$((_sc_clean + 1)) ;;
        exclude-test)   _sc_exctest=$((_sc_exctest + 1)) ;;
        exclude-cl+test) _sc_exccl=$((_sc_exccl + 1)) ;;
        fuzz-C1)        _sc_fuzzc1=$((_sc_fuzzc1 + 1)) ;;
        3way)           _sc_3way=$((_sc_3way + 1)) ;;
      esac
    fi
  done

  # Summary line
  local strat_parts=""
  [ $_sc_manual -gt 0 ] && strat_parts="${strat_parts}${_sc_manual} manual, "
  [ $_sc_clean -gt 0 ] && strat_parts="${strat_parts}${_sc_clean} clean, "
  [ $_sc_exctest -gt 0 ] && strat_parts="${strat_parts}${_sc_exctest} exclude-test, "
  [ $_sc_exccl -gt 0 ] && strat_parts="${strat_parts}${_sc_exccl} exclude-cl+test, "
  [ $_sc_fuzzc1 -gt 0 ] && strat_parts="${strat_parts}${_sc_fuzzc1} fuzz-C1, "
  [ $_sc_3way -gt 0 ] && strat_parts="${strat_parts}${_sc_3way} 3way, "
  strat_parts="${strat_parts%, }"

  echo ""
  ok "Applied: $PA_APPLIED/$((PA_APPLIED + PA_FAILED)) ($strat_parts)"
  if [ $PA_FAILED -gt 0 ]; then
    warn "Failed: ${PA_FAILED_LIST[*]}"
  fi
}

# ── FIX Script Application ───────────────────────────────────────────────

apply_fix_scripts() {
  local target_dir="$1"
  local verbose="${2:-false}"

  local fix_applied=0
  local fix_failed=0
  local fix_scripts=("$MANUAL_PATCHES"/FIX-*-*.sh)

  # Check if glob matched anything
  if [ ! -f "${fix_scripts[0]}" ]; then
    info "No FIX scripts found"
    return 0
  fi

  info "Applying ${#fix_scripts[@]} FIX scripts..."

  for fix_script in "${fix_scripts[@]}"; do
    local fix_name
    fix_name=$(basename "$fix_script" .sh)

    if bash "$fix_script" "$target_dir" 2>/dev/null; then
      [ "$verbose" = true ] && ok "$fix_name applied"
      fix_applied=$((fix_applied + 1))
    else
      warn "$fix_name FAILED"
      fix_failed=$((fix_failed + 1))
    fi
  done

  ok "Fixes: $fix_applied/${#fix_scripts[@]} applied"
  echo "$fix_applied"
}

# ── Expansion Script Application ──────────────────────────────────────────

apply_expansion_scripts() {
  local target_dir="$1"
  local verbose="${2:-false}"

  local exp_applied=0
  local exp_failed=0
  local exp_scripts=("$MANUAL_PATCHES"/EXP-*-*.sh)

  if [ ! -f "${exp_scripts[0]}" ]; then
    info "No expansion scripts found"
    return 0
  fi

  info "Applying ${#exp_scripts[@]} expansion scripts..."

  for exp_script in "${exp_scripts[@]}"; do
    local exp_name
    exp_name=$(basename "$exp_script" .sh)

    if bash "$exp_script" "$target_dir" 2>/dev/null; then
      [ "$verbose" = true ] && ok "$exp_name applied"
      exp_applied=$((exp_applied + 1))
    else
      warn "$exp_name FAILED"
      exp_failed=$((exp_failed + 1))
    fi
  done

  ok "Expansions: $exp_applied/${#exp_scripts[@]} applied"
  echo "$exp_applied"
}

# ── Retirement Scan ───────────────────────────────────────────────────────
# Check which PRs have been merged upstream and should be retired

scan_retirements() {
  local verbose="${1:-false}"

  # Collect PR numbers from conf
  local all_prs=()
  while IFS='|' read -r pr_num description; do
    pr_num=$(echo "$pr_num" | tr -d ' ')
    [[ "$pr_num" =~ ^[[:space:]]*# ]] && continue
    [[ -z "$pr_num" ]] && continue
    [[ "$pr_num" =~ ^[[:space:]]*EXP- ]] && continue
    [[ "$pr_num" =~ ^[[:space:]]*FIX- ]] && continue
    all_prs+=("$pr_num")
  done < "$CONF"

  info "Checking ${#all_prs[@]} PRs for retirement (batch)..."

  # Batch check using GraphQL (50 PRs per query, much faster than REST)
  local merged_prs=()
  local closed_prs=()

  local batch_size=25
  local i=0
  while [ $i -lt ${#all_prs[@]} ]; do
    # Build GraphQL query for this batch
    local query="query {"
    local j=0
    local batch_nums=()
    while [ $j -lt $batch_size ] && [ $((i + j)) -lt ${#all_prs[@]} ]; do
      local pr="${all_prs[$((i + j))]}"
      batch_nums+=("$pr")
      query="$query pr_$pr: repository(owner:\"openclaw\",name:\"openclaw\"){pullRequest(number:$pr){state merged}}"
      j=$((j + 1))
    done
    query="$query }"

    # Execute batch query
    local result
    result=$(gh api graphql -f query="$query" 2>/dev/null || echo '{}')

    # Parse all results in single python3 call
    local parsed
    parsed=$(echo "$result" | python3 -c "
import json, sys
data = json.load(sys.stdin).get('data', {})
for key, val in data.items():
    pr_num = key.replace('pr_', '')
    pr_data = val.get('pullRequest', {}) if val else {}
    state = pr_data.get('state', 'UNKNOWN').lower()
    merged = str(pr_data.get('merged', False)).lower()
    print(f'{pr_num} {state} {merged}')
" 2>/dev/null || true)

    # Parse output lines
    while IFS=' ' read -r pr_num state merged_val; do
      [ -z "$pr_num" ] && continue
      if [ "$merged_val" = "true" ]; then
        merged_prs+=("$pr_num")
        [ "$verbose" = true ] && warn "#$pr_num MERGED upstream"
      elif [ "$state" = "closed" ]; then
        closed_prs+=("$pr_num")
        [ "$verbose" = true ] && info "#$pr_num closed (not merged)"
      fi
    done <<< "$parsed"

    i=$((i + batch_size))
  done

  if [ ${#merged_prs[@]} -gt 0 ]; then
    warn "${#merged_prs[@]} PR(s) merged upstream: ${merged_prs[*]}"
  fi
  if [ ${#closed_prs[@]} -gt 0 ]; then
    info "${#closed_prs[@]} PR(s) closed (not merged): ${closed_prs[*]}"
  fi

  # Export for caller (safe for set -u)
  SCAN_MERGED_PRS=("${merged_prs[@]+"${merged_prs[@]}"}")
  SCAN_CLOSED_PRS=("${closed_prs[@]+"${closed_prs[@]}"}")
}
