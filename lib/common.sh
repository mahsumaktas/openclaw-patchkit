#!/usr/bin/env bash
# lib/common.sh — Patchkit shared library
# Source this file from any patchkit script:
#   source "$(dirname "$0")/../lib/common.sh" || source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

set -euo pipefail

# ── Path Resolution ──────────────────────────────────────────────────────

PATCHKIT_ROOT="${PATCHKIT_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
PATCHES_YAML="$PATCHKIT_ROOT/metadata/patches.yaml"
EXTENSIONS_YAML="$PATCHKIT_ROOT/metadata/extensions.yaml"
CONF="$PATCHKIT_ROOT/pr-patches.conf"
MANUAL_PATCHES="$PATCHKIT_ROOT/manual-patches"
HISTORY_DIR="$PATCHKIT_ROOT/history"
NOTIFY_SCRIPT="$PATCHKIT_ROOT/notify.sh"

# OpenClaw paths
OPENCLAW_CONFIG="$HOME/.openclaw/openclaw.json"
OPENCLAW_EXTENSIONS="$HOME/.openclaw/extensions"
OPENCLAW_LOGS="$HOME/.openclaw/logs"
LAUNCH_AGENTS="$HOME/Library/LaunchAgents"

resolve_openclaw_root() {
  local oc_bin
  oc_bin=$(which openclaw 2>/dev/null || true)
  if [ -n "$oc_bin" ]; then
    # Resolve symlink relative to its directory
    local bin_dir resolved
    bin_dir=$(cd "$(dirname "$oc_bin")" && pwd)
    resolved=$(readlink "$oc_bin" 2>/dev/null || echo "$oc_bin")
    # readlink may return relative path (../lib/...) — resolve from bin_dir
    local full_path
    full_path=$(cd "$bin_dir" && cd "$(dirname "$resolved")" 2>/dev/null && pwd)
    echo "$full_path"
  else
    echo "/opt/homebrew/lib/node_modules/openclaw"
  fi
}

OPENCLAW_ROOT="$(resolve_openclaw_root)"
OPENCLAW_DIST="$OPENCLAW_ROOT/dist"
OPENCLAW_EXTENSIONS_BUILTIN="$OPENCLAW_ROOT/extensions"

get_openclaw_version() {
  node -e "console.log(require('$OPENCLAW_ROOT/package.json').version)" 2>/dev/null || echo "unknown"
}

# ── Output Helpers ───────────────────────────────────────────────────────

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
DIM='\033[2m'
NC='\033[0m'

ok()   { echo -e "  ${GREEN}OK${NC}  $1"; }
warn() { echo -e "  ${YELLOW}!!${NC}  $1"; }
fail() { echo -e "  ${RED}FAIL${NC}  $1"; }
info() { echo -e "  ${CYAN}..${NC}  $1"; }
step() { echo -e "\n${BOLD}${CYAN}── $1 ──${NC}"; }

# ── Discord Notification ─────────────────────────────────────────────────

notify() {
  local title="$1"
  local message="${2:-}"
  local color="${3:-green}"

  if [ -f "$NOTIFY_SCRIPT" ]; then
    bash "$NOTIFY_SCRIPT" "$title" "$message" "$color" 2>/dev/null || true
  fi
}

# ── YAML Reader (python3 fallback) ──────────────────────────────────────

yaml_read() {
  local file="$1"
  local query="$2"

  if ! command -v yq &>/dev/null; then
    fail "yq is required but not installed. Install: brew install yq"
    return 1
  fi
  yq eval "$query" "$file" 2>/dev/null
}

yaml_count() {
  local file="$1"
  local query="$2"

  if command -v yq &>/dev/null; then
    yq eval "$query | length" "$file" 2>/dev/null || echo "0"
  else
    yq -o=json '.' "$file" | python3 -c "
import json, sys
data = json.load(sys.stdin)
path = '$query'.strip('.').split('.')
node = data
for p in path:
    if p == '': continue
    if isinstance(node, dict): node = node.get(p, [])
    elif isinstance(node, list):
        try: node = node[int(p)]
        except: node = []
    else: node = []
print(len(node) if isinstance(node, list) else 0)
" 2>/dev/null || echo "0"
  fi
}

# ── GitHub API Helpers ───────────────────────────────────────────────────

gh_api_retry() {
  local endpoint="$1"
  local max_retries="${2:-3}"
  local retry=0

  while [ $retry -lt $max_retries ]; do
    local result
    result=$(gh api "$endpoint" 2>/dev/null) && echo "$result" && return 0
    retry=$((retry + 1))
    [ $retry -lt $max_retries ] && sleep 1
  done
  return 1
}

# ── Gateway Management ───────────────────────────────────────────────────

is_gateway_running() {
  pgrep -x "openclaw-gateway" >/dev/null 2>&1
}

stop_gateway() {
  if is_gateway_running; then
    info "Stopping gateway..."
    launchctl kill SIGTERM ai.openclaw.gateway 2>/dev/null || true
    local wait=0
    while is_gateway_running && [ $wait -lt 15 ]; do
      sleep 1
      wait=$((wait + 1))
    done
    if is_gateway_running; then
      warn "Gateway did not stop gracefully after 15s"
      return 1
    fi
    ok "Gateway stopped"
  else
    info "Gateway not running"
  fi
}

start_gateway() {
  info "Starting gateway..."
  launchctl kickstart -k system/ai.openclaw.gateway 2>/dev/null || \
    launchctl kickstart system/ai.openclaw.gateway 2>/dev/null || \
    launchctl start ai.openclaw.gateway 2>/dev/null || true

  sleep 3
  if is_gateway_running; then
    ok "Gateway started"
  else
    fail "Gateway failed to start"
    return 1
  fi
}

# ── Preflight Checks ────────────────────────────────────────────────────

check_disk_space() {
  local required_gb="${1:-2}"
  local available_gb
  available_gb=$(df -g "$HOME" | awk 'NR==2{print $4}')
  if [ "$available_gb" -lt "$required_gb" ]; then
    fail "Insufficient disk space: ${available_gb}GB available, ${required_gb}GB required"
    return 1
  fi
  ok "Disk space: ${available_gb}GB available"
}

check_sudo_access() {
  if sudo -n true 2>/dev/null; then
    ok "Sudo access available"
  else
    warn "Sudo access needed for built-in extension disable. You may be prompted."
  fi
}

check_gh_auth() {
  if gh auth status >/dev/null 2>&1; then
    ok "GitHub CLI authenticated"
  else
    fail "GitHub CLI not authenticated. Run: gh auth login"
    return 1
  fi
}

# ── Snapshot & Rollback ──────────────────────────────────────────────────

create_snapshot() {
  local snapshot_id
  snapshot_id="$(date +%Y%m%d-%H%M%S)"
  local snapshot_dir="$HISTORY_DIR/snapshots/$snapshot_id"
  mkdir -p "$snapshot_dir"

  # Config
  cp "$OPENCLAW_CONFIG" "$snapshot_dir/openclaw.json" 2>/dev/null || true

  # Extension configs
  for ext_dir in "$OPENCLAW_EXTENSIONS"/*/; do
    [ -d "$ext_dir" ] || continue
    local ext_name
    ext_name=$(basename "$ext_dir")
    [ -f "$ext_dir/extension-config.json" ] && \
      cp "$ext_dir/extension-config.json" "$snapshot_dir/${ext_name}-extension-config.json"
  done

  # LaunchAgent plists
  cp "$LAUNCH_AGENTS"/ai.openclaw.*.plist "$snapshot_dir/" 2>/dev/null || true

  # Version info
  echo "{\"version\": \"$(get_openclaw_version)\", \"timestamp\": \"$(date -u +%Y-%m-%dT%H:%M:%SZ)\", \"patches\": $(yaml_count "$PATCHES_YAML" ".patches")}" > "$snapshot_dir/info.json"

  ok "Snapshot created: $snapshot_id" >&2
  echo "$snapshot_id"
}

restore_snapshot() {
  local snapshot_id="$1"
  local snapshot_dir="$HISTORY_DIR/snapshots/$snapshot_id"

  if [ ! -d "$snapshot_dir" ]; then
    fail "Snapshot not found: $snapshot_id"
    return 1
  fi

  step "Restoring snapshot: $snapshot_id"
  cp "$snapshot_dir/openclaw.json" "$OPENCLAW_CONFIG" 2>/dev/null || true

  for cfg in "$snapshot_dir"/*-extension-config.json; do
    [ -f "$cfg" ] || continue
    local ext_name
    ext_name=$(basename "$cfg" | sed 's/-extension-config.json//')
    cp "$cfg" "$OPENCLAW_EXTENSIONS/$ext_name/extension-config.json" 2>/dev/null || true
  done

  for plist in "$snapshot_dir"/ai.openclaw.*.plist; do
    [ -f "$plist" ] || continue
    cp "$plist" "$LAUNCH_AGENTS/" 2>/dev/null || true
  done

  ok "Snapshot restored: $snapshot_id"
}

# ── Logging ──────────────────────────────────────────────────────────────

log_event() {
  local event_type="$1"
  local details="$2"
  local log_file="$HISTORY_DIR/events.jsonl"

  mkdir -p "$HISTORY_DIR"
  python3 -c "
import json, sys, datetime
ts = datetime.datetime.utcnow().strftime('%Y-%m-%dT%H:%M:%SZ')
evt = sys.argv[1]
raw = sys.argv[2]
try:
    det = json.loads(raw)
except:
    det = raw
print(json.dumps({'timestamp': ts, 'event': evt, 'details': det}, ensure_ascii=False))
" "$event_type" "$details" >> "$log_file"
}
