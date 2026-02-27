#!/usr/bin/env bash
# PR #28291 — fix(daemon): forward NODE_EXTRA_CA_CERTS + NODE_USE_SYSTEM_CA
# Manual patch: v2026.2.26 base has no NODE_EXTRA_CA_CERTS in service-env.ts
# Adds dedicated readServiceTlsEnvironment() function + spreads into both build*Environment returns
set -euo pipefail
cd "$1"

FILE="src/daemon/service-env.ts"
if ! [ -f "$FILE" ]; then echo "SKIP: $FILE not found"; exit 0; fi
if grep -q 'NODE_USE_SYSTEM_CA' "$FILE"; then echo "SKIP: #28291 already applied"; exit 0; fi

python3 - "$FILE" << 'PYEOF'
import sys

with open(sys.argv[1], "r") as f:
    content = f.read()

# Step 1: Add SERVICE_TLS_ENV_KEYS const after SERVICE_PROXY_ENV_KEYS block
marker = '] as const;\n\nfunction readServiceProxyEnvironment('
if marker not in content:
    print("ERROR: cannot find SERVICE_PROXY_ENV_KEYS end marker")
    sys.exit(1)

tls_const = '''] as const;

const SERVICE_TLS_ENV_KEYS = ["NODE_EXTRA_CA_CERTS", "NODE_USE_SYSTEM_CA"] as const;

function readServiceProxyEnvironment('''
content = content.replace(marker, tls_const, 1)

# Step 2: Add readServiceTlsEnvironment function after readServiceProxyEnvironment
proxy_fn_end = '  return out;\n}\n\nfunction addNonEmptyDir('
tls_fn = '''  return out;
}

function readServiceTlsEnvironment(
  env: Record<string, string | undefined>,
  platform: NodeJS.Platform,
): Record<string, string | undefined> {
  const out: Record<string, string | undefined> = {};
  for (const key of SERVICE_TLS_ENV_KEYS) {
    const value = env[key];
    if (typeof value !== "string") {
      continue;
    }
    const trimmed = value.trim();
    if (!trimmed) {
      continue;
    }
    out[key] = trimmed;
  }

  // On macOS, launchd services don't inherit the shell environment, so Node's undici/fetch
  // cannot locate the system CA bundle. Default to /etc/ssl/cert.pem so TLS verification
  // works correctly when running as a LaunchAgent without extra user configuration.
  if (!out.NODE_EXTRA_CA_CERTS && platform === "darwin") {
    out.NODE_EXTRA_CA_CERTS = "/etc/ssl/cert.pem";
  }

  return out;
}

function addNonEmptyDir('''
content = content.replace(proxy_fn_end, tls_fn, 1)

# Step 3: Add tlsEnv to buildServiceEnvironment (first proxyEnv occurrence)
pattern = 'const proxyEnv = readServiceProxyEnvironment(env);\n  return {\n    HOME: env.HOME,\n    TMPDIR: tmpDir,\n    PATH: buildMinimalServicePath({ env }),\n    ...proxyEnv,'
replace = 'const proxyEnv = readServiceProxyEnvironment(env);\n  const tlsEnv = readServiceTlsEnvironment(env, platform);\n  return {\n    HOME: env.HOME,\n    TMPDIR: tmpDir,\n    PATH: buildMinimalServicePath({ env }),\n    ...proxyEnv,\n    ...tlsEnv,'

if pattern not in content:
    print("ERROR: cannot find first proxyEnv return block")
    sys.exit(1)
content = content.replace(pattern, replace, 1)

# Step 4: Same for buildNodeServiceEnvironment (second occurrence)
if pattern in content:
    content = content.replace(pattern, replace, 1)
else:
    # Second block uses OPENCLAW_STATE_DIR directly after proxyEnv
    alt = 'const proxyEnv = readServiceProxyEnvironment(env);\n  return {\n    HOME: env.HOME,\n    TMPDIR: tmpDir,\n    PATH: buildMinimalServicePath({ env }),\n    ...proxyEnv,\n    OPENCLAW_STATE_DIR: stateDir,'
    alt_r = 'const proxyEnv = readServiceProxyEnvironment(env);\n  const tlsEnv = readServiceTlsEnvironment(env, platform);\n  return {\n    HOME: env.HOME,\n    TMPDIR: tmpDir,\n    PATH: buildMinimalServicePath({ env }),\n    ...proxyEnv,\n    ...tlsEnv,\n    OPENCLAW_STATE_DIR: stateDir,'
    if alt in content:
        content = content.replace(alt, alt_r, 1)
    else:
        print("ERROR: cannot find second proxyEnv return block")
        sys.exit(1)

with open(sys.argv[1], "w") as f:
    f.write(content)

print("OK: #28291 applied — NODE_EXTRA_CA_CERTS + NODE_USE_SYSTEM_CA forwarding")
PYEOF
