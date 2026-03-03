#!/usr/bin/env bash
# commands/remove.sh — Retire a patch from patchkit
# Loaded by: bin/patchkit

cmd_remove() {
  local pr_number="$1"
  local reason="${2:-manual}"

  if [ -z "$pr_number" ] || ! [[ "$pr_number" =~ ^[0-9]+$ ]]; then
    fail "Usage: patchkit remove <PR_NUMBER> [reason]"
    exit 1
  fi

  step "Removing PR #$pr_number from patchkit"

  # 1. Check if exists and is active
  local patch_info
  patch_info=$(yq -o=json '.' "$PATCHES_YAML" | python3 -c "
import json, sys
data = json.load(sys.stdin)
for p in data.get('patches', []):
    if p.get('pr') == $pr_number and p.get('status') == 'active':
        print(json.dumps(p))
        exit()
print('')
" 2>/dev/null)

  if [ -z "$patch_info" ]; then
    fail "PR #$pr_number not found or not active in patchkit"
    exit 1
  fi

  local title category _rm_fields
  _rm_fields=$(echo "$patch_info" | python3 -c "import json,sys; d=json.loads(sys.stdin.read()); print(d['title']); print(d['category'])")
  title=$(echo "$_rm_fields" | sed -n '1p')
  category=$(echo "$_rm_fields" | sed -n '2p')

  info "Found: $title ($category)"

  # 2. Move to retired in patches.yaml
  local today
  today=$(date +%Y-%m-%d)

  local _tmp_rm_in="/tmp/patchkit-rm-$$-in.json"
  local _tmp_rm_out="/tmp/patchkit-rm-$$-out.json"
  yq -o=json '.' "$PATCHES_YAML" > "$_tmp_rm_in"
  python3 - "$_tmp_rm_in" "$pr_number" "$reason" "$today" "$_tmp_rm_out" << 'PYEOF'
import json, sys

json_path = sys.argv[1]
pr = int(sys.argv[2])
reason = sys.argv[3]
today = sys.argv[4]
out_path = sys.argv[5]

with open(json_path) as f:
    data = json.load(f)

# Find and remove from patches
new_patches = []
for p in data.get("patches", []):
    if p.get("pr") == pr:
        p["status"] = "retired"
        # Add to retired list
        if "retired" not in data:
            data["retired"] = []
        data["retired"].append({
            "pr": pr,
            "retired_date": today,
            "reason": reason,
        })
    else:
        new_patches.append(p)

data["patches"] = new_patches
data["last_updated"] = today

with open(out_path, "w") as f:
    json.dump(data, f, indent=2, ensure_ascii=False)
    f.write("\n")

print(f"  \033[0;32mOK\033[0m  Moved to retired in patches.yaml")
PYEOF
  yq -P '.' "$_tmp_rm_out" > "$PATCHES_YAML"
  rm -f "$_tmp_rm_in" "$_tmp_rm_out"

  # 3. Comment out in pr-patches.conf
  if grep -q "^${pr_number}[| ]" "$CONF" 2>/dev/null; then
    python3 -c "
import re, sys
conf, pr, today = sys.argv[1], sys.argv[2], sys.argv[3]
with open(conf) as f:
    lines = f.readlines()
with open(conf, 'w') as f:
    for line in lines:
        if re.match(rf'^{re.escape(pr)}[\s|]', line):
            f.write(f'# RETIRED({today}): {line}')
        else:
            f.write(line)
" "$CONF" "$pr_number" "$today"
    ok "Commented out in pr-patches.conf"
  fi

  # 4. Archive manual patch script if exists
  local archived=false
  for script in "$MANUAL_PATCHES"/${pr_number}-*; do
    if [ -f "$script" ]; then
      local archive_dir="$PATCHKIT_ROOT/archive/retired"
      mkdir -p "$archive_dir"
      mv "$script" "$archive_dir/"
      ok "Archived: $(basename "$script")"
      archived=true
    fi
  done

  if ! $archived; then
    info "No manual patch script found to archive"
  fi

  # 5. Summary
  echo ""
  ok "PR #$pr_number retired (reason: $reason)"

  log_event "patch_retired" "{\"pr\": $pr_number, \"reason\": \"$reason\"}"
}
