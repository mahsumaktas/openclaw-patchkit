#!/usr/bin/env bash
# PR #19134 - fix(gateway): specify utf-8 encoding on SSE res.write()
# Without explicit encoding, Node.js may use latin1 for string writes,
# corrupting non-ASCII characters in SSE streams.
set -euo pipefail
cd "$1"

# File 1: http-common.ts - writeDone
sed -i.bak 's|res.write("data: \[DONE\]\\n\\n");|res.write("data: [DONE]\\n\\n", "utf-8");|' \
  src/gateway/http-common.ts

# File 2: openai-http.ts - writeSse
sed -i.bak 's|res.write(`data: ${JSON.stringify(data)}\\n\\n`);|res.write(`data: ${JSON.stringify(data)}\\n\\n`, "utf-8");|' \
  src/gateway/openai-http.ts

# File 3: openresponses-http.ts - writeSseEvent (two lines)
sed -i.bak \
  -e 's|res.write(`event: ${event.type}\\n`);|res.write(`event: ${event.type}\\n`, "utf-8");|' \
  -e 's|res.write(`data: ${JSON.stringify(event)}\\n\\n`);|res.write(`data: ${JSON.stringify(event)}\\n\\n`, "utf-8");|' \
  src/gateway/openresponses-http.ts

rm -f src/gateway/http-common.ts.bak src/gateway/openai-http.ts.bak src/gateway/openresponses-http.ts.bak
echo "Applied PR #19134 - SSE utf-8 encoding"
