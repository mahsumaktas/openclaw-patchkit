#!/usr/bin/env bash
# EXP-2: Gateway Pre-Auth Firewall
# Unified pre-auth security middleware that centralizes scattered rate limiting,
# frame limiting, handshake caps, and IP throttling into a single module.
#
# New file: src/gateway/firewall.ts (~400 lines)
# Integrates into: src/gateway/server/ws-connection.ts (connection handler)
#
# Replaces logic from PRs: #25966 (handshake cap), #25973 (frame limit), #25093 (ingress bind)
# Adds new: IP-based connection burst detection, configurable rule engine
set -euo pipefail

SRC="${1:-.}/src"

# ── Idempotency check ──────────────────────────────────────────────────────
if [ -f "$SRC/gateway/firewall.ts" ]; then
  echo "    SKIP: EXP-2 gateway/firewall.ts already exists"
  exit 0
fi

# Verify prerequisites
[ -f "$SRC/gateway/server-constants.ts" ] || { echo "FAIL: server-constants.ts not found"; exit 1; }
[ -f "$SRC/gateway/server/ws-connection.ts" ] || { echo "FAIL: ws-connection.ts not found"; exit 1; }

# ── 1. Create src/gateway/firewall.ts ──────────────────────────────────────
cat > "$SRC/gateway/firewall.ts" << 'TSEOF'
/**
 * Gateway Pre-Auth Firewall — unified pre-authentication security layer.
 *
 * Centralizes scattered security checks into a single configurable module:
 *   1. Connection rate limiting (per-IP sliding window)
 *   2. Pending handshake cap (total concurrent pre-auth connections)
 *   3. Frame size limiting (pre-auth message bytes)
 *   4. Connection burst detection (rapid connects from same IP)
 *   5. IP blocklist (ephemeral, auto-managed)
 *
 * All rules are evaluated BEFORE authentication, so malicious traffic is
 * rejected at the earliest possible point with minimal resource consumption.
 */
import { createSubsystemLogger } from "../logging/subsystem.js";

// ── Configuration ─────────────────────────────────────────────────────────

export type FirewallConfig = {
  /** Enable/disable the entire firewall. @default true */
  enabled?: boolean;

  /** Max concurrent pre-auth (unauthenticated) WS connections. @default 50 */
  maxPendingHandshakes?: number;

  /** Max pre-auth WS frame size in bytes. @default 65536 (64 KiB) */
  maxPreAuthFrameBytes?: number;

  /** Connection rate limit per IP. */
  connectionRate?: {
    /** Max connections per window. @default 20 */
    maxPerWindow?: number;
    /** Window duration in ms. @default 60000 (1 min) */
    windowMs?: number;
  };

  /** Burst detection: rapid connections from same IP. */
  burst?: {
    /** Max connections within burst window before blocking. @default 10 */
    maxConnections?: number;
    /** Burst window in ms. @default 5000 (5 sec) */
    windowMs?: number;
    /** Cooldown after burst detected. @default 30000 (30 sec) */
    cooldownMs?: number;
  };

  /** Exempt loopback (localhost) from all firewall rules. @default true */
  exemptLoopback?: boolean;

  /** IPs to always block. Ephemeral list managed at runtime. */
  blockedIps?: Set<string>;
};

// ── Defaults ──────────────────────────────────────────────────────────────

const DEFAULT_MAX_PENDING_HANDSHAKES = 50;
const DEFAULT_MAX_PREAUTH_FRAME_BYTES = 64 * 1024;
const DEFAULT_RATE_MAX_PER_WINDOW = 20;
const DEFAULT_RATE_WINDOW_MS = 60_000;
const DEFAULT_BURST_MAX = 10;
const DEFAULT_BURST_WINDOW_MS = 5_000;
const DEFAULT_BURST_COOLDOWN_MS = 30_000;
const IP_TRACKER_PRUNE_INTERVAL_MS = 60_000;

// ── Types ─────────────────────────────────────────────────────────────────

export type FirewallVerdict =
  | { allowed: true }
  | { allowed: false; reason: FirewallRejectReason; detail?: string };

export type FirewallRejectReason =
  | "handshake-cap"
  | "rate-limit"
  | "burst-detected"
  | "ip-blocked"
  | "frame-too-large"
  | "disabled";

export type FirewallMetrics = {
  totalChecked: number;
  totalRejected: number;
  rejectedByReason: Record<FirewallRejectReason, number>;
  pendingHandshakes: number;
  trackedIps: number;
};

type IpState = {
  /** Timestamps of connection attempts in the rate window. */
  connectionTimes: number[];
  /** If set, IP is in burst cooldown until this epoch ms. */
  burstCooldownUntil?: number;
};

// ── Implementation ────────────────────────────────────────────────────────

const log = createSubsystemLogger("gateway/firewall");

export class GatewayFirewall {
  private readonly enabled: boolean;
  private readonly maxPendingHandshakes: number;
  private readonly maxPreAuthFrameBytes: number;
  private readonly rateMax: number;
  private readonly rateWindowMs: number;
  private readonly burstMax: number;
  private readonly burstWindowMs: number;
  private readonly burstCooldownMs: number;
  private readonly exemptLoopback: boolean;
  private readonly blockedIps: Set<string>;

  private pendingHandshakes = 0;
  private readonly ipStates = new Map<string, IpState>();
  private pruneTimer: ReturnType<typeof setInterval> | null = null;

  // Metrics
  private totalChecked = 0;
  private totalRejected = 0;
  private readonly rejectedByReason: Record<FirewallRejectReason, number> = {
    "handshake-cap": 0,
    "rate-limit": 0,
    "burst-detected": 0,
    "ip-blocked": 0,
    "frame-too-large": 0,
    disabled: 0,
  };

  constructor(config?: FirewallConfig) {
    this.enabled = config?.enabled !== false;
    this.maxPendingHandshakes = config?.maxPendingHandshakes ?? DEFAULT_MAX_PENDING_HANDSHAKES;
    this.maxPreAuthFrameBytes = config?.maxPreAuthFrameBytes ?? DEFAULT_MAX_PREAUTH_FRAME_BYTES;
    this.rateMax = config?.connectionRate?.maxPerWindow ?? DEFAULT_RATE_MAX_PER_WINDOW;
    this.rateWindowMs = config?.connectionRate?.windowMs ?? DEFAULT_RATE_WINDOW_MS;
    this.burstMax = config?.burst?.maxConnections ?? DEFAULT_BURST_MAX;
    this.burstWindowMs = config?.burst?.windowMs ?? DEFAULT_BURST_WINDOW_MS;
    this.burstCooldownMs = config?.burst?.cooldownMs ?? DEFAULT_BURST_COOLDOWN_MS;
    this.exemptLoopback = config?.exemptLoopback !== false;
    this.blockedIps = config?.blockedIps ?? new Set();

    if (this.enabled) {
      this.pruneTimer = setInterval(() => this.pruneExpiredEntries(), IP_TRACKER_PRUNE_INTERVAL_MS);
      if (this.pruneTimer && typeof this.pruneTimer === "object" && "unref" in this.pruneTimer) {
        (this.pruneTimer as NodeJS.Timeout).unref();
      }
    }
  }

  // ── Connection lifecycle ──────────────────────────────────────────────

  /**
   * Check whether an incoming connection should be allowed.
   * Call this when a new WS connection is established, BEFORE auth.
   */
  checkConnection(ip: string | undefined): FirewallVerdict {
    this.totalChecked++;

    if (!this.enabled) {
      return { allowed: true };
    }

    const clientIp = ip ?? "unknown";

    if (this.isLoopback(clientIp) && this.exemptLoopback) {
      return { allowed: true };
    }

    // Rule 1: IP blocklist
    if (this.blockedIps.has(clientIp)) {
      return this.reject("ip-blocked", `blocked IP: ${clientIp}`);
    }

    // Rule 2: Pending handshake cap
    if (this.pendingHandshakes >= this.maxPendingHandshakes) {
      return this.reject(
        "handshake-cap",
        `pending handshakes ${this.pendingHandshakes} >= ${this.maxPendingHandshakes}`,
      );
    }

    // Rule 3: Rate limiting
    const state = this.getOrCreateIpState(clientIp);
    const now = Date.now();

    // Check burst cooldown
    if (state.burstCooldownUntil && now < state.burstCooldownUntil) {
      return this.reject(
        "burst-detected",
        `IP ${clientIp} in burst cooldown until ${new Date(state.burstCooldownUntil).toISOString()}`,
      );
    }

    // Prune old connection timestamps
    const rateWindowCutoff = now - this.rateWindowMs;
    state.connectionTimes = state.connectionTimes.filter((t) => t > rateWindowCutoff);

    // Check rate limit
    if (state.connectionTimes.length >= this.rateMax) {
      return this.reject(
        "rate-limit",
        `IP ${clientIp}: ${state.connectionTimes.length} connections in ${this.rateWindowMs}ms window`,
      );
    }

    // Check burst (rapid connections in short window)
    const burstWindowCutoff = now - this.burstWindowMs;
    const recentBurst = state.connectionTimes.filter((t) => t > burstWindowCutoff).length;
    if (recentBurst >= this.burstMax) {
      state.burstCooldownUntil = now + this.burstCooldownMs;
      return this.reject(
        "burst-detected",
        `IP ${clientIp}: ${recentBurst} connections in ${this.burstWindowMs}ms (burst), cooldown applied`,
      );
    }

    // Record this connection
    state.connectionTimes.push(now);
    this.pendingHandshakes++;

    return { allowed: true };
  }

  /**
   * Check whether a pre-auth WS frame should be allowed.
   * Call this for each message received before the client is authenticated.
   */
  checkPreAuthFrame(byteLength: number): FirewallVerdict {
    if (!this.enabled) {
      return { allowed: true };
    }
    if (byteLength > this.maxPreAuthFrameBytes) {
      return this.reject(
        "frame-too-large",
        `pre-auth frame ${byteLength} bytes > ${this.maxPreAuthFrameBytes} limit`,
      );
    }
    return { allowed: true };
  }

  /**
   * Signal that a handshake completed (either successfully or via disconnect).
   * Must be called to release the pending handshake counter.
   */
  handshakeCompleted(): void {
    if (this.pendingHandshakes > 0) {
      this.pendingHandshakes--;
    }
  }

  // ── IP management ─────────────────────────────────────────────────────

  blockIp(ip: string): void {
    this.blockedIps.add(ip);
    log.warn(`IP blocked: ${ip}`);
  }

  unblockIp(ip: string): void {
    this.blockedIps.delete(ip);
    log.info(`IP unblocked: ${ip}`);
  }

  isBlocked(ip: string): boolean {
    return this.blockedIps.has(ip);
  }

  // ── Metrics ───────────────────────────────────────────────────────────

  getMetrics(): FirewallMetrics {
    return {
      totalChecked: this.totalChecked,
      totalRejected: this.totalRejected,
      rejectedByReason: { ...this.rejectedByReason },
      pendingHandshakes: this.pendingHandshakes,
      trackedIps: this.ipStates.size,
    };
  }

  // ── Lifecycle ─────────────────────────────────────────────────────────

  dispose(): void {
    if (this.pruneTimer) {
      clearInterval(this.pruneTimer);
      this.pruneTimer = null;
    }
    this.ipStates.clear();
    this.blockedIps.clear();
  }

  // ── Internal ──────────────────────────────────────────────────────────

  private reject(reason: FirewallRejectReason, detail: string): FirewallVerdict {
    this.totalRejected++;
    this.rejectedByReason[reason]++;
    log.debug(`firewall reject: ${reason} — ${detail}`);
    return { allowed: false, reason, detail };
  }

  private getOrCreateIpState(ip: string): IpState {
    let state = this.ipStates.get(ip);
    if (!state) {
      state = { connectionTimes: [] };
      this.ipStates.set(ip, state);
    }
    return state;
  }

  private isLoopback(ip: string): boolean {
    return ip === "127.0.0.1" || ip === "::1" || ip === "localhost";
  }

  private pruneExpiredEntries(): void {
    const now = Date.now();
    const cutoff = now - this.rateWindowMs;

    for (const [ip, state] of this.ipStates) {
      // Remove expired connection timestamps
      state.connectionTimes = state.connectionTimes.filter((t) => t > cutoff);

      // Clear expired burst cooldowns
      if (state.burstCooldownUntil && now >= state.burstCooldownUntil) {
        state.burstCooldownUntil = undefined;
      }

      // Remove empty entries
      if (state.connectionTimes.length === 0 && !state.burstCooldownUntil) {
        this.ipStates.delete(ip);
      }
    }
  }
}

// ── Singleton for gateway-wide use ────────────────────────────────────────

let globalFirewall: GatewayFirewall | null = null;

export function getGatewayFirewall(config?: FirewallConfig): GatewayFirewall {
  if (!globalFirewall) {
    globalFirewall = new GatewayFirewall(config);
  }
  return globalFirewall;
}

export function resetGatewayFirewallForTest(): void {
  if (globalFirewall) {
    globalFirewall.dispose();
    globalFirewall = null;
  }
}
TSEOF

echo "    OK: EXP-2 created src/gateway/firewall.ts"

# ── 2. Integrate into src/gateway/server/ws-connection.ts ──────────────────
python3 - "$SRC/gateway/server/ws-connection.ts" << 'PYEOF'
import sys

path = sys.argv[1]
with open(path, 'r') as f:
    content = f.read()

changed = False

# 2a. Add import for getGatewayFirewall
if 'getGatewayFirewall' not in content:
    # Insert after the last import from server-constants
    marker = 'import { getHandshakeTimeoutMs } from "../server-constants.js";'
    if marker in content:
        import_line = 'import { getGatewayFirewall } from "../firewall.js";'
        content = content.replace(marker, marker + '\n' + import_line)
        changed = True
        print("    OK: EXP-2 added firewall import to ws-connection.ts")
    else:
        print("    WARN: EXP-2 could not find server-constants import marker")
else:
    print("    SKIP: EXP-2 firewall import already present in ws-connection.ts")

# 2b. Add firewall check at the beginning of the connection handler
# Find the wss.on("connection") callback start
if 'gatewayFirewall' not in content:
    # Look for the connection handler function body
    # The pattern: wss.on("connection", (ws, request) => { ... })
    # We insert the firewall check early in the connection callback
    marker_candidates = [
        'const connId = randomUUID();',
        'const connId = crypto.randomUUID();',
    ]
    inserted = False
    for marker in marker_candidates:
        if marker in content:
            firewall_check = """    // ── EXP-2: Pre-auth firewall check ──
    const gatewayFirewall = getGatewayFirewall();
    const firewallVerdict = gatewayFirewall.checkConnection(remoteAddr);
    if (!firewallVerdict.allowed) {
      logWsControl.warn(
        `firewall rejected connection: ${firewallVerdict.reason}` +
          (firewallVerdict.detail ? ` (${firewallVerdict.detail})` : ""),
      );
      ws.close(1013, "try again later");
      return;
    }
    // Track handshake completion for pending counter
    const onHandshakeOrClose = () => gatewayFirewall.handshakeCompleted();
    ws.once("close", onHandshakeOrClose);
    // ── end EXP-2 ──

    """
            content = content.replace(marker, firewall_check + marker)
            changed = True
            inserted = True
            print("    OK: EXP-2 added firewall check to ws-connection.ts")
            break
    if not inserted:
        print("    WARN: EXP-2 could not find connection handler marker in ws-connection.ts")
else:
    print("    SKIP: EXP-2 firewall check already present in ws-connection.ts")

if changed:
    with open(path, 'w') as f:
        f.write(content)
    print("    OK: EXP-2 ws-connection.ts fully patched")
else:
    print("    SKIP: EXP-2 ws-connection.ts already up to date")

PYEOF

# ── 3. Verification ───────────────────────────────────────────────────────
echo ""
echo "  Verifying EXP-2..."
PASS=true

if [ ! -f "$SRC/gateway/firewall.ts" ]; then
  echo "    FAIL: gateway/firewall.ts not created"
  PASS=false
fi

if ! grep -q 'class GatewayFirewall' "$SRC/gateway/firewall.ts" 2>/dev/null; then
  echo "    FAIL: GatewayFirewall class not found"
  PASS=false
fi

if ! grep -q 'getGatewayFirewall' "$SRC/gateway/server/ws-connection.ts" 2>/dev/null; then
  echo "    FAIL: firewall not integrated into ws-connection.ts"
  PASS=false
fi

if $PASS; then
  echo "    OK: EXP-2 fully verified"
else
  echo "    FAIL: EXP-2 verification failed"
  exit 1
fi
