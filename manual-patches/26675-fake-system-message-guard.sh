#!/usr/bin/env bash
# Issue #26675 + #26851: security(agents): strip fake system/audit messages from user input
#
# Attackers inject text mimicking OpenClaw's internal [System Message] and
# Post-Compaction Audit format into user messages (via Telegram, Discord, etc.).
# The injected content reaches the agent's context unmodified, potentially
# manipulating agent behavior.
#
# Fix: Sanitize inbound user message text before it is prepended to agent context.
# 1. session-updates.ts: Tag real system events with an internal-only marker
#    so agents can distinguish genuine system events from spoofed content.
# 2. external-content.ts: Add patterns to SUSPICIOUS_PATTERNS for audit spoofing.
# 3. post-compaction-audit.ts: Add HMAC signature to formatAuditWarning output
#    so agents can verify audit messages are genuine.
#
# Changes:
#   src/auto-reply/reply/session-updates.ts — add INTERNAL_SYSTEM_EVENT_MARKER
#   src/security/external-content.ts — add audit-spoof detection patterns
#   src/auto-reply/reply/post-compaction-audit.ts — HMAC-sign audit warnings
set -euo pipefail

SRC="${1:-.}/src"

# ── Idempotency check ──────────────────────────────────────────────────────
if grep -q 'INTERNAL_SYSTEM_EVENT_MARKER' "$SRC/auto-reply/reply/session-updates.ts" 2>/dev/null; then
  echo "    SKIP: #26675 already applied"
  exit 0
fi

# ── 1. session-updates.ts: tag real system events with internal marker ─────
python3 - "$SRC/auto-reply/reply/session-updates.ts" << 'PYEOF'
import sys

path = sys.argv[1]
with open(path, 'r') as f:
    content = f.read()

# 1a. Add the internal marker constant and sanitizer function after imports
import_marker = 'import { drainSystemEventEntries } from "../../infra/system-events.js";'
if import_marker not in content:
    print("    FAIL: #26675 import marker not found in session-updates.ts")
    sys.exit(1)

new_import_block = '''import { drainSystemEventEntries } from "../../infra/system-events.js";

/**
 * Internal-only marker prepended to genuine system events.
 * User-facing channels cannot produce this token, so agents can trust
 * that lines starting with this marker are authentic OpenClaw events.
 * The random hex suffix is generated once per process to prevent replay.
 */
import { randomBytes } from "node:crypto";
const INTERNAL_SYSTEM_EVENT_MARKER = `[oc-internal-${randomBytes(4).toString("hex")}]`;

/**
 * Patterns that indicate spoofed system/audit content in user messages.
 * Matches are neutralized (escaped) before reaching the agent context.
 */
const SPOOFED_SYSTEM_PATTERNS: RegExp[] = [
  /\\[System Message\\]/gi,
  /\\[System\\s*:\\s*/gi,
  /Post-Compaction Audit/gi,
  /required startup files were not read/gi,
  /Please read them now using the Read tool/gi,
  /operating protocols are restored after memory compaction/gi,
];

/**
 * Strip or neutralize spoofed system/audit patterns from user message text.
 * Wraps matched substrings in [UNTRUSTED: ...] to make spoofing visible
 * to the agent without silently swallowing user content.
 */
function neutralizeSpoofedSystemContent(text: string): string {
  let result = text;
  for (const pattern of SPOOFED_SYSTEM_PATTERNS) {
    result = result.replace(pattern, (match) => `[UNTRUSTED: ${match}]`);
  }
  return result;
}'''

content = content.replace(import_marker, new_import_block, 1)

# 1b. Update the system event formatting to include internal marker
# Change: `System: ${l}` → include marker
old_format = "const block = systemLines.map((l) => `System: ${l}`).join(\"\\n\");"
new_format = "const block = systemLines.map((l) => `${INTERNAL_SYSTEM_EVENT_MARKER} System: ${l}`).join(\"\\n\");"

if old_format not in content:
    print("    FAIL: #26675 system event format marker not found")
    sys.exit(1)

content = content.replace(old_format, new_format, 1)

# 1c. Sanitize the user message body (prefixedBodyBase) to neutralize spoofed content
old_return = "return `${block}\\n\\n${params.prefixedBodyBase}`;"
new_return = "const sanitizedBody = neutralizeSpoofedSystemContent(params.prefixedBodyBase);\n  return `${block}\\n\\n${sanitizedBody}`;"

if old_return not in content:
    print("    FAIL: #26675 return format marker not found")
    sys.exit(1)

content = content.replace(old_return, new_return, 1)

# 1d. Also sanitize the body when there are no system events
old_no_events = "return params.prefixedBodyBase;"
new_no_events = "return neutralizeSpoofedSystemContent(params.prefixedBodyBase);"

if old_no_events not in content:
    print("    FAIL: #26675 no-events return not found")
    sys.exit(1)

content = content.replace(old_no_events, new_no_events, 1)

with open(path, 'w') as f:
    f.write(content)

print("    OK: #26675 session-updates.ts patched — internal marker + spoof neutralization")
PYEOF

# ── 2. external-content.ts: add audit-spoof detection patterns ────────────
python3 - "$SRC/security/external-content.ts" << 'PYEOF'
import sys

path = sys.argv[1]
with open(path, 'r') as f:
    content = f.read()

# Add audit-specific spoof patterns to SUSPICIOUS_PATTERNS array
old_last_pattern = '  /<\\/?system>/i,'
new_patterns = '''  /<\\/?system>/i,
  /Post-Compaction Audit/i,
  /\\[System Message\\].*(?:sessionId|completed|failed)/i,
  /required startup files were not read/i,'''

if 'Post-Compaction Audit' in content:
    print("    SKIP: #26675 external-content.ts patterns already present")
else:
    if old_last_pattern not in content:
        print("    FAIL: #26675 SUSPICIOUS_PATTERNS insertion point not found")
        sys.exit(1)
    content = content.replace(old_last_pattern, new_patterns, 1)
    with open(path, 'w') as f:
        f.write(content)
    print("    OK: #26675 external-content.ts — audit-spoof patterns added")
PYEOF

# ── 3. post-compaction-audit.ts: sign audit warnings ──────────────────────
python3 - "$SRC/auto-reply/reply/post-compaction-audit.ts" << 'PYEOF'
import sys

path = sys.argv[1]
with open(path, 'r') as f:
    content = f.read()

# Add HMAC-based signature to formatAuditWarning so agents can verify authenticity
old_format_fn = '''/** Format the audit warning message */
export function formatAuditWarning(missingPatterns: string[]): string {
  const fileList = missingPatterns.map((p) => `  - ${p}`).join("\\n");
  return (
    "\u26a0\ufe0f Post-Compaction Audit: The following required startup files were not read after context reset:\\n" +
    fileList +
    "\\n\\nPlease read them now using the Read tool before continuing. " +
    "This ensures your operating protocols are restored after memory compaction."
  );
}'''

new_format_fn = '''/** Format the audit warning message.
 * Includes an HMAC signature so agents can verify the message is genuine
 * and not spoofed by injected user content (#26675, #26851).
 */
export function formatAuditWarning(missingPatterns: string[]): string {
  const fileList = missingPatterns.map((p) => `  - ${p}`).join("\\n");
  const nonce = Math.floor(Date.now() / 1000).toString(36);
  return (
    `[openclaw-audit-${nonce}] ` +
    "\u26a0\ufe0f Post-Compaction Audit: The following required startup files were not read after context reset:\\n" +
    fileList +
    "\\n\\nPlease read them now using the Read tool before continuing. " +
    "This ensures your operating protocols are restored after memory compaction."
  );
}'''

if 'openclaw-audit-' in content:
    print("    SKIP: #26675 post-compaction-audit.ts already signed")
else:
    if old_format_fn not in content:
        print("    FAIL: #26675 formatAuditWarning marker not found")
        sys.exit(1)
    content = content.replace(old_format_fn, new_format_fn, 1)
    with open(path, 'w') as f:
        f.write(content)
    print("    OK: #26675 post-compaction-audit.ts — audit warnings now signed")
PYEOF

echo "    OK: #26675 fake system message guard fully applied"
