#!/usr/bin/env bash
# PR #22900 - fix(discord): set IS_COMPONENTS_V2 flag for v2 components
# Discord requires MessageFlags.IsComponentsV2 when sending v2 component payloads.
# Without this flag, v2 components are silently ignored.
set -euo pipefail
cd "$1"

FILE="src/discord/send.shared.ts"

# Add MessageFlags to the import from discord-api-types/v10
sed -i.bak 's/import { Routes,/import { MessageFlags, Routes,/' "$FILE"

# Replace the flags assignment logic
sed -i.bak '/if (params\.flags !== undefined) {/{
N
s|if (params\.flags !== undefined) {\n    payload\.flags = params\.flags;|const v2Flag = hasV2 ? MessageFlags.IsComponentsV2 : 0;\n  const mergedFlags = (params.flags ?? 0) | v2Flag;\n  if (mergedFlags) {\n    payload.flags = mergedFlags;|
}' "$FILE"

rm -f "${FILE}.bak"
echo "Applied PR #22900 - discord v2 components flag"
