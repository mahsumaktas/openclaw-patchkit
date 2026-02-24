#!/usr/bin/env bash
# PR #24583: Strip external content markers from output
# 1. external-content.ts — adds stripExternalContentFromOutput function (applied via diff)
# 2. reply-payloads.ts — adds import + pipeline step (manual)
set -euo pipefail

FILE="src/auto-reply/reply/reply-payloads.ts"
[ -f "$FILE" ] || { echo "SKIP: $FILE not found"; exit 1; }

node -e "
const fs = require('fs');
let code = fs.readFileSync('$FILE', 'utf8');

// 1. Add import if not present
if (!code.includes('stripExternalContentFromOutput')) {
  // Add import after the first import line
  code = code.replace(
    /^(import .+\n)/,
    '\$1import { stripExternalContentFromOutput } from \"../../security/external-content.js\";\n'
  );

  // 2. Add pipeline step after resolveReplyThreadingForPayload map
  const marker = '      resolveReplyThreadingForPayload({ payload, implicitReplyToId, currentMessageId }),';
  const addition = marker + \`
    )
    .map((payload) => {
      if (typeof payload.text === \"string\") {
        const stripped = stripExternalContentFromOutput(payload.text);
        return stripped !== payload.text ? { ...payload, text: stripped } : payload;
      }
      return payload;
    })\`;

  // Replace the marker + closing paren of the first .map
  code = code.replace(
    marker + '\n    )',
    addition
  );

  fs.writeFileSync('$FILE', code);
  console.log('OK: #24583 reply-payloads.ts patched');
} else {
  console.log('SKIP: #24583 already applied');
}
"
