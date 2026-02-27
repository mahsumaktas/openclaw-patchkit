#!/usr/bin/env bash
# PR #16963 — fix: enable auth rate limiting by default
# Without explicit gateway.auth.rateLimit config, the auth rate limiter was
# undefined, meaning no throttling on failed auth attempts. This opens the
# gateway to brute-force token guessing on exposed instances.
# Fix: always create the auth rate limiter — when config is absent, use
# default settings instead of skipping creation.
set -euo pipefail

SRC="${1:?Usage: $0 <openclaw-source-dir>}/src"

FILE="$SRC/gateway/server.impl.ts"
if [ ! -f "$FILE" ]; then
  echo "    FAIL: #16963 target file not found: $FILE"
  exit 1
fi

# Idempotency check
if grep -q '#16963\|always create.*rate limiter' "$FILE"; then
  echo "    SKIP: #16963 already applied"
  exit 0
fi

python3 - "$FILE" << 'PYEOF'
import sys

path = sys.argv[1]
with open(path, 'r') as f:
    content = f.read()

# Fix 1: Change the factory function to always return a rate limiter
old_factory = """\
function createGatewayAuthRateLimiters(rateLimitConfig: AuthRateLimitConfig | undefined): {
  rateLimiter?: AuthRateLimiter;
  browserRateLimiter: AuthRateLimiter;
} {
  const rateLimiter = rateLimitConfig ? createAuthRateLimiter(rateLimitConfig) : undefined;"""

new_factory = """\
function createGatewayAuthRateLimiters(rateLimitConfig: AuthRateLimitConfig | undefined): {
  rateLimiter: AuthRateLimiter;
  browserRateLimiter: AuthRateLimiter;
} {
  // #16963: always create rate limiter — use defaults when config is absent
  const rateLimiter = createAuthRateLimiter(rateLimitConfig ?? {});"""

if old_factory not in content:
    print("    FAIL: #16963 factory pattern not found in server.impl.ts")
    sys.exit(1)

content = content.replace(old_factory, new_factory, 1)

with open(path, 'w') as f:
    f.write(content)

print("    OK: #16963 auth rate limiting enabled by default")
PYEOF
