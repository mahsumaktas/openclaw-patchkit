#!/usr/bin/env bash
# PR #35114 — fix: validate tailscale/bind compatibility at config-write time
#
# When gateway.tailscale.mode is "serve" or "funnel", gateway.bind must be
# "loopback" (or custom with a loopback IP). Without this validation the
# gateway enters an unrecoverable crash loop on next restart.
#
# Three-part patch:
#   1. Add isLoopbackHost import to config.ts
#   2. Add validateTailscaleBindCompat() function before configHandlers
#   3. Insert validation calls in config.set, config.patch, config.apply handlers
#
# See: https://github.com/openclaw/openclaw/pull/35114
set -euo pipefail

WORKDIR="${1:-$(ls -d /tmp/openclaw-patch-build-* 2>/dev/null | head -1)}"
if [ -z "$WORKDIR" ] || [ ! -d "$WORKDIR" ]; then
  echo "FAIL: No build workspace found"
  exit 1
fi

FILE="$WORKDIR/src/gateway/server-methods/config.ts"

if [ ! -f "$FILE" ]; then
  echo "FAIL: $FILE not found"
  exit 1
fi

# ── Idempotency check ──
if grep -q 'validateTailscaleBindCompat' "$FILE" 2>/dev/null; then
  echo "SKIP: #35114 already applied (validateTailscaleBindCompat present)"
  exit 0
fi

python3 - "$FILE" << 'PYEOF'
import sys

path = sys.argv[1]
with open(path, "r") as f:
    content = f.read()

if "validateTailscaleBindCompat" in content:
    print("SKIP: #35114 already applied")
    sys.exit(0)

changed = False

# ── Part 1: Add isLoopbackHost import ──
# Insert after the first import line (import { exec } from "node:child_process";)
import_anchor = 'import { exec } from "node:child_process";'
import_line = 'import { isLoopbackHost } from "../net.js";'

if import_anchor in content and "isLoopbackHost" not in content:
    # Insert after the resolveAgentWorkspaceDir import line
    agent_import = 'import { resolveAgentWorkspaceDir, resolveDefaultAgentId } from "../../agents/agent-scope.js";'
    if agent_import in content:
        content = content.replace(
            agent_import,
            agent_import + "\n" + import_line,
            1,
        )
        changed = True
        print("OK: #35114 added isLoopbackHost import")
    else:
        print("FAIL: #35114 cannot find agent-scope import for anchor", file=sys.stderr)
        sys.exit(1)

# ── Part 2: Add validateTailscaleBindCompat function ──
# Insert before "export const configHandlers"
func_anchor = "export const configHandlers: GatewayRequestHandlers = {"

validate_func = '''/**
 * Validate that gateway.tailscale.mode and gateway.bind are compatible.
 * When tailscale mode is "serve" or "funnel", bind must be "loopback" (or unset,
 * which defaults to "loopback"). Rejecting at config-write time prevents the
 * gateway from entering an unrecoverable crash loop on next restart.
 */
export function validateTailscaleBindCompat(config: OpenClawConfig): string | null {
  const tailscaleMode = config.gateway?.tailscale?.mode;
  if (tailscaleMode !== "serve" && tailscaleMode !== "funnel") {
    return null;
  }
  const bind = config.gateway?.bind ?? "loopback";
  if (bind === "loopback") {
    return null;
  }
  // A custom bind with a loopback IP is equivalent to bind=loopback at runtime
  // (server-runtime-config.ts uses isLoopbackHost on the resolved IP). Allow it
  // at write-time too so we don't reject a valid config.
  if (bind === "custom") {
    const customBindHost = config.gateway?.customBindHost?.trim();
    if (customBindHost && isLoopbackHost(customBindHost)) {
      return null;
    }
  }
  return `gateway.tailscale.mode="${tailscaleMode}" requires gateway.bind="loopback", but gateway.bind="${bind}". Change gateway.bind to "loopback" or set gateway.tailscale.mode to "off".`;
}

'''

if func_anchor in content:
    content = content.replace(func_anchor, validate_func + func_anchor, 1)
    changed = True
    print("OK: #35114 added validateTailscaleBindCompat function")
else:
    print("FAIL: #35114 cannot find configHandlers export", file=sys.stderr)
    sys.exit(1)

# ── Part 3a: Insert validation in config.set ──
# After: if (!parsed) { return; }
# Before: await writeConfigFile(parsed.config, writeOptions);
# in config.set handler
set_anchor = '''    const parsed = parseValidateConfigFromRawOrRespond(params, "config.set", snapshot, respond);
    if (!parsed) {
      return;
    }
    await writeConfigFile(parsed.config, writeOptions);'''

set_replacement = '''    const parsed = parseValidateConfigFromRawOrRespond(params, "config.set", snapshot, respond);
    if (!parsed) {
      return;
    }
    const compatError = validateTailscaleBindCompat(parsed.config);
    if (compatError) {
      respond(false, undefined, errorShape(ErrorCodes.INVALID_REQUEST, compatError));
      return;
    }
    await writeConfigFile(parsed.config, writeOptions);'''

if set_anchor in content:
    content = content.replace(set_anchor, set_replacement, 1)
    changed = True
    print("OK: #35114 added validation in config.set")
else:
    print("WARN: #35114 could not find config.set insertion point — may need manual check")

# ── Part 3b: Insert validation in config.patch ──
# After: validated = validateConfigObjectWithPlugins(resolved)
# Before: const changedPaths = diffConfigPaths(snapshot.config, validated.config);
# Look for the unique pattern in config.patch
patch_anchor = '''      return;
    }
    const changedPaths = diffConfigPaths(snapshot.config, validated.config);
    const actor = resolveControlPlaneActor(client);
    context?.logGateway?.info(
      `config.patch write'''

patch_replacement = '''      return;
    }
    const patchCompatError = validateTailscaleBindCompat(validated.config);
    if (patchCompatError) {
      respond(false, undefined, errorShape(ErrorCodes.INVALID_REQUEST, patchCompatError));
      return;
    }
    const changedPaths = diffConfigPaths(snapshot.config, validated.config);
    const actor = resolveControlPlaneActor(client);
    context?.logGateway?.info(
      `config.patch write'''

if patch_anchor in content:
    content = content.replace(patch_anchor, patch_replacement, 1)
    changed = True
    print("OK: #35114 added validation in config.patch")
else:
    print("WARN: #35114 could not find config.patch insertion point — may need manual check")

# ── Part 3c: Insert validation in config.apply ──
# After: if (!parsed) { return; }
# Before: const changedPaths = diffConfigPaths(snapshot.config, parsed.config);
# in config.apply handler
apply_anchor = '''    const parsed = parseValidateConfigFromRawOrRespond(params, "config.apply", snapshot, respond);
    if (!parsed) {
      return;
    }
    const changedPaths = diffConfigPaths(snapshot.config, parsed.config);
    const actor = resolveControlPlaneActor(client);
    context?.logGateway?.info(
      `config.apply write'''

apply_replacement = '''    const parsed = parseValidateConfigFromRawOrRespond(params, "config.apply", snapshot, respond);
    if (!parsed) {
      return;
    }
    const applyCompatError = validateTailscaleBindCompat(parsed.config);
    if (applyCompatError) {
      respond(false, undefined, errorShape(ErrorCodes.INVALID_REQUEST, applyCompatError));
      return;
    }
    const changedPaths = diffConfigPaths(snapshot.config, parsed.config);
    const actor = resolveControlPlaneActor(client);
    context?.logGateway?.info(
      `config.apply write'''

if apply_anchor in content:
    content = content.replace(apply_anchor, apply_replacement, 1)
    changed = True
    print("OK: #35114 added validation in config.apply")
else:
    print("WARN: #35114 could not find config.apply insertion point — may need manual check")

if changed:
    with open(path, "w") as f:
        f.write(content)
    print("OK: #35114 tailscale-bind validation fully applied")
else:
    print("FAIL: #35114 no changes made", file=sys.stderr)
    sys.exit(1)
PYEOF

echo "OK: #35114 tailscale-bind-validation applied"
