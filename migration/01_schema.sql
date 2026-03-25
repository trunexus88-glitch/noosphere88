-- NOOSPHERE v2 — Database Schema Migration
-- Step 1 of 5: Run this FIRST in your Supabase SQL Editor
-- Target project: isfhndnwydnqbmvixddm
-- Source project: bdpvvclndurhuzxzrlma (being retired)
-- ============================================================

-- Extensions (required before tables)
CREATE EXTENSION IF NOT EXISTS "uuid-ossp";
CREATE EXTENSION IF NOT EXISTS "vector";
CREATE EXTENSION IF NOT EXISTS "pg_net";

-- ============================================================
-- TABLE: baselines
-- ============================================================
CREATE TABLE IF NOT EXISTS public.baselines (
  id uuid DEFAULT gen_random_uuid() NOT NULL PRIMARY KEY,
  domain text NOT NULL,
  name text NOT NULL,
  description text,
  tier int4 DEFAULT 1 NOT NULL,
  decay_rate_function jsonb DEFAULT '{"type": "exponential", "base_rate": 0.01, "domain_modifier": 1.0}'::jsonb,
  max_invocations_per_day int4 DEFAULT 100,
  current_invocations int4 DEFAULT 0,
  created_at timestamptz DEFAULT now() NOT NULL,
  updated_at timestamptz DEFAULT now() NOT NULL
);

-- ============================================================
-- TABLE: raw_intel
-- ============================================================
CREATE TABLE IF NOT EXISTS public.raw_intel (
  id uuid DEFAULT gen_random_uuid() NOT NULL PRIMARY KEY,
  source_url text,
  source_type text NOT NULL,
  raw_content text NOT NULL,
  content_hash text NOT NULL,
  pipeline text DEFAULT 'manual'::text,
  ingested_at timestamptz DEFAULT now() NOT NULL,
  expires_at timestamptz DEFAULT (now() + '72:00:00'::interval) NOT NULL,
  processed bool DEFAULT false
);

-- ============================================================
-- TABLE: source_reputation
-- ============================================================
CREATE TABLE IF NOT EXISTS public.source_reputation (
  id uuid DEFAULT gen_random_uuid() NOT NULL PRIMARY KEY,
  source_domain text NOT NULL,
  reputation_score numeric DEFAULT 0.5 NOT NULL,
  total_claims int4 DEFAULT 0 NOT NULL,
  confirmed_claims int4 DEFAULT 0 NOT NULL,
  invalidated_claims int4 DEFAULT 0 NOT NULL,
  last_updated timestamptz DEFAULT now() NOT NULL
);

-- ============================================================
-- TABLE: claims_pending
-- ============================================================
CREATE TABLE IF NOT EXISTS public.claims_pending (
  id uuid DEFAULT gen_random_uuid() NOT NULL PRIMARY KEY,
  raw_intel_id uuid NOT NULL REFERENCES public.raw_intel(id),
  triple_subject text NOT NULL,
  triple_relation text NOT NULL,
  triple_object text NOT NULL,
  triple_conditions text,
  truth_vector jsonb DEFAULT '{"consensus": 0.0, "confidence": 0.5, "verifiability": 0.5, "temporal_validity": {"decay_rate": 0.01, "valid_from": null, "valid_until": null}}'::jsonb NOT NULL,
  extraction_confidence numeric NOT NULL,
  extraction_model text NOT NULL,
  extraction_reasoning text NOT NULL,
  requires_human_review bool DEFAULT false,
  vanguard_confidence numeric,
  vanguard_reasoning text,
  vanguard_recommendation text,
  status text DEFAULT 'pending'::text NOT NULL,
  domain text,
  created_at timestamptz DEFAULT now() NOT NULL,
  reviewed_at timestamptz,
  reviewed_by text,
  skeptic_reviewed bool DEFAULT false,
  skeptic_confidence numeric,
  skeptic_reasoning text,
  skeptic_verdict text,
  skeptic_reviewed_at timestamptz,
  advocate_reviewed bool DEFAULT false,
  advocate_confidence numeric,
  advocate_reasoning text,
  advocate_evidence jsonb DEFAULT '[]'::jsonb,
  advocate_reviewed_at timestamptz,
  jarvis_evaluated bool DEFAULT false,
  jarvis_confidence numeric,
  jarvis_recommendation text,
  jarvis_rationale text,
  jarvis_evaluated_at timestamptz,
  jarvis_baseline_tier int4,
  adversarial_reviewed bool DEFAULT false,
  adversarial_result text,
  adversarial_recommendation text,
  adversarial_reasoning text,
  adversarial_reviewed_at timestamptz
);

-- ============================================================
-- TABLE: claims
-- ============================================================
CREATE TABLE IF NOT EXISTS public.claims (
  id uuid DEFAULT gen_random_uuid() NOT NULL PRIMARY KEY,
  pending_id uuid NOT NULL REFERENCES public.claims_pending(id),
  triple_subject text NOT NULL,
  triple_relation text NOT NULL,
  triple_object text NOT NULL,
  triple_conditions text,
  truth_vector jsonb NOT NULL,
  initial_confidence numeric NOT NULL,
  effective_confidence numeric NOT NULL,
  final_confidence numeric,
  outcome_status text DEFAULT 'unverified'::text NOT NULL,
  outcome_source text,
  outcome_timestamp timestamptz,
  domain text,
  promoted_at timestamptz DEFAULT now() NOT NULL,
  promoted_by text DEFAULT 'human'::text NOT NULL,
  decay_rate numeric DEFAULT 0.01 NOT NULL,
  cascade_depth int4 DEFAULT 0 NOT NULL,
  embedding vector,
  adversarial_flags jsonb DEFAULT '[]'::jsonb,
  failure_cluster_id uuid
);

-- ============================================================
-- TABLE: claim_conflicts
-- ============================================================
CREATE TABLE IF NOT EXISTS public.claim_conflicts (
  id uuid DEFAULT gen_random_uuid() NOT NULL PRIMARY KEY,
  claim_id uuid NOT NULL REFERENCES public.claims(id),
  conflicting_claim_id uuid NOT NULL REFERENCES public.claims(id),
  conflict_type text NOT NULL,
  evidence_for uuid,
  evidence_against uuid,
  detected_by text DEFAULT 'symbolic'::text NOT NULL,
  created_at timestamptz DEFAULT now() NOT NULL
);

-- ============================================================
-- TABLE: evidence_artifacts
-- ============================================================
CREATE TABLE IF NOT EXISTS public.evidence_artifacts (
  id uuid DEFAULT gen_random_uuid() NOT NULL PRIMARY KEY,
  claim_id uuid REFERENCES public.claims(id),
  pending_claim_id uuid REFERENCES public.claims_pending(id),
  source_url text,
  source_type text NOT NULL,
  excerpt text NOT NULL,
  credibility_weight numeric DEFAULT 0.0 NOT NULL,
  freshness_timestamp timestamptz DEFAULT now(),
  created_at timestamptz DEFAULT now() NOT NULL
);

-- ============================================================
-- TABLE: failure_clusters
-- ============================================================
CREATE TABLE IF NOT EXISTS public.failure_clusters (
  id uuid DEFAULT gen_random_uuid() NOT NULL PRIMARY KEY,
  domain text NOT NULL,
  signature jsonb NOT NULL,
  incorrect_count int4 DEFAULT 0 NOT NULL,
  total_in_window int4 DEFAULT 0 NOT NULL,
  triggered bool DEFAULT false NOT NULL,
  trust_penalty_applied numeric DEFAULT 0.0,
  created_at timestamptz DEFAULT now() NOT NULL,
  resolved_at timestamptz
);

-- ============================================================
-- TABLE: jarvis_trust_scores
-- ============================================================
CREATE TABLE IF NOT EXISTS public.jarvis_trust_scores (
  id uuid DEFAULT gen_random_uuid() NOT NULL PRIMARY KEY,
  domain text NOT NULL,
  total_decisions int4 DEFAULT 0 NOT NULL,
  correct_decisions int4 DEFAULT 0 NOT NULL,
  outcome_resolution_rate numeric DEFAULT 0.0 NOT NULL,
  effective_trust_score numeric DEFAULT 0.0 NOT NULL,
  extraction_accuracy numeric DEFAULT 1.0 NOT NULL,
  window_start timestamptz DEFAULT now() NOT NULL,
  window_end timestamptz,
  updated_at timestamptz DEFAULT now() NOT NULL,
  autonomy_tier int4 DEFAULT 1,
  tier_activated_at timestamptz,
  audit_sample_rate numeric DEFAULT 1.0,
  window_size int4 DEFAULT 1000,
  window_type text DEFAULT 'rolling'::text,
  clean_cluster_start timestamptz DEFAULT now(),
  promotion_threshold numeric DEFAULT 0.80
);

-- ============================================================
-- TABLE: governance_thresholds
-- ============================================================
CREATE TABLE IF NOT EXISTS public.governance_thresholds (
  id uuid DEFAULT gen_random_uuid() NOT NULL PRIMARY KEY,
  tier int4 NOT NULL,
  tier_name text NOT NULL,
  min_trust_score numeric NOT NULL,
  min_resolution_rate numeric NOT NULL,
  min_decisions int4 NOT NULL,
  max_active_clusters int4 DEFAULT 0 NOT NULL,
  clean_cluster_days int4 DEFAULT 0,
  description text,
  created_at timestamptz DEFAULT now() NOT NULL
);

-- ============================================================
-- TABLE: compute_routing_config
-- ============================================================
CREATE TABLE IF NOT EXISTS public.compute_routing_config (
  id uuid DEFAULT gen_random_uuid() NOT NULL PRIMARY KEY,
  agent_role text NOT NULL,
  primary_provider text NOT NULL,
  primary_model text NOT NULL,
  fallback_provider text,
  fallback_model text,
  max_tokens int4 DEFAULT 2000,
  temperature numeric DEFAULT 0.3,
  cost_ceiling_per_call numeric,
  timeout_ms int4 DEFAULT 30000,
  updated_at timestamptz DEFAULT now() NOT NULL
);

-- ============================================================
-- TABLE: jarvis_log
-- ============================================================
CREATE TABLE IF NOT EXISTS public.jarvis_log (
  id uuid DEFAULT gen_random_uuid() NOT NULL PRIMARY KEY,
  claim_pending_id uuid REFERENCES public.claims_pending(id),
  claim_id uuid REFERENCES public.claims(id),
  decision_type text NOT NULL,
  recommendation text,
  rationale text NOT NULL,
  confidence_at_decision numeric,
  model_used text,
  baseline_tier int4,
  failure_cluster_id uuid,
  created_at timestamptz DEFAULT now() NOT NULL
);

-- ============================================================
-- TABLE: llm_call_log
-- ============================================================
CREATE TABLE IF NOT EXISTS public.llm_call_log (
  id uuid DEFAULT gen_random_uuid() NOT NULL PRIMARY KEY,
  agent_role text NOT NULL,
  claim_pending_id uuid REFERENCES public.claims_pending(id),
  provider text NOT NULL,
  model text NOT NULL,
  fallback_used bool DEFAULT false,
  tokens_in int4 NOT NULL,
  tokens_out int4 NOT NULL,
  cost_usd numeric NOT NULL,
  latency_ms int4 NOT NULL,
  success bool NOT NULL,
  error_msg text,
  created_at timestamptz DEFAULT now() NOT NULL
);

-- ============================================================
-- TABLE: learning_events
-- ============================================================
CREATE TABLE IF NOT EXISTS public.learning_events (
  id uuid DEFAULT gen_random_uuid() NOT NULL PRIMARY KEY,
  event_type text NOT NULL,
  domain text,
  failure_cluster_id uuid REFERENCES public.failure_clusters(id),
  before_state jsonb,
  after_state jsonb,
  rationale text NOT NULL,
  created_at timestamptz DEFAULT now() NOT NULL
);

-- ============================================================
-- TABLE: model_divergence_log
-- ============================================================
CREATE TABLE IF NOT EXISTS public.model_divergence_log (
  id uuid DEFAULT gen_random_uuid() NOT NULL PRIMARY KEY,
  claim_pending_id uuid REFERENCES public.claims_pending(id),
  prompt_hash text NOT NULL,
  model_a text NOT NULL,
  model_b text NOT NULL,
  output_a_digest text NOT NULL,
  output_b_digest text NOT NULL,
  divergence_score numeric NOT NULL,
  resolved_by text,
  resolution_reason text,
  created_at timestamptz DEFAULT now() NOT NULL
);

-- ============================================================
-- TABLE: partial_outcomes
-- ============================================================
CREATE TABLE IF NOT EXISTS public.partial_outcomes (
  id uuid DEFAULT gen_random_uuid() NOT NULL PRIMARY KEY,
  claim_id uuid NOT NULL REFERENCES public.claims(id),
  outcome_type text NOT NULL,
  evidence_summary text NOT NULL,
  confidence_adjustment numeric NOT NULL,
  source_url text,
  created_at timestamptz DEFAULT now() NOT NULL
);

-- ============================================================
-- TABLE: spec_deviations
-- ============================================================
CREATE TABLE IF NOT EXISTS public.spec_deviations (
  id uuid DEFAULT gen_random_uuid() NOT NULL PRIMARY KEY,
  component text NOT NULL,
  deviation_description text NOT NULL,
  rationale text NOT NULL,
  severity text DEFAULT 'minor'::text NOT NULL,
  resolved bool DEFAULT false,
  resolved_at timestamptz,
  created_at timestamptz DEFAULT now() NOT NULL
);

-- ============================================================
-- TABLE: tasks
-- ============================================================
CREATE TABLE IF NOT EXISTS public.tasks (
  id uuid DEFAULT gen_random_uuid() NOT NULL PRIMARY KEY,
  task_type text NOT NULL,
  objective text NOT NULL,
  state text DEFAULT 'created'::text NOT NULL,
  retry_count int4 DEFAULT 0 NOT NULL,
  max_retries int4 DEFAULT 3 NOT NULL,
  state_history jsonb DEFAULT '[]'::jsonb,
  constraints jsonb,
  result jsonb,
  assigned_to text,
  created_at timestamptz DEFAULT now() NOT NULL,
  updated_at timestamptz DEFAULT now() NOT NULL
);

-- ============================================================
-- Done. Proceed to 02_seed_data.sql
-- ============================================================
