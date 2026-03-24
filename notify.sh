#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# OpenClaw Patchkit — Notification helper (Discord + Telegram)
#
# Usage (standalone):  bash notify.sh "Title" "Message" [color]
# Usage (sourced):     source notify.sh && notify "Title" "Message" [color]
#
# Channel selection (env or .env):
#   NOTIFY_CHANNEL=telegram   → sends to Telegram (default)
#   NOTIFY_CHANNEL=discord    → sends to Discord webhook
#   NOTIFY_CHANNEL=both       → sends to both
#
# Colors: green (default), red, yellow, blue
# ─────────────────────────────────────────────────────────────────────────────

_NOTIFY_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"

# Load env
if [ -f "$_NOTIFY_DIR/.env" ]; then
    set -a && source "$_NOTIFY_DIR/.env" 2>/dev/null && set +a
fi

# Defaults
: "${NOTIFY_CHANNEL:=telegram}"
: "${TELEGRAM_BOT_TOKEN:=$(cat ~/.config/hachix/secrets.d/telegram-primary.token 2>/dev/null)}"
: "${TELEGRAM_CHAT_ID:=6702362132}"
: "${DISCORD_WEBHOOK_URL:=$(cat ~/.openclaw/webhook-url.txt 2>/dev/null | tr -d '[:space:]')}"

_json_escape() {
    local s="$1"
    s="${s//\\/\\\\}"
    s="${s//\"/\\\"}"
    s="${s//$'\n'/\\n}"
    s="${s//$'\r'/}"
    s="${s//$'\t'/\\t}"
    echo -n "$s"
}

_emoji_for_color() {
    case "$1" in
        green)  echo "✅" ;;
        red)    echo "🔴" ;;
        yellow) echo "⚠️" ;;
        blue)   echo "ℹ️" ;;
        *)      echo "📌" ;;
    esac
}

_send_telegram() {
    local title="$1" message="$2" color="$3"

    if [ -z "$TELEGRAM_BOT_TOKEN" ]; then
        return 0
    fi

    local emoji
    emoji=$(_emoji_for_color "$color")
    local hostname
    hostname=$(hostname -s 2>/dev/null || echo "unknown")

    local text="${emoji} <b>${title}</b>"
    [ -n "$message" ] && text="${text}\n\n${message}"
    text="${text}\n\n<i>OpenClaw Patchkit — ${hostname}</i>"

    # Convert \n to actual newlines for Telegram
    local body
    body=$(printf '%s' "$text" | sed 's/\\n/\n/g')

    local safe_body
    safe_body=$(_json_escape "$body")

    curl -s -o /dev/null \
        -X POST "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
        -H "Content-Type: application/json" \
        -d "{\"chat_id\":\"${TELEGRAM_CHAT_ID}\",\"text\":\"${safe_body}\",\"parse_mode\":\"HTML\",\"disable_web_page_preview\":true}" \
        2>/dev/null || true
}

_send_discord() {
    local title="$1" message="$2" color_name="$3"

    if [ -z "$DISCORD_WEBHOOK_URL" ]; then
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

    curl -s -o /dev/null -w "" \
        -H "Content-Type: application/json" \
        -d "$payload" \
        "$DISCORD_WEBHOOK_URL" 2>/dev/null || true
}

notify() {
    local title="$1"
    local message="${2:-}"
    local color_name="${3:-green}"

    case "${NOTIFY_CHANNEL:-telegram}" in
        telegram)
            _send_telegram "$title" "$message" "$color_name"
            ;;
        discord)
            _send_discord "$title" "$message" "$color_name"
            ;;
        both)
            _send_telegram "$title" "$message" "$color_name"
            _send_discord "$title" "$message" "$color_name"
            ;;
        *)
            _send_telegram "$title" "$message" "$color_name"
            ;;
    esac
}

# Allow standalone invocation
if [ "${BASH_SOURCE[0]:-$0}" = "$0" ] && [ $# -ge 1 ]; then
    notify "$@"
fi
