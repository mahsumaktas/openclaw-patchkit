#!/usr/bin/env bash
# Issue #24008: fix(config): don't reject entire config for unrecognized keys
#
# Problem: Zod .strict() schemas cause validation to fail when a config section
# contains unrecognized keys (e.g., typos, keys from a newer version, or keys
# from a different context like sandbox vs host browser). The validation failure
# makes loadConfig() return {} — which silently resets the ENTIRE config,
# including all valid keys in the affected section.
#
# Fix: In validateConfigObjectRaw(), when Zod validation fails ONLY due to
# unrecognized keys (code === "unrecognized_keys"), strip those keys and
# re-validate. The unrecognized keys are reported as warnings, not errors.
# This preserves all valid config values instead of dropping everything.
#
# Changes:
#   1. src/config/validation.ts — add fallback re-validation that strips
#      unrecognized keys and reports them as warnings
set -euo pipefail

SRC="${1:-.}/src"
FILE="$SRC/config/validation.ts"
[ -f "$FILE" ] || { echo "    FAIL: $FILE not found"; exit 1; }

# ── Idempotency gate ─────────────────────────────────────────────────────────
if grep -q 'unrecognized_keys' "$FILE" 2>/dev/null; then
  echo "    SKIP: #24008 already applied"
  exit 0
fi

python3 - "$FILE" << 'PYEOF'
import sys

filepath = sys.argv[1]
with open(filepath, "r") as f:
    code = f.read()

# ── Change 1: Add the stripAndRetry import + helper at the top of the function ──

old_validate = """export function validateConfigObjectRaw(
  raw: unknown,
): { ok: true; config: OpenClawConfig } | { ok: false; issues: ConfigValidationIssue[] } {
  const legacyIssues = findLegacyConfigIssues(raw);
  if (legacyIssues.length > 0) {
    return {
      ok: false,
      issues: legacyIssues.map((iss) => ({
        path: iss.path,
        message: iss.message,
      })),
    };
  }
  const validated = OpenClawSchema.safeParse(raw);
  if (!validated.success) {
    return {
      ok: false,
      issues: validated.error.issues.map((iss) => ({
        path: iss.path.join("."),
        message: iss.message,
      })),
    };
  }"""

new_validate = """export function validateConfigObjectRaw(
  raw: unknown,
): { ok: true; config: OpenClawConfig; warnings?: ConfigValidationIssue[] } | { ok: false; issues: ConfigValidationIssue[] } {
  const legacyIssues = findLegacyConfigIssues(raw);
  if (legacyIssues.length > 0) {
    return {
      ok: false,
      issues: legacyIssues.map((iss) => ({
        path: iss.path,
        message: iss.message,
      })),
    };
  }
  const validated = OpenClawSchema.safeParse(raw);
  if (!validated.success) {
    // #24008: If the ONLY errors are unrecognized keys, strip them and retry
    // instead of rejecting the entire config. Report stripped keys as warnings.
    const unrecognizedIssues = validated.error.issues.filter(
      (iss) => iss.code === "unrecognized_keys",
    );
    const otherIssues = validated.error.issues.filter(
      (iss) => iss.code !== "unrecognized_keys",
    );
    if (unrecognizedIssues.length > 0 && otherIssues.length === 0 && raw && typeof raw === "object") {
      // Strip unrecognized keys by deep-cloning and removing them
      const stripped = structuredClone(raw) as Record<string, unknown>;
      const warnings: ConfigValidationIssue[] = [];
      for (const iss of unrecognizedIssues) {
        const issPath = iss.path.join(".");
        const keys = "keys" in iss && Array.isArray(iss.keys) ? iss.keys : [];
        let target: unknown = stripped;
        for (const segment of iss.path) {
          if (target && typeof target === "object" && !Array.isArray(target)) {
            target = (target as Record<string, unknown>)[String(segment)];
          } else {
            target = undefined;
            break;
          }
        }
        if (target && typeof target === "object" && !Array.isArray(target)) {
          const record = target as Record<string, unknown>;
          for (const key of keys) {
            if (typeof key === "string" && key in record) {
              delete record[key];
              const fullPath = issPath ? `${issPath}.${key}` : key;
              warnings.push({
                path: fullPath,
                message: `Unrecognized config key "${key}" ignored (key removed, valid keys preserved)`,
              });
            }
          }
        }
      }
      // Re-validate without the unrecognized keys
      const retryValidated = OpenClawSchema.safeParse(stripped);
      if (retryValidated.success) {
        // Log warnings to stderr so they're visible in gateway logs
        for (const w of warnings) {
          console.warn(`[config] ${w.path}: ${w.message}`);
        }
        // Continue with the stripped config — fall through to duplicate/avatar checks below
        const retryConfig = retryValidated.data as OpenClawConfig;
        const retryDuplicates = findDuplicateAgentDirs(retryConfig);
        if (retryDuplicates.length > 0) {
          return {
            ok: false,
            issues: [{ path: "agents.list", message: formatDuplicateAgentDirError(retryDuplicates) }],
          };
        }
        const retryAvatarIssues = validateIdentityAvatar(retryConfig);
        if (retryAvatarIssues.length > 0) {
          return { ok: false, issues: retryAvatarIssues };
        }
        return { ok: true, config: retryConfig, warnings };
      }
    }
    return {
      ok: false,
      issues: validated.error.issues.map((iss) => ({
        path: iss.path.join("."),
        message: iss.message,
      })),
    };
  }"""

if old_validate not in code:
    print("    FAIL: #24008 cannot find validateConfigObjectRaw function body", file=sys.stderr)
    sys.exit(1)

code = code.replace(old_validate, new_validate, 1)

with open(filepath, "w") as f:
    f.write(code)
print("    OK: #24008 validateConfigObjectRaw now strips unrecognized keys instead of rejecting entire config")

PYEOF

echo "    OK: #24008 fully applied"
