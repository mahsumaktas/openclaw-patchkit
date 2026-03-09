#!/usr/bin/env bash
# PR #28247 — fix(gateway): fail fast on port-in-use to prevent systemd crash loop
# Adds early port availability check before loading the full gateway (~340MB).
# Also adds systemd StartLimitBurst/StartLimitIntervalSec to prevent infinite restarts.
#
# Changes:
# 1. cli/gateway-cli/run.ts: Import ensurePortAvailable/handlePortError + add early check
# 2. daemon/systemd-unit.ts: Add StartLimitIntervalSec=300, StartLimitBurst=5
set -euo pipefail
SRC="${1:-.}/src"

RUN_FILE="$SRC/cli/gateway-cli/run.ts"
UNIT_FILE="$SRC/daemon/systemd-unit.ts"

# Idempotency check
if grep -q 'ensurePortAvailable' "$RUN_FILE" 2>/dev/null; then
  echo "    SKIP: #28247 already applied"
  exit 0
fi

[ -f "$RUN_FILE" ]  || { echo "    FAIL: $RUN_FILE not found"; exit 1; }
[ -f "$UNIT_FILE" ] || { echo "    FAIL: $UNIT_FILE not found"; exit 1; }

# 1) run.ts: Add ensurePortAvailable/handlePortError imports + early port check
python3 - "$RUN_FILE" << 'PYEOF'
import sys

path = sys.argv[1]
with open(path, 'r') as f:
    content = f.read()

# 1a) Expand import
old_import = 'import { formatPortDiagnostics, inspectPortUsage } from "../../infra/ports.js";'
new_import = '''import {
  ensurePortAvailable,
  formatPortDiagnostics,
  handlePortError,
  inspectPortUsage,
} from "../../infra/ports.js";'''

if old_import not in content:
    print("    FAIL: #28247 run.ts import pattern not found", file=sys.stderr)
    sys.exit(1)

content = content.replace(old_import, new_import, 1)

# 1b) Add early port probe before try { await runGatewayLoop
old_try = '      : undefined;\n\n  try {\n    await runGatewayLoop({'
new_try = '''      : undefined;

  // Early port probe: fail fast before loading ~340MB gateway (avoids systemd crash loops).
  if (!opts.force) {
    try {
      await ensurePortAvailable(port);
    } catch (err) {
      await handlePortError(err, port, "Early port check", defaultRuntime);
      return;
    }
  }

  try {
    await runGatewayLoop({'''

if old_try not in content:
    print("    FAIL: #28247 run.ts try/runGatewayLoop pattern not found", file=sys.stderr)
    sys.exit(1)

content = content.replace(old_try, new_try, 1)

with open(path, 'w') as f:
    f.write(content)
print("    OK: #28247 early port check added to run.ts")
PYEOF

# 2) systemd-unit.ts: Add restart limits
python3 - "$UNIT_FILE" << 'PYEOF'
import sys

path = sys.argv[1]
with open(path, 'r') as f:
    content = f.read()

old_restart = '    "Restart=always",\n    "RestartSec=5",'
new_restart = '''    "Restart=always",
    "RestartSec=5",
    // Limit restarts to prevent infinite crash loops (e.g. port already in use).
    "StartLimitIntervalSec=300",
    "StartLimitBurst=5",'''

if old_restart not in content:
    print("    FAIL: #28247 systemd-unit.ts RestartSec pattern not found", file=sys.stderr)
    sys.exit(1)

content = content.replace(old_restart, new_restart, 1)

with open(path, 'w') as f:
    f.write(content)
print("    OK: #28247 systemd restart limits added to systemd-unit.ts")
PYEOF

echo "    OK: #28247 port-in-use fail-fast + systemd restart limits applied (2 files)"
