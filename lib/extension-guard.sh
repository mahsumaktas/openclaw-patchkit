#!/usr/bin/env bash
# lib/extension-guard.sh — Extension compatibility guard
# Source: lib/common.sh must be loaded first
#
# Reads extensions.yaml and verifies all custom extensions are compatible
# with the target version before and after upgrade.
#
# Usage:
#   source lib/common.sh
#   source lib/extension-guard.sh
#   check_extension_compatibility
#   verify_extensions_loaded

# ── Pre-Upgrade Compatibility Check ──────────────────────────────────────

check_extension_compatibility() {
  step "Extension Compatibility Check"

  local all_ok=true

  local _tmp_yaml="/tmp/patchkit-extguard-$$-compat.json"
  yq -o=json '.' "$EXTENSIONS_YAML" > "$_tmp_yaml"
  EXT_BASE="$OPENCLAW_EXTENSIONS" EXT_JSON="$_tmp_yaml" python3 << 'PYEOF'
import json, os, sys

ext_json = os.environ["EXT_JSON"]
ext_base = os.environ["EXT_BASE"]

with open(ext_json) as f:
    data = json.load(f)

extensions = data.get("extensions", [])
issues = []
ok_count = 0

for ext in extensions:
    name = ext["name"]
    status = ext.get("status", "active")

    if status == "disabled":
        print(f"  [SKIP] {name}: disabled")
        continue

    path = os.path.expanduser(ext.get("path", ""))

    # Check extension exists
    if not os.path.isdir(path):
        print(f"  [WARN] {name}: directory not found at {path}")
        issues.append(name)
        continue

    # Check entry point
    entry = ext.get("entry_point", "index.ts")
    entry_path = os.path.join(path, entry)
    if not os.path.exists(entry_path):
        # Try .js variant
        js_entry = entry.replace(".ts", ".js")
        if not os.path.exists(os.path.join(path, js_entry)):
            print(f"  [WARN] {name}: entry point not found ({entry})")
            issues.append(name)
            continue

    # Check config files
    for cfg in ext.get("config_files", []):
        cfg_path = os.path.join(path, cfg)
        if not os.path.exists(cfg_path):
            print(f"  [WARN] {name}: config file missing ({cfg})")

    # Check native deps
    node_modules = os.path.join(path, "node_modules")
    for dep in ext.get("native_deps", []):
        dep_path = os.path.join(node_modules, dep.replace("/", os.sep))
        if not os.path.isdir(dep_path):
            print(f"  [WARN] {name}: native dep missing ({dep})")
            issues.append(name)
            continue

    # Report risk
    risk = ext.get("breaking_risk", "unknown")
    notes = ext.get("notes", "")
    print(f"  [OK]   {name} (risk: {risk})")
    ok_count += 1

    # Show upgrade actions
    for action in ext.get("upgrade_actions", []):
        print(f"         -> {action}")

if issues:
    print(f"\n  {len(issues)} extension(s) have issues: {', '.join(set(issues))}")
    sys.exit(1)
else:
    print(f"\n  {ok_count} extension(s) OK")
    sys.exit(0)
PYEOF
  local _pyexit=$?
  rm -f "$_tmp_yaml"

  if [ $_pyexit -ne 0 ]; then
    all_ok=false
  fi

  $all_ok
}

# ── Post-Upgrade Extension Verification ──────────────────────────────────

verify_extensions_loaded() {
  step "Extension Load Verification"

  local log_file="$OPENCLAW_LOGS/gateway.log"
  local err_file="$OPENCLAW_LOGS/gateway.err.log"

  if [ ! -f "$log_file" ] && [ ! -f "$err_file" ]; then
    warn "Gateway log files not found"
    return 1
  fi

  # Read expected extensions from YAML
  local expected_extensions
  expected_extensions=$(yq -o=json '.' "$EXTENSIONS_YAML" | python3 -c "
import json, sys
data = json.load(sys.stdin)
for ext in data.get('extensions', []):
    if ext.get('status', 'active') != 'disabled':
        print(ext['name'])
" 2>/dev/null)

  local all_loaded=true
  local check_file=""
  if [ -f "$log_file" ]; then
    check_file="$log_file"
  elif [ -f "$err_file" ]; then
    check_file="$err_file"
  fi

  if [ -z "$check_file" ]; then
    warn "No gateway log files found"
    return 1
  fi

  # Check last 200 lines for extension loading messages
  local recent_log
  recent_log=$(tail -200 "$check_file" 2>/dev/null || true)

  while IFS= read -r ext_name; do
    [ -z "$ext_name" ] && continue

    if echo "$recent_log" | grep -qi "$ext_name" 2>/dev/null; then
      ok "$ext_name: found in gateway log"
    else
      warn "$ext_name: NOT found in recent gateway log"
      all_loaded=false
    fi
  done <<< "$expected_extensions"

  if $all_loaded; then
    ok "All extensions loaded"
  else
    warn "Some extensions may not have loaded — check gateway logs"
  fi

  $all_loaded
}

# ── Extension Deps Reinstall ──────────────────────────────────────────────
# After npm install -g upgrades OpenClaw, extension native deps may break.

reinstall_extension_deps() {
  step "Extension Dependencies"

  local _tmp_yaml="/tmp/patchkit-extguard-$$-deps.json"
  yq -o=json '.' "$EXTENSIONS_YAML" > "$_tmp_yaml"
  EXT_JSON="$_tmp_yaml" python3 << 'PYEOF'
import json, os, subprocess, sys

with open(os.environ["EXT_JSON"]) as f:
    data = json.load(f)

for ext in data.get("extensions", []):
    if ext.get("status", "active") == "disabled":
        continue

    name = ext["name"]
    native_deps = ext.get("native_deps", [])
    if not native_deps:
        continue

    path = os.path.expanduser(ext.get("path", ""))
    if not os.path.isdir(path):
        print(f"  [SKIP] {name}: not found")
        continue

    # Quick check: try importing first dep
    dep = native_deps[0]
    node_check = f"require('{dep}')"
    result = subprocess.run(
        ["node", "-e", node_check],
        cwd=path,
        capture_output=True,
        timeout=10
    )

    if result.returncode == 0:
        print(f"  [OK]   {name}: deps already importable")
    else:
        print(f"  [..]   {name}: reinstalling deps...")
        npm_result = subprocess.run(
            ["npm", "install", "--no-save", "--no-audit", "--no-fund"],
            cwd=path,
            capture_output=True,
            timeout=120
        )
        if npm_result.returncode == 0:
            print(f"  [OK]   {name}: deps reinstalled")
        else:
            print(f"  [WARN] {name}: npm install failed (non-fatal)")
            print(f"         {npm_result.stderr.decode()[:200]}")
PYEOF
  rm -f "$_tmp_yaml"
}
