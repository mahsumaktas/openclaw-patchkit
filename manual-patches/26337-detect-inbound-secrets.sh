#!/usr/bin/env bash
# PR #26337 — security: detect secrets in inbound messages
# 2 files: security/detect-inbound-secrets.ts (new), auto-reply/reply/get-reply-run.ts (edit)
# (tests skipped)
#
# Creates detect-inbound-secrets.ts with containsSecretPatterns() and
# buildSecretDetectionWarning(), then wires it into get-reply-run.ts
# to add a system prompt warning when secrets are detected.
set -euo pipefail
SRC="${1:-.}/src"

SECRETS="$SRC/security/detect-inbound-secrets.ts"
REPLY="$SRC/auto-reply/reply/get-reply-run.ts"

# ── Idempotency ──
if [ -f "$SECRETS" ] && grep -q 'buildSecretDetectionWarning' "$REPLY" 2>/dev/null; then
  echo "    SKIP: #26337 already applied"
  exit 0
fi

# ── File checks ──
[ -d "$SRC/security" ] || { echo "    FAIL: #26337 $SRC/security not found"; exit 1; }
[ -f "$REPLY" ] || { echo "    FAIL: #26337 $REPLY not found"; exit 1; }

# ── 1. Create detect-inbound-secrets.ts ──
if [ ! -f "$SECRETS" ]; then
  cat > "$SECRETS" << 'TSEOF'
import { compileSafeRegex } from "./safe-regex.js";

/**
 * Patterns that match common secret/credential formats in user messages.
 * Reuses the same pattern philosophy as `src/logging/redact.ts` but tuned for
 * inbound user message detection (lower false-positive tolerance).
 */
const SECRET_DETECTION_PATTERNS: string[] = [
  // ENV-style assignments: API_KEY=xxx, SECRET=xxx
  String.raw`\b[A-Z0-9_]*(?:KEY|TOKEN|SECRET|PASSWORD|PASSWD)\b\s*[=:]\s*(["']?)([^\s"'\\]+)\1`,
  // JSON fields: "apiKey": "xxx", "secret": "xxx"
  String.raw`"(?:apiKey|token|secret|password|passwd|accessToken|refreshToken|accessKey|accessSecret|secretKey|secretAccessKey)"\s*:\s*"([^"]+)"`,
  // CLI flags: --api-key xxx, --token xxx
  String.raw`--(?:api[-_]?key|token|secret|password|passwd)\s+(["']?)([^\s"']+)\1`,
  // Authorization headers
  String.raw`Authorization\s*[:=]\s*Bearer\s+([A-Za-z0-9._\-+=]+)`,
  String.raw`\bBearer\s+([A-Za-z0-9._\-+=]{18,})\b`,
  // PEM private keys
  String.raw`-----BEGIN [A-Z ]*PRIVATE KEY-----`,
  // Common token prefixes (high confidence)
  String.raw`\b(sk-[A-Za-z0-9_-]{8,})\b`,
  String.raw`\b(ghp_[A-Za-z0-9]{20,})\b`,
  String.raw`\b(github_pat_[A-Za-z0-9_]{20,})\b`,
  String.raw`\b(xox[baprs]-[A-Za-z0-9-]{10,})\b`,
  String.raw`\b(xapp-[A-Za-z0-9-]{10,})\b`,
  String.raw`\b(gsk_[A-Za-z0-9_-]{10,})\b`,
  String.raw`\b(AIza[0-9A-Za-z\-_]{20,})\b`,
  String.raw`\b(pplx-[A-Za-z0-9_-]{10,})\b`,
  String.raw`\b(npm_[A-Za-z0-9]{10,})\b`,
  // AWS access key IDs (AKIA...)
  String.raw`\b(AKIA[0-9A-Z]{16})\b`,
  // Telegram bot tokens
  String.raw`\bbot(\d{6,}:[A-Za-z0-9_-]{20,})\b`,
  String.raw`\b(\d{6,}:[A-Za-z0-9_-]{20,})\b`,
];

let compiledPatterns: RegExp[] | undefined;

function getPatterns(): RegExp[] {
  if (!compiledPatterns) {
    compiledPatterns = SECRET_DETECTION_PATTERNS.map((raw) => compileSafeRegex(raw, "gi")).filter(
      (re): re is RegExp => Boolean(re),
    );
  }
  return compiledPatterns;
}

/**
 * Checks whether a user message contains patterns that look like secrets or credentials.
 * Returns true if at least one pattern matches.
 */
export function containsSecretPatterns(text: string): boolean {
  if (!text) {
    return false;
  }
  for (const pattern of getPatterns()) {
    pattern.lastIndex = 0;
    if (pattern.test(text)) {
      return true;
    }
  }
  return false;
}

const SECRET_WARNING_SYSTEM_PROMPT = [
  "SECURITY NOTICE: The user's message appears to contain credentials, API keys, tokens, or other secrets.",
  "You MUST:",
  "1. Immediately warn the user that sending credentials in chat messages is unsafe because the message content is processed by AI model APIs.",
  "2. Suggest they use secure configuration methods instead (e.g., `openclaw config set`, configuration files, or environment variables).",
  "3. Do NOT repeat, store, or echo back the credentials in your response.",
  "4. If the user is trying to configure a service, guide them to the secure way to do it.",
].join(" ");

/**
 * Returns a system prompt fragment that instructs the LLM to warn the user
 * about detected credentials. Returns undefined when no secrets are detected.
 */
export function buildSecretDetectionWarning(messageBody: string): string | undefined {
  if (!containsSecretPatterns(messageBody)) {
    return undefined;
  }
  return SECRET_WARNING_SYSTEM_PROMPT;
}
TSEOF
  echo "    OK: #26337 detect-inbound-secrets.ts created"
else
  echo "    SKIP: #26337 detect-inbound-secrets.ts already exists"
fi

# ── 2. Wire into get-reply-run.ts ──
if ! grep -q 'buildSecretDetectionWarning' "$REPLY" 2>/dev/null; then
  python3 - "$REPLY" << 'PYEOF'
import sys

path = sys.argv[1]
with open(path, 'r') as f:
    content = f.read()

# Part 2a: Add import after the normalizeMainKey import
old_import = 'import { normalizeMainKey } from "../../routing/session-key.js";'
new_import = '''import { normalizeMainKey } from "../../routing/session-key.js";
import { buildSecretDetectionWarning } from "../../security/detect-inbound-secrets.js";'''

if old_import not in content:
    print("    FAIL: #26337 cannot find normalizeMainKey import", file=sys.stderr)
    sys.exit(1)

if 'buildSecretDetectionWarning' in content:
    print("    SKIP: #26337 get-reply-run.ts import already present")
    sys.exit(0)

content = content.replace(old_import, new_import, 1)

# Part 2b: Add secretWarning to extraSystemPromptParts
# v2026.3.8 uses extraSystemPromptParts array (not the old join pattern)
old_parts = '''  const extraSystemPromptParts = [
    inboundMetaPrompt,
    groupChatContext,
    groupIntro,
    groupSystemPrompt,
  ].filter(Boolean);'''

new_parts = '''  const secretWarning = buildSecretDetectionWarning(
    ctx.CommandBody ?? ctx.RawBody ?? ctx.Body ?? "",
  );
  const extraSystemPromptParts = [
    inboundMetaPrompt,
    groupChatContext,
    groupIntro,
    groupSystemPrompt,
    secretWarning,
  ].filter(Boolean);'''

if old_parts not in content:
    print("    FAIL: #26337 cannot find extraSystemPromptParts array", file=sys.stderr)
    sys.exit(1)

content = content.replace(old_parts, new_parts, 1)

with open(path, 'w') as f:
    f.write(content)
print("    OK: #26337 get-reply-run.ts — secretWarning wired into extraSystemPromptParts")
PYEOF
fi

echo "    OK: #26337 detect inbound secrets applied"
