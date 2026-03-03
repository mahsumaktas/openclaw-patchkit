#!/usr/bin/env bash
set -euo pipefail
cd "$1"

PATCH_ID="PR-27013"
MARKER_LIFECYCLE="preSnapshot"
MARKER_HEALTH="needForceKill"

# --- File 1: src/cli/daemon-cli/lifecycle.ts ---
# Add pre-restart inspection: detect stale PIDs and kill them before restart
FILE1="src/cli/daemon-cli/lifecycle.ts"

if [[ ! -f "$FILE1" ]]; then
  echo "$PATCH_ID: ERROR - $FILE1 not found"
  exit 1
fi

if grep -q "$MARKER_LIFECYCLE" "$FILE1"; then
  echo "$PATCH_ID: $FILE1 already patched (idempotent skip)"
else
  python3 - "$FILE1" << 'PYEOF'
import sys

filepath = sys.argv[1]
with open(filepath, 'r') as f:
    content = f.read()

# 1. Add inspectGatewayRestart import
old_import = '''import {
  DEFAULT_RESTART_HEALTH_ATTEMPTS,
  DEFAULT_RESTART_HEALTH_DELAY_MS,
  renderRestartDiagnostics,
  terminateStaleGatewayPids,
  waitForGatewayHealthyRestart,
} from "./restart-health.js";'''

new_import = '''import {
  DEFAULT_RESTART_HEALTH_ATTEMPTS,
  DEFAULT_RESTART_HEALTH_DELAY_MS,
  inspectGatewayRestart,
  renderRestartDiagnostics,
  terminateStaleGatewayPids,
  waitForGatewayHealthyRestart,
} from "./restart-health.js";'''

if old_import not in content:
    print(f"ERROR: Could not find restart-health import block in {filepath}", file=sys.stderr)
    sys.exit(1)

content = content.replace(old_import, new_import, 1)

# 2. Add pre-restart stale PID detection before runServiceRestart call
old_restart = '  return await runServiceRestart({\n    serviceNoun: "Gateway",'

new_restart = '''  const preSnapshot = await inspectGatewayRestart({ service, port: restartPort }).catch(() => null);
  if (preSnapshot && preSnapshot.staleGatewayPids.length > 0) {
    if (!json) {
      defaultRuntime.log(
        theme.warn(
          `Found stale gateway process(es) holding port ${restartPort}: ${preSnapshot.staleGatewayPids.join(", ")}.`,
        ),
      );
      defaultRuntime.log(theme.muted("Stopping stale process(es) before restart..."));
    }
    await terminateStaleGatewayPids(preSnapshot.staleGatewayPids);
  }

  return await runServiceRestart({
    serviceNoun: "Gateway",'''

if old_restart not in content:
    print(f"ERROR: Could not find runServiceRestart call in {filepath}", file=sys.stderr)
    sys.exit(1)

content = content.replace(old_restart, new_restart, 1)

with open(filepath, 'w') as f:
    f.write(content)

print(f"Patched {filepath}")
PYEOF
  echo "$PATCH_ID: Patched $FILE1"
fi

# --- File 2: src/cli/daemon-cli/restart-health.ts ---
# Fix terminateStaleGatewayPids: add needForceKill flag + extra sleep after SIGKILL
FILE2="src/cli/daemon-cli/restart-health.ts"

if [[ ! -f "$FILE2" ]]; then
  echo "$PATCH_ID: ERROR - $FILE2 not found"
  exit 1
fi

if grep -q "$MARKER_HEALTH" "$FILE2"; then
  echo "$PATCH_ID: $FILE2 already patched (idempotent skip)"
else
  python3 - "$FILE2" << 'PYEOF'
import sys

filepath = sys.argv[1]
with open(filepath, 'r') as f:
    content = f.read()

# v2026.3.2 has a simple version: killProcessTree + sleep(500) + return targets
# The PR adds a SIGKILL follow-up pass with needForceKill flag for stubborn processes
# Replace the entire function body

old_fn = '''export async function terminateStaleGatewayPids(pids: number[]): Promise<number[]> {
  const targets = Array.from(
    new Set(pids.filter((pid): pid is number => Number.isFinite(pid) && pid > 0)),
  );
  for (const pid of targets) {
    killProcessTree(pid, { graceMs: 300 });
  }
  if (targets.length > 0) {
    await sleep(500);
  }
  return targets;
}'''

new_fn = '''export async function terminateStaleGatewayPids(pids: number[]): Promise<number[]> {
  const targets = Array.from(
    new Set(pids.filter((pid): pid is number => Number.isFinite(pid) && pid > 0)),
  );
  const killed: number[] = [];
  for (const pid of targets) {
    try {
      killProcessTree(pid, { graceMs: 300 });
      killed.push(pid);
    } catch {
      // Process may already be gone.
    }
  }

  await sleep(400);

  let needForceKill = false;
  for (const pid of killed) {
    try {
      process.kill(pid, 0);
      process.kill(pid, "SIGKILL");
      needForceKill = true;
    } catch (err) {
      const code = (err as NodeJS.ErrnoException)?.code;
      if (code !== "ESRCH") {
        throw err;
      }
    }
  }

  if (needForceKill) {
    await sleep(200);
  }

  return killed;
}'''

if old_fn not in content:
    print(f"ERROR: Could not find terminateStaleGatewayPids function in {filepath}", file=sys.stderr)
    sys.exit(1)

content = content.replace(old_fn, new_fn, 1)

with open(filepath, 'w') as f:
    f.write(content)

print(f"Patched {filepath}")
PYEOF
  echo "$PATCH_ID: Patched $FILE2"
fi

echo "$PATCH_ID: Done"
