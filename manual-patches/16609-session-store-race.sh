#!/usr/bin/env bash
# PR #16609: Fix session store race condition and contextTokens updates
# 1. session-store.ts: Move entry build inside updateSessionStore callback
# 2. model-overrides.ts: Add contextTokens update on model change
set -euo pipefail

CHANGED=0

# 1. session-store.ts: Move entry build into lock callback
FILE="src/commands/agent/session-store.ts"
if [ -f "$FILE" ]; then
  node -e "
const fs = require('fs');
let code = fs.readFileSync('$FILE', 'utf8');

// Find the block to replace: from 'const entry = sessionStore' to the closing of updateSessionStore
const oldBlock = \`  const entry = sessionStore[sessionKey] ?? {
    sessionId,
    updatedAt: Date.now(),
  };
  const next: SessionEntry = {
    ...entry,
    sessionId,
    updatedAt: Date.now(),
    modelProvider: providerUsed,
    model: modelUsed,
    contextTokens,
  };
  if (isCliProvider(providerUsed, cfg)) {
    const cliSessionId = result.meta.agentMeta?.sessionId?.trim();
    if (cliSessionId) {
      setCliSessionId(next, providerUsed, cliSessionId);
    }
  }
  next.abortedLastRun = result.meta.aborted ?? false;
  if (hasNonzeroUsage(usage)) {
    const input = usage.input ?? 0;
    const output = usage.output ?? 0;
    const totalTokens =
      deriveSessionTotalTokens({
        usage,
        contextTokens,
        promptTokens,
      }) ?? input;
    next.inputTokens = input;
    next.outputTokens = output;
    next.totalTokens = totalTokens;
    next.totalTokensFresh = true;
    next.cacheRead = usage.cacheRead ?? 0;
    next.cacheWrite = usage.cacheWrite ?? 0;
  }
  if (compactionsThisRun > 0) {
    next.compactionCount = (entry.compactionCount ?? 0) + compactionsThisRun;
  }
  sessionStore[sessionKey] = next;
  await updateSessionStore(storePath, (store) => {
    store[sessionKey] = next;
  });\`;

const newBlock = \`  // Build the session entry inside the lock callback to read fresh data
  // from disk, avoiding races where compaction or another agent run
  // modifies the entry between our read and write.
  await updateSessionStore(storePath, (store) => {
    const entry = store[sessionKey] ?? {
      sessionId,
      updatedAt: Date.now(),
    };
    const next: SessionEntry = {
      ...entry,
      sessionId,
      updatedAt: Date.now(),
      modelProvider: providerUsed,
      model: modelUsed,
      contextTokens,
    };
    if (isCliProvider(providerUsed, cfg)) {
      const cliSessionId = result.meta.agentMeta?.sessionId?.trim();
      if (cliSessionId) {
        setCliSessionId(next, providerUsed, cliSessionId);
      }
    }
    next.abortedLastRun = result.meta.aborted ?? false;
    if (hasNonzeroUsage(usage)) {
      const input = usage.input ?? 0;
      const output = usage.output ?? 0;
      const totalTokens =
        deriveSessionTotalTokens({
          usage,
          contextTokens,
          promptTokens,
        }) ?? input;
      next.inputTokens = input;
      next.outputTokens = output;
      next.totalTokens = totalTokens;
      next.totalTokensFresh = true;
      next.cacheRead = usage.cacheRead ?? 0;
      next.cacheWrite = usage.cacheWrite ?? 0;
    }
    if (compactionsThisRun > 0) {
      next.compactionCount = (entry.compactionCount ?? 0) + compactionsThisRun;
    }
    store[sessionKey] = next;
    sessionStore[sessionKey] = next;
  });\`;

if (code.includes('const entry = sessionStore[sessionKey]')) {
  code = code.replace(oldBlock, newBlock);
  fs.writeFileSync('$FILE', code);
  console.log('OK: session-store.ts race condition fixed');
} else {
  console.log('SKIP: session-store.ts already patched or different');
}
"
  CHANGED=$((CHANGED + 1))
fi

# 2. model-overrides.ts: Add contextTokens update
FILE="src/sessions/model-overrides.ts"
if [ -f "$FILE" ]; then
  node -e "
const fs = require('fs');
let code = fs.readFileSync('$FILE', 'utf8');

// Add imports at top
if (!code.includes('lookupContextTokens')) {
  code = 'import { lookupContextTokens } from \"../agents/context.js\";\nimport { DEFAULT_CONTEXT_TOKENS } from \"../agents/defaults.js\";\n' + code;

  // Add contextTokens update before profileOverride block
  const insertBefore = '  if (profileOverride) {';
  const contextBlock = \`  // Update contextTokens to match the selected model's context window
  const modelContextTokens = lookupContextTokens(selection.model) ?? DEFAULT_CONTEXT_TOKENS;
  if (entry.contextTokens !== modelContextTokens) {
    entry.contextTokens = modelContextTokens;
    updated = true;
  }

\`;
  code = code.replace(insertBefore, contextBlock + insertBefore);
  fs.writeFileSync('$FILE', code);
  console.log('OK: model-overrides.ts contextTokens update added');
} else {
  console.log('SKIP: model-overrides.ts already patched');
}
"
  CHANGED=$((CHANGED + 1))
fi

echo "Done: $CHANGED files patched for #16609"
