#!/usr/bin/env bash
set -euo pipefail
cd "$1"

# PR #24806 - fix(onboarding): fallback install when core channel plugin is missing

TARGET="src/commands/onboard-channels.ts"

if [ ! -f "$TARGET" ]; then
  echo "FAIL: $TARGET not found"
  exit 1
fi

if grep -q 'CORE_CHANNEL_NPM_FALLBACK_SPECS' "$TARGET"; then
  echo "SKIP: onboarding fallback already applied in $TARGET"
  exit 0
fi

if ! grep -q 'ensureBundledPluginEnabled' "$TARGET"; then
  echo "FAIL: ensureBundledPluginEnabled not found in $TARGET"
  exit 1
fi

python3 << 'PYEOF'
import re
import sys

target = "src/commands/onboard-channels.ts"
with open(target, "r") as f:
    content = f.read()

errors = []

# STEP 1: Add ChannelPluginCatalogEntry type import
if 'type ChannelPluginCatalogEntry' not in content:
    catalog_import = re.search(
        r'import\s*\{([^}]*listChannelPluginCatalogEntries[^}]*)\}\s*from\s*["\'](\.\./channels/plugins/catalog\.js)["\'];?',
        content
    )
    if catalog_import:
        old_imports = catalog_import.group(1)
        new_imports = old_imports.rstrip() + ",\n  type ChannelPluginCatalogEntry,\n"
        content = content[:catalog_import.start(1)] + new_imports + content[catalog_import.end(1):]
        print("OK: Added ChannelPluginCatalogEntry type import")
    else:
        catalog_line = re.search(r'.*catalog\.js.*\n', content)
        if catalog_line:
            content = content[:catalog_line.end()] + 'import type { ChannelPluginCatalogEntry } from "../channels/plugins/catalog.js";\n' + content[catalog_line.end():]
            print("OK: Added separate ChannelPluginCatalogEntry type import")
        else:
            errors.append("Could not find catalog.js import")

# STEP 2: Add CORE_CHANNEL_NPM_FALLBACK_SPECS
new_code_block = '''\nconst CORE_CHANNEL_NPM_FALLBACK_SPECS: Partial<Record<ChannelChoice, string>> = {\n  discord: "@openclaw/discord",\n};\n\nfunction buildCoreChannelInstallFallbackEntry(\n  channel: ChannelChoice,\n): ChannelPluginCatalogEntry | null {\n  const npmSpec = CORE_CHANNEL_NPM_FALLBACK_SPECS[channel];\n  if (!npmSpec) {\n    return null;\n  }\n  const meta = listChatChannels().find((entry) => entry.id === channel);\n  if (!meta) {\n    return null;\n  }\n  return {\n    id: channel,\n    meta,\n    install: {\n      npmSpec,\n      defaultChoice: "npm",\n    },\n  };\n}\n\n'''

insert_match = re.search(r'\n(async\s+function\s+maybeConfigureDmPolicies)', content)
if insert_match:
    insert_pos = insert_match.start(1)
    content = content[:insert_pos] + new_code_block.lstrip('\n') + '\n' + content[insert_pos:]
    print("OK: Added CORE_CHANNEL_NPM_FALLBACK_SPECS and buildCoreChannelInstallFallbackEntry")
else:
    errors.append("Could not find insertion point for fallback specs")

# STEP 3: Replace ensureBundledPluginEnabled
ebpe_match = re.search(r'const\s+ensureBundledPluginEnabled\s*=\s*async\s*\(', content)
if ebpe_match:
    func_start = ebpe_match.start()
    brace_depth = 0
    i = func_start
    found_first_brace = False
    func_end = None
    while i < len(content):
        ch = content[i]
        if ch == '{':
            brace_depth += 1
            found_first_brace = True
        elif ch == '}':
            brace_depth -= 1
            if found_first_brace and brace_depth == 0:
                rest = content[i+1:i+5].lstrip()
                if rest.startswith(';'):
                    func_end = i + 1 + content[i+1:i+5].index(';') + 1
                else:
                    func_end = i + 1
                break
        i += 1

    if func_end:
        new_ebpe = '''const ensureBundledPluginEnabled = async (
    channel: ChannelChoice,
    options?: { suppressUnavailableNote?: boolean },
  ): Promise<{ ok: true } | { ok: false; reason: "disabled" | "unavailable" }> => {
    if (getChannelPlugin(channel)) {
      return { ok: true };
    }
    const result = enablePluginInConfig(next, channel);
    next = result.config;
    if (!result.enabled) {
      await prompter.note(
        `Cannot enable ${channel}: ${result.reason ?? "plugin disabled"}.`,
        "Channel setup",
      );
      return { ok: false, reason: "disabled" };
    }
    const workspaceDir = resolveAgentWorkspaceDir(next, resolveDefaultAgentId(next));
    reloadOnboardingPluginRegistry({
      cfg: next,
      runtime,
      workspaceDir,
    });
    if (!getChannelPlugin(channel)) {
      if (!options?.suppressUnavailableNote) {
        await prompter.note(`${channel} plugin not available.`, "Channel setup");
      }
      return { ok: false, reason: "unavailable" };
    }
    await refreshStatus(channel);
    return { ok: true };
  };'''
        content = content[:func_start] + new_ebpe + content[func_end:]
        print("OK: Replaced ensureBundledPluginEnabled with { ok, reason } return type")
    else:
        errors.append("Could not find end of ensureBundledPluginEnabled")
else:
    errors.append("Could not find ensureBundledPluginEnabled function")

# STEP 4: Add ensureCatalogPluginInstalled helper
new_catalog_helper = '''\n\n  const ensureCatalogPluginInstalled = async (\n    entry: ChannelPluginCatalogEntry,\n  ): Promise<boolean> => {\n    const workspaceDir = resolveAgentWorkspaceDir(next, resolveDefaultAgentId(next));\n    const result = await ensureOnboardingPluginInstalled({\n      cfg: next,\n      entry,\n      prompter,\n      runtime,\n      workspaceDir,\n    });\n    next = result.cfg;\n    if (!result.installed) {\n      return false;\n    }\n    reloadOnboardingPluginRegistry({\n      cfg: next,\n      runtime,\n      workspaceDir,\n    });\n    if (!getChannelPlugin(entry.id as ChannelChoice)) {\n      await prompter.note(`${entry.id} plugin not available.`, "Channel setup");\n      return false;\n    }\n    await refreshStatus(entry.id as ChannelChoice);\n    return true;\n  };\n'''

configure_match = re.search(r'\n(\s*const\s+configureChannel\s*=\s*async)', content)
if configure_match:
    insert_pos = configure_match.start()
    content = content[:insert_pos] + new_catalog_helper + content[insert_pos:]
    print("OK: Added ensureCatalogPluginInstalled helper")
else:
    errors.append("Could not find configureChannel function")

# STEP 5: Rewrite handleChannelChoice
hcc_match = re.search(r'const\s+handleChannelChoice\s*=\s*async\s*\(', content)
if hcc_match:
    func_start = hcc_match.start()
    brace_depth = 0
    i = func_start
    found_first_brace = False
    func_end = None
    while i < len(content):
        ch = content[i]
        if ch == '{':
            brace_depth += 1
            found_first_brace = True
        elif ch == '}':
            brace_depth -= 1
            if found_first_brace and brace_depth == 0:
                rest = content[i+1:i+5].lstrip()
                if rest.startswith(';'):
                    func_end = i + 1 + content[i+1:i+5].index(';') + 1
                else:
                    func_end = i + 1
                break
        i += 1

    if func_end:
        new_hcc = '''const handleChannelChoice = async (channel: ChannelChoice) => {
    const { catalogById } = getChannelEntries();
    const catalogEntry = catalogById.get(channel);
    if (catalogEntry) {
      const installed = await ensureCatalogPluginInstalled(catalogEntry);
      if (!installed) {
        return;
      }
    } else {
      const bundled = await ensureBundledPluginEnabled(channel, {
        suppressUnavailableNote: true,
      });
      if (!bundled.ok) {
        if (bundled.reason !== "unavailable") {
          return;
        }
        const fallbackEntry = buildCoreChannelInstallFallbackEntry(channel);
        if (!fallbackEntry) {
          await prompter.note(`${channel} plugin not available.`, "Channel setup");
          return;
        }
        const installed = await ensureCatalogPluginInstalled(fallbackEntry);
        if (!installed) {
          return;
        }
      }
    }

    const plugin = getChannelPlugin(channel);
    const label = plugin?.meta.label ?? catalogEntry?.meta.label ?? channel;
    const status = statusByChannel.get(channel);
    const configured = status?.configured ?? false;
    if (configured) {
      await handleConfiguredChannel(channel, label);
      return;
    }
    await configureChannel(channel);
  };'''
        content = content[:func_start] + new_hcc + content[func_end:]
        print("OK: Replaced handleChannelChoice with fallback install logic")
    else:
        errors.append("Could not find end of handleChannelChoice")
else:
    errors.append("Could not find handleChannelChoice function")

if errors:
    for e in errors:
        print(f"FAIL: {e}", file=sys.stderr)
    sys.exit(1)

with open(target, "w") as f:
    f.write(content)

print("OK: All changes applied to onboard-channels.ts")
PYEOF

VERIFY_OK=1
if ! grep -q 'CORE_CHANNEL_NPM_FALLBACK_SPECS' "$TARGET"; then
  echo "FAIL: CORE_CHANNEL_NPM_FALLBACK_SPECS not found after patching"
  VERIFY_OK=0
fi
if ! grep -q 'ensureCatalogPluginInstalled' "$TARGET"; then
  echo "FAIL: ensureCatalogPluginInstalled not found after patching"
  VERIFY_OK=0
fi
if [ "$VERIFY_OK" -eq 1 ]; then
  echo "OK: PR #24806 applied successfully - onboarding fallback install for missing core channel plugins"
else
  exit 1
fi
