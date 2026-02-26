#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# OpenClaw Gateway Health Monitor
# Watches gateway for 5 minutes after restart. On crash → rollback auto-added
# PRs, re-patch, restart, notify Discord.
#
# Usage:
#   health-monitor.sh                              # Monitor gateway
#   health-monitor.sh --auto-added-prs "123,456"   # Track auto-added PRs for rollback
#   health-monitor.sh --dry-run                     # Print actions without executing
# ─────────────────────────────────────────────────────────────────────────────
set -uo pipefail

export PATH="/opt/homebrew/bin:/opt/homebrew/sbin:/usr/local/bin:/usr/bin:/bin:$HOME/.local/bin:$PATH"

PATCHES_DIR="$(cd "$(dirname "$0")" && pwd)"
CONF="$PATCHES_DIR/pr-patches.conf"
GATEWAY_LABEL="ai.openclaw.gateway"
UID_NUM=$(id -u)
CHECK_INTERVAL=30    # seconds between checks
CHECK_DURATION=300   # total monitoring: 5 minutes
DRY_RUN=false
AUTO_ADDED_PRS=""

# shellcheck disable=SC1091
source "$PATCHES_DIR/notify.sh" 2>/dev/null || true

# ── Parse args ────────────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
    case "$1" in
        --auto-added-prs) AUTO_ADDED_PRS="$2"; shift 2 ;;
        --dry-run) DRY_RUN=true; shift ;;
        *) shift ;;
    esac
done

# ── Helpers ───────────────────────────────────────────────────────────────────
get_gateway_pid() {
    launchctl print "gui/$UID_NUM/$GATEWAY_LABEL" 2>/dev/null | grep -m1 'pid =' | awk '{print $NF}'
}

gateway_is_running() {
    local pid
    pid=$(get_gateway_pid)
    [ -n "$pid" ] && [ "$pid" != "0" ] && kill -0 "$pid" 2>/dev/null
}

rollback_auto_added() {
    if [ -z "$AUTO_ADDED_PRS" ]; then
        echo "  No auto-added PRs to rollback."
        return 0
    fi

    echo "  Rolling back auto-added PRs: $AUTO_ADDED_PRS"
    IFS=',' read -ra PR_LIST <<< "$AUTO_ADDED_PRS"

    for pr in "${PR_LIST[@]}"; do
        pr=$(echo "$pr" | tr -d ' ')
        if $DRY_RUN; then
            echo "  [DRY-RUN] Would comment out PR #$pr in conf"
        else
            # Comment out the line — preserve it for manual review
            sed -i '' "s/^${pr} /# ROLLBACK: ${pr} /" "$CONF" 2>/dev/null || true
            echo "  Disabled PR #$pr in conf"
        fi
    done
}

rebuild_and_restart() {
    if $DRY_RUN; then
        echo "  [DRY-RUN] Would run: sudo patch-openclaw.sh --skip-restart"
        echo "  [DRY-RUN] Would restart gateway"
        return 0
    fi

    echo "  Re-patching without rolled-back PRs..."
    sudo "$PATCHES_DIR/patch-openclaw.sh" --skip-restart
    local exit_code=$?

    if [ $exit_code -ne 0 ]; then
        echo "  WARNING: Re-patch also failed (exit $exit_code)" >&2
        notify "Rollback Re-patch Failed" "Re-patch after rollback also failed (exit $exit_code).\nManual intervention needed." "red"
        return $exit_code
    fi

    echo "  Restarting gateway..."
    launchctl kill SIGTERM "gui/$UID_NUM/$GATEWAY_LABEL" 2>/dev/null || true
    sleep 3

    if gateway_is_running; then
        echo "  Gateway restarted successfully after rollback."
    else
        echo "  WARNING: Gateway did not come back after rollback restart." >&2
        notify "Gateway Down After Rollback" "Gateway failed to restart after rollback.\nManual intervention needed." "red"
    fi
}

# ── Main loop ─────────────────────────────────────────────────────────────────
echo "=== HEALTH MONITOR: $(date '+%Y-%m-%d %H:%M:%S') ==="
echo "  Monitoring gateway for ${CHECK_DURATION}s (interval: ${CHECK_INTERVAL}s)"
echo "  Auto-added PRs: ${AUTO_ADDED_PRS:-none}"
echo "  Dry run: $DRY_RUN"

# Initial check — gateway should be running
sleep 5  # grace period for restart
if ! gateway_is_running; then
    echo "  WARNING: Gateway not running at monitor start."
    # Still continue monitoring — it might come up
fi

ELAPSED=0
CRASH_DETECTED=false

while [ $ELAPSED -lt $CHECK_DURATION ]; do
    sleep "$CHECK_INTERVAL"
    ELAPSED=$((ELAPSED + CHECK_INTERVAL))

    if gateway_is_running; then
        echo "  [${ELAPSED}s] Gateway OK (PID: $(get_gateway_pid))"
    else
        echo "  [${ELAPSED}s] CRASH DETECTED — gateway is not running!"
        CRASH_DETECTED=true
        break
    fi
done

# ── Result ────────────────────────────────────────────────────────────────────
if $CRASH_DETECTED; then
    echo ""
    echo "=== ROLLBACK INITIATED ==="
    notify "Gateway Crash Detected" "Gateway crashed within ${ELAPSED}s of restart.\nRolling back: ${AUTO_ADDED_PRS:-nothing to rollback}" "red"

    rollback_auto_added
    rebuild_and_restart

    if [ -n "$AUTO_ADDED_PRS" ]; then
        notify "Rollback Complete" "Disabled PRs: $AUTO_ADDED_PRS\nGateway re-patched and restarted." "yellow"
    fi
else
    echo ""
    echo "=== HEALTH CHECK PASSED ==="
    echo "  Gateway stable for ${CHECK_DURATION}s."
fi
