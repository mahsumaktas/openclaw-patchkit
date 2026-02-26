#!/usr/bin/env bash
# Issue #26435: fix(update): reload LaunchAgent after openclaw update completes
#
# After `openclaw update` (npm update), the LaunchAgent plist is NOT reloaded.
# The old binary/version continues running until the user manually restarts.
# This causes up to 6 hours of downtime (until user notices).
#
# Fix: In maybeRestartService(), after refreshGatewayServiceEnv fails or before
# using the restart script, perform an explicit bootout + bootstrap cycle to
# ensure the LaunchAgent picks up the new binary/plist. Also add a fallback
# reloadLaunchAgentAfterUpdate() in launchd.ts that handles the full reload
# sequence with proper error handling.
#
# Changes:
#   1. src/daemon/launchd.ts — add reloadLaunchAgentAfterUpdate() export
#   2. src/cli/update-cli/update-command.ts — import + call reload in maybeRestartService
set -euo pipefail

SRC="${1:-.}/src"

# ── Idempotency check ──────────────────────────────────────────────────────
if grep -q 'reloadLaunchAgentAfterUpdate' "$SRC/daemon/launchd.ts" 2>/dev/null; then
  echo "    SKIP: #26435 already applied"
  exit 0
fi

# ── 1. src/daemon/launchd.ts — add reloadLaunchAgentAfterUpdate() ─────────
python3 - "$SRC/daemon/launchd.ts" << 'PYEOF'
import sys

filepath = sys.argv[1]
with open(filepath, "r") as f:
    code = f.read()

# Insert the new function before the restartLaunchAgent export.
# This function performs bootout + bootstrap + kickstart as a full reload cycle,
# which ensures the LaunchAgent picks up any new plist or binary changes.
marker = "export async function restartLaunchAgent({"
if marker not in code:
    print("    FAIL: #26435 restartLaunchAgent marker not found in launchd.ts", file=sys.stderr)
    sys.exit(1)

new_fn = '''/**
 * Full LaunchAgent reload cycle for post-update scenarios.
 *
 * Unlike restartLaunchAgent (which only does kickstart -k), this performs
 * bootout + bootstrap + kickstart to ensure the LaunchAgent picks up any
 * new plist changes (updated binary path, environment, etc.) after an
 * `openclaw update`.
 *
 * Errors are caught and returned as a result object rather than thrown,
 * so callers can log warnings without crashing the update flow.
 */
export async function reloadLaunchAgentAfterUpdate(args: {
  env?: Record<string, string | undefined>;
}): Promise<{ ok: boolean; detail?: string }> {
  const env = args.env ?? (process.env as Record<string, string | undefined>);
  const domain = resolveGuiDomain();
  const label = resolveLaunchAgentLabel({ env });
  const plistPath = resolveLaunchAgentPlistPath(env);

  // Verify plist exists before attempting reload.
  try {
    await fs.access(plistPath);
  } catch {
    return { ok: false, detail: `plist not found at ${plistPath}` };
  }

  // Bootout the current service (ignore "not loaded" errors).
  const bootout = await execLaunchctl(["bootout", domain, plistPath]);
  if (bootout.code !== 0 && !isLaunchctlNotLoaded(bootout)) {
    return { ok: false, detail: `bootout failed: ${(bootout.stderr || bootout.stdout).trim()}` };
  }

  // Clear any "disabled" state left over from bootout.
  await execLaunchctl(["enable", `${domain}/${label}`]);

  // Bootstrap the service with the (potentially updated) plist.
  const boot = await execLaunchctl(["bootstrap", domain, plistPath]);
  if (boot.code !== 0) {
    return { ok: false, detail: `bootstrap failed: ${(boot.stderr || boot.stdout).trim()}` };
  }

  // Kickstart to ensure the service starts immediately.
  const kick = await execLaunchctl(["kickstart", "-k", `${domain}/${label}`]);
  if (kick.code !== 0) {
    return { ok: false, detail: `kickstart failed: ${(kick.stderr || kick.stdout).trim()}` };
  }

  return { ok: true };
}

'''

code = code.replace(marker, new_fn + marker, 1)

with open(filepath, "w") as f:
    f.write(code)
print("    OK: #26435 launchd.ts — reloadLaunchAgentAfterUpdate() added")
PYEOF

# ── 2. src/cli/update-cli/update-command.ts — import + use in maybeRestartService ──
python3 - "$SRC/cli/update-cli/update-command.ts" << 'PYEOF'
import sys

filepath = sys.argv[1]
with open(filepath, "r") as f:
    code = f.read()

changed = False

# 2a. Add import for reloadLaunchAgentAfterUpdate
if "reloadLaunchAgentAfterUpdate" not in code:
    import_marker = 'import { resolveGatewayService } from "../../daemon/service.js";'
    if import_marker not in code:
        print("    FAIL: #26435 resolveGatewayService import not found", file=sys.stderr)
        sys.exit(1)
    code = code.replace(
        import_marker,
        import_marker + '\nimport { reloadLaunchAgentAfterUpdate } from "../../daemon/launchd.js";',
        1,
    )
    changed = True
    print("    OK: #26435 import added")
else:
    print("    SKIP: #26435 import already present")

# 2b. In maybeRestartService, after refreshGatewayServiceEnv try/catch block,
#     add a LaunchAgent reload fallback before using the restart script.
#     This ensures plist is reloaded even when refreshGatewayServiceEnv fails.
#
# Target: insert after the refreshGatewayServiceEnv catch block, before the
# "if (params.restartScriptPath)" check.
old_block = '''      if (params.restartScriptPath) {
        await runRestartScript(params.restartScriptPath);
        restartInitiated = true;
      } else {
        restarted = await runDaemonRestart();
      }'''

new_block = '''      // #26435: On macOS, perform a full LaunchAgent reload (bootout + bootstrap)
      // to ensure the plist picks up updated binary paths after npm update.
      // This is critical because kickstart -k alone reuses the cached plist.
      if (process.platform === "darwin") {
        try {
          const reloadResult = await reloadLaunchAgentAfterUpdate({ env: process.env });
          if (reloadResult.ok) {
            restartInitiated = true;
          } else if (!params.opts.json) {
            defaultRuntime.log(
              theme.warn(`LaunchAgent reload: ${reloadResult.detail ?? "unknown error"}`),
            );
          }
        } catch (err) {
          if (!params.opts.json) {
            defaultRuntime.log(
              theme.warn(`LaunchAgent reload failed: ${String(err)}`),
            );
          }
        }
      }

      if (!restartInitiated && params.restartScriptPath) {
        await runRestartScript(params.restartScriptPath);
        restartInitiated = true;
      } else if (!restartInitiated) {
        restarted = await runDaemonRestart();
      }'''

if old_block in code:
    code = code.replace(old_block, new_block, 1)
    changed = True
    print("    OK: #26435 maybeRestartService reload logic added")
else:
    print("    FAIL: #26435 maybeRestartService block not found", file=sys.stderr)
    sys.exit(1)

if changed:
    with open(filepath, "w") as f:
        f.write(code)

print("    OK: #26435 update-command.ts fully patched")
PYEOF

echo "    OK: #26435 fully applied"
