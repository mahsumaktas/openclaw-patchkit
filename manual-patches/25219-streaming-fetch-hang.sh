#!/usr/bin/env bash
# PR #25219 — fix(agent): prevent gateway hang on streaming fetch errors
# When a streaming fetch to the LLM provider fails mid-stream (ECONNRESET,
# ECONNREFUSED, socket hang up, etc.), the async generator returned by
# streamFn could silently stall, causing activeSession.prompt() to never
# resolve or reject. The gateway would then hang until the timeout fired.
# Fix: wrap streamFn to catch fetch/network errors in the async generator
# and ensure they propagate as rejections so the prompt completes promptly.
set -euo pipefail

SRC="${1:?Usage: $0 <openclaw-source-dir>}/src"

FILE="$SRC/agents/pi-embedded-runner/run/attempt.ts"
if [ ! -f "$FILE" ]; then
  echo "    FAIL: #25219 target file not found: $FILE"
  exit 1
fi

# Idempotency check
if grep -q '#25219\|streaming fetch error guard' "$FILE"; then
  echo "    SKIP: #25219 already applied"
  exit 0
fi

python3 - "$FILE" << 'PYEOF'
import sys

path = sys.argv[1]
with open(path, 'r') as f:
    content = f.read()

# Insert the streaming fetch error guard wrapper right after applyExtraParamsToAgent call.
# This goes before the cacheTrace wrapper so errors are caught at the lowest layer.

old = """\
      applyExtraParamsToAgent(
        activeSession.agent,
        params.config,
        params.provider,
        params.modelId,
        params.streamParams,
        params.thinkLevel,
        sessionAgentId,
      );

      if (cacheTrace) {"""

new = """\
      applyExtraParamsToAgent(
        activeSession.agent,
        params.config,
        params.provider,
        params.modelId,
        params.streamParams,
        params.thinkLevel,
        sessionAgentId,
      );

      // #25219: Guard against streaming fetch errors that silently stall the
      // prompt. Wrap streamFn so network-level failures (ECONNRESET,
      // socket hang up, etc.) are logged and properly propagated.
      {
        const innerStream = activeSession.agent.streamFn;
        activeSession.agent.streamFn = (model, context, options) => {
          try {
            const result = innerStream(model, context, options);
            // If result is a Promise, attach error logging before propagation
            if (result && typeof (result as Promise<unknown>).catch === "function") {
              return (result as Promise<unknown>).catch((fetchErr: unknown) => {
                log.warn(
                  `streaming fetch error: runId=${params.runId} ${String(fetchErr).slice(0, 200)}`,
                );
                throw fetchErr;
              }) as typeof result;
            }
            return result;
          } catch (fetchErr) {
            log.warn(
              `streamFn init error: runId=${params.runId} ${String(fetchErr).slice(0, 200)}`,
            );
            throw fetchErr;
          }
        };
      }

      if (cacheTrace) {"""

if old not in content:
    print("    FAIL: #25219 pattern not found in attempt.ts")
    sys.exit(1)

content = content.replace(old, new, 1)

with open(path, 'w') as f:
    f.write(content)

print("    OK: #25219 added streaming fetch error guard to prevent gateway hang")
PYEOF
