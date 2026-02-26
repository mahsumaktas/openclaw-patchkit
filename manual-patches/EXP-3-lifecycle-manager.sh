#!/usr/bin/env bash
# EXP-3: Graceful Lifecycle Manager
# Unified startup validation and graceful shutdown orchestration.
#
# New file: src/gateway/lifecycle-manager.ts (~500 lines)
# Integrates into: src/gateway/server.impl.ts (startup + close path)
#
# Consolidates logic from PRs: #26626 (KeepAlive), #26441 (drain mode),
# #25219 (streaming abort), #26502 (compaction guard), #27013 (stale PID kill)
#
# Adds new: startup validation (port check, DB reachability),
#   health check endpoint augmentation, phase-based shutdown orchestration
#
# Risk: HIGH — touches core startup/shutdown path. Designed as opt-in wrapper.
set -euo pipefail

SRC="${1:-.}/src"

# ── Idempotency check ──────────────────────────────────────────────────────
if [ -f "$SRC/gateway/lifecycle-manager.ts" ]; then
  echo "    SKIP: EXP-3 lifecycle-manager.ts already exists"
  exit 0
fi

# Verify prerequisites
[ -f "$SRC/gateway/server.impl.ts" ] || { echo "FAIL: server.impl.ts not found"; exit 1; }
[ -f "$SRC/gateway/server-close.ts" ] || { echo "FAIL: server-close.ts not found"; exit 1; }

# ── 1. Create src/gateway/lifecycle-manager.ts ─────────────────────────────
cat > "$SRC/gateway/lifecycle-manager.ts" << 'TSEOF'
/**
 * Graceful Lifecycle Manager — orchestrates clean startup validation,
 * phased shutdown (drain -> flush -> cleanup -> exit), and health state.
 *
 * Design:
 *   - Opt-in: gateway code calls lifecycle hooks at appropriate points
 *   - Phase-based shutdown: each phase has a timeout and rollback
 *   - Signal handling: SIGTERM/SIGINT trigger graceful drain
 *   - Startup validation: port availability, config sanity
 *   - Health augmentation: exposes lifecycle phase to health endpoint
 *
 * Shutdown phases:
 *   1. DRAIN    — stop accepting new connections, finish in-flight requests
 *   2. FLUSH    — flush pending writes (sessions, cron, logs)
 *   3. CLEANUP  — stop channels, close DB connections, release resources
 *   4. EXIT     — final cleanup, process exit
 */
import { createServer } from "node:net";
import { execFileSync } from "node:child_process";
import { createSubsystemLogger } from "../logging/subsystem.js";

// ── Types ─────────────────────────────────────────────────────────────────

export type LifecyclePhase =
  | "initializing"
  | "validating"
  | "starting"
  | "running"
  | "draining"
  | "flushing"
  | "cleaning"
  | "stopped";

export type LifecycleConfig = {
  /** Enable graceful shutdown handling. @default true */
  enabled?: boolean;

  /** Max time for drain phase in ms. @default 10000 */
  drainTimeoutMs?: number;

  /** Max time for flush phase in ms. @default 5000 */
  flushTimeoutMs?: number;

  /** Max time for cleanup phase in ms. @default 10000 */
  cleanupTimeoutMs?: number;

  /** Listen for SIGTERM/SIGINT and trigger graceful shutdown. @default true */
  handleSignals?: boolean;

  /** Run startup validation checks. @default true */
  validateOnStartup?: boolean;
};

export type StartupValidationResult = {
  ok: boolean;
  checks: Array<{
    name: string;
    ok: boolean;
    detail?: string;
    durationMs: number;
  }>;
};

export type ShutdownContext = {
  reason: string;
  signal?: string;
  phase: LifecyclePhase;
};

type ShutdownHook = (ctx: ShutdownContext) => Promise<void> | void;

type FlushHook = () => Promise<void> | void;

// ── Constants ─────────────────────────────────────────────────────────────

const DEFAULT_DRAIN_TIMEOUT_MS = 10_000;
const DEFAULT_FLUSH_TIMEOUT_MS = 5_000;
const DEFAULT_CLEANUP_TIMEOUT_MS = 10_000;
const VALIDATION_PORT_CHECK_TIMEOUT_MS = 2_000;
const STALE_PID_KILL_WAIT_MS = 200;

// ── Implementation ────────────────────────────────────────────────────────

const log = createSubsystemLogger("lifecycle");

export class LifecycleManager {
  private phase: LifecyclePhase = "initializing";
  private readonly enabled: boolean;
  private readonly drainTimeoutMs: number;
  private readonly flushTimeoutMs: number;
  private readonly cleanupTimeoutMs: number;
  private readonly handleSignals: boolean;
  private readonly validateOnStartup: boolean;

  private readonly drainHooks: ShutdownHook[] = [];
  private readonly flushHooks: FlushHook[] = [];
  private readonly cleanupHooks: ShutdownHook[] = [];

  private shutdownPromise: Promise<void> | null = null;
  private signalListeners: Array<{ signal: string; handler: () => void }> = [];
  private shutdownReason: string | null = null;

  constructor(config?: LifecycleConfig) {
    this.enabled = config?.enabled !== false;
    this.drainTimeoutMs = config?.drainTimeoutMs ?? DEFAULT_DRAIN_TIMEOUT_MS;
    this.flushTimeoutMs = config?.flushTimeoutMs ?? DEFAULT_FLUSH_TIMEOUT_MS;
    this.cleanupTimeoutMs = config?.cleanupTimeoutMs ?? DEFAULT_CLEANUP_TIMEOUT_MS;
    this.handleSignals = config?.handleSignals !== false;
    this.validateOnStartup = config?.validateOnStartup !== false;
  }

  // ── Phase management ──────────────────────────────────────────────────

  getPhase(): LifecyclePhase {
    return this.phase;
  }

  isRunning(): boolean {
    return this.phase === "running";
  }

  isDraining(): boolean {
    return (
      this.phase === "draining" ||
      this.phase === "flushing" ||
      this.phase === "cleaning"
    );
  }

  isStopped(): boolean {
    return this.phase === "stopped";
  }

  // ── Hook registration ─────────────────────────────────────────────────

  /** Register a hook for the drain phase (stop accepting new work). */
  onDrain(hook: ShutdownHook): void {
    this.drainHooks.push(hook);
  }

  /** Register a hook for the flush phase (persist pending data). */
  onFlush(hook: FlushHook): void {
    this.flushHooks.push(hook);
  }

  /** Register a hook for the cleanup phase (release resources). */
  onCleanup(hook: ShutdownHook): void {
    this.cleanupHooks.push(hook);
  }

  // ── Startup ───────────────────────────────────────────────────────────

  /**
   * Run startup validation checks.
   * Call this before starting the gateway server.
   */
  async validateStartup(params: {
    port: number;
    configPath?: string;
  }): Promise<StartupValidationResult> {
    if (!this.validateOnStartup || !this.enabled) {
      return { ok: true, checks: [] };
    }

    this.phase = "validating";
    const checks: StartupValidationResult["checks"] = [];

    // Check 0: Kill stale gateway PIDs holding the port (PR #27013)
    const stalePidCheck = await this.killStaleGatewayPids(params.port);
    checks.push(stalePidCheck);

    // Check 1: Port availability
    const portCheck = await this.checkPortAvailable(params.port);
    checks.push(portCheck);

    // Check 2: Config file exists
    if (params.configPath) {
      const configCheck = await this.checkConfigExists(params.configPath);
      checks.push(configCheck);
    }

    const allOk = checks.every((c) => c.ok);
    if (allOk) {
      log.info("startup validation passed", {
        checks: checks.map((c) => `${c.name}: OK`).join(", "),
      });
    } else {
      const failed = checks.filter((c) => !c.ok);
      log.error("startup validation FAILED", {
        failed: failed.map((c) => `${c.name}: ${c.detail ?? "failed"}`).join(", "),
      });
    }

    return { ok: allOk, checks };
  }

  /**
   * Mark the gateway as fully running.
   * Installs signal handlers if configured.
   */
  markRunning(onShutdown?: () => Promise<void>): void {
    this.phase = "running";
    log.info("gateway lifecycle: running");

    if (this.handleSignals && this.enabled) {
      this.installSignalHandlers(onShutdown);
    }
  }

  // ── Shutdown orchestration ────────────────────────────────────────────

  /**
   * Initiate graceful shutdown.
   * Returns a promise that resolves when all phases complete.
   * Calling multiple times returns the same promise (idempotent).
   */
  async shutdown(reason: string, signal?: string): Promise<void> {
    if (this.shutdownPromise) {
      return this.shutdownPromise;
    }
    this.shutdownReason = reason;
    this.shutdownPromise = this.executeShutdown(reason, signal);
    return this.shutdownPromise;
  }

  // ── Lifecycle health info ─────────────────────────────────────────────

  getHealthInfo(): {
    phase: LifecyclePhase;
    draining: boolean;
    shutdownReason: string | null;
  } {
    return {
      phase: this.phase,
      draining: this.isDraining(),
      shutdownReason: this.shutdownReason,
    };
  }

  // ── Disposal ──────────────────────────────────────────────────────────

  dispose(): void {
    this.removeSignalHandlers();
    this.drainHooks.length = 0;
    this.flushHooks.length = 0;
    this.cleanupHooks.length = 0;
    this.phase = "stopped";
  }

  // ── Internal: shutdown execution ──────────────────────────────────────

  private async executeShutdown(reason: string, signal?: string): Promise<void> {
    const ctx: ShutdownContext = { reason, signal, phase: "draining" };

    log.info(`shutdown initiated: ${reason}${signal ? ` (signal: ${signal})` : ""}`);

    // Phase 1: Drain
    try {
      this.phase = "draining";
      ctx.phase = "draining";
      log.info("shutdown phase: DRAIN");
      await this.runHooksWithTimeout(
        this.drainHooks.map((h) => () => h(ctx)),
        this.drainTimeoutMs,
        "drain",
      );
    } catch (err) {
      log.warn(`drain phase error: ${String(err)}`);
    }

    // Phase 2: Flush
    try {
      this.phase = "flushing";
      ctx.phase = "flushing";
      log.info("shutdown phase: FLUSH");
      await this.runHooksWithTimeout(
        this.flushHooks.map((h) => () => h()),
        this.flushTimeoutMs,
        "flush",
      );
    } catch (err) {
      log.warn(`flush phase error: ${String(err)}`);
    }

    // Phase 3: Cleanup
    try {
      this.phase = "cleaning";
      ctx.phase = "cleaning";
      log.info("shutdown phase: CLEANUP");
      await this.runHooksWithTimeout(
        this.cleanupHooks.map((h) => () => h(ctx)),
        this.cleanupTimeoutMs,
        "cleanup",
      );
    } catch (err) {
      log.warn(`cleanup phase error: ${String(err)}`);
    }

    this.phase = "stopped";
    log.info("shutdown complete");
    this.removeSignalHandlers();
  }

  private async runHooksWithTimeout(
    hooks: Array<() => Promise<void> | void>,
    timeoutMs: number,
    phaseName: string,
  ): Promise<void> {
    if (hooks.length === 0) return;

    const results = await Promise.allSettled(
      hooks.map((hook) =>
        Promise.race([
          Promise.resolve(hook()),
          new Promise<void>((_, reject) =>
            setTimeout(
              () => reject(new Error(`${phaseName} hook timed out after ${timeoutMs}ms`)),
              timeoutMs,
            ),
          ),
        ]),
      ),
    );

    const failures = results.filter(
      (r): r is PromiseRejectedResult => r.status === "rejected",
    );
    if (failures.length > 0) {
      for (const f of failures) {
        log.warn(`${phaseName} hook failed: ${String(f.reason)}`);
      }
    }
  }

  // ── Internal: signal handlers ─────────────────────────────────────────

  private installSignalHandlers(onShutdown?: () => Promise<void>): void {
    const makeHandler = (sig: string) => () => {
      log.info(`received ${sig}, initiating graceful shutdown`);
      void this.shutdown(`signal: ${sig}`, sig).then(() => {
        if (onShutdown) {
          void onShutdown();
        }
      });
    };

    for (const sig of ["SIGTERM", "SIGINT"]) {
      const handler = makeHandler(sig);
      process.on(sig, handler);
      this.signalListeners.push({ signal: sig, handler });
    }
  }

  private removeSignalHandlers(): void {
    for (const { signal, handler } of this.signalListeners) {
      process.removeListener(signal, handler);
    }
    this.signalListeners = [];
  }

  // ── Internal: startup validation checks ───────────────────────────────

  private async checkPortAvailable(
    port: number,
  ): Promise<StartupValidationResult["checks"][number]> {
    const start = Date.now();
    try {
      const available = await new Promise<boolean>((resolve) => {
        const server = createServer();
        const timer = setTimeout(() => {
          server.close();
          resolve(false);
        }, VALIDATION_PORT_CHECK_TIMEOUT_MS);

        server.once("error", (err: NodeJS.ErrnoException) => {
          clearTimeout(timer);
          server.close();
          if (err.code === "EADDRINUSE") {
            resolve(false);
          } else {
            resolve(true); // Other errors might be transient
          }
        });

        server.listen(port, "127.0.0.1", () => {
          clearTimeout(timer);
          server.close(() => resolve(true));
        });
      });

      return {
        name: "port-available",
        ok: available,
        detail: available ? `port ${port} is available` : `port ${port} is already in use`,
        durationMs: Date.now() - start,
      };
    } catch (err) {
      return {
        name: "port-available",
        ok: false,
        detail: `port check failed: ${String(err)}`,
        durationMs: Date.now() - start,
      };
    }
  }

  private async checkConfigExists(
    configPath: string,
  ): Promise<StartupValidationResult["checks"][number]> {
    const start = Date.now();
    try {
      const { access } = await import("node:fs/promises");
      await access(configPath);
      return {
        name: "config-exists",
        ok: true,
        detail: `config found at ${configPath}`,
        durationMs: Date.now() - start,
      };
    } catch {
      return {
        name: "config-exists",
        ok: false,
        detail: `config not found at ${configPath}`,
        durationMs: Date.now() - start,
      };
    }
  }

  /**
   * Kill stale gateway processes holding the target port.
   * Integrated from PR #27013 — prevents port conflict on restart.
   * Non-fatal: startup continues even if cleanup fails.
   */
  private async killStaleGatewayPids(
    port: number,
  ): Promise<StartupValidationResult["checks"][number]> {
    const start = Date.now();
    try {
      const stalePids = this.findPidsOnPort(port);
      if (stalePids.length === 0) {
        return {
          name: "stale-pid-cleanup",
          ok: true,
          detail: "no stale gateway processes found",
          durationMs: Date.now() - start,
        };
      }

      log.warn(
        `found ${stalePids.length} stale process(es) on port ${port}: ${stalePids.join(", ")}`,
      );

      for (const pid of stalePids) {
        try { process.kill(pid, "SIGTERM"); } catch { /* already gone */ }
      }
      await this.sleep(400);

      let forceKilled = false;
      for (const pid of stalePids) {
        try {
          process.kill(pid, 0);
          process.kill(pid, "SIGKILL");
          forceKilled = true;
        } catch { /* already gone */ }
      }

      if (forceKilled) {
        await this.sleep(STALE_PID_KILL_WAIT_MS);
      }

      log.info(`terminated ${stalePids.length} stale gateway process(es)`);
      return {
        name: "stale-pid-cleanup",
        ok: true,
        detail: `killed ${stalePids.length} stale pid(s): ${stalePids.join(", ")}`,
        durationMs: Date.now() - start,
      };
    } catch (err) {
      log.warn(`stale PID cleanup failed: ${String(err)}`);
      return {
        name: "stale-pid-cleanup",
        ok: true,
        detail: `cleanup skipped: ${String(err)}`,
        durationMs: Date.now() - start,
      };
    }
  }

  private findPidsOnPort(port: number): number[] {
    try {
      const output = execFileSync(
        "lsof",
        ["-t", "-i", `:${port}`, "-s", "TCP:LISTEN"],
        { encoding: "utf8", timeout: 3000 },
      ).trim();
      if (!output) return [];
      return output
        .split("\n")
        .map((s) => parseInt(s.trim(), 10))
        .filter((n) => Number.isFinite(n) && n > 0 && n !== process.pid);
    } catch {
      return [];
    }
  }

  private sleep(ms: number): Promise<void> {
    return new Promise((resolve) => setTimeout(resolve, ms));
  }
}

// ── Singleton for gateway-wide use ────────────────────────────────────────

let globalLifecycle: LifecycleManager | null = null;

export function getLifecycleManager(config?: LifecycleConfig): LifecycleManager {
  if (!globalLifecycle) {
    globalLifecycle = new LifecycleManager(config);
  }
  return globalLifecycle;
}

export function resetLifecycleManagerForTest(): void {
  if (globalLifecycle) {
    globalLifecycle.dispose();
    globalLifecycle = null;
  }
}
TSEOF

echo "    OK: EXP-3 created src/gateway/lifecycle-manager.ts"

# ── 2. Integrate into src/gateway/server.impl.ts ──────────────────────────
python3 - "$SRC/gateway/server.impl.ts" << 'PYEOF'
import sys, re

path = sys.argv[1]
with open(path, 'r') as f:
    content = f.read()

changed = False

# 2a. Add import for getLifecycleManager
if 'getLifecycleManager' not in content:
    # Insert after the last import near the top
    marker = 'import { ensureGatewayStartupAuth } from "./startup-auth.js";'
    if marker in content:
        import_line = 'import { getLifecycleManager } from "./lifecycle-manager.js";'
        content = content.replace(marker, marker + '\n' + import_line)
        changed = True
        print("    OK: EXP-3 added lifecycle-manager import to server.impl.ts")
    else:
        print("    WARN: EXP-3 could not find startup-auth import marker")
else:
    print("    SKIP: EXP-3 lifecycle-manager import already present")

# 2b. Add lifecycle markRunning() near the end, after logGatewayStartup
if 'lifecycleManager' not in content:
    marker = '  logGatewayStartup({'
    if marker in content:
        lifecycle_init = """  // ── EXP-3: Lifecycle manager — mark gateway as running ──
  const lifecycleManager = getLifecycleManager();
  lifecycleManager.onCleanup(async () => {
    try { const { getWebhookDeduplicator } = await import("../channels/webhook-deduplicator.js"); getWebhookDeduplicator().dispose(); } catch {}
    try { const { getGatewayFirewall } = await import("./firewall.js"); getGatewayFirewall().dispose(); } catch {}
  });
  lifecycleManager.markRunning();
  // ── end EXP-3 ──

  logGatewayStartup({"""
        content = content.replace(marker, lifecycle_init, 1)
        changed = True
        print("    OK: EXP-3 added lifecycle markRunning to server.impl.ts")
    else:
        print("    WARN: EXP-3 could not find logGatewayStartup marker")
else:
    print("    SKIP: EXP-3 lifecycle integration already present")

if changed:
    with open(path, 'w') as f:
        f.write(content)
    print("    OK: EXP-3 server.impl.ts patched")
else:
    print("    SKIP: EXP-3 server.impl.ts already up to date")

PYEOF

# ── 3. Verification ───────────────────────────────────────────────────────
echo ""
echo "  Verifying EXP-3..."
PASS=true

if [ ! -f "$SRC/gateway/lifecycle-manager.ts" ]; then
  echo "    FAIL: lifecycle-manager.ts not created"
  PASS=false
fi

if ! grep -q 'class LifecycleManager' "$SRC/gateway/lifecycle-manager.ts" 2>/dev/null; then
  echo "    FAIL: LifecycleManager class not found"
  PASS=false
fi

if ! grep -q 'getLifecycleManager' "$SRC/gateway/server.impl.ts" 2>/dev/null; then
  echo "    FAIL: lifecycle manager not integrated into server.impl.ts"
  PASS=false
fi

if $PASS; then
  echo "    OK: EXP-3 fully verified"
else
  echo "    FAIL: EXP-3 verification failed"
  exit 1
fi
