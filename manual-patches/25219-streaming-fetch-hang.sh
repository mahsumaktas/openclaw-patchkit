#!/usr/bin/env bash
# PR #25219 — fix(agent): prevent gateway hang on streaming fetch errors
# When a streaming fetch to the LLM provider fails mid-stream (ECONNRESET,
# socket hang up, etc.), the async generator can silently stall, causing
# prompt() to never resolve. The gateway then hangs until timeout.
#
# Fix has two parts:
#   1. attempt.ts: Register an unhandled rejection handler during prompt() to
#      catch leaked streaming fetch errors, capture them, and force-abort the run.
#      Also replace the generic AbortError with the real streaming error.
#   2. run.ts: Process prompt errors even when abort was triggered by a captured
#      streaming rejection (isStreamingAbort logic).
#
# v2026.3.13 fix: The old script tried to match applyExtraParamsToAgent with
# specific params (params.streamParams, params.thinkLevel, sessionAgentId).
# In v2026.3.13, the signature changed: streamParams is now
# { ...params.streamParams, fastMode: params.fastMode }.
# New approach: match the prompt() call site directly instead.
set -euo pipefail

SRC="${1:-.}/src"

ATTEMPT="$SRC/agents/pi-embedded-runner/run/attempt.ts"
RUN="$SRC/agents/pi-embedded-runner/run.ts"

for f in "$ATTEMPT" "$RUN"; do
  if [ ! -f "$f" ]; then
    echo "    FAIL: #25219 target file not found: $f"
    exit 1
  fi
done

# Idempotency check
if grep -q 'streamingErrorRef\|#24622\|streaming fetch error guard' "$ATTEMPT"; then
  echo "    SKIP: #25219 already applied"
  exit 0
fi

# -- 1. Patch attempt.ts --
python3 - "$ATTEMPT" << 'PYEOF'
import sys

path = sys.argv[1]
with open(path, 'r') as f:
    content = f.read()

# 1a. Add registerUnhandledRejectionHandler import
# Find the existing imports from unhandled-rejections or nearby infra imports
import_anchor = 'import { MAX_IMAGE_BYTES } from "../../../media/constants.js";'
if import_anchor not in content:
    # Fallback: look for any media/constants import
    import re
    m = re.search(r'import \{[^}]*MAX_IMAGE_BYTES[^}]*\} from "[^"]*media/constants[^"]*";', content)
    if m:
        import_anchor = m.group(0)
    else:
        print("    FAIL: #25219 cannot find MAX_IMAGE_BYTES import anchor")
        sys.exit(1)

if 'registerUnhandledRejectionHandler' not in content:
    new_import = 'import { registerUnhandledRejectionHandler } from "../../../infra/unhandled-rejections.js";\n'
    content = content.replace(import_anchor, new_import + import_anchor, 1)
    print("    OK: #25219 added registerUnhandledRejectionHandler import")

# 1b. Add streamingErrorRef declaration before the try block
# Find: let promptError: unknown = null;
#        let promptErrorSource: ...
#        ...
#        try {
# Insert streamingErrorRef after promptErrorSource

old_prompt_vars = '''      let promptError: unknown = null;
      let promptErrorSource: "prompt" | "compaction" | null = null;'''

new_prompt_vars = '''      let promptError: unknown = null;
      let promptErrorSource: "prompt" | "compaction" | null = null;

      // FIX(#24622): Mutable ref to capture streaming errors from the
      // unhandled rejection handler so they survive into the catch block.
      // Must be declared outside the try so it is visible in catch.
      const streamingErrorRef: { error?: Error } = {};'''

if old_prompt_vars in content:
    content = content.replace(old_prompt_vars, new_prompt_vars, 1)
else:
    print("    FAIL: #25219 cannot find promptError/promptErrorSource declarations")
    sys.exit(1)

# 1c. Wrap the prompt() call with the rejection handler
# In v2026.3.13 the prompt call is:
#           if (imageResult.images.length > 0) {
#             await abortable(activeSession.prompt(effectivePrompt, { images: imageResult.images }));
#           } else {
#             await abortable(activeSession.prompt(effectivePrompt));
#           }
#         } catch (err) {

old_prompt = '''          // Only pass images option if there are actually images to pass
          // This avoids potential issues with models that don't expect the images parameter
          if (imageResult.images.length > 0) {
            await abortable(activeSession.prompt(effectivePrompt, { images: imageResult.images }));
          } else {
            await abortable(activeSession.prompt(effectivePrompt));
          }
        } catch (err) {'''

new_prompt = '''          // Only pass images option if there are actually images to pass
          // This avoids potential issues with models that don't expect the images parameter
          //
          // FIX(#24622): Register an unhandled rejection handler during the prompt
          // call to catch streaming fetch errors (e.g. TypeError: fetch failed from
          // billing/quota exhaustion). The pi-ai SDK's streaming implementation can
          // leak these as unhandled rejections instead of rejecting the prompt()
          // promise, causing the gateway to hang indefinitely. When we catch such
          // an error, we force-abort the run so the error surfaces properly
          // through the normal error handling path (failover, user message, etc.).
          let unregisterPromptRejectionHandler: (() => void) | undefined;
          try {
            unregisterPromptRejectionHandler = registerUnhandledRejectionHandler(
              (reason: unknown) => {
                // Only intercept errors that look like streaming fetch failures.
                const isFetchError =
                  reason instanceof TypeError && reason.message === "fetch failed";
                const isNetworkLike =
                  reason instanceof Error &&
                  /ECONNRESET|ECONNREFUSED|ENOTFOUND|ETIMEDOUT|socket hang up/i.test(
                    reason.message,
                  );
                if (!isFetchError && !isNetworkLike) {
                  return false;
                }
                log.warn(
                  `Captured unhandled streaming rejection during prompt, forcing abort: ` +
                    `runId=${params.runId} sessionId=${params.sessionId} error=${String(reason)}`,
                );
                streamingErrorRef.error =
                  reason instanceof Error ? reason : new Error(String(reason));
                abortRun(true, reason);
                return true;
              },
            );
          } catch {
            // Best-effort: if handler registration fails, proceed without it.
          }
          try {
            if (imageResult.images.length > 0) {
              await abortable(
                activeSession.prompt(effectivePrompt, { images: imageResult.images }),
              );
            } else {
              await abortable(activeSession.prompt(effectivePrompt));
            }
          } finally {
            unregisterPromptRejectionHandler?.();
          }
        } catch (err) {'''

if old_prompt in content:
    content = content.replace(old_prompt, new_prompt, 1)
else:
    print("    FAIL: #25219 cannot find prompt() call site in attempt.ts")
    sys.exit(1)

# 1d. Replace promptError = err with streamingErrorRef.error ?? err
# Find the catch block that sets promptError
old_catch = '''          } else {
            promptError = err;
            promptErrorSource = "prompt";
          }'''

new_catch = '''          } else {
            // FIX(#24622): When a streaming fetch error was captured via the
            // unhandled rejection handler, the abortable() wrapper produces a
            // generic AbortError/TimeoutError. Replace it with the original
            // streaming error so the outer run loop can classify it correctly
            // (e.g. as a billing error for proper failover).
            promptError = streamingErrorRef.error ?? err;
            promptErrorSource = "prompt";
          }'''

if old_catch in content:
    content = content.replace(old_catch, new_catch, 1)
else:
    print("    WARN: #25219 cannot find promptError = err catch block (may need manual review)")

with open(path, 'w') as f:
    f.write(content)
print("    OK: #25219 attempt.ts — streaming rejection handler + error capture applied")
PYEOF

# -- 2. Patch run.ts: isStreamingAbort logic --
python3 - "$RUN" << 'PYEOF'
import sys

path = sys.argv[1]
with open(path, 'r') as f:
    content = f.read()

# The run.ts change: replace `if (promptError && !aborted)` with
# isStreamingAbort detection
old_check = '          if (promptError && !aborted) {'
if old_check not in content:
    print("    FAIL: #25219 cannot find 'promptError && !aborted' in run.ts")
    sys.exit(1)

new_check = '''          // FIX(#24622): Also process prompt errors when the abort was triggered
          // by a captured streaming rejection (e.g. fetch failed from billing
          // error). In that case, promptError contains the original streaming
          // error (not a generic AbortError), and should go through the normal
          // failover classification path.
          const isStreamingAbort =
            aborted &&
            promptError instanceof Error &&
            promptError.name !== "AbortError" &&
            promptError.name !== "TimeoutError";
          if (promptError && (!aborted || isStreamingAbort)) {'''

content = content.replace(old_check, new_check, 1)

with open(path, 'w') as f:
    f.write(content)
print("    OK: #25219 run.ts — isStreamingAbort classification added")
PYEOF

echo "    OK: #25219 streaming fetch hang prevention fully applied"
