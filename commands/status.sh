#!/usr/bin/env bash
# commands/status.sh — Patch dashboard
# Loaded by: bin/patchkit

cmd_status() {
  local json_mode=false
  [ "${1:-}" = "--json" ] && json_mode=true

  step "OpenClaw Patchkit Status"

  local oc_version
  oc_version=$(get_openclaw_version)
  echo -e "  OpenClaw version: ${BOLD}v${oc_version}${NC}"
  echo -e "  Patchkit root:    ${DIM}$PATCHKIT_ROOT${NC}"
  echo ""

  # Count patches by status and category
  local _status_yaml="${PATCHES_YAML:-$PATCHKIT_ROOT/metadata/patches.yaml}"
  local _tmp_status="/tmp/patchkit-status-$$.json"
  if ! yq -o=json '.' "$_status_yaml" > "$_tmp_status" 2>/dev/null; then
    echo -e "  \033[0;31mFAIL\033[0m Cannot read patches.yaml"
    rm -f "$_tmp_status"
    return 1
  fi
  STATUS_JSON="$_tmp_status" python3 << 'PYEOF'
import json, os, sys

json_path = os.environ.get("STATUS_JSON", "")

try:
    with open(json_path) as f:
        data = json.load(f)
except Exception as e:
    print(f"  \033[0;31mFAIL\033[0m Cannot read patches.yaml: {e}")
    sys.exit(1)

patches = data.get("patches", [])
fixes = data.get("fixes", [])
retired = data.get("retired", [])
disabled = data.get("disabled", [])

# Active patches by category
categories = {}
risk_counts = {"low": 0, "medium": 0, "high": 0, "critical": 0}
for p in patches:
    if p.get("status") == "active":
        cat = p.get("category", "unknown")
        categories[cat] = categories.get(cat, 0) + 1
        risk = p.get("risk", "unknown")
        if risk in risk_counts:
            risk_counts[risk] += 1

active_count = sum(categories.values())
active_fixes = sum(1 for f in fixes if f.get("status") == "active")

# Category order
cat_order = ["security", "gateway", "session", "channel", "memory", "config", "stability", "platform"]
cat_colors = {
    "security": "\033[0;31m",    # red
    "gateway": "\033[0;33m",     # orange/yellow
    "session": "\033[1;33m",     # bright yellow
    "channel": "\033[0;34m",     # blue
    "memory": "\033[0;35m",      # purple
    "config": "\033[0;36m",      # cyan
    "stability": "\033[0;32m",   # green
    "platform": "\033[2m",       # dim
}
NC = "\033[0m"
BOLD = "\033[1m"

print(f"  {BOLD}Active Patches: {active_count} + {active_fixes} FIX{NC}")
print(f"  Retired: {len(retired)} | Disabled: {len(disabled)}")
print()

# Category breakdown
print(f"  {'Category':<12} {'Count':>5}  {'Bar'}")
print(f"  {'─'*12} {'─'*5}  {'─'*30}")
for cat in cat_order:
    count = categories.get(cat, 0)
    if count == 0:
        continue
    color = cat_colors.get(cat, "")
    bar = "█" * count
    print(f"  {color}{cat:<12}{NC} {count:>5}  {color}{bar}{NC}")

print()

# Risk distribution
print(f"  Risk: {risk_counts['low']} low, {risk_counts['medium']} medium, {risk_counts['high']} high, {risk_counts['critical']} critical")

# Base version info
base = data.get("base_version", "unknown")
updated = data.get("last_updated", "unknown")
print(f"  Base: {base} | Last updated: {updated}")
PYEOF
  rm -f "$_tmp_status"

  echo ""

  # Built-in extension status
  source "$PATCHKIT_ROOT/lib/builtin-disable.sh"
  verify_builtin_disabled 2>/dev/null || true

  # Gateway status
  echo ""
  if is_gateway_running; then
    ok "Gateway: running"
  else
    warn "Gateway: not running"
  fi
}
