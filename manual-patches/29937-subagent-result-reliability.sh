#!/usr/bin/env bash
# PR #29937 — fix: improve subagent result reliability
# 4 files: agents/subagent-announce.ts, auto-reply/reply/agent-runner-execution.ts,
#          gateway/server-methods/agent-job.ts, shared/chat-content.ts
# (tests skipped)
#
# Changes:
# 1. subagent-announce.ts: Add readAggregatedSubagentOutput for timeout/error recovery
# 2. agent-runner-execution.ts: Add CLI heartbeat timer, onError callback, terminal lifecycle
# 3. agent-job.ts: Convert absolute timeout to inactivity timer (reset on any lifecycle event)
# 4. chat-content.ts: Fall back to thinking blocks when text blocks are empty
set -euo pipefail
SRC="${1:-.}/src"

ANNOUNCE="$SRC/agents/subagent-announce.ts"
RUNNER="$SRC/auto-reply/reply/agent-runner-execution.ts"
JOB="$SRC/gateway/server-methods/agent-job.ts"
CONTENT="$SRC/shared/chat-content.ts"

# ── Idempotency ──
if grep -q 'readAggregatedSubagentOutput' "$ANNOUNCE" 2>/dev/null; then
  echo "    SKIP: #29937 already applied"
  exit 0
fi

# ── File checks ──
[ -f "$ANNOUNCE" ] || { echo "    FAIL: #29937 $ANNOUNCE not found"; exit 1; }
[ -f "$RUNNER" ] || { echo "    FAIL: #29937 $RUNNER not found"; exit 1; }
[ -f "$JOB" ] || { echo "    FAIL: #29937 $JOB not found"; exit 1; }
[ -f "$CONTENT" ] || { echo "    FAIL: #29937 $CONTENT not found"; exit 1; }

# ── 1. subagent-announce.ts: Add readAggregatedSubagentOutput ──
python3 - "$ANNOUNCE" << 'PYEOF'
import sys

path = sys.argv[1]
with open(path, 'r') as f:
    content = f.read()

# Part 1a: Add readAggregatedSubagentOutput after readLatestSubagentOutput
old_func = '''async function readLatestSubagentOutputWithRetry(params: {'''

aggregated_func = '''/**
 * Aggregate ALL assistant text from a subagent's session history.
 *
 * Unlike {@link readLatestSubagentOutput} which returns only the most recent
 * assistant message, this function collects text from every assistant turn in
 * chronological order.  This is used when a subagent times out or errors so
 * that intermediate findings accumulated over multiple tool-call rounds are
 * preserved instead of being silently lost.
 */
async function readAggregatedSubagentOutput(params: {
  sessionKey: string;
  maxChars?: number;
}): Promise<string | undefined> {
  const MAX_CHARS = params.maxChars ?? 32_000;
  const history = await callGateway<{ messages?: Array<unknown> }>({
    method: "chat.history",
    params: { sessionKey: params.sessionKey, limit: 200 },
  });
  const messages = Array.isArray(history?.messages) ? history.messages : [];

  const chunks: string[] = [];
  let totalLength = 0;

  for (const msg of messages) {
    if (!msg || typeof msg !== "object") {
      continue;
    }
    if ((msg as { role?: unknown }).role !== "assistant") {
      continue;
    }
    const text = extractSubagentOutputText(msg);
    if (!text?.trim()) {
      continue;
    }
    const trimmed = text.trim();
    if (totalLength + trimmed.length > MAX_CHARS) {
      const remaining = MAX_CHARS - totalLength;
      if (remaining > 100) {
        chunks.push(trimmed.slice(0, remaining) + "\\n[...truncated]");
      }
      break;
    }
    chunks.push(trimmed);
    totalLength += trimmed.length;
  }

  if (chunks.length === 0) {
    return undefined;
  }
  if (chunks.length === 1) {
    return chunks[0];
  }
  return chunks.join("\\n\\n");
}

async function readAggregatedSubagentOutputWithRetry(params: {
  sessionKey: string;
  maxWaitMs: number;
  maxChars?: number;
}): Promise<string | undefined> {
  const RETRY_INTERVAL_MS = FAST_TEST_MODE ? FAST_TEST_RETRY_INTERVAL_MS : 100;
  const deadline = Date.now() + Math.max(0, Math.min(params.maxWaitMs, 15_000));
  let result: string | undefined;
  while (Date.now() < deadline) {
    result = await readAggregatedSubagentOutput({
      sessionKey: params.sessionKey,
      maxChars: params.maxChars,
    });
    if (result?.trim()) {
      return result;
    }
    await new Promise((resolve) => setTimeout(resolve, RETRY_INTERVAL_MS));
  }
  return result;
}

async function readLatestSubagentOutputWithRetry(params: {'''

if old_func not in content:
    print("    FAIL: #29937 cannot find readLatestSubagentOutputWithRetry", file=sys.stderr)
    sys.exit(1)

content = content.replace(old_func, aggregated_func, 1)

# Part 1b: Replace the reply fallback section to use aggregated output on timeout/error
# Target: the section where reply is read after childCompletionFindings check
old_reply = '''      if (!reply) {
        reply = await readLatestSubagentOutput(params.childSessionKey);
      }

      if (!reply?.trim()) {
        reply = await readLatestSubagentOutputWithRetry({
          sessionKey: params.childSessionKey,
          maxWaitMs: params.timeoutMs,
        });
      }'''

new_reply = '''      if (!reply) {
        if (outcome?.status === "timeout" || outcome?.status === "error") {
          reply = await readAggregatedSubagentOutput({
            sessionKey: params.childSessionKey,
          });
        } else {
          reply = await readLatestSubagentOutput(params.childSessionKey);
        }
      }

      if (!reply?.trim()) {
        if (outcome?.status === "timeout" || outcome?.status === "error") {
          reply = await readAggregatedSubagentOutputWithRetry({
            sessionKey: params.childSessionKey,
            maxWaitMs: params.timeoutMs,
          });
        } else {
          reply = await readLatestSubagentOutputWithRetry({
            sessionKey: params.childSessionKey,
            maxWaitMs: params.timeoutMs,
          });
        }
      }'''

if old_reply not in content:
    print("    FAIL: #29937 cannot find reply fallback section", file=sys.stderr)
    sys.exit(1)

content = content.replace(old_reply, new_reply, 1)

with open(path, 'w') as f:
    f.write(content)
print("    OK: #29937 subagent-announce.ts — readAggregatedSubagentOutput added")
PYEOF

# ── 2. agent-runner-execution.ts: CLI heartbeat + onError + terminal lifecycle ──
python3 - "$RUNNER" << 'PYEOF'
import sys

path = sys.argv[1]
with open(path, 'r') as f:
    content = f.read()

# Part 2a: Replace lifecycleTerminalEmitted pattern with heartbeat timer
old_cli = '''            return (async () => {
              let lifecycleTerminalEmitted = false;
              try {'''

new_cli = '''            return (async () => {
              // Emit periodic heartbeats during CLI execution so the parent's
              // inactivity timer (waitForAgentJob) stays alive.  CLI backends
              // produce no streaming output — without heartbeats, long runs
              // (e.g. 100s+ with reasoning models) would silently timeout.
              const CLI_HEARTBEAT_INTERVAL_MS = 30_000;
              const heartbeatTimer = setInterval(() => {
                emitAgentEvent({
                  runId,
                  stream: "lifecycle",
                  data: {
                    phase: "info",
                    message: `CLI execution in progress (${provider}/${model})`,
                  },
                });
              }, CLI_HEARTBEAT_INTERVAL_MS);
              try {'''

if old_cli not in content:
    print("    FAIL: #29937 cannot find lifecycleTerminalEmitted block", file=sys.stderr)
    sys.exit(1)

content = content.replace(old_cli, new_cli, 1)

# Part 2b: Remove the lifecycleTerminalEmitted = true after end event
old_end = '''                lifecycleTerminalEmitted = true;

                return result;
              } catch (err) {
                emitAgentEvent({
                  runId,
                  stream: "lifecycle",
                  data: {
                    phase: "error",
                    startedAt,
                    endedAt: Date.now(),
                    error: String(err),
                  },
                });
                lifecycleTerminalEmitted = true;
                throw err;
              } finally {
                // Defensive backstop: never let a CLI run complete without a terminal
                // lifecycle event, otherwise downstream consumers can hang.
                if (!lifecycleTerminalEmitted) {
                  emitAgentEvent({
                    runId,
                    stream: "lifecycle",
                    data: {
                      phase: "error",
                      startedAt,
                      endedAt: Date.now(),
                      error: "CLI run completed without lifecycle terminal event",
                    },
                  });
                }
              }'''

new_end = '''
                return result;
              } finally {
                // Don't emit lifecycle "error" for individual model failures —
                // model fallback will try the next candidate; only the final
                // outcome (success or all-models-exhausted) should be a terminal
                // lifecycle event.  The outer fallback error handler covers that.
                clearInterval(heartbeatTimer);
              }'''

if old_end not in content:
    print("    FAIL: #29937 cannot find lifecycleTerminalEmitted catch/finally block", file=sys.stderr)
    sys.exit(1)

content = content.replace(old_end, new_end, 1)

# Part 2c: Add onError callback before the closing }); of runWithModelFallback
old_close = '''      });
      runResult = fallbackResult.result;
      fallbackProvider = fallbackResult.provider;'''

new_close = '''        onError: async ({ provider: errProvider, model: errModel, attempt, total }) => {
          // Emit an "info" lifecycle event so downstream consumers can
          // observe fallback transitions.  "info" is ignored by
          // waitForAgentJob's terminal-phase logic (it only acts on
          // start/end/error), but it IS used to reset the inactivity
          // timer (see activity-aware timer in agent-job.ts).
          emitAgentEvent({
            runId,
            stream: "lifecycle",
            data: {
              phase: "info",
              message: `Model ${errProvider}/${errModel} failed (attempt ${attempt}/${total}), switching to next fallback`,
            },
          });
        },
      });
      runResult = fallbackResult.result;
      fallbackProvider = fallbackResult.provider;'''

if old_close not in content:
    print("    FAIL: #29937 cannot find runWithModelFallback closing", file=sys.stderr)
    sys.exit(1)

content = content.replace(old_close, new_close, 1)

# Part 2d: Add terminal lifecycle error event after "Embedded agent failed before reply"
old_err = '''      defaultRuntime.error(`Embedded agent failed before reply: ${message}`);
      const safeMessage = isTransientHttp'''

new_err = '''      defaultRuntime.error(`Embedded agent failed before reply: ${message}`);

      // Emit terminal lifecycle error for the entire fallback chain.
      // Individual model errors were intentionally suppressed in the CLI
      // run callback (see above) so they don't trigger premature failure
      // in waitForAgentJob.  This is the single authoritative "error"
      // lifecycle event for this agent run.
      emitAgentEvent({
        runId,
        stream: "lifecycle",
        data: {
          phase: "error",
          endedAt: Date.now(),
          error: message,
        },
      });

      const safeMessage = isTransientHttp'''

if old_err not in content:
    print("    FAIL: #29937 cannot find 'Embedded agent failed' block", file=sys.stderr)
    sys.exit(1)

content = content.replace(old_err, new_err, 1)

with open(path, 'w') as f:
    f.write(content)
print("    OK: #29937 agent-runner-execution.ts — heartbeat + onError + terminal lifecycle")
PYEOF

# ── 3. agent-job.ts: Convert absolute timeout to inactivity timer ──
python3 - "$JOB" << 'PYEOF'
import sys

path = sys.argv[1]
with open(path, 'r') as f:
    content = f.read()

# Move timerDelayMs + timer before the unsubscribe, and add reset logic
old_job = '''    const unsubscribe = onAgentEvent((evt) => {
      if (!evt || evt.stream !== "lifecycle") {
        return;
      }
      if (evt.runId !== runId) {
        return;
      }
      const phase = evt.data?.phase;'''

new_job = '''    const timerDelayMs = Math.max(1, Math.min(Math.floor(timeoutMs), 2_147_483_647));
    // Use an inactivity timer rather than an absolute deadline.  Any lifecycle
    // event (including "info" heartbeats) resets the timer, so the agent is
    // only considered timed-out after `timerDelayMs` of complete silence.
    let timer = setTimeout(() => finish(null), timerDelayMs);

    const unsubscribe = onAgentEvent((evt) => {
      if (!evt || evt.stream !== "lifecycle") {
        return;
      }
      if (evt.runId !== runId) {
        return;
      }

      // Any lifecycle activity for this run means the agent is still working.
      // Reset the inactivity timer to prevent premature timeout during model
      // fallback chains or long-running CLI operations.
      clearTimeout(timer);
      timer = setTimeout(() => finish(null), timerDelayMs);

      const phase = evt.data?.phase;'''

if old_job not in content:
    print("    FAIL: #29937 cannot find onAgentEvent block in agent-job.ts", file=sys.stderr)
    sys.exit(1)

content = content.replace(old_job, new_job, 1)

# Remove the old timer creation at the end
old_timer = '''    const timerDelayMs = Math.max(1, Math.min(Math.floor(timeoutMs), 2_147_483_647));
    const timer = setTimeout(() => finish(null), timerDelayMs);'''

if old_timer in content:
    content = content.replace(old_timer, '', 1)

with open(path, 'w') as f:
    f.write(content)
print("    OK: #29937 agent-job.ts — inactivity timer with reset")
PYEOF

# ── 4. chat-content.ts: Fall back to thinking blocks ──
python3 - "$CONTENT" << 'PYEOF'
import sys

path = sys.argv[1]
with open(path, 'r') as f:
    content = f.read()

old_chat = '''  const chunks: string[] = [];
  for (const block of content) {
    if (!block || typeof block !== "object") {
      continue;
    }
    if ((block as { type?: unknown }).type !== "text") {
      continue;
    }
    const text = (block as { text?: unknown }).text;
    if (typeof text !== "string") {
      continue;
    }
    const value = opts?.sanitizeText ? opts.sanitizeText(text) : text;
    if (value.trim()) {
      chunks.push(value);
    }
  }

  const joined = normalize(chunks.join(joinWith));
  return joined ? joined : null;'''

new_chat = '''  const chunks: string[] = [];
  const thinkingChunks: string[] = [];
  for (const block of content) {
    if (!block || typeof block !== "object") {
      continue;
    }
    const blockType = (block as { type?: unknown }).type;
    if (blockType === "text") {
      const text = (block as { text?: unknown }).text;
      if (typeof text !== "string") {
        continue;
      }
      const value = opts?.sanitizeText ? opts.sanitizeText(text) : text;
      if (value.trim()) {
        chunks.push(value);
      }
    } else if (blockType === "thinking") {
      const thinking = (block as { thinking?: unknown }).thinking;
      if (typeof thinking === "string") {
        const value = opts?.sanitizeText ? opts.sanitizeText(thinking) : thinking;
        if (value.trim()) {
          thinkingChunks.push(value);
        }
      }
    }
  }

  // Prefer text blocks; fall back to thinking blocks when text is empty
  // to avoid silently dropping content from models that place their
  // response in thinking blocks (e.g. extended-thinking / high-thinking modes).
  const source = chunks.length > 0 ? chunks : thinkingChunks;
  const joined = normalize(source.join(joinWith));
  return joined ? joined : null;'''

if old_chat not in content:
    print("    FAIL: #29937 cannot find extractTextFromChatContent body", file=sys.stderr)
    sys.exit(1)

content = content.replace(old_chat, new_chat, 1)

with open(path, 'w') as f:
    f.write(content)
print("    OK: #29937 chat-content.ts — thinking block fallback")
PYEOF

echo "    OK: #29937 subagent result reliability applied"
