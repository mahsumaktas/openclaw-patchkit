#!/usr/bin/env bash
# OpenClaw post-update patch check
# Checks if the patched dist is still in place. If openclaw was updated
# (new dist files detected), triggers the unified patch system.
#
# Run via launchd: ai.openclaw.patch-check

PATCHES_DIR="$(cd "$(dirname "$0")" && pwd)"
OPENCLAW_ROOT="$(npm root -g)/openclaw"
VERSION=$(node -e "console.log(require('$OPENCLAW_ROOT/package.json').version)" 2>/dev/null)
MARKER="$PATCHES_DIR/.last-patched-version"

if [ -f "$MARKER" ] && [ "$(cat "$MARKER")" = "$VERSION" ]; then
  echo "OpenClaw $VERSION — patches intact."
  exit 0
fi

echo "OpenClaw version changed or first run — running unified patch system..."
bash "$PATCHES_DIR/patch-openclaw.sh" --skip-restart
PATCH_EXIT=$?

# Write version marker even on partial failure (same version = same result).
# User can override with: patch-openclaw.sh --force
echo "$VERSION" > "$MARKER"

if [ $PATCH_EXIT -eq 0 ]; then
  echo "All patches applied for $VERSION"
else
  echo "Patches partially applied for $VERSION (check: patch-openclaw.sh --status)" >&2
fi

exit $PATCH_EXIT
