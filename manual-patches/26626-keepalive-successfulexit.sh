#!/usr/bin/env bash
# PR #26626 — fix(daemon): replace unconditional KeepAlive with SuccessfulExit dict
# Boolean KeepAlive:true causes launchd to restart the daemon even on clean
# exit (e.g. user-initiated stop), creating crash-loops (29 restarts/day observed).
# SuccessfulExit:false dict tells launchd to only restart on non-zero exit,
# which is the correct behavior for a gateway daemon.
set -euo pipefail

SRC="${1:?Usage: $0 <openclaw-source-dir>}/src"

FILE="$SRC/daemon/launchd-plist.ts"
if [ ! -f "$FILE" ]; then
  echo "    FAIL: #26626 target file not found: $FILE"
  exit 1
fi

# Idempotency check
if grep -q 'SuccessfulExit' "$FILE"; then
  echo "    SKIP: #26626 already applied"
  exit 0
fi

python3 - "$FILE" << 'PYEOF'
import sys

path = sys.argv[1]
with open(path, 'r') as f:
    content = f.read()

# The KeepAlive<true/> is inside a template string on the buildLaunchAgentPlist return line.
# Replace the unconditional KeepAlive boolean with SuccessfulExit dict.

old_keepalive = r'<key>KeepAlive</key>\n    <true/>'
new_keepalive = r'<key>KeepAlive</key>\n    <dict>\n      <key>SuccessfulExit</key>\n      <false/>\n    </dict>'

if old_keepalive not in content:
    print("    FAIL: #26626 KeepAlive pattern not found in launchd-plist.ts")
    sys.exit(1)

content = content.replace(old_keepalive, new_keepalive, 1)

with open(path, 'w') as f:
    f.write(content)

print("    OK: #26626 replaced KeepAlive<true/> with SuccessfulExit dict")
PYEOF
