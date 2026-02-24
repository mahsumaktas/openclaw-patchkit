# Minimal Cognitive Memory (MCM) — Research Report

**Date:** 2026-02-24  
**Source:** Deep analysis of MSAM + ACT-R theory + competitive landscape  
**Goal:** Extract MSAM's core innovations into a minimal, buildable system (<1000 LOC)

---

## Executive Summary

**MSAM** (Multi-Stream Adaptive Memory) is a 24-module, 264-test cognitive memory system for AI agents. It's impressive engineering but massively over-scoped for most use cases. After deep analysis, here's the verdict:

### Worth Keeping (Core Innovations)
1. **ACT-R activation scoring** — frequency × recency decay instead of pure vector similarity
2. **Confidence-gated retrieval** — return nothing when uncertain (saves tokens)
3. **Intentional forgetting with lifecycle** — active → fading → dormant → tombstone
4. **Compressed context startup** — entity codebook + semantic dedup for session init

### Discard (Commodity / Over-engineered)
- Knowledge graph with triple extraction (requires LLM calls, marginal value)
- Multi-stream separation (semantic/episodic/procedural/working — 2 streams max suffice)
- Predictive prefetch (3-strategy prediction engine — premature optimization)
- Multi-agent protocol (namespace isolation — add later if needed)
- REST API with 20 endpoints (overkill for embedded use)
- Cross-provider calibration (nice but not core)
- Beam search retrieval (only useful at 10K+ atoms)
- Emotional context scoring (arousal, valence — gimmick)

**Bottom line:** 4 ideas from MSAM are genuinely valuable. The other 20 modules are standard RAG, premature scaling, or academic decoration. We can capture ~80% of MSAM's value in ~500 LOC.

---

## 1. Scientific Foundations

### 1.1 ACT-R Base-Level Learning

ACT-R (Adaptive Control of Thought—Rational) is a cognitive architecture from Carnegie Mellon. Its declarative memory module uses **base-level activation** to model human memory:

```
B_i = ln(Σ t_j^(-d))
```

Where:
- `B_i` = base-level activation of memory chunk i
- `t_j` = time since the j-th access of chunk i (in seconds or arbitrary time units)
- `d` = decay parameter (default 0.5)
- Sum is over all n presentations/accesses

**What this means:** Memories that are accessed frequently AND recently have high activation. Old, rarely-accessed memories decay. This naturally captures both the **power law of practice** and the **power law of forgetting**.

**Key insight:** The ln() wrapper means activation grows logarithmically with practice — diminishing returns on repetition, which prevents any single memory from dominating.

**Simplified approximation (Petrov 2006):**
For computational efficiency with many accesses:
```
B_i ≈ ln(n) - d × ln(L)
```
Where n = number of accesses, L = lifetime (time since creation). This is O(1) instead of O(n) — critical for production use.

**Comparison with alternatives:**

| Model | Equation | Pros | Cons |
|-------|----------|------|------|
| ACT-R BLL | `ln(Σ t_j^(-d))` | Captures frequency+recency, well-validated | O(n) per chunk, needs access log |
| Petrov approx | `ln(n) - d×ln(L)` | O(1), good approximation | Loses temporal distribution info |
| Ebbinghaus | `R = e^(-t/S)` | Simple, one parameter | No frequency component |
| SM-2 (Anki) | Interval × EF | Optimized for learning | Designed for flashcards, not retrieval |

**Recommendation:** Use **Petrov approximation** for base activation + **Ebbinghaus decay** for retrievability. Best of both worlds: O(1) computation, captures frequency+recency+forgetting.

### 1.2 Retrievability and Forgetting

MSAM uses exponential decay for retrievability:
```
R(t) = e^(-t/S)
```
Where S = stability (increases with each successful retrieval).

This is essentially the **Ebbinghaus forgetting curve**, which is one of the most replicated findings in psychology. The stability parameter S models the **spacing effect** — each retrieval makes the memory more durable.

**For MCM, the combined activation score:**
```
score = activation_weight × B_i + similarity_weight × cosine_sim(query, memory)
```
Where `B_i` comes from ACT-R and `cosine_sim` from embeddings. This is the key innovation: **vector similarity alone is insufficient**. A highly similar but ancient memory should rank below a moderately similar recent one.

### 1.3 Compression Theory

MSAM's 99.3% compression (7327→51 tokens) uses 4 techniques:

1. **Subatom extraction** — Break atoms into sentences, select most relevant
2. **Codebook compression** — Entity shortcodes (Agent→A, User→U)
3. **Delta encoding** — Only emit changes from previous context
4. **Semantic dedup** — Remove sentences with >0.75 cosine similarity

**What actually matters:**
- Semantic dedup: **HIGH value** — most memory systems store redundant info
- Entity codebook: **MEDIUM value** — simple, effective, easy to implement
- Subatom extraction: **LOW-MEDIUM** — useful but adds complexity
- Delta encoding: **LOW** — only matters for repeated context loads in same session

**Minimum viable compression:** Semantic dedup + entity codebook = ~90% of compression value with ~20% of implementation effort.

**Comparison:**
- **OpenClaw compaction:** LLM-based summarization of conversation history. Loses granularity but works. No scoring/decay.
- **MemGPT/Letta:** Tiered memory (core/recall/archival). LLM self-edits core memory. High token cost for memory management.
- **Zep:** Session-based extraction with entity/fact graphs. Good but requires their cloud service.
- **Mem0:** Vector store + LLM extraction. Simple but no decay/forgetting.

---

## 2. Competitive Landscape

| Feature | MSAM | MemGPT/Letta | Zep | Mem0 | OpenClaw | **MCM (proposed)** |
|---------|------|-------------|-----|------|----------|-------------------|
| Activation scoring | ACT-R full | None | None | None | None | ACT-R simplified |
| Confidence gating | 4-tier | None | None | None | None | 2-tier (yes/no) |
| Forgetting | 4-signal lifecycle | LLM-managed | TTL-based | None | None | Decay + threshold |
| Compression | 4-stage pipeline | LLM summary | LLM extract | None | LLM compaction | Dedup + codebook |
| Embeddings | Multi-provider | OpenAI | Proprietary | Multi | None (keyword) | Any provider |
| Storage | SQLite | Postgres | Cloud | Multi | JSON files | SQLite |
| Knowledge graph | Yes (triples) | No | Yes (entities) | No | No | No |
| Multi-agent | Yes | Yes | Yes | Yes | No | No |
| LOC | ~5000+ | ~10000+ | Cloud SaaS | ~3000 | ~500 | **<800** |
| Dependencies | Python, embedding API | Python, Postgres, LLM | Cloud only | Python, LLM | Node.js | Python/TS, SQLite |

**Key insight:** No existing system combines activation-based scoring with confidence gating and forgetting in a minimal package. This is MCM's niche.

---

## 3. MCM Design Specification

### 3.1 Architecture

```
┌─────────────────────────────────────────────┐
│                   MCM API                    │
│         store() / recall() / decay()         │
├─────────────┬───────────────┬───────────────┤
│  Activation │  Confidence   │  Forgetting   │
│   Scorer    │    Gate       │   Engine      │
│             │               │               │
│ B = ln(n) - │ if score <    │ R = e^(-t/S)  │
│   d×ln(L)   │  threshold:   │ if R < 0.1:   │
│ + sim×w     │  return ∅     │  mark dormant │
├─────────────┴───────────────┴───────────────┤
│              SQLite + FTS5                   │
│    memories | access_log | embeddings        │
└─────────────────────────────────────────────┘
```

### 3.2 Data Model (SQLite Schema)

```sql
-- Core memory storage
CREATE TABLE memories (
    id          TEXT PRIMARY KEY,  -- uuid
    content     TEXT NOT NULL,
    category    TEXT DEFAULT 'fact',  -- fact | episode | procedure
    embedding   BLOB,             -- float32 array, serialized
    
    -- Activation tracking
    access_count    INTEGER DEFAULT 1,
    created_at      REAL NOT NULL,    -- unix timestamp
    last_accessed   REAL NOT NULL,
    
    -- Forgetting
    stability       REAL DEFAULT 1.0,  -- S in R=e^(-t/S), grows with retrievals
    state           TEXT DEFAULT 'active',  -- active | fading | dormant | tombstone
    
    -- Metadata
    importance      REAL DEFAULT 0.5,  -- 0-1, user-set or auto
    tokens          INTEGER,           -- estimated token count
    superseded_by   TEXT,              -- id of newer contradicting memory
    
    created_date    TEXT GENERATED ALWAYS AS (datetime(created_at, 'unixepoch'))
);

-- Full-text search for keyword matching
CREATE VIRTUAL TABLE memories_fts USING fts5(content, content=memories, content_rowid=rowid);

-- Compact access log for activation calculation
CREATE TABLE access_log (
    memory_id   TEXT NOT NULL REFERENCES memories(id),
    accessed_at REAL NOT NULL,
    source      TEXT DEFAULT 'query'  -- query | explicit | startup
);
CREATE INDEX idx_access_memory ON access_log(memory_id);

-- Dedup tracking for compression
CREATE TABLE entity_codebook (
    entity      TEXT PRIMARY KEY,
    code        TEXT NOT NULL,       -- shortcode
    frequency   INTEGER DEFAULT 1
);

-- Session state (optional, for delta encoding)
CREATE TABLE session (
    key         TEXT PRIMARY KEY,
    value       TEXT,
    updated_at  REAL
);
```

### 3.3 Core Algorithms

#### Store
```python
def store(content: str, category: str = "fact", importance: float = 0.5):
    # 1. Check for semantic duplicates
    embedding = embed(content)
    similar = find_similar(embedding, threshold=0.85)
    if similar:
        # Merge: update existing memory, boost access count
        update_memory(similar.id, content, access_count + 1)
        return similar.id
    
    # 2. Store new memory
    id = uuid4()
    tokens = estimate_tokens(content)
    now = time.time()
    insert_memory(id, content, category, embedding, importance, tokens, now)
    log_access(id, now, "store")
    return id
```

#### Recall (with activation scoring + confidence gating)
```python
def recall(query: str, top_k: int = 5, threshold: float = 0.3):
    query_emb = embed(query)
    now = time.time()
    
    candidates = get_active_memories()  # state != 'tombstone'
    scored = []
    
    for mem in candidates:
        # ACT-R activation (Petrov approximation)
        n = mem.access_count
        L = max(now - mem.created_at, 1.0)
        B = math.log(n) - 0.5 * math.log(L)
        
        # Vector similarity
        sim = cosine_similarity(query_emb, mem.embedding)
        
        # Combined score (normalized)
        score = 0.4 * sigmoid(B) + 0.5 * sim + 0.1 * mem.importance
        
        scored.append((mem, score, sim))
    
    # Sort by score
    scored.sort(key=lambda x: x[1], reverse=True)
    top = scored[:top_k]
    
    # Confidence gate: if best score < threshold, return nothing
    if not top or top[0][1] < threshold:
        return []  # "I don't know" — saves tokens
    
    # Log accesses for retrieved memories
    for mem, score, sim in top:
        log_access(mem.id, now, "query")
        update_stability(mem.id)  # S *= 1.1 on each retrieval
    
    return [(mem, score) for mem, score, sim in top]
```

#### Decay (run periodically — e.g., daily or on startup)
```python
def decay():
    now = time.time()
    
    for mem in get_all_active_memories():
        t = now - mem.last_accessed
        S = mem.stability
        R = math.exp(-t / (S * 86400))  # S in days
        
        if R < 0.1 and mem.state == 'fading':
            set_state(mem.id, 'dormant')
        elif R < 0.3 and mem.state == 'active':
            set_state(mem.id, 'fading')
        
        # Reactivation happens automatically via recall()
    
    # Semantic dedup: find near-duplicates among active memories
    active = get_active_memories()
    for i, a in enumerate(active):
        for b in active[i+1:]:
            sim = cosine_similarity(a.embedding, b.embedding)
            if sim > 0.9:
                # Keep the one with higher activation
                loser = b if activation(a) > activation(b) else a
                set_state(loser.id, 'dormant')
```

#### Compressed Context (for session startup)
```python
def get_context(token_budget: int = 200):
    # Get top memories by activation (not query-specific)
    now = time.time()
    all_mems = get_active_memories()
    
    scored = []
    for mem in all_mems:
        n = mem.access_count
        L = max(now - mem.created_at, 1.0)
        B = math.log(n) - 0.5 * math.log(L)
        score = sigmoid(B) * (0.7 + 0.3 * mem.importance)
        scored.append((mem, score))
    
    scored.sort(key=lambda x: x[1], reverse=True)
    
    # Greedily add until budget exhausted, with entity codebook
    codebook = get_entity_codebook()
    context_parts = []
    used_tokens = 0
    
    for mem, score in scored:
        compressed = apply_codebook(mem.content, codebook)
        tokens = estimate_tokens(compressed)
        if used_tokens + tokens > token_budget:
            break
        context_parts.append(compressed)
        used_tokens += tokens
    
    return "\n".join(context_parts)
```

### 3.4 File Structure

```
mcm/
├── __init__.py          # Public API: store, recall, decay, context (~50 LOC)
├── memory.py            # Core Memory class, store/recall/decay (~250 LOC)  
├── activation.py        # ACT-R scoring, confidence gating (~100 LOC)
├── forgetting.py        # Decay engine, state transitions, dedup (~120 LOC)
├── schema.sql           # SQLite schema (~40 lines)
└── compression.py       # Entity codebook, context builder (~80 LOC)
                         # Total: ~600 LOC
```

### 3.5 Estimated Token Savings

| Scenario | Flat Files | Basic Vector Store | MCM |
|----------|-----------|-------------------|-----|
| Startup context (100 memories) | ~5000t (all loaded) | ~2000t (top-k) | ~100-200t (scored + compressed) |
| Query with answer | ~5000t | ~500t (top-5 chunks) | ~200-400t (gated, relevant only) |
| Query without answer | ~5000t | ~500t (irrelevant chunks) | **0t** (confidence gate) |
| 10-query session | ~50,000t | ~7,000t | ~1,500-3,000t |

**Key win:** The confidence gate returning 0 tokens for unknown queries is the single biggest token saver. Most agent sessions have many queries where memory has nothing useful — flat files and basic vector stores waste tokens on these.

---

## 4. Implementation Roadmap

### Phase 1: Core (2-3 days, ~400 LOC)
- SQLite schema + basic CRUD
- Embedding integration (any provider via simple interface)
- ACT-R activation scoring (Petrov approximation)
- Basic recall with combined score (activation + similarity)
- **Deliverable:** Working store/recall with activation-aware ranking

### Phase 2: Intelligence (1-2 days, ~200 LOC)  
- Confidence gating (threshold-based, return empty when uncertain)
- Decay engine (exponential retrievability, state transitions)
- Semantic dedup on store (prevent redundant memories)
- **Deliverable:** Self-regulating memory that forgets and gates

### Phase 3: Compression (1 day, ~100 LOC)
- Entity codebook (auto-extract frequent entities)
- Compressed context generation for session startup
- **Deliverable:** Minimal-token session initialization

### Phase 4: Integration (1 day)
- CLI interface or Python API wrapper
- TypeScript port feasibility check (for OpenClaw)
- Documentation and examples

**Total estimated effort: 5-7 days for a complete, production-ready system.**

---

## 5. OpenClaw PR Strategy

### Pain Points MCM Would Solve

1. **Memory bloat:** OpenClaw's `memory_store` accumulates memories with no decay. Over time, recall returns increasingly irrelevant results. MCM's forgetting engine directly addresses this.

2. **No relevance scoring beyond keyword/embedding:** OpenClaw uses basic similarity matching. ACT-R activation would rank frequently-used, recent memories higher — matching how humans actually remember.

3. **Wasted tokens on uncertain recalls:** When memory has nothing relevant, OpenClaw still returns results (closest matches, even if poor). Confidence gating would return nothing, saving tokens.

4. **No compression for context:** Session startups load raw memory text. Even basic entity codebook + dedup would reduce token usage significantly.

### Proposed PR: "Cognitive Memory Scoring for memory_recall"

**Title:** `feat(memory): Add activation-based scoring and confidence gating`

**Description:**
```
Adds cognitive science-inspired improvements to memory_recall:

1. **Activation scoring**: Memories are ranked by ACT-R base-level 
   activation (frequency × recency decay) combined with embedding 
   similarity. Frequently accessed, recent memories rank higher.

2. **Confidence gating**: When no memory exceeds a confidence threshold,
   return empty results instead of low-quality matches. Saves tokens
   and prevents hallucination-inducing context.

3. **Automatic decay**: Memories that haven't been accessed transition
   through active → fading → dormant states. Dormant memories are
   excluded from recall unless explicitly searched.

Based on ACT-R cognitive architecture (Anderson & Lebiere, 1998)
and the Petrov (2006) efficient approximation.

Estimated token savings: 40-89% per session depending on query mix.
```

**Implementation approach for OpenClaw:**
- Add `access_count`, `last_accessed`, `stability`, `state` fields to memory records
- Modify recall scoring: `combined = 0.4 * activation + 0.5 * similarity + 0.1 * importance`
- Add confidence threshold parameter (default 0.3, configurable)
- Add periodic decay (on startup or every N recalls)
- Backward compatible: existing memories get default activation values

### Viability Assessment
- **High viability** for activation scoring + confidence gating (small, self-contained changes)
- **Medium viability** for forgetting/decay (needs discussion on UX — users may not want memories to "disappear")
- **Low viability** for compression (OpenClaw's architecture may not support custom context building)

**Recommendation:** Start with a standalone MCM Python package. Prove value. Then propose specific features for OpenClaw integration.

---

## 6. Key Takeaways

1. **ACT-R activation is the real innovation.** Vector similarity alone is insufficient for agent memory. The combination of frequency, recency, and similarity is well-validated cognitive science.

2. **Confidence gating is the biggest token saver.** Returning nothing for uncertain queries is counterintuitive but hugely valuable. Most systems pad with noise.

3. **Forgetting is necessary at scale.** Without decay, memory systems degrade over time as old, irrelevant memories pollute results.

4. **MSAM is 80% over-engineering.** Knowledge graphs, multi-stream, predictive prefetch, multi-agent, REST API — all add complexity without proportional value for single-agent use cases.

5. **Build MCM as a standalone package first.** Prove it works, benchmark against flat files and basic vector stores, then propose integration.

---

## References

- Anderson, J. R., & Lebiere, C. (1998). *The Atomic Components of Thought.* Lawrence Erlbaum.
- Petrov, A. (2006). Computationally efficient approximation of the base-level learning equation in ACT-R. *ICCM 2006.*
- Morrison, D. PyACTUp — Python ACT-R implementation. Carnegie Mellon University.
- MSAM: https://github.com/jadenschwab/msam
- Ebbinghaus, H. (1885). *Über das Gedächtnis.*
- MemGPT/Letta: https://github.com/letta-ai/letta
- Zep: https://www.getzep.com/
- Mem0: https://github.com/mem0ai/mem0
