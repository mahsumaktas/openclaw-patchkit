#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# OpenClaw v2026.3.2 Post-Upgrade Cleanup Script
# Generated: 2026-03-03
#
# Cleanup targets identified after v2026.3.1 -> v2026.3.2 upgrade:
#   1. Temp sandbox directories (~1.5GB)
#   2. Old dist backup (45MB)
#   3. Stale nightly scan dirs
#   4. Stale LaunchAgent services (3 chrome-cdp ghosts)
#   5. patch-check service fix (exit code 1 — missing script reference)
#   6. Gateway log rotation (yesterday's log, 14MB)
#   7. Misc temp files (~4MB)
#
# Safety: checks existence, shows sizes, prompts before each action.
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

TOTAL_FREED=0
DRY_RUN=false
YES_ALL=false

usage() {
    echo "Usage: $0 [--dry-run] [--yes]"
    echo "  --dry-run   Show what would be cleaned without deleting"
    echo "  --yes       Skip confirmation prompts (auto-yes)"
    exit 0
}

for arg in "$@"; do
    case "$arg" in
        --dry-run) DRY_RUN=true ;;
        --yes|-y) YES_ALL=true ;;
        --help|-h) usage ;;
    esac
done

log()  { echo -e "${CYAN}[CLEANUP]${NC} $*"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
ok()   { echo -e "${GREEN}[OK]${NC} $*"; }
err()  { echo -e "${RED}[ERROR]${NC} $*"; }
skip() { echo -e "${YELLOW}[SKIP]${NC} $*"; }

confirm() {
    if $YES_ALL; then return 0; fi
    if $DRY_RUN; then echo "  (dry-run: would prompt for confirmation)"; return 1; fi
    read -rp "  Proceed? [y/N] " answer
    [[ "$answer" =~ ^[Yy]$ ]]
}

get_size() {
    if [ -e "$1" ]; then
        du -sh "$1" 2>/dev/null | cut -f1
    else
        echo "0"
    fi
}

get_size_bytes() {
    if [ -e "$1" ]; then
        du -sk "$1" 2>/dev/null | cut -f1
    else
        echo "0"
    fi
}

safe_rm() {
    local target="$1"
    local use_sudo="${2:-false}"

    if [ ! -e "$target" ]; then
        skip "$target does not exist"
        return 0
    fi

    local size
    size=$(get_size "$target")
    local size_kb
    size_kb=$(get_size_bytes "$target")

    log "Target: $target ($size)"

    if $DRY_RUN; then
        echo "  (dry-run: would delete $target)"
        TOTAL_FREED=$((TOTAL_FREED + size_kb))
        return 0
    fi

    if confirm; then
        if [ "$use_sudo" = "true" ]; then
            sudo rm -rf "$target"
        else
            rm -rf "$target"
        fi
        TOTAL_FREED=$((TOTAL_FREED + size_kb))
        ok "Deleted $target ($size freed)"
    else
        skip "Skipped $target"
    fi
}

# ─────────────────────────────────────────────────────────────────────────────
echo ""
echo -e "${BOLD}${CYAN}═══════════════════════════════════════════════════════${NC}"
echo -e "${BOLD}  OpenClaw v2026.3.2 Post-Upgrade Cleanup${NC}"
echo -e "${BOLD}${CYAN}═══════════════════════════════════════════════════════${NC}"
echo ""
if $DRY_RUN; then
    warn "DRY RUN mode — nothing will be deleted"
    echo ""
fi

# ─────────────────────────────────────────────────────────────────────────────
# 1. Temp sandbox directories
# ─────────────────────────────────────────────────────────────────────────────
echo -e "${BOLD}1. Temp Sandbox Directories${NC}"
echo "   Upgrade sandboxes contain full node_modules copies."
echo ""

safe_rm "/tmp/openclaw-upgrade-1772563983" false
safe_rm "/tmp/openclaw-upgrade-1772563409" false
safe_rm "/tmp/oc-pr-diffs" false

echo ""

# ─────────────────────────────────────────────────────────────────────────────
# 2. Stale nightly scan temp directories
# ─────────────────────────────────────────────────────────────────────────────
echo -e "${BOLD}2. Stale Nightly Scan Temp Directories${NC}"
echo "   Old nightly-scan working directories."
echo ""

for dir in /tmp/openclaw-nightly-*; do
    [ -e "$dir" ] && safe_rm "$dir" false
done

echo ""

# ─────────────────────────────────────────────────────────────────────────────
# 3. Misc temp files
# ─────────────────────────────────────────────────────────────────────────────
echo -e "${BOLD}3. Misc Temp Files${NC}"
echo "   One-off config/json/md files from upgrade process."
echo ""

for f in \
    /tmp/openclaw-backup-check.json \
    /tmp/openclaw-orig.json \
    /tmp/openclaw-patched.json \
    /tmp/openclaw-v2026.3.2-release.md \
    /tmp/openclaw-x-post-main.last \
    /tmp/openclaw-501; do
    [ -e "$f" ] && safe_rm "$f" false
done

echo ""

# ─────────────────────────────────────────────────────────────────────────────
# 4. Old dist backup (root-owned)
# ─────────────────────────────────────────────────────────────────────────────
echo -e "${BOLD}4. Old dist.v2026.3.1.bak Backup (root-owned, 45MB)${NC}"
echo "   Previous dist backup from v2026.3.1. No longer needed after v2026.3.2 stabilization."
echo ""

DIST_BAK="/opt/homebrew/lib/node_modules/openclaw/dist.v2026.3.1.bak"
if [ -d "$DIST_BAK" ]; then
    local_size=$(get_size "$DIST_BAK")
    log "Target: $DIST_BAK ($local_size) — requires sudo"
    if $DRY_RUN; then
        echo "  (dry-run: would sudo rm -rf $DIST_BAK)"
        TOTAL_FREED=$((TOTAL_FREED + $(get_size_bytes "$DIST_BAK")))
    elif confirm; then
        sudo rm -rf "$DIST_BAK"
        TOTAL_FREED=$((TOTAL_FREED + $(get_size_bytes "$DIST_BAK" || echo 0)))
        ok "Deleted $DIST_BAK ($local_size freed)"
    else
        skip "Skipped $DIST_BAK"
    fi
else
    skip "$DIST_BAK does not exist"
fi

echo ""

# ─────────────────────────────────────────────────────────────────────────────
# 5. Stale LaunchAgent services (chrome-cdp ghosts)
# ─────────────────────────────────────────────────────────────────────────────
echo -e "${BOLD}5. Stale LaunchAgent Services${NC}"
echo "   3 chrome-cdp services registered but not running (no active process)."
echo "   These are leftover from Playwright/CDP debugging sessions."
echo ""

for svc in com.oracle.chrome-cdp-18805 com.oracle.chrome-cdp-18806 com.oracle.chrome-cdp-18807; do
    PLIST="$HOME/Library/LaunchAgents/${svc}.plist"
    if [ -f "$PLIST" ]; then
        log "Stale service: $svc"
        log "  Plist: $PLIST"

        if $DRY_RUN; then
            echo "  (dry-run: would bootout + remove plist)"
        elif confirm; then
            # Bootout first (ignore error if already not loaded)
            launchctl bootout "gui/$(id -u)/$svc" 2>/dev/null || true
            rm -f "$PLIST"
            ok "Removed $svc service and plist"
        else
            skip "Skipped $svc"
        fi
    else
        skip "$svc plist does not exist"
    fi
done

echo ""

# ─────────────────────────────────────────────────────────────────────────────
# 6. Fix patch-check service (exit code 1)
# ─────────────────────────────────────────────────────────────────────────────
echo -e "${BOLD}6. Fix patch-check Service (exit code 1)${NC}"
echo "   Root cause: post-update-check.sh calls 'sudo patch-openclaw.sh'"
echo "   but patch-openclaw.sh does not exist. It was replaced by rebuild-with-patches.sh."
echo "   The plist itself is valid. The script reference needs updating."
echo ""

PATCH_CHECK_SCRIPT="$HOME/.openclaw/my-patches/post-update-check.sh"
if [ -L "$PATCH_CHECK_SCRIPT" ]; then
    REAL_SCRIPT=$(readlink "$PATCH_CHECK_SCRIPT" 2>/dev/null || echo "$PATCH_CHECK_SCRIPT")
    log "post-update-check.sh -> $REAL_SCRIPT"
    if [ -f "$REAL_SCRIPT" ]; then
        # Check if it references the missing patch-openclaw.sh
        if grep -q 'patch-openclaw\.sh' "$REAL_SCRIPT" 2>/dev/null; then
            warn "Script references missing 'patch-openclaw.sh'"
            warn "Fix: Replace 'patch-openclaw.sh' with 'rebuild-with-patches.sh' in:"
            warn "  $REAL_SCRIPT"
            echo ""
            log "Showing the problematic lines:"
            grep -n 'patch-openclaw\.sh' "$REAL_SCRIPT" 2>/dev/null | sed 's/^/    /'
            echo ""
            if ! $DRY_RUN; then
                if confirm; then
                    sed -i.bak 's|patch-openclaw\.sh|rebuild-with-patches.sh|g' "$REAL_SCRIPT"
                    ok "Updated script references"
                    ok "Backup at: ${REAL_SCRIPT}.bak"

                    # Reset the service error state
                    log "Resetting patch-check service state..."
                    launchctl bootout "gui/$(id -u)/ai.openclaw.patch-check" 2>/dev/null || true
                    sleep 1
                    launchctl bootstrap "gui/$(id -u)" "$HOME/Library/LaunchAgents/ai.openclaw.patch-check.plist" 2>/dev/null || true
                    ok "patch-check service reloaded"
                else
                    skip "Skipped patch-check fix"
                fi
            else
                echo "  (dry-run: would sed replace patch-openclaw.sh -> rebuild-with-patches.sh)"
                echo "  (dry-run: would reload ai.openclaw.patch-check service)"
            fi
        else
            ok "post-update-check.sh does not reference patch-openclaw.sh (already fixed?)"
        fi
    else
        err "Symlink target does not exist: $REAL_SCRIPT"
    fi
elif [ -f "$PATCH_CHECK_SCRIPT" ]; then
    log "post-update-check.sh is a regular file (not symlink)"
    if grep -q 'patch-openclaw\.sh' "$PATCH_CHECK_SCRIPT" 2>/dev/null; then
        warn "Script references missing 'patch-openclaw.sh' — needs manual fix"
    fi
else
    skip "post-update-check.sh not found at $PATCH_CHECK_SCRIPT"
fi

echo ""

# ─────────────────────────────────────────────────────────────────────────────
# 7. Gateway log rotation
# ─────────────────────────────────────────────────────────────────────────────
echo -e "${BOLD}7. Gateway Log Rotation${NC}"
echo "   Gateway logs in temp dir. Compress yesterday's log, keep today's."
echo ""

LOG_DIR="/var/folders/rt/w3tspmtd695g7dl3lzw22j4c0000gn/T/openclaw-501"
TODAY=$(date +%Y-%m-%d)

if [ -d "$LOG_DIR" ]; then
    for logfile in "$LOG_DIR"/openclaw-*.log; do
        [ -f "$logfile" ] || continue
        logname=$(basename "$logfile")

        # Skip today's active log
        if [[ "$logname" == *"$TODAY"* ]]; then
            log "Keeping active log: $logname ($(get_size "$logfile"))"
            continue
        fi

        local_size=$(get_size "$logfile")
        log "Old log: $logname ($local_size)"

        if $DRY_RUN; then
            echo "  (dry-run: would gzip $logfile)"
        elif confirm; then
            gzip "$logfile"
            ok "Compressed $logname -> ${logname}.gz"
        else
            skip "Skipped $logname"
        fi
    done
else
    skip "Log directory not found: $LOG_DIR"
fi

echo ""

# ─────────────────────────────────────────────────────────────────────────────
# 8. Permission check (pnpm store/cache)
# ─────────────────────────────────────────────────────────────────────────────
echo -e "${BOLD}8. Permission Check — pnpm Store & Cache${NC}"
echo ""

PNPM_STORE="$HOME/Library/pnpm/store"
PNPM_CACHE="$HOME/Library/Caches/pnpm"

check_ownership() {
    local dir="$1"
    local label="$2"
    if [ -d "$dir" ]; then
        local root_count
        root_count=$(find "$dir" -user root 2>/dev/null | wc -l | tr -d ' ')
        if [ "$root_count" -gt 0 ]; then
            warn "$label: $root_count root-owned files found"
            log "Listing first 5:"
            find "$dir" -user root 2>/dev/null | head -5 | sed 's/^/    /'
            echo ""
            if ! $DRY_RUN; then
                log "Fix: sudo chown -R $(whoami) $dir"
                if confirm; then
                    sudo chown -R "$(whoami)" "$dir"
                    ok "Fixed ownership for $dir"
                else
                    skip "Skipped ownership fix for $dir"
                fi
            else
                echo "  (dry-run: would sudo chown -R $(whoami) $dir)"
            fi
        else
            ok "$label: No root-owned files ($(get_size "$dir") total, all user-owned)"
        fi
    else
        skip "$label: directory does not exist"
    fi
}

check_ownership "$PNPM_STORE" "pnpm store"
check_ownership "$PNPM_CACHE" "pnpm cache"

echo ""

# ─────────────────────────────────────────────────────────────────────────────
# Summary
# ─────────────────────────────────────────────────────────────────────────────
echo -e "${BOLD}${CYAN}═══════════════════════════════════════════════════════${NC}"
echo -e "${BOLD}  Cleanup Summary${NC}"
echo -e "${BOLD}${CYAN}═══════════════════════════════════════════════════════${NC}"
echo ""

if [ "$TOTAL_FREED" -gt 0 ]; then
    if [ "$TOTAL_FREED" -gt 1048576 ]; then
        echo -e "  Space freed: ${GREEN}$((TOTAL_FREED / 1048576)) GB${NC}"
    elif [ "$TOTAL_FREED" -gt 1024 ]; then
        echo -e "  Space freed: ${GREEN}$((TOTAL_FREED / 1024)) MB${NC}"
    else
        echo -e "  Space freed: ${GREEN}${TOTAL_FREED} KB${NC}"
    fi
else
    echo "  No space freed (nothing was deleted)"
fi

echo ""

if $DRY_RUN; then
    warn "This was a dry run. Run without --dry-run to actually clean up."
    warn "  $0"
    warn "  $0 --yes   (skip prompts)"
fi

echo ""
echo "Done."
