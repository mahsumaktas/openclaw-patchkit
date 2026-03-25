#!/usr/bin/env bash
# Post-fix for PR 34580: add missing imports to gateway-tool.ts
# PR 34580 uses canonicalizeMainSessionAlias and resolveAgentIdFromSessionKey
# but the diff doesn't include the import lines (they existed in the PR branch base)
set -euo pipefail
SRC="${1:-.}/src"
FILE="$SRC/agents/tools/gateway-tool.ts"

[ -f "$FILE" ] || exit 0  # Nothing to fix if file doesn't exist

# Check if the functions are used but not imported
if grep -q "canonicalizeMainSessionAlias" "$FILE" && ! grep -q "import.*canonicalizeMainSessionAlias" "$FILE"; then
  # Add import for canonicalizeMainSessionAlias from main-session
  sed -i '' '1s|^|import { canonicalizeMainSessionAlias } from "../../config/sessions/main-session.js";\n|' "$FILE"
  echo "    OK: 34580-fix-imports: added canonicalizeMainSessionAlias import"
fi

if grep -q "resolveAgentIdFromSessionKey" "$FILE" && ! grep -q "import.*resolveAgentIdFromSessionKey" "$FILE"; then
  # Add import for resolveAgentIdFromSessionKey from session-key
  sed -i '' '1s|^|import { resolveAgentIdFromSessionKey } from "../../routing/session-key.js";\n|' "$FILE"
  echo "    OK: 34580-fix-imports: added resolveAgentIdFromSessionKey import"
fi

# Also check for resolveGatewayTarget if needed  
if grep -q "resolveGatewayTarget" "$FILE" && ! grep -q "resolveGatewayTarget" <(head -20 "$FILE"); then
  echo "    WARN: 34580-fix-imports: resolveGatewayTarget may need import check"
fi

exit 0
