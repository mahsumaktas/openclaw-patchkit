#!/usr/bin/env bash
# PR #24764 — fix(failover): classify subscription/plan unavailability as billing
# Some providers return errors like "subscription expired", "plan limit exceeded",
# "no active subscription", or "plan unavailable" which are effectively billing
# issues but weren't classified as such. Without this, failover doesn't trigger
# and the user sees a raw API error.
# Fix: add subscription/plan unavailability patterns to isBillingErrorMessage.
set -euo pipefail

SRC="${1:?Usage: $0 <openclaw-source-dir>}/src"

FILE="$SRC/agents/pi-embedded-helpers/errors.ts"
if [ ! -f "$FILE" ]; then
  echo "    FAIL: #24764 target file not found: $FILE"
  exit 1
fi

# Idempotency check
if grep -q 'subscription.*unavailable\|#24764' "$FILE"; then
  echo "    SKIP: #24764 already applied"
  exit 0
fi

python3 - "$FILE" << 'PYEOF'
import sys

path = sys.argv[1]
with open(path, 'r') as f:
    content = f.read()

# 1. Add subscription/plan patterns to the billing error patterns array.
# Target the end of the billing patterns list.
old_patterns = '''\
  billing: [
    /["']?(?:status|code)["']?\\s*[:=]\\s*402\\b|\\bhttp\\s*402\\b|\\berror(?:\\s+code)?\\s*[:=]?\\s*402\\b|\\b(?:got|returned|received)\\s+(?:a\\s+)?402\\b|^\\s*402\\s+payment/i,
    "payment required",
    "insufficient credits",
    "credit balance",
    "plans & billing",
    "insufficient balance",
  ],'''

new_patterns = '''\
  billing: [
    /["']?(?:status|code)["']?\\s*[:=]\\s*402\\b|\\bhttp\\s*402\\b|\\berror(?:\\s+code)?\\s*[:=]?\\s*402\\b|\\b(?:got|returned|received)\\s+(?:a\\s+)?402\\b|^\\s*402\\s+payment/i,
    "payment required",
    "insufficient credits",
    "credit balance",
    "plans & billing",
    "insufficient balance",
    // #24764: subscription/plan unavailability → billing failover
    "subscription expired",
    "subscription unavailable",
    "no active subscription",
    "plan limit exceeded",
    "plan unavailable",
    /subscription.*(?:expired|inactive|unavailable|cancelled|canceled)/i,
    /plan.*(?:limit|unavailable|expired|exceeded)/i,
  ],'''

if old_patterns not in content:
    print("    FAIL: #24764 billing patterns block not found in errors.ts")
    sys.exit(1)

content = content.replace(old_patterns, new_patterns, 1)

with open(path, 'w') as f:
    f.write(content)

print("    OK: #24764 added subscription/plan unavailability patterns to billing failover")
PYEOF
