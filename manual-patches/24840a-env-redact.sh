#!/usr/bin/env bash
# PR #24840 Group A: fix(config): redact env.vars with register(sensitive)
#
# Split from original bundled patch (stability audit 2026-02-26).
# Only env.vars redaction — network failover removed, CLI cookie-url separate.
#
# Changes: src/config/zod-schema.ts — 1 line change
set -euo pipefail
cd "$1"

# ── Idempotency gate ─────────────────────────────────────────────────────────
if grep -q 'register(sensitive)' src/config/zod-schema.ts 2>/dev/null; then
  echo "    SKIP: #24840-A env.vars register(sensitive) already present"
  exit 0
fi

python3 - src/config/zod-schema.ts << 'PYEOF'
import sys

filepath = sys.argv[1]
with open(filepath, "r") as f:
    code = f.read()

old = "vars: z.record(z.string(), z.string()).optional(),"
new = "vars: z.record(z.string(), z.string().register(sensitive)).optional(),"

if new in code:
    print("    SKIP: #24840-A already applied")
elif old in code:
    code = code.replace(old, new, 1)
    with open(filepath, "w") as f:
        f.write(code)
    print("    OK: #24840-A env.vars register(sensitive) applied")
else:
    print("    FAIL: #24840-A cannot find env.vars marker")
    sys.exit(1)
PYEOF
