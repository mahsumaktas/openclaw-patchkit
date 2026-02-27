#!/usr/bin/env bash
# PR #24379 — fix(config): preserve env var refs during gateway startup config writes
# Adds ConfigWriteOptions type export, uses readConfigFileSnapshotForWrite in
# server.impl.ts and startup-auth.ts so ${VAR} references survive config writes.
set -euo pipefail
SRC="${1:-.}/src"

CONFIG_FILE="$SRC/config/config.ts"
SERVER_FILE="$SRC/gateway/server.impl.ts"
AUTH_FILE="$SRC/gateway/startup-auth.ts"

# Idempotency check
if grep -q 'ConfigWriteOptions' "$CONFIG_FILE" 2>/dev/null; then
  echo "    SKIP: #24379 already applied"
  exit 0
fi

# 1) Add ConfigWriteOptions type re-export to config/config.ts
python3 - "$CONFIG_FILE" << 'PYEOF'
import sys
path = sys.argv[1]
with open(path, 'r') as f:
    content = f.read()

old = '} from "./io.js";\nexport { migrateLegacyConfig }'
new = '} from "./io.js";\nexport type { ConfigWriteOptions } from "./io.js";\nexport { migrateLegacyConfig }'

if old not in content:
    print("    FAIL: #24379 config.ts pattern not found", file=sys.stderr)
    sys.exit(1)

content = content.replace(old, new, 1)
with open(path, 'w') as f:
    f.write(content)
PYEOF

# 2) Update server.impl.ts imports: add readConfigFileSnapshotForWrite
python3 - "$SERVER_FILE" << 'PYEOF'
import sys
path = sys.argv[1]
with open(path, 'r') as f:
    content = f.read()

# Add readConfigFileSnapshotForWrite to import block
old_import = '  readConfigFileSnapshot,\n  writeConfigFile,'
new_import = '  readConfigFileSnapshot,\n  readConfigFileSnapshotForWrite,\n  writeConfigFile,'

if old_import not in content:
    print("    FAIL: #24379 server.impl.ts import pattern not found", file=sys.stderr)
    sys.exit(1)

content = content.replace(old_import, new_import, 1)

# 3) Replace first readConfigFileSnapshot() call with readConfigFileSnapshotForWrite()
old1 = '  let configSnapshot = await readConfigFileSnapshot();\n  if (configSnapshot.legacyIssues.length > 0) {'
new1 = '  let configRead = await readConfigFileSnapshotForWrite();\n  let configSnapshot = configRead.snapshot;\n  if (configSnapshot.legacyIssues.length > 0) {'

if old1 not in content:
    print("    FAIL: #24379 server.impl.ts first readConfigFileSnapshot pattern not found", file=sys.stderr)
    sys.exit(1)

content = content.replace(old1, new1, 1)

# 4) Pass writeOptions to first writeConfigFile (legacy migration)
old2 = '    await writeConfigFile(migrated);\n    if (changes.length > 0) {'
new2 = '    await writeConfigFile(migrated, configRead.writeOptions);\n    if (changes.length > 0) {'

if old2 not in content:
    print("    FAIL: #24379 server.impl.ts writeConfigFile(migrated) pattern not found", file=sys.stderr)
    sys.exit(1)

content = content.replace(old2, new2, 1)

# 5) Replace second readConfigFileSnapshot() call
old3 = '  configSnapshot = await readConfigFileSnapshot();\n  if (configSnapshot.exists && !configSnapshot.valid) {'
new3 = '  configRead = await readConfigFileSnapshotForWrite();\n  configSnapshot = configRead.snapshot;\n  if (configSnapshot.exists && !configSnapshot.valid) {'

if old3 not in content:
    print("    FAIL: #24379 server.impl.ts second readConfigFileSnapshot pattern not found", file=sys.stderr)
    sys.exit(1)

content = content.replace(old3, new3, 1)

# 6) Pass writeOptions to autoEnable writeConfigFile
old4 = '      await writeConfigFile(autoEnable.config);\n      log.info('
new4 = '      await writeConfigFile(autoEnable.config, configRead.writeOptions);\n      log.info('

if old4 not in content:
    print("    FAIL: #24379 server.impl.ts writeConfigFile(autoEnable) pattern not found", file=sys.stderr)
    sys.exit(1)

content = content.replace(old4, new4, 1)

# 7) Add authConfigRead before ensureGatewayStartupAuth
old5 = '  cfgAtStart = loadConfig();\n  const authBootstrap = await ensureGatewayStartupAuth({\n    cfg: cfgAtStart,\n    env: process.env,\n    authOverride: opts.auth,\n    tailscaleOverride: opts.tailscale,\n    persist: true,\n  });'
new5 = '  const authConfigRead = await readConfigFileSnapshotForWrite();\n  cfgAtStart = loadConfig();\n  const authBootstrap = await ensureGatewayStartupAuth({\n    cfg: cfgAtStart,\n    env: process.env,\n    authOverride: opts.auth,\n    tailscaleOverride: opts.tailscale,\n    persist: true,\n    configWriteOptions: authConfigRead.writeOptions,\n  });'

if old5 not in content:
    print("    FAIL: #24379 server.impl.ts ensureGatewayStartupAuth pattern not found", file=sys.stderr)
    sys.exit(1)

content = content.replace(old5, new5, 1)

with open(path, 'w') as f:
    f.write(content)
PYEOF

# 8) Update startup-auth.ts: add ConfigWriteOptions import + param + usage
python3 - "$AUTH_FILE" << 'PYEOF'
import sys
path = sys.argv[1]
with open(path, 'r') as f:
    content = f.read()

# Add ConfigWriteOptions to import
old_import = 'import type {\n  GatewayAuthConfig,\n  GatewayTailscaleConfig,\n  OpenClawConfig,\n} from "../config/config.js";'
new_import = 'import type {\n  ConfigWriteOptions,\n  GatewayAuthConfig,\n  GatewayTailscaleConfig,\n  OpenClawConfig,\n} from "../config/config.js";'

if old_import not in content:
    print("    FAIL: #24379 startup-auth.ts import pattern not found", file=sys.stderr)
    sys.exit(1)

content = content.replace(old_import, new_import, 1)

# Add configWriteOptions param to ensureGatewayStartupAuth
old_params = '  persist?: boolean;\n}): Promise<{'
new_params = '  persist?: boolean;\n  configWriteOptions?: ConfigWriteOptions;\n}): Promise<{'

if old_params not in content:
    print("    FAIL: #24379 startup-auth.ts persist param pattern not found", file=sys.stderr)
    sys.exit(1)

content = content.replace(old_params, new_params, 1)

# Pass configWriteOptions to writeConfigFile
old_write = '    await writeConfigFile(nextCfg);\n  }'
new_write = '    await writeConfigFile(nextCfg, params.configWriteOptions ?? {});\n  }'

if old_write not in content:
    print("    FAIL: #24379 startup-auth.ts writeConfigFile pattern not found", file=sys.stderr)
    sys.exit(1)

content = content.replace(old_write, new_write, 1)

with open(path, 'w') as f:
    f.write(content)
PYEOF

echo "    OK: #24379 env var preserve config writes applied (3 files)"
