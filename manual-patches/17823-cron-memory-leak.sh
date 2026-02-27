#!/usr/bin/env bash
# PR #17823 — fix: memory leak in cron isolated runs — agent-events Maps never cleaned
# Two files: run.ts (import + withRunSession cleanup) + agent-events.ts (seqByRun.delete)
set -euo pipefail
cd "$1"

RUN_FILE="src/cron/isolated-agent/run.ts"
EVENTS_FILE="src/infra/agent-events.ts"

if ! [ -f "$RUN_FILE" ]; then echo "SKIP: $RUN_FILE not found"; exit 0; fi
if ! [ -f "$EVENTS_FILE" ]; then echo "SKIP: $EVENTS_FILE not found"; exit 0; fi
if grep -q 'clearAgentRunContext' "$RUN_FILE"; then echo "SKIP: #17823 already applied"; exit 0; fi

# Part 1: Update import + withRunSession in run.ts
python3 - "$RUN_FILE" << 'PYEOF'
import sys

with open(sys.argv[1], "r") as f:
    content = f.read()

old_import = 'import { registerAgentRunContext } from "../../infra/agent-events.js";'
new_import = 'import { clearAgentRunContext, registerAgentRunContext } from "../../infra/agent-events.js";'

if old_import not in content:
    print("ERROR: cannot find registerAgentRunContext import")
    sys.exit(1)
content = content.replace(old_import, new_import, 1)

old_fn = '''  const withRunSession = (
    result: Omit<RunCronAgentTurnResult, "sessionId" | "sessionKey">,
  ): RunCronAgentTurnResult => ({
    ...result,
    sessionId: runSessionId,
    sessionKey: runSessionKey,
  });'''

new_fn = '''  const withRunSession = (
    result: Omit<RunCronAgentTurnResult, "sessionId" | "sessionKey">,
  ): RunCronAgentTurnResult => {
    clearAgentRunContext(runSessionId);
    return {
      ...result,
      sessionId: runSessionId,
      sessionKey: runSessionKey,
    };
  };'''

if old_fn not in content:
    print("ERROR: cannot find withRunSession arrow function")
    sys.exit(1)
content = content.replace(old_fn, new_fn, 1)

with open(sys.argv[1], "w") as f:
    f.write(content)
print("OK: #17823 part 1 — run.ts: import + withRunSession cleanup")
PYEOF

# Part 2: Add seqByRun.delete to clearAgentRunContext
python3 - "$EVENTS_FILE" << 'PYEOF'
import sys

with open(sys.argv[1], "r") as f:
    content = f.read()

old_clear = '''export function clearAgentRunContext(runId: string) {
  runContextById.delete(runId);
}'''

new_clear = '''export function clearAgentRunContext(runId: string) {
  runContextById.delete(runId);
  seqByRun.delete(runId);
}'''

if old_clear not in content:
    if 'seqByRun.delete(runId)' in content:
        print("SKIP: #17823 part 2 already applied")
        sys.exit(0)
    print("ERROR: cannot find clearAgentRunContext function")
    sys.exit(1)

content = content.replace(old_clear, new_clear, 1)

with open(sys.argv[1], "w") as f:
    f.write(content)
print("OK: #17823 part 2 — agent-events.ts: seqByRun cleanup")
PYEOF
