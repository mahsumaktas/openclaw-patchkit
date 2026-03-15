#!/usr/bin/env bash
# PR #39117 — fix: recover busy sessions and improve queued handling
# When an embedded run times out but never reaches its finally block, the
# per-session command lane stays permanently "busy" — all subsequent messages
# queue forever. This patch adds:
#
# 1. runs.ts: isActiveEmbeddedRunHandle() guard + EMBEDDED_RUN_ABORT_RELEASE_GRACE_MS export
# 2. runs.ts: clearActiveEmbeddedRun() gains a `reason` parameter for audit logging
# 3. command-queue.ts: resetCommandLane() to force-release stuck lane bookkeeping
# 4. attempt.ts: watchdog release timer that force-clears the lane after grace period
# 5. payloads.ts: selectAssistantAnswerTexts() — suppress stale text after aborted runs
# 6. queue-policy.ts: buildQueuedBusyReceipt() — user-facing "queued" receipt
# 7. agent-runner.ts: return busy receipt to user when message is enqueued
# 8. sessions types + schema + handler: session reset audit metadata
#
# See: https://github.com/openclaw/openclaw/pull/39117
set -euo pipefail

WORKDIR="${1:-$(ls -d /tmp/openclaw-patch-build-* 2>/dev/null | head -1)}"
if [ -z "$WORKDIR" ] || [ ! -d "$WORKDIR" ]; then
  echo "FAIL: No build workspace found"
  exit 1
fi
cd "$WORKDIR"

RUNS_FILE="src/agents/pi-embedded-runner/runs.ts"
CMD_QUEUE_FILE="src/process/command-queue.ts"
ATTEMPT_FILE="src/agents/pi-embedded-runner/run/attempt.ts"
PAYLOADS_FILE="src/agents/pi-embedded-runner/run/payloads.ts"
QUEUE_POLICY_FILE="src/auto-reply/reply/queue-policy.ts"
AGENT_RUNNER_FILE="src/auto-reply/reply/agent-runner.ts"
SESSION_TYPES_FILE="src/config/sessions/types.ts"
SESSION_SCHEMA_FILE="src/gateway/protocol/schema/sessions.ts"
SESSION_HANDLER_FILE="src/gateway/server-methods/sessions.ts"

APPLIED=0
TOTAL=9

# ── Helper ──
check_file() {
  if ! [ -f "$1" ]; then
    echo "WARN: $1 not found — skipping"
    return 1
  fi
  return 0
}

# ═══════════════════════════════════════════════════════════
# 1. runs.ts — add isActiveEmbeddedRunHandle, GRACE_MS export, reason param
# ═══════════════════════════════════════════════════════════
if check_file "$RUNS_FILE"; then
  if grep -q 'isActiveEmbeddedRunHandle' "$RUNS_FILE" 2>/dev/null; then
    echo "SKIP: #39117 runs.ts already patched"
    APPLIED=$((APPLIED + 1))
  else
    python3 - "$RUNS_FILE" << 'PYEOF'
import sys, re

with open(sys.argv[1], "r") as f:
    content = f.read()

changes = 0

# 1a. Add EMBEDDED_RUN_ABORT_RELEASE_GRACE_MS after the ACTIVE_EMBEDDED_RUNS line
# v2026.3.8: const ACTIVE_EMBEDDED_RUNS = new Map<...>();
# v2026.3.13: const ACTIVE_EMBEDDED_RUNS = embeddedRunState.activeRuns;
anchor_match = re.search(r'const ACTIVE_EMBEDDED_RUNS = [^;]+;', content)
if anchor_match and "EMBEDDED_RUN_ABORT_RELEASE_GRACE_MS" not in content:
    anchor = anchor_match.group(0)
    content = content.replace(
        anchor,
        anchor + "\nexport const EMBEDDED_RUN_ABORT_RELEASE_GRACE_MS = 15_000;",
        1,
    )
    changes += 1

# 1b. Add isActiveEmbeddedRunHandle function before waitForEmbeddedPiRunEnd
wait_anchor = "export function waitForEmbeddedPiRunEnd("
new_fn = '''export function isActiveEmbeddedRunHandle(
  sessionId: string,
  handle: EmbeddedPiQueueHandle,
): boolean {
  return ACTIVE_EMBEDDED_RUNS.get(sessionId) === handle;
}

'''
if wait_anchor in content and "isActiveEmbeddedRunHandle" not in content:
    content = content.replace(wait_anchor, new_fn + wait_anchor, 1)
    changes += 1

# 1c. Add `reason` parameter to clearActiveEmbeddedRun
old_clear_sig = re.search(
    r'export function clearActiveEmbeddedRun\(\s*\n\s*sessionId: string,\s*\n\s*handle: EmbeddedPiQueueHandle,\s*\n\s*sessionKey\?: string,?\s*\n\)',
    content,
)
if old_clear_sig and 'reason = "run_completed"' not in content:
    content = content.replace(
        old_clear_sig.group(0),
        'export function clearActiveEmbeddedRun(\n  sessionId: string,\n  handle: EmbeddedPiQueueHandle,\n  sessionKey?: string,\n  reason = "run_completed",\n)',
        1,
    )
    changes += 1

# 1d. Update logSessionStateChange to use reason parameter
old_log = 'logSessionStateChange({ sessionId, sessionKey, state: "idle", reason: "run_completed" });'
new_log = 'logSessionStateChange({ sessionId, sessionKey, state: "idle", reason });'
if old_log in content:
    content = content.replace(old_log, new_log, 1)
    changes += 1

# 1e. Update debug log to include reason
old_debug = re.search(
    r'`run cleared: sessionId=\$\{sessionId\} totalActive=\$\{ACTIVE_EMBEDDED_RUNS\.size\}`',
    content,
)
if old_debug and "reason=${reason}" not in content:
    content = content.replace(
        old_debug.group(0),
        '`run cleared: sessionId=${sessionId} totalActive=${ACTIVE_EMBEDDED_RUNS.size} reason=${reason}`',
        1,
    )
    changes += 1

# 1f. Export isActiveEmbeddedRunHandle and EMBEDDED_RUN_ABORT_RELEASE_GRACE_MS
# (already inline-exported above)

if changes > 0:
    with open(sys.argv[1], "w") as f:
        f.write(content)
    print(f"OK: #39117 runs.ts — {changes} changes applied")
else:
    print("WARN: #39117 runs.ts — no changes needed or patterns not found")
    sys.exit(1)
PYEOF
    APPLIED=$((APPLIED + 1))
  fi
fi

# ═══════════════════════════════════════════════════════════
# 2. command-queue.ts — add resetCommandLane()
# ═══════════════════════════════════════════════════════════
if check_file "$CMD_QUEUE_FILE"; then
  if grep -q 'resetCommandLane' "$CMD_QUEUE_FILE" 2>/dev/null; then
    echo "SKIP: #39117 command-queue.ts already patched"
    APPLIED=$((APPLIED + 1))
  else
    python3 - "$CMD_QUEUE_FILE" << 'PYEOF'
import sys, re

with open(sys.argv[1], "r") as f:
    content = f.read()

# Insert resetCommandLane after clearCommandLane function
# Find the end of clearCommandLane (the closing brace + return statement)
anchor = re.search(
    r'export function clearCommandLane\(.*?\n(.*?\n)*?\s*return removed;\s*\n\}',
    content,
)
if not anchor:
    print("FAIL: #39117 cannot find clearCommandLane function in command-queue.ts")
    sys.exit(1)

new_fn = '''

/**
 * Force-reset a single lane's active runtime bookkeeping while preserving
 * queued work. Used by embedded-run watchdogs when a timed-out run never
 * reaches its finally block and leaves the per-session lane permanently busy.
 */
export function resetCommandLane(lane: string = CommandLane.Main) {
  const cleaned = lane.trim() || CommandLane.Main;
  const state = queueState.lanes.get(cleaned);
  if (!state) {
    return 0;
  }
  const released = state.activeTaskIds.size;
  state.generation += 1;
  state.activeTaskIds.clear();
  state.draining = false;
  if (state.queue.length > 0) {
    drainLane(cleaned);
  }
  return released;
}'''

insert_pos = anchor.end()
content = content[:insert_pos] + new_fn + content[insert_pos:]

with open(sys.argv[1], "w") as f:
    f.write(content)

print("OK: #39117 command-queue.ts — added resetCommandLane()")
PYEOF
    APPLIED=$((APPLIED + 1))
  fi
fi

# ═══════════════════════════════════════════════════════════
# 3. attempt.ts — watchdog release timer + lane resolution
# ═══════════════════════════════════════════════════════════
if check_file "$ATTEMPT_FILE"; then
  if grep -q 'abortReleaseTimer' "$ATTEMPT_FILE" 2>/dev/null; then
    echo "SKIP: #39117 attempt.ts already patched"
    APPLIED=$((APPLIED + 1))
  else
    python3 - "$ATTEMPT_FILE" << 'PYEOF'
import sys, re

with open(sys.argv[1], "r") as f:
    content = f.read()

changes = 0

# 3a. Add imports at the top: resetCommandLane, resolveSessionLane, isActiveEmbeddedRunHandle, EMBEDDED_RUN_ABORT_RELEASE_GRACE_MS
# Add resetCommandLane import
if 'resetCommandLane' not in content:
    # Find an existing import from command-queue or process
    cmd_import = re.search(r'import \{[^}]*\} from ["\'].*?command-queue.*?["\'];', content)
    if cmd_import:
        old_imp = cmd_import.group(0)
        # Add resetCommandLane to existing import
        new_imp = old_imp.replace("} from", ", resetCommandLane } from")
        content = content.replace(old_imp, new_imp, 1)
    else:
        # Add new import line after other imports
        content = 'import { resetCommandLane } from "../../../process/command-queue.js";\n' + content
    changes += 1

# Add resolveSessionLane import
if 'resolveSessionLane' not in content:
    lanes_import = re.search(r'import \{[^}]*\} from ["\'].*?lanes.*?["\'];', content)
    if lanes_import:
        old_imp = lanes_import.group(0)
        new_imp = old_imp.replace("} from", ", resolveSessionLane } from")
        content = content.replace(old_imp, new_imp, 1)
    else:
        # Find the logger import from the same package and insert nearby
        logger_import = re.search(r'import \{ log \} from ["\']\.\.\/logger\.js["\'];', content)
        if logger_import:
            content = content.replace(
                logger_import.group(0),
                logger_import.group(0) + '\nimport { resolveSessionLane } from "../lanes.js";',
                1,
            )
        else:
            content = 'import { resolveSessionLane } from "../lanes.js";\n' + content
    changes += 1

# Add isActiveEmbeddedRunHandle and EMBEDDED_RUN_ABORT_RELEASE_GRACE_MS imports
runs_import = re.search(
    r'import \{([^}]*?)clearActiveEmbeddedRun([^}]*?)\} from ["\']\.\.\/runs\.js["\'];',
    content,
    re.DOTALL,
)
if runs_import:
    old_imp = runs_import.group(0)
    additions = []
    if 'EMBEDDED_RUN_ABORT_RELEASE_GRACE_MS' not in old_imp:
        additions.append('EMBEDDED_RUN_ABORT_RELEASE_GRACE_MS')
    if 'isActiveEmbeddedRunHandle' not in old_imp:
        additions.append('isActiveEmbeddedRunHandle')
    if additions:
        add_str = ",\n  ".join(additions)
        new_imp = old_imp.replace("clearActiveEmbeddedRun", f"clearActiveEmbeddedRun,\n  {add_str}")
        content = content.replace(old_imp, new_imp, 1)
        changes += 1

# 3b. Add sessionLane resolution + abortReleaseTimer + watchdogReleased variables
# Find: setActiveEmbeddedRun(params.sessionId, queueHandle, params.sessionKey);
set_active = 'setActiveEmbeddedRun(params.sessionId, queueHandle, params.sessionKey);'
if set_active in content and 'sessionLane' not in content:
    content = content.replace(
        set_active,
        'const sessionLane = resolveSessionLane(params.sessionKey?.trim() || params.sessionId);\n      ' + set_active,
        1,
    )
    changes += 1

# Find: let abortWarnTimer and add abortReleaseTimer + watchdogReleased
warn_timer = 'let abortWarnTimer: NodeJS.Timeout | undefined;'
if warn_timer in content and 'abortReleaseTimer' not in content:
    content = content.replace(
        warn_timer,
        warn_timer + '\n      let abortReleaseTimer: NodeJS.Timeout | undefined;\n      let watchdogReleased = false;',
        1,
    )
    changes += 1

# 3c. Add watchdog release timer inside the abort warn timer callback
# The PR adds a setTimeout block inside the 10_000ms warn timer
# Find the pattern where abortWarnTimer logs streaming status
# Regex must capture through the closing } of if (!isProbeSession) to avoid duplicate braces
streaming_log = re.search(
    r'(`embedded run abort still streaming:.*?`[,\s]*\n\s*\);\s*\n\s*\})',
    content,
)
if streaming_log and 'abortReleaseTimer' not in content.split(streaming_log.group(0))[1][:200]:
    watchdog_block = '''`embedded run abort still streaming: runId=${params.runId} sessionId=${params.sessionId}`,
                );
              }
              if (!abortReleaseTimer) {
                abortReleaseTimer = setTimeout(() => {
                  if (!isActiveEmbeddedRunHandle(params.sessionId, queueHandle)) {
                    return;
                  }
                  watchdogReleased = true;
                  const releasedActive = resetCommandLane(sessionLane);
                  clearActiveEmbeddedRun(
                    params.sessionId,
                    queueHandle,
                    params.sessionKey,
                    "run_watchdog_timeout",
                  );
                  if (!isProbeSession) {
                    log.error(
                      `embedded run watchdog forced lane release: runId=${params.runId} sessionId=${params.sessionId} lane=${sessionLane} releasedActive=${releasedActive}`,
                    );
                  }
                }, EMBEDDED_RUN_ABORT_RELEASE_GRACE_MS);
              }'''
    content = content.replace(streaming_log.group(0), watchdog_block, 1)
    changes += 1

# 3d. Clear abortReleaseTimer in the finally block
if 'clearTimeout(abortWarnTimer)' in content and 'clearTimeout(abortReleaseTimer)' not in content:
    content = content.replace(
        'if (abortWarnTimer) {\n          clearTimeout(abortWarnTimer);\n        }',
        'if (abortWarnTimer) {\n          clearTimeout(abortWarnTimer);\n        }\n        if (abortReleaseTimer) {\n          clearTimeout(abortReleaseTimer);\n        }',
        1,
    )
    changes += 1

# 3e. Update run cleanup debug log to include watchdogReleased
old_cleanup_log = re.search(
    r'`run cleanup:.*?aborted=\$\{aborted\} timedOut=\$\{timedOut\}`',
    content,
)
if old_cleanup_log and 'watchdogReleased' not in old_cleanup_log.group(0):
    content = content.replace(
        old_cleanup_log.group(0),
        '`run cleanup: runId=${params.runId} sessionId=${params.sessionId} aborted=${aborted} timedOut=${timedOut} watchdogReleased=${watchdogReleased}`',
        1,
    )
    changes += 1

# 3f. Update clearActiveEmbeddedRun call in finally to pass reason
old_clear = 'clearActiveEmbeddedRun(params.sessionId, queueHandle, params.sessionKey);'
if old_clear in content:
    content = content.replace(
        old_clear,
        'clearActiveEmbeddedRun(\n          params.sessionId,\n          queueHandle,\n          params.sessionKey,\n          watchdogReleased ? "run_watchdog_timeout" : "run_completed",\n        );',
        1,
    )
    changes += 1

if changes > 0:
    with open(sys.argv[1], "w") as f:
        f.write(content)
    print(f"OK: #39117 attempt.ts — {changes} changes applied")
else:
    print("WARN: #39117 attempt.ts — no changes applied")
    sys.exit(1)
PYEOF
    APPLIED=$((APPLIED + 1))
  fi
fi

# ═══════════════════════════════════════════════════════════
# 4. payloads.ts — selectAssistantAnswerTexts (suppress stale text after abort)
# ═══════════════════════════════════════════════════════════
if check_file "$PAYLOADS_FILE"; then
  if grep -q 'selectAssistantAnswerTexts' "$PAYLOADS_FILE" 2>/dev/null; then
    echo "SKIP: #39117 payloads.ts already patched"
    APPLIED=$((APPLIED + 1))
  else
    python3 - "$PAYLOADS_FILE" << 'PYEOF'
import sys, re

with open(sys.argv[1], "r") as f:
    content = f.read()

changes = 0

# 4c. Replace inline answerTexts logic with selectAssistantAnswerTexts call
# MUST run before 4a so the fallbackAnswerText removal targets the original
# instance inside buildEmbeddedRunPayloads, not the one we're about to add
# in selectAssistantAnswerTexts.
# Try to replace the full answerTexts block first — only remove const
# fallbackAnswerText if the replacement succeeds (otherwise the dangling
# reference to fallbackAnswerText causes TS2304).
old_answer = re.search(
    r'const answerTexts = \(\s*\n\s*params\.assistantTexts\.length\s*\n\s*\? params\.assistantTexts\s*\n\s*: fallbackAnswerText\s*\n\s*\? \[fallbackAnswerText\]\s*\n\s*: \[\]\s*\n\s*\)\.filter',
    content,
)
if old_answer:
    # Remove const fallbackAnswerText only when we can also replace the answerTexts block
    fallback_line = re.search(
        r'\n\s*const fallbackAnswerText = params\.lastAssistant \? extractAssistantText\(params\.lastAssistant\) : "";',
        content,
    )
    if fallback_line:
        content = content.replace(fallback_line.group(0), '', 1)
        changes += 1
    content = content.replace(
        old_answer.group(0),
        'const answerTexts = selectAssistantAnswerTexts(params).filter',
        1,
    )
    changes += 1

# 4a. Add selectAssistantAnswerTexts function before buildEmbeddedRunPayloads
build_fn = 'export function buildEmbeddedRunPayloads(params: {'
if build_fn in content:
    new_fn = '''export function selectAssistantAnswerTexts(params: {
  aborted?: boolean;
  assistantTexts: string[];
  lastAssistant: AssistantMessage | undefined;
}): string[] {
  if (params.aborted) {
    return [];
  }
  const fallbackAnswerText = params.lastAssistant ? extractAssistantText(params.lastAssistant) : "";
  return params.assistantTexts.length
    ? params.assistantTexts
    : fallbackAnswerText
      ? [fallbackAnswerText]
      : [];
}

'''
    content = content.replace(build_fn, new_fn + build_fn, 1)
    changes += 1

# 4b. Add `aborted?: boolean;` to buildEmbeddedRunPayloads params
old_params = 'export function buildEmbeddedRunPayloads(params: {\n  assistantTexts: string[];'
if 'aborted?: boolean;' not in content.split('buildEmbeddedRunPayloads')[1][:200]:
    new_params = 'export function buildEmbeddedRunPayloads(params: {\n  aborted?: boolean;\n  assistantTexts: string[];'
    content = content.replace(old_params, new_params, 1)
    changes += 1

if changes > 0:
    with open(sys.argv[1], "w") as f:
        f.write(content)
    print(f"OK: #39117 payloads.ts — {changes} changes applied")
else:
    print("WARN: #39117 payloads.ts — no changes applied (patterns may differ)")
PYEOF
    APPLIED=$((APPLIED + 1))
  fi
fi

# ═══════════════════════════════════════════════════════════
# 5. run.ts — pass aborted flag to buildEmbeddedRunPayloads
# ═══════════════════════════════════════════════════════════
RUN_FILE="src/agents/pi-embedded-runner/run.ts"
if check_file "$RUN_FILE"; then
  if grep -q 'aborted: attempt.aborted' "$RUN_FILE" 2>/dev/null; then
    echo "SKIP: #39117 run.ts already patched"
    APPLIED=$((APPLIED + 1))
  else
    python3 - "$RUN_FILE" << 'PYEOF'
import sys

with open(sys.argv[1], "r") as f:
    content = f.read()

# Add aborted field to buildEmbeddedRunPayloads call
old_call = "const payloads = buildEmbeddedRunPayloads({\n            assistantTexts: attempt.assistantTexts,"
new_call = "const payloads = buildEmbeddedRunPayloads({\n            aborted: attempt.aborted,\n            assistantTexts: attempt.assistantTexts,"

if old_call in content:
    content = content.replace(old_call, new_call, 1)
    with open(sys.argv[1], "w") as f:
        f.write(content)
    print("OK: #39117 run.ts — added aborted flag to buildEmbeddedRunPayloads call")
else:
    print("WARN: #39117 run.ts — buildEmbeddedRunPayloads call pattern not found")
PYEOF
    APPLIED=$((APPLIED + 1))
  fi
fi

# ═══════════════════════════════════════════════════════════
# 6. queue-policy.ts — add buildQueuedBusyReceipt
# ═══════════════════════════════════════════════════════════
if check_file "$QUEUE_POLICY_FILE"; then
  if grep -q 'buildQueuedBusyReceipt' "$QUEUE_POLICY_FILE" 2>/dev/null; then
    echo "SKIP: #39117 queue-policy.ts already patched"
    APPLIED=$((APPLIED + 1))
  else
    cat >> "$QUEUE_POLICY_FILE" << 'APPEND_EOF'

export function buildQueuedBusyReceipt(params: { depth?: number }) {
  const queuedAhead = Math.max(0, Math.floor((params.depth ?? 1) - 1));
  const queueHint = queuedAhead > 0 ? ` (${queuedAhead} ahead)` : "";
  return {
    text: `⏳ Still finishing the previous run — this message is queued${queueHint} and I'll follow up shortly.`,
  };
}
APPEND_EOF
    echo "OK: #39117 queue-policy.ts — added buildQueuedBusyReceipt"
    APPLIED=$((APPLIED + 1))
  fi
fi

# ═══════════════════════════════════════════════════════════
# 7. agent-runner.ts — return busy receipt on enqueue
# ═══════════════════════════════════════════════════════════
if check_file "$AGENT_RUNNER_FILE"; then
  if grep -q 'buildQueuedBusyReceipt' "$AGENT_RUNNER_FILE" 2>/dev/null; then
    echo "SKIP: #39117 agent-runner.ts already patched"
    APPLIED=$((APPLIED + 1))
  else
    python3 - "$AGENT_RUNNER_FILE" << 'PYEOF'
import sys, re

with open(sys.argv[1], "r") as f:
    content = f.read()

changes = 0

# 7a. Add imports: buildQueuedBusyReceipt, getFollowupQueueDepth
# Update queue-policy import
qp_import = re.search(
    r'import \{([^}]*?)resolveActiveRunQueueAction([^}]*?)\} from ["\']\.\/queue-policy\.js["\'];',
    content,
    re.DOTALL,
)
if qp_import and 'buildQueuedBusyReceipt' not in qp_import.group(0):
    old_imp = qp_import.group(0)
    new_imp = old_imp.replace(
        'resolveActiveRunQueueAction',
        'buildQueuedBusyReceipt, resolveActiveRunQueueAction',
    )
    content = content.replace(old_imp, new_imp, 1)
    changes += 1

# Update queue import to add getFollowupQueueDepth
q_import = re.search(
    r'import \{([^}]*?)enqueueFollowupRun([^}]*?)\} from ["\']\.\/queue\.js["\'];',
    content,
    re.DOTALL,
)
if q_import and 'getFollowupQueueDepth' not in q_import.group(0):
    old_imp = q_import.group(0)
    new_imp = old_imp.replace(
        'enqueueFollowupRun',
        'enqueueFollowupRun,\n  getFollowupQueueDepth',
    )
    content = content.replace(old_imp, new_imp, 1)
    changes += 1

# 7b. Update the enqueue-followup block to return busy receipt
old_enqueue = re.search(
    r'if \(activeRunQueueAction === "enqueue-followup"\) \{\s*\n\s*enqueueFollowupRun\(queueKey, followupRun, resolvedQueue\);\s*\n\s*await touchActiveSessionEntry\(\);\s*\n\s*typing\.cleanup\(\);\s*\n\s*return undefined;',
    content,
)
if old_enqueue:
    new_enqueue = '''if (activeRunQueueAction === "enqueue-followup") {
    const enqueued = enqueueFollowupRun(queueKey, followupRun, resolvedQueue);
    await touchActiveSessionEntry();
    typing.cleanup();
    if (enqueued && !isHeartbeat) {
      return buildQueuedBusyReceipt({
        depth: getFollowupQueueDepth(queueKey),
      });
    }
    return undefined;'''
    content = content.replace(old_enqueue.group(0), new_enqueue, 1)
    changes += 1

if changes > 0:
    with open(sys.argv[1], "w") as f:
        f.write(content)
    print(f"OK: #39117 agent-runner.ts — {changes} changes applied")
else:
    print("WARN: #39117 agent-runner.ts — no changes applied")
PYEOF
    APPLIED=$((APPLIED + 1))
  fi
fi

# ═══════════════════════════════════════════════════════════
# 8. Session types — add reset audit fields
# ═══════════════════════════════════════════════════════════
if check_file "$SESSION_TYPES_FILE"; then
  if grep -q 'lastResetAt' "$SESSION_TYPES_FILE" 2>/dev/null; then
    echo "SKIP: #39117 session types already patched"
    APPLIED=$((APPLIED + 1))
  else
    python3 - "$SESSION_TYPES_FILE" << 'PYEOF'
import sys

with open(sys.argv[1], "r") as f:
    content = f.read()

# Add reset audit fields after abortedLastRun
anchor = "abortedLastRun?: boolean;"
if anchor in content:
    new_fields = '''abortedLastRun?: boolean;
  lastResetAt?: number;
  lastResetMode?: "new" | "reset";
  lastResetSource?: string;
  lastResetBy?: string;
  lastResetReason?: string;
  lastResetRunId?: string;'''
    content = content.replace(anchor, new_fields, 1)
    with open(sys.argv[1], "w") as f:
        f.write(content)
    print("OK: #39117 session types — added reset audit fields")
else:
    print("WARN: #39117 session types — abortedLastRun anchor not found")
PYEOF
    APPLIED=$((APPLIED + 1))
  fi
fi

# ═══════════════════════════════════════════════════════════
# 9. Session schema + handler — reset audit metadata
# ═══════════════════════════════════════════════════════════
if check_file "$SESSION_SCHEMA_FILE"; then
  if grep -q 'triggerSource' "$SESSION_SCHEMA_FILE" 2>/dev/null; then
    echo "SKIP: #39117 session schema already patched"
  else
    python3 - "$SESSION_SCHEMA_FILE" << 'PYEOF'
import sys, re

with open(sys.argv[1], "r") as f:
    content = f.read()

# Add trigger fields to SessionsResetParamsSchema
anchor = re.search(
    r'(reason: Type\.Optional\(Type\.Union\(\[Type\.Literal\("new"\), Type\.Literal\("reset"\)\]\)\),?\s*\n\s*\})',
    content,
)
if anchor:
    old = anchor.group(0)
    new = old.replace(
        '}',
        '    triggerSource: Type.Optional(NonEmptyString),\n    triggeredBy: Type.Optional(NonEmptyString),\n    triggerReason: Type.Optional(NonEmptyString),\n    triggerRunId: Type.Optional(NonEmptyString),\n  }',
    )
    content = content.replace(old, new, 1)
    with open(sys.argv[1], "w") as f:
        f.write(content)
    print("OK: #39117 session schema — added trigger fields")
else:
    print("WARN: #39117 session schema — reset params anchor not found")
PYEOF
  fi
fi

if check_file "$SESSION_HANDLER_FILE"; then
  if grep -q 'buildSessionResetAuditMetadata' "$SESSION_HANDLER_FILE" 2>/dev/null; then
    echo "SKIP: #39117 session handler already patched"
  else
    python3 - "$SESSION_HANDLER_FILE" << 'PYEOF'
import sys, re

with open(sys.argv[1], "r") as f:
    content = f.read()

changes = 0

# 9a. Add buildSessionResetAuditMetadata function before sessionsHandlers
handlers_anchor = "export const sessionsHandlers: GatewayRequestHandlers = {"
if handlers_anchor in content:
    audit_fn = '''export function buildSessionResetAuditMetadata(params: {
  reason?: "new" | "reset";
  triggerSource?: string;
  triggeredBy?: string;
  triggerReason?: string;
  triggerRunId?: string;
  lastResetAt?: number;
}) {
  const clean = (value: unknown): string | undefined => {
    if (typeof value !== "string") {
      return undefined;
    }
    const trimmed = value.trim();
    return trimmed ? trimmed : undefined;
  };
  const mode = params.reason === "new" ? "new" : "reset";
  const source = clean(params.triggerSource) ?? "gateway:sessions.reset";
  const triggeredBy = clean(params.triggeredBy) ?? source;
  const triggerReason =
    clean(params.triggerReason) ?? (mode === "new" ? "new-session" : "manual-reset");
  const triggerRunId = clean(params.triggerRunId);
  const lastResetAt =
    typeof params.lastResetAt === "number" && Number.isFinite(params.lastResetAt)
      ? params.lastResetAt
      : Date.now();
  return {
    lastResetAt,
    lastResetMode: mode,
    lastResetSource: source,
    lastResetBy: triggeredBy,
    lastResetReason: triggerReason,
    ...(triggerRunId ? { lastResetRunId: triggerRunId } : {}),
  } as const;
}

'''
    content = content.replace(handlers_anchor, audit_fn + handlers_anchor, 1)
    changes += 1

# 9b. In sessions.reset handler, add resetAudit computation and spread into entry
# Find the commandReason line and add resetAudit after it
cmd_reason = re.search(
    r'const commandReason = p\.reason === "new" \? "new" : "reset";',
    content,
)
if cmd_reason:
    content = content.replace(
        cmd_reason.group(0),
        cmd_reason.group(0) + '\n    const resetAuditAt = Date.now();\n    const resetAudit = buildSessionResetAuditMetadata({ ...p, lastResetAt: resetAuditAt });',
        1,
    )
    changes += 1

# 9c. Spread resetAudit into the session entry object
# Find abortedLastRun: false in the reset handler and add ...resetAudit after
abort_line = re.search(
    r'(abortedLastRun: false,)',
    content,
)
if abort_line and '...resetAudit' not in content:
    content = content.replace(
        abort_line.group(0),
        abort_line.group(0) + '\n        ...resetAudit,',
        1,
    )
    changes += 1

if changes > 0:
    with open(sys.argv[1], "w") as f:
        f.write(content)
    print(f"OK: #39117 session handler — {changes} changes applied")
else:
    print("WARN: #39117 session handler — no changes applied")
PYEOF
  fi
  APPLIED=$((APPLIED + 1))
fi

# SESSION_SCHEMA_FILE was processed in the block above but not counted separately.
# The APPLIED counter covers both schema+handler as one logical section (section 9).

echo ""
echo "═══════════════════════════════════════"
echo "#39117 recover-busy-sessions: $APPLIED/$TOTAL components processed"
echo "═══════════════════════════════════════"
