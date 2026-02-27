#!/usr/bin/env bash
# PR #20185 — fix(model): recognize default/reset/clear keywords to clear session model override
# Adds support for "/model default", "/model reset", "/model clear" to restore the
# configured default model without needing to specify the exact provider/model string.
set +e

SRC="${1:?Usage: $0 <openclaw-source-dir>}"

DIRECTIVE="$SRC/src/auto-reply/reply/directive-handling.model.ts"
SELECTION="$SRC/src/auto-reply/reply/model-selection.ts"

if [ ! -f "$DIRECTIVE" ] || [ ! -f "$SELECTION" ]; then
  echo "SKIP: required source files not found"
  exit 0
fi

# ── Idempotency check ──
if grep -q 'wantsReset' "$DIRECTIVE" && grep -q 'rawLower === "default"' "$SELECTION"; then
  echo "Already applied: 20185-model-reset-keywords"
  exit 0
fi

# ── 1. Patch model-selection.ts — add reset keywords to resolveModelDirectiveSelection ──
python3 -c "
import sys

path = sys.argv[1]
with open(path, 'r') as f:
    content = f.read()

# Insert reset keyword check after rawLower declaration, before pickAliasForKey
marker = '  const pickAliasForKey = (provider: string, model: string): string | undefined =>'

if marker not in content:
    print('ERROR: Could not find pickAliasForKey in model-selection.ts')
    sys.exit(1)

reset_block = '''  // Reserved reset keywords (single token, no slash) clear the session model override
  // and fall back to the configured default without going through allowlist validation.
  // \"provider/default\" (contains a slash) is still treated as a literal model id.
  if (
    (rawLower === \"default\" || rawLower === \"reset\" || rawLower === \"clear\") &&
    !rawTrimmed.includes(\"/\")
  ) {
    return {
      selection: {
        provider: defaultProvider,
        model: defaultModel,
        isDefault: true,
      },
    };
  }

'''

content = content.replace(marker, reset_block + marker, 1)

with open(path, 'w') as f:
    f.write(content)
print('OK: model-selection.ts patched with reset keywords')
" "$SELECTION"

if [ $? -ne 0 ]; then
  echo "FAIL: Could not patch model-selection.ts"
  exit 1
fi

# ── 2. Patch directive-handling.model.ts — maybeHandleModelDirectiveInfo ──
# Add wantsReset detection and early return for reset keywords

python3 -c "
import sys

path = sys.argv[1]
with open(path, 'r') as f:
    content = f.read()

# Part 2a: Add wantsReset to the guard condition
old_guard = '''  const wantsLegacyList = directive === \"list\";
  if (!wantsSummary && !wantsStatus && !wantsLegacyList) {
    return undefined;
  }'''

new_guard = '''  const wantsLegacyList = directive === \"list\";
  // Reset keywords are handled by resolveModelSelectionFromDirective; skip info display.
  const wantsReset = directive === \"default\" || directive === \"reset\" || directive === \"clear\";
  if (!wantsSummary && !wantsStatus && !wantsLegacyList && !wantsReset) {
    return undefined;
  }'''

if old_guard not in content:
    print('ERROR: Could not find guard condition in directive-handling.model.ts')
    sys.exit(1)

content = content.replace(old_guard, new_guard, 1)

with open(path, 'w') as f:
    f.write(content)
print('OK: directive-handling.model.ts guard patched')
" "$DIRECTIVE"

if [ $? -ne 0 ]; then
  echo "FAIL: Could not patch guard condition"
  exit 1
fi

# Part 2b: Add wantsReset early return after wantsLegacyList block
python3 -c "
import sys

path = sys.argv[1]
with open(path, 'r') as f:
    content = f.read()

# Insert after the wantsLegacyList block's closing brace
old_after_list = '''    return reply ?? { text: \"No models available.\" };
  }

  if (wantsSummary) {'''

new_after_list = '''    return reply ?? { text: \"No models available.\" };
  }

  // Reset keywords (default/reset/clear) are handled by resolveModelSelectionFromDirective;
  // return undefined here so the caller proceeds to model selection handling.
  if (wantsReset) {
    return undefined;
  }

  if (wantsSummary) {'''

if old_after_list not in content:
    print('ERROR: Could not find wantsLegacyList/wantsSummary boundary')
    sys.exit(1)

content = content.replace(old_after_list, new_after_list, 1)

with open(path, 'w') as f:
    f.write(content)
print('OK: wantsReset early return added')
" "$DIRECTIVE"

if [ $? -ne 0 ]; then
  echo "FAIL: Could not add wantsReset early return"
  exit 1
fi

# Part 2c: Add reset keyword handling in resolveModelSelectionFromDirective
# Insert before resolveModelRefFromString call
python3 -c "
import sys

path = sys.argv[1]
with open(path, 'r') as f:
    content = f.read()

old_explicit = '''  const explicit = resolveModelRefFromString({
    raw,
    defaultProvider: params.defaultProvider,
    aliasIndex: params.aliasIndex,
  });'''

new_explicit = '''  // Reserved reset keywords (single token, no slash) clear the session model override
  // and fall back to the configured default. \"provider/default\" is still a valid model id.
  const rawLower = raw.toLowerCase();
  if (
    (rawLower === \"default\" || rawLower === \"reset\" || rawLower === \"clear\") &&
    !raw.includes(\"/\")
  ) {
    return {
      modelSelection: {
        provider: params.defaultProvider,
        model: params.defaultModel,
        isDefault: true,
      },
    };
  }

  const explicit = resolveModelRefFromString({
    raw,
    defaultProvider: params.defaultProvider,
    aliasIndex: params.aliasIndex,
  });'''

if old_explicit not in content:
    print('ERROR: Could not find resolveModelRefFromString call in resolveModelSelectionFromDirective')
    sys.exit(1)

content = content.replace(old_explicit, new_explicit, 1)

with open(path, 'w') as f:
    f.write(content)
print('OK: resolveModelSelectionFromDirective reset keywords added')
" "$DIRECTIVE"

if [ $? -ne 0 ]; then
  echo "FAIL: Could not add reset keywords to resolveModelSelectionFromDirective"
  exit 1
fi

# Part 2d: Add help text for reset command in Telegram and non-Telegram views
python3 -c "
import sys

path = sys.argv[1]
with open(path, 'r') as f:
    content = f.read()

# Telegram help text
old_tg = '''          \"/model <provider/model> to switch\",
          \"/model status for details\",'''

new_tg = '''          \"/model <provider/model> to switch\",
          \"/model default (or reset/clear) to restore default\",
          \"/model status for details\",'''

if old_tg in content:
    content = content.replace(old_tg, new_tg, 1)
    print('OK: Telegram help text updated')
else:
    print('WARN: Telegram help text pattern not found (may be different format)')

# Non-Telegram help text
old_generic = '''        \"Switch: /model <provider/model>\",
        \"Browse: /models (providers) or /models <provider> (models)\",'''

new_generic = '''        \"Switch: /model <provider/model>\",
        \"Reset:  /model default (or reset, clear)\",
        \"Browse: /models (providers) or /models <provider> (models)\",'''

if old_generic in content:
    content = content.replace(old_generic, new_generic, 1)
    print('OK: generic help text updated')
else:
    print('WARN: generic help text pattern not found')

with open(path, 'w') as f:
    f.write(content)
" "$DIRECTIVE"

echo "DONE: 20185-model-reset-keywords applied"
