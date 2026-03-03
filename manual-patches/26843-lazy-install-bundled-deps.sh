#!/usr/bin/env bash
set -euo pipefail

# PR #26843 — Lazy-install bundled extension deps
# Creates src/plugins/ensure-extension-deps.ts (NEW file)
# Modifies src/plugins/bundled-dir.ts (add resolveBundledExtensionDir)
# Modifies src/plugins/loader.ts (lazy-install deps before jiti load)
# Modifies src/cli/plugins-cli.ts (async dep install on enable)
# Modifies src/agents/pi-embedded-subscribe.ts (toolXmlDepth + stripToolXmlBlocks)
# Modifies src/agents/pi-embedded-subscribe.handlers.types.ts (toolXmlDepth)
# Modifies src/agents/pi-embedded-subscribe.handlers.messages.ts (toolXmlDepth reset)
# Modifies src/agents/pi-embedded-utils.ts (stripToolXmlBlocks function)
# Skips: test files, CHANGELOG, package.json, pnpm-lock.yaml

TARGET="${1:?Usage: $0 <openclaw-src-dir>}"
cd "$TARGET"

MARKER="__PATCH_26843_LAZY_INSTALL_BUNDLED_DEPS__"

# ── Idempotency ──────────────────────────────────────────────────────────
if [ -f "src/plugins/ensure-extension-deps.ts" ] && grep -q "$MARKER" src/plugins/ensure-extension-deps.ts 2>/dev/null; then
  echo "[26843] Already applied — skipping"
  exit 0
fi

# ── 1. Create NEW file: src/plugins/ensure-extension-deps.ts ──────────────
FILE1="src/plugins/ensure-extension-deps.ts"
cat > "$FILE1" << 'TSEOF'
/**
 * Lazy dependency installer for bundled extensions.
 *
 * Bundled extensions ship without node_modules/; this module detects missing
 * dependencies and installs them on first load (sync for gateway, async for CLI).
 *
 * @marker __PATCH_26843_LAZY_INSTALL_BUNDLED_DEPS__
 */
import { execFile, spawnSync } from "node:child_process";
import fs from "node:fs";
import path from "node:path";
import { promisify } from "node:util";

const execFileAsync = promisify(execFile);

export type PackageManagerSpec = {
  command: string;
  installArgs: string[];
};

// Priority order for PM detection. --ignore-scripts prevents untrusted postinstall
// from running inside bundled extensions. Matches install-package-dir.ts conventions.
const PM_CASCADE: PackageManagerSpec[] = [
  { command: "npm", installArgs: ["install", "--omit=dev", "--silent", "--ignore-scripts"] },
  { command: "pnpm", installArgs: ["install", "--prod", "--ignore-scripts", "--silent"] },
  { command: "yarn", installArgs: ["install", "--production", "--ignore-scripts", "--silent"] },
  { command: "bun", installArgs: ["install", "--production", "--ignore-scripts"] },
];

const INSTALL_TIMEOUT_MS = 300_000;

const INSTALL_ENV = {
  COREPACK_ENABLE_DOWNLOAD_PROMPT: "0",
  NPM_CONFIG_FUND: "false",
};

// Three-state cache: undefined = not probed, null = probed and none found, object = found.
let cachedPm: PackageManagerSpec | null | undefined;

/**
 * Check whether any `dependencies` entries in the extension's package.json
 * are missing from its local node_modules.
 */
export function hasMissingDependenciesSync(packageDir: string): boolean {
  const manifestPath = path.join(packageDir, "package.json");
  let raw: string;
  try {
    raw = fs.readFileSync(manifestPath, "utf-8");
  } catch {
    return false;
  }

  let manifest: Record<string, unknown>;
  try {
    const parsed: unknown = JSON.parse(raw);
    if (!parsed || typeof parsed !== "object" || Array.isArray(parsed)) {
      return false;
    }
    manifest = parsed as Record<string, unknown>;
  } catch {
    return false;
  }

  const deps = manifest.dependencies;
  if (!deps || typeof deps !== "object" || Array.isArray(deps)) {
    return false;
  }

  const depNames = Object.keys(deps as Record<string, unknown>);
  if (depNames.length === 0) {
    return false;
  }

  const nodeModules = path.join(packageDir, "node_modules");
  for (const dep of depNames) {
    // Scoped packages: @scope/pkg -> node_modules/@scope/pkg
    if (!fs.existsSync(path.join(nodeModules, dep))) {
      return true;
    }
  }
  return false;
}

/**
 * Probe PATH for the first available package manager.
 * Result is cached for the lifetime of the process.
 */
export function detectAvailablePackageManagerSync(): PackageManagerSpec | null {
  if (cachedPm !== undefined) {
    return cachedPm;
  }

  for (const pm of PM_CASCADE) {
    try {
      const result = spawnSync(pm.command, ["--version"], {
        timeout: 5_000,
        stdio: "ignore",
      });
      if (result.status === 0) {
        cachedPm = pm;
        return pm;
      }
    } catch {
      // Not available — try next
    }
  }

  cachedPm = null;
  return null;
}

/** Reset the cached PM detection result. For tests only. */
export function resetPackageManagerCache(): void {
  cachedPm = undefined;
}

type EnsureResult = { ok: true } | { ok: false; error: string };

/**
 * Ensure a bundled extension's npm dependencies are installed (sync).
 * Checks for missing deps via existsSync, then runs a synchronous PM install
 * if needed. Returns `{ ok: true }` on success or skip, `{ ok: false, error }`
 * on failure. Called from the plugin loader before jiti loads the module.
 */
export function ensureExtensionDepsSync(params: {
  packageDir: string;
  pluginId: string;
  logger: { info?: (msg: string) => void; error?: (msg: string) => void };
}): EnsureResult {
  if (!hasMissingDependenciesSync(params.packageDir)) {
    return { ok: true };
  }

  const pm = detectAvailablePackageManagerSync();
  if (!pm) {
    return { ok: false, error: "no package manager found on PATH (need npm, pnpm, yarn, or bun)" };
  }

  params.logger.info?.(`[plugins] ${params.pluginId}: installing dependencies with ${pm.command}…`);

  const result = spawnSync(pm.command, pm.installArgs, {
    cwd: params.packageDir,
    timeout: INSTALL_TIMEOUT_MS,
    env: { ...process.env, ...INSTALL_ENV },
    stdio: ["ignore", "pipe", "pipe"],
  });

  if (result.status !== 0) {
    const stderr = result.stderr?.toString().trim() ?? "";
    const stdout = result.stdout?.toString().trim() ?? "";
    const detail = stderr || stdout || `exit code ${result.status}`;
    return { ok: false, error: `${pm.command} install failed: ${detail}` };
  }

  return { ok: true };
}

/**
 * Ensure a bundled extension's npm dependencies are installed (async).
 * Same logic as the sync variant but uses `execFile` for non-blocking install.
 * Called from `openclaw extensions enable` for first-enable UX with a spinner.
 */
export async function ensureExtensionDepsAsync(params: {
  packageDir: string;
  pluginId: string;
}): Promise<EnsureResult> {
  if (!hasMissingDependenciesSync(params.packageDir)) {
    return { ok: true };
  }

  const pm = detectAvailablePackageManagerSync();
  if (!pm) {
    return { ok: false, error: "no package manager found on PATH (need npm, pnpm, yarn, or bun)" };
  }

  try {
    await execFileAsync(pm.command, pm.installArgs, {
      cwd: params.packageDir,
      timeout: INSTALL_TIMEOUT_MS,
      env: { ...process.env, ...INSTALL_ENV },
    });
  } catch (err: unknown) {
    const detail =
      err && typeof err === "object" && "stderr" in err
        ? String((err as { stderr: unknown }).stderr).trim()
        : String(err);
    return { ok: false, error: `${pm.command} install failed: ${detail || String(err)}` };
  }

  return { ok: true };
}
TSEOF
echo "[26843] Created $FILE1"

# ── 2. Modify src/plugins/bundled-dir.ts ──────────────────────────────────
FILE2="src/plugins/bundled-dir.ts"
[ -f "$FILE2" ] || { echo "[26843] ERROR: $FILE2 not found"; exit 1; }

python3 - "$FILE2" << 'PYEOF'
import sys

filepath = sys.argv[1]
with open(filepath, 'r') as f:
    content = f.read()

# Add resolveBundledExtensionDir function at the end of the file
new_function = '''

/**
 * Resolve the on-disk directory for a bundled extension by plugin id.
 * Returns undefined if the extension is not found in the bundled plugins dir.
 */
export function resolveBundledExtensionDir(pluginId: string): string | undefined {
  const root = resolveBundledPluginsDir();
  if (!root) {
    return undefined;
  }
  const dir = path.join(root, pluginId);
  if (fs.existsSync(path.join(dir, "package.json"))) {
    return dir;
  }
  return undefined;
}
'''

if 'resolveBundledExtensionDir' not in content:
    content = content.rstrip() + '\n' + new_function
else:
    print(f"[26843] resolveBundledExtensionDir already exists in {filepath}")

with open(filepath, 'w') as f:
    f.write(content)

print(f"[26843] Modified {filepath}")
PYEOF

# ── 3. Modify src/plugins/loader.ts ──────────────────────────────────────
FILE3="src/plugins/loader.ts"
[ -f "$FILE3" ] || { echo "[26843] ERROR: $FILE3 not found"; exit 1; }

python3 - "$FILE3" << 'PYEOF'
import sys

filepath = sys.argv[1]
with open(filepath, 'r') as f:
    content = f.read()

# --- 3a. Add import for ensureExtensionDepsSync ---
old_import = 'import { initializeGlobalHookRunner } from "./hook-runner-global.js";'
new_import = 'import { ensureExtensionDepsSync } from "./ensure-extension-deps.js";\nimport { initializeGlobalHookRunner } from "./hook-runner-global.js";'

if 'ensureExtensionDepsSync' not in content:
    if old_import in content:
        content = content.replace(old_import, new_import, 1)
    else:
        print(f"[26843] WARNING: Could not find hook-runner-global import in {filepath}")

# --- 3b. Add lazy-install block before jiti load ---
# Find the pattern: safeSource assigned, fd closed, then jiti load
old_jiti_load = '''    const safeSource = opened.path;
    fs.closeSync(opened.fd);

    let mod: OpenClawPluginModule | null = null;
    try {
      mod = getJiti()(safeSource) as OpenClawPluginModule;'''

new_jiti_load = '''    const safeSource = opened.path;
    fs.closeSync(opened.fd);

    // Lazy-install bundled extension dependencies.
    // Bundled extensions ship without node_modules/; install deps before jiti load.
    if (candidate.origin === "bundled") {
      const installResult = ensureExtensionDepsSync({
        packageDir: candidate.rootDir,
        pluginId,
        logger,
      });
      if (!installResult.ok) {
        recordPluginError({
          logger,
          registry,
          record,
          seenIds,
          pluginId,
          origin: candidate.origin,
          error: installResult.error,
          logPrefix: `[plugins] ${record.id} `,
          diagnosticMessagePrefix: "dependency install failed: ",
        });
        continue;
      }
    }

    let mod: OpenClawPluginModule | null = null;
    try {
      mod = getJiti()(safeSource) as OpenClawPluginModule;'''

if old_jiti_load in content:
    content = content.replace(old_jiti_load, new_jiti_load, 1)
else:
    print(f"[26843] WARNING: Could not find jiti load block in {filepath}")

with open(filepath, 'w') as f:
    f.write(content)

print(f"[26843] Modified {filepath}")
PYEOF

# ── 4. Modify src/cli/plugins-cli.ts ─────────────────────────────────────
FILE4="src/cli/plugins-cli.ts"
[ -f "$FILE4" ] || { echo "[26843] ERROR: $FILE4 not found"; exit 1; }

python3 - "$FILE4" << 'PYEOF'
import sys

filepath = sys.argv[1]
with open(filepath, 'r') as f:
    content = f.read()

# --- 4a. Add imports ---
# Add resolveBundledExtensionDir import
if 'resolveBundledExtensionDir' not in content:
    # Add after resolveArchiveKind import
    old_archive = 'import { resolveArchiveKind } from "../infra/archive.js";'
    new_archive = '''import { resolveArchiveKind } from "../infra/archive.js";
import { resolveBundledExtensionDir } from "../plugins/bundled-dir.js";
import {
  ensureExtensionDepsAsync,
  hasMissingDependenciesSync,
} from "../plugins/ensure-extension-deps.js";'''
    if old_archive in content:
        content = content.replace(old_archive, new_archive, 1)

# Add withProgress import
if 'withProgress' not in content:
    old_prompt = 'import { promptYesNo } from "./prompt.js";'
    # Check if this import pattern exists (may vary)
    if old_prompt in content:
        content = content.replace(old_prompt, 'import { withProgress } from "./progress.js";\nimport { promptYesNo } from "./prompt.js";', 1)
    else:
        # Try inserting after the last import
        lines = content.split('\n')
        last_import_idx = 0
        for i, line in enumerate(lines):
            if line.startswith('import '):
                last_import_idx = i
        lines.insert(last_import_idx + 1, 'import { withProgress } from "./progress.js";')
        content = '\n'.join(lines)

# --- 4b. Add dep install after enable ---
old_enable = '''      if (enableResult.enabled) {
        defaultRuntime.log(`Enabled plugin "${id}". Restart the gateway to apply.`);
        return;
      }'''

new_enable = '''      if (enableResult.enabled) {
        // Async dep install for bundled extensions with missing dependencies.
        const bundledExtDir = resolveBundledExtensionDir(id);
        if (bundledExtDir && hasMissingDependenciesSync(bundledExtDir)) {
          const result = await withProgress(
            { label: `Installing ${id} dependencies…`, indeterminate: true },
            () => ensureExtensionDepsAsync({ packageDir: bundledExtDir, pluginId: id }),
          );
          if (!result.ok) {
            defaultRuntime.log(
              theme.warn(
                `Could not install dependencies for "${id}": ${result.error}\\n` +
                  `Dependencies will be installed on next gateway start.`,
              ),
            );
          }
        }
        defaultRuntime.log(`Enabled plugin "${id}". Restart the gateway to apply.`);
        return;
      }'''

if old_enable in content:
    content = content.replace(old_enable, new_enable, 1)
else:
    print(f"[26843] WARNING: Could not find enable block in {filepath}")

with open(filepath, 'w') as f:
    f.write(content)

print(f"[26843] Modified {filepath}")
PYEOF

# ── 5. Modify src/agents/pi-embedded-utils.ts ────────────────────────────
# Add stripToolXmlBlocks function
FILE5="src/agents/pi-embedded-utils.ts"
[ -f "$FILE5" ] || { echo "[26843] ERROR: $FILE5 not found"; exit 1; }

python3 - "$FILE5" << 'PYEOF'
import sys

filepath = sys.argv[1]
with open(filepath, 'r') as f:
    content = f.read()

if 'stripToolXmlBlocks' in content:
    print(f"[26843] stripToolXmlBlocks already exists in {filepath} — skipping")
    sys.exit(0)

# Insert before inferToolMetaFromArgs
new_function = '''
// Regex matching Anthropic-style tool XML tags that leak via OpenAI-compatible proxies.
const TOOL_XML_TAG_SCAN_RE =
  /<\\s*(\\/?)\\s*(?:antml_function_calls|antml_invoke|tool_call|tool_result)\\b[^>]*>/gi;

/**
 * Stateful tool XML block stripper for streaming paths.
 *
 * Tracks open/close depth across calls so that tool XML blocks split across
 * chunk boundaries are fully suppressed. Content inside tool XML (depth > 0)
 * is dropped; content outside is preserved.
 *
 * @param text           The current chunk text (post-thinking-strip).
 * @param state          Mutable state; `toolXmlDepth` is updated across calls.
 * @param isInsideCodeSpan Optional predicate — tags inside backtick code spans are preserved.
 */
export function stripToolXmlBlocks(
  text: string,
  state: { toolXmlDepth: number },
  isInsideCodeSpan?: (index: number) => boolean,
): string {
  // Fast path: skip regex scan when no tool XML markers present and not inside an open block.
  if (
    state.toolXmlDepth === 0 &&
    !/<\\s*\\/?(?:antml_function_calls|antml_invoke|tool_call|tool_result)\\b/i.test(text)
  ) {
    return text;
  }

  let result = "";
  let lastIndex = 0;
  let depth = state.toolXmlDepth;
  TOOL_XML_TAG_SCAN_RE.lastIndex = 0;

  for (const match of text.matchAll(TOOL_XML_TAG_SCAN_RE)) {
    const idx = match.index ?? 0;
    if (isInsideCodeSpan?.(idx)) {
      continue;
    }
    const isClose = match[1] === "/";

    // Emit text before this tag only when outside tool XML blocks.
    // Covers both open tags (entering a block) and orphaned close tags (strip the tag itself).
    if (depth === 0) {
      result += text.slice(lastIndex, idx);
    }

    if (isClose) {
      depth = Math.max(0, depth - 1);
    } else {
      depth += 1;
    }
    lastIndex = idx + match[0].length;
  }

  // Emit trailing text only when outside tool XML blocks.
  if (depth === 0) {
    result += text.slice(lastIndex);
  }

  state.toolXmlDepth = depth;
  return result;
}

'''

old_infer = 'export function inferToolMetaFromArgs(toolName: string, args: unknown): string | undefined {'
if old_infer in content:
    content = content.replace(old_infer, new_function + old_infer, 1)
else:
    print(f"[26843] WARNING: Could not find inferToolMetaFromArgs in {filepath}")

with open(filepath, 'w') as f:
    f.write(content)

print(f"[26843] Modified {filepath}")
PYEOF

# ── 6. Modify src/agents/pi-embedded-subscribe.handlers.types.ts ─────────
# Add toolXmlDepth to blockState and partialBlockState types + stripBlockTags signature
FILE6="src/agents/pi-embedded-subscribe.handlers.types.ts"
[ -f "$FILE6" ] || { echo "[26843] ERROR: $FILE6 not found"; exit 1; }

python3 - "$FILE6" << 'PYEOF'
import sys

filepath = sys.argv[1]
with open(filepath, 'r') as f:
    content = f.read()

if 'toolXmlDepth' in content:
    print(f"[26843] toolXmlDepth already exists in {filepath} — skipping")
    sys.exit(0)

# Update blockState type
old_block = '  blockState: { thinking: boolean; final: boolean; inlineCode: InlineCodeState };'
new_block = '  blockState: { thinking: boolean; final: boolean; toolXmlDepth: number; inlineCode: InlineCodeState };'
content = content.replace(old_block, new_block, 1)

# Update partialBlockState type
old_partial = '  partialBlockState: { thinking: boolean; final: boolean; inlineCode: InlineCodeState };'
new_partial = '  partialBlockState: { thinking: boolean; final: boolean; toolXmlDepth: number; inlineCode: InlineCodeState };'
content = content.replace(old_partial, new_partial, 1)

# Update stripBlockTags signature
old_strip = '    state: { thinking: boolean; final: boolean; inlineCode?: InlineCodeState },'
new_strip = '    state: { thinking: boolean; final: boolean; toolXmlDepth?: number; inlineCode?: InlineCodeState },'
content = content.replace(old_strip, new_strip, 1)

with open(filepath, 'w') as f:
    f.write(content)

print(f"[26843] Modified {filepath}")
PYEOF

# ── 7. Modify src/agents/pi-embedded-subscribe.ts ────────────────────────
# Add toolXmlDepth to state initialization, resets, stripBlockTags, and import
FILE7="src/agents/pi-embedded-subscribe.ts"
[ -f "$FILE7" ] || { echo "[26843] ERROR: $FILE7 not found"; exit 1; }

python3 - "$FILE7" << 'PYEOF'
import sys

filepath = sys.argv[1]
with open(filepath, 'r') as f:
    content = f.read()

if 'toolXmlDepth' in content:
    print(f"[26843] toolXmlDepth already exists in {filepath} — skipping")
    sys.exit(0)

# --- 7a. Add stripToolXmlBlocks to import ---
old_import = 'import { formatReasoningMessage, stripDowngradedToolCallText } from "./pi-embedded-utils.js";'
new_import = '''import {
  formatReasoningMessage,
  stripDowngradedToolCallText,
  stripToolXmlBlocks,
} from "./pi-embedded-utils.js";'''

if old_import in content:
    content = content.replace(old_import, new_import, 1)

# --- 7b. Add toolXmlDepth to initial state ---
old_state1 = '    blockState: { thinking: false, final: false, inlineCode: createInlineCodeState() },'
new_state1 = '    blockState: { thinking: false, final: false, toolXmlDepth: 0, inlineCode: createInlineCodeState() },'
content = content.replace(old_state1, new_state1, 1)

old_state2 = '    partialBlockState: { thinking: false, final: false, inlineCode: createInlineCodeState() },'
new_state2 = '    partialBlockState: { thinking: false, final: false, toolXmlDepth: 0, inlineCode: createInlineCodeState() },'
content = content.replace(old_state2, new_state2, 1)

# --- 7c. Add toolXmlDepth resets ---
# First reset: after state.blockState.final = false;
old_reset1 = '    state.blockState.final = false;\n    state.blockState.inlineCode = createInlineCodeState();'
new_reset1 = '    state.blockState.final = false;\n    state.blockState.toolXmlDepth = 0;\n    state.blockState.inlineCode = createInlineCodeState();'
content = content.replace(old_reset1, new_reset1, 1)

old_reset2 = '    state.partialBlockState.final = false;\n    state.partialBlockState.inlineCode = createInlineCodeState();'
new_reset2 = '    state.partialBlockState.final = false;\n    state.partialBlockState.toolXmlDepth = 0;\n    state.partialBlockState.inlineCode = createInlineCodeState();'
content = content.replace(old_reset2, new_reset2, 1)

# --- 7d. Update stripBlockTags signature ---
old_strip_sig = '    state: { thinking: boolean; final: boolean; inlineCode?: InlineCodeState },'
new_strip_sig = '''    state: {
      thinking: boolean;
      final: boolean;
      toolXmlDepth?: number;
      inlineCode?: InlineCodeState;
    },'''
content = content.replace(old_strip_sig, new_strip_sig, 1)

# --- 7e. Add stripToolXmlBlocks call after thinking strip ---
# Insert after: state.thinking = inThinking;
# And before: // 2. Handle <final> blocks
old_thinking_end = '    state.thinking = inThinking;\n\n    // 2. Handle <final> blocks'
new_thinking_end = '''    state.thinking = inThinking;

    // 1.5. Handle tool XML blocks (stateful, strip content inside — depth-counted).
    const toolXmlState = { toolXmlDepth: state.toolXmlDepth ?? 0 };
    const toolCodeSpans = buildCodeSpanIndex(processed, inlineStateStart);
    processed = stripToolXmlBlocks(processed, toolXmlState, toolCodeSpans.isInside);
    state.toolXmlDepth = toolXmlState.toolXmlDepth;

    // 2. Handle <final> blocks'''

if old_thinking_end in content:
    content = content.replace(old_thinking_end, new_thinking_end, 1)
else:
    print(f"[26843] WARNING: Could not find thinking end -> final block transition in {filepath}")

with open(filepath, 'w') as f:
    f.write(content)

print(f"[26843] Modified {filepath}")
PYEOF

# ── 8. Modify src/agents/pi-embedded-subscribe.handlers.messages.ts ──────
# Add toolXmlDepth = 0 reset in handleMessageEnd
FILE8="src/agents/pi-embedded-subscribe.handlers.messages.ts"
[ -f "$FILE8" ] || { echo "[26843] ERROR: $FILE8 not found"; exit 1; }

python3 - "$FILE8" << 'PYEOF'
import sys

filepath = sys.argv[1]
with open(filepath, 'r') as f:
    content = f.read()

if 'toolXmlDepth' in content:
    print(f"[26843] toolXmlDepth already exists in {filepath} — skipping")
    sys.exit(0)

# Add toolXmlDepth = 0 after blockState.final = false
old_msg_end = '  ctx.state.blockState.final = false;\n  ctx.state.blockState.inlineCode = createInlineCodeState();'
new_msg_end = '  ctx.state.blockState.final = false;\n  ctx.state.blockState.toolXmlDepth = 0;\n  ctx.state.blockState.inlineCode = createInlineCodeState();'

if old_msg_end in content:
    content = content.replace(old_msg_end, new_msg_end, 1)
else:
    print(f"[26843] WARNING: Could not find blockState reset in {filepath}")

with open(filepath, 'w') as f:
    f.write(content)

print(f"[26843] Modified {filepath}")
PYEOF

echo "[26843] Patch applied successfully"
