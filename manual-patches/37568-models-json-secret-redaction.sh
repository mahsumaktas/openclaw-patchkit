#!/usr/bin/env bash
set -euo pipefail
# PR #37568 — fix: redact resolved API key secrets from models.json
# Adds isEnvVarNameOrMarker() + redactResolvedSecrets() to models-config.plan.ts
# and calls redactResolvedSecrets() before serializing providers to disk.
# Preserves env var names (UPPER_SNAKE_CASE) and markers (ollama-local, aws-sdk),
# strips actual resolved API keys (sk-..., xai-..., mixed-case tokens).
#
# v2026.3.13 update: the plan function now uses `secretEnforcedProviders`
# (from enforceSourceManagedProviderSecrets) instead of `mergedProviders`.
# The script targets all known variable names across versions.

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
import re

path = sys.argv[1]
with open(path, 'r') as f:
    content = f.read()

# ── 1. Find insertion point for helper functions ──
# Try multiple anchors in order of preference:
# a) ModelsConfig type alias (v2026.3.8+)
# b) ModelsJsonPlan type (v2026.3.8+)
# c) planOpenClawModelsJson function (universal fallback)
insert_point = None

# Try type alias first
for anchor_pattern in [
    r'type\s+ModelsConfig\s*=\s*[^;]+;',
    r'type\s+ModelsJsonPlan\s*=\s*\{[^}]*\}\s*\|\s*\{[^}]*\}\s*\|\s*\{[^}]*\};',
]:
    m = re.search(anchor_pattern, content, re.DOTALL)
    if m:
        # Insert after this declaration
        end = m.end()
        nl = content.find('\n', end)
        insert_point = nl + 1 if nl != -1 else end
        break

# Fallback: insert just before planOpenClawModelsJson
if insert_point is None:
    m = re.search(r'(?:export\s+)?(?:async\s+)?function\s+planOpenClawModelsJson', content)
    if m:
        insert_point = m.start()

if insert_point is None:
    print("    FAIL: cannot find insertion anchor in " + path)
    sys.exit(1)

new_functions = '''
/**
 * Check if a string looks like an environment variable name or a known
 * synthetic marker rather than a resolved secret value.
 * Env var names are UPPER_SNAKE_CASE. Resolved secrets are typically longer
 * mixed-case alphanumeric strings (sk-..., xai-..., etc.).
 *
 * Special cases preserved:
 * - "ollama-local" and similar synthetic markers
 * - "aws-sdk" auth mode markers
 */
function isEnvVarNameOrMarker(value: string): boolean {
  const trimmed = value.trim();
  if (!trimmed) return false;

  // Synthetic local provider markers
  if (trimmed === "ollama-local") return true;

  // AWS SDK auth marker
  if (trimmed === "aws-sdk") return true;

  // Environment variable name pattern: UPPER_SNAKE_CASE
  // Must start with letter, contain only uppercase letters, digits, underscores
  return /^[A-Z][A-Z0-9_]*$/.test(trimmed);
}

/**
 * Redact resolved secret values from provider configs before writing to disk.
 * Preserves env var names (UPPER_SNAKE_CASE) and special markers, but strips
 * actual resolved API keys to prevent plaintext secrets in models.json.
 */
function redactResolvedSecrets(
  providers: NonNullable<Record<string, any>>,
): Record<string, any> {
  const redacted: Record<string, any> = {};

  for (const [key, provider] of Object.entries(providers)) {
    if (!provider || typeof provider !== "object") {
      redacted[key] = provider;
      continue;
    }
    const { apiKey, ...rest } = provider;

    // If apiKey is undefined/empty or looks like an env var name/marker, keep it
    if (
      apiKey === undefined ||
      apiKey === "" ||
      (typeof apiKey === "string" && isEnvVarNameOrMarker(apiKey))
    ) {
      redacted[key] = provider;
    } else {
      // apiKey looks like a resolved secret — strip it
      redacted[key] = rest;
    }
  }

  return redacted;
}

'''

content = content[:insert_point] + new_functions + content[insert_point:]

# ── 2. Wire redactResolvedSecrets into the serialization ──
# Try all known variable name patterns across OpenClaw versions:
#   v2026.3.13+: secretEnforcedProviders (after enforceSourceManagedProviderSecrets)
#   v2026.3.8-3.12: mergedProviders (after resolveProvidersForMode)
#   pre-3.8: normalizedProviders (after normalizeProviders)
replacements = [
    ('JSON.stringify({ providers: secretEnforcedProviders }',
     'JSON.stringify({ providers: redactResolvedSecrets(secretEnforcedProviders) }'),
    ('JSON.stringify({ providers: mergedProviders }',
     'JSON.stringify({ providers: redactResolvedSecrets(mergedProviders) }'),
    ('JSON.stringify({ providers: normalizedProviders }',
     'JSON.stringify({ providers: redactResolvedSecrets(normalizedProviders) }'),
]

applied = False
for old, new in replacements:
    if old in content:
        content = content.replace(old, new, 1)
        applied = True
        break

if not applied:
    # Last resort: regex match for any JSON.stringify({ providers: <identifier> }
    m = re.search(
        r'JSON\.stringify\(\{\s*providers:\s*(\w+)\s*\}',
        content
    )
    if m:
        var_name = m.group(1)
        old_str = m.group(0)
        new_str = old_str.replace(
            f'providers: {var_name}',
            f'providers: redactResolvedSecrets({var_name})'
        )
        content = content.replace(old_str, new_str, 1)
        applied = True

if not applied:
    print("    FAIL: cannot find JSON.stringify providers line in " + path)
    sys.exit(1)

with open(path, 'w') as f:
    f.write(content)
print("    OK: " + path.split('/')[-1] + " — secret redaction functions added + wired")
PYEOF

echo "    OK: #37568 secret redaction from models.json fully applied"
