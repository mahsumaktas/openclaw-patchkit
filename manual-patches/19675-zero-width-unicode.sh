#!/usr/bin/env bash
# PR #19675: Prevent zero-width Unicode chars from bypassing boundary marker sanitization
# Adds stripInvisibleChars() before foldMarkerText() in replaceMarkers()
set -euo pipefail
cd "$1"

FILE="src/security/external-content.ts"
[ -f "$FILE" ] || { echo "SKIP: $FILE not found"; exit 1; }

# 1. Add the regex and function before FULLWIDTH_ASCII_OFFSET
node -e "
const fs = require('fs');
let code = fs.readFileSync('$FILE', 'utf8');

const INJECTION = \`
/**
 * Regex matching all Unicode \"Format\" (Cf) category characters.
 * These invisible characters can be inserted into boundary marker text
 * to bypass string matching.
 */
const INVISIBLE_FORMAT_CHARS_RE = /\\\\p{Cf}/gu;

/**
 * Strip invisible Unicode format characters from input.
 */
function stripInvisibleChars(input: string): string {
  return input.replace(INVISIBLE_FORMAT_CHARS_RE, \"\");
}

\`;

// Insert before FULLWIDTH_ASCII_OFFSET
code = code.replace(
  'const FULLWIDTH_ASCII_OFFSET',
  INJECTION + 'const FULLWIDTH_ASCII_OFFSET'
);

// 2. Modify replaceMarkers: add stripInvisibleChars before foldMarkerText
code = code.replace(
  'function replaceMarkers(content: string): string {\\n  const folded = foldMarkerText(content);',
  'function replaceMarkers(content: string): string {\\n  // Strip invisible Unicode format characters first to prevent bypass.\\n  const stripped = stripInvisibleChars(content);\\n  const folded = foldMarkerText(stripped);'
);

// 3. Replace 'return content;' with 'return stripped;' inside replaceMarkers only
// The first 'return content;' is the early return after regex check
// The second is after replacements.length === 0
// We need to replace both occurrences AFTER replaceMarkers function starts
const markerIdx = code.indexOf('function replaceMarkers');
const before = code.substring(0, markerIdx);
let after = code.substring(markerIdx);
after = after.replace(/return content;/g, 'return stripped;');

// Also replace content.slice with stripped.slice in the same function
after = after.replace(/content\.slice\(cursor/g, 'stripped.slice(cursor');

code = before + after;

fs.writeFileSync('$FILE', code);
console.log('OK: #19675 applied');
"
