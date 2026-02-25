#!/usr/bin/env bash
# PR #21735 - fix(hooks): pass configured model to slug generator
set -euo pipefail
cd "$1"

FILE="src/hooks/llm-slug-generator.ts"

if [ ! -f "$FILE" ]; then
  echo "SKIP: $FILE not found"
  exit 0
fi

if grep -q 'resolveDefaultModelForAgent' "$FILE"; then
  echo "SKIP: PR #21735 already applied (resolveDefaultModelForAgent found)"
  exit 0
fi

python3 << 'PYEOF'
import sys

filepath = "src/hooks/llm-slug-generator.ts"
with open(filepath, "r") as f:
    content = f.read()

old_import_scope = """\
import {
  resolveDefaultAgentId,
  resolveAgentWorkspaceDir,
  resolveAgentDir,
  resolveAgentModelPrimary,
} from "../agents/agent-scope.js";"""

new_import_scope = """\
import {
  resolveDefaultAgentId,
  resolveAgentWorkspaceDir,
  resolveAgentDir,
} from "../agents/agent-scope.js";"""

if old_import_scope not in content:
    print("ERROR: Could not find agent-scope import block to patch", file=sys.stderr)
    sys.exit(1)

content = content.replace(old_import_scope, new_import_scope)

old_import_defaults = 'import { DEFAULT_PROVIDER, DEFAULT_MODEL } from "../agents/defaults.js";\n'
content = content.replace(old_import_defaults, "")

old_import_model = 'import { parseModelRef } from "../agents/model-selection.js";'
new_import_model = 'import { resolveDefaultModelForAgent } from "../agents/model-selection.js";'

if old_import_model not in content:
    print("ERROR: Could not find model-selection import to patch", file=sys.stderr)
    sys.exit(1)

content = content.replace(old_import_model, new_import_model)

old_resolve = """\
    // Resolve model from agent config instead of using hardcoded defaults
    const modelRef = resolveAgentModelPrimary(params.cfg, agentId);
    const parsed = modelRef ? parseModelRef(modelRef, DEFAULT_PROVIDER) : null;
    const provider = parsed?.provider ?? DEFAULT_PROVIDER;
    const model = parsed?.model ?? DEFAULT_MODEL;

    const result = await runEmbeddedPiAgent({"""

new_resolve = """\
    const resolvedModel = resolveDefaultModelForAgent({ cfg: params.cfg, agentId });

    const result = await runEmbeddedPiAgent({"""

if old_resolve not in content:
    print("ERROR: Could not find model resolution block to patch", file=sys.stderr)
    sys.exit(1)

content = content.replace(old_resolve, new_resolve)
content = content.replace("      provider,\n      model,", "      provider: resolvedModel.provider,\n      model: resolvedModel.model,")

with open(filepath, "w") as f:
    f.write(content)

print("OK: PR #21735 applied - slug generator now uses resolveDefaultModelForAgent")
PYEOF
