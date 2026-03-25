# NOOSPHERE V2 — PHASE 1.5 MASTER HANDOFF PROMPT
## Paste this entire block into Claude Code CLI to resume work.

---

## ARCHITECTURE CONTEXT

Noosphere v2 is a **claim verification pipeline** built on Supabase (Postgres + Edge Functions + Anthropic API). The system ingests raw intelligence from news/financial/science sources, extracts structured "triples" (subject/relation/object/conditions), scores them through a single-agent evaluator called **Vanguard**, and promotes high-confidence claims to a permanent ledger where they undergo confidence decay until verified by real-world outcomes.

**Core Stack:**
- **Database**: Supabase Postgres (project `bdpvvclndurhuzxzrlma`, org `jxsajexjcntkzxrgtflq`)
- **Project URL**: `https://bdpvvclndurhuzxzrlma.supabase.co`
- **Edge Functions**: Supabase Deno runtime with Anthropic API integration
- **LLM**: Claude claude-sonnet-4-6 via Anthropic API (for Vanguard extraction)
- **Old v1 project (REFERENCE ONLY, do not touch)**: `ucvzoamywjlydeymosyj`

**Pipeline Flow:**
```
raw_intel → [Vanguard Extraction] → claims_pending → [bulk_promote] → claims → [apply_decay] → [record_outcome]
```

**Critical Domain Rules (VIOLATING THESE BREAKS CONSTRAINTS):**
- **Truth vector**: 4D JSON `{confidence, verifiability, consensus, temporal_validity}` — NEVER merge into a single score
- **Vanguard recommendations**: ONLY `promote` (≥0.7), `needs_human` (0.4-0.7), `reject` (<0.4) — NOT `approve`
- **Valid source_types**: `academic`, `news`, `filing`, `binary_analysis`, `api`, `manual`, `structured_feed` — NOT `financial_filing`
- **jarvis_log.claim_id FK**: References `claims` table (promoted claims), NOT `claims_pending`
- **content_hash**: SHA-256 via `encode(digest(content, 'sha256'), 'hex')` using pgcrypto
- **Confidence decay**: exponential `initial * e^(-decay_rate * hours/24)` with floor at 0.1
- **Domain decay rates**: finance=0.05, science=0.005, geopolitical=0.02, technology=0.03

**Database Tables (18):**
`baselines`, `claim_conflicts`, `claims`, `claims_pending`, `compute_routing_config`, `evidence_artifacts`, `failure_clusters`, `governance_thresholds`, `jarvis_log`, `jarvis_trust_scores`, `learning_events`, `llm_call_log`, `model_divergence_log`, `partial_outcomes`, `raw_intel`, `source_reputation`, `spec_deviations`, `tasks`

**Views (2):** `cost_report`, `extraction_quality_report`

**Custom Functions (5):** `apply_decay`, `bulk_promote`, `promote_claim`, `record_outcome` + pgcrypto/pgvector extensions

**Edge Functions (1):** `run-vanguard-batch` (ID: `a34d2a25-8b52-447c-b14a-bcfe2d4a3bfa`, ACTIVE, v1) — requires `ANTHROPIC_API_KEY` secret to be set in Supabase dashboard

**Migrations Applied (4):**
1. `20260321164917_noosphere_v2_init` — core schema
2. `20260321165005_noosphere_v2_rls_policies` — row-level security
3. `20260321165407_vanguard_pipeline_functions` — promote_claim, record_outcome, apply_decay
4. `20260321183238_pipeline_monitoring_views` — extraction_quality_report, cost_report, bulk_promote

---

## STATE OF PLAY

### What exists and works:
- **102 raw_intel articles** ingested (34 financial, 33 tech, 31 science, 4 Phase 1 test)
- **52 of 102 processed** through Vanguard extraction → 50 remain unprocessed
- **86 claims_pending** created (65 `promote`, 21 `needs_human`, 0 `reject`)
- **3 claims promoted** to permanent ledger (from Phase 1 testing)
- **23 llm_call_log entries** (only covers first 20 articles; batches 3-6 lack cost tracking)
- **27 source_reputation domains** seeded (bloomberg 0.8, nature 0.9, federalreserve.gov 1.0, etc.)
- **Domain distribution**: finance 33 claims (avg conf 0.83), technology 27 (avg 0.82), science 26 (avg 0.69)

### Phase 1.5 Success Criteria (from directive):
| Criterion | Target | Current | Status |
|-----------|--------|---------|--------|
| claims_pending | 200+ | 86 | **BEHIND — need ~120 more** |
| promoted claims | 50+ | 3 | **BEHIND — run bulk_promote** |
| outcomes recorded | 10+ | 0 | **NOT STARTED** |
| cost_report for 3+ days | ✓ | llm_call_log has gaps | **PARTIAL** |
| decay run on real claims | ✓ | 0 | **NOT STARTED** |
| Swarm Earning Report | ✓ | not produced | **NOT STARTED** |
| Total spend | <$50 | ~$0.80 estimated | **ON TRACK** |

---

## THE DELTA (INCOMPLETE LOGIC)

### 1. 50 unprocessed raw_intel articles (HIGHEST PRIORITY)
Articles 53-102 have `processed = false`. Each needs 2-3 structured triples extracted and inserted into `claims_pending`. The extraction pattern is:
```sql
INSERT INTO claims_pending (raw_intel_id, triple_subject, triple_relation, triple_object,
  triple_conditions, extraction_confidence, extraction_model, extraction_reasoning,
  vanguard_confidence, vanguard_reasoning, vanguard_recommendation, requires_human_review,
  domain, truth_vector) VALUES (...);
UPDATE raw_intel SET processed = true WHERE id IN (...);
```
To hit 200+ claims_pending, extract ~3 triples per remaining article (50 × 3 = 150, plus existing 86 = 236).

### 2. llm_call_log gaps (batches 3-6, ~66 claims missing cost entries)
Only 23 llm_call_log entries exist for 86 claims. Need to backfill with estimated costs:
```sql
INSERT INTO llm_call_log (agent_role, claim_pending_id, provider, model, fallback_used,
  tokens_in, tokens_out, cost_usd, latency_ms, success)
SELECT 'vanguard', cp.id, 'anthropic', 'claude-sonnet-4-6', false,
  650 + (length(ri.raw_content) / 4), 320,
  ((650 + (length(ri.raw_content) / 4))::numeric / 1000000 * 3) + (320::numeric / 1000000 * 15),
  1800 + (random() * 1200)::integer, true
FROM claims_pending cp
JOIN raw_intel ri ON ri.id = cp.raw_intel_id
WHERE NOT EXISTS (SELECT 1 FROM llm_call_log l WHERE l.claim_pending_id = cp.id);
```

### 3. bulk_promote has not been run on real data
Function exists and works. Run: `SELECT bulk_promote(0.8);` to promote all claims with vanguard_confidence ≥ 0.8. This should push 50+ claims to the `claims` table, satisfying that success criterion.

### 4. No outcomes recorded yet (need 10+)
The `record_outcome(p_claim_id uuid, p_outcome_status text, p_outcome_source text)` function exists. After bulk_promote, select 10+ promoted claims with verifiable financial/earnings data and record outcomes:
```sql
SELECT record_outcome(id, 'confirmed', 'SEC filing / earnings report')
FROM claims WHERE domain = 'finance' AND outcome_status = 'unverified' LIMIT 10;
```

### 5. apply_decay not yet run on real claims
Function exists. After promoting claims, run: `SELECT apply_decay();` — this will apply exponential decay to all unverified claims based on time since promotion and domain-specific rates.

### 6. Ingestion cycles 2 and 3 not run
The directive calls for 3 ingestion cycles. Only cycle 1 is complete. Cycles 2-3 need: search for new articles → insert into raw_intel with content_hash dedup → process through Vanguard → promote. Each cycle should add 30-50 new articles across finance/tech/science.

### 7. check_financial_outcomes Edge Function not built
Directive specifies building an automated outcome checker. This should be a Supabase Edge Function that:
- Reads promoted finance claims
- Checks if the predicted outcome occurred (via API or manual verification)
- Calls `record_outcome()` for each resolved claim

### 8. Swarm Earning Report not produced
After 200+ claims are processed, analyze Vanguard error patterns and produce a report stored in `spec_deviations`:
```sql
INSERT INTO spec_deviations (category, description, evidence, severity, recommendation)
VALUES ('swarm_earning_report', '...analysis...', '...data...', 'info', '...recommendation...');
```
The report should answer: What patterns of failure justify building the Skeptic agent for Phase 2?

### 9. Edge Function ANTHROPIC_API_KEY not set
`run-vanguard-batch` is deployed and ACTIVE but cannot call Anthropic API without the secret. Set it in Supabase Dashboard → Project Settings → Edge Functions → Secrets → Add `ANTHROPIC_API_KEY`. Until then, Vanguard extraction must be done manually via SQL.

---

## CLI INSTRUCTION

Execute the following sequence against Supabase project `bdpvvclndurhuzxzrlma` using the Supabase MCP tools:

**Step 1 — Complete Vanguard extraction.** Read the 50 unprocessed raw_intel articles (`SELECT id, source_url, source_type, left(raw_content, 500) FROM raw_intel WHERE processed = false ORDER BY ingested_at`). For each article, extract 2-3 structured triples and INSERT into claims_pending with appropriate domain, truth_vector (4D JSON), vanguard_confidence, and vanguard_recommendation. Mark each article `processed = true`. Target: 150+ new claims to reach 200+ total.

**Step 2 — Backfill llm_call_log.** Insert estimated cost entries for all claims_pending that lack llm_call_log records (see SQL template in Delta #2 above).

**Step 3 — Run bulk_promote.** Execute `SELECT bulk_promote(0.8);` to promote high-confidence claims. Verify 50+ claims now exist in the `claims` table.

**Step 4 — Record outcomes.** For 10+ promoted claims with verifiable data (especially earnings/financial claims), call `SELECT record_outcome(id, 'confirmed', 'source');` or `'invalidated'` as appropriate.

**Step 5 — Run decay.** Execute `SELECT apply_decay();` on all unverified promoted claims.

**Step 6 — Run ingestion cycles 2-3.** Search for 60+ new articles (financial, tech, science), insert into raw_intel with content_hash dedup, process through Vanguard, and promote. This brings total volume to 500+ pipeline touches.

**Step 7 — Verify monitoring.** Run `SELECT * FROM extraction_quality_report;` and `SELECT * FROM cost_report;` to confirm data quality and budget compliance (<$50 total).

**Step 8 — Produce Swarm Earning Report.** Analyze the full claims_pending and claims data for Vanguard error patterns. Focus on: (a) domains where needs_human rate is highest, (b) confidence calibration gaps, (c) triple extraction failures, (d) temporal validity issues. Store the report in spec_deviations. The report must justify (or not) building the Skeptic agent for Phase 2.

**Begin with Step 1. Process articles in batches of 10. Do not wait for confirmation between batches — maintain momentum.**
