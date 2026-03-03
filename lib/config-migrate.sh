#!/usr/bin/env bash
# lib/config-migrate.sh — Config migration engine
# Source: lib/common.sh must be loaded first
#
# Reads migration definitions from metadata/config-migrations/*.yaml
# and applies config changes (renames, new defaults, LaunchAgent updates).
#
# Usage:
#   source lib/common.sh
#   source lib/config-migrate.sh
#   run_config_migration "v2026.3.1" "v2026.3.2" [--dry-run]

run_config_migration() {
  local source_version="$1"
  local target_version="$2"
  local dry_run="${3:-false}"

  # Find migration YAML
  local migration_file="$PATCHKIT_ROOT/metadata/config-migrations/${source_version}-to-${target_version}.yaml"

  if [ ! -f "$migration_file" ]; then
    info "No config migration found for ${source_version} -> ${target_version}"
    return 0
  fi

  step "Config Migration: ${source_version} -> ${target_version}"

  # Parse migration YAML once into temp JSON
  local _mig_json="/tmp/patchkit-migrate-$$-data.json"
  yq -o=json '.' "$migration_file" > "$_mig_json"

  # ── openclaw.json renames ─────────────────────────────────────────────
  local renames_count
  renames_count=$(python3 -c "
import json, sys
with open(sys.argv[1]) as f: data = json.load(f)
print(len(data.get('openclaw_json', {}).get('renames', [])))
" "$_mig_json" 2>/dev/null || echo "0")

  if [ "$renames_count" -gt 0 ]; then
    info "Applying $renames_count config rename(s)..."
    python3 - "$OPENCLAW_CONFIG" "$_mig_json" "$dry_run" << 'PYEOF'
import json, sys

config_file = sys.argv[1]
migration_json = sys.argv[2]
dry_run = sys.argv[3] == "true"

with open(config_file) as f:
    config = json.load(f)
with open(migration_json) as f:
    migration = json.load(f)

renames = migration.get("openclaw_json", {}).get("renames", [])
changed = False

for rename in renames:
    old_path = rename["from"].split(".")
    new_path = rename["to"].split(".")

    # Navigate to old value
    node = config
    for key in old_path[:-1]:
        node = node.get(key, {})
    old_value = node.get(old_path[-1])

    if old_value is not None:
        # Set new path
        target = config
        for key in new_path[:-1]:
            if key not in target:
                target[key] = {}
            target = target[key]
        target[new_path[-1]] = old_value

        # Remove old path
        node = config
        for key in old_path[:-1]:
            node = node.get(key, {})
        del node[old_path[-1]]

        changed = True
        action = "DRY-RUN" if dry_run else "APPLIED"
        print(f"  [{action}] Renamed: {rename['from']} -> {rename['to']}")

if changed and not dry_run:
    with open(config_file, "w") as f:
        json.dump(config, f, indent=2, ensure_ascii=False)
        f.write("\n")

if not changed:
    print("  No renames needed")
PYEOF
  fi

  # ── openclaw.json new defaults ────────────────────────────────────────
  local defaults_count
  defaults_count=$(python3 -c "
import json, sys
with open(sys.argv[1]) as f: data = json.load(f)
print(len(data.get('openclaw_json', {}).get('new_defaults', [])))
" "$_mig_json" 2>/dev/null || echo "0")

  if [ "$defaults_count" -gt 0 ]; then
    info "Checking $defaults_count new default(s)..."
    python3 - "$OPENCLAW_CONFIG" "$_mig_json" "$dry_run" << 'PYEOF'
import json, sys

config_file = sys.argv[1]
migration_json = sys.argv[2]
dry_run = sys.argv[3] == "true"

with open(config_file) as f:
    config = json.load(f)
with open(migration_json) as f:
    migration = json.load(f)

defaults = migration.get("openclaw_json", {}).get("new_defaults", [])
changed = False

for default in defaults:
    path_parts = default["path"].split(".")
    condition = default.get("condition", "field_missing")
    value = default["value"]
    note = default.get("note", "")

    # Check if field exists
    node = config
    exists = True
    for key in path_parts:
        if isinstance(node, dict) and key in node:
            node = node[key]
        else:
            exists = False
            break

    should_apply = False
    if condition == "field_missing" and not exists:
        should_apply = True
    elif condition == "always":
        should_apply = True

    if should_apply:
        # Set the value
        target = config
        for key in path_parts[:-1]:
            if key not in target:
                target[key] = {}
            target = target[key]

        action = "DRY-RUN" if dry_run else "SET"
        print(f"  [{action}] {default['path']} = {json.dumps(value)}")
        if note:
            print(f"           Note: {note}")

        if not dry_run:
            target[path_parts[-1]] = value
            changed = True
    else:
        current = node
        print(f"  [SKIP] {default['path']} already set to {json.dumps(current)}")

if changed:
    with open(config_file, "w") as f:
        json.dump(config, f, indent=2, ensure_ascii=False)
        f.write("\n")
PYEOF
  fi

  # ── LaunchAgent plist updates ──────────────────────────────────────────
  local la_changes
  la_changes=$(python3 -c "
import json, sys
with open(sys.argv[1]) as f: data = json.load(f)
print(len(data.get('launchagent', {}).get('changes', [])))
" "$_mig_json" 2>/dev/null || echo "0")

  if [ "$la_changes" -gt 0 ]; then
    info "Applying $la_changes LaunchAgent change(s)..."
    local plist="$LAUNCH_AGENTS/ai.openclaw.gateway.plist"

    if [ ! -f "$plist" ]; then
      warn "LaunchAgent plist not found: $plist"
    else
      python3 - "$plist" "$_mig_json" "$dry_run" << 'PYEOF'
import plistlib, json, sys

plist_file = sys.argv[1]
migration_json = sys.argv[2]
dry_run = sys.argv[3] == "true"

with open(plist_file, "rb") as f:
    plist = plistlib.load(f)
with open(migration_json) as f:
    migration = json.load(f)

changes = migration.get("launchagent", {}).get("changes", [])
modified = False

for change in changes:
    field = change["field"]
    value = change["value"]
    note = change.get("note", "")

    # Handle nested fields in EnvironmentVariables
    if field.startswith("EnvironmentVariables."):
        env_key = field.split(".", 1)[1]
        env_vars = plist.get("EnvironmentVariables", {})
        current = env_vars.get(env_key)

        if current != str(value):
            action = "DRY-RUN" if dry_run else "SET"
            print(f"  [{action}] EnvironmentVariables.{env_key} = {value}")
            if note:
                print(f"           Note: {note}")
            if not dry_run:
                env_vars[env_key] = str(value)
                plist["EnvironmentVariables"] = env_vars
                modified = True
        else:
            print(f"  [SKIP] EnvironmentVariables.{env_key} already = {current}")
    else:
        # Top-level plist key
        current = plist.get(field)
        if current != value:
            action = "DRY-RUN" if dry_run else "SET"
            print(f"  [{action}] {field} = {value}")
            if note:
                print(f"           Note: {note}")
            if not dry_run:
                plist[field] = value
                modified = True
        else:
            print(f"  [SKIP] {field} already = {current}")

if modified:
    with open(plist_file, "wb") as f:
        plistlib.dump(plist, f)
    print("  Plist updated")
PYEOF
    fi
  fi

  # ── Security notes ─────────────────────────────────────────────────────
  local security_notes
  security_notes=$(python3 -c "
import json, sys
with open(sys.argv[1]) as f: data = json.load(f)
for note in data.get('security_notes', []):
    print(note)
" "$_mig_json" 2>/dev/null)

  if [ -n "$security_notes" ]; then
    echo ""
    info "Security notes:"
    while IFS= read -r note; do
      [ -z "$note" ] && continue
      echo "    $note"
    done <<< "$security_notes"
  fi

  rm -f "$_mig_json"
  ok "Config migration complete"
}

# ── Version Marker Update ────────────────────────────────────────────────

update_plist_version() {
  local target_version="$1"
  local plist="$LAUNCH_AGENTS/ai.openclaw.gateway.plist"

  if [ ! -f "$plist" ]; then
    warn "LaunchAgent plist not found"
    return 1
  fi

  python3 - "$plist" "$target_version" << 'PYEOF'
import plistlib, sys

plist_file = sys.argv[1]
version = sys.argv[2].lstrip("v")

with open(plist_file, "rb") as f:
    plist = plistlib.load(f)

env = plist.get("EnvironmentVariables", {})
old_version = env.get("OPENCLAW_SERVICE_VERSION", "unknown")
env["OPENCLAW_SERVICE_VERSION"] = version
plist["EnvironmentVariables"] = env

# Update Comment field
plist["Comment"] = f"OpenClaw Gateway (v{version})"

with open(plist_file, "wb") as f:
    plistlib.dump(plist, f)

print(f"  Plist version: {old_version} -> {version}")
PYEOF
}
