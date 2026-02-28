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
CRASH_COUNT=0

while [ $ELAPSED -lt $CHECK_DURATION ]; do
    sleep "$CHECK_INTERVAL"
    ELAPSED=$((ELAPSED + CHECK_INTERVAL))

    if gateway_is_running; then
        echo "  [${ELAPSED}s] Gateway OK (PID: $(get_gateway_pid))"
    else
        CRASH_COUNT=$((CRASH_COUNT + 1))
        echo "  [${ELAPSED}s] CRASH DETECTED (#$CRASH_COUNT) — gateway is not running!"

        # 3+ crashes → dist-level rollback, stop monitoring
        if [ "$CRASH_COUNT" -ge 3 ]; then
            break
        fi

        # Under 3 crashes → log and wait for launchd SuccessfulExit restart
        echo "  Waiting for launchd auto-restart..."
        sleep 5
    fi
done

# ── Result ────────────────────────────────────────────────────────────────────
if [ "$CRASH_COUNT" -ge 3 ]; then
    echo ""
    echo "=== CRITICAL: $CRASH_COUNT CRASHES — AUTO-ROLLBACK ==="
    notify "Gateway Critical Crash" "Gateway crashed $CRASH_COUNT times post-patch.\nTriggering dist-level auto-rollback." "red"

    if $DRY_RUN; then
        echo "  [DRY-RUN] Would run: sudo patch-openclaw.sh --rollback"
    else
        echo "  Triggering dist-level rollback..."
        sudo "$PATCHES_DIR/patch-openclaw.sh" --rollback
        local_exit=$?
        if [ $local_exit -ne 0 ]; then
            echo "  WARNING: Dist rollback failed (exit $local_exit)" >&2
            notify "Dist Rollback Failed" "Auto-rollback failed (exit $local_exit).\nManual intervention needed." "red"
        else
            notify "Dist Rollback Complete" "Gateway rolled back to previous dist backup after $CRASH_COUNT crashes." "yellow"
        fi
    fi

    # Also disable auto-added PRs if any
    if [ -n "$AUTO_ADDED_PRS" ]; then
        rollback_auto_added
    fi
    exit 1
elif [ "$CRASH_COUNT" -gt 0 ]; then
    # 1-2 crashes detected but monitoring period ended without hitting 3
    echo ""
    echo "=== PARTIAL INSTABILITY ==="
    echo "  $CRASH_COUNT crash(es) detected during monitoring."
    notify "Gateway Unstable" "Gateway crashed $CRASH_COUNT time(s) during monitoring.\nRolling back auto-added PRs as precaution." "yellow"

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
