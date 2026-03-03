#!/usr/bin/env bash
# commands/add.sh — Add a new PR patch to patchkit
# Loaded by: bin/patchkit

cmd_add() {
  local pr_number="$1"
  local risk_override=""
  local category_override=""

  # Parse optional flags
  shift || true
  while [ $# -gt 0 ]; do
    case "$1" in
      --risk=*) risk_override="${1#*=}" ;;
      --category=*) category_override="${1#*=}" ;;
      *) warn "Unknown flag: $1" ;;
    esac
    shift
  done

  if [ -z "$pr_number" ] || ! [[ "$pr_number" =~ ^[0-9]+$ ]]; then
    fail "Usage: patchkit add <PR_NUMBER> [--risk=LEVEL] [--category=CAT]"
    exit 1
  fi

  step "Adding PR #$pr_number to patchkit"

  # 1. Check if already exists
  if yq -o=json '.' "$PATCHES_YAML" | python3 -c "
import json, sys
data = json.load(sys.stdin)
for p in data.get('patches', []):
    if p.get('pr') == $pr_number:
        exit(0)
exit(1)
" 2>/dev/null; then
    fail "PR #$pr_number already in patchkit"
    exit 1
  fi

  # 2. Fetch PR info from GitHub
  info "Fetching PR info..."
  local pr_json
  pr_json=$(gh_api_retry "repos/openclaw/openclaw/pulls/$pr_number")

  if [ -z "$pr_json" ]; then
    fail "Could not fetch PR #$pr_number from GitHub"
    exit 1
  fi

  local pr_title pr_state pr_author
  local _pr_fields
  _pr_fields=$(echo "$pr_json" | python3 -c "
import json, sys
d = json.loads(sys.stdin.read())
print(d['title'])
print(d['state'])
print(d['user']['login'])
")
  pr_title=$(echo "$_pr_fields" | sed -n '1p')
  pr_state=$(echo "$_pr_fields" | sed -n '2p')
  pr_author=$(echo "$_pr_fields" | sed -n '3p')

  if [ "$pr_state" != "open" ]; then
    warn "PR #$pr_number is $pr_state (not open)"
    echo -n "  Continue anyway? [y/N] "
    read -r answer
    [ "$answer" != "y" ] && exit 0
  fi

  ok "PR: $pr_title (by $pr_author, $pr_state)"

  # 3. Fetch affected files
  info "Fetching affected files..."
  local files_json
  files_json=$(gh_api_retry "repos/openclaw/openclaw/pulls/$pr_number/files")

  local affected_files
  affected_files=$(echo "$files_json" | python3 -c "
import json, sys
files = json.loads(sys.stdin.read())
for f in files:
    print(f['filename'])
")

  local file_count
  file_count=$(echo "$affected_files" | wc -l | tr -d ' ')
  ok "Affects $file_count file(s)"

  # 4. Auto-categorize
  local category
  if [ -n "$category_override" ]; then
    category="$category_override"
  else
    category=$(echo "$affected_files" | python3 -c "
import sys
files = sys.stdin.read().strip().split('\n')
cats = {
    'security': ['security', 'auth', 'sanitize', 'csrf', 'xss'],
    'gateway': ['gateway', 'daemon', 'process', 'server-http', 'launchd'],
    'session': ['session', 'compaction', 'transcript', 'compact'],
    'channel': ['discord', 'telegram', 'slack', 'signal', 'whatsapp'],
    'memory': ['memory', 'lancedb', 'embedding', 'bm25'],
    'config': ['config', 'env', 'plist', 'settings'],
}
for cat, keywords in cats.items():
    for f in files:
        fl = f.lower()
        if any(k in fl for k in keywords):
            print(cat)
            exit()
print('stability')
")
  fi
  info "Category: $category"

  # 5. Auto-risk assessment
  local risk
  if [ -n "$risk_override" ]; then
    risk="$risk_override"
  else
    local additions deletions _churn
    _churn=$(echo "$pr_json" | python3 -c "import json,sys; d=json.loads(sys.stdin.read()); print(d['additions']); print(d['deletions'])")
    additions=$(echo "$_churn" | sed -n '1p')
    deletions=$(echo "$_churn" | sed -n '2p')
    local total=$((additions + deletions))

    # Check if any file is in hot paths
    local hot_path=false
    echo "$affected_files" | grep -qE "(agent-loop|run\.ts|gateway\.ts|server-http)" && hot_path=true

    if [ $total -gt 500 ] || [ "$hot_path" = true ]; then
      risk="high"
    elif [ $total -gt 100 ]; then
      risk="medium"
    else
      risk="low"
    fi
  fi
  info "Risk: $risk (${additions}+ ${deletions}-)"

  # 6. Download diff
  info "Downloading diff..."
  local diff_dir="$PATCHKIT_ROOT/manual-patches"
  local diff_file="$diff_dir/${pr_number}-$(echo "$pr_title" | tr ' ' '-' | tr -cd '[:alnum:]-' | head -c 50).diff"

  gh pr diff "$pr_number" --repo openclaw/openclaw > "$diff_file" 2>/dev/null

  if [ -s "$diff_file" ]; then
    ok "Diff saved: $(basename "$diff_file")"
  else
    warn "Could not download diff"
    rm -f "$diff_file"
  fi

  # 7. Add to patches.yaml
  local oc_version
  oc_version=$(get_openclaw_version)
  local today
  today=$(date +%Y-%m-%d)

  local _tmp_add_in="/tmp/patchkit-add-$$-in.json"
  local _tmp_add_out="/tmp/patchkit-add-$$-out.json"
  yq -o=json '.' "$PATCHES_YAML" > "$_tmp_add_in"
  python3 - "$_tmp_add_in" "$pr_number" "$pr_title" "$category" "$risk" "$oc_version" "$today" "$pr_author" "$_tmp_add_out" << 'PYEOF'
import json, sys

json_path = sys.argv[1]
pr = int(sys.argv[2])
title = sys.argv[3]
category = sys.argv[4]
risk = sys.argv[5]
version = f"v{sys.argv[6]}"
today = sys.argv[7]
author = sys.argv[8]
out_path = sys.argv[9]

with open(json_path) as f:
    data = json.load(f)

new_patch = {
    "pr": pr,
    "title": title,
    "category": category,
    "risk": risk,
    "status": "active",
    "tested_versions": [version],
    "added_date": today,
    "last_test_date": today,
    "author": author,
}

data["patches"].append(new_patch)
data["last_updated"] = today

with open(out_path, "w") as f:
    json.dump(data, f, indent=2, ensure_ascii=False)
    f.write("\n")

print(f"  \033[0;32mOK\033[0m  Added to patches.yaml")
PYEOF
  yq -P '.' "$_tmp_add_out" > "$PATCHES_YAML"
  rm -f "$_tmp_add_in" "$_tmp_add_out"

  # 8. Update pr-patches.conf (backward compat)
  local conf_line="$pr_number | $pr_title  [risk:$risk] [verified:v$oc_version]"

  # Find the right category section and append
  local section_header
  case "$category" in
    security) section_header="SECURITY" ;;
    gateway)  section_header="GATEWAY" ;;
    session)  section_header="SESSION" ;;
    channel)  section_header="CHANNEL" ;;
    memory)   section_header="MEMORY" ;;
    config)   section_header="CONFIG" ;;
    *)        section_header="BUG/STABILITY" ;;
  esac

  # Append to conf (at end of respective section)
  echo "$conf_line" >> "$CONF"
  ok "Added to pr-patches.conf"

  # 9. Summary
  echo ""
  echo -e "  ${BOLD}Summary${NC}"
  echo "  PR:       #$pr_number"
  echo "  Title:    $pr_title"
  echo "  Category: $category"
  echo "  Risk:     $risk"
  echo "  Author:   $pr_author"
  echo "  Files:    $file_count"

  log_event "patch_added" "{\"pr\": $pr_number, \"category\": \"$category\", \"risk\": \"$risk\"}"

  ok "PR #$pr_number added to patchkit"
}
