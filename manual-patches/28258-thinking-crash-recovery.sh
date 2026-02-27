#!/usr/bin/env bash
# PR #28258 — fix: crash recovery for Anthropic thinking blocks
# Creates 2 new files + modifies pi-embedded-helpers.ts + attempt.ts
# DIKKATLI EKLE: attempt.ts hot zone (3+ patch hedefinde)
set -euo pipefail
cd "$1"

HELPERS="src/agents/pi-embedded-helpers.ts"
ANTHRO_HELPERS="src/agents/pi-embedded-helpers/anthropic.ts"
ANTHRO_RUNNER="src/agents/pi-embedded-runner/anthropic.ts"
ATTEMPT="src/agents/pi-embedded-runner/run/attempt.ts"

if ! [ -d "src/agents/pi-embedded-runner/run" ]; then
  echo "ERROR: src/agents/pi-embedded-runner/run not found"
  exit 1
fi
if grep -q 'sanitizeThinkingForRecovery' "$ATTEMPT" 2>/dev/null; then
  echo "SKIP: #28258 already applied"
  exit 0
fi

# Step 1: Add exports to pi-embedded-helpers.ts
python3 - "$HELPERS" << 'PYEOF'
import sys
with open(sys.argv[1], "r") as f:
    content = f.read()
export_block = '\nexport {\n  assessLastAssistantMessage,\n  sanitizeThinkingForRecovery,\n} from "./pi-embedded-helpers/anthropic.js";\n'
if 'sanitizeThinkingForRecovery' not in content:
    content = content.rstrip() + export_block
    with open(sys.argv[1], "w") as f:
        f.write(content)
    print("  helpers.ts: exports added")
else:
    print("  helpers.ts: already has export")
PYEOF

# Step 2: Create anthropic.ts in pi-embedded-helpers/
cat > "$ANTHRO_HELPERS" << 'TSEOF'
import type { AgentMessage } from "@mariozechner/pi-agent-core";

interface ContentBlock {
  type: string;
  thinking?: string;
  text?: string;
  signature?: string;
  [key: string]: unknown;
}

export function assessLastAssistantMessage(
  msg: AgentMessage,
): "valid" | "incomplete-thinking" | "incomplete-text" {
  if (msg.role !== "assistant") return "valid";
  if (typeof msg.content === "string") return "valid";
  if (!Array.isArray(msg.content) || msg.content.length === 0) return "incomplete-thinking";

  const blocks = msg.content as ContentBlock[];
  let hasSignedThinking = false;
  let hasUnsignedThinking = false;
  let hasNonThinkingContent = false;
  let textBlockIsEmpty = false;

  for (const block of blocks) {
    if (!block || typeof block !== "object" || !block.type) return "incomplete-thinking";
    if (block.type === "thinking" || block.type === "redacted_thinking") {
      if (block.type === "thinking" && !block.signature) hasUnsignedThinking = true;
      else hasSignedThinking = true;
    } else {
      hasNonThinkingContent = true;
      if (block.type === "text" && (!block.text || block.text.trim() === "")) textBlockIsEmpty = true;
    }
  }

  if (hasUnsignedThinking) return "incomplete-thinking";
  if (hasSignedThinking && !hasNonThinkingContent) return "incomplete-text";
  if (hasSignedThinking && textBlockIsEmpty) return "incomplete-text";
  return "valid";
}

export function sanitizeThinkingForRecovery(messages: AgentMessage[]): {
  messages: AgentMessage[];
  prefill: boolean;
} {
  if (!messages || messages.length === 0) return { messages, prefill: false };

  let lastAssistantIdx = -1;
  for (let i = messages.length - 1; i >= 0; i--) {
    if (messages[i].role === "assistant") { lastAssistantIdx = i; break; }
  }
  if (lastAssistantIdx === -1) return { messages, prefill: false };

  const assessment = assessLastAssistantMessage(messages[lastAssistantIdx]);
  switch (assessment) {
    case "valid": return { messages, prefill: false };
    case "incomplete-thinking":
      return {
        messages: [...messages.slice(0, lastAssistantIdx), ...messages.slice(lastAssistantIdx + 1)],
        prefill: false,
      };
    case "incomplete-text":
      return { messages, prefill: true };
  }
}
TSEOF
echo "  anthropic-helpers.ts: created"

# Step 3: Create anthropic.ts in pi-embedded-runner/
cat > "$ANTHRO_RUNNER" << 'TSEOF'
import type { StreamFn } from "@mariozechner/pi-agent-core";

const THINKING_BLOCK_ERROR_PATTERN = /thinking or redacted_thinking blocks?.* cannot be modified/i;

export function wrapAnthropicStreamWithRecovery(
  innerStreamFn: StreamFn,
  sessionMeta: { id: string; recovered?: boolean },
): StreamFn {
  const wrapped: StreamFn = (model, context, options) => {
    const ctx = context as unknown as Record<string, unknown> | undefined;
    const attemptStream = () => innerStreamFn(model, context, options);
    const retryWithCleanedContext = () => {
      const cleaned = stripAllThinkingBlocks(ctx);
      const newContext = { ...ctx, messages: cleaned } as unknown as typeof context;
      return innerStreamFn(model, newContext, options);
    };

    const streamOrPromise = attemptStream();
    if (streamOrPromise instanceof Promise) {
      return streamOrPromise.catch((err: unknown) => {
        if (shouldRecover(err, sessionMeta)) {
          sessionMeta.recovered = true;
          return retryWithCleanedContext();
        }
        throw err;
      }) as unknown as ReturnType<StreamFn>;
    }
    return wrapAsyncIterableWithRecovery(
      streamOrPromise, sessionMeta, retryWithCleanedContext,
    ) as unknown as ReturnType<StreamFn>;
  };
  return wrapped;
}

function shouldRecover(err: unknown, meta: { id: string; recovered?: boolean }): boolean {
  const msg = err instanceof Error ? err.message : String(err);
  if (!THINKING_BLOCK_ERROR_PATTERN.test(msg)) return false;
  if (meta.recovered) {
    console.error(`[session-recovery] Session ${meta.id}: thinking block error persists. Not retrying.`);
    return false;
  }
  console.warn(`[session-recovery] Session ${meta.id}: thinking block error. Stripping ALL thinking blocks, retrying once.`);
  return true;
}

interface ContentBlock { type?: string; [key: string]: unknown; }

function stripAllThinkingBlocks(ctx: Record<string, unknown> | undefined): unknown[] {
  const messages = Array.isArray(ctx?.messages) ? ctx.messages : [];
  return messages.map((msg: unknown) => {
    const m = msg as { role?: string; content?: unknown };
    if (m.role !== "assistant" || !Array.isArray(m.content)) return msg;
    const stripped = (m.content as ContentBlock[]).filter(
      (b) => b?.type !== "thinking" && b?.type !== "redacted_thinking",
    );
    return stripped.length === 0 ? { ...m, content: [{ type: "text", text: "" }] } : { ...m, content: stripped };
  });
}

async function* wrapAsyncIterableWithRecovery(
  stream: ReturnType<StreamFn>,
  meta: { id: string; recovered?: boolean },
  retryFn: () => ReturnType<StreamFn>,
): AsyncGenerator {
  try {
    const resolved = stream instanceof Promise ? await stream : stream;
    for await (const chunk of resolved as AsyncIterable<unknown>) yield chunk;
  } catch (err: unknown) {
    if (shouldRecover(err, meta)) {
      meta.recovered = true;
      const retry = retryFn();
      const resolved = retry instanceof Promise ? await retry : retry;
      for await (const chunk of resolved as AsyncIterable<unknown>) yield chunk;
      return;
    }
    throw err;
  }
}
TSEOF
echo "  anthropic-runner.ts: created"

# Step 4: Modify attempt.ts — add imports + recovery logic
python3 - "$ATTEMPT" << 'PYEOF'
import sys
with open(sys.argv[1], "r") as f:
    content = f.read()

# 4a: Add sanitizeThinkingForRecovery to helpers import
old_imp = '  validateGeminiTurns,\n} from "../../pi-embedded-helpers.js";'
new_imp = '  validateGeminiTurns,\n  sanitizeThinkingForRecovery,\n} from "../../pi-embedded-helpers.js";'
if old_imp not in content:
    print("ERROR: validateGeminiTurns import not found"); sys.exit(1)
content = content.replace(old_imp, new_imp, 1)

# 4b: Add wrapAnthropicStreamWithRecovery import
old_abort = 'import { isRunnerAbortError } from "../abort.js";'
new_abort = 'import { isRunnerAbortError } from "../abort.js";\nimport { wrapAnthropicStreamWithRecovery } from "../anthropic.js";'
if old_abort not in content:
    print("ERROR: isRunnerAbortError import not found"); sys.exit(1)
content = content.replace(old_abort, new_abort, 1)

# 4c: Wrap stream before anthropicPayloadLogger
old_log = '      if (anthropicPayloadLogger) {\n        activeSession.agent.streamFn = anthropicPayloadLogger.wrapStreamFn('
new_log = '      if (params.provider === "anthropic") {\n        activeSession.agent.streamFn = wrapAnthropicStreamWithRecovery(\n          activeSession.agent.streamFn,\n          { id: activeSession.sessionId },\n        );\n      }\n      if (anthropicPayloadLogger) {\n        activeSession.agent.streamFn = anthropicPayloadLogger.wrapStreamFn('
if old_log not in content:
    print("ERROR: anthropicPayloadLogger block not found"); sys.exit(1)
content = content.replace(old_log, new_log, 1)

# 4d: Add sanitize call before sanitizeSessionHistory
old_san = '        const prior = await sanitizeSessionHistory({'
new_san = '''        if (params.provider === "anthropic") {
          const originalMessageCount = activeSession.messages.length;
          const { messages, prefill } = sanitizeThinkingForRecovery(activeSession.messages);
          if (messages !== activeSession.messages) {
            activeSession.agent.replaceMessages(messages);
          }
          if (messages.length !== originalMessageCount) {
            log.warn(
              `[session-recovery] Dropped last assistant message with incomplete thinking: sessionId=${params.sessionId}`,
            );
          }
          if (prefill) {
            log.warn(
              `[session-recovery] Last assistant message has signed thinking but incomplete text; retaining for recovery: sessionId=${params.sessionId}`,
            );
          }
        }

        const prior = await sanitizeSessionHistory({'''
if old_san not in content:
    print("ERROR: sanitizeSessionHistory not found"); sys.exit(1)
content = content.replace(old_san, new_san, 1)

with open(sys.argv[1], "w") as f:
    f.write(content)
print("  attempt.ts: 4 modifications applied")
PYEOF

echo "OK: #28258 applied — Anthropic thinking blocks crash recovery"
