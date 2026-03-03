#!/usr/bin/env bash
set -euo pipefail

# PR #30853 — Unify internal + plugin hook registries
# Creates src/hooks/dispatch-unified.ts (NEW file)
# Modifies src/hooks/internal-hooks.ts (HookSource, source-scoped clearing, Symbol singleton)
# Modifies src/hooks/loader.ts (pass source to registerInternalHook)
# Modifies src/plugins/hook-runner-global.ts (Symbol.for singleton)
# Modifies src/plugins/registry.ts (pass "plugin" source)
# Modifies src/gateway/server-startup.ts (clearInternalHooksBySource)
# Modifies src/gateway/server.impl.ts (emitGatewayStartup)
# Modifies src/agents/pi-embedded-subscribe.handlers.compaction.ts (sessionKey in after_compaction)
# Modifies src/gateway/server-methods/sessions.ts (before_reset hook)
#
# NOTE: dispatch-from-config.ts and deliver.ts in v2026.3.2 already use
# fireAndForgetHook + message-hook-mappers pattern (different from diff base).
# The unified dispatch module is created but those call sites are NOT rewritten —
# the existing pattern already separates plugin + internal hooks correctly.
# The KEY changes from this PR are:
# 1. HookSource tagging + source-scoped clearing (prevents hot-reload wiping plugin hooks)
# 2. Symbol.for singletons (prevents bundle-splitting handler loss)
# 3. dispatch-unified.ts as a utility (available for future call sites)
# 4. before_reset hook + sessionKey in after_compaction
# 5. gateway startup hook moved from setTimeout to post-sidecar

TARGET="${1:?Usage: $0 <openclaw-src-dir>}"
cd "$TARGET"

MARKER="__PATCH_30853_UNIFIED_HOOK_DISPATCH__"

# ── Idempotency ──────────────────────────────────────────────────────────
if grep -q "HookSource" src/hooks/internal-hooks.ts 2>/dev/null; then
  echo "[30853] Already applied — skipping"
  exit 0
fi

# ── 1. Modify src/hooks/internal-hooks.ts ─────────────────────────────────
FILE1="src/hooks/internal-hooks.ts"
[ -f "$FILE1" ] || { echo "[30853] ERROR: $FILE1 not found"; exit 1; }

python3 - "$FILE1" << 'PYEOF'
import sys

filepath = sys.argv[1]
with open(filepath, 'r') as f:
    content = f.read()

MARKER = "__PATCH_30853_UNIFIED_HOOK_DISPATCH__"

# --- 1a. Add HookSource type after InternalHookHandler ---
old_handler_type = 'export type InternalHookHandler = (event: InternalHookEvent) => Promise<void> | void;'
new_handler_type = f'''export type InternalHookHandler = (event: InternalHookEvent) => Promise<void> | void;

// @marker {MARKER}
export type HookSource = "bundled" | "workspace" | "managed" | "config" | "plugin";

interface HookRegistryEntry {{
  handler: InternalHookHandler;
  source: HookSource;
}}'''

if old_handler_type in content:
    content = content.replace(old_handler_type, new_handler_type, 1)
else:
    print(f"[30853] WARNING: Could not find InternalHookHandler type in {filepath}")

# --- 1b. Replace the handler registry with Symbol.for singleton + HookRegistryEntry ---
# v2026.3.2 has a globalThis singleton pattern already, need to adapt it
old_registry_block = '''const _g = globalThis as typeof globalThis & {
  __openclaw_internal_hook_handlers__?: Map<string, InternalHookHandler[]>;
};
const handlers = (_g.__openclaw_internal_hook_handlers__ ??= new Map<
  string,
  InternalHookHandler[]
>());'''

new_registry_block = '''const HOOK_REGISTRY_KEY = Symbol.for("openclaw:hookRegistry");

type HookRegistryState = {
  handlers: Map<string, HookRegistryEntry[]>;
};

const registryState: HookRegistryState = (() => {
  const g = globalThis as typeof globalThis & { [HOOK_REGISTRY_KEY]?: HookRegistryState };
  if (!g[HOOK_REGISTRY_KEY]) {
    g[HOOK_REGISTRY_KEY] = { handlers: new Map() };
  }
  return g[HOOK_REGISTRY_KEY];
})();'''

if old_registry_block in content:
    content = content.replace(old_registry_block, new_registry_block, 1)
else:
    print(f"[30853] WARNING: Could not find handler registry block in {filepath}")

# --- 1c. Update registerInternalHook to accept source parameter ---
old_register = '''export function registerInternalHook(eventKey: string, handler: InternalHookHandler): void {
  if (!handlers.has(eventKey)) {
    handlers.set(eventKey, []);
  }
  handlers.get(eventKey)!.push(handler);
}'''

new_register = '''export function registerInternalHook(
  eventKey: string,
  handler: InternalHookHandler,
  source: HookSource = "config",
): void {
  if (!registryState.handlers.has(eventKey)) {
    registryState.handlers.set(eventKey, []);
  }
  registryState.handlers.get(eventKey)!.push({ handler, source });
}'''

if old_register in content:
    content = content.replace(old_register, new_register, 1)
else:
    print(f"[30853] WARNING: Could not find registerInternalHook in {filepath}")

# --- 1d. Update unregisterInternalHook ---
old_unregister = '''export function unregisterInternalHook(eventKey: string, handler: InternalHookHandler): void {
  const eventHandlers = handlers.get(eventKey);
  if (!eventHandlers) {
    return;
  }

  const index = eventHandlers.indexOf(handler);
  if (index !== -1) {
    eventHandlers.splice(index, 1);
  }

  // Clean up empty handler arrays
  if (eventHandlers.length === 0) {
    handlers.delete(eventKey);
  }
}'''

new_unregister = '''export function unregisterInternalHook(eventKey: string, handler: InternalHookHandler): void {
  const eventEntries = registryState.handlers.get(eventKey);
  if (!eventEntries) {
    return;
  }

  const index = eventEntries.findIndex((e) => e.handler === handler);
  if (index !== -1) {
    eventEntries.splice(index, 1);
  }

  // Clean up empty entry arrays
  if (eventEntries.length === 0) {
    registryState.handlers.delete(eventKey);
  }
}'''

if old_unregister in content:
    content = content.replace(old_unregister, new_unregister, 1)
else:
    print(f"[30853] WARNING: Could not find unregisterInternalHook in {filepath}")

# --- 1e. Update clearInternalHooks + add clearInternalHooksBySource ---
old_clear = '''export function clearInternalHooks(): void {
  handlers.clear();
}'''

new_clear = '''export function clearInternalHooks(): void {
  registryState.handlers.clear();
}

/**
 * Clear hooks registered by specific sources, preserving hooks from other sources.
 * Use this instead of clearInternalHooks() during hot-reload to preserve plugin hooks.
 */
export function clearInternalHooksBySource(sources: HookSource[]): void {
  const sourceSet = new Set(sources);
  for (const [key, entries] of registryState.handlers) {
    const filtered = entries.filter((e) => !sourceSet.has(e.source));
    if (filtered.length === 0) {
      registryState.handlers.delete(key);
    } else {
      registryState.handlers.set(key, filtered);
    }
  }
}'''

if old_clear in content:
    content = content.replace(old_clear, new_clear, 1)
else:
    print(f"[30853] WARNING: Could not find clearInternalHooks in {filepath}")

# --- 1f. Update getRegisteredEventKeys ---
old_keys = '''export function getRegisteredEventKeys(): string[] {
  return Array.from(handlers.keys());
}'''

new_keys = '''export function getRegisteredEventKeys(): string[] {
  return Array.from(registryState.handlers.keys());
}'''

if old_keys in content:
    content = content.replace(old_keys, new_keys, 1)
else:
    print(f"[30853] WARNING: Could not find getRegisteredEventKeys in {filepath}")

# --- 1g. Update triggerInternalHook ---
old_trigger = '''  const typeHandlers = handlers.get(event.type) ?? [];
  const specificHandlers = handlers.get(`${event.type}:${event.action}`) ?? [];

  const allHandlers = [...typeHandlers, ...specificHandlers];

  if (allHandlers.length === 0) {
    return;
  }

  for (const handler of allHandlers) {
    try {
      await handler(event);'''

new_trigger = '''  const typeEntries = registryState.handlers.get(event.type) ?? [];
  const specificEntries = registryState.handlers.get(`${event.type}:${event.action}`) ?? [];

  const allEntries = [...typeEntries, ...specificEntries];

  if (allEntries.length === 0) {
    return;
  }

  for (const entry of allEntries) {
    try {
      await entry.handler(event);'''

if old_trigger in content:
    content = content.replace(old_trigger, new_trigger, 1)
else:
    print(f"[30853] WARNING: Could not find triggerInternalHook body in {filepath}")

with open(filepath, 'w') as f:
    f.write(content)

print(f"[30853] Modified {filepath}")
PYEOF

# ── 2. Modify src/hooks/loader.ts ────────────────────────────────────────
FILE2="src/hooks/loader.ts"
[ -f "$FILE2" ] || { echo "[30853] ERROR: $FILE2 not found"; exit 1; }

python3 - "$FILE2" << 'PYEOF'
import sys

filepath = sys.argv[1]
with open(filepath, 'r') as f:
    content = f.read()

# --- 2a. Update import to include HookSource ---
old_import = 'import type { InternalHookHandler } from "./internal-hooks.js";'
new_import = 'import type { InternalHookHandler, HookSource } from "./internal-hooks.js";'

if old_import in content:
    content = content.replace(old_import, new_import, 1)

# --- 2b. Add resolveHookSource function after the log line ---
old_log = 'const log = createSubsystemLogger("hooks:loader");'
new_log = '''const log = createSubsystemLogger("hooks:loader");

/** Map workspace discovery source names to HookSource for source-scoped clearing. */
function resolveHookSource(source: string): HookSource {
  switch (source) {
    case "openclaw-bundled": return "bundled";
    case "openclaw-managed": return "managed";
    case "openclaw-workspace": return "workspace";
    case "openclaw-plugin": return "workspace";
    default: return "config";
  }
}'''

if old_log in content:
    content = content.replace(old_log, new_log, 1)

# --- 2c. Update directory-based hook registration to pass source ---
old_dir_register = '''        for (const event of events) {
          registerInternalHook(event, handler);
        }

        log.info(
          `Registered hook: ${entry.hook.name}'''

new_dir_register = '''        const source = resolveHookSource(entry.hook.source);
        for (const event of events) {
          registerInternalHook(event, handler, source);
        }

        log.info(
          `Registered hook: ${entry.hook.name}'''

if old_dir_register in content:
    content = content.replace(old_dir_register, new_dir_register, 1)
else:
    print(f"[30853] WARNING: Could not find directory hook register in {filepath}")

# --- 2d. Update legacy handler registration to pass "config" source ---
old_legacy = '      registerInternalHook(handlerConfig.event, handler);\n      log.info(\n        `Registered hook (legacy):'
new_legacy = '      registerInternalHook(handlerConfig.event, handler, "config");\n      log.info(\n        `Registered hook (legacy):'

if old_legacy in content:
    content = content.replace(old_legacy, new_legacy, 1)
else:
    print(f"[30853] WARNING: Could not find legacy hook register in {filepath}")

with open(filepath, 'w') as f:
    f.write(content)

print(f"[30853] Modified {filepath}")
PYEOF

# ── 3. Modify src/plugins/hook-runner-global.ts ──────────────────────────
FILE3="src/plugins/hook-runner-global.ts"
[ -f "$FILE3" ] || { echo "[30853] ERROR: $FILE3 not found"; exit 1; }

python3 - "$FILE3" << 'PYEOF'
import sys

filepath = sys.argv[1]
with open(filepath, 'r') as f:
    content = f.read()

# Replace module-level variables with Symbol.for singleton
old_vars = '''let globalHookRunner: HookRunner | null = null;
let globalRegistry: PluginRegistry | null = null;'''

new_vars = '''const HOOK_RUNNER_KEY = Symbol.for("openclaw:hookRunner");

type HookRunnerState = {
  runner: HookRunner | null;
  registry: PluginRegistry | null;
};

const hookRunnerState: HookRunnerState = (() => {
  const g = globalThis as typeof globalThis & { [HOOK_RUNNER_KEY]?: HookRunnerState };
  if (!g[HOOK_RUNNER_KEY]) {
    g[HOOK_RUNNER_KEY] = { runner: null, registry: null };
  }
  return g[HOOK_RUNNER_KEY];
})();'''

if old_vars in content:
    content = content.replace(old_vars, new_vars, 1)
else:
    print(f"[30853] WARNING: Could not find global vars in {filepath}")

# Update initializeGlobalHookRunner
content = content.replace(
    '  globalRegistry = registry;\n  globalHookRunner = createHookRunner(registry, {',
    '  hookRunnerState.registry = registry;\n  hookRunnerState.runner = createHookRunner(registry, {',
    1
)

# Update getGlobalHookRunner
content = content.replace(
    '  return globalHookRunner;\n}',
    '  return hookRunnerState.runner;\n}',
    1
)

# Update getGlobalPluginRegistry
content = content.replace(
    '  return globalRegistry;\n}',
    '  return hookRunnerState.registry;\n}',
    1
)

# Update hasGlobalHooks
content = content.replace(
    '  return globalHookRunner?.hasHooks(hookName) ?? false;',
    '  return hookRunnerState.runner?.hasHooks(hookName) ?? false;',
    1
)

# Update resetGlobalHookRunner
content = content.replace(
    '  globalHookRunner = null;\n  globalRegistry = null;',
    '  hookRunnerState.runner = null;\n  hookRunnerState.registry = null;',
    1
)

with open(filepath, 'w') as f:
    f.write(content)

print(f"[30853] Modified {filepath}")
PYEOF

# ── 4. Modify src/plugins/registry.ts ────────────────────────────────────
FILE4="src/plugins/registry.ts"
[ -f "$FILE4" ] || { echo "[30853] ERROR: $FILE4 not found"; exit 1; }

python3 - "$FILE4" << 'PYEOF'
import sys

filepath = sys.argv[1]
with open(filepath, 'r') as f:
    content = f.read()

# Add "plugin" source to registerInternalHook call in plugin registry
old_plugin_register = '      registerInternalHook(event, handler);\n    }'
new_plugin_register = '      registerInternalHook(event, handler, "plugin");\n    }'

if old_plugin_register in content:
    content = content.replace(old_plugin_register, new_plugin_register, 1)
else:
    print(f"[30853] WARNING: Could not find plugin hook register in {filepath}")

with open(filepath, 'w') as f:
    f.write(content)

print(f"[30853] Modified {filepath}")
PYEOF

# ── 5. Modify src/gateway/server-startup.ts ──────────────────────────────
FILE5="src/gateway/server-startup.ts"
[ -f "$FILE5" ] || { echo "[30853] ERROR: $FILE5 not found"; exit 1; }

python3 - "$FILE5" << 'PYEOF'
import sys

filepath = sys.argv[1]
with open(filepath, 'r') as f:
    content = f.read()

# --- 5a. Update import to use clearInternalHooksBySource ---
old_import = '''import {
  clearInternalHooks,
  createInternalHookEvent,
  triggerInternalHook,
} from "../hooks/internal-hooks.js";'''

new_import = '''import {
  clearInternalHooksBySource,
} from "../hooks/internal-hooks.js";'''

if old_import in content:
    content = content.replace(old_import, new_import, 1)
else:
    print(f"[30853] WARNING: Could not find imports block in {filepath}")

# --- 5b. Replace clearInternalHooks() with clearInternalHooksBySource ---
old_clear = '    // Clear any previously registered hooks to ensure fresh loading\n    clearInternalHooks();'
new_clear = '    // Clear file-discovered hooks but preserve plugin-registered hooks (#30784)\n    clearInternalHooksBySource(["bundled", "workspace", "managed", "config"]);'

if old_clear in content:
    content = content.replace(old_clear, new_clear, 1)
else:
    print(f"[30853] WARNING: Could not find clearInternalHooks call in {filepath}")

# --- 5c. Remove the gateway startup setTimeout block ---
# This block fires the gateway:startup hook via setTimeout; it should now be
# fired from server.impl.ts via emitGatewayStartup after sidecars are loaded.
old_startup_block = '''  if (params.cfg.hooks?.internal?.enabled) {
    setTimeout(() => {
      const hookEvent = createInternalHookEvent("gateway", "startup", "gateway:startup", {
        cfg: params.cfg,
        deps: params.deps,
        workspaceDir: params.defaultWorkspaceDir,
      });
      void triggerInternalHook(hookEvent);
    }, 250);
  }'''

new_startup_block = '''  // gateway:startup hook is now emitted from server.impl.ts via
  // emitGatewayStartup() after sidecars are fully loaded (#30784)'''

if old_startup_block in content:
    content = content.replace(old_startup_block, new_startup_block, 1)
else:
    print(f"[30853] WARNING: Could not find gateway startup setTimeout block in {filepath}")

with open(filepath, 'w') as f:
    f.write(content)

print(f"[30853] Modified {filepath}")
PYEOF

# ── 6. Create NEW file: src/hooks/dispatch-unified.ts ─────────────────────
FILE6="src/hooks/dispatch-unified.ts"
cat > "$FILE6" << 'TSEOF'
/**
 * Unified dispatch helpers for overlapping hook events.
 *
 * Three events are dispatched through both the internal hook system
 * (HOOK.md discovery) and the plugin typed hook system. This module
 * co-locates the dual dispatch so each call site only needs one function.
 */

import { logVerbose } from "../globals.js";
import { getGlobalHookRunner } from "../plugins/hook-runner-global.js";
import { createInternalHookEvent, triggerInternalHook } from "./internal-hooks.js";

/**
 * Emit a message_received event through both hook systems.
 */
export function emitMessageReceived(params: {
  from: string;
  content: string;
  timestamp?: number;
  channelId: string;
  accountId?: string;
  conversationId?: string;
  messageId?: string;
  sessionKey?: string;
  metadata?: Record<string, unknown>;
}): void {
  const hookRunner = getGlobalHookRunner();
  if (hookRunner?.hasHooks("message_received")) {
    void hookRunner
      .runMessageReceived(
        {
          from: params.from,
          content: params.content,
          timestamp: params.timestamp,
          metadata: {
            ...params.metadata,
            ...(params.messageId ? { messageId: params.messageId } : {}),
          },
        },
        {
          channelId: params.channelId,
          accountId: params.accountId,
          conversationId: params.conversationId,
        },
      )
      .catch((err) => {
        logVerbose(`dispatch-unified: message_received plugin hook failed: ${String(err)}`);
      });
  }

  if (params.sessionKey) {
    void triggerInternalHook(
      createInternalHookEvent("message", "received", params.sessionKey, {
        from: params.from,
        content: params.content,
        timestamp: params.timestamp,
        channelId: params.channelId,
        accountId: params.accountId,
        conversationId: params.conversationId,
        messageId: params.messageId,
        metadata: params.metadata ?? {},
      }),
    ).catch(() => {});
  }
}

/**
 * Emit a message_sent event through both hook systems.
 */
export function emitMessageSent(params: {
  to: string;
  content: string;
  success: boolean;
  error?: string;
  channelId: string;
  accountId?: string;
  conversationId?: string;
  messageId?: string;
  sessionKey?: string;
}): void {
  const hookRunner = getGlobalHookRunner();
  if (hookRunner?.hasHooks("message_sent")) {
    void hookRunner
      .runMessageSent(
        {
          to: params.to,
          content: params.content,
          success: params.success,
          ...(params.error ? { error: params.error } : {}),
        },
        {
          channelId: params.channelId,
          accountId: params.accountId,
          conversationId: params.conversationId ?? params.to,
        },
      )
      .catch((err) => {
        logVerbose(`dispatch-unified: message_sent plugin hook failed: ${String(err)}`);
      });
  }

  if (params.sessionKey) {
    void triggerInternalHook(
      createInternalHookEvent("message", "sent", params.sessionKey, {
        to: params.to,
        content: params.content,
        success: params.success,
        ...(params.error ? { error: params.error } : {}),
        channelId: params.channelId,
        accountId: params.accountId,
        conversationId: params.conversationId ?? params.to,
        messageId: params.messageId,
      }),
    ).catch(() => {});
  }
}

/**
 * Emit gateway startup through both hook systems.
 *
 * Fires both hooks synchronously (no setTimeout). Must be called after
 * hook loading completes to avoid the race condition in #30784.
 */
export function emitGatewayStartup(params: {
  port: number;
  cfg?: unknown;
  deps?: unknown;
  workspaceDir?: string;
  internalHooksEnabled?: boolean;
}): void {
  // Plugin hook
  const hookRunner = getGlobalHookRunner();
  if (hookRunner?.hasHooks("gateway_start")) {
    void hookRunner
      .runGatewayStart({ port: params.port }, { port: params.port })
      .catch((err) => {
        logVerbose(`dispatch-unified: gateway_start plugin hook failed: ${String(err)}`);
      });
  }

  // Internal hook — no setTimeout, fire immediately after hooks are loaded
  if (params.internalHooksEnabled) {
    void triggerInternalHook(
      createInternalHookEvent("gateway", "startup", "gateway:startup", {
        cfg: params.cfg,
        deps: params.deps,
        workspaceDir: params.workspaceDir,
      }),
    ).catch(() => {});
  }
}
TSEOF
echo "[30853] Created $FILE6"

# ── 7. Modify src/gateway/server.impl.ts ─────────────────────────────────
FILE7="src/gateway/server.impl.ts"
[ -f "$FILE7" ] || { echo "[30853] ERROR: $FILE7 not found"; exit 1; }

python3 - "$FILE7" << 'PYEOF'
import sys

filepath = sys.argv[1]
with open(filepath, 'r') as f:
    content = f.read()

# --- 7a. Update import: remove getGlobalHookRunner, add emitGatewayStartup ---
old_import = 'import { getGlobalHookRunner, runGlobalGatewayStopSafely } from "../plugins/hook-runner-global.js";'
new_import = 'import { runGlobalGatewayStopSafely } from "../plugins/hook-runner-global.js";\nimport { emitGatewayStartup } from "../hooks/dispatch-unified.js";'

if old_import in content:
    content = content.replace(old_import, new_import, 1)
else:
    print(f"[30853] WARNING: Could not find hook-runner-global import in {filepath}")

# --- 7b. Replace gateway_start hook block with emitGatewayStartup ---
old_hook_block = '''  // Run gateway_start plugin hook (fire-and-forget)
  if (!minimalTestGateway) {
    const hookRunner = getGlobalHookRunner();
    if (hookRunner?.hasHooks("gateway_start")) {
      void hookRunner.runGatewayStart({ port }, { port }).catch((err) => {
        log.warn(`gateway_start hook failed: ${String(err)}`);
      });
    }
  }'''

new_hook_block = '''  // Emit gateway startup through both plugin and internal hook systems (#30784)
  if (!minimalTestGateway) {
    emitGatewayStartup({
      port,
      cfg: cfgAtStart,
      deps,
      workspaceDir: defaultWorkspaceDir,
      internalHooksEnabled: cfgAtStart.hooks?.internal?.enabled === true,
    });
  }'''

if old_hook_block in content:
    content = content.replace(old_hook_block, new_hook_block, 1)
else:
    print(f"[30853] WARNING: Could not find gateway_start hook block in {filepath}")

with open(filepath, 'w') as f:
    f.write(content)

print(f"[30853] Modified {filepath}")
PYEOF

# ── 8. Modify src/agents/pi-embedded-subscribe.handlers.compaction.ts ────
FILE8="src/agents/pi-embedded-subscribe.handlers.compaction.ts"
[ -f "$FILE8" ] || { echo "[30853] ERROR: $FILE8 not found"; exit 1; }

python3 - "$FILE8" << 'PYEOF'
import sys

filepath = sys.argv[1]
with open(filepath, 'r') as f:
    content = f.read()

# Add sessionKey to the after_compaction hook context (second arg)
# Current: .runAfterCompaction({ messageCount, compactedCount }, {})
# Target:  .runAfterCompaction({ messageCount, compactedCount }, { sessionKey })
old_compaction = '''          },
          {},
        )
        .catch((err) => {
          ctx.log.warn(`after_compaction hook failed: ${String(err)}`);'''

new_compaction = '''          },
          {
            sessionKey: ctx.params.sessionKey,
          },
        )
        .catch((err) => {
          ctx.log.warn(`after_compaction hook failed: ${String(err)}`);'''

if old_compaction in content:
    content = content.replace(old_compaction, new_compaction, 1)
else:
    print(f"[30853] WARNING: Could not find after_compaction hook block in {filepath}")

with open(filepath, 'w') as f:
    f.write(content)

print(f"[30853] Modified {filepath}")
PYEOF

# ── 9. Modify src/gateway/server-methods/sessions.ts ─────────────────────
# Add before_reset plugin hook in the reset handler
FILE9="src/gateway/server-methods/sessions.ts"
[ -f "$FILE9" ] || { echo "[30853] ERROR: $FILE9 not found"; exit 1; }

python3 - "$FILE9" << 'PYEOF'
import sys

filepath = sys.argv[1]
with open(filepath, 'r') as f:
    content = f.read()

# Add logVerbose import if not present
if 'import { logVerbose }' not in content:
    # Add after the existing imports from hooks/internal-hooks
    old_hooks_import = 'import { createInternalHookEvent, triggerInternalHook } from "../../hooks/internal-hooks.js";'
    if old_hooks_import in content:
        content = content.replace(
            old_hooks_import,
            old_hooks_import + '\nimport { logVerbose } from "../../globals.js";',
            1
        )

# Add before_reset hook block after triggerInternalHook(hookEvent) in reset handler
# In v2026.3.2, the line after triggerInternalHook is cleanupSessionBeforeMutation, not sessionId
old_reset_hook = '    await triggerInternalHook(hookEvent);\n    const mutationCleanupError = await cleanupSessionBeforeMutation({'

new_reset_hook = '''    await triggerInternalHook(hookEvent);

    // Fire before_reset plugin hook — extract memories before session history is lost (#30784)
    const hookRunner = getGlobalHookRunner();
    if (hookRunner?.hasHooks("before_reset")) {
      const sessionFile = entry?.sessionFile;
      // Read session file synchronously BEFORE cleanup can rename/archive it
      const messages: unknown[] = [];
      if (sessionFile) {
        try {
          const fileContent = fs.readFileSync(sessionFile, "utf-8");
          for (const line of fileContent.split("\\n")) {
            if (!line.trim()) {
              continue;
            }
            try {
              const parsed = JSON.parse(line);
              if (parsed.type === "message" && parsed.message) {
                messages.push(parsed.message);
              }
            } catch {
              // skip malformed lines
            }
          }
        } catch {
          // file may not exist
        }
      }
      const resetAgentId = (() => {
        const k = target.canonicalKey ?? key;
        const parts = k.split(":");
        return parts[0] === "agent" && parts[1] ? parts[1] : (parts[0] ?? "main");
      })();
      // Await hook so it finishes before archiveSessionTranscriptsForSession
      // renames the session file (#30784)
      await hookRunner
        .runBeforeReset(
          { sessionFile, messages, reason: commandReason },
          {
            agentId: resetAgentId,
            sessionKey: target.canonicalKey ?? key,
            sessionId: entry?.sessionId,
          },
        )
        .catch((err) => {
          logVerbose(`sessions.reset: before_reset plugin hook failed: ${String(err)}`);
        });
    }

    const mutationCleanupError = await cleanupSessionBeforeMutation({'''

if old_reset_hook in content:
    content = content.replace(old_reset_hook, new_reset_hook, 1)
else:
    print(f"[30853] WARNING: Could not find reset hook insertion point in {filepath}")

with open(filepath, 'w') as f:
    f.write(content)

print(f"[30853] Modified {filepath}")
PYEOF

echo "[30853] Patch applied successfully"
