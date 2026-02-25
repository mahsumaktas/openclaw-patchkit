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
# NOTE: BSD sed (macOS) cannot reliably do multiline s/// with N command.
# Use python3 for the multiline replacement instead.
python3 -c "
with open('$FILE', 'r') as f:
    content = f.read()

old = '''if (params.flags !== undefined) {
    payload.flags = params.flags;'''

new = '''const v2Flag = hasV2 ? MessageFlags.IsComponentsV2 : 0;
  const mergedFlags = (params.flags ?? 0) | v2Flag;
  if (mergedFlags) {
    payload.flags = mergedFlags;'''

if old in content:
    content = content.replace(old, new, 1)
    with open('$FILE', 'w') as f:
        f.write(content)
    print('OK: flags assignment replaced')
else:
    print('SKIP: flags pattern not found or already applied')
"

rm -f \"\${FILE}.bak\"
echo \"Applied PR #22900 - discord v2 components flag\"
