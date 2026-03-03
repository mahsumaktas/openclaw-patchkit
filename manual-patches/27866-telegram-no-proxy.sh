#!/usr/bin/env bash
set -euo pipefail
cd "$1"

PATCH_MARKER="PATCH_27866_TELEGRAM_NO_PROXY"

# ── File 1: src/telegram/proxy.ts ──
FILE="src/telegram/proxy.ts"
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

# The current proxy.ts is just a re-export:
#   export { makeProxyFetch } from "../infra/net/proxy-fetch.js";
# We need to keep the re-export and add the two new functions.

if 'export { makeProxyFetch } from "../infra/net/proxy-fetch.js";' not in content:
    print(f"WARN {file_path} — expected re-export not found, skipping")
    sys.exit(0)

new_content = '''export { makeProxyFetch } from "../infra/net/proxy-fetch.js";

// PATCH_27866_TELEGRAM_NO_PROXY
/**
 * Resolve proxy URL from standard environment variables.
 * Precedence: HTTPS_PROXY > HTTP_PROXY > ALL_PROXY (case-insensitive).
 */
export function resolveProxyUrlFromEnv(): string | undefined {
  const candidates = [
    process.env.HTTPS_PROXY,
    process.env.https_proxy,
    process.env.HTTP_PROXY,
    process.env.http_proxy,
    process.env.ALL_PROXY,
    process.env.all_proxy,
  ];
  for (const value of candidates) {
    const trimmed = value?.trim();
    if (trimmed) {
      return trimmed;
    }
  }
  return undefined;
}

type NoProxyEntry = { wildcard: true } | { wildcard: false; host: string; port: string | null };

function normalizeNoProxyEntry(value: string): NoProxyEntry | null {
  let normalized = value.trim().toLowerCase();
  if (!normalized) {
    return null;
  }
  if (normalized === "*") {
    return { wildcard: true };
  }
  normalized = normalized.replace(/^[a-z][a-z0-9+.-]*:\\/\\//i, "");
  normalized = normalized.split("/")[0] ?? normalized;

  let host = normalized;
  let port: string | null = null;
  if (normalized.startsWith("[")) {
    const end = normalized.indexOf("]");
    if (end > 0) {
      host = normalized.slice(1, end);
      const remainder = normalized.slice(end + 1);
      const portMatch = remainder.match(/^:(\\d+)$/);
      if (portMatch?.[1]) {
        port = portMatch[1];
      }
    }
  } else {
    const hostPortMatch = normalized.match(/^(.*):(\\d+)$/);
    if (hostPortMatch?.[1] && hostPortMatch[2]) {
      host = hostPortMatch[1];
      port = hostPortMatch[2];
    }
  }

  if (host.startsWith("*.")) {
    host = host.slice(2);
  }
  if (!host) {
    return null;
  }
  return { wildcard: false, host, port };
}

function resolveNoProxyEntries(noProxy?: string | string[]): NoProxyEntry[] {
  const raw =
    typeof noProxy === "undefined" ? (process.env.NO_PROXY ?? process.env.no_proxy ?? "") : noProxy;
  const list = Array.isArray(raw) ? raw : raw.split(",");
  return list.map(normalizeNoProxyEntry).filter((entry): entry is NoProxyEntry => entry !== null);
}

function resolveDefaultPort(protocol: string): string | null {
  switch (protocol.toLowerCase()) {
    case "http:":
    case "ws:":
      return "80";
    case "https:":
    case "wss:":
      return "443";
    default:
      return null;
  }
}

function normalizeHostnameForNoProxy(hostname: string): string {
  const trimmed = hostname.trim().toLowerCase();
  if (trimmed.startsWith("[") && trimmed.endsWith("]")) {
    return trimmed.slice(1, -1);
  }
  return trimmed;
}

/**
 * Return true when proxying should be bypassed for the given URL based on NO_PROXY.
 * Supports exact host entries, leading-dot/suffix domains, and wildcard (*).
 */
export function shouldBypassProxyForUrl(url: string, noProxy?: string | string[]): boolean {
  let hostname: string;
  let port: string | null;
  try {
    const parsed = new URL(url);
    hostname = normalizeHostnameForNoProxy(parsed.hostname);
    port = parsed.port || resolveDefaultPort(parsed.protocol);
  } catch {
    return false;
  }
  if (!hostname) {
    return false;
  }

  const entries = resolveNoProxyEntries(noProxy);
  for (const entry of entries) {
    if (entry.wildcard) {
      return true;
    }
    if (entry.port && port && entry.port !== port) {
      continue;
    }
    if (entry.host.startsWith(".")) {
      const suffix = entry.host.slice(1);
      if (suffix && (hostname === suffix || hostname.endsWith("." + suffix))) {
        return true;
      }
      continue;
    }
    if (hostname === entry.host || hostname.endsWith("." + entry.host)) {
      return true;
    }
  }
  return false;
}
'''

with open(file_path, "w") as f:
    f.write(new_content)

print(f"OK   {file_path}")
PYEOF
  fi
fi

# ── File 2: src/telegram/audit.ts ──
FILE="src/telegram/audit.ts"
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

# Replace the fetcher resolution block
old_fetcher = '''  // Lazy import to avoid pulling `undici` (ProxyAgent) into cold-path callers that only need
  // `collectTelegramUnmentionedGroupIds` (e.g. config audits).
  const fetcher = params.proxyUrl
    ? (await import("./proxy.js")).makeProxyFetch(params.proxyUrl)
    : fetch;'''

new_fetcher = '''  // Lazy import to avoid pulling `undici` (ProxyAgent) into cold-path callers that only need
  // `collectTelegramUnmentionedGroupIds` (e.g. config audits).
  const proxyModule = await import("./proxy.js"); // PATCH_27866_TELEGRAM_NO_PROXY
  const resolvedProxyUrl = params.proxyUrl?.trim() || proxyModule.resolveProxyUrlFromEnv();
  const shouldBypassProxy = proxyModule.shouldBypassProxyForUrl(TELEGRAM_API_BASE);
  const fetcher =
    resolvedProxyUrl && !shouldBypassProxy ? proxyModule.makeProxyFetch(resolvedProxyUrl) : fetch;'''

if old_fetcher not in content:
    print(f"WARN {file_path} — fetcher resolution block not found, skipping")
    sys.exit(0)

content = content.replace(old_fetcher, new_fetcher)

with open(file_path, "w") as f:
    f.write(content)

print(f"OK   {file_path}")
PYEOF
  fi
fi

# ── File 3: src/telegram/monitor.ts ──
FILE="src/telegram/monitor.ts"
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

# 1. Update the import to include resolveProxyUrlFromEnv and shouldBypassProxyForUrl
old_import = '''import { makeProxyFetch } from "./proxy.js";'''

new_import = '''import { makeProxyFetch, resolveProxyUrlFromEnv, shouldBypassProxyForUrl } from "./proxy.js"; // PATCH_27866_TELEGRAM_NO_PROXY'''

if old_import not in content:
    print(f"WARN {file_path} — proxy import not found, skipping")
    sys.exit(0)

content = content.replace(old_import, new_import)

# 2. Replace the proxyFetch resolution
old_proxy_fetch = '''    const proxyFetch =
      opts.proxyFetch ?? (account.config.proxy ? makeProxyFetch(account.config.proxy) : undefined);'''

new_proxy_fetch = '''    const resolvedProxyUrl = account.config.proxy?.trim() || resolveProxyUrlFromEnv(); // PATCH_27866_TELEGRAM_NO_PROXY
    const shouldBypassProxy = shouldBypassProxyForUrl("https://api.telegram.org");
    const proxyFetch =
      opts.proxyFetch ??
      (resolvedProxyUrl && !shouldBypassProxy ? makeProxyFetch(resolvedProxyUrl) : undefined);'''

if old_proxy_fetch not in content:
    print(f"WARN {file_path} — proxyFetch resolution block not found, skipping")
    sys.exit(0)

content = content.replace(old_proxy_fetch, new_proxy_fetch)

with open(file_path, "w") as f:
    f.write(content)

print(f"OK   {file_path}")
PYEOF
  fi
fi

# ── File 4: src/telegram/probe.ts ──
FILE="src/telegram/probe.ts"
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

# 1. Update the import
old_import = '''import { makeProxyFetch } from "./proxy.js";'''

new_import = '''import { makeProxyFetch, resolveProxyUrlFromEnv, shouldBypassProxyForUrl } from "./proxy.js"; // PATCH_27866_TELEGRAM_NO_PROXY'''

if old_import not in content:
    print(f"WARN {file_path} — proxy import not found, skipping")
    sys.exit(0)

content = content.replace(old_import, new_import)

# 2. Replace the fetcher resolution
old_fetcher = '''  const started = Date.now();
  const fetcher = proxyUrl ? makeProxyFetch(proxyUrl) : fetch;'''

new_fetcher = '''  const started = Date.now();
  const resolvedProxyUrl = proxyUrl?.trim() || resolveProxyUrlFromEnv(); // PATCH_27866_TELEGRAM_NO_PROXY
  const shouldBypassProxy = shouldBypassProxyForUrl(TELEGRAM_API_BASE);
  const fetcher = resolvedProxyUrl && !shouldBypassProxy ? makeProxyFetch(resolvedProxyUrl) : fetch;'''

if old_fetcher not in content:
    print(f"WARN {file_path} — fetcher resolution block not found, skipping")
    sys.exit(0)

content = content.replace(old_fetcher, new_fetcher)

with open(file_path, "w") as f:
    f.write(content)

print(f"OK   {file_path}")
PYEOF
  fi
fi

echo "DONE #27866 — honor NO_PROXY and env proxy precedence for Telegram"
