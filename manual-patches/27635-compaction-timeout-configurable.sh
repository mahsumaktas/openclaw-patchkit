#!/usr/bin/env bash
set -euo pipefail
cd "$1"

PATCH_MARKER="PATCH_27635_COMPACTION_TIMEOUT"

# ── File 1: src/agents/usage.ts ──
FILE="src/agents/usage.ts"
if [[ ! -f "$FILE" ]]; then
  echo "SKIP $FILE — not found"
else
  if grep -q "$PATCH_MARKER" "$FILE" 2>/dev/null; then
    echo "SKIP $FILE — already patched"
  else
    python3 - "$FILE" << 'PYEOF'
import sys

file_path = sys.argv[1]
with open(file_path, "r") as f:
    content = f.read()

# Add the asFiniteNumberWithPreferred helper after asFiniteNumber
old_block = '''const asFiniteNumber = (value: unknown): number | undefined => {
  if (typeof value !== "number") {
    return undefined;
  }
  if (!Number.isFinite(value)) {
    return undefined;
  }
  return value;
};'''

new_block = '''const asFiniteNumber = (value: unknown): number | undefined => {
  if (typeof value !== "number") {
    return undefined;
  }
  if (!Number.isFinite(value)) {
    return undefined;
  }
  return value;
};

// PATCH_27635_COMPACTION_TIMEOUT
// Pick the first value that is > 0, otherwise return the first defined value.
// This handles providers that return both input_tokens (0) and prompt_tokens (actual count).
const asFiniteNumberWithPreferred = (value: unknown, fallback: unknown): number | undefined => {
  const primary = asFiniteNumber(value);
  const secondary = asFiniteNumber(fallback);
  // Prefer non-zero values, otherwise fall back to any defined value
  if (primary !== undefined && primary > 0) {
    return primary;
  }
  if (secondary !== undefined && secondary > 0) {
    return secondary;
  }
  // Return primary if defined (even if 0), otherwise secondary
  return primary ?? secondary;
};'''

if old_block not in content:
    print(f"WARN {file_path} — asFiniteNumber block not found, skipping")
    sys.exit(0)

content = content.replace(old_block, new_block)

# Replace the normalizeUsage input/output parsing
old_normalize = '''  // Some providers (pi-ai OpenAI-format) pre-subtract cached_tokens from
  // prompt_tokens upstream.  When cached_tokens > prompt_tokens the result is
  // negative, which is nonsensical.  Clamp to 0.
  const rawInput = asFiniteNumber(
    raw.input ?? raw.inputTokens ?? raw.input_tokens ?? raw.promptTokens ?? raw.prompt_tokens,
  );
  const input = rawInput !== undefined && rawInput < 0 ? 0 : rawInput;
  const output = asFiniteNumber(
    raw.output ??
      raw.outputTokens ??
      raw.output_tokens ??
      raw.completionTokens ??
      raw.completion_tokens,
  );'''

new_normalize = '''  // Prefer input_tokens but fall back to prompt_tokens if input_tokens is 0 or undefined.
  // Some providers (e.g., yunwu-openai) return input_tokens=0 but prompt_tokens with actual count.
  const input = asFiniteNumberWithPreferred(
    raw.input ?? raw.inputTokens ?? raw.input_tokens,
    raw.promptTokens ?? raw.prompt_tokens,
  );
  const output = asFiniteNumberWithPreferred(
    raw.output ?? raw.outputTokens ?? raw.output_tokens,
    raw.completionTokens ?? raw.completion_tokens,
  );'''

if old_normalize not in content:
    print(f"WARN {file_path} — normalizeUsage input/output block not found, skipping")
    sys.exit(0)

content = content.replace(old_normalize, new_normalize)

with open(file_path, "w") as f:
    f.write(content)

print(f"OK   {file_path}")
PYEOF
  fi
fi

# ── File 2: src/agents/pi-embedded-runner/compact.ts ──
FILE="src/agents/pi-embedded-runner/compact.ts"
if [[ ! -f "$FILE" ]]; then
  echo "SKIP $FILE — not found"
else
  if grep -q "$PATCH_MARKER" "$FILE" 2>/dev/null; then
    echo "SKIP $FILE — already patched"
  else
    python3 - "$FILE" << 'PYEOF'
import sys

file_path = sys.argv[1]
with open(file_path, "r") as f:
    content = f.read()

# Change 1: Add configurable timeout before acquireSessionWriteLock
old_lock = '''    const systemPromptOverride = createSystemPromptOverride(appendPrompt);

    const sessionLock = await acquireSessionWriteLock({
      sessionFile: params.sessionFile,
      maxHoldMs: resolveSessionLockMaxHoldFromTimeout({
        timeoutMs: EMBEDDED_COMPACTION_TIMEOUT_MS,
      }),
    });'''

new_lock = '''    const systemPromptOverride = createSystemPromptOverride(appendPrompt);

    const compactionTimeoutMs = // PATCH_27635_COMPACTION_TIMEOUT
      params.config?.agents?.defaults?.compaction?.timeoutMs ?? EMBEDDED_COMPACTION_TIMEOUT_MS;
    const sessionLock = await acquireSessionWriteLock({
      sessionFile: params.sessionFile,
      maxHoldMs: resolveSessionLockMaxHoldFromTimeout({
        timeoutMs: compactionTimeoutMs,
      }),
    });'''

if old_lock not in content:
    print(f"WARN {file_path} — sessionLock block not found, skipping")
    sys.exit(0)

content = content.replace(old_lock, new_lock)

# Change 2: Pass compactionTimeoutMs to compactWithSafetyTimeout
old_compact = '''        const compactStartedAt = Date.now();
        const result = await compactWithSafetyTimeout(() =>
          session.compact(params.customInstructions),
        );'''

new_compact = '''        const compactStartedAt = Date.now();
        const result = await compactWithSafetyTimeout(
          () => session.compact(params.customInstructions),
          compactionTimeoutMs,
        );'''

if old_compact not in content:
    print(f"WARN {file_path} — compactWithSafetyTimeout call not found, skipping")
    sys.exit(0)

content = content.replace(old_compact, new_compact)

with open(file_path, "w") as f:
    f.write(content)

print(f"OK   {file_path}")
PYEOF
  fi
fi

# ── File 3: src/config/types.agent-defaults.ts ──
FILE="src/config/types.agent-defaults.ts"
if [[ ! -f "$FILE" ]]; then
  echo "SKIP $FILE — not found"
else
  if grep -q "$PATCH_MARKER" "$FILE" 2>/dev/null; then
    echo "SKIP $FILE — already patched"
  else
    python3 - "$FILE" << 'PYEOF'
import sys

file_path = sys.argv[1]
with open(file_path, "r") as f:
    content = f.read()

# Add timeoutMs field to AgentCompactionConfig
old_type = '''  /** Pre-compaction memory flush (agentic turn). Default: enabled. */
  memoryFlush?: AgentCompactionMemoryFlushConfig;
};

export type AgentCompactionMemoryFlushConfig = {'''

new_type = '''  /** Pre-compaction memory flush (agentic turn). Default: enabled. */
  memoryFlush?: AgentCompactionMemoryFlushConfig;
  /** Safety timeout for the compaction LLM call in milliseconds (default: 300000 = 5 min). Increase for slow local models. */ // PATCH_27635_COMPACTION_TIMEOUT
  timeoutMs?: number;
};

export type AgentCompactionMemoryFlushConfig = {'''

if old_type not in content:
    print(f"WARN {file_path} — AgentCompactionConfig memoryFlush block not found, skipping")
    sys.exit(0)

content = content.replace(old_type, new_type)

with open(file_path, "w") as f:
    f.write(content)

print(f"OK   {file_path}")
PYEOF
  fi
fi

# ── File 4: src/config/zod-schema.agent-defaults.ts ──
FILE="src/config/zod-schema.agent-defaults.ts"
if [[ ! -f "$FILE" ]]; then
  echo "SKIP $FILE — not found"
else
  if grep -q "$PATCH_MARKER" "$FILE" 2>/dev/null; then
    echo "SKIP $FILE — already patched"
  else
    python3 - "$FILE" << 'PYEOF'
import sys

file_path = sys.argv[1]
with open(file_path, "r") as f:
    content = f.read()

# Add timeoutMs to the compaction zod schema, after maxHistoryShare
old_schema = '''        maxHistoryShare: z.number().min(0.1).max(0.9).optional(),
        identifierPolicy: z'''

new_schema = '''        maxHistoryShare: z.number().min(0.1).max(0.9).optional(),
        timeoutMs: z.number().int().min(30_000).max(3_600_000).optional(), // PATCH_27635_COMPACTION_TIMEOUT
        identifierPolicy: z'''

if old_schema not in content:
    print(f"WARN {file_path} — compaction schema maxHistoryShare block not found, skipping")
    sys.exit(0)

content = content.replace(old_schema, new_schema)

with open(file_path, "w") as f:
    f.write(content)

print(f"OK   {file_path}")
PYEOF
  fi
fi

# ── File 5: src/config/schema.labels.ts ──
FILE="src/config/schema.labels.ts"
if [[ ! -f "$FILE" ]]; then
  echo "SKIP $FILE — not found"
else
  if grep -q "$PATCH_MARKER" "$FILE" 2>/dev/null; then
    echo "SKIP $FILE — already patched"
  else
    python3 - "$FILE" << 'PYEOF'
import sys

file_path = sys.argv[1]
with open(file_path, "r") as f:
    content = f.read()

# Add timeoutMs label after maxHistoryShare
old_labels = '''  "agents.defaults.compaction.maxHistoryShare": "Compaction Max History Share",
  "agents.defaults.compaction.identifierPolicy"'''

new_labels = '''  "agents.defaults.compaction.maxHistoryShare": "Compaction Max History Share",
  "agents.defaults.compaction.timeoutMs": "Compaction Timeout (ms)", // PATCH_27635_COMPACTION_TIMEOUT
  "agents.defaults.compaction.identifierPolicy"'''

if old_labels not in content:
    print(f"WARN {file_path} — compaction labels maxHistoryShare block not found")
    # Try alternate anchor
    alt_old = '''  "agents.defaults.compaction.maxHistoryShare": "Compaction Max History Share",
  "agents.defaults.compaction.memoryFlush"'''
    alt_new = '''  "agents.defaults.compaction.maxHistoryShare": "Compaction Max History Share",
  "agents.defaults.compaction.timeoutMs": "Compaction Timeout (ms)", // PATCH_27635_COMPACTION_TIMEOUT
  "agents.defaults.compaction.memoryFlush"'''
    if alt_old in content:
        content = content.replace(alt_old, alt_new)
    else:
        print(f"WARN {file_path} — no suitable anchor found, skipping")
        sys.exit(0)
else:
    content = content.replace(old_labels, new_labels)

with open(file_path, "w") as f:
    f.write(content)

print(f"OK   {file_path}")
PYEOF
  fi
fi

# ── File 6: src/config/schema.help.ts ──
FILE="src/config/schema.help.ts"
if [[ ! -f "$FILE" ]]; then
  echo "SKIP $FILE — not found"
else
  if grep -q "$PATCH_MARKER" "$FILE" 2>/dev/null; then
    echo "SKIP $FILE — already patched"
  else
    python3 - "$FILE" << 'PYEOF'
import sys

file_path = sys.argv[1]
with open(file_path, "r") as f:
    content = f.read()

# Add timeoutMs help after maxHistoryShare help entry
# The maxHistoryShare entry spans two lines
old_help = '''  "agents.defaults.compaction.maxHistoryShare":
    "Maximum fraction of total context budget allowed for retained history after compaction (range 0.1-0.9). Use lower shares for more generation headroom or higher shares for deeper historical continuity.",
  "agents.defaults.compaction.identifierPolicy"'''

new_help = '''  "agents.defaults.compaction.maxHistoryShare":
    "Maximum fraction of total context budget allowed for retained history after compaction (range 0.1-0.9). Use lower shares for more generation headroom or higher shares for deeper historical continuity.",
  "agents.defaults.compaction.timeoutMs": // PATCH_27635_COMPACTION_TIMEOUT
    "Safety timeout in milliseconds for the compaction LLM call (default: 300000 = 5 minutes, range: 30000-3600000). Increase for slow local models (e.g., Ollama) that need more time to generate compaction summaries.",
  "agents.defaults.compaction.identifierPolicy"'''

if old_help not in content:
    print(f"WARN {file_path} — compaction help maxHistoryShare block not found")
    # Try alternate anchor
    alt_old = '''  "agents.defaults.compaction.maxHistoryShare":
    "Maximum fraction of total context budget allowed for retained history after compaction (range 0.1-0.9). Use lower shares for more generation headroom or higher shares for deeper historical continuity.",
  "agents.defaults.compaction.memoryFlush"'''
    alt_new = '''  "agents.defaults.compaction.maxHistoryShare":
    "Maximum fraction of total context budget allowed for retained history after compaction (range 0.1-0.9). Use lower shares for more generation headroom or higher shares for deeper historical continuity.",
  "agents.defaults.compaction.timeoutMs": // PATCH_27635_COMPACTION_TIMEOUT
    "Safety timeout in milliseconds for the compaction LLM call (default: 300000 = 5 minutes, range: 30000-3600000). Increase for slow local models (e.g., Ollama) that need more time to generate compaction summaries.",
  "agents.defaults.compaction.memoryFlush"'''
    if alt_old in content:
        content = content.replace(alt_old, alt_new)
    else:
        print(f"WARN {file_path} — no suitable anchor found, skipping")
        sys.exit(0)
else:
    content = content.replace(old_help, new_help)

with open(file_path, "w") as f:
    f.write(content)

print(f"OK   {file_path}")
PYEOF
  fi
fi

echo "DONE #27635 — compaction timeout configurable"
