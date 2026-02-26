#!/usr/bin/env bash
set -euo pipefail

# ─────────────────────────────────────────────────────────────────────────────
# Install sudoers entry for OpenClaw Patchkit
# Run manually: sudo bash install-sudoers.sh
# ─────────────────────────────────────────────────────────────────────────────

SUDOERS_FILE="/etc/sudoers.d/openclaw-patchkit"
TMP_FILE="/tmp/openclaw-patchkit-sudoers"

cat > "$TMP_FILE" <<'EOF'
# OpenClaw Patchkit — passwordless sudo for patch scripts
# Installed by: install-sudoers.sh
Defaults!/Users/mahsum/.openclaw/my-patches/patch-openclaw.sh env_keep += "PATH HOME"
Defaults!/Users/mahsum/.openclaw/my-patches/dist-patches.sh env_keep += "PATH HOME"
Defaults!/Users/mahsum/.openclaw/my-patches/rebuild-with-patches.sh env_keep += "PATH HOME"
mahsum ALL=(root) NOPASSWD: /Users/mahsum/.openclaw/my-patches/patch-openclaw.sh
mahsum ALL=(root) NOPASSWD: /Users/mahsum/.openclaw/my-patches/patch-openclaw.sh *
mahsum ALL=(root) NOPASSWD: /Users/mahsum/.openclaw/my-patches/dist-patches.sh
mahsum ALL=(root) NOPASSWD: /Users/mahsum/.openclaw/my-patches/rebuild-with-patches.sh
mahsum ALL=(root) NOPASSWD: /Users/mahsum/.openclaw/my-patches/rebuild-with-patches.sh *
EOF

chmod 0440 "$TMP_FILE"

# Validate before installing
if visudo -c -f "$TMP_FILE"; then
    cp "$TMP_FILE" "$SUDOERS_FILE"
    chmod 0440 "$SUDOERS_FILE"
    echo "Sudoers installed: $SUDOERS_FILE"
    echo "Test: sudo -n /Users/mahsum/.openclaw/my-patches/patch-openclaw.sh --dry-run"
else
    echo "ERROR: sudoers syntax invalid — not installed" >&2
    rm -f "$TMP_FILE"
    exit 1
fi

rm -f "$TMP_FILE"
