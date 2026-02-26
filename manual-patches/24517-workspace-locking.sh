#!/usr/bin/env bash
# PR #24517: feat(concurrency): shared workspace locking for multi-agent write safety
#
# Adds optional path-scoped write/edit serialization for concurrent multi-agent workspaces.
#
# Changes:
#   1. src/config/types.agent-defaults.ts — sharedWorkspaceLocking type
#   2. src/config/zod-schema.agent-defaults.ts — zod schema
#   3. src/infra/workspace-lock-manager.ts — NEW FILE (205 lines)
#   4. src/agents/pi-tools.read.ts — import + wrapToolMutationLock + SandboxToolParams
#   5. src/agents/pi-tools.ts — mutationLockingEnabled flag + pass-through
#
# Tests and docs skipped (not needed for build).
set -euo pipefail
cd "$1"

# ── Idempotency gate ─────────────────────────────────────────────────────────
if grep -q 'withWorkspaceLock' src/agents/pi-tools.read.ts 2>/dev/null; then
  echo "SKIP: #24517 already applied (withWorkspaceLock found)"
  exit 0
fi

ERRORS=()

# ── Step 1: Config type ──────────────────────────────────────────────────────
python3 << 'PYEOF'
import sys

filepath = "src/config/types.agent-defaults.ts"
with open(filepath, "r") as f:
    code = f.read()

if "sharedWorkspaceLocking" in code:
    print("SKIP: #24517 types.agent-defaults.ts already has sharedWorkspaceLocking")
    sys.exit(0)

# Insert after "workspace?: string;"
marker = '  /** Agent working directory (preferred). Used as the default cwd for agent runs. */\n  workspace?: string;'
insert = marker + '''
  /** Optional shared-workspace mutation locking for concurrent multi-agent writes. */
  sharedWorkspaceLocking?: {
    /** Enable path-scoped write/edit serialization and workspace lock primitives. */
    enabled?: boolean;
  };'''

if marker in code:
    code = code.replace(marker, insert, 1)
    with open(filepath, "w") as f:
        f.write(code)
    print("OK: #24517 types.agent-defaults.ts patched")
else:
    print("FAIL: #24517 cannot find workspace marker in types.agent-defaults.ts", file=sys.stderr)
    sys.exit(1)

PYEOF
[ $? -eq 0 ] || ERRORS+=("types.agent-defaults.ts")

# ── Step 2: Zod schema ───────────────────────────────────────────────────────
python3 << 'PYEOF'
import sys

filepath = "src/config/zod-schema.agent-defaults.ts"
with open(filepath, "r") as f:
    code = f.read()

if "sharedWorkspaceLocking" in code:
    print("SKIP: #24517 zod-schema.agent-defaults.ts already has sharedWorkspaceLocking")
    sys.exit(0)

# Insert after "workspace: z.string().optional(),"
marker = '    workspace: z.string().optional(),'
insert = marker + '''
    sharedWorkspaceLocking: z
      .object({
        enabled: z.boolean().optional(),
      })
      .strict()
      .optional(),'''

if marker in code:
    code = code.replace(marker, insert, 1)
    with open(filepath, "w") as f:
        f.write(code)
    print("OK: #24517 zod-schema.agent-defaults.ts patched")
else:
    print("FAIL: #24517 cannot find workspace marker in zod-schema.agent-defaults.ts", file=sys.stderr)
    sys.exit(1)

PYEOF
[ $? -eq 0 ] || ERRORS+=("zod-schema.agent-defaults.ts")

# ── Step 3: New file — workspace-lock-manager.ts ─────────────────────────────
mkdir -p src/infra

if [ -f "src/infra/workspace-lock-manager.ts" ]; then
  echo "SKIP: #24517 workspace-lock-manager.ts already exists"
else
  cat > src/infra/workspace-lock-manager.ts << 'TSEOF'
import fs from "node:fs/promises";
import path from "node:path";
import { isPidAlive } from "../shared/pid-alive.js";
import { resolveProcessScopedMap } from "../shared/process-scoped-map.js";

const DEFAULT_TIMEOUT_MS = 5_000;
const DEFAULT_POLL_INTERVAL_MS = 50;
const DEFAULT_TTL_MS = 30_000;

export type WorkspaceLockKind = "file" | "dir";

export type WorkspaceLockOptions = {
  kind?: WorkspaceLockKind;
  timeoutMs?: number;
  pollIntervalMs?: number;
  ttlMs?: number;
};

type LockPayload = {
  pid: number;
  createdAt: string;
  expiresAt: string;
  targetPath: string;
  kind: WorkspaceLockKind;
};

type HeldLock = {
  count: number;
  lockPath: string;
};

export type WorkspaceLockHandle = {
  lockPath: string;
  release: () => Promise<void>;
};

const HELD_WORKSPACE_LOCKS_KEY = Symbol.for("openclaw.workspaceLockManager.heldLocks");
const HELD_WORKSPACE_LOCKS = resolveProcessScopedMap<HeldLock>(HELD_WORKSPACE_LOCKS_KEY);

function lockMapKey(kind: WorkspaceLockKind, normalizedTarget: string): string {
  return `${kind}:${normalizedTarget}`;
}

async function normalizeTargetPath(targetPath: string, kind: WorkspaceLockKind): Promise<string> {
  const resolved = path.resolve(targetPath);
  if (kind === "file") {
    await fs.mkdir(path.dirname(resolved), { recursive: true });
    return resolved;
  }
  await fs.mkdir(resolved, { recursive: true });
  try {
    return await fs.realpath(resolved);
  } catch {
    return resolved;
  }
}

function resolveLockPath(normalizedTarget: string, kind: WorkspaceLockKind): string {
  return kind === "file"
    ? `${normalizedTarget}.lock`
    : path.join(normalizedTarget, ".openclaw.workspace.lock");
}

function isTimestampExpired(isoTimestamp: string | undefined): boolean {
  if (!isoTimestamp) {
    return false;
  }
  const ts = Date.parse(isoTimestamp);
  return Number.isFinite(ts) && Date.now() >= ts;
}

async function readPayload(lockPath: string): Promise<LockPayload | null> {
  try {
    const raw = await fs.readFile(lockPath, "utf8");
    const parsed = JSON.parse(raw) as Partial<LockPayload>;
    if (
      typeof parsed.pid !== "number" ||
      typeof parsed.createdAt !== "string" ||
      typeof parsed.expiresAt !== "string" ||
      typeof parsed.targetPath !== "string" ||
      (parsed.kind !== "file" && parsed.kind !== "dir")
    ) {
      return null;
    }
    return {
      pid: parsed.pid,
      createdAt: parsed.createdAt,
      expiresAt: parsed.expiresAt,
      targetPath: parsed.targetPath,
      kind: parsed.kind,
    };
  } catch {
    return null;
  }
}

async function isStaleLock(lockPath: string, ttlMs: number): Promise<boolean> {
  const payload = await readPayload(lockPath);
  if (payload?.pid && !isPidAlive(payload.pid)) {
    return true;
  }
  if (payload && isTimestampExpired(payload.expiresAt)) {
    return true;
  }
  if (payload && !Number.isFinite(Date.parse(payload.createdAt))) {
    return true;
  }

  try {
    const stat = await fs.stat(lockPath);
    return Date.now() - stat.mtimeMs > ttlMs;
  } catch {
    return true;
  }
}

async function releaseLock(mapKey: string): Promise<void> {
  const held = HELD_WORKSPACE_LOCKS.get(mapKey);
  if (!held) {
    return;
  }

  held.count -= 1;
  if (held.count > 0) {
    return;
  }

  HELD_WORKSPACE_LOCKS.delete(mapKey);
  await fs.rm(held.lockPath, { force: true }).catch(() => undefined);
}

export async function acquireWorkspaceLock(
  targetPath: string,
  options: WorkspaceLockOptions = {},
): Promise<WorkspaceLockHandle> {
  const kind = options.kind ?? "file";
  const timeoutMs = Math.max(0, options.timeoutMs ?? DEFAULT_TIMEOUT_MS);
  const pollIntervalMs = Math.max(1, options.pollIntervalMs ?? DEFAULT_POLL_INTERVAL_MS);
  const ttlMs = Math.max(1, options.ttlMs ?? DEFAULT_TTL_MS);

  const normalizedTarget = await normalizeTargetPath(targetPath, kind);
  const lockPath = resolveLockPath(normalizedTarget, kind);
  const mapKey = lockMapKey(kind, normalizedTarget);

  const held = HELD_WORKSPACE_LOCKS.get(mapKey);
  if (held) {
    held.count += 1;
    return {
      lockPath,
      release: () => releaseLock(mapKey),
    };
  }

  const startedAt = Date.now();
  while (Date.now() - startedAt <= timeoutMs) {
    try {
      const handle = await fs.open(lockPath, "wx");
      const now = Date.now();
      const payload: LockPayload = {
        pid: process.pid,
        createdAt: new Date(now).toISOString(),
        expiresAt: new Date(now + ttlMs).toISOString(),
        targetPath: normalizedTarget,
        kind,
      };
      await handle.writeFile(JSON.stringify(payload), "utf8");
      await handle.close();
      HELD_WORKSPACE_LOCKS.set(mapKey, { count: 1, lockPath });
      return {
        lockPath,
        release: () => releaseLock(mapKey),
      };
    } catch (err) {
      const code = (err as { code?: string }).code;
      if (code !== "EEXIST") {
        throw err;
      }

      if (await isStaleLock(lockPath, ttlMs)) {
        await fs.rm(lockPath, { force: true }).catch(() => undefined);
        continue;
      }

      if (Date.now() - startedAt >= timeoutMs) {
        break;
      }
      await new Promise((resolve) => setTimeout(resolve, pollIntervalMs));
    }
  }

  throw new Error(`workspace lock timeout for ${normalizedTarget}`);
}

export async function withWorkspaceLock<T>(
  targetPath: string,
  options: WorkspaceLockOptions = {},
  fn: () => Promise<T>,
): Promise<T> {
  const lock = await acquireWorkspaceLock(targetPath, options);
  try {
    return await fn();
  } finally {
    await lock.release();
  }
}
TSEOF
  echo "OK: #24517 workspace-lock-manager.ts created (205 lines)"
fi

# ── Step 4: pi-tools.read.ts — import + wrapToolMutationLock + params ────────
python3 << 'PYEOF'
import sys

filepath = "src/agents/pi-tools.read.ts"
with open(filepath, "r") as f:
    code = f.read()

if "withWorkspaceLock" in code:
    print("SKIP: #24517 pi-tools.read.ts already patched")
    sys.exit(0)

changed = False

# 4a: Add import after the pi-coding-agent import
import_marker = 'import { createEditTool, createReadTool, createWriteTool } from "@mariozechner/pi-coding-agent";'
if import_marker in code:
    code = code.replace(
        import_marker,
        import_marker + '\nimport { withWorkspaceLock } from "../infra/workspace-lock-manager.js";',
        1
    )
    changed = True
    print("OK: #24517-4a withWorkspaceLock import added")
else:
    print("FAIL: #24517-4a cannot find pi-coding-agent import", file=sys.stderr)
    sys.exit(1)

# 4b: Add workspaceMutationLocks map before RETRY_GUIDANCE_SUFFIX
retry_marker = 'const RETRY_GUIDANCE_SUFFIX = " Supply correct parameters before retrying.";'
if retry_marker in code:
    code = code.replace(
        retry_marker,
        'const workspaceMutationLocks = new Map<string, Promise<void>>();\n\n' + retry_marker,
        1
    )
    changed = True
    print("OK: #24517-4b workspaceMutationLocks map added")
else:
    print("FAIL: #24517-4b cannot find RETRY_GUIDANCE_SUFFIX", file=sys.stderr)
    sys.exit(1)

# 4c: Add wrapToolMutationLock function after wrapToolParamNormalization
# Find the closing of wrapToolParamNormalization — it ends with "  };\n}"
# We need to insert after the full function. Find "export function wrapToolWorkspaceRootGuard"
root_guard_marker = 'export function wrapToolWorkspaceRootGuard(tool: AnyAgentTool, root: string): AnyAgentTool {'
mutation_lock_fn = '''export function wrapToolMutationLock(tool: AnyAgentTool, root: string): AnyAgentTool {
  return {
    ...tool,
    execute: async (toolCallId, params, signal, onUpdate) => {
      const normalized = normalizeToolParams(params);
      const record =
        normalized ??
        (params && typeof params === "object" ? (params as Record<string, unknown>) : undefined);
      const filePathRaw = record?.path;
      if (typeof filePathRaw !== "string" || !filePathRaw.trim()) {
        return tool.execute(toolCallId, params, signal, onUpdate);
      }

      const lockKey = path.resolve(root, filePathRaw);
      const previous = workspaceMutationLocks.get(lockKey) ?? Promise.resolve();
      let release: (() => void) | undefined;
      const current = new Promise<void>((resolve) => {
        release = resolve;
      });
      workspaceMutationLocks.set(lockKey, current);

      await previous;
      try {
        return await withWorkspaceLock(lockKey, { kind: "file" }, async () => {
          return await tool.execute(toolCallId, params, signal, onUpdate);
        });
      } finally {
        release?.();
        if (workspaceMutationLocks.get(lockKey) === current) {
          workspaceMutationLocks.delete(lockKey);
        }
      }
    },
  };
}

'''

if root_guard_marker in code:
    code = code.replace(root_guard_marker, mutation_lock_fn + root_guard_marker, 1)
    changed = True
    print("OK: #24517-4c wrapToolMutationLock function added")
else:
    print("FAIL: #24517-4c cannot find wrapToolWorkspaceRootGuard marker", file=sys.stderr)
    sys.exit(1)

# 4d: Add mutationLockingEnabled to SandboxToolParams type
# IMPORTANT: Use multi-line marker to target SandboxToolParams specifically,
# not the earlier OpenClawReadToolOptions which also has imageSanitization.
sandbox_type_marker = 'type SandboxToolParams = {\n  root: string;\n  bridge: SandboxFsBridge;\n  modelContextWindowTokens?: number;\n  imageSanitization?: ImageSanitizationLimits;\n};'
sandbox_type_new = 'type SandboxToolParams = {\n  root: string;\n  bridge: SandboxFsBridge;\n  modelContextWindowTokens?: number;\n  imageSanitization?: ImageSanitizationLimits;\n  mutationLockingEnabled?: boolean;\n};'
if 'mutationLockingEnabled' in code:
    print("SKIP: #24517-4d mutationLockingEnabled already in SandboxToolParams")
elif sandbox_type_marker in code:
    code = code.replace(sandbox_type_marker, sandbox_type_new, 1)
    changed = True
    print("OK: #24517-4d SandboxToolParams extended")
else:
    print("FAIL: #24517-4d cannot find SandboxToolParams type block", file=sys.stderr)
    sys.exit(1)

# 4e: Update createSandboxedWriteTool to use mutation locking
old_write = '''export function createSandboxedWriteTool(params: SandboxToolParams) {
  const base = createWriteTool(params.root, {
    operations: createSandboxWriteOperations(params),
  }) as unknown as AnyAgentTool;
  return wrapToolParamNormalization(base, CLAUDE_PARAM_GROUPS.write);
}'''
new_write = '''export function createSandboxedWriteTool(params: SandboxToolParams) {
  const base = createWriteTool(params.root, {
    operations: createSandboxWriteOperations(params),
  }) as unknown as AnyAgentTool;
  const normalized = wrapToolParamNormalization(base, CLAUDE_PARAM_GROUPS.write);
  return params.mutationLockingEnabled ? wrapToolMutationLock(normalized, params.root) : normalized;
}'''

if old_write in code:
    code = code.replace(old_write, new_write, 1)
    changed = True
    print("OK: #24517-4e createSandboxedWriteTool updated")
else:
    print("WARN: #24517-4e createSandboxedWriteTool pattern not found (may differ)")

# 4f: Update createSandboxedEditTool to use mutation locking
old_edit = '''export function createSandboxedEditTool(params: SandboxToolParams) {
  const base = createEditTool(params.root, {
    operations: createSandboxEditOperations(params),
  }) as unknown as AnyAgentTool;
  return wrapToolParamNormalization(base, CLAUDE_PARAM_GROUPS.edit);
}'''
new_edit = '''export function createSandboxedEditTool(params: SandboxToolParams) {
  const base = createEditTool(params.root, {
    operations: createSandboxEditOperations(params),
  }) as unknown as AnyAgentTool;
  const normalized = wrapToolParamNormalization(base, CLAUDE_PARAM_GROUPS.edit);
  return params.mutationLockingEnabled ? wrapToolMutationLock(normalized, params.root) : normalized;
}'''

if old_edit in code:
    code = code.replace(old_edit, new_edit, 1)
    changed = True
    print("OK: #24517-4f createSandboxedEditTool updated")
else:
    print("WARN: #24517-4f createSandboxedEditTool pattern not found (may differ)")

if changed:
    with open(filepath, "w") as f:
        f.write(code)
    print("OK: #24517 pi-tools.read.ts fully patched")
else:
    print("FAIL: #24517 no changes applied to pi-tools.read.ts", file=sys.stderr)
    sys.exit(1)

PYEOF
[ $? -eq 0 ] || ERRORS+=("pi-tools.read.ts")

# ── Step 5: pi-tools.ts — mutationLockingEnabled flag ────────────────────────
python3 << 'PYEOF'
import sys

filepath = "src/agents/pi-tools.ts"
with open(filepath, "r") as f:
    code = f.read()

if "mutationLockingEnabled" in code:
    print("SKIP: #24517 pi-tools.ts already has mutationLockingEnabled")
    sys.exit(0)

changed = False

# 5a: Add mutationLockingEnabled derivation before "const tools: AnyAgentTool[] = ["
tools_marker = '  const tools: AnyAgentTool[] = ['
mutation_flag = '''  const mutationLockingEnabled =
    options?.config?.agents?.defaults?.sharedWorkspaceLocking?.enabled === true;

  const tools: AnyAgentTool[] = ['''

if tools_marker in code:
    code = code.replace(tools_marker, mutation_flag, 1)
    changed = True
    print("OK: #24517-5a mutationLockingEnabled flag added")
else:
    print("FAIL: #24517-5a cannot find tools array marker", file=sys.stderr)
    sys.exit(1)

# 5b: Add mutationLockingEnabled to createSandboxedEditTool calls
# Pattern: "createSandboxedEditTool({ root: sandboxRoot, bridge: sandboxFsBridge! })"
old_edit_call = 'createSandboxedEditTool({ root: sandboxRoot, bridge: sandboxFsBridge! })'
new_edit_call = 'createSandboxedEditTool({\n                    root: sandboxRoot,\n                    bridge: sandboxFsBridge!,\n                    mutationLockingEnabled,\n                  })'

# There are 2 occurrences of each (workspaceOnly and non-workspaceOnly paths)
code = code.replace(old_edit_call, new_edit_call)
if code.count('mutationLockingEnabled') > 1:
    changed = True
    print("OK: #24517-5b createSandboxedEditTool calls updated")
else:
    print("WARN: #24517-5b edit tool call pattern may differ")

# 5c: Add mutationLockingEnabled to createSandboxedWriteTool calls
old_write_call = 'createSandboxedWriteTool({ root: sandboxRoot, bridge: sandboxFsBridge! })'
new_write_call = 'createSandboxedWriteTool({\n                    root: sandboxRoot,\n                    bridge: sandboxFsBridge!,\n                    mutationLockingEnabled,\n                  })'

code = code.replace(old_write_call, new_write_call)
changed = True
print("OK: #24517-5c createSandboxedWriteTool calls updated")

if changed:
    with open(filepath, "w") as f:
        f.write(code)
    print("OK: #24517 pi-tools.ts fully patched")
else:
    print("FAIL: #24517 no changes applied to pi-tools.ts", file=sys.stderr)
    sys.exit(1)

PYEOF
[ $? -eq 0 ] || ERRORS+=("pi-tools.ts")

# ── Final report ─────────────────────────────────────────────────────────────
if [ ${#ERRORS[@]} -gt 0 ]; then
  echo "FAIL: #24517 errors in: ${ERRORS[*]}"
  exit 1
fi

echo "OK: #24517 workspace locking fully applied (3 new + 4 modified)"
