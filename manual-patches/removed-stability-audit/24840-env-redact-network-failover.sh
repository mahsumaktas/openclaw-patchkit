#!/usr/bin/env bash
# PR #24840: fix(config): redact env.vars + network failover + CLI cookie-url
#
# 3 independent change groups:
#   A. env.vars redaction — z.string().register(sensitive) on env.vars
#   B. Network failover — FailoverReason + error patterns + classify + status
#   C. CLI cookie-url — rename --url to --cookie-url in cookies set
#
# Source-only (tests skipped): 6 files, +153/-8 lines
set -euo pipefail
cd "$1"

# ── Idempotency gate ─────────────────────────────────────────────────────────
if grep -q 'isNetworkErrorMessage' src/agents/pi-embedded-helpers/errors.ts 2>/dev/null; then
  echo "SKIP: #24840 already applied (isNetworkErrorMessage found)"
  exit 0
fi

python3 << 'PYEOF'
import sys, re

errors = []

# ── Group A: env.vars redaction ──────────────────────────────────────────────
filepath = "src/config/zod-schema.ts"
try:
    with open(filepath, "r") as f:
        code = f.read()

    old = "vars: z.record(z.string(), z.string()).optional(),"
    new = "vars: z.record(z.string(), z.string().register(sensitive)).optional(),"

    if new in code:
        print("SKIP: #24840-A env.vars register(sensitive) already present")
    elif old in code:
        code = code.replace(old, new, 1)
        with open(filepath, "w") as f:
            f.write(code)
        print("OK: #24840-A env.vars register(sensitive) applied")
    else:
        errors.append(f"FAIL: #24840-A cannot find env.vars marker in {filepath}")
except Exception as e:
    errors.append(f"FAIL: #24840-A {filepath}: {e}")

# ── Group B1: FailoverReason union type ──────────────────────────────────────
filepath = "src/agents/pi-embedded-helpers/types.ts"
try:
    with open(filepath, "r") as f:
        code = f.read()

    if '"network"' in code:
        print("SKIP: #24840-B1 FailoverReason already has network")
    else:
        # Single-line format
        old_single = 'export type FailoverReason = "auth" | "format" | "rate_limit" | "billing" | "timeout" | "unknown";'
        new_multi = '''export type FailoverReason =
  | "auth"
  | "format"
  | "rate_limit"
  | "billing"
  | "timeout"
  | "network"
  | "unknown";'''

        if old_single in code:
            code = code.replace(old_single, new_multi, 1)
        elif '| "unknown"' in code:
            # Already multi-line, insert before unknown
            code = code.replace('  | "unknown";', '  | "network"\n  | "unknown";', 1)
        else:
            errors.append(f"FAIL: #24840-B1 cannot find FailoverReason in {filepath}")
            raise SystemExit

        with open(filepath, "w") as f:
            f.write(code)
        print("OK: #24840-B1 FailoverReason union updated")
except SystemExit:
    pass
except Exception as e:
    errors.append(f"FAIL: #24840-B1 {filepath}: {e}")

# ── Group B2: AuthProfileFailureReason ───────────────────────────────────────
filepath = "src/agents/auth-profiles/types.ts"
try:
    with open(filepath, "r") as f:
        code = f.read()

    if '"network"' in code:
        print("SKIP: #24840-B2 AuthProfileFailureReason already has network")
    elif '| "unknown";' in code:
        # Insert "network" before "unknown" — base may have extra entries like model_not_found
        code = code.replace(
            '  | "unknown";',
            '  | "network"\n  | "unknown";',
            1
        )
        with open(filepath, "w") as f:
            f.write(code)
        print("OK: #24840-B2 AuthProfileFailureReason updated")
    else:
        errors.append(f"FAIL: #24840-B2 cannot find unknown marker in {filepath}")
except Exception as e:
    errors.append(f"FAIL: #24840-B2 {filepath}: {e}")

# ── Group B3: resolveFailoverStatus + resolveFailoverReasonFromError ─────────
filepath = "src/agents/failover-error.ts"
try:
    with open(filepath, "r") as f:
        code = f.read()

    changed = False

    # Add network case to resolveFailoverStatus
    if 'case "network"' not in code:
        marker = '    case "format":\n      return 400;'
        insert = '    case "format":\n      return 400;\n    case "network":\n      return 503; // Service Unavailable - appropriate for network connectivity issues'
        if marker in code:
            code = code.replace(marker, insert, 1)
            changed = True
            print("OK: #24840-B3a resolveFailoverStatus network case added")
        else:
            errors.append(f"FAIL: #24840-B3a cannot find format/400 case in {filepath}")
    else:
        print("SKIP: #24840-B3a network case already present")

    # Add network error codes before timeout codes
    if "ENETUNREACH" not in code:
        marker = '  if (["ETIMEDOUT", "ESOCKETTIMEDOUT", "ECONNRESET", "ECONNABORTED"].includes(code)) {'
        insert = '''  // Network connectivity errors - trigger fallback to local models
  if (["ENETUNREACH", "EHOSTUNREACH", "ENOTFOUND", "EAI_AGAIN", "ECONNREFUSED"].includes(code)) {
    return "network";
  }
  ''' + marker
        if marker in code:
            code = code.replace(marker, insert, 1)
            changed = True
            print("OK: #24840-B3b network error codes added")
        else:
            errors.append(f"FAIL: #24840-B3b cannot find ETIMEDOUT marker in {filepath}")
    else:
        print("SKIP: #24840-B3b network error codes already present")

    if changed:
        with open(filepath, "w") as f:
            f.write(code)
except Exception as e:
    errors.append(f"FAIL: #24840-B3 {filepath}: {e}")

# ── Group B4: errors.ts — patterns + isNetworkErrorMessage + classify ────────
filepath = "src/agents/pi-embedded-helpers/errors.ts"
try:
    with open(filepath, "r") as f:
        code = f.read()

    changed = False

    # Add network patterns to ERROR_PATTERNS
    if "isNetworkErrorMessage" not in code:
        # Find end of ERROR_PATTERNS — insert before "} as const;"
        pattern_end = '} as const;'
        network_patterns = '''  network: [
    /\\benetunreach\\b/i,
    /\\behostunreach\\b/i,
    /\\benotfound\\b/i,
    /\\beai_again\\b/i,
    /\\beconnrefused\\b/i,
    /\\bnetwork\\s+(?:is\\s+)?unreachable\\b/i,
    /\\bconnection\\s+refused\\b/i,
    /\\bgetaddrinfo\\b/i,
    /\\bfetch\\s+failed\\b/i,
    /\\bno\\s+(?:network|internet)\\s+connection\\b/i,
    /\\bdns\\s+(?:lookup|resolution)\\s+failed\\b/i,
  ],
'''
        # Find the last entry before "} as const;" — insert network patterns
        # The last pattern block ends with "],\n} as const;"
        close_marker = '],\n} as const;'
        if close_marker in code:
            code = code.replace(close_marker, '],\n' + network_patterns + '} as const;', 1)
            changed = True
            print("OK: #24840-B4a network error patterns added")
        else:
            errors.append(f"FAIL: #24840-B4a cannot find ERROR_PATTERNS close in {filepath}")

        # Add isNetworkErrorMessage after isOverloadedErrorMessage
        func_marker = 'export function isOverloadedErrorMessage(raw: string): boolean {\n  return matchesErrorPatterns(raw, ERROR_PATTERNS.overloaded);\n}'
        if func_marker in code:
            code = code.replace(
                func_marker,
                func_marker + '\n\nexport function isNetworkErrorMessage(raw: string): boolean {\n  return matchesErrorPatterns(raw, ERROR_PATTERNS.network);\n}',
                1
            )
            changed = True
            print("OK: #24840-B4b isNetworkErrorMessage function added")
        else:
            errors.append(f"FAIL: #24840-B4b cannot find isOverloadedErrorMessage in {filepath}")

        # Add network to classifyFailoverReason — after timeout check
        timeout_classify = '  if (isTimeoutErrorMessage(raw)) {\n    return "timeout";\n  }'
        if timeout_classify in code:
            code = code.replace(
                timeout_classify,
                timeout_classify + '\n  if (isNetworkErrorMessage(raw)) {\n    return "network";\n  }',
                1
            )
            changed = True
            print("OK: #24840-B4c classifyFailoverReason network added")
        else:
            errors.append(f"FAIL: #24840-B4c cannot find timeout classify in {filepath}")

        if changed:
            with open(filepath, "w") as f:
                f.write(code)
    else:
        print("SKIP: #24840-B4 errors.ts already patched")
except Exception as e:
    errors.append(f"FAIL: #24840-B4 {filepath}: {e}")

# ── Group C: CLI cookie-url ──────────────────────────────────────────────────
filepath = "src/cli/browser-cli-state.cookies-storage.ts"
try:
    with open(filepath, "r") as f:
        code = f.read()

    changed = False

    if "--cookie-url" in code:
        print("SKIP: #24840-C cookie-url already applied")
    else:
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
            print("OK: #24840-C cookie-url rename applied")
        else:
            errors.append(f"FAIL: #24840-C cannot find --url patterns in {filepath}")
except Exception as e:
    errors.append(f"FAIL: #24840-C {filepath}: {e}")

# ── Final ────────────────────────────────────────────────────────────────────
if errors:
    for e in errors:
        print(e, file=sys.stderr)
    sys.exit(1)
else:
    print("OK: #24840 all 3 groups applied successfully")

PYEOF
