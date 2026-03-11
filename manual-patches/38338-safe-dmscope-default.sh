#!/usr/bin/env bash
# PR #38338 — fix: use safe dmScope default to prevent cross-channel reply leakage
#
# Problem: dmScope defaults to "main" in 6 runtime locations but onboarding sets
# "per-channel-peer". After upgrades that don't preserve config, the runtime
# default silently falls back to "main", causing cross-channel reply leakage.
#
# Fix: Add DEFAULT_DM_SCOPE constant to config/types.base.ts and use it everywhere.
set -euo pipefail
SRC="${1:-.}/src"

TYPES_BASE="$SRC/config/types.base.ts"

# ── Idempotency ──
if grep -q 'DEFAULT_DM_SCOPE' "$TYPES_BASE" 2>/dev/null; then
  echo "    SKIP: #38338 already applied"
  exit 0
fi

# ── File checks ──
[ -f "$TYPES_BASE" ] || { echo "    FAIL: #38338 $TYPES_BASE not found"; exit 1; }

# ── 1. Add DEFAULT_DM_SCOPE constant to config/types.base.ts ──
python3 - "$TYPES_BASE" << 'PYEOF'
import sys

path = sys.argv[1]
with open(path, 'r') as f:
    content = f.read()

old = 'export type DmScope = "main" | "per-peer" | "per-channel-peer" | "per-account-channel-peer";'
new = '''export type DmScope = "main" | "per-peer" | "per-channel-peer" | "per-account-channel-peer";

/**
 * Safe default for dmScope when not explicitly configured.
 * Matches the onboarding default ("per-channel-peer") to prevent
 * cross-channel reply leakage after upgrades that don't preserve the setting.
 */
export const DEFAULT_DM_SCOPE: DmScope = "per-channel-peer";'''

if old not in content:
    print("    FAIL: #38338 cannot find DmScope type declaration", file=sys.stderr)
    sys.exit(1)

content = content.replace(old, new, 1)

old_jsdoc = '  /** DM session scoping (default: "main"). */'
new_jsdoc = '  /** DM session scoping (default: "per-channel-peer"). */'
if old_jsdoc in content:
    content = content.replace(old_jsdoc, new_jsdoc, 1)

with open(path, 'w') as f:
    f.write(content)
print("    OK: #38338 types.base.ts — DEFAULT_DM_SCOPE added")
PYEOF

# ── 2-6. Replace "main" literals with DEFAULT_DM_SCOPE in runtime files ──
# Using a single python3 call to handle all files at once
python3 - "$SRC" << 'PYEOF'
import sys, os

src = sys.argv[1]

files_config = [
    ("routing/resolve-route.ts", "../config/types.base.js"),
    ("routing/session-key.ts", "../config/types.base.js"),
    ("security/audit-channel.ts", "../config/types.base.js"),
    ("commands/doctor-security.ts", "../config/types.base.js"),
    ("infra/outbound/outbound-session.ts", "../../config/types.base.js"),
]

for rel, import_path in files_config:
    fpath = os.path.join(src, rel)
    if not os.path.isfile(fpath):
        print(f"    WARN: #38338 {rel} not found -- skipping")
        continue

    with open(fpath, 'r') as f:
        content = f.read()

    if 'dmScope ?? "main"' not in content:
        print(f"    SKIP: #38338 {rel} -- pattern not found (may be pre-patched)")
        continue

    import_line = f'import {{ DEFAULT_DM_SCOPE }} from "{import_path}";'

    if 'DEFAULT_DM_SCOPE' not in content:
        lines = content.split('\n')
        # Find the end of the last import block, accounting for multi-line imports.
        # A multi-line import starts with 'import' or 'import type' and ends with
        # a line containing '} from' or 'from "'. We need to insert AFTER the
        # closing line, not after the opening 'import' line.
        last_import_end = -1
        in_import = False
        for i, line in enumerate(lines):
            stripped = line.strip()
            if stripped.startswith('import '):
                if 'from ' in stripped and stripped.endswith(';'):
                    # Single-line import
                    last_import_end = i
                    in_import = False
                else:
                    # Start of multi-line import
                    in_import = True
            elif in_import:
                if stripped.endswith(';') and ('from ' in stripped or 'from "' in line or "from '" in line):
                    last_import_end = i
                    in_import = False
                elif '} from ' in stripped:
                    last_import_end = i
                    in_import = False
        if last_import_end >= 0:
            lines.insert(last_import_end + 1, import_line)
            content = '\n'.join(lines)
        else:
            content = import_line + '\n' + content

    content = content.replace('dmScope ?? "main"', 'dmScope ?? DEFAULT_DM_SCOPE')

    with open(fpath, 'w') as f:
        f.write(content)
    print(f"    OK: #38338 {rel} -- DEFAULT_DM_SCOPE wired")
PYEOF

# ── 7. Update onboard-config.ts to use DEFAULT_DM_SCOPE ──
ONBOARD="$SRC/commands/onboard-config.ts"
if [ -f "$ONBOARD" ]; then
  python3 - "$ONBOARD" << 'PYEOF'
import sys

path = sys.argv[1]
with open(path, 'r') as f:
    content = f.read()

old_import = 'import type { DmScope } from "../config/types.base.js";'
new_import = 'import { DEFAULT_DM_SCOPE } from "../config/types.base.js";'

if old_import in content:
    content = content.replace(old_import, new_import, 1)
    content = content.replace('\nexport const ONBOARDING_DEFAULT_DM_SCOPE: DmScope = "per-channel-peer";\n', '\n', 1)
    content = content.replace('ONBOARDING_DEFAULT_DM_SCOPE', 'DEFAULT_DM_SCOPE')
    with open(path, 'w') as f:
        f.write(content)
    print("    OK: #38338 onboard-config.ts -- uses DEFAULT_DM_SCOPE")
elif 'DEFAULT_DM_SCOPE' in content:
    print("    SKIP: #38338 onboard-config.ts -- already patched")
else:
    print("    WARN: #38338 onboard-config.ts -- unexpected layout, skipping")
PYEOF
fi

echo "    OK: #38338 safe dmScope default applied"
