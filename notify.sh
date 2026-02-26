#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# OpenClaw Patchkit — Discord webhook notification helper
#
# Usage (standalone):  bash notify.sh "Title" "Message" [color]
# Usage (sourced):     source notify.sh && notify "Title" "Message" [color]
#
# Colors: green (default), red, yellow, blue
# ─────────────────────────────────────────────────────────────────────────────

_NOTIFY_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"

# Load webhook URL
if [ -f "$_NOTIFY_DIR/.env" ]; then
    # shellcheck disable=SC1091
    set -a && source "$_NOTIFY_DIR/.env" 2>/dev/null && set +a
fi

_json_escape() {
    local s="$1"
    s="${s//\\/\\\\}"
    s="${s//\"/\\\"}"
    s="${s//$'\n'/\\n}"
    s="${s//$'\r'/}"
    s="${s//$'\t'/\\t}"
    echo -n "$s"
}

notify() {
    local title="$1"
    local message="${2:-}"
    local color_name="${3:-green}"

    # No webhook → silent skip
    if [ -z "${DISCORD_WEBHOOK_URL:-}" ]; then
        return 0
    fi

    local color
    case "$color_name" in
        green)  color=65280 ;;
        red)    color=16711680 ;;
        yellow) color=16776960 ;;
        blue)   color=3447003 ;;
        *)      color=65280 ;;
    esac

    local safe_title safe_message
    safe_title=$(_json_escape "$title")
    safe_message=$(_json_escape "$message")

    local hostname
    hostname=$(hostname -s 2>/dev/null || echo "unknown")

    local payload
    payload=$(cat <<ENDJSON
{
  "embeds": [{
    "title": "$safe_title",
    "description": "$safe_message",
    "color": $color,
    "footer": {"text": "OpenClaw Patchkit — $hostname"},
    "timestamp": "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
  }]
}
ENDJSON
)

    # Fire and forget — never block the caller
    curl -s -o /dev/null -w "" \
        -H "Content-Type: application/json" \
        -d "$payload" \
        "$DISCORD_WEBHOOK_URL" 2>/dev/null || true
}

# Allow standalone invocation: bash notify.sh "Title" "Message" [color]
if [ "${BASH_SOURCE[0]:-$0}" = "$0" ] && [ $# -ge 1 ]; then
    notify "$@"
fi
