#!/usr/bin/env bash
# PR #26441 — fix(gateway): graceful drain mode for restart/shutdown
# ESSENTIAL changes only — subagent-aware drain counting + recovery probe.
# Skipped: googlechat extension changes, CLI options (--drain/--drain-timeout),
# run-loop.ts (v2026.2.26 already has GatewayDrainingError/markGatewayDraining),
# command-queue.ts (v2026.2.26 already has equivalent drain rejection).
set -euo pipefail
SRC="${1:-.}/src"

REG_FILE="$SRC/agents/subagent-registry.ts"
RELOAD_FILE="$SRC/gateway/server-reload-handlers.ts"
SERVER_FILE="$SRC/gateway/server.impl.ts"

# Idempotency check
if grep -q 'countTotalActiveSubagentRuns' "$REG_FILE" 2>/dev/null; then
  echo "    SKIP: #26441 already applied"
  exit 0
fi

# 1) subagent-registry.ts: Add constants, recovery probe, and exported count functions
python3 - "$REG_FILE" << 'PYEOF'
import sys
path = sys.argv[1]
with open(path, 'r') as f:
    content = f.read()

# 1a) Add RESUME_RECOVERY_WAIT_TIMEOUT_MS and RESTART_INTERRUPTED_ERROR constants
old_const = 'const ANNOUNCE_EXPIRY_MS = 5 * 60_000; // 5 minutes\ntype SubagentRunOrphanReason'
new_const = '''const ANNOUNCE_EXPIRY_MS = 5 * 60_000; // 5 minutes
const RESUME_RECOVERY_WAIT_TIMEOUT_MS = 30_000;
const RESTART_INTERRUPTED_ERROR = "subagent run interrupted by gateway restart (requeue required)";
type SubagentRunOrphanReason'''

if old_const not in content:
    print("    FAIL: #26441 subagent-registry.ts ANNOUNCE_EXPIRY_MS pattern not found", file=sys.stderr)
    sys.exit(1)

content = content.replace(old_const, new_const, 1)

# 1b) Update resumeSubagentRun: cap wait timeout + pass recoveryProbe
old_resume = '''  // Wait for completion again after restart.
  const cfg = loadConfig();
  const waitTimeoutMs = resolveSubagentWaitTimeoutMs(cfg, entry.runTimeoutSeconds);
  void waitForSubagentCompletion(runId, waitTimeoutMs);'''

new_resume = '''  // Wait for completion again after restart.
  const cfg = loadConfig();
  const waitTimeoutMs = resolveSubagentWaitTimeoutMs(cfg, entry.runTimeoutSeconds);
  void waitForSubagentCompletion(runId, Math.min(waitTimeoutMs, RESUME_RECOVERY_WAIT_TIMEOUT_MS), {
    recoveryProbe: true,
  });'''

if old_resume not in content:
    print("    FAIL: #26441 subagent-registry.ts resumeSubagentRun pattern not found", file=sys.stderr)
    sys.exit(1)

content = content.replace(old_resume, new_resume, 1)

# 1c) Add logging for restored active runs in restoreSubagentRunsOnce
old_restore = '''    if (subagentRuns.size === 0) {
      return;
    }
    // Resume pending work.'''

new_restore = '''    if (subagentRuns.size === 0) {
      return;
    }
    const activeRestoredRuns = Array.from(subagentRuns.values()).filter(
      (entry) => typeof entry.endedAt !== "number",
    );
    if (activeRestoredRuns.length > 0) {
      const sample = activeRestoredRuns
        .slice(0, 5)
        .map((entry) => `${entry.runId}:${entry.childSessionKey}`)
        .join(", ");
      const suffix =
        activeRestoredRuns.length > 5 ? ` (+${activeRestoredRuns.length - 5} more)` : "";
      defaultRuntime.log(
        `[warn] Restored ${activeRestoredRuns.length} active subagent run(s) after restart: ${sample}${suffix}`,
      );
    }
    // Resume pending work.'''

if old_restore not in content:
    print("    FAIL: #26441 subagent-registry.ts restoreSubagentRunsOnce pattern not found", file=sys.stderr)
    sys.exit(1)

content = content.replace(old_restore, new_restore, 1)

# 1d) Update waitForSubagentCompletion signature + add recovery probe handling
old_wait = 'async function waitForSubagentCompletion(runId: string, waitTimeoutMs: number) {'
new_wait = '''async function waitForSubagentCompletion(
  runId: string,
  waitTimeoutMs: number,
  opts?: { recoveryProbe?: boolean },
) {'''

if old_wait not in content:
    print("    FAIL: #26441 subagent-registry.ts waitForSubagentCompletion signature not found", file=sys.stderr)
    sys.exit(1)

content = content.replace(old_wait, new_wait, 1)

# 1e) Add recovery probe timeout handling after "if (!entry) { return; }"
old_entry_check = '''    if (!entry) {
      return;
    }
    let mutated = false;
    if (typeof wait.startedAt === "number") {'''

new_entry_check = '''    if (!entry) {
      return;
    }
    if (opts?.recoveryProbe && wait.status === "timeout") {
      defaultRuntime.log(
        `[warn] Subagent run marked interrupted after restart run=${runId} child=${entry.childSessionKey}`,
      );
      await completeSubagentRun({
        runId,
        endedAt: Date.now(),
        outcome: {
          status: "error",
          error: RESTART_INTERRUPTED_ERROR,
        },
        reason: SUBAGENT_ENDED_REASON_ERROR,
        sendFarewell: true,
        accountId: entry.requesterOrigin?.accountId,
        triggerCleanup: true,
      });
      return;
    }
    let mutated = false;
    if (typeof wait.startedAt === "number") {'''

if old_entry_check not in content:
    print("    FAIL: #26441 subagent-registry.ts entry check pattern not found", file=sys.stderr)
    sys.exit(1)

content = content.replace(old_entry_check, new_entry_check, 1)

# 1f) Add listActiveSubagentRuns and countTotalActiveSubagentRuns before countActiveRunsForSession
old_count = 'export function countActiveRunsForSession(requesterSessionKey: string): number {'
new_count = '''export function listActiveSubagentRuns(): SubagentRunRecord[] {
  return Array.from(getSubagentRunsSnapshotForRead(subagentRuns).values()).filter(
    (entry) => typeof entry.endedAt !== "number",
  );
}

export function countTotalActiveSubagentRuns(): number {
  return listActiveSubagentRuns().length;
}

export function countActiveRunsForSession(requesterSessionKey: string): number {'''

if old_count not in content:
    print("    FAIL: #26441 subagent-registry.ts countActiveRunsForSession pattern not found", file=sys.stderr)
    sys.exit(1)

content = content.replace(old_count, new_count, 1)

with open(path, 'w') as f:
    f.write(content)
PYEOF

# 2) server-reload-handlers.ts: Add countTotalActiveSubagentRuns import + usage
python3 - "$RELOAD_FILE" << 'PYEOF'
import sys
path = sys.argv[1]
with open(path, 'r') as f:
    content = f.read()

# 2a) Add import
old_import = 'import { getActiveEmbeddedRunCount } from "../agents/pi-embedded-runner/runs.js";'
new_import = 'import { getActiveEmbeddedRunCount } from "../agents/pi-embedded-runner/runs.js";\nimport { countTotalActiveSubagentRuns } from "../agents/subagent-registry.js";'

if old_import not in content:
    print("    FAIL: #26441 server-reload-handlers.ts import pattern not found", file=sys.stderr)
    sys.exit(1)

content = content.replace(old_import, new_import, 1)

# 2b) Add activeSubagents to getActiveCounts
old_counts = '''      const embeddedRuns = getActiveEmbeddedRunCount();
      return {
        queueSize,
        pendingReplies,
        embeddedRuns,
        totalActive: queueSize + pendingReplies + embeddedRuns,
      };'''

new_counts = '''      const embeddedRuns = getActiveEmbeddedRunCount();
      const activeSubagents = countTotalActiveSubagentRuns();
      return {
        queueSize,
        pendingReplies,
        embeddedRuns,
        activeSubagents,
        totalActive: queueSize + pendingReplies + embeddedRuns + activeSubagents,
      };'''

if old_counts not in content:
    print("    FAIL: #26441 server-reload-handlers.ts getActiveCounts pattern not found", file=sys.stderr)
    sys.exit(1)

content = content.replace(old_counts, new_counts, 1)

# 2c) Add subagent detail to formatActiveDetails
old_details = '''      if (counts.embeddedRuns > 0) {
        details.push(`${counts.embeddedRuns} embedded run(s)`);
      }
      return details;'''

new_details = '''      if (counts.embeddedRuns > 0) {
        details.push(`${counts.embeddedRuns} embedded run(s)`);
      }
      if (counts.activeSubagents > 0) {
        details.push(`${counts.activeSubagents} subagent run(s)`);
      }
      return details;'''

if old_details not in content:
    print("    FAIL: #26441 server-reload-handlers.ts formatActiveDetails pattern not found", file=sys.stderr)
    sys.exit(1)

content = content.replace(old_details, new_details, 1)

with open(path, 'w') as f:
    f.write(content)
PYEOF

# 3) server.impl.ts: Add countTotalActiveSubagentRuns to import + setPreRestartDeferralCheck
python3 - "$SERVER_FILE" << 'PYEOF'
import sys
path = sys.argv[1]
with open(path, 'r') as f:
    content = f.read()

# 3a) Update import
old_import = 'import { initSubagentRegistry } from "../agents/subagent-registry.js";'
new_import = 'import { countTotalActiveSubagentRuns, initSubagentRegistry } from "../agents/subagent-registry.js";'

if old_import not in content:
    print("    FAIL: #26441 server.impl.ts import pattern not found", file=sys.stderr)
    sys.exit(1)

content = content.replace(old_import, new_import, 1)

# 3b) Add countTotalActiveSubagentRuns to setPreRestartDeferralCheck
old_check = '    () => getTotalQueueSize() + getTotalPendingReplies() + getActiveEmbeddedRunCount(),'
new_check = '''    () =>
      getTotalQueueSize() +
      getTotalPendingReplies() +
      getActiveEmbeddedRunCount() +
      countTotalActiveSubagentRuns(),'''

if old_check not in content:
    print("    FAIL: #26441 server.impl.ts setPreRestartDeferralCheck pattern not found", file=sys.stderr)
    sys.exit(1)

content = content.replace(old_check, new_check, 1)

with open(path, 'w') as f:
    f.write(content)
PYEOF

echo "    OK: #26441 graceful drain — subagent-aware counting + recovery probe applied (3 files)"
echo "    NOTE: Skipped googlechat extension, run-loop.ts (already has drain), CLI options, command-queue.ts (already has GatewayDrainingError)"
