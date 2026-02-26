#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# OpenClaw post-update patch check
# Checks if the patched dist is still in place. If openclaw was updated
# (new dist files detected), triggers the unified patch system with sudo,
# restarts the gateway, and launches health monitoring.
#
# Run via launchd: ai.openclaw.patch-check (triggered by WatchPaths + daily)
# ─────────────────────────────────────────────────────────────────────────────

# launchd runs with minimal PATH — ensure node/npm/gh are available
export PATH="/opt/homebrew/bin:/opt/homebrew/sbin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:$HOME/.local/bin:$PATH"

PATCHES_DIR="$(cd "$(dirname "$0")" && pwd)"
OPENCLAW_ROOT="$(npm root -g)/openclaw"
VERSION=$(node -e "console.log(require('$OPENCLAW_ROOT/package.json').version)" 2>/dev/null)
MARKER="$PATCHES_DIR/.last-patched-version"

# Load Discord notifications (non-fatal if missing)
# shellcheck disable=SC1091
source "$PATCHES_DIR/notify.sh" 2>/dev/null || true

if [ -f "$MARKER" ] && [ "$(cat "$MARKER")" = "$VERSION" ]; then
    echo "OpenClaw $VERSION — patches intact."
    exit 0
fi

echo "OpenClaw version changed ($VERSION) or first run — running unified patch system..."
notify "Patch Triggered" "OpenClaw updated to **$VERSION** — applying patches..." "blue"

# Run with sudo (passwordless via /etc/sudoers.d/openclaw-patchkit)
sudo "$PATCHES_DIR/patch-openclaw.sh" --skip-restart
PATCH_EXIT=$?

# Write version marker as current user (not root)
echo "$VERSION" > "$MARKER"

if [ $PATCH_EXIT -eq 0 ]; then
    echo "All patches applied for $VERSION"

    # Restart gateway (user domain — not root)
    UID_NUM=$(id -u)
    GATEWAY_LABEL="ai.openclaw.gateway"
    if launchctl print "gui/$UID_NUM/$GATEWAY_LABEL" &>/dev/null; then
        echo "Restarting gateway..."
        launchctl kill SIGTERM "gui/$UID_NUM/$GATEWAY_LABEL"
        sleep 2
        echo "Gateway restart signal sent."
    else
        echo "Gateway service not running — skip restart."
    fi

    notify "Patch Success" "OpenClaw **$VERSION** — all patches applied, gateway restarted." "green"

    # Launch health monitor in background
    if [ -x "$PATCHES_DIR/health-monitor.sh" ]; then
        nohup bash "$PATCHES_DIR/health-monitor.sh" >> "$PATCHES_DIR/../logs/health-monitor.log" 2>&1 &
        echo "Health monitor started (PID $!)."
    fi
else
    echo "Patches partially applied for $VERSION (check: patch-openclaw.sh --status)" >&2
    notify "Patch Partial Failure" "OpenClaw **$VERSION** — some patches failed.\nRun \`patch-openclaw.sh --status\` for details." "yellow"
fi

exit $PATCH_EXIT
