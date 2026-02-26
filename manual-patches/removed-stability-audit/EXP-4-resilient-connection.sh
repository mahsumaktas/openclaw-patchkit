#!/usr/bin/env bash
# EXP-4: Resilient Channel Connection Base Class
# Generic base class for channel connections with exponential backoff,
# circuit breaker, stale session detection, and connection health monitoring.
#
# New file: src/channels/resilient-connection.ts (~300 lines)
# Does NOT modify existing files — channels opt-in by extending the base class.
#
# Channels that would benefit:
#   - Discord (fixes death spiral from #25974)
#   - IRC (fixes monitor loop from #26918)
#   - Telegram polling, Slack socket mode — preventive
#
# Risk: LOW — purely additive, no existing code modified
set -euo pipefail

SRC="${1:-.}/src"

# ── Idempotency check ──────────────────────────────────────────────────────
if [ -f "$SRC/channels/resilient-connection.ts" ]; then
  echo "    SKIP: EXP-4 resilient-connection.ts already exists"
  exit 0
fi

# Verify prerequisite directories
[ -d "$SRC/channels" ] || { echo "FAIL: src/channels/ directory not found"; exit 1; }

# ── 1. Create src/channels/resilient-connection.ts ─────────────────────────
cat > "$SRC/channels/resilient-connection.ts" << 'TSEOF'
/**
 * Resilient Channel Connection — base class providing standardized
 * reconnection logic for all channel adapters.
 *
 * Features:
 *   - Exponential backoff with configurable jitter
 *   - Circuit breaker (open/half-open/closed states)
 *   - Stale session detection and forced reconnect
 *   - Connection health monitoring with heartbeat
 *   - Per-connection metrics and logging
 *
 * Usage:
 *   class DiscordGatewayConnection extends ResilientConnection {
 *     protected async doConnect(): Promise<void> { ... }
 *     protected async doDisconnect(): Promise<void> { ... }
 *     protected async doHealthCheck(): Promise<boolean> { ... }
 *   }
 */
import { createSubsystemLogger } from "../logging/subsystem.js";

// ── Configuration ─────────────────────────────────────────────────────────

export type ResilientConnectionConfig = {
  /** Channel name for logging. */
  channel: string;

  /** Optional account/instance identifier. */
  accountId?: string;

  /** Backoff configuration. */
  backoff?: {
    /** Initial delay in ms. @default 1000 */
    initialDelayMs?: number;
    /** Maximum delay in ms. @default 60000 */
    maxDelayMs?: number;
    /** Backoff multiplier. @default 2 */
    multiplier?: number;
    /** Jitter factor (0-1). @default 0.2 */
    jitter?: number;
  };

  /** Circuit breaker configuration. */
  circuitBreaker?: {
    /** Consecutive failures before opening circuit. @default 5 */
    failureThreshold?: number;
    /** Time in ms before half-open attempt. @default 30000 */
    resetTimeoutMs?: number;
    /** Successful connects in half-open to close circuit. @default 2 */
    successThreshold?: number;
  };

  /** Stale session detection. */
  staleSession?: {
    /** Max time in ms without activity before declaring stale. @default 120000 (2 min) */
    maxIdleMs?: number;
    /** Enable periodic stale checks. @default true */
    enabled?: boolean;
  };

  /** Health check interval in ms. 0 to disable. @default 30000 */
  healthCheckIntervalMs?: number;

  /** Maximum reconnect attempts before giving up. 0 = unlimited. @default 0 */
  maxReconnectAttempts?: number;

  /** Abort signal for external cancellation. */
  abortSignal?: AbortSignal;
};

// ── Types ─────────────────────────────────────────────────────────────────

export type ConnectionState =
  | "disconnected"
  | "connecting"
  | "connected"
  | "reconnecting"
  | "failed";

export type CircuitState = "closed" | "open" | "half-open";

export type ConnectionMetrics = {
  state: ConnectionState;
  circuitState: CircuitState;
  totalConnects: number;
  totalDisconnects: number;
  totalFailures: number;
  consecutiveFailures: number;
  lastConnectedAt: number | null;
  lastDisconnectedAt: number | null;
  lastFailureAt: number | null;
  lastActivityAt: number | null;
  uptimeMs: number;
};

export type ConnectionEvent =
  | { type: "connected" }
  | { type: "disconnected"; reason?: string }
  | { type: "reconnecting"; attempt: number; delayMs: number }
  | { type: "failed"; error: string }
  | { type: "circuit-open"; failures: number }
  | { type: "circuit-half-open" }
  | { type: "circuit-closed" }
  | { type: "stale-detected"; idleMs: number };

type EventListener = (event: ConnectionEvent) => void;

// ── Defaults ──────────────────────────────────────────────────────────────

const DEFAULT_INITIAL_DELAY_MS = 1_000;
const DEFAULT_MAX_DELAY_MS = 60_000;
const DEFAULT_MULTIPLIER = 2;
const DEFAULT_JITTER = 0.2;
const DEFAULT_FAILURE_THRESHOLD = 5;
const DEFAULT_RESET_TIMEOUT_MS = 30_000;
const DEFAULT_SUCCESS_THRESHOLD = 2;
const DEFAULT_MAX_IDLE_MS = 120_000;
const DEFAULT_HEALTH_CHECK_INTERVAL_MS = 30_000;

// ── Implementation ────────────────────────────────────────────────────────

export abstract class ResilientConnection {
  protected readonly log;
  protected readonly config: Required<
    Pick<ResilientConnectionConfig, "channel">
  > &
    ResilientConnectionConfig;

  // State
  private _state: ConnectionState = "disconnected";
  private _circuitState: CircuitState = "closed";
  private consecutiveFailures = 0;
  private consecutiveSuccesses = 0;
  private reconnectAttempt = 0;
  private reconnectTimer: ReturnType<typeof setTimeout> | null = null;
  private healthCheckTimer: ReturnType<typeof setInterval> | null = null;
  private staleCheckTimer: ReturnType<typeof setInterval> | null = null;
  private circuitResetTimer: ReturnType<typeof setTimeout> | null = null;

  // Metrics
  private totalConnects = 0;
  private totalDisconnects = 0;
  private totalFailures = 0;
  private lastConnectedAt: number | null = null;
  private lastDisconnectedAt: number | null = null;
  private lastFailureAt: number | null = null;
  private _lastActivityAt: number | null = null;

  // Event listeners
  private readonly listeners: EventListener[] = [];

  // Abort
  private abortHandler: (() => void) | null = null;

  constructor(config: ResilientConnectionConfig) {
    this.config = config;
    const label = config.accountId
      ? `${config.channel}/${config.accountId}`
      : config.channel;
    this.log = createSubsystemLogger(`resilient-conn/${label}`);
  }

  // ── Abstract methods (implement in subclass) ──────────────────────────

  /** Establish the underlying connection. Throw on failure. */
  protected abstract doConnect(): Promise<void>;

  /** Tear down the underlying connection. */
  protected abstract doDisconnect(): Promise<void>;

  /** Return true if the connection is healthy. */
  protected abstract doHealthCheck(): Promise<boolean>;

  // ── Public API ────────────────────────────────────────────────────────

  get state(): ConnectionState {
    return this._state;
  }

  get circuitState(): CircuitState {
    return this._circuitState;
  }

  get lastActivityAt(): number | null {
    return this._lastActivityAt;
  }

  /** Record activity (call from subclass on data received). */
  recordActivity(): void {
    this._lastActivityAt = Date.now();
  }

  /** Connect (or reconnect). */
  async connect(): Promise<void> {
    if (this._state === "connected" || this._state === "connecting") {
      return;
    }

    // Circuit breaker check
    if (this._circuitState === "open") {
      this.log.warn("circuit breaker is open, rejecting connect");
      return;
    }

    this._state = "connecting";

    // Listen for external abort
    if (this.config.abortSignal && !this.abortHandler) {
      this.abortHandler = () => {
        void this.disconnect("abort signal");
      };
      this.config.abortSignal.addEventListener("abort", this.abortHandler, { once: true });
    }

    try {
      await this.doConnect();
      this.onConnectSuccess();
    } catch (err) {
      this.onConnectFailure(String(err));
    }
  }

  /** Disconnect and stop all timers. */
  async disconnect(reason?: string): Promise<void> {
    this.clearAllTimers();

    if (this._state === "disconnected" || this._state === "failed") {
      return;
    }

    try {
      await this.doDisconnect();
    } catch (err) {
      this.log.warn(`disconnect error: ${String(err)}`);
    }

    this._state = "disconnected";
    this.totalDisconnects++;
    this.lastDisconnectedAt = Date.now();
    this.emit({ type: "disconnected", reason });

    if (this.abortHandler && this.config.abortSignal) {
      this.config.abortSignal.removeEventListener("abort", this.abortHandler);
      this.abortHandler = null;
    }
  }

  /** Subscribe to connection events. */
  on(listener: EventListener): () => void {
    this.listeners.push(listener);
    return () => {
      const idx = this.listeners.indexOf(listener);
      if (idx >= 0) this.listeners.splice(idx, 1);
    };
  }

  /** Get current metrics. */
  getMetrics(): ConnectionMetrics {
    const now = Date.now();
    const uptimeMs =
      this._state === "connected" && this.lastConnectedAt
        ? now - this.lastConnectedAt
        : 0;

    return {
      state: this._state,
      circuitState: this._circuitState,
      totalConnects: this.totalConnects,
      totalDisconnects: this.totalDisconnects,
      totalFailures: this.totalFailures,
      consecutiveFailures: this.consecutiveFailures,
      lastConnectedAt: this.lastConnectedAt,
      lastDisconnectedAt: this.lastDisconnectedAt,
      lastFailureAt: this.lastFailureAt,
      lastActivityAt: this._lastActivityAt,
      uptimeMs,
    };
  }

  // ── Internal: connection lifecycle ────────────────────────────────────

  private onConnectSuccess(): void {
    this._state = "connected";
    this.totalConnects++;
    this.lastConnectedAt = Date.now();
    this._lastActivityAt = Date.now();
    this.consecutiveFailures = 0;
    this.reconnectAttempt = 0;

    // Circuit breaker: track successes in half-open
    if (this._circuitState === "half-open") {
      this.consecutiveSuccesses++;
      const threshold =
        this.config.circuitBreaker?.successThreshold ?? DEFAULT_SUCCESS_THRESHOLD;
      if (this.consecutiveSuccesses >= threshold) {
        this._circuitState = "closed";
        this.consecutiveSuccesses = 0;
        this.emit({ type: "circuit-closed" });
        this.log.info("circuit breaker closed");
      }
    }

    this.startHealthCheck();
    this.startStaleCheck();
    this.emit({ type: "connected" });
    this.log.info("connected");
  }

  private onConnectFailure(error: string): void {
    this.totalFailures++;
    this.consecutiveFailures++;
    this.lastFailureAt = Date.now();
    this.log.warn(`connect failed (attempt ${this.reconnectAttempt + 1}): ${error}`);

    // Circuit breaker
    const failureThreshold =
      this.config.circuitBreaker?.failureThreshold ?? DEFAULT_FAILURE_THRESHOLD;
    if (this.consecutiveFailures >= failureThreshold) {
      this.openCircuitBreaker();
      return;
    }

    // Max attempts check
    const maxAttempts = this.config.maxReconnectAttempts ?? 0;
    if (maxAttempts > 0 && this.reconnectAttempt >= maxAttempts) {
      this._state = "failed";
      this.emit({ type: "failed", error: `max reconnect attempts (${maxAttempts}) reached` });
      this.log.error(`giving up after ${maxAttempts} reconnect attempts`);
      return;
    }

    this.scheduleReconnect();
  }

  // ── Internal: reconnect scheduling ────────────────────────────────────

  private scheduleReconnect(): void {
    this.reconnectAttempt++;
    const delay = this.calculateBackoffDelay();

    this._state = "reconnecting";
    this.emit({ type: "reconnecting", attempt: this.reconnectAttempt, delayMs: delay });
    this.log.info(`reconnecting in ${delay}ms (attempt ${this.reconnectAttempt})`);

    this.reconnectTimer = setTimeout(() => {
      this.reconnectTimer = null;
      void this.connect();
    }, delay);

    if (this.reconnectTimer && typeof this.reconnectTimer === "object" && "unref" in this.reconnectTimer) {
      (this.reconnectTimer as NodeJS.Timeout).unref();
    }
  }

  private calculateBackoffDelay(): number {
    const initialDelay =
      this.config.backoff?.initialDelayMs ?? DEFAULT_INITIAL_DELAY_MS;
    const maxDelay = this.config.backoff?.maxDelayMs ?? DEFAULT_MAX_DELAY_MS;
    const multiplier = this.config.backoff?.multiplier ?? DEFAULT_MULTIPLIER;
    const jitter = this.config.backoff?.jitter ?? DEFAULT_JITTER;

    const exponential = initialDelay * Math.pow(multiplier, this.reconnectAttempt - 1);
    const capped = Math.min(exponential, maxDelay);
    const jitterRange = capped * jitter;
    const jitterOffset = (Math.random() - 0.5) * 2 * jitterRange;

    return Math.max(0, Math.floor(capped + jitterOffset));
  }

  // ── Internal: circuit breaker ─────────────────────────────────────────

  private openCircuitBreaker(): void {
    this._circuitState = "open";
    this._state = "failed";
    this.consecutiveSuccesses = 0;
    const resetTimeout =
      this.config.circuitBreaker?.resetTimeoutMs ?? DEFAULT_RESET_TIMEOUT_MS;

    this.emit({ type: "circuit-open", failures: this.consecutiveFailures });
    this.log.warn(
      `circuit breaker OPEN after ${this.consecutiveFailures} failures, ` +
        `will attempt half-open in ${resetTimeout}ms`,
    );

    this.circuitResetTimer = setTimeout(() => {
      this.circuitResetTimer = null;
      this._circuitState = "half-open";
      this._state = "disconnected";
      this.consecutiveFailures = 0;
      this.emit({ type: "circuit-half-open" });
      this.log.info("circuit breaker half-open, attempting reconnect");
      void this.connect();
    }, resetTimeout);

    if (this.circuitResetTimer && typeof this.circuitResetTimer === "object" && "unref" in this.circuitResetTimer) {
      (this.circuitResetTimer as NodeJS.Timeout).unref();
    }
  }

  // ── Internal: health check ────────────────────────────────────────────

  private startHealthCheck(): void {
    const interval = this.config.healthCheckIntervalMs ?? DEFAULT_HEALTH_CHECK_INTERVAL_MS;
    if (interval <= 0) return;

    this.stopHealthCheck();
    this.healthCheckTimer = setInterval(() => {
      void this.runHealthCheck();
    }, interval);

    if (this.healthCheckTimer && typeof this.healthCheckTimer === "object" && "unref" in this.healthCheckTimer) {
      (this.healthCheckTimer as NodeJS.Timeout).unref();
    }
  }

  private stopHealthCheck(): void {
    if (this.healthCheckTimer) {
      clearInterval(this.healthCheckTimer);
      this.healthCheckTimer = null;
    }
  }

  private async runHealthCheck(): Promise<void> {
    if (this._state !== "connected") return;

    try {
      const healthy = await this.doHealthCheck();
      if (healthy) {
        this.recordActivity();
      } else {
        this.log.warn("health check failed, initiating reconnect");
        await this.disconnect("health check failed");
        void this.connect();
      }
    } catch (err) {
      this.log.warn(`health check error: ${String(err)}`);
    }
  }

  // ── Internal: stale session detection ─────────────────────────────────

  private startStaleCheck(): void {
    const staleConfig = this.config.staleSession;
    if (staleConfig?.enabled === false) return;

    const maxIdleMs = staleConfig?.maxIdleMs ?? DEFAULT_MAX_IDLE_MS;
    if (maxIdleMs <= 0) return;

    this.stopStaleCheck();
    // Check at half the max idle interval
    const checkInterval = Math.max(5_000, Math.floor(maxIdleMs / 2));
    this.staleCheckTimer = setInterval(() => {
      if (this._state !== "connected") return;
      const now = Date.now();
      const lastActivity = this._lastActivityAt ?? this.lastConnectedAt ?? 0;
      const idleMs = now - lastActivity;

      if (idleMs > maxIdleMs) {
        this.log.warn(
          `stale session detected: idle for ${Math.floor(idleMs / 1000)}s ` +
            `(threshold: ${Math.floor(maxIdleMs / 1000)}s)`,
        );
        this.emit({ type: "stale-detected", idleMs });
        void this.disconnect("stale session");
        void this.connect();
      }
    }, checkInterval);

    if (this.staleCheckTimer && typeof this.staleCheckTimer === "object" && "unref" in this.staleCheckTimer) {
      (this.staleCheckTimer as NodeJS.Timeout).unref();
    }
  }

  private stopStaleCheck(): void {
    if (this.staleCheckTimer) {
      clearInterval(this.staleCheckTimer);
      this.staleCheckTimer = null;
    }
  }

  // ── Internal: utilities ───────────────────────────────────────────────

  private clearAllTimers(): void {
    if (this.reconnectTimer) {
      clearTimeout(this.reconnectTimer);
      this.reconnectTimer = null;
    }
    if (this.circuitResetTimer) {
      clearTimeout(this.circuitResetTimer);
      this.circuitResetTimer = null;
    }
    this.stopHealthCheck();
    this.stopStaleCheck();
  }

  private emit(event: ConnectionEvent): void {
    for (const listener of this.listeners) {
      try {
        listener(event);
      } catch (err) {
        this.log.warn(`event listener error: ${String(err)}`);
      }
    }
  }
}
TSEOF

echo "    OK: EXP-4 created src/channels/resilient-connection.ts"

# ── 2. No existing file modifications ─────────────────────────────────────
# This expansion is purely additive — channels opt-in by extending the base class.
# Future patches can modify discord/monitor/provider.lifecycle.ts to use it.
echo "    INFO: EXP-4 is purely additive, no existing files modified"

# ── 3. Verification ───────────────────────────────────────────────────────
echo ""
echo "  Verifying EXP-4..."
PASS=true

if [ ! -f "$SRC/channels/resilient-connection.ts" ]; then
  echo "    FAIL: resilient-connection.ts not created"
  PASS=false
fi

if ! grep -q 'abstract class ResilientConnection' "$SRC/channels/resilient-connection.ts" 2>/dev/null; then
  echo "    FAIL: ResilientConnection class not found"
  PASS=false
fi

if ! grep -q 'doConnect' "$SRC/channels/resilient-connection.ts" 2>/dev/null; then
  echo "    FAIL: abstract doConnect method not found"
  PASS=false
fi

if ! grep -q 'CircuitState' "$SRC/channels/resilient-connection.ts" 2>/dev/null; then
  echo "    FAIL: CircuitState type not found"
  PASS=false
fi

if $PASS; then
  echo "    OK: EXP-4 fully verified"
else
  echo "    FAIL: EXP-4 verification failed"
  exit 1
fi
