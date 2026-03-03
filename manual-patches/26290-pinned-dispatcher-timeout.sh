#!/usr/bin/env bash
set -euo pipefail
cd "$1"

PATCH_MARKER="PATCH_26290_PINNED_DISPATCHER_TIMEOUT"

# ── File 1: src/infra/net/ssrf.ts ──
FILE="src/infra/net/ssrf.ts"
if [[ ! -f "$FILE" ]]; then
  echo "SKIP $FILE — not found"
else
  if grep -q "$PATCH_MARKER" "$FILE" 2>/dev/null; then
    echo "SKIP $FILE — already patched"
  else
    python3 - "$FILE" << 'PYEOF'
import sys

file_path = sys.argv[1]
with open(file_path, "r") as f:
    content = f.read()

# Replace createPinnedDispatcher to accept options and add timeout constants
old_fn = '''export function createPinnedDispatcher(pinned: PinnedHostname): Dispatcher {
  return new Agent({
    connect: {
      lookup: pinned.lookup,
    },
  });
}'''

new_fn = '''// PATCH_26290_PINNED_DISPATCHER_TIMEOUT
// Keep the default path close to Node/undici defaults for fast networks.
export const PINNED_AUTO_SELECT_FAMILY_PRIMARY_TIMEOUT_MS = 300;
// Use a relaxed timeout only for targeted retry paths on slow networks.
export const PINNED_AUTO_SELECT_FAMILY_FALLBACK_TIMEOUT_MS = 2500;

type CreatePinnedDispatcherOptions = {
  autoSelectFamilyAttemptTimeoutMs?: number;
};

export function createPinnedDispatcher(
  pinned: PinnedHostname,
  options: CreatePinnedDispatcherOptions = {},
): Dispatcher {
  const autoSelectFamilyAttemptTimeoutMs =
    typeof options.autoSelectFamilyAttemptTimeoutMs === "number" &&
    Number.isFinite(options.autoSelectFamilyAttemptTimeoutMs) &&
    options.autoSelectFamilyAttemptTimeoutMs > 0
      ? Math.floor(options.autoSelectFamilyAttemptTimeoutMs)
      : PINNED_AUTO_SELECT_FAMILY_PRIMARY_TIMEOUT_MS;

  return new Agent({
    connect: {
      lookup: pinned.lookup,
      autoSelectFamily: true,
      autoSelectFamilyAttemptTimeout: autoSelectFamilyAttemptTimeoutMs,
    },
  });
}'''

if old_fn not in content:
    print(f"WARN {file_path} — createPinnedDispatcher block not found, skipping")
    sys.exit(0)

content = content.replace(old_fn, new_fn)

with open(file_path, "w") as f:
    f.write(content)

print(f"OK   {file_path}")
PYEOF
  fi
fi

# ── File 2: src/infra/net/fetch-guard.ts ──
FILE="src/infra/net/fetch-guard.ts"
if [[ ! -f "$FILE" ]]; then
  echo "SKIP $FILE — not found"
else
  if grep -q "$PATCH_MARKER" "$FILE" 2>/dev/null; then
    echo "SKIP $FILE — already patched"
  else
    python3 - "$FILE" << 'PYEOF'
import sys

file_path = sys.argv[1]
with open(file_path, "r") as f:
    content = f.read()

# 1. Add PINNED_AUTO_SELECT_FAMILY_FALLBACK_TIMEOUT_MS to the import
old_import = '''import {
  closeDispatcher,
  createPinnedDispatcher,
  resolvePinnedHostnameWithPolicy,
  type LookupFn,
  SsrFBlockedError,
  type SsrFPolicy,
} from "./ssrf.js";'''

new_import = '''import {
  closeDispatcher,
  createPinnedDispatcher,
  PINNED_AUTO_SELECT_FAMILY_FALLBACK_TIMEOUT_MS, // PATCH_26290_PINNED_DISPATCHER_TIMEOUT
  resolvePinnedHostnameWithPolicy,
  type LookupFn,
  SsrFBlockedError,
  type SsrFPolicy,
} from "./ssrf.js";'''

if old_import not in content:
    print(f"WARN {file_path} — ssrf import block not found, skipping")
    sys.exit(0)

content = content.replace(old_import, new_import)

# 2. Add helper constants and functions after the stripSensitiveHeaders function
old_after_strip = '''function stripSensitiveHeadersForCrossOriginRedirect(init?: RequestInit): RequestInit | undefined {
  if (!init?.headers) {
    return init;
  }
  const headers = new Headers(init.headers);
  for (const header of CROSS_ORIGIN_REDIRECT_SENSITIVE_HEADERS) {
    headers.delete(header);
  }
  return { ...init, headers };
}

function buildAbortSignal'''

new_after_strip = '''function stripSensitiveHeadersForCrossOriginRedirect(init?: RequestInit): RequestInit | undefined {
  if (!init?.headers) {
    return init;
  }
  const headers = new Headers(init.headers);
  for (const header of CROSS_ORIGIN_REDIRECT_SENSITIVE_HEADERS) {
    headers.delete(header);
  }
  return { ...init, headers };
}

const RETRYABLE_METHODS_FOR_FAMILY_TIMEOUT = new Set(["GET", "HEAD"]);
const RETRYABLE_FAMILY_ERROR_CODES = new Set(["ETIMEDOUT", "ENETUNREACH", "EHOSTUNREACH"]);

function resolveRequestMethod(init?: RequestInit): string {
  if (typeof init?.method !== "string") {
    return "GET";
  }
  const normalized = init.method.trim().toUpperCase();
  return normalized.length > 0 ? normalized : "GET";
}

function hasDualStackAddresses(addresses: readonly string[]): boolean {
  let sawIpv4 = false;
  let sawIpv6 = false;
  for (const address of addresses) {
    if (address.includes(":")) {
      sawIpv6 = true;
    } else {
      sawIpv4 = true;
    }
    if (sawIpv4 && sawIpv6) {
      return true;
    }
  }
  return false;
}

function readErrnoCode(error: unknown): string | undefined {
  if (!error || typeof error !== "object") {
    return undefined;
  }
  const maybeWithCode = error as { code?: unknown; cause?: unknown };
  if (typeof maybeWithCode.code === "string") {
    return maybeWithCode.code;
  }
  if (maybeWithCode.cause && maybeWithCode.cause !== error) {
    return readErrnoCode(maybeWithCode.cause);
  }
  return undefined;
}

function isRetryableFamilyTimeoutError(error: unknown): boolean {
  const code = readErrnoCode(error);
  return typeof code === "string" && RETRYABLE_FAMILY_ERROR_CODES.has(code);
}

function buildAbortSignal'''

if old_after_strip not in content:
    print(f"WARN {file_path} — stripSensitiveHeaders + buildAbortSignal anchor not found, skipping")
    sys.exit(0)

content = content.replace(old_after_strip, new_after_strip)

# 3. Replace the fetch logic inside the while loop — the pinned DNS + fetch section
old_fetch_logic = '''      const canUseTrustedEnvProxy =
        mode === GUARDED_FETCH_MODE.TRUSTED_ENV_PROXY && hasProxyEnvConfigured();
      if (canUseTrustedEnvProxy) {
        dispatcher = new EnvHttpProxyAgent();
      } else if (params.pinDns !== false) {
        dispatcher = createPinnedDispatcher(pinned);
      }

      const init: RequestInit & { dispatcher?: Dispatcher } = {
        ...(currentInit ? { ...currentInit } : {}),
        redirect: "manual",
        ...(dispatcher ? { dispatcher } : {}),
        ...(signal ? { signal } : {}),
      };

      const response = await fetcher(parsedUrl.toString(), init);'''

new_fetch_logic = '''      const canUseTrustedEnvProxy =
        mode === GUARDED_FETCH_MODE.TRUSTED_ENV_PROXY && hasProxyEnvConfigured();
      if (canUseTrustedEnvProxy) {
        dispatcher = new EnvHttpProxyAgent();
        const init: RequestInit & { dispatcher?: Dispatcher } = {
          ...(currentInit ? { ...currentInit } : {}),
          redirect: "manual",
          ...(dispatcher ? { dispatcher } : {}),
          ...(signal ? { signal } : {}),
        };
        var response = await fetcher(parsedUrl.toString(), init);
      } else {
        const requestMethod = resolveRequestMethod(currentInit);
        const baseInit: RequestInit = {
          ...(currentInit ? { ...currentInit } : {}),
          redirect: "manual",
          ...(signal ? { signal } : {}),
        };
        const runFetchAttempt = async (
          autoSelectFamilyAttemptTimeoutMs?: number,
        ): Promise<{ response: Response; dispatcher: Dispatcher | null }> => {
          const attemptDispatcher =
            params.pinDns === false
              ? null
              : typeof autoSelectFamilyAttemptTimeoutMs === "number"
                ? createPinnedDispatcher(pinned, {
                    autoSelectFamilyAttemptTimeoutMs,
                  })
                : createPinnedDispatcher(pinned);
          const init: RequestInit & { dispatcher?: Dispatcher } = {
            ...baseInit,
            ...(attemptDispatcher ? { dispatcher: attemptDispatcher } : {}),
          };
          try {
            const response = await fetcher(parsedUrl.toString(), init);
            return { response, dispatcher: attemptDispatcher };
          } catch (attemptError) {
            await closeDispatcher(attemptDispatcher);
            throw attemptError;
          }
        };

        try {
          const primaryAttempt = await runFetchAttempt();
          var response = primaryAttempt.response;
          dispatcher = primaryAttempt.dispatcher;
        } catch (primaryError) {
          const shouldRetryWithRelaxedFamilyTimeout =
            params.pinDns !== false &&
            RETRYABLE_METHODS_FOR_FAMILY_TIMEOUT.has(requestMethod) &&
            hasDualStackAddresses(pinned.addresses) &&
            isRetryableFamilyTimeoutError(primaryError);
          if (!shouldRetryWithRelaxedFamilyTimeout) {
            throw primaryError;
          }
          const retryAttempt = await runFetchAttempt(PINNED_AUTO_SELECT_FAMILY_FALLBACK_TIMEOUT_MS);
          var response = retryAttempt.response;
          dispatcher = retryAttempt.dispatcher;
        }
      }'''

if old_fetch_logic not in content:
    print(f"WARN {file_path} — fetch logic block not found, skipping")
    sys.exit(0)

content = content.replace(old_fetch_logic, new_fetch_logic)

with open(file_path, "w") as f:
    f.write(content)

print(f"OK   {file_path}")
PYEOF
  fi
fi

# ── File 3: src/telegram/fetch.ts ──
FILE="src/telegram/fetch.ts"
if [[ ! -f "$FILE" ]]; then
  echo "SKIP $FILE — not found"
else
  if grep -q "$PATCH_MARKER" "$FILE" 2>/dev/null; then
    echo "SKIP $FILE — already patched"
  else
    python3 - "$FILE" << 'PYEOF'
import sys

file_path = sys.argv[1]
with open(file_path, "r") as f:
    content = f.read()

# 1. Add import for PINNED_AUTO_SELECT_FAMILY_FALLBACK_TIMEOUT_MS
old_import = '''import { resolveFetch } from "../infra/fetch.js";
import { hasProxyEnvConfigured } from "../infra/net/proxy-env.js";'''

new_import = '''import { resolveFetch } from "../infra/fetch.js";
import { PINNED_AUTO_SELECT_FAMILY_FALLBACK_TIMEOUT_MS } from "../infra/net/ssrf.js"; // PATCH_26290_PINNED_DISPATCHER_TIMEOUT
import { hasProxyEnvConfigured } from "../infra/net/proxy-env.js";'''

if old_import not in content:
    print(f"WARN {file_path} — import block not found, skipping")
    sys.exit(0)

content = content.replace(old_import, new_import)

# 2. Replace the hardcoded 300 timeout with the constant
old_timeout = '''            autoSelectFamilyAttemptTimeout: 300,'''

new_timeout = '''            autoSelectFamilyAttemptTimeout: PINNED_AUTO_SELECT_FAMILY_FALLBACK_TIMEOUT_MS,'''

if old_timeout not in content:
    print(f"WARN {file_path} — autoSelectFamilyAttemptTimeout: 300 not found, skipping")
    sys.exit(0)

content = content.replace(old_timeout, new_timeout)

with open(file_path, "w") as f:
    f.write(content)

print(f"OK   {file_path}")
PYEOF
  fi
fi

echo "DONE #26290 — pinned dispatcher timeout 300ms -> 2500ms with dual-stack retry"
