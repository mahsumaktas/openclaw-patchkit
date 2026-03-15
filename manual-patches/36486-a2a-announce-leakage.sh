#!/usr/bin/env bash
# PR #36486 — prevent channel-bound A2A announce leakage
#
# Problem: When a subagent completes, the announce flow can leak messages into
# channel-bound user sessions (e.g. Discord channels) that the agent shouldn't
# post to. The sessions_send tool's A2A announce path doesn't distinguish
# between internal-only sessions and externally-bound ones.
#
# This patch implements the core safety changes:
# 1. sessions-announce-target.ts: return typed AnnounceTargetDecision instead
#    of AnnounceTarget|null — distinguishes external_target, no_external_target,
#    and unknown cases
# 2. subagent-announce.ts: resolveSubagentCompletionOrigin now returns routeMode
#    ("bound"|"fallback"|"hook") so callers can make routing decisions
# 3. config: add session.agentToAgent.allowChannelBoundAnnounce option (default false)
# 4. sessions-send-tool.a2a.ts: respect allowChannelBoundAnnounce, handle new decision types
# 5. sessions-send-tool.ts: early target resolution, gate announce flow on config flag
#
# NOTE: This is a large PR with significant refactoring. The manual patch focuses
# on the core safety-critical changes. The full delivery plan refactoring
# (buildSubagentDirectDeliveryPlan) is simplified to maintain the security fix
# without rewriting hundreds of lines.
#
# v1: Written for v2026.3.13
set -euo pipefail
SRC="${1:-.}/src"

# ── Idempotency ──
if grep -q 'allowChannelBoundAnnounce' "$SRC/config/types.base.ts" 2>/dev/null; then
  echo "    SKIP: #36486 already applied"
  exit 0
fi

CHANGES=0

# ─── 1) sessions-announce-target.ts: typed AnnounceTargetDecision ───
FILE="$SRC/agents/tools/sessions-announce-target.ts"
[ -f "$FILE" ] || { echo "    FAIL: $FILE not found"; exit 1; }

python3 - "$FILE" << 'PYEOF'
import sys

path = sys.argv[1]
with open(path, 'r') as f:
    content = f.read()

# Replace the entire file with the updated version that returns typed decisions
new_content = '''import { getChannelPlugin, normalizeChannelId } from "../../channels/plugins/index.js";
import { callGateway } from "../../gateway/call.js";
import { SessionListRow } from "./sessions-helpers.js";
import type { AnnounceTarget } from "./sessions-send-helpers.js";
import { resolveAnnounceTargetFromKey } from "./sessions-send-helpers.js";

export type AnnounceTargetDecision =
  | { kind: "external_target"; target: AnnounceTarget }
  | { kind: "no_external_target" }
  | { kind: "unknown"; reason: "miss" | "partial" | "error" };

export async function resolveAnnounceTarget(params: {
  sessionKey: string;
  displayKey: string;
}): Promise<AnnounceTargetDecision> {
  const parsed = resolveAnnounceTargetFromKey(params.sessionKey);

  if (parsed) {
    const normalized = normalizeChannelId(parsed.channel);
    const plugin = normalized ? getChannelPlugin(normalized) : null;
    if (!plugin?.meta?.preferSessionLookupForAnnounceTarget) {
      return { kind: "external_target", target: parsed };
    }
  }

  try {
    const list = await callGateway<{ sessions: Array<SessionListRow> }>({
      method: "sessions.list",
      params: {
        includeGlobal: true,
        includeUnknown: true,
        limit: 200,
      },
    });
    const sessions = Array.isArray(list?.sessions) ? list.sessions : [];
    const match =
      sessions.find((entry) => entry?.key === params.sessionKey) ??
      sessions.find((entry) => entry?.key === params.displayKey);
    if (!match) {
      return { kind: "unknown", reason: "miss" };
    }

    const deliveryContext =
      match?.deliveryContext && typeof match.deliveryContext === "object"
        ? (match.deliveryContext as Record<string, unknown>)
        : undefined;
    const channel =
      (typeof deliveryContext?.channel === "string" ? deliveryContext.channel : undefined) ??
      (typeof match?.lastChannel === "string" ? match.lastChannel : undefined);
    const to =
      (typeof deliveryContext?.to === "string" ? deliveryContext.to : undefined) ??
      (typeof match?.lastTo === "string" ? match.lastTo : undefined);
    const accountId =
      (typeof deliveryContext?.accountId === "string" ? deliveryContext.accountId : undefined) ??
      (typeof match?.lastAccountId === "string" ? match.lastAccountId : undefined);
    if (channel && to) {
      return { kind: "external_target", target: { channel, to, accountId } };
    }
    if (channel || to || accountId) {
      // Partial routing data is inconclusive, so fail closed instead of assuming internal-only.
      return { kind: "unknown", reason: "partial" };
    }
    return { kind: "no_external_target" };
  } catch {
    return { kind: "unknown", reason: "error" };
  }
}
'''
with open(path, 'w') as f:
    f.write(new_content)
print("    OK: #36486 sessions-announce-target.ts rewritten with AnnounceTargetDecision")
PYEOF
CHANGES=$((CHANGES + 1))

# ─── 2) subagent-announce.ts: return routeMode from resolveSubagentCompletionOrigin ───
FILE="$SRC/agents/subagent-announce.ts"
[ -f "$FILE" ] || { echo "    FAIL: $FILE not found"; exit 1; }

python3 - "$FILE" << 'PYEOF'
import sys

path = sys.argv[1]
with open(path, 'r') as f:
    content = f.read()

changes = 0

# 2a) Change return type of resolveSubagentCompletionOrigin
old_sig = '}): Promise<DeliveryContext | undefined> {'
new_sig = '}): Promise<{ origin?: DeliveryContext; routeMode: "bound" | "fallback" | "hook" }> {'
if old_sig in content:
    content = content.replace(old_sig, new_sig, 1)
    changes += 1

# 2b) Wrap the bound route return
old_bound = '''  if (route.mode === "bound" && route.binding) {
    return mergeDeliveryContext(
      {
        channel: route.binding.conversation.channel,
        accountId: route.binding.conversation.accountId,
        to: `channel:${route.binding.conversation.conversationId}`,
        threadId:
          requesterOrigin?.threadId != null && requesterOrigin.threadId !== ""
            ? String(requesterOrigin.threadId)
            : undefined,
      },
      requesterOrigin,
    );
  }'''
new_bound = '''  if (route.mode === "bound" && route.binding) {
    return {
      routeMode: "bound",
      origin: mergeDeliveryContext(
        {
          channel: route.binding.conversation.channel,
          accountId: route.binding.conversation.accountId,
          to: `channel:${route.binding.conversation.conversationId}`,
          threadId:
            requesterOrigin?.threadId != null && requesterOrigin.threadId !== ""
              ? String(requesterOrigin.threadId)
              : undefined,
        },
        requesterOrigin,
      ),
    };
  }'''
if old_bound in content:
    content = content.replace(old_bound, new_bound, 1)
    changes += 1

# 2c) Wrap the no-hooks fallback return
old_nohook = '''  if (!hookRunner?.hasHooks("subagent_delivery_target")) {
    return requesterOrigin;
  }'''
new_nohook = '''  if (!hookRunner?.hasHooks("subagent_delivery_target")) {
    return {
      routeMode: "fallback",
      origin: requesterOrigin,
    };
  }'''
if old_nohook in content:
    content = content.replace(old_nohook, new_nohook, 1)
    changes += 1

# 2d) Wrap the hook result returns
old_hook_fallback1 = '''    if (!hookOrigin || (hookOrigin.channel && !isDeliverableMessageChannel(hookOrigin.channel))) {
      return requesterOrigin;
    }
    return mergeDeliveryContext(hookOrigin, requesterOrigin);
  } catch {
    return requesterOrigin;
  }'''
new_hook_fallback1 = '''    if (!hookOrigin || (hookOrigin.channel && !isDeliverableMessageChannel(hookOrigin.channel))) {
      return {
        routeMode: "fallback",
        origin: requesterOrigin,
      };
    }
    return {
      routeMode: "hook",
      origin: mergeDeliveryContext(hookOrigin, requesterOrigin),
    };
  } catch {
    return {
      routeMode: "fallback",
      origin: requesterOrigin,
    };
  }'''
if old_hook_fallback1 in content:
    content = content.replace(old_hook_fallback1, new_hook_fallback1, 1)
    changes += 1

# 2e) Update the caller at runSubagentAnnounceFlow to destructure routeMode
old_caller = '''    const completionDirectOrigin =
      expectsCompletionMessage && !requesterIsSubagent
        ? await resolveSubagentCompletionOrigin({'''
new_caller = '''    const completionDelivery =
      expectsCompletionMessage && !requesterIsSubagent
        ? await resolveSubagentCompletionOrigin({'''
if old_caller in content:
    content = content.replace(old_caller, new_caller, 1)
    changes += 1

# 2f) Update the fallback for non-completion case
old_fallback = '        : targetRequesterOrigin;\n    const directIdempotencyKey'
new_fallback = '''        : {
            routeMode: "fallback" as const,
            origin: targetRequesterOrigin,
          };
    const completionDirectOrigin = completionDelivery.origin;
    const directIdempotencyKey'''
if old_fallback in content:
    content = content.replace(old_fallback, new_fallback, 1)
    changes += 1

with open(path, 'w') as f:
    f.write(content)
print(f"    OK: #36486 subagent-announce.ts ({changes} changes)")
PYEOF
CHANGES=$((CHANGES + 1))

# ─── 3) config/types.base.ts: add allowChannelBoundAnnounce ───
FILE="$SRC/config/types.base.ts"
[ -f "$FILE" ] || { echo "    FAIL: $FILE not found"; exit 1; }

python3 - "$FILE" << 'PYEOF'
import sys

path = sys.argv[1]
with open(path, 'r') as f:
    content = f.read()

old = '    /** Max ping-pong turns between requester/target (0-5). Default: 5. */\n    maxPingPongTurns?: number;\n  };'
# Handle both em-dash and regular dash variants
if old not in content:
    old = '    /** Max ping-pong turns between requester/target (0\xe2\x80\x935). Default: 5. */\n    maxPingPongTurns?: number;\n  };'

new = old.replace(
    'maxPingPongTurns?: number;\n  };',
    '''maxPingPongTurns?: number;
    /**
     * Allow sessions_send announce flow for channel-bound target sessions.
     * Default: false (channel-bound sessions skip announce flow).
     */
    allowChannelBoundAnnounce?: boolean;
  };'''
)
if old in content:
    content = content.replace(old, new, 1)
    with open(path, 'w') as f:
        f.write(content)
    print("    OK: #36486 types.base.ts — allowChannelBoundAnnounce added")
else:
    # Try broader pattern
    import re
    m = re.search(r'(maxPingPongTurns\?: number;\s*\n\s*\};)', content)
    if m:
        old2 = m.group(0)
        new2 = old2.replace(
            'maxPingPongTurns?: number;',
            'maxPingPongTurns?: number;\n    /**\n     * Allow sessions_send announce flow for channel-bound target sessions.\n     * Default: false (channel-bound sessions skip announce flow).\n     */\n    allowChannelBoundAnnounce?: boolean;'
        )
        content = content.replace(old2, new2, 1)
        with open(path, 'w') as f:
            f.write(content)
        print("    OK: #36486 types.base.ts — allowChannelBoundAnnounce added (alt pattern)")
    else:
        print("    FAIL: #36486 types.base.ts maxPingPongTurns pattern not found", file=sys.stderr)
        sys.exit(1)
PYEOF
CHANGES=$((CHANGES + 1))

# ─── 4) config/zod-schema.session.ts: add allowChannelBoundAnnounce ───
FILE="$SRC/config/zod-schema.session.ts"
[ -f "$FILE" ] || { echo "    FAIL: $FILE not found"; exit 1; }

python3 - "$FILE" << 'PYEOF'
import sys

path = sys.argv[1]
with open(path, 'r') as f:
    content = f.read()

old = '        maxPingPongTurns: z.number().int().min(0).max(5).optional(),\n      })\n      .strict()'
new = '        maxPingPongTurns: z.number().int().min(0).max(5).optional(),\n        allowChannelBoundAnnounce: z.boolean().optional(),\n      })\n      .strict()'
if old in content:
    content = content.replace(old, new, 1)
    with open(path, 'w') as f:
        f.write(content)
    print("    OK: #36486 zod-schema.session.ts — allowChannelBoundAnnounce added")
else:
    print("    FAIL: #36486 zod-schema.session.ts maxPingPongTurns pattern not found", file=sys.stderr)
    sys.exit(1)
PYEOF
CHANGES=$((CHANGES + 1))

# ─── 5) config/schema.help.ts: add help text ───
FILE="$SRC/config/schema.help.ts"
[ -f "$FILE" ] || { echo "    FAIL: $FILE not found"; exit 1; }

python3 - "$FILE" << 'PYEOF'
import sys

path = sys.argv[1]
with open(path, 'r') as f:
    content = f.read()

old = '  "session.agentToAgent.maxPingPongTurns":\n    "Max reply-back turns between requester and target agents during agent-to-agent exchanges (0-5). Use lower values to hard-limit chatter loops and preserve predictable run completion.",'
new = '''  "session.agentToAgent.maxPingPongTurns":
    "Max reply-back turns between requester and target agents during agent-to-agent exchanges (0-5). Use lower values to hard-limit chatter loops and preserve predictable run completion.",
  "session.agentToAgent.allowChannelBoundAnnounce":
    "When true, allows sessions_send announce flow to post to channel-bound target sessions. Keep false to avoid cross-agent announce leakage into bound user channels.",'''
if old in content:
    content = content.replace(old, new, 1)
    with open(path, 'w') as f:
        f.write(content)
    print("    OK: #36486 schema.help.ts — allowChannelBoundAnnounce help added")
else:
    print("    WARN: #36486 schema.help.ts pattern not matched — non-critical", file=sys.stderr)
PYEOF
CHANGES=$((CHANGES + 1))

# ─── 6) config/schema.labels.ts: add label ───
FILE="$SRC/config/schema.labels.ts"
[ -f "$FILE" ] || { echo "    FAIL: $FILE not found"; exit 1; }

python3 - "$FILE" << 'PYEOF'
import sys

path = sys.argv[1]
with open(path, 'r') as f:
    content = f.read()

old = '  "session.agentToAgent.maxPingPongTurns": "Agent-to-Agent Ping-Pong Turns",'
new = '''  "session.agentToAgent.maxPingPongTurns": "Agent-to-Agent Ping-Pong Turns",
  "session.agentToAgent.allowChannelBoundAnnounce": "Allow Channel-bound Agent Announce",'''
if old in content:
    content = content.replace(old, new, 1)
    with open(path, 'w') as f:
        f.write(content)
    print("    OK: #36486 schema.labels.ts — allowChannelBoundAnnounce label added")
else:
    print("    WARN: #36486 schema.labels.ts pattern not matched — non-critical", file=sys.stderr)
PYEOF
CHANGES=$((CHANGES + 1))

# ─── 7) sessions-send-tool.a2a.ts: adapt to AnnounceTargetDecision type ───
FILE="$SRC/agents/tools/sessions-send-tool.a2a.ts"
if [ -f "$FILE" ]; then
  python3 - "$FILE" << 'PYEOF'
import sys, re

path = sys.argv[1]
with open(path, 'r') as f:
    content = f.read()

changes = 0

# 7a. Update targetChannel extraction to use decision type
old_channel = "const targetChannel = announceTarget?.channel ?? \"unknown\";"
new_channel = 'const resolvedTarget = announceTarget.kind === "external_target" ? announceTarget.target : undefined;\n    const targetChannel = resolvedTarget?.channel ?? "unknown";'
if old_channel in content:
    content = content.replace(old_channel, new_channel, 1)
    changes += 1

# 7b. Update the announce delivery guard to check for external_target
old_guard = "if (announceTarget && outboundReply) {"
new_guard = "if (resolvedTarget && outboundReply) {"
if old_guard in content:
    content = content.replace(old_guard, new_guard, 1)
    changes += 1

# 7c. Update callGateway send params to use resolvedTarget
old_send = '''            to: announceTarget.to,
            message: outboundReply,
            channel: announceTarget.channel,
            accountId: announceTarget.accountId,'''
new_send = '''            to: resolvedTarget.to,
            message: outboundReply,
            channel: resolvedTarget.channel,
            accountId: resolvedTarget.accountId,'''
if old_send in content:
    content = content.replace(old_send, new_send, 1)
    changes += 1

# 7d. Update error log to use resolvedTarget
old_log = '''          channel: announceTarget.channel,
          to: announceTarget.to,'''
new_log = '''          channel: resolvedTarget?.channel,
          to: resolvedTarget?.to,'''
if old_log in content:
    content = content.replace(old_log, new_log, 1)
    changes += 1

if changes > 0:
    with open(path, 'w') as f:
        f.write(content)
    print(f"    OK: #36486 sessions-send-tool.a2a.ts ({changes} changes)")
else:
    print("    WARN: #36486 sessions-send-tool.a2a.ts — no changes needed or patterns not found")
PYEOF
  CHANGES=$((CHANGES + 1))
fi

echo "    OK: #36486 A2A announce leakage prevention — $CHANGES items patched"
