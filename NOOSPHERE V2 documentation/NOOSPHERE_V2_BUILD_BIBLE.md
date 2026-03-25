# 🧠 NOOSPHERE v2 — BUILD BIBLE
## Canonical Epistemic Specification v1.1

---

**Project:** `noosphere-v2` | **ID:** `bdpvvclndurhuzxzrlma` | **Region:** `us-east-1`
**URL:** `https://bdpvvclndurhuzxzrlma.supabase.co`
**Status:** ACTIVE — Phase 1 Complete — Phase 1.5 In Progress
**Tables:** 18 | **Last Updated:** March 21, 2026

> ⚠️ **If any implementation conflicts with this document, the implementation is wrong.**

---

## 0. SYSTEM IDENTITY

**Definition:** A self-correcting epistemic machine that tracks the reliability of its own decisions about reality over time.

**Optimization Target:** Rate of Corrected Error Over Time. NOT correctness. NOT speed. NOT truth.

**Three-Word Identity:** CORRECT THE CORRECTIONS

**What It Is NOT:** A truth engine, a chatbot, a consensus machine, a pipeline, or a summarizer.

---

## 1. THE 10 SYSTEM LAWS (INVARIANTS)

1. **Confidence Decays Without Outcome.** Exponential decay, domain-adaptive, floor = 0.1.
2. **Confidence Cannot Increase Without New Evidence.**
3. **Outcome-Free Domains Cannot Achieve High Trust.** Partial outcomes provide max ±0.1 relief.
4. **All Decisions Must Be Logged Before Action.** Everything to `jarvis_log`. Append-only.
5. **No Autonomous Promotion in Phase 1.** Graduated autonomy earned through `governance_thresholds`.
6. **Invalidated Claims Have Final Confidence = 0.** No exceptions.
7. **Clustered Failures Trigger Systemic Response.** Adaptive trigger: MAX(3, 0.1 × window_total).
8. **Evidence Is Required for All Claims.**
9. **Historical Records Are Append-Only.** Never delete from claims, jarvis_log, learning_events.
10. **Dependency Invalidations Propagate Forward.** Cascade depth limit = 3.

---

## 2. CORE ONTOLOGY

### 2.1 Claim
A structured assertion: `(subject, relation, object)` with optional **conditions** (load-bearing — dropping them changes truth value). Exists in `claims_pending` and `claims`.

### 2.2 Truth Vector (4 Dimensions — NEVER Merged)
- **Confidence:** [0,1] — probability claim is correct
- **Verifiability:** [0,1] — how testable/falsifiable
- **Consensus:** [0,1] — agreement across sources
- **Temporal Validity:** {valid_from, valid_until, decay_rate}

### 2.3 Outcome States
`unverified` → `partial` → `directional` → `confirmed` OR `invalidated`

### 2.4 Confidence Model
- **Decay:** `effective = initial × e^(-decay_rate × Δt)` (floor 0.1)
- **Confirmation:** `final = MIN(1.0, initial + (1 - initial) × verification_weight)`
- **Invalidation:** `final = 0`

### 2.5 Trust Score
`effective_trust = correct_decisions / (total_decisions × outcome_resolution_rate)`

### 2.6 Failure Cluster
Triggered when: `incorrect_count ≥ MAX(3, ROUND(0.1 × window_total_decisions))`
Response: cluster ID assigned, trust penalty, quarantine, learning event.

---

## 3. ARCHITECTURE

### 3.1 Prime Directive
> **Raw data NEVER enters the permanent ledger directly.**

### 3.2 Two Worlds
- **Noosphere Core:** Protected truth vault. Validation, storage, trust, governance.
- **OpenClaw Layer:** External interaction, agents, data cleaning, normalization.

### 3.3 Three-Stage Commitment
1. **STAGING** (`raw_intel`): Immutable intake. 72h TTL. Dedup via content_hash.
2. **VALIDATION** (`claims_pending`): Extraction + evaluation. Human review flags.
3. **LEDGER** (`claims`): Permanent. Append-only. Never deleted.

### 3.4 Phase 1 Runtime
Single-Agent Vanguard (one Claude call per claim). Debate Swarm earned in Phase 2 via Swarm Earning Report.

---

## 4. GRADUATED AUTONOMY

| Tier | Name | Trust | Resolution Rate | Min Decisions | Clusters |
|------|------|-------|-----------------|---------------|----------|
| 1 | recommend_only | ≥ 0.0 | ≥ 0.0 | 0 | N/A |
| 2 | auto_promote + audit | ≥ 0.85 | ≥ 0.3 | 200 | 0 active, 30d clean |
| 3 | full autonomy | ≥ 0.95 | ≥ 0.5 | 1000 | 0 active, 90d clean |

**Demotion:** Any failure cluster → immediate downgrade one tier.

---

## 5. DEPLOYED SCHEMA (18 Tables)

### Layer 1: Ingestion
- `raw_intel` — Immutable intake staging

### Layer 2: Validation
- `claims_pending` — Working memory with triples + truth_vector + vanguard eval

### Layer 3: Permanent Ledger
- `claims` — Append-only truth ledger with vector(3072) and cascade_depth

### Layer 4: Evidence & Conflicts
- `evidence_artifacts` — Evidence with credibility weights
- `claim_conflicts` — Contradictions linked, never collapsed

### Layer 5: Governance & Trust
- `baselines` — Domain decay functions
- `source_reputation` — Per-source accuracy
- `jarvis_trust_scores` — Domain trust (rolling window)
- `jarvis_log` — Decision audit trail (append-only)
- `failure_clusters` — Correlated error detection
- `governance_thresholds` — Autonomy tier definitions

### Layer 6: System Operations
- `tasks` — Task queue with state machine
- `partial_outcomes` — Intermediate outcome tracking
- `learning_events` — Behavioral adaptation log

### Layer 7: LLM Routing
- `compute_routing_config` — Model routing per agent role
- `llm_call_log` — Per-call telemetry
- `model_divergence_log` — Dual extraction disagreement (Phase 2+)
- `spec_deviations` — Change protocol log

---

## 6. COMPUTE WATERFALL

| Agent | Model | Fallback | Ceiling | Phase |
|-------|-------|----------|---------|-------|
| vanguard | claude-sonnet-4-6 | claude-haiku-4-5 | $0.01 | 1 (ACTIVE) |
| extractor | claude-sonnet-4-6 | claude-haiku-4-5 | $0.008 | 2 |
| advocate | claude-sonnet-4-6 | claude-haiku-4-5 | $0.01 | 2 |
| skeptic | claude-sonnet-4-6 | claude-haiku-4-5 | $0.01 | 2 |
| adversarial | claude-sonnet-4-6 | N/A | $0.01 | 3 |
| jarvis | claude-opus-4-6 | claude-sonnet-4-6 | $0.02 | 3 |
| embeddings | text-embedding-3-large | N/A | $0.001 | 2 |

**Hard ceiling:** $0.05/claim. Expensive reasoning reserved for irreversible decisions only.

---

## 7. CONTRADICTION ENGINE

Contradictions are MAPPED, never RESOLVED.

1. **LLM Extraction:** Raw text → structured triple
2. **Symbolic Comparison:** Negation detection, quantifier conflict detection
3. **Embeddings (Secondary):** Find semantically similar claims missed by symbolic rules

**Cascade:** Invalidation propagates to dependents. Depth limit = 3. Beyond: batch review.

---

## 8. PHASE MAP

- **Phase 1:** ✅ Core loop proven (18 tables, vanguard pipeline, all tests pass)
- **Phase 1.5:** 🔄 Real data at volume, earn the swarm via error analysis
- **Phase 2:** ⬜ Debate Swarm (Skeptic first, based on Swarm Earning Report)
- **Phase 3:** ⬜ Full system (Jarvis governance, Cosmos Canvas, Ghidra-MCP)

---

## 9. CHANGE PROTOCOL

- **Build Bible:** Constitution. Amended rarely, during explicit review sessions.
- **Tech Spec:** Legislation. Updated with every migration.
- **Test Plan:** Case law. Every bug becomes a test case.
- **spec_deviations table:** Real-time change log in Supabase.

> **Component Addition Rule:** No new table, column, function, or dependency unless it (1) replaces existing, OR (2) is required for current phase core loop.

---

## 10. METRICS THAT MATTER

1. Outcome Resolution Rate
2. Effective Trust Score per domain
3. Failure Cluster Frequency
4. Extraction Accuracy per domain
5. Cost Per Claim (ceiling: $0.05)
6. Confidence Calibration (do high-conf claims confirm more often?)

---

## 11. NON-GOALS

The system does NOT: determine absolute truth, optimize for speed, prioritize UX, auto-scale autonomy without proof, remove historical errors, replace human judgment, compress reasoning, or resolve contradictions.

---

## 12. LEGACY

- **Old NOOSPHERE** (`ucvzoamywjlydeymosyj`): 172+ tables. REFERENCE ONLY. Never write.
- **Taken from v1:** LLM routing schema (well-designed, 0 rows — v2 uses it from day 1).
- **Discarded:** All blockchain, NFT, wallet, simulation, revenue, video tables.

---

> **If any implementation conflicts with this → the implementation is wrong.**
> **If any implementation deviates from this → the system is drifting.**
> **If the system has more than 25 tables → something went wrong.**
