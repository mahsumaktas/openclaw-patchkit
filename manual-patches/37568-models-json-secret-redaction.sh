#!/usr/bin/env bash
set -euo pipefail
# PR #37568 — fix: redact resolved API key secrets from models.json
# Adds isEnvVarNameOrMarker() + redactResolvedSecrets() to models-config.plan.ts
# and calls redactResolvedSecrets() before serializing providers to disk.
# Preserves env var names (UPPER_SNAKE_CASE) and markers (ollama-local, aws-sdk),
# strips actual resolved API keys (sk-..., xai-..., mixed-case tokens).
#
# NOTE: v2026.3.8 refactored models-config — the plan logic moved from
# models-config.ts to models-config.plan.ts. This script targets the plan file.

SRC="${1:-.}/src"

# v2026.3.8+: plan logic is in models-config.plan.ts
PLAN_FILE="$SRC/agents/models-config.plan.ts"
# Pre-refactor fallback: models-config.ts
LEGACY_FILE="$SRC/agents/models-config.ts"

# ── Decide target file ──
if [ -f "$PLAN_FILE" ]; then
  TARGET="$PLAN_FILE"
elif [ -f "$LEGACY_FILE" ]; then
  TARGET="$LEGACY_FILE"
else
  echo "    FAIL: neither models-config.plan.ts nor models-config.ts found"
  exit 1
fi

# ── Idempotency ──
if grep -q 'redactResolvedSecrets' "$TARGET" 2>/dev/null; then
  echo "    SKIP: #37568 already applied"
  exit 0
fi

# ── Apply patch ──
python3 - "$TARGET" << 'PYEOF'
import sys

path = sys.argv[1]
with open(path, 'r') as f:
    content = f.read()

# ── 1. Add helper functions ──
# Find insertion point: after the ModelsConfig type alias
anchor = 'type ModelsConfig = NonNullable<OpenClawConfig["models"]>;'
if anchor not in content:
    anchor = "type ModelsConfig = NonNullable<OpenClawConfig['models']>;"
if anchor not in content:
    # Try to find any type ModelsConfig line
    import re
    m = re.search(r'type ModelsConfig\s*=\s*[^;]+;', content)
    if m:
        anchor = m.group(0)

if anchor not in content:
    print("    FAIL: cannot find ModelsConfig type alias in " + path)
    sys.exit(1)

idx = content.index(anchor)
insert_point = content.index('\n', idx) + 1

new_functions = '''
/**
 * Check if a string looks like an environment variable name rather than a
 * resolved secret value. Env var names are UPPER_SNAKE_CASE. Resolved secrets
 * are typically longer and contain mixed-case alphanumeric characters, dashes,
 * underscores in non-UPPER_SNAKE_CASE patterns.
 *
 * Special cases:
 * - "ollama-local" and similar synthetic markers are preserved
 * - "aws-sdk" auth mode markers are preserved
 */
function isEnvVarNameOrMarker(value: string): boolean {
  const trimmed = value.trim();
  if (!trimmed) {
    return false;
  }

  // Synthetic local provider markers (e.g., "ollama-local")
  if (trimmed === "ollama-local") {
    return true;
  }

  // AWS SDK auth marker
  if (trimmed === "aws-sdk") {
    return true;
  }

  // Environment variable name pattern: UPPER_SNAKE_CASE
  // Must start with letter, contain only uppercase letters, digits, underscores
  // Examples: OPENAI_API_KEY, ANTHROPIC_API_KEY, AWS_ACCESS_KEY_ID
  return /^[A-Z][A-Z0-9_]*$/.test(trimmed);
}

/**
 * Redact resolved secret values from provider configs before writing to disk.
 * Preserves env var names (UPPER_SNAKE_CASE) and special markers, but strips
 * actual resolved API keys to prevent plaintext secrets in models.json.
 */
function redactResolvedSecrets(
  providers: Record<string, ProviderConfig>,
): Record<string, ProviderConfig> {
  const redacted: Record<string, ProviderConfig> = {};

  for (const [key, provider] of Object.entries(providers)) {
    const { apiKey, ...rest } = provider;

    // If apiKey is undefined or empty, or looks like an env var name/marker, preserve it
    if (
      apiKey === undefined ||
      apiKey === "" ||
      (typeof apiKey === "string" && isEnvVarNameOrMarker(apiKey))
    ) {
      redacted[key] = provider;
    } else {
      // apiKey looks like a resolved secret - strip it
      redacted[key] = rest as ProviderConfig;
    }
  }

  return redacted;
}

'''

content = content[:insert_point] + new_functions + content[insert_point:]

# ── 2. Wire redactResolvedSecrets into the serialization ──
# v2026.3.8 pattern (plan file): JSON.stringify({ providers: mergedProviders }, null, 2)
old_a = 'JSON.stringify({ providers: mergedProviders }, null, 2)'
new_a = 'JSON.stringify({ providers: redactResolvedSecrets(mergedProviders) }, null, 2)'

# Pre-refactor pattern: JSON.stringify({ providers: normalizedProviders }, null, 2)
old_b = 'JSON.stringify({ providers: normalizedProviders }, null, 2)'
new_b = 'JSON.stringify({ providers: redactResolvedSecrets(normalizedProviders) }, null, 2)'

if old_a in content:
    content = content.replace(old_a, new_a, 1)
elif old_b in content:
    content = content.replace(old_b, new_b, 1)
else:
    print("    FAIL: cannot find JSON.stringify providers line")
    sys.exit(1)

with open(path, 'w') as f:
    f.write(content)
print("    OK: " + path.split('/')[-1] + " — secret redaction functions added + wired")
PYEOF

echo "    OK: #37568 secret redaction from models.json fully applied"
