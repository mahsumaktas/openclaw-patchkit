#!/usr/bin/env bash
# Issue #26673: fix(agents): make compaction.mode "safeguard" respect contextTokens cap
#
# Bug: The contextTokens config value (agents.defaults.contextTokens) is intended
# to cap the effective context window for compaction triggering. However, the cap
# was only passed to the safeguard extension runtime — the pi-coding-agent SDK's
# built-in shouldCompact() still used model.contextWindow (e.g. 1M for Gemini Flash).
# This meant compaction never triggered at the configured contextTokens threshold.
#
# Root cause: resolveContextWindowInfo() correctly computes the capped value, but
# neither attempt.ts nor compact.ts apply it to the model object before calling
# createAgentSession(). The SDK's compaction trigger only sees model.contextWindow.
#
# Fix: After building extension factories, compute the effective context window
# using resolveContextWindowInfo(). If it's lower than the model's contextWindow,
# override model.contextWindow so the SDK's built-in compaction respects the cap.
#
# Changes:
#   src/agents/pi-embedded-runner/run/attempt.ts — import + apply contextWindow cap
#   src/agents/pi-embedded-runner/compact.ts — import + apply contextWindow cap
set -euo pipefail

SRC="${1:-.}/src"

# ── Idempotency check ──────────────────────────────────────────────────────
if grep -q 'effectiveContextWindow' "$SRC/agents/pi-embedded-runner/run/attempt.ts" 2>/dev/null; then
  echo "    SKIP: #26673 already applied"
  exit 0
fi

# ── 1. attempt.ts: import resolveContextWindowInfo + apply cap ─────────────
python3 - "$SRC/agents/pi-embedded-runner/run/attempt.ts" << 'PYEOF'
import sys

path = sys.argv[1]
with open(path, 'r') as f:
    content = f.read()

# 1a. Add import for resolveContextWindowInfo after buildEmbeddedExtensionFactories import
old_import = 'import { buildEmbeddedExtensionFactories } from "../extensions.js";'
new_import = '''import { buildEmbeddedExtensionFactories } from "../extensions.js";
import { resolveContextWindowInfo } from "../../context-window-guard.js";'''

if 'resolveContextWindowInfo' in content:
    print("    SKIP: #26673 attempt.ts import already present")
else:
    if old_import not in content:
        print("    FAIL: #26673 extensions import marker not found in attempt.ts")
        sys.exit(1)
    content = content.replace(old_import, new_import, 1)
    print("    OK: #26673 attempt.ts resolveContextWindowInfo import added")

# 1a-bis. Ensure DEFAULT_CONTEXT_TOKENS is imported in attempt.ts
if 'DEFAULT_CONTEXT_TOKENS' not in content:
    old_defaults = 'import { DEFAULT_CONTEXT_TOKENS } from "../../defaults.js";'
    if old_defaults in content:
        pass  # already there
    else:
        # Try to add to existing defaults import
        for variant in [
            'import { DEFAULT_CONTEXT_TOKENS, DEFAULT_MODEL, DEFAULT_PROVIDER } from "../../defaults.js";',
            'import { DEFAULT_MODEL, DEFAULT_PROVIDER } from "../../defaults.js";',
        ]:
            if variant in content and 'DEFAULT_CONTEXT_TOKENS' not in variant:
                content = content.replace(
                    variant,
                    variant.replace('import { ', 'import { DEFAULT_CONTEXT_TOKENS, '),
                    1
                )
                print("    OK: #26673 attempt.ts DEFAULT_CONTEXT_TOKENS added to defaults import")
                break
        else:
            # Add as standalone import after the context-window-guard import
            guard_import = 'import { resolveContextWindowInfo } from "../../context-window-guard.js";'
            if guard_import in content:
                content = content.replace(
                    guard_import,
                    guard_import + '\nimport { DEFAULT_CONTEXT_TOKENS } from "../../defaults.js";',
                    1
                )
                print("    OK: #26673 attempt.ts DEFAULT_CONTEXT_TOKENS standalone import added")

# 1b. Add context window cap logic after buildEmbeddedExtensionFactories call
# We need to insert BEFORE the createAgentSession call and AFTER extensionFactories
old_session_create = '''      const allCustomTools = [...customTools, ...clientToolDefs];

      ({ session } = await createAgentSession({
        cwd: resolvedWorkspace,
        agentDir,
        authStorage: params.authStorage,
        modelRegistry: params.modelRegistry,
        model: params.model,'''

new_session_create = '''      const allCustomTools = [...customTools, ...clientToolDefs];

      // #26673: Apply contextTokens cap to model.contextWindow so the SDK's
      // built-in shouldCompact() respects the configured threshold, not just
      // the model's native context window (which can be 1M+ for some models).
      const effectiveContextWindow = resolveContextWindowInfo({
        cfg: params.config,
        provider: params.provider,
        modelId: params.modelId,
        modelContextWindow: params.model.contextWindow,
        defaultTokens: DEFAULT_CONTEXT_TOKENS,
      });
      let sessionModel = params.model;
      if (
        effectiveContextWindow.source === "agentContextTokens" &&
        effectiveContextWindow.tokens < (params.model.contextWindow ?? Infinity)
      ) {
        sessionModel = { ...params.model, contextWindow: effectiveContextWindow.tokens };
      }

      ({ session } = await createAgentSession({
        cwd: resolvedWorkspace,
        agentDir,
        authStorage: params.authStorage,
        modelRegistry: params.modelRegistry,
        model: sessionModel,'''

if 'effectiveContextWindow' in content:
    print("    SKIP: #26673 attempt.ts cap already applied")
else:
    if old_session_create not in content:
        print("    FAIL: #26673 createAgentSession marker not found in attempt.ts")
        sys.exit(1)
    content = content.replace(old_session_create, new_session_create, 1)
    print("    OK: #26673 attempt.ts contextWindow cap applied")

with open(path, 'w') as f:
    f.write(content)

print("    OK: #26673 attempt.ts fully patched")
PYEOF

# ── 2. compact.ts: import resolveContextWindowInfo + DEFAULT_CONTEXT_TOKENS + apply cap ──
python3 - "$SRC/agents/pi-embedded-runner/compact.ts" << 'PYEOF'
import sys

path = sys.argv[1]
with open(path, 'r') as f:
    content = f.read()

# 2a. Add import for resolveContextWindowInfo
old_import = 'import { buildEmbeddedExtensionFactories } from "./extensions.js";'
new_import = '''import { resolveContextWindowInfo } from "../context-window-guard.js";
import { DEFAULT_CONTEXT_TOKENS } from "../defaults.js";
import { buildEmbeddedExtensionFactories } from "./extensions.js";'''

if 'resolveContextWindowInfo' in content:
    print("    SKIP: #26673 compact.ts import already present")
else:
    if old_import not in content:
        print("    FAIL: #26673 extensions import marker not found in compact.ts")
        sys.exit(1)
    content = content.replace(old_import, new_import, 1)
    # Check if DEFAULT_CONTEXT_TOKENS already imported from defaults
    if 'DEFAULT_CONTEXT_TOKENS' in content.split(new_import)[0]:
        # Already imported, remove duplicate
        content = content.replace(
            'import { DEFAULT_CONTEXT_TOKENS } from "../defaults.js";\n',
            '', 1)
    print("    OK: #26673 compact.ts imports added")

# Also check DEFAULT_MODEL import already has DEFAULT_CONTEXT_TOKENS
# DEFAULT_MODEL, DEFAULT_PROVIDER are imported from ../defaults.js
if 'DEFAULT_CONTEXT_TOKENS' not in content:
    # Need to add it to existing defaults import
    old_defaults_import = 'import { DEFAULT_MODEL, DEFAULT_PROVIDER } from "../defaults.js";'
    new_defaults_import = 'import { DEFAULT_CONTEXT_TOKENS, DEFAULT_MODEL, DEFAULT_PROVIDER } from "../defaults.js";'
    if old_defaults_import in content:
        content = content.replace(old_defaults_import, new_defaults_import, 1)
        print("    OK: #26673 compact.ts DEFAULT_CONTEXT_TOKENS added to defaults import")

# 2b. Add context window cap logic before createAgentSession in compact.ts
old_session_create = '''      const { session } = await createAgentSession({
        cwd: resolvedWorkspace,
        agentDir,
        authStorage,
        modelRegistry,
        model,
        thinkingLevel: mapThinkingLevel(params.thinkLevel),
        tools: builtInTools,
        customTools,
        sessionManager,
        settingsManager,
        resourceLoader,
      });'''

new_session_create = '''      // #26673: Apply contextTokens cap to model.contextWindow so the SDK's
      // built-in shouldCompact() respects the configured threshold.
      const effectiveContextWindow = resolveContextWindowInfo({
        cfg: params.config,
        provider,
        modelId,
        modelContextWindow: model.contextWindow,
        defaultTokens: DEFAULT_CONTEXT_TOKENS,
      });
      let sessionModel = model;
      if (
        effectiveContextWindow.source === "agentContextTokens" &&
        effectiveContextWindow.tokens < (model.contextWindow ?? Infinity)
      ) {
        sessionModel = { ...model, contextWindow: effectiveContextWindow.tokens };
      }

      const { session } = await createAgentSession({
        cwd: resolvedWorkspace,
        agentDir,
        authStorage,
        modelRegistry,
        model: sessionModel,
        thinkingLevel: mapThinkingLevel(params.thinkLevel),
        tools: builtInTools,
        customTools,
        sessionManager,
        settingsManager,
        resourceLoader,
      });'''

if 'effectiveContextWindow' in content:
    print("    SKIP: #26673 compact.ts cap already applied")
else:
    if old_session_create not in content:
        print("    FAIL: #26673 createAgentSession marker not found in compact.ts")
        sys.exit(1)
    content = content.replace(old_session_create, new_session_create, 1)
    print("    OK: #26673 compact.ts contextWindow cap applied")

with open(path, 'w') as f:
    f.write(content)

print("    OK: #26673 compact.ts fully patched")
PYEOF

echo "    OK: #26673 compaction safeguard fully applied"
