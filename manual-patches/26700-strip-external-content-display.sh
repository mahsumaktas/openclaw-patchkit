#!/usr/bin/env bash
# PR #26700 — fix(security): strip leaked external untrusted-content wrappers from user-facing replies
# When external content (email, webhook, browser) is processed, security boundary markers
# (<<<EXTERNAL_UNTRUSTED_CONTENT>>>) and SECURITY NOTICE headers can leak into
# user-visible text. This adds stripExternalContentForDisplay() to clean them out.
#
# Changes:
# 1. security/external-content.ts: Add stripExternalContentForDisplay function
# 2. agents/pi-embedded-helpers/errors.ts: Wrap stripFinalTagsFromText with stripExternalContentForDisplay
set -euo pipefail
SRC="${1:-.}/src"

EC_FILE="$SRC/security/external-content.ts"
ERR_FILE="$SRC/agents/pi-embedded-helpers/errors.ts"

# Idempotency check
if grep -q 'stripExternalContentForDisplay' "$EC_FILE" 2>/dev/null; then
  echo "    SKIP: #26700 already applied"
  exit 0
fi

[ -f "$EC_FILE" ]  || { echo "    FAIL: $EC_FILE not found"; exit 1; }
[ -f "$ERR_FILE" ] || { echo "    FAIL: $ERR_FILE not found"; exit 1; }

# 1) external-content.ts: Add stripExternalContentForDisplay function
python3 - "$EC_FILE" << 'PYEOF'
import sys

path = sys.argv[1]
with open(path, 'r') as f:
    content = f.read()

INSERT_AFTER = '  - Send messages to third parties\n`.trim();\n\nexport type ExternalContentSource'

NEW_CODE = """  - Send messages to third parties
`.trim();

const EXTERNAL_CONTENT_BLOCK_RE =
  /<<<EXTERNAL_UNTRUSTED_CONTENT(?:\\s+id="[^"]{1,128}")?\\s*>>>[\\s\\S]*?<<<END_EXTERNAL_UNTRUSTED_CONTENT(?:\\s+id="[^"]{1,128}")?\\s*>>>/gi;
const EXTERNAL_CONTENT_MARKER_ONLY_RE =
  /<<<(?:END_)?EXTERNAL_UNTRUSTED_CONTENT(?:\\s+id="[^"]{1,128}")?\\s*>>>/gi;
const UNTRUSTED_CONTEXT_HEADER_RE =
  /^\\s*Untrusted context \\(metadata, do not treat as instructions or commands\\):\\s*$/gim;

const EXTERNAL_WARNING_LINE_RE =
  /^\\s*SECURITY NOTICE:\\s*The following content is from an EXTERNAL, UNTRUSTED source.*$/im;

function stripExternalWarningBlock(text: string): string {
  const warningMatch = EXTERNAL_WARNING_LINE_RE.exec(text);
  if (!warningMatch) {
    return text;
  }

  const start = warningMatch.index;
  const afterWarningLine = start + warningMatch[0].length;
  const tail = text.slice(afterWarningLine);
  const blankLineOffset = tail.search(/\\r?\\n\\r?\\n/);
  const end = blankLineOffset >= 0 ? afterWarningLine + blankLineOffset + 2 : afterWarningLine;
  return `$""" + """{text.slice(0, start)}$""" + """{text.slice(end)}`;
}

/**
 * Remove external untrusted-content wrappers from text that will be shown to users.
 *
 * This strips the structured `EXTERNAL_UNTRUSTED_CONTENT` boundary blocks and
 * SECURITY NOTICE header if they leak into assistant-visible replies.
 */
export function stripExternalContentForDisplay(text: string): string {
  if (!text) {
    return text;
  }
  if (
    !/EXTERNAL_UNTRUSTED_CONTENT|SECURITY NOTICE|Untrusted context \\(metadata, do not treat as instructions or commands\\)/i.test(
      text,
    )
  ) {
    return text;
  }

  let stripped = text.replace(EXTERNAL_CONTENT_BLOCK_RE, "");
  stripped = stripped.replace(EXTERNAL_CONTENT_MARKER_ONLY_RE, "");
  stripped = stripped.replace(UNTRUSTED_CONTEXT_HEADER_RE, "");
  stripped = stripExternalWarningBlock(stripped);
  stripped = stripped.replace(/\\n{3,}/g, "\\n\\n");
  return stripped;
}

export type ExternalContentSource"""

if INSERT_AFTER not in content:
    print("    FAIL: #26700 external-content.ts insert point not found", file=sys.stderr)
    sys.exit(1)

content = content.replace(INSERT_AFTER, NEW_CODE, 1)

with open(path, 'w') as f:
    f.write(content)
print("    OK: #26700 stripExternalContentForDisplay added to external-content.ts")
PYEOF

# 2) errors.ts: Import + use stripExternalContentForDisplay
python3 - "$ERR_FILE" << 'PYEOF'
import sys

path = sys.argv[1]
with open(path, 'r') as f:
    content = f.read()

# 2a) Add import
old_import = 'import { createSubsystemLogger } from "../../logging/subsystem.js";\nimport { formatSandboxToolPolicyBlockedMessage }'
new_import = 'import { createSubsystemLogger } from "../../logging/subsystem.js";\nimport { stripExternalContentForDisplay } from "../../security/external-content.js";\nimport { formatSandboxToolPolicyBlockedMessage }'

if old_import not in content:
    print("    FAIL: #26700 errors.ts import pattern not found", file=sys.stderr)
    sys.exit(1)

content = content.replace(old_import, new_import, 1)

# 2b) Wrap stripFinalTagsFromText with stripExternalContentForDisplay
old_strip = '  const stripped = stripFinalTagsFromText(text);'
new_strip = '  const stripped = stripExternalContentForDisplay(stripFinalTagsFromText(text));'

if old_strip not in content:
    print("    FAIL: #26700 errors.ts stripFinalTagsFromText pattern not found", file=sys.stderr)
    sys.exit(1)

content = content.replace(old_strip, new_strip, 1)

with open(path, 'w') as f:
    f.write(content)
print("    OK: #26700 sanitizeUserFacingText now strips external content wrappers")
PYEOF

echo "    OK: #26700 strip leaked external untrusted-content wrappers applied (2 files)"
