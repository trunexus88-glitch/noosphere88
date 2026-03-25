# NOOSPHERE v2 — DEPLOYMENT DIRECTIVE
## Claude Code Team Prompt — Paste This Entire Document

---

/team

## 0. MISSION BRIEFING (READ BEFORE DOING ANYTHING)

You are building Noosphere v2: a self-correcting epistemic machine that tracks the reliability of its own decisions about reality over time. The optimization target is NOT truth. It is: **rate of corrected error over time.** Philosophy: "Correct the Corrections."

This system went through v1 (172 tables, 80+ edge functions, total sprawl collapse) and months of architectural redesign. The design is DONE. The System Bible is LOCKED. You are here to BUILD, not to redesign. Every architectural question has been answered. If you encounter ambiguity, log it in `spec_deviations` and keep moving.

### THE CRITICAL PIVOT YOU MUST INTERNALIZE

**Do NOT build a multi-agent Debate Swarm.** No Advocate. No Skeptic. No Adversarial Agent. No Jarvis-as-separate-agent. Phase 1 is a **SINGLE-AGENT VANGUARD** — one structured LLM call per claim that extracts, evaluates, and logs in a single pass. The Debate Swarm is earned in Phase 1.5 after 5,000 real claims reveal actual error patterns. This decision cuts cold-start cost by 85% ($1,200/month vs $10,650/month) and gets us to first real data in 3 days instead of 14.

The schema includes all 19 tables (including the tables the swarm will eventually use). We build the full schema now so we don't need surgery later. But the runtime in Phase 1 only touches a subset.

---

## 1. SYSTEM IDENTITY & LAWS (NON-NEGOTIABLE)

**What it is:** A self-correcting epistemic machine.
**What it optimizes:** Rate of corrected error over time.
**What it is NOT:** A truth engine. A chatbot. A summarizer. A consensus machine.

### The 10 System Laws (Violations = Stop and Flag)

1. Confidence decays without outcome (exponential, domain-adaptive, floor = 0.1)
2. Confidence cannot increase without new evidence
3. Outcome-free domains cannot achieve high trust
4. All decisions must be logged before action
5. No autonomous promotion in Phase 1 (human-in-the-loop for all promotions)
6. Invalidated claims have final_confidence = 0
7. Clustered failures trigger systemic response
8. Evidence is required for all claims
9. Historical records are append-only (never delete, never mutate)
10. Dependency invalidations must propagate forward (with cascade_depth_limit = 3)

### The Prime Directive

**Raw data NEVER enters the permanent ledger directly.** All claims must pass through `claims_pending` before promotion to `claims`. No exceptions.

### Component Addition Rule

**No new table, column, function, or dependency may be added unless it:**
- Replaces an existing component, OR
- Is required to complete the core loop

If you think you need something not in this spec, log it in `spec_deviations` and build without it.

---

## 2. TEAM TOPOLOGY

Spin up 3 sub-agents with these roles:

### Agent 1: DATA ARCHITECT
**Scope:** Schema migration, seed data, RLS policies, indexes.
**Delivers:** A working 19-table Supabase database with pgvector enabled, all tables created, seed data loaded, and RLS policies applied.
**Does NOT do:** Write application code, edge functions, or business logic.

### Agent 2: BACKEND ENGINEER  
**Scope:** The Vanguard single-agent pipeline — ingestion, extraction, claim creation, outcome processing, trust recalculation.
**Delivers:** A working extraction pipeline that takes raw text, produces structured triples, inserts into `claims_pending`, and handles promotion/outcome/trust flows.
**Does NOT do:** Schema changes (flag to Data Architect), multi-agent orchestration, UI.

### Agent 3: QA / TEST ENGINEER
**Scope:** Test fixtures, MVL (Minimum Viable Loop) validation, edge case testing.
**Delivers:** A test suite that proves the core loop works end-to-end with concrete inputs and verified outputs.
**Does NOT do:** Write production code. Tests only.

### Coordination Rules
- Data Architect goes FIRST. No other agent starts until the schema is applied and verified.
- Backend Engineer goes SECOND. Builds against the verified schema.
- QA Engineer goes THIRD. Tests against the running pipeline.
- If any agent needs a schema change, they insert into `spec_deviations` and the Data Architect handles the migration.

---

## 3. SUPABASE PROJECT

### Finding or Creating the Project
First, list all Supabase projects to find the v2 project. Look for a project named "noospherev2", "noosphere-v2", or similar. If it exists, use its project_id.

If NO v2 project exists, create one:
- Name: `noosphere-v2`
- Region: `us-east-1`
- **Do NOT use the old NOOSPHERE project** (`ucvzoamywjlydeymosyj`). That is the v1 graveyard with 172 tables. Reference only. Never write to it.

### First Action After Project ID is Confirmed
```sql
CREATE EXTENSION IF NOT EXISTS vector;
CREATE EXTENSION IF NOT EXISTS pg_trgm;
```

---

## 4. THE 19-TABLE SCHEMA (Data Architect — Execute This)

Apply this as a single migration named `noosphere_v2_init`. Every table, every column, every constraint in one atomic migration.

### LAYER 1: INGESTION

```sql
-- raw_intel: Immutable intake staging. 72h TTL before auto-purge if not processed.
CREATE TABLE raw_intel (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  source_url text,
  source_type text NOT NULL CHECK (source_type IN ('academic','news','filing','binary_analysis','api','manual','structured_feed')),
  raw_content text NOT NULL,
  content_hash text NOT NULL,  -- SHA-256 for deduplication
  pipeline text DEFAULT 'manual',
  ingested_at timestamptz NOT NULL DEFAULT now(),
  expires_at timestamptz NOT NULL DEFAULT (now() + interval '72 hours'),
  processed boolean DEFAULT false,
  UNIQUE(content_hash)
);

CREATE INDEX idx_raw_intel_unprocessed ON raw_intel(processed, ingested_at) WHERE processed = false;
CREATE INDEX idx_raw_intel_expires ON raw_intel(expires_at) WHERE processed = false;
```

### LAYER 2: VALIDATION (Working Memory)

```sql
-- claims_pending: Where extraction results live before human promotion.
CREATE TABLE claims_pending (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  raw_intel_id uuid NOT NULL REFERENCES raw_intel(id),
  
  -- Structured triple (THE core data structure)
  triple_subject text NOT NULL,
  triple_relation text NOT NULL,
  triple_object text NOT NULL,
  triple_conditions text,  -- Load-bearing for symbolic contradiction detection
  
  -- Truth vector (4 dimensions, NEVER merged into one number)
  truth_vector jsonb NOT NULL DEFAULT '{"confidence": 0.5, "verifiability": 0.5, "consensus": 0.0, "temporal_validity": {"valid_from": null, "valid_until": null, "decay_rate": 0.01}}',
  
  -- Extraction metadata
  extraction_confidence numeric NOT NULL CHECK (extraction_confidence BETWEEN 0.0 AND 1.0),
  extraction_model text NOT NULL,
  extraction_reasoning text NOT NULL,
  requires_human_review boolean DEFAULT false,
  
  -- Phase 1: Single-agent evaluation (replaces multi-agent debate)
  vanguard_confidence numeric CHECK (vanguard_confidence BETWEEN 0.0 AND 1.0),
  vanguard_reasoning text,
  vanguard_recommendation text CHECK (vanguard_recommendation IN ('promote','quarantine','needs_human','reject')),
  
  -- Status tracking
  status text NOT NULL DEFAULT 'pending' CHECK (status IN ('pending','approved','rejected','quarantined')),
  domain text,
  created_at timestamptz NOT NULL DEFAULT now(),
  reviewed_at timestamptz,
  reviewed_by text  -- 'human' or 'auto_tier2' or 'auto_tier3' (Phase 2+)
);

CREATE INDEX idx_claims_pending_status ON claims_pending(status, created_at);
CREATE INDEX idx_claims_pending_review ON claims_pending(requires_human_review) WHERE status = 'pending';
```

### LAYER 3: PERMANENT LEDGER

```sql
-- claims: The permanent, append-only truth ledger. NEVER delete. NEVER mutate historical fields.
CREATE TABLE claims (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  pending_id uuid NOT NULL REFERENCES claims_pending(id),
  
  -- Triple (copied from claims_pending on promotion)
  triple_subject text NOT NULL,
  triple_relation text NOT NULL,
  triple_object text NOT NULL,
  triple_conditions text,
  
  -- Truth vector at time of promotion
  truth_vector jsonb NOT NULL,
  initial_confidence numeric NOT NULL CHECK (initial_confidence BETWEEN 0.0 AND 1.0),
  effective_confidence numeric NOT NULL CHECK (effective_confidence BETWEEN 0.0 AND 1.0),
  final_confidence numeric CHECK (final_confidence BETWEEN 0.0 AND 1.0),
  
  -- Outcome tracking
  outcome_status text NOT NULL DEFAULT 'unverified' CHECK (outcome_status IN ('unverified','partial','directional','confirmed','invalidated')),
  outcome_source text,
  outcome_timestamp timestamptz,
  
  -- Temporal
  domain text,
  promoted_at timestamptz NOT NULL DEFAULT now(),
  promoted_by text NOT NULL DEFAULT 'human',
  decay_rate numeric NOT NULL DEFAULT 0.01,
  cascade_depth integer NOT NULL DEFAULT 0,
  
  -- Embedding for vector similarity (Phase 1.5+)
  embedding vector(3072),
  
  -- Adversarial flags
  adversarial_flags jsonb DEFAULT '[]',
  failure_cluster_id uuid
);

CREATE INDEX idx_claims_outcome ON claims(outcome_status, domain);
CREATE INDEX idx_claims_domain ON claims(domain, promoted_at);
CREATE INDEX idx_claims_unverified ON claims(outcome_status, effective_confidence) WHERE outcome_status = 'unverified';
```

### LAYER 4: EVIDENCE & CONFLICTS

```sql
-- evidence_artifacts: Every piece of evidence linked to a claim.
CREATE TABLE evidence_artifacts (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  claim_id uuid REFERENCES claims(id),
  pending_claim_id uuid REFERENCES claims_pending(id),
  source_url text,
  source_type text NOT NULL CHECK (source_type IN ('academic','financial_filing','news','binary_analysis','api','court_record','structured_feed')),
  excerpt text NOT NULL,
  credibility_weight numeric NOT NULL DEFAULT 0.0 CHECK (credibility_weight BETWEEN -1.0 AND 1.0),
  freshness_timestamp timestamptz DEFAULT now(),
  created_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX idx_evidence_claim ON evidence_artifacts(claim_id);
CREATE INDEX idx_evidence_pending ON evidence_artifacts(pending_claim_id);

-- claim_conflicts: Contradictions are LINKED, never collapsed.
CREATE TABLE claim_conflicts (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  claim_id uuid NOT NULL REFERENCES claims(id),
  conflicting_claim_id uuid NOT NULL REFERENCES claims(id),
  conflict_type text NOT NULL CHECK (conflict_type IN ('direct_contradiction','partial','temporal','quantifier')),
  evidence_for uuid REFERENCES evidence_artifacts(id),
  evidence_against uuid REFERENCES evidence_artifacts(id),
  detected_by text NOT NULL DEFAULT 'symbolic',  -- 'symbolic' | 'embedding' | 'manual'
  created_at timestamptz NOT NULL DEFAULT now(),
  CHECK (claim_id != conflicting_claim_id)
);

CREATE INDEX idx_conflicts_claim ON claim_conflicts(claim_id);
CREATE INDEX idx_conflicts_conflicting ON claim_conflicts(conflicting_claim_id);
```

### LAYER 5: GOVERNANCE & TRUST

```sql
-- baselines: Authoritative references. Tier-controlled, invocation-limited.
CREATE TABLE baselines (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  domain text NOT NULL,
  name text NOT NULL,
  description text,
  tier integer NOT NULL DEFAULT 1 CHECK (tier BETWEEN 1 AND 3),
  decay_rate_function jsonb DEFAULT '{"type": "exponential", "base_rate": 0.01, "domain_modifier": 1.0}',
  max_invocations_per_day integer DEFAULT 100,
  current_invocations integer DEFAULT 0,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);

-- source_reputation: Tracks accuracy per source for Bayesian priors.
CREATE TABLE source_reputation (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  source_domain text NOT NULL UNIQUE,
  reputation_score numeric NOT NULL DEFAULT 0.5 CHECK (reputation_score BETWEEN 0.0 AND 1.0),
  total_claims integer NOT NULL DEFAULT 0,
  confirmed_claims integer NOT NULL DEFAULT 0,
  invalidated_claims integer NOT NULL DEFAULT 0,
  last_updated timestamptz NOT NULL DEFAULT now()
);

-- jarvis_trust_scores: Domain-specific accuracy tracking (rolling window).
CREATE TABLE jarvis_trust_scores (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  domain text NOT NULL,
  total_decisions integer NOT NULL DEFAULT 0,
  correct_decisions integer NOT NULL DEFAULT 0,
  outcome_resolution_rate numeric NOT NULL DEFAULT 0.0,
  effective_trust_score numeric NOT NULL DEFAULT 0.0,
  extraction_accuracy numeric NOT NULL DEFAULT 1.0,  -- tracks extraction quality per domain
  window_start timestamptz NOT NULL DEFAULT now(),
  window_end timestamptz,
  updated_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE(domain, window_start)
);

-- jarvis_log: Decision audit trail. Append-only. NEVER delete.
CREATE TABLE jarvis_log (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  claim_pending_id uuid REFERENCES claims_pending(id),
  claim_id uuid REFERENCES claims(id),
  decision_type text NOT NULL CHECK (decision_type IN ('extraction','evaluation','promotion','outcome','cascade','cluster_detection')),
  recommendation text,
  rationale text NOT NULL,
  confidence_at_decision numeric,
  model_used text,
  baseline_tier integer,
  failure_cluster_id uuid,
  created_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX idx_jarvis_log_claim ON jarvis_log(claim_id);
CREATE INDEX idx_jarvis_log_pending ON jarvis_log(claim_pending_id);
CREATE INDEX idx_jarvis_log_type ON jarvis_log(decision_type, created_at);

-- failure_clusters: Correlated error detection.
CREATE TABLE failure_clusters (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  domain text NOT NULL,
  signature jsonb NOT NULL,  -- {baseline_id, source_pattern, domain_subdivision}
  incorrect_count integer NOT NULL DEFAULT 0,
  total_in_window integer NOT NULL DEFAULT 0,
  triggered boolean NOT NULL DEFAULT false,
  trust_penalty_applied numeric DEFAULT 0.0,
  created_at timestamptz NOT NULL DEFAULT now(),
  resolved_at timestamptz
);

-- governance_thresholds: Autonomy tier definitions.
CREATE TABLE governance_thresholds (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tier integer NOT NULL UNIQUE CHECK (tier BETWEEN 1 AND 3),
  tier_name text NOT NULL,
  min_trust_score numeric NOT NULL,
  min_resolution_rate numeric NOT NULL,
  min_decisions integer NOT NULL,
  max_active_clusters integer NOT NULL DEFAULT 0,
  clean_cluster_days integer DEFAULT 0,
  description text,
  created_at timestamptz NOT NULL DEFAULT now()
);
```

### LAYER 6: SYSTEM OPERATIONS

```sql
-- tasks: OpenClaw task queue (Noosphere → External requests). Also serves as GSD state machine.
CREATE TABLE tasks (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  task_type text NOT NULL CHECK (task_type IN ('deep_research','validation','scan','extraction','outcome_check','ingestion')),
  objective text NOT NULL,
  state text NOT NULL DEFAULT 'created' CHECK (state IN ('created','assigned','executing','completed','failed','retrying')),
  retry_count integer NOT NULL DEFAULT 0,
  max_retries integer NOT NULL DEFAULT 3,
  state_history jsonb DEFAULT '[]',  -- append-only log of state transitions
  constraints jsonb,
  result jsonb,
  assigned_to text,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX idx_tasks_state ON tasks(state, created_at);

-- partial_outcomes: Intermediate outcome tracking.
CREATE TABLE partial_outcomes (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  claim_id uuid NOT NULL REFERENCES claims(id),
  outcome_type text NOT NULL CHECK (outcome_type IN ('partial','directional')),
  evidence_summary text NOT NULL,
  confidence_adjustment numeric NOT NULL CHECK (confidence_adjustment BETWEEN -0.1 AND 0.1),
  source_url text,
  created_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX idx_partial_outcomes_claim ON partial_outcomes(claim_id);

-- learning_events: Behavioral adaptation changelog.
CREATE TABLE learning_events (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  event_type text NOT NULL CHECK (event_type IN ('weight_adjustment','cluster_response','threshold_change','extraction_recalibration')),
  domain text,
  failure_cluster_id uuid REFERENCES failure_clusters(id),
  before_state jsonb,
  after_state jsonb,
  rationale text NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now()
);
```

### LAYER 7: LLM ROUTING (Stolen from v1, adapted for v2)

```sql
-- compute_routing_config: Centralized model routing per agent role.
CREATE TABLE compute_routing_config (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  agent_role text NOT NULL UNIQUE,
  primary_provider text NOT NULL,
  primary_model text NOT NULL,
  fallback_provider text,
  fallback_model text,
  max_tokens integer DEFAULT 2000,
  temperature numeric DEFAULT 0.3,
  cost_ceiling_per_call numeric,  -- hard limit in USD
  timeout_ms integer DEFAULT 30000,
  updated_at timestamptz NOT NULL DEFAULT now()
);

-- llm_call_log: Per-call telemetry.
CREATE TABLE llm_call_log (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  agent_role text NOT NULL,
  claim_pending_id uuid REFERENCES claims_pending(id),
  provider text NOT NULL,
  model text NOT NULL,
  fallback_used boolean DEFAULT false,
  tokens_in integer NOT NULL,
  tokens_out integer NOT NULL,
  cost_usd numeric NOT NULL,
  latency_ms integer NOT NULL,
  success boolean NOT NULL,
  error_msg text,
  created_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX idx_llm_calls_role ON llm_call_log(agent_role, created_at);
CREATE INDEX idx_llm_calls_claim ON llm_call_log(claim_pending_id);

-- model_divergence_log: Dual extraction disagreement tracking (Phase 1.5+).
CREATE TABLE model_divergence_log (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  claim_pending_id uuid REFERENCES claims_pending(id),
  prompt_hash text NOT NULL,
  model_a text NOT NULL,
  model_b text NOT NULL,
  output_a_digest text NOT NULL,
  output_b_digest text NOT NULL,
  divergence_score numeric NOT NULL CHECK (divergence_score BETWEEN 0.0 AND 1.0),
  resolved_by text,
  resolution_reason text,
  created_at timestamptz NOT NULL DEFAULT now()
);

-- spec_deviations: THE CHANGE PROTOCOL. Log every implementation deviation here.
CREATE TABLE spec_deviations (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  component text NOT NULL,  -- which table/function/system was affected
  deviation_description text NOT NULL,
  rationale text NOT NULL,
  severity text NOT NULL DEFAULT 'minor' CHECK (severity IN ('minor','moderate','major')),
  resolved boolean DEFAULT false,
  resolved_at timestamptz,
  created_at timestamptz NOT NULL DEFAULT now()
);
```

### SEED DATA (Data Architect — Execute After Migration)

```sql
-- Governance thresholds: Tier 1/2/3 autonomy definitions
INSERT INTO governance_thresholds (tier, tier_name, min_trust_score, min_resolution_rate, min_decisions, max_active_clusters, clean_cluster_days, description) VALUES
  (1, 'recommend_only', 0.0, 0.0, 0, 999, 0, 'Phase 1 default. All promotions require human approval.'),
  (2, 'auto_promote_with_audit', 0.85, 0.3, 200, 0, 30, 'Auto-promote claims in this domain. Random audit sampling.'),
  (3, 'full_autonomy', 0.95, 0.5, 1000, 0, 90, 'Full autonomous operation. Exception flagging only.');

-- Compute routing: Single-agent Phase 1 config
INSERT INTO compute_routing_config (agent_role, primary_provider, primary_model, fallback_provider, fallback_model, max_tokens, temperature, cost_ceiling_per_call, timeout_ms) VALUES
  ('vanguard', 'anthropic', 'claude-sonnet-4-6', 'anthropic', 'claude-haiku-4-5-20251001', 2000, 0.2, 0.01, 30000),
  ('extractor', 'anthropic', 'claude-sonnet-4-6', 'anthropic', 'claude-haiku-4-5-20251001', 1500, 0.1, 0.008, 25000),
  ('advocate', 'anthropic', 'claude-sonnet-4-6', 'anthropic', 'claude-haiku-4-5-20251001', 2000, 0.3, 0.01, 30000),
  ('skeptic', 'anthropic', 'claude-sonnet-4-6', 'anthropic', 'claude-haiku-4-5-20251001', 2000, 0.3, 0.01, 30000),
  ('adversarial', 'anthropic', 'claude-sonnet-4-6', NULL, NULL, 2000, 0.4, 0.01, 30000),
  ('jarvis', 'anthropic', 'claude-opus-4-6', 'anthropic', 'claude-sonnet-4-6', 3000, 0.2, 0.02, 45000),
  ('embeddings', 'openai', 'text-embedding-3-large', NULL, NULL, 8000, 0.0, 0.001, 15000);

-- Initial baselines
INSERT INTO baselines (domain, name, description, tier, decay_rate_function) VALUES
  ('finance', 'Financial Earnings', 'Quarterly earnings reports and SEC filings', 1, '{"type": "exponential", "base_rate": 0.05, "domain_modifier": 1.0, "note": "Fast decay - quarterly resolution"}'),
  ('science', 'Scientific Claims', 'Peer-reviewed research findings', 1, '{"type": "exponential", "base_rate": 0.005, "domain_modifier": 1.0, "note": "Slow decay - long verification horizon"}'),
  ('geopolitical', 'Geopolitical Analysis', 'International relations and policy claims', 1, '{"type": "exponential", "base_rate": 0.02, "domain_modifier": 1.0, "note": "Medium decay"}'),
  ('technology', 'Technology Claims', 'Product launches, capabilities, benchmarks', 1, '{"type": "exponential", "base_rate": 0.03, "domain_modifier": 1.0, "note": "Fast-medium decay"}');
```

### RLS POLICIES (Data Architect — Execute After Seed)

```sql
-- Enable RLS on all tables
ALTER TABLE raw_intel ENABLE ROW LEVEL SECURITY;
ALTER TABLE claims_pending ENABLE ROW LEVEL SECURITY;
ALTER TABLE claims ENABLE ROW LEVEL SECURITY;
ALTER TABLE evidence_artifacts ENABLE ROW LEVEL SECURITY;
ALTER TABLE claim_conflicts ENABLE ROW LEVEL SECURITY;
ALTER TABLE baselines ENABLE ROW LEVEL SECURITY;
ALTER TABLE source_reputation ENABLE ROW LEVEL SECURITY;
ALTER TABLE jarvis_trust_scores ENABLE ROW LEVEL SECURITY;
ALTER TABLE jarvis_log ENABLE ROW LEVEL SECURITY;
ALTER TABLE failure_clusters ENABLE ROW LEVEL SECURITY;
ALTER TABLE governance_thresholds ENABLE ROW LEVEL SECURITY;
ALTER TABLE tasks ENABLE ROW LEVEL SECURITY;
ALTER TABLE partial_outcomes ENABLE ROW LEVEL SECURITY;
ALTER TABLE learning_events ENABLE ROW LEVEL SECURITY;
ALTER TABLE compute_routing_config ENABLE ROW LEVEL SECURITY;
ALTER TABLE llm_call_log ENABLE ROW LEVEL SECURITY;
ALTER TABLE model_divergence_log ENABLE ROW LEVEL SECURITY;
ALTER TABLE spec_deviations ENABLE ROW LEVEL SECURITY;

-- Service role gets full access (for edge functions and backend)
CREATE POLICY "service_role_all" ON raw_intel FOR ALL USING (auth.role() = 'service_role');
CREATE POLICY "service_role_all" ON claims_pending FOR ALL USING (auth.role() = 'service_role');
CREATE POLICY "service_role_all" ON claims FOR ALL USING (auth.role() = 'service_role');
CREATE POLICY "service_role_all" ON evidence_artifacts FOR ALL USING (auth.role() = 'service_role');
CREATE POLICY "service_role_all" ON claim_conflicts FOR ALL USING (auth.role() = 'service_role');
CREATE POLICY "service_role_all" ON baselines FOR ALL USING (auth.role() = 'service_role');
CREATE POLICY "service_role_all" ON source_reputation FOR ALL USING (auth.role() = 'service_role');
CREATE POLICY "service_role_all" ON jarvis_trust_scores FOR ALL USING (auth.role() = 'service_role');
CREATE POLICY "service_role_all" ON jarvis_log FOR ALL USING (auth.role() = 'service_role');
CREATE POLICY "service_role_all" ON failure_clusters FOR ALL USING (auth.role() = 'service_role');
CREATE POLICY "service_role_all" ON governance_thresholds FOR ALL USING (auth.role() = 'service_role');
CREATE POLICY "service_role_all" ON tasks FOR ALL USING (auth.role() = 'service_role');
CREATE POLICY "service_role_all" ON partial_outcomes FOR ALL USING (auth.role() = 'service_role');
CREATE POLICY "service_role_all" ON learning_events FOR ALL USING (auth.role() = 'service_role');
CREATE POLICY "service_role_all" ON compute_routing_config FOR ALL USING (auth.role() = 'service_role');
CREATE POLICY "service_role_all" ON llm_call_log FOR ALL USING (auth.role() = 'service_role');
CREATE POLICY "service_role_all" ON model_divergence_log FOR ALL USING (auth.role() = 'service_role');
CREATE POLICY "service_role_all" ON spec_deviations FOR ALL USING (auth.role() = 'service_role');

-- Anon role: read-only on claims and governance (for future API consumers)
CREATE POLICY "anon_read_claims" ON claims FOR SELECT USING (auth.role() = 'anon');
CREATE POLICY "anon_read_governance" ON governance_thresholds FOR SELECT USING (auth.role() = 'anon');
CREATE POLICY "anon_read_trust" ON jarvis_trust_scores FOR SELECT USING (auth.role() = 'anon');
```

---

## 5. THE VANGUARD PIPELINE (Backend Engineer)

Build a single function/script called `vanguard_pipeline` that does one thing: takes raw text and produces a structured claim candidate.

### Input
Read one unprocessed row from `raw_intel` (WHERE processed = false ORDER BY ingested_at ASC LIMIT 1).

### LLM Call
Make ONE call to the model specified in `compute_routing_config` WHERE agent_role = 'vanguard'. Use the system prompt below:

```
You are the Noosphere Vanguard — a structured claim extractor and evaluator.

Given raw text, you MUST output ONLY valid JSON with this exact structure:
{
  "triples": [
    {
      "subject": "string — the entity or concept being described",
      "relation": "string — the relationship or predicate",
      "object": "string — the target entity, value, or state",
      "conditions": "string or null — any qualifying conditions, temporal bounds, or caveats that are LOAD-BEARING for the claim's truth value"
    }
  ],
  "domain": "string — one of: finance, science, geopolitical, technology, general",
  "confidence": 0.0 to 1.0,
  "extraction_confidence": 0.0 to 1.0,
  "reasoning": "string — 2-3 sentences explaining your confidence assessment and any uncertainty"
}

Rules:
- Extract ALL distinct claims as separate triples. Do not merge.
- NEVER drop conditions. If the text says "X is true IF Y" — the condition "IF Y" MUST appear.
- If you are uncertain about the extraction, set extraction_confidence below 0.7.
- Confidence reflects how likely the claim is true based on the source text alone.
- Be conservative. Default to lower confidence when uncertain.
```

### Post-Processing
For each triple in the response:
1. Insert into `claims_pending` with:
   - `extraction_confidence` from the LLM response
   - `requires_human_review` = true IF extraction_confidence < 0.7
   - `vanguard_confidence` = confidence from response
   - `vanguard_reasoning` = reasoning from response
   - `vanguard_recommendation` = 'promote' if confidence >= 0.7, 'needs_human' if 0.4-0.7, 'reject' if < 0.4
   - `status` = 'pending'
   - `domain` from the response
2. Mark the `raw_intel` row as `processed = true`
3. Log the LLM call to `llm_call_log` with tokens, cost, latency, success
4. Log the decision to `jarvis_log` with decision_type = 'extraction'

### Promotion Function
Build a `promote_claim` function that:
1. Takes a `claims_pending.id`
2. Copies the triple + truth_vector + confidence into `claims`
3. Sets `initial_confidence` and `effective_confidence` to the vanguard_confidence
4. Sets `promoted_by` = 'human'
5. Sets `decay_rate` from the domain's baseline (lookup from `baselines` table)
6. Logs the promotion to `jarvis_log` with decision_type = 'promotion'
7. Updates `claims_pending.status` = 'approved' and `reviewed_at` = now()

### Outcome Recording Function
Build a `record_outcome` function that:
1. Takes a `claims.id` and an `outcome_status` ('confirmed' or 'invalidated')
2. If confirmed: calculates `final_confidence` using verification_weight formula: `MIN(1.0, initial_confidence + (1 - initial_confidence) * 0.7)`
3. If invalidated: sets `final_confidence` = 0
4. Updates `jarvis_trust_scores` for the domain (increment total_decisions, increment correct_decisions if outcome matches recommendation)
5. If invalidated: propagates adversarial flag to dependent claims (check `claim_conflicts` + `evidence_artifacts`) up to `cascade_depth_limit` = 3
6. Logs to `jarvis_log` with decision_type = 'outcome'

### Confidence Decay Function
Build a `apply_decay` function that:
1. Selects all claims WHERE outcome_status = 'unverified'
2. For each: `effective_confidence = initial_confidence * e^(-decay_rate * hours_since_promotion / 24)`
3. Floor at 0.1 (never below)
4. This should run on a schedule (cron or manual trigger for Phase 1)

---

## 6. MINIMUM VIABLE LOOP TEST (QA Engineer)

Write a test script that proves the full loop works. Use these exact test fixtures:

### Test 1: Happy Path — Single Claim Extraction
```
Input raw_intel: "Apple reported Q1 2026 revenue of $124.3 billion, exceeding analyst expectations of $121.1 billion."
Expected: claims_pending row with subject="Apple", relation="reported Q1 2026 revenue of", object="$124.3 billion", conditions="exceeding analyst expectations of $121.1 billion", domain="finance"
Verify: extraction_confidence > 0.5, status = 'pending'
```

### Test 2: Low-Confidence Extraction
```
Input raw_intel: "Sources suggest that a major tech company may be considering a significant acquisition in the AI space."
Expected: claims_pending row with extraction_confidence < 0.7, requires_human_review = true
Verify: vanguard_recommendation = 'needs_human'
```

### Test 3: Promotion to Ledger
```
Action: Promote Test 1 claim via promote_claim function
Verify: Row exists in claims table with initial_confidence > 0, outcome_status = 'unverified', decay_rate matches finance baseline
Verify: jarvis_log has entry with decision_type = 'promotion'
```

### Test 4: Outcome — Confirmation
```
Action: Record outcome on promoted claim with outcome_status = 'confirmed'
Verify: final_confidence > initial_confidence (verification boost applied)
Verify: jarvis_trust_scores for 'finance' domain has total_decisions = 1, correct_decisions = 1
```

### Test 5: Outcome — Invalidation + Cascade
```
Setup: Promote a second claim. Create a claim_conflicts entry linking it to the first.
Action: Record outcome on second claim with outcome_status = 'invalidated'
Verify: final_confidence = 0
Verify: First claim receives adversarial_flags entry with 'dependency_invalidated'
Verify: cascade_depth on flagged claims does not exceed 3
Verify: jarvis_log has entry with decision_type = 'cascade'
```

### Test 6: Confidence Decay
```
Action: Run apply_decay on the confirmed claim from Test 4
Verify: effective_confidence < initial_confidence (decay applied)
Verify: effective_confidence >= 0.1 (floor respected)
```

### Test 7: Spec Deviation Logging
```
Action: Insert a test row into spec_deviations
Verify: Row exists with component, deviation_description, rationale, severity
```

---

## 7. SUCCESS CRITERIA (When Is Phase 1 DONE?)

Phase 1 is complete when ALL of these are true:
- [ ] 19 tables exist in Supabase with correct columns and constraints
- [ ] pgvector extension is enabled
- [ ] Seed data is loaded (governance_thresholds, compute_routing_config, baselines)
- [ ] Vanguard pipeline processes raw_intel → claims_pending successfully
- [ ] promote_claim moves claims_pending → claims correctly
- [ ] record_outcome updates trust scores and propagates cascades
- [ ] apply_decay reduces effective_confidence on unverified claims
- [ ] All 7 test cases pass
- [ ] llm_call_log has entries for every LLM call made during testing
- [ ] spec_deviations table is populated if ANY schema changes were needed

Phase 1 is NOT complete if:
- Any multi-agent code exists (no Advocate, Skeptic, Adversarial, or Jarvis agents)
- Any UI code exists
- Any Google Workspace integration exists
- Any Ghidra-MCP code exists
- Any embedding generation code exists (schema has the column, but we don't populate it yet)

---

## 8. WHAT COMES AFTER (DO NOT BUILD THIS NOW)

Phase 1.5 (after 5,000 claims processed):
- Analyze error patterns in jarvis_log
- Build Advocate/Skeptic agents targeted at specific error types
- Enable dual extraction + model_divergence_log
- Begin embedding generation

Phase 2:
- Full Debate Swarm operational
- Adversarial Agent
- Jarvis as governance layer
- Conflict graph visualization (Cosmos Canvas data contract)

Phase 3:
- Google Workspace integration (notification_config table)
- Ghidra-MCP bridge
- Graduated autonomy (Tier 2/3 activation)

---

## 9. REMINDERS (TAPE THESE TO YOUR WALL)

1. **Supabase is the only authority.** Not Obsidian. Not Google. Not local state.
2. **Append-only on truth tables.** Never delete from claims, jarvis_log, learning_events.
3. **Log everything to llm_call_log.** Every LLM call. Every one. No exceptions.
4. **If it's not in the schema, you don't need it.** No new tables without spec_deviations entry.
5. **The old NOOSPHERE project (ucvzoamywjlydeymosyj) is REFERENCE ONLY.** Never write to it.
6. **Phase 1 = single agent.** If you find yourself building multi-agent orchestration, STOP.
7. **Prove the loop.** extraction → pending → promotion → ledger → outcome → trust. That's it.

---

BEGIN. Data Architect goes first. Output the compiled SQL migration for review, then apply it.
