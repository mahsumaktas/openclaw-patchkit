#!/usr/bin/env bash
# PR #27044 — fix(net): allow network config overrides for pinned dispatchers
# Adds DispatcherNetworkOptions type and parameter to createPinnedDispatcher,
# forwards networkOptions through fetch-guard, updates Telegram timeout default.
set -euo pipefail
SRC="${1:-.}/src"

SSRF_FILE="$SRC/infra/net/ssrf.ts"
GUARD_FILE="$SRC/infra/net/fetch-guard.ts"
FETCH_FILE="$SRC/telegram/fetch.ts"

# Idempotency check
if grep -q 'DispatcherNetworkOptions' "$SSRF_FILE" 2>/dev/null; then
  echo "    SKIP: #27044 already applied"
  exit 0
fi

# 1) ssrf.ts: Add DispatcherNetworkOptions type + constants + update createPinnedDispatcher
python3 - "$SSRF_FILE" << 'PYEOF'
import sys
path = sys.argv[1]
with open(path, 'r') as f:
    content = f.read()

# Replace createPinnedDispatcher function
old = '''export function createPinnedDispatcher(pinned: PinnedHostname): Dispatcher {
  return new Agent({
    connect: {
      lookup: pinned.lookup,
    },
  });
}'''

new = '''/**
 * Network-level options forwarded to the pinned undici dispatcher.
 *
 * When omitted the dispatcher falls back to safe defaults that work on most
 * networks.  Callers that have access to channel-level network configuration
 * (e.g. `channels.telegram.network`) should forward the relevant fields so
 * the user's intent is respected for SSRF-guarded media fetches as well.
 */
export type DispatcherNetworkOptions = {
  /**
   * Override Node / undici `autoSelectFamily` (Happy Eyeballs).  When `true`
   * undici races IPv4 and IPv6 connections; when `false` it uses the first
   * address returned by DNS (typically IPv4 after `dedupeAndPreferIpv4`).
   *
   * Default: `true`.
   */
  autoSelectFamily?: boolean;
  /**
   * Milliseconds to wait for the preferred address family before trying the
   * next one.  The previous hard-coded value of 300 ms was too aggressive for
   * high-latency routes (Australia/Asia/South America -> Telegram API).
   *
   * Default: `2000`.
   */
  autoSelectFamilyAttemptTimeout?: number;
};

const DEFAULT_AUTO_SELECT_FAMILY = true;
export const DEFAULT_AUTO_SELECT_FAMILY_ATTEMPT_TIMEOUT = 2_000;

export function createPinnedDispatcher(
  pinned: PinnedHostname,
  networkOptions?: DispatcherNetworkOptions,
): Dispatcher {
  return new Agent({
    connect: {
      lookup: pinned.lookup,
      autoSelectFamily: networkOptions?.autoSelectFamily ?? DEFAULT_AUTO_SELECT_FAMILY,
      autoSelectFamilyAttemptTimeout:
        networkOptions?.autoSelectFamilyAttemptTimeout ??
        DEFAULT_AUTO_SELECT_FAMILY_ATTEMPT_TIMEOUT,
    },
  });
}'''

if old not in content:
    print("    FAIL: #27044 ssrf.ts createPinnedDispatcher pattern not found", file=sys.stderr)
    sys.exit(1)

content = content.replace(old, new, 1)
with open(path, 'w') as f:
    f.write(content)
PYEOF

# 2) fetch-guard.ts: Add DispatcherNetworkOptions import + networkOptions param + forward
python3 - "$GUARD_FILE" << 'PYEOF'
import sys
path = sys.argv[1]
with open(path, 'r') as f:
    content = f.read()

# Add DispatcherNetworkOptions to import
old_import = '''  closeDispatcher,
  createPinnedDispatcher,
  resolvePinnedHostnameWithPolicy,'''

new_import = '''  closeDispatcher,
  createPinnedDispatcher,
  type DispatcherNetworkOptions,
  resolvePinnedHostnameWithPolicy,'''

if old_import not in content:
    print("    FAIL: #27044 fetch-guard.ts import pattern not found", file=sys.stderr)
    sys.exit(1)

content = content.replace(old_import, new_import, 1)

# Add networkOptions to GuardedFetchOptions type
old_opts = '  auditContext?: string;\n};'
new_opts = '  auditContext?: string;\n  /** Network-level options forwarded to the pinned undici dispatcher. */\n  networkOptions?: DispatcherNetworkOptions;\n};'

if old_opts not in content:
    print("    FAIL: #27044 fetch-guard.ts GuardedFetchOptions pattern not found", file=sys.stderr)
    sys.exit(1)

content = content.replace(old_opts, new_opts, 1)

# Forward networkOptions to createPinnedDispatcher
old_call = '        dispatcher = createPinnedDispatcher(pinned);'
new_call = '        dispatcher = createPinnedDispatcher(pinned, params.networkOptions);'

if old_call not in content:
    print("    FAIL: #27044 fetch-guard.ts createPinnedDispatcher call not found", file=sys.stderr)
    sys.exit(1)

content = content.replace(old_call, new_call, 1)

with open(path, 'w') as f:
    f.write(content)
PYEOF

# 3) telegram/fetch.ts: Use DEFAULT_AUTO_SELECT_FAMILY_ATTEMPT_TIMEOUT constant
python3 - "$FETCH_FILE" << 'PYEOF'
import sys
path = sys.argv[1]
with open(path, 'r') as f:
    content = f.read()

# Add import for the constant
old_import = 'import { resolveFetch } from "../infra/fetch.js";'
new_import = 'import { resolveFetch } from "../infra/fetch.js";\nimport { DEFAULT_AUTO_SELECT_FAMILY_ATTEMPT_TIMEOUT } from "../infra/net/ssrf.js";'

if old_import not in content:
    print("    FAIL: #27044 fetch.ts import pattern not found", file=sys.stderr)
    sys.exit(1)

content = content.replace(old_import, new_import, 1)

# Replace hardcoded 300 with constant
old_timeout = '            autoSelectFamilyAttemptTimeout: 300,'
new_timeout = '            autoSelectFamilyAttemptTimeout: DEFAULT_AUTO_SELECT_FAMILY_ATTEMPT_TIMEOUT,'

if old_timeout not in content:
    print("    FAIL: #27044 fetch.ts timeout pattern not found", file=sys.stderr)
    sys.exit(1)

content = content.replace(old_timeout, new_timeout, 1)

with open(path, 'w') as f:
    f.write(content)
PYEOF

echo "    OK: #27044 net config overrides for pinned dispatchers applied (3 files)"
