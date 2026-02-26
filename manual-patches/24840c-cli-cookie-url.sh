#!/usr/bin/env bash
# PR #24840 Group C: fix(cli): rename --url to --cookie-url in cookies set
#
# Split from original bundled patch (stability audit 2026-02-26).
# Only CLI cookie-url rename — env redact separate, network failover removed.
#
# Changes: src/cli/browser-cli-state.cookies-storage.ts — 3 replacements
set -euo pipefail
cd "$1"

# ── Idempotency gate ─────────────────────────────────────────────────────────
if grep -q 'cookie-url' src/cli/browser-cli-state.cookies-storage.ts 2>/dev/null; then
  echo "    SKIP: #24840-C cookie-url already applied"
  exit 0
fi

python3 - src/cli/browser-cli-state.cookies-storage.ts << 'PYEOF'
import sys

filepath = sys.argv[1]
with open(filepath, "r") as f:
    code = f.read()

if "--cookie-url" in code:
    print("    SKIP: #24840-C already applied")
    sys.exit(0)

changed = False
replacements = [
    ('Set a cookie (requires --url or domain+path)', 'Set a cookie (requires --cookie-url or domain+path)'),
    ('.requiredOption("--url <url>", "Cookie URL scope (recommended)")', '.requiredOption("--cookie-url <url>", "Cookie URL scope (recommended)")'),
    ('cookie: { name, value, url: opts.url }', 'cookie: { name, value, url: opts.cookieUrl }'),
]
for old, new in replacements:
    if old in code:
        code = code.replace(old, new, 1)
        changed = True

if changed:
    with open(filepath, "w") as f:
        f.write(code)
    print("    OK: #24840-C cookie-url rename applied")
else:
    print("    FAIL: #24840-C cannot find --url patterns")
    sys.exit(1)
PYEOF
