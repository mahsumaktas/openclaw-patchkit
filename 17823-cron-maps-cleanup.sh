#!/usr/bin/env bash
# PR #17823 - fix: memory leak in cron isolated runs Maps cleanup
# Cron isolated agent runs register context in runContextById and seqByRun Maps
# but never clean up after completion. Over time this leaks memory.
# This patch:
# 1. Adds seqByRun.delete(runId) to clearAgentRunContext
# 2. Calls clearAgentRunContext(runSessionId) in withRunSession helper
# 3. Imports clearAgentRunContext in cron/isolated-agent/run.ts
set -euo pipefail
cd "$1"

# 1. Add seqByRun.delete to clearAgentRunContext in agent-events.ts
sed -i.bak '/export function clearAgentRunContext(runId: string) {/{
n
s|runContextById.delete(runId);|runContextById.delete(runId);\n  seqByRun.delete(runId);|
}' src/infra/agent-events.ts

# 2. Add clearAgentRunContext import in cron run.ts
sed -i.bak 's|import { registerAgentRunContext }|import { clearAgentRunContext, registerAgentRunContext }|' \
  src/cron/isolated-agent/run.ts

# 3. Update withRunSession to call clearAgentRunContext before returning
python3 -c "
with open('src/cron/isolated-agent/run.ts', 'r') as f:
    content = f.read()

old = '''  const withRunSession = (
    result: Omit<RunCronAgentTurnResult, \"sessionId\" | \"sessionKey\">,
  ): RunCronAgentTurnResult => ({
    ...result,
    sessionId: runSessionId,
    sessionKey: runSessionKey,
  });'''

new = '''  const withRunSession = (
    result: Omit<RunCronAgentTurnResult, \"sessionId\" | \"sessionKey\">,
  ): RunCronAgentTurnResult => {
    clearAgentRunContext(runSessionId);
    return {
      ...result,
      sessionId: runSessionId,
      sessionKey: runSessionKey,
    };
  };'''

if old in content:
    content = content.replace(old, new, 1)
    with open('src/cron/isolated-agent/run.ts', 'w') as f:
        f.write(content)
    print('Applied PR #17823 - cron Maps cleanup')
else:
    print('SKIP: withRunSession pattern not found or already applied')
"

rm -f src/infra/agent-events.ts.bak src/cron/isolated-agent/run.ts.bak
