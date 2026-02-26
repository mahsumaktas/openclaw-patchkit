#!/usr/bin/env bash
# PR #16015 - fix(gateway): truncate oversized message in chat.history
# Adds truncateMessagesForChatHistory to cap individual message content
# at 50K chars before sending to the client, preventing huge payloads.
set -euo pipefail
cd "$1"

# 1. Append truncation functions to chat-sanitize.ts
cat >> src/gateway/chat-sanitize.ts << 'PATCH_EOF'

const MAX_CONTENT_CHARS = 50_000;
const TRUNCATION_SUFFIX = "\n\n… [content truncated for display]";

function truncateString(text: string): string {
  if (text.length <= MAX_CONTENT_CHARS) {
    return text;
  }
  return text.slice(0, MAX_CONTENT_CHARS) + TRUNCATION_SUFFIX;
}

function truncateContentArray(content: unknown[]): { content: unknown[]; changed: boolean } {
  let changed = false;
  const next = content.map((item) => {
    if (!item || typeof item !== "object") {
      return item;
    }
    const entry = item as Record<string, unknown>;
    if (typeof entry.text !== "string" || entry.text.length <= MAX_CONTENT_CHARS) {
      return item;
    }
    changed = true;
    return { ...entry, text: truncateString(entry.text) };
  });
  return { content: next, changed };
}

function truncateMessageContent(message: unknown): unknown {
  if (!message || typeof message !== "object") {
    return message;
  }
  const entry = message as Record<string, unknown>;
  let changed = false;
  const next: Record<string, unknown> = { ...entry };

  if (typeof entry.content === "string" && entry.content.length > MAX_CONTENT_CHARS) {
    next.content = truncateString(entry.content);
    changed = true;
  } else if (Array.isArray(entry.content)) {
    const updated = truncateContentArray(entry.content);
    if (updated.changed) {
      next.content = updated.content;
      changed = true;
    }
  }

  if (typeof entry.text === "string" && entry.text.length > MAX_CONTENT_CHARS) {
    next.text = truncateString(entry.text);
    changed = true;
  }

  return changed ? next : message;
}

export function truncateMessagesForChatHistory(messages: unknown[]): unknown[] {
  if (messages.length === 0) {
    return messages;
  }
  let changed = false;
  const next = messages.map((message) => {
    const truncated = truncateMessageContent(message);
    if (truncated !== message) {
      changed = true;
    }
    return truncated;
  });
  return changed ? next : messages;
}
PATCH_EOF

# 2. Add import in server-methods/chat.ts
sed -i.bak 's|import { stripEnvelopeFromMessages }|import { stripEnvelopeFromMessages, truncateMessagesForChatHistory }|' \
  src/gateway/server-methods/chat.ts
# Also handle if it imports stripEnvelopeFromMessage (singular) too
sed -i.bak 's|import { stripEnvelopeFromMessage, stripEnvelopeFromMessages }|import { stripEnvelopeFromMessage, stripEnvelopeFromMessages, truncateMessagesForChatHistory }|' \
  src/gateway/server-methods/chat.ts

# 3. Insert truncation step after sanitization in chat history handler
sed -i.bak 's|const sanitized = stripEnvelopeFromMessages(sliced);|const sanitized = stripEnvelopeFromMessages(sliced);\n    const truncated = truncateMessagesForChatHistory(sanitized);|' \
  src/gateway/server-methods/chat.ts

# 4. Update the next line to use truncated instead of sanitized
# This depends on what follows - adapt to actual code
python3 -c "
with open('src/gateway/server-methods/chat.ts', 'r') as f:
    content = f.read()
# Replace first occurrence of variable name after truncated is introduced
# The line after should reference sanitized -> truncated
import re
# Find: truncated = truncateMessages...\n    const XXX = someFunc(sanitized
# Replace sanitized with truncated in the next line
content = re.sub(
    r'(const truncated = truncateMessagesForChatHistory\(sanitized\);\n\s+const \w+ = \w+\()sanitized(\))',
    r'\1truncated\2',
    content,
    count=1
)
with open('src/gateway/server-methods/chat.ts', 'w') as f:
    f.write(content)
"

rm -f src/gateway/server-methods/chat.ts.bak
echo "Applied PR #16015 - truncate oversized chat history messages"
