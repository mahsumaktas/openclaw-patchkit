#!/usr/bin/env bash
# PR #28428 — Fix gateway daemon token drift after token rotation
# 26 files total — git apply excluding tests+changelog+service-env.ts
# service-env.ts token removal applied separately via python3
set -euo pipefail
cd "$1"

# Check if already applied
if grep -q 'resolveServiceTokenFromConfig\|prefer.*gateway\.auth\.token' "src/gateway/credentials.ts" 2>/dev/null; then
  echo "SKIP: #28428 already applied"
  exit 0
fi

# Download diff if not cached
DIFF="/tmp/oc-pr-diffs/28428.diff"
if [ ! -s "$DIFF" ]; then
  mkdir -p /tmp/oc-pr-diffs
  echo "  Downloading PR #28428 diff..."
  gh pr diff 28428 --repo openclaw/openclaw > "$DIFF" 2>/dev/null || {
    curl -sL "https://github.com/openclaw/openclaw/pull/28428.diff" > "$DIFF"
  }
fi

if [ ! -s "$DIFF" ]; then
  echo "ERROR: cannot download diff for #28428"
  exit 1
fi

# Apply excluding tests, changelog, service-env.ts (handled by #28291 script + below)
echo "  Applying git diff (13 src files)..."
git apply --exclude='*test*' --exclude='*CHANGELOG*' --exclude='*service-env.ts' "$DIFF" 2>&1

# Apply service-env.ts token removal (compatible with #28291)
python3 - "src/daemon/service-env.ts" << 'PYEOF'
import sys
with open(sys.argv[1], "r") as f:
    content = f.read()

changed = False

# Remove token from params type
old_p = '  port: number;\n  token?: string;\n  launchdLabel'
new_p = '  port: number;\n  launchdLabel'
if old_p in content:
    content = content.replace(old_p, new_p, 1)
    changed = True
    print("  Removed token from params type")

# Remove token from destructuring
old_d = 'const { env, port, token, launchdLabel } = params;'
new_d = 'const { env, port, launchdLabel } = params;'
if old_d in content:
    content = content.replace(old_d, new_d, 1)
    changed = True
    print("  Removed token from destructuring")

# Remove OPENCLAW_GATEWAY_TOKEN line
old_t = '    OPENCLAW_GATEWAY_TOKEN: token,\n'
if old_t in content:
    content = content.replace(old_t, '', 1)
    changed = True
    print("  Removed OPENCLAW_GATEWAY_TOKEN from return")

if changed:
    with open(sys.argv[1], "w") as f:
        f.write(content)
    print("  service-env.ts: token drift changes applied")
else:
    print("  service-env.ts: no token changes needed")
PYEOF

echo "OK: #28428 applied — token drift fix"
