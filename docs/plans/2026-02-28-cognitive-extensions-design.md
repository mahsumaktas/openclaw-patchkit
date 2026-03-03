# Cognitive Extensions v2 — Design Document

**Tarih:** 2026-02-28
**Durum:** Arastirma tamamlandi, onay bekliyor

---

## Problem

Oracle agent'in 21:53'te deploy ettigi 2 extension (attention-context, cognitive-memory) gateway'i crash ettirdi. Root cause: OpenClaw plugin API format hatalari (`inputSchema` vs `parameters`, eksik `label`, yanlis `execute` signature).

Plugin KODU iyi yazilmis — sorun sadece OpenClaw API entegrasyonu. Ama bunun otesinde, cognitive-memory plugin'inin asil degeri memory-lancedb'ye ENTEGRE etmekte.

---

## Arastirma Ozeti

### Analiz Edilen Kaynaklar
- 8 repo (vestige, claude-cognitive, agentic-memory, compcogneuro, DeerFlow, ComoRAG, mem0, MemoryMesh)
- GitHub taramasi: ScallopBot, fsrs.js, openclaw-engram, AI-Memory, mcp-neuralmemory, PowerMem
- Mevcut calisan extension: memory-lancedb (1602 satir, v4 Cognitive Memory)

### Deger Matrisi

| Ozellik | Kaynak | Deger | Effor | Oncelik |
|---------|--------|-------|-------|---------|
| Plugin API fix | — | Kritik | 1 saat | P0 |
| FSRS-6 → memory-lancedb | vestige | Yuksek | 2-3 saat | P1 |
| Importance scoring → capture | vestige | Yuksek | 2 saat | P1 |
| PE gating → dedup pipeline | vestige | Yuksek | 2 saat | P1 |
| BCM floating threshold | compcogneuro | Yuksek | 1 saat | P1 |
| Pattern separation | compcogneuro | Orta | 2 saat | P2 |
| Impasse detection | ComoRAG | Orta | 2 saat | P2 |
| Attention context (fix+enable) | claude-cognitive | Orta | 1 saat | P2 |
| Dream cycle (consolidation) | ScallopBot | Dusuk | 4 saat | P3 |
| CLS fast/slow | compcogneuro | Dusuk | 3 saat | P3 |

---

## Mimari Karar

### Karar 1: cognitive-memory plugin'i memory-lancedb'ye ENTEGRE et

**Neden bagimsiz plugin DEGIL:**
- cognitive-memory'nin FSRS-6, importance scoring ve PE gating'i memory-lancedb OLMADAN anlamsiz
- Bagimsiz plugin olarak sadece CLI + 2 tool sunuyor (score hesapla, decay hesapla) — ama bu skorlari KULLANMIYOR
- Asil deger: capture/prune/dedup kararlarinda BU algoritmalari kullanmak
- memory-lancedb zaten v4'te statik pruning (30 gun), heuristic capture, SHA256 dedup kullaniyor
- Bunlari FSRS-6 decay, 4-channel importance, PE gating ile UPGRADE etmek gercek degeri yaratir

**Plan:** cognitive-memory/src/ modullerini memory-lancedb icine tasi, plugin'i sil.

### Karar 2: attention-context BAGIMSIZ kalsin

**Neden:**
- HOT/WARM/COLD context yonetimi memory'den bagimsiz bir sorun
- Pool coordinator (agent-arasi iletisim) memory ile ilgisiz
- Bagimsiz calisabilir, sadece API fix yeterli

### Karar 3: Fazlar halinde ilerle

Stability-first felsefesi: her faz sonrasi gateway test et, bozulma varsa geri al.

---

## Faz 0: Plugin API Fix (P0 — 1 saat)

### attention-context
1. `inputSchema` → `parameters: Type.Object({...})`
2. `label` field ekle
3. `execute: async (input)` → `async execute(_toolCallId, params)`
4. `@sinclair/typebox` import ekle
5. `kind: "context"` → manifest'te de duzelt (OpenClaw context plugin'leri tool register edebilir mi kontrol et, degilse `"tools"` yap)

### cognitive-memory
1. Ayni 3 fix
2. Ama ENTEGRE edilecegi icin sadece CLI kismi kalsin (tool'lar silinecek, yerine memory-lancedb'ye entegre)

### Test
- Gateway restart
- Her agent'ta 1 mesaj gonder
- 0 crash = gecti

---

## Faz 1: Memory-LanceDB v5 Upgrade (P1 — 8 saat)

### 1a. FSRS-6 Decay (vestige'den, zaten port edilmis)

**Mevcut (v4):** Statik 30-gun dormant kurali. `state: active → fading → dormant → pruned`

**Yeni (v5):** FSRS-6 power-law decay.
```
R = (1 + t / (9 * S * sentimentBoost))^(-2)
```

Degisiklikler:
- `MemoryEntry` type'ina `fsrsStability`, `fsrsReviewCount`, `sentimentMagnitude` ekle
- Prune karar mekanizmasi: `computeRetrieval(daysSinceAccess, stability, boost) < 0.15` → prune
- Recall yapildiginda `onSuccessfulRecall()` cagir → stability artar
- Kaynak: `cognitive-memory.disabled/src/fsrs.ts` (134 satir, test edilmis)

### 1b. BCM Floating Threshold (compcogneuro'dan)

**Mevcut:** Sabit 30-gun dormant esik, tum kategoriler icin ayni.

**Yeni:** Dinamik esik, access frequency'ye gore ayarlanir.
```typescript
// BCM: theta = avg(accessCount) across all memories
// if accessCount < theta * 0.5 → accelerated decay
// if accessCount > theta * 1.5 → protected
function computeBcmThreshold(memories: MemoryEntry[]): number {
  const avg = memories.reduce((s, m) => s + m.accessCount, 0) / memories.length;
  return avg;
}
```

Kategori bazli minimum stability:
- correction: 90 gun
- preference: 60 gun
- decision: 45 gun
- entity: 30 gun
- fact: 14 gun
- other: 7 gun

### 1c. 4-Channel Importance Scoring (vestige'den, zaten port edilmis)

**Mevcut (v4):** Heuristic capture scoring (`captureScore >= 0.5` direct, `0.2-0.5` LLM verify).

**Yeni (v5):** 4-channel neuromodulator model.
```
composite = novelty * 0.25 + arousal * 0.30 + reward * 0.25 + attention * 0.20
```

Degisiklikler:
- `autoCapture` pipeline'inda `computeImportance(text, memoryId, category)` cagir
- `captureScore` yerine `importance.composite` kullan
- `importance.encodingBoost` → `fsrsStability` baslangic degerini etkile
- Kaynak: `cognitive-memory.disabled/src/importance.ts` (270 satir)

### 1d. Prediction Error Gating (vestige'den, zaten port edilmis)

**Mevcut (v4):** SHA256 exact dedup + vector similarity 0.85 threshold merge.

**Yeni (v5):** PE gating ile akilli karar.
```
similarity < 0.70  → CREATE (yeni memory)
0.70-0.75         → CREATE (ama pattern separation flag'le)
0.75-0.92         → UPDATE (mevcut memory'yi guncelle)
0.92+             → REINFORCE (access count artir, stability artir)
contradiction     → SUPERSEDE (eski memory'yi demote et)
```

Degisiklikler:
- `memory_store` icinde `evaluateGate(newText, candidates)` cagir
- `reinforce` → sadece accessCount++ ve onSuccessfulRecall()
- `supersede` → eski memory'ye `supersededBy: newId` ekle, state → fading
- Kaynak: `cognitive-memory.disabled/src/prediction-gate.ts` (176 satir)

### Test Plani
- Mevcut memory'ler korunmali (migration gerekli — yeni field'lar default degerle)
- `ltm store "test memory"` → importance score loglanmali
- `ltm store "test memory"` (tekrar) → reinforce karari
- `ltm store "actually test memory is wrong"` → supersede karari
- `ltm prune --dry-run` → FSRS-6 skorlari gorulmeli

---

## Faz 2: Attention Context + Pattern Separation (P2 — 5 saat)

### 2a. attention-context API Fix ve Enable

- Faz 0'daki fix'leri uygula
- Gateway test et
- 5 tool + CLI calisiyor = gecti

### 2b. Pattern Separation (compcogneuro'dan, memory-lancedb icine)

**Sorun:** 0.70-0.84 benzerlik zonunda iki memory benzer AMA farkli olabilir.

**Cozum:**
```typescript
function detectPatternSeparation(a: string, b: string, similarity: number): boolean {
  if (similarity < 0.70 || similarity > 0.84) return false;
  // Entity extraction: are the subjects different?
  const entitiesA = extractEntities(a);
  const entitiesB = extractEntities(b);
  const entityOverlap = jaccard(entitiesA, entitiesB);
  // High text similarity but low entity overlap = different memories about similar topics
  return entityOverlap < 0.5;
}
```

Bu fonksiyon `evaluateGate()` icine eklenir — pattern separation tespit edilirse CREATE (UPDATE degil).

### 2c. ComoRAG Impasse Detection (oracle-research.sh icine)

**Ne:** LLM cevabinda yetersiz bilgi tespit edildiginde otomatik probe generation.

**Nerede:** `oracle-research.sh` icine `--impasse-detect` flag'i ekle.

```bash
# LLM cevabinda yetersiz bilgi tespit et
if echo "$RESPONSE" | grep -qE 'bilmiyorum|not enough|insufficient'; then
  # Non-overlapping probe queries uret
  PROBES=$(generate_probes "$QUERY" "$RESPONSE")
  for probe in $PROBES; do
    search_and_append "$probe"
  done
fi
```

---

## Faz 3: Gelismis Ozellikler (P3 — Opsiyonel)

### 3a. Dream Cycle / Gece Consolidation (ScallopBot'tan)

Gece idle'da (03:00 cron):
1. Tum memory'lere FSRS decay uygula
2. Endangered memory'leri listele
3. Benzer memory cluster'larini bul, merge et
4. Contradicting memory ciftlerini bul, eski olani supersede et

### 3b. CLS Fast/Slow Consolidation (compcogneuro'dan)

- Fast path: ilk capture → STM (yuksek retrieval, dusuk storage)
- Slow path: 24 saat sonra hala relevant → LTM'e promote et (storage artir)
- Haftalik consolidation script: weak memory'leri review icin flag'le

---

## Dosya Yapisi (hedef)

```
~/.openclaw/extensions/
  memory-lancedb/           # v5: FSRS-6 + importance + PE gating entegre
    index.ts                # Ana plugin (mevcut + yeni entegrasyonlar)
    config.ts               # Mevcut config
    src/
      fsrs.ts              # cognitive-memory'den tasinacak
      importance.ts        # cognitive-memory'den tasinacak
      prediction-gate.ts   # cognitive-memory'den tasinacak
      types.ts             # cognitive-memory'den tasinacak
  attention-context/        # v2: API fix'lenmis, bagimsiz
    index.ts               # Fix'lenmis plugin
    openclaw.plugin.json   # Manifest
```

cognitive-memory plugin'i SILINECEK (kodu memory-lancedb'ye tasindi).

---

## Riskler

| Risk | Etki | Onlem |
|------|------|-------|
| memory-lancedb v5 mevcut memory'leri bozar | Yuksek | Migration: yeni field'lara default deger, rollback .bak |
| FSRS-6 cok agresif prune eder | Orta | Ilk 2 hafta dry-run mode, prune etme sadece logla |
| attention-context memory kullanimi arttirir | Dusuk | max 4 HOT + 8 WARM limiti zaten var |
| Plugin fix sonrasi baska crash | Orta | Faz 0 sonrasi 24 saat izle |

---

## Basari Kriterleri

1. **Faz 0:** 0 crash, her agent cevap veriyor, attention_state tool calisiyor
2. **Faz 1:** Memory capture'da importance score loglanıyor, prune kararlari FSRS-6'ya gore, duplicate memory'ler PE gating ile yakalaniyor
3. **Faz 2:** attention-context calisiyor, pattern separation benzer-ama-farkli memory'leri ayiriyor
4. **Faz 3:** Gece consolidation raporu Discord'a gidiyor
