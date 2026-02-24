# Cognitive Memory PRs for OpenClaw — Detailed Specs

**Date:** 2026-02-24
**Target:** `extensions/memory-lancedb/index.ts` + `config.ts`
**Base:** OpenClaw v2026.2.22 (670 LOC index.ts, 161 LOC config.ts)

---

## PR 1: Activation-Based Memory Scoring

### Problem
`memory_recall` uses pure vector similarity (L2 distance → inverse score). A memory accessed 500 times yesterday ranks the same as one accessed once 6 months ago, as long as vector similarity is equal. This doesn't match how useful memories actually are.

### Solution
Add ACT-R base-level activation scoring to `memory_recall`. Combine vector similarity with frequency × recency to rank results.

### Changes Required

#### 1. MemoryEntry type — add fields
```typescript
type MemoryEntry = {
  // ... existing fields ...
  accessCount: number;      // NEW: times this memory was recalled
  lastAccessed: number;     // NEW: timestamp of last recall
};
```

#### 2. MemoryDB.store() — initialize new fields
```typescript
const fullEntry: MemoryEntry = {
  ...entry,
  id: randomUUID(),
  createdAt: Date.now(),
  accessCount: 1,           // NEW
  lastAccessed: Date.now(), // NEW
};
```

#### 3. MemoryDB.search() — combined scoring
```typescript
async search(vector: number[], limit = 5, minScore = 0.5): Promise<MemorySearchResult[]> {
  // ... existing vectorSearch ...
  
  const now = Date.now();
  const mapped = results.map((row) => {
    const distance = row._distance ?? 0;
    const similarity = 1 / (1 + distance);
    
    // ACT-R activation (Petrov approximation)
    const n = (row.accessCount as number) ?? 1;
    const L = Math.max(now - (row.createdAt as number), 1000) / 1000; // seconds
    const B = Math.log(n) - 0.5 * Math.log(L);
    const activation = 1 / (1 + Math.exp(-B)); // sigmoid normalize to 0-1
    
    // Combined score
    const importance = (row.importance as number) ?? 0.5;
    const score = 0.5 * similarity + 0.35 * activation + 0.15 * importance;
    
    return { entry: { ... }, score };
  });
  // ... rest same ...
}
```

#### 4. memory_recall tool — update accessCount on retrieval
After successful recall, update the retrieved memories:
```typescript
// After filtering results, update access tracking
for (const r of results) {
  await this.table!.update({
    where: `id = '${r.entry.id}'`,
    values: { 
      accessCount: r.entry.accessCount + 1,
      lastAccessed: Date.now()
    }
  });
}
```

#### 5. Schema migration — handle old entries
In `doInitialize()`, old entries without `accessCount`/`lastAccessed` get defaults:
- `accessCount ?? 1`
- `lastAccessed ?? createdAt`
(Already handled by `?? 1` in scoring, but table schema needs the columns)

#### 6. LanceDB table schema update
```typescript
// In createTable, add new fields to schema seed:
{
  id: "__schema__",
  text: "",
  vector: Array.from({ length: this.vectorDim }).fill(0),
  importance: 0,
  category: "other",
  createdAt: 0,
  accessCount: 1,      // NEW
  lastAccessed: 0,     // NEW
}
```

### Config additions
```typescript
// In MemoryConfig
activationWeight?: number;  // default 0.35
similarityWeight?: number;  // default 0.50
importanceWeight?: number;  // default 0.15
```

### Estimated LOC: +60-80
### Breaking changes: None (backward compatible, old entries get defaults)
### Risk: Low

---

## PR 2: Confidence-Gated Retrieval

### Problem
When `memory_recall` has nothing relevant, it still returns the closest matches (often irrelevant). These get injected into context via auto-recall, wasting tokens and potentially confusing the model.

### Solution
Add a confidence gate: if the best result's combined score is below a threshold, return empty results. "I don't know" saves more tokens than "here's something vaguely related."

### Changes Required

#### 1. Config — add confidence threshold
```typescript
// In MemoryConfig
confidenceThreshold?: number;  // default 0.35, below this = return nothing
```

#### 2. memory_recall tool — gate output
```typescript
// After scoring and sorting:
const confidenceThreshold = cfg.confidenceThreshold ?? 0.35;
if (results.length === 0 || results[0].score < confidenceThreshold) {
  return {
    content: [{ type: "text", text: "No relevant memories found." }],
    details: { count: 0, gated: true, bestScore: results[0]?.score ?? 0 },
  };
}
```

#### 3. Auto-recall hook — respect gate
```typescript
// In before_agent_start:
const results = await db.search(vector, 3, cfg.confidenceThreshold ?? 0.35);
// Already filters by minScore, but now minScore = confidenceThreshold
```

#### 4. CLI stats command — show gating stats
```typescript
// Optional: track gate events for tuning
memory.command("stats").action(async () => {
  const count = await db.count();
  console.log(`Total memories: ${count}`);
  // Could add: gated queries count, avg score, etc.
});
```

### Estimated LOC: +20-30
### Breaking changes: None (threshold is configurable, default preserves current behavior if set to 0.1)
### Risk: Very low
### Token savings: Significant — every "I don't know" saves ~200-500 tokens of irrelevant context injection

---

## PR 3: Memory Decay & Forgetting

### Problem
Memories never expire. Over months of use, the database fills with stale, outdated, or superseded information. Old preferences, obsolete facts, and one-time events pollute recall results.

### Solution
Add an Ebbinghaus-based decay system. Memories transition through states: `active → fading → dormant`. Dormant memories are excluded from recall. Each successful retrieval increases stability (makes the memory harder to forget).

### Changes Required

#### 1. MemoryEntry — add state and stability
```typescript
type MemoryEntry = {
  // ... existing + PR1 fields ...
  stability: number;    // NEW: S in R=e^(-t/S), starts at 1.0 (days)
  state: 'active' | 'fading' | 'dormant';  // NEW: lifecycle state
};
```

#### 2. Decay function — run on startup or periodically
```typescript
async decay(): Promise<{ faded: number; dormant: number }> {
  const now = Date.now();
  let faded = 0, dormant = 0;
  
  const memories = await this.getAllActive(); // state != 'dormant'
  
  for (const mem of memories) {
    const daysSinceAccess = (now - mem.lastAccessed) / 86400000;
    const R = Math.exp(-daysSinceAccess / mem.stability);
    
    if (R < 0.1 && mem.state === 'fading') {
      await this.setState(mem.id, 'dormant');
      dormant++;
    } else if (R < 0.3 && mem.state === 'active') {
      await this.setState(mem.id, 'fading');
      faded++;
    }
  }
  
  return { faded, dormant };
}
```

#### 3. Stability boost on retrieval (in PR1's access update)
```typescript
// When a memory is recalled:
stability: mem.stability * 1.2  // each retrieval makes it 20% more durable
```

#### 4. Search — exclude dormant
```typescript
// In search(), filter out dormant memories:
const mapped = results.filter(row => (row.state ?? 'active') !== 'dormant');
```

#### 5. Config
```typescript
decayEnabled?: boolean;     // default true
fadingThreshold?: number;   // default 0.3 (retrievability below this = fading)
dormantThreshold?: number;  // default 0.1 (retrievability below this = dormant)
decayOnStartup?: boolean;   // default true (run decay check on plugin init)
```

#### 6. CLI command
```typescript
memory.command("decay")
  .description("Run memory decay cycle")
  .action(async () => {
    const result = await db.decay();
    console.log(`Decay complete: ${result.faded} fading, ${result.dormant} dormant`);
  });

memory.command("revive")
  .argument("<id>", "Memory ID to reactivate")
  .action(async (id) => {
    await db.setState(id, 'active');
    console.log(`Memory ${id} reactivated.`);
  });
```

### Estimated LOC: +80-100
### Breaking changes: None (decay disabled by default or non-destructive — dormant, not deleted)
### Risk: Medium (users may not expect memories to "disappear")
### Mitigation: Dormant memories are never deleted, can be revived via CLI

---

## PR 4: Semantic Deduplication on Store

### Problem  
`memory_store` checks for duplicates at 0.95 similarity. This misses near-duplicates at 0.85-0.94 that are essentially the same information phrased differently. Over time, memory fills with redundant entries.

### Solution
Lower dedup threshold to 0.85 and add a merge behavior: when a near-duplicate is found, update the existing memory's text (keep newer version), boost access count, and preserve the original ID.

### Changes Required

#### 1. Store — merge instead of reject
```typescript
// In memory_store execute:
const existing = await db.search(vector, 1, 0.85); // was 0.95
if (existing.length > 0) {
  // Merge: update text to newer version, boost access
  await db.update(existing[0].entry.id, {
    text: text,  // keep newer phrasing
    accessCount: existing[0].entry.accessCount + 1,
    lastAccessed: Date.now(),
    importance: Math.max(existing[0].entry.importance, importance),
  });
  return {
    content: [{ type: "text", text: `Updated existing memory: "${text.slice(0, 100)}..."` }],
    details: { action: "merged", id: existing[0].entry.id },
  };
}
```

#### 2. Config
```typescript
deduplicationThreshold?: number;  // default 0.85
```

### Estimated LOC: +25-35
### Breaking changes: None
### Risk: Low (merge preserves data, just consolidates)

---

## Implementation Priority & Treliq Scoring

| PR | Impact | Complexity | Risk | Treliq Score | Priority |
|----|--------|-----------|------|-------------|----------|
| PR 1: Activation Scoring | High | Medium | Low | 8.5/10 | 🥇 First |
| PR 2: Confidence Gating | High | Low | Very Low | 9.0/10 | 🥇 First (can be same PR) |
| PR 3: Memory Decay | Medium-High | Medium | Medium | 7.5/10 | 🥈 Second |
| PR 4: Semantic Dedup | Medium | Low | Low | 7.0/10 | 🥉 Third |

### Recommended Grouping
- **PR A (PR1 + PR2):** "Cognitive memory scoring with confidence gating" — these are tightly coupled (activation scoring makes confidence gating meaningful). ~100 LOC.
- **PR B (PR3):** "Memory decay and lifecycle management" — independent, can land separately. ~90 LOC.  
- **PR C (PR4):** "Improved semantic deduplication with merge" — smallest, most independent. ~30 LOC.

### Total estimated change: ~220 LOC across 3 PRs

---

## Notes for Claude Code Implementation

1. **LanceDB schema evolution:** LanceDB doesn't have formal migrations. New columns on old tables need careful handling — read with `?? defaultValue` patterns.

2. **LanceDB update API:** Check if `table.update()` supports partial updates or if we need `table.delete()` + `table.add()` combo.

3. **Performance:** Activation scoring adds O(n) computation to search results, but n is already limited by `limit` parameter (default 5). No concern.

4. **Testing:** Add tests in `index.test.ts` for:
   - Activation scoring affects ranking
   - Confidence gate returns empty for low scores
   - Decay transitions state correctly
   - Dedup merges instead of rejecting

5. **Config backward compat:** All new config keys must be optional with sensible defaults.
