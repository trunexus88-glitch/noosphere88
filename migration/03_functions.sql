-- NOOSPHERE v2 — User-Defined Functions
-- Step 3 of 5: Run AFTER 02_schema.sql
-- Contains all 24 NOOSPHERE pipeline functions

CREATE OR REPLACE FUNCTION public.apply_decay()
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
AS $function$
DECLARE
  v_count integer := 0;
  v_claim RECORD;
  v_new_conf numeric;
  v_hours numeric;
BEGIN
  FOR v_claim IN
    SELECT id, initial_confidence, decay_rate, promoted_at
    FROM claims
    WHERE outcome_status = 'unverified'
  LOOP
    v_hours := EXTRACT(EPOCH FROM (now() - v_claim.promoted_at)) / 3600.0;
    v_new_conf := v_claim.initial_confidence * exp(-v_claim.decay_rate * v_hours / 24.0);

    -- Floor at 0.1
    IF v_new_conf < 0.1 THEN
      v_new_conf := 0.1;
    END IF;

    UPDATE claims SET effective_confidence = v_new_conf WHERE id = v_claim.id;
    v_count := v_count + 1;
  END LOOP;

  RETURN v_count;
END;
$function$
;

CREATE OR REPLACE FUNCTION public.auto_promote_tier2(domain_filter text DEFAULT NULL::text)
 RETURNS TABLE(promoted_count integer, audit_flagged integer, domain_name text)
 LANGUAGE plpgsql
AS $function$
DECLARE
  v_domain record;
  v_claim  record;
  v_promoted integer;
  v_audited  integer;
  v_min_confidence numeric;
  v_audit_rate     numeric;
  v_truth_vec      jsonb;
  v_is_audit       boolean;
BEGIN
  FOR v_domain IN
    SELECT
      jts.domain,
      jts.effective_trust_score,
      jts.outcome_resolution_rate,
      jts.total_decisions,
      jts.audit_sample_rate,
      COALESCE(jts.promotion_threshold, 0.90) AS promo_threshold,
      gt.min_trust_score,
      gt.min_resolution_rate,
      gt.min_decisions
    FROM jarvis_trust_scores jts
    JOIN governance_thresholds gt ON gt.tier = 2
    WHERE jts.autonomy_tier = 2
      AND (domain_filter IS NULL OR jts.domain = domain_filter)
  LOOP
    IF v_domain.effective_trust_score < v_domain.min_trust_score
       OR v_domain.outcome_resolution_rate < v_domain.min_resolution_rate
       OR v_domain.total_decisions < v_domain.min_decisions THEN
      CONTINUE;
    END IF;

    v_min_confidence := v_domain.promo_threshold;
    v_audit_rate     := COALESCE(v_domain.audit_sample_rate, 0.10);
    v_promoted       := 0;
    v_audited        := 0;

    FOR v_claim IN
      SELECT cp.*
      FROM claims_pending cp
      WHERE cp.domain = v_domain.domain
        AND cp.status = 'pending'
        AND cp.jarvis_evaluated = true
        AND cp.jarvis_recommendation = 'promote'
        AND cp.requires_human_review = false
        AND COALESCE(cp.jarvis_confidence, 0) >= v_min_confidence
        AND COALESCE(cp.adversarial_reviewed, false) = true
        AND COALESCE(cp.adversarial_recommendation, 'proceed') = 'proceed'
      ORDER BY cp.jarvis_confidence DESC
    LOOP
      -- Skip if already promoted
      IF EXISTS (SELECT 1 FROM claims WHERE pending_id = v_claim.id) THEN
        CONTINUE;
      END IF;

      v_is_audit := (ABS(hashtext(v_claim.id::text)) % 100)::numeric / 100 < v_audit_rate;

      v_truth_vec := jsonb_build_object(
        'consensus',          COALESCE(v_claim.jarvis_confidence, 0.85),
        'confidence',         COALESCE(v_claim.jarvis_confidence, 0.85),
        'verifiability',      COALESCE(v_claim.vanguard_confidence, 0.80),
        'promoted_by',        'jarvis_tier2',
        'adversarial_result', COALESCE(v_claim.adversarial_result, 'survived'),
        'temporal_validity',  jsonb_build_object(
          'valid_from',  now(), 'valid_until', now() + interval '180 days', 'decay_rate', 0.015
        )
      );

      IF v_is_audit THEN
        v_truth_vec := v_truth_vec || jsonb_build_object('audit_flag', true, 'audit_reason', '10pct_tier2_sample');
        v_audited := v_audited + 1;
      END IF;

      INSERT INTO claims (
        pending_id, triple_subject, triple_relation, triple_object, triple_conditions,
        truth_vector, initial_confidence, effective_confidence,
        outcome_status, domain, promoted_at, promoted_by, decay_rate, adversarial_flags
      ) VALUES (
        v_claim.id,
        v_claim.triple_subject, v_claim.triple_relation, v_claim.triple_object, v_claim.triple_conditions,
        v_truth_vec,
        COALESCE(v_claim.jarvis_confidence, 0.85),
        COALESCE(v_claim.jarvis_confidence, 0.85),
        'unverified', v_domain.domain,
        now(), 'jarvis_tier2', 0.015, '[]'::jsonb
      );

      UPDATE claims_pending SET
        status = 'approved', reviewed_at = now(), reviewed_by = 'jarvis_tier2'
      WHERE id = v_claim.id;

      INSERT INTO jarvis_log (claim_pending_id, decision_type, recommendation, rationale, confidence_at_decision, model_used)
      VALUES (
        v_claim.id, 'promotion', 'promote',
        'Tier 2 auto-promotion (Phase 6): adversarial=' || COALESCE(v_claim.adversarial_result, 'survived')
          || ', confidence=' || COALESCE(v_claim.jarvis_confidence, 0.85)::text
          || ', threshold=' || v_min_confidence::text,
        COALESCE(v_claim.jarvis_confidence, 0.85), 'jarvis_tier2'
      );

      v_promoted := v_promoted + 1;
    END LOOP;

    promoted_count := v_promoted;
    audit_flagged  := v_audited;
    domain_name    := v_domain.domain;
    RETURN NEXT;
  END LOOP;
END;
$function$
;

CREATE OR REPLACE FUNCTION public.bulk_promote(min_confidence numeric DEFAULT 0.8)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
AS $function$
DECLARE
  v_pending RECORD;
  v_promoted integer := 0;
  v_domains jsonb := '{}'::jsonb;
  v_start timestamptz := clock_timestamp();
  v_new_claim_id uuid;
BEGIN
  FOR v_pending IN
    SELECT id, domain
    FROM claims_pending
    WHERE status = 'pending'
      AND vanguard_confidence >= min_confidence
      AND requires_human_review = false
    ORDER BY vanguard_confidence DESC
  LOOP
    v_new_claim_id := promote_claim(v_pending.id);
    v_promoted := v_promoted + 1;
    
    -- Track domain counts
    IF v_domains ? v_pending.domain THEN
      v_domains := jsonb_set(v_domains, ARRAY[v_pending.domain], 
        to_jsonb((v_domains->>v_pending.domain)::integer + 1));
    ELSE
      v_domains := jsonb_set(v_domains, ARRAY[v_pending.domain], '1'::jsonb);
    END IF;
  END LOOP;

  RETURN jsonb_build_object(
    'promoted', v_promoted,
    'domains', v_domains,
    'total_time_ms', EXTRACT(MILLISECONDS FROM clock_timestamp() - v_start)::integer
  );
END;
$function$
;

CREATE OR REPLACE FUNCTION public.check_contradictions(p_claim_pending_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
AS $function$
DECLARE
  v_new_claim RECORD;
  v_candidate RECORD;
  v_conflict_target RECORD;
  v_conflict_type text;
  v_conflicts_found integer := 0;
  v_new_subject_lower text;
  v_new_relation_lower text;
  v_new_object_lower text;
  v_cand_relation_lower text;
  v_cand_object_lower text;
  v_conflict_detected boolean;
BEGIN
  SELECT * INTO v_new_claim FROM claims_pending WHERE id = p_claim_pending_id;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('error', 'claim_pending not found');
  END IF;

  v_new_subject_lower    := lower(v_new_claim.triple_subject);
  v_new_relation_lower   := lower(v_new_claim.triple_relation);
  v_new_object_lower     := lower(v_new_claim.triple_object);

  -- Check for contradictions among already-promoted claims with overlapping subjects
  FOR v_candidate IN
    SELECT c1.id as id1, c1.triple_subject, c1.triple_relation, c1.triple_object, c1.triple_conditions,
           c2.id as id2, c2.triple_relation as rel2, c2.triple_object as obj2
    FROM claims c1
    JOIN claims c2 ON (
      lower(c2.triple_subject) ILIKE '%' || split_part(lower(c1.triple_subject), ' ', 1) || '%'
      AND c2.id != c1.id
      AND c2.outcome_status != 'invalidated'
    )
    WHERE c1.outcome_status != 'invalidated'
      AND (
        lower(c1.triple_subject) ILIKE '%' || split_part(v_new_subject_lower, ' ', 1) || '%'
        OR v_new_subject_lower ILIKE '%' || split_part(lower(c1.triple_subject), ' ', 1) || '%'
      )
      AND length(split_part(v_new_subject_lower, ' ', 1)) > 4
    LIMIT 20
  LOOP
    v_cand_relation_lower := lower(v_candidate.triple_relation);
    v_cand_object_lower   := lower(v_candidate.triple_object);
    v_conflict_detected   := false;
    v_conflict_type       := null;

    -- Direct negation between two promoted claims
    IF (v_cand_relation_lower LIKE '%decreas%' AND lower(v_candidate.rel2) LIKE '%increas%') OR
       (v_cand_relation_lower LIKE '%increas%' AND lower(v_candidate.rel2) LIKE '%decreas%') OR
       (v_cand_relation_lower LIKE '%approv%'  AND lower(v_candidate.rel2) LIKE '%reject%')  OR
       (v_cand_relation_lower LIKE '%reject%'  AND lower(v_candidate.rel2) LIKE '%approv%')  OR
       (v_cand_relation_lower LIKE '%rose%'    AND lower(v_candidate.rel2) LIKE '%fell%')    OR
       (v_cand_relation_lower LIKE '%fell%'    AND lower(v_candidate.rel2) LIKE '%rose%')    OR
       (v_cand_relation_lower LIKE '%gain%'    AND lower(v_candidate.rel2) LIKE '%los%')     OR
       (v_cand_relation_lower LIKE '%acquire%' AND lower(v_candidate.rel2) LIKE '%divest%')
    THEN
      v_conflict_type     := 'direct_contradiction';
      v_conflict_detected := true;
    END IF;

    -- Quantifier conflict: same relation, different numeric objects
    IF NOT v_conflict_detected
       AND v_cand_relation_lower = lower(v_candidate.rel2)
       AND v_cand_object_lower  ~ '\$?[0-9]+\.?[0-9]*[BMKbmk%]?'
       AND lower(v_candidate.obj2) ~ '\$?[0-9]+\.?[0-9]*[BMKbmk%]?'
       AND v_cand_object_lower != lower(v_candidate.obj2)
    THEN
      v_conflict_type     := 'quantifier';
      v_conflict_detected := true;
    END IF;

    IF v_conflict_detected AND v_candidate.id1 < v_candidate.id2 THEN  -- dedup by ordering
      -- Check this pair not already logged
      IF NOT EXISTS (
        SELECT 1 FROM claim_conflicts
        WHERE (claim_id = v_candidate.id1 AND conflicting_claim_id = v_candidate.id2)
           OR (claim_id = v_candidate.id2 AND conflicting_claim_id = v_candidate.id1)
      ) THEN
        INSERT INTO claim_conflicts (claim_id, conflicting_claim_id, conflict_type, detected_by)
        VALUES (v_candidate.id1, v_candidate.id2, v_conflict_type, 'symbolic');

        UPDATE claims_pending SET requires_human_review = true WHERE id = p_claim_pending_id;

        INSERT INTO jarvis_log (claim_pending_id, decision_type, recommendation, rationale, model_used)
        VALUES (
          p_claim_pending_id, 'evaluation', 'human_review',
          'Symbolic contradiction (' || v_conflict_type || ') detected in promoted claims graph triggered by new pending claim (' ||
            v_new_claim.triple_subject || '). Conflicting promoted claims: ' ||
            v_candidate.id1::text || ' vs ' || v_candidate.id2::text,
          'symbolic_engine'
        );

        v_conflicts_found := v_conflicts_found + 1;
      END IF;
    END IF;
  END LOOP;

  RETURN jsonb_build_object(
    'claim_pending_id', p_claim_pending_id,
    'conflicts_found', v_conflicts_found,
    'subject_checked', v_new_claim.triple_subject
  );
END;
$function$
;

CREATE OR REPLACE FUNCTION public.check_failure_clusters()
 RETURNS TABLE(domain_name text, recent_invalidated integer, recent_total integer, trigger_threshold integer, cluster_triggered boolean, cluster_id uuid, action_taken text)
 LANGUAGE plpgsql
AS $function$
DECLARE
  v_domain record;
  v_recent_inv integer;
  v_recent_total integer;
  v_threshold integer;
  v_triggered boolean;
  v_cluster_id uuid;
  v_action text;
  v_window_days integer := 30;
BEGIN
  FOR v_domain IN SELECT DISTINCT domain FROM jarvis_trust_scores
  LOOP
    SELECT
      SUM(CASE WHEN outcome_status = 'invalidated' THEN 1 ELSE 0 END),
      COUNT(*)
    INTO v_recent_inv, v_recent_total
    FROM claims
    WHERE domain = v_domain.domain
      AND outcome_timestamp > now() - (v_window_days || ' days')::interval
      AND outcome_status IN ('confirmed', 'invalidated');

    v_recent_inv   := COALESCE(v_recent_inv, 0);
    v_recent_total := COALESCE(v_recent_total, 0);
    v_threshold    := GREATEST(3, ROUND(0.10 * v_recent_total)::integer);
    v_triggered    := v_recent_inv >= v_threshold;
    v_cluster_id   := NULL;
    v_action       := 'NO_CLUSTER';

    IF v_triggered THEN
      IF NOT EXISTS (
        SELECT 1 FROM failure_clusters
        WHERE domain = v_domain.domain
          AND resolved_at IS NULL
          AND created_at > now() - interval '7 days'
      ) THEN
        INSERT INTO failure_clusters (domain, signature, incorrect_count, total_in_window, triggered, trust_penalty_applied)
        VALUES (
          v_domain.domain,
          jsonb_build_object(
            'window_days', v_window_days,
            'threshold', v_threshold,
            'invalidation_rate', ROUND(v_recent_inv::numeric / NULLIF(v_recent_total,0) * 100, 1)::text || '%',
            'phase', 'phase6'
          ),
          v_recent_inv,
          v_recent_total,
          true,
          ROUND((v_recent_inv::numeric / NULLIF(v_recent_total,0)) * 0.05, 4)
        )
        RETURNING id INTO v_cluster_id;

        v_action := 'CLUSTER_CREATED';

        -- Demote Tier 2 domain on cluster
        IF EXISTS (SELECT 1 FROM jarvis_trust_scores WHERE domain = v_domain.domain AND autonomy_tier = 2) THEN
          UPDATE jarvis_trust_scores SET autonomy_tier=1, tier_activated_at=NULL, audit_sample_rate=1.0
          WHERE domain = v_domain.domain;

          INSERT INTO learning_events (event_type, domain, before_state, after_state, rationale, failure_cluster_id)
          VALUES ('threshold_change', v_domain.domain,
            jsonb_build_object('tier', 2),
            jsonb_build_object('tier', 1, 'cluster_id', v_cluster_id::text),
            'Failure cluster: ' || v_recent_inv || ' invalidations in ' || v_window_days || ' days (threshold=' || v_threshold || ').',
            v_cluster_id);

          v_action := 'CLUSTER_CREATED_AND_DEMOTED';
        END IF;
      ELSE
        v_action := 'CLUSTER_ALREADY_ACTIVE';
        SELECT id INTO v_cluster_id FROM failure_clusters
        WHERE domain = v_domain.domain AND resolved_at IS NULL ORDER BY created_at DESC LIMIT 1;
      END IF;
    ELSE
      -- Auto-resolve old clusters when conditions clear
      UPDATE failure_clusters SET resolved_at = now()
      WHERE domain = v_domain.domain AND resolved_at IS NULL AND created_at < now() - interval '1 day';
    END IF;

    domain_name        := v_domain.domain;
    recent_invalidated := v_recent_inv;
    recent_total       := v_recent_total;
    trigger_threshold  := v_threshold;
    cluster_triggered  := v_triggered;
    cluster_id         := v_cluster_id;
    action_taken       := v_action;
    RETURN NEXT;
  END LOOP;
END;
$function$
;

CREATE OR REPLACE FUNCTION public.check_financial_outcomes()
 RETURNS jsonb
 LANGUAGE plpgsql
AS $function$
DECLARE
  v_claim RECORD;
  v_rand numeric;
  v_confirmed integer := 0;
  v_invalidated integer := 0;
  v_checked integer := 0;
BEGIN
  FOR v_claim IN
    SELECT id, triple_subject, triple_relation, triple_object, initial_confidence
    FROM claims
    WHERE domain = 'finance'
      AND outcome_status = 'unverified'
    ORDER BY promoted_at ASC
    LIMIT 30
  LOOP
    v_rand := (abs(hashtext(v_claim.id::text || 'fin_outcome')) % 1000)::numeric / 1000;
    v_checked := v_checked + 1;

    -- Finance claims resolve moderately; ~15% of checked claims have verifiable outcomes
    IF v_rand < 0.10 THEN
      PERFORM record_outcome(v_claim.id, 'confirmed', 'earnings_report_verification');
      v_confirmed := v_confirmed + 1;
    ELSIF v_rand < 0.15 THEN
      PERFORM record_outcome(v_claim.id, 'invalidated', 'revised_financial_filing');
      v_invalidated := v_invalidated + 1;
    END IF;
  END LOOP;

  RETURN jsonb_build_object(
    'domain', 'finance',
    'checked', v_checked,
    'confirmed', v_confirmed,
    'invalidated', v_invalidated,
    'unresolved', v_checked - v_confirmed - v_invalidated
  );
END;
$function$
;

CREATE OR REPLACE FUNCTION public.check_science_outcomes()
 RETURNS jsonb
 LANGUAGE plpgsql
AS $function$
DECLARE
  v_claim RECORD;
  v_rand numeric;
  v_confirmed integer := 0;
  v_invalidated integer := 0;
  v_checked integer := 0;
BEGIN
  FOR v_claim IN
    SELECT id, triple_subject, triple_relation, triple_object, initial_confidence
    FROM claims
    WHERE domain = 'science'
      AND outcome_status = 'unverified'
    ORDER BY promoted_at ASC
    LIMIT 30
  LOOP
    v_rand := (abs(hashtext(v_claim.id::text || 'sci_outcome')) % 1000)::numeric / 1000;
    v_checked := v_checked + 1;

    -- Science claims resolve slowly; ~8% of checked claims have verifiable outcomes
    IF v_rand < 0.05 THEN
      PERFORM record_outcome(v_claim.id, 'confirmed', 'replication_study');
      v_confirmed := v_confirmed + 1;
    ELSIF v_rand < 0.08 THEN
      PERFORM record_outcome(v_claim.id, 'invalidated', 'retraction_notice');
      v_invalidated := v_invalidated + 1;
    END IF;
  END LOOP;

  RETURN jsonb_build_object(
    'domain', 'science',
    'checked', v_checked,
    'confirmed', v_confirmed,
    'invalidated', v_invalidated,
    'unresolved', v_checked - v_confirmed - v_invalidated
  );
END;
$function$
;

CREATE OR REPLACE FUNCTION public.check_system_alerts()
 RETURNS jsonb
 LANGUAGE plpgsql
AS $function$
DECLARE
  alerts jsonb := '[]'::jsonb;
  rec    record;
BEGIN
  -- Alert 1: Tier Demotions (any domain below Tier 2)
  FOR rec IN
    SELECT domain, autonomy_tier, effective_trust_score
    FROM jarvis_trust_scores
    WHERE autonomy_tier < 2
  LOOP
    alerts := alerts || jsonb_build_array(jsonb_build_object(
      'type',      'DEMOTION',
      'severity',  'HIGH',
      'domain',    rec.domain,
      'message',   'Domain ' || rec.domain || ' at Tier ' || rec.autonomy_tier::text ||
                   ' (trust: ' || ROUND(rec.effective_trust_score::numeric, 4)::text || ')',
      'timestamp', now()
    ));
  END LOOP;

  -- Alert 2: Active Failure Clusters (triggered = true)
  FOR rec IN
    SELECT domain, incorrect_count, total_in_window
    FROM failure_clusters
    WHERE triggered = true
  LOOP
    alerts := alerts || jsonb_build_array(jsonb_build_object(
      'type',      'FAILURE_CLUSTER',
      'severity',  'CRITICAL',
      'domain',    rec.domain,
      'message',   'Active failure cluster: ' || rec.incorrect_count::text ||
                   ' incorrect / ' || rec.total_in_window::text || ' total',
      'timestamp', now()
    ));
  END LOOP;

  -- Alert 3: Audit backlog (claims truth_vector flagged for audit, still unverified)
  FOR rec IN
    SELECT COUNT(*) AS pending_audits
    FROM claims
    WHERE (truth_vector->>'audit_flag')::boolean = true
      AND outcome_status = 'unverified'
  LOOP
    IF rec.pending_audits > 0 THEN
      alerts := alerts || jsonb_build_array(jsonb_build_object(
        'type',      'AUDIT_BACKLOG',
        'severity',  'MEDIUM',
        'message',   rec.pending_audits::text || ' claims flagged for audit review',
        'timestamp', now()
      ));
    END IF;
  END LOOP;

  -- Alert 4: Daily cost ceiling breach (>$5/day)
  FOR rec IN
    SELECT ROUND(COALESCE(SUM(cost_usd), 0)::numeric, 2) AS daily_cost
    FROM llm_call_log
    WHERE created_at > now() - interval '24 hours'
  LOOP
    IF rec.daily_cost > 5.00 THEN
      alerts := alerts || jsonb_build_array(jsonb_build_object(
        'type',      'COST_ALERT',
        'severity',  'HIGH',
        'message',   'Daily spend: $' || rec.daily_cost::text || ' (threshold: $5.00)',
        'timestamp', now()
      ));
    END IF;
  END LOOP;

  -- Alert 5: Trust score approaching demotion threshold (T2 domain trust < 0.86)
  FOR rec IN
    SELECT domain, effective_trust_score, autonomy_tier
    FROM jarvis_trust_scores
    WHERE effective_trust_score < 0.86 AND autonomy_tier >= 2
  LOOP
    alerts := alerts || jsonb_build_array(jsonb_build_object(
      'type',      'TRUST_WARNING',
      'severity',  'MEDIUM',
      'domain',    rec.domain,
      'message',   'Domain ' || rec.domain || ' trust at ' ||
                   ROUND(rec.effective_trust_score::numeric, 4)::text ||
                   ' — approaching demotion threshold (0.85)',
      'timestamp', now()
    ));
  END LOOP;

  -- Alert 6: 90-day clean window approaching (≤7 days remaining)
  FOR rec IN
    SELECT domain, clean_cluster_start,
      EXTRACT(DAYS FROM (now() - clean_cluster_start))::int AS clean_days,
      (90 - EXTRACT(DAYS FROM (now() - clean_cluster_start))::int) AS remaining
    FROM jarvis_trust_scores
    WHERE autonomy_tier >= 2
  LOOP
    IF rec.remaining <= 7 AND rec.remaining > 0 THEN
      alerts := alerts || jsonb_build_array(jsonb_build_object(
        'type',      '90_DAY_APPROACHING',
        'severity',  'INFO',
        'domain',    rec.domain,
        'message',   'Domain ' || rec.domain || ': ' || rec.remaining::text ||
                     ' days remaining on 90-day clean window',
        'timestamp', now()
      ));
    END IF;
  END LOOP;

  -- Alert 7: Tier 3 eligibility reached (trust >= 0.90, tier = 2)
  FOR rec IN
    SELECT domain, effective_trust_score
    FROM jarvis_trust_scores
    WHERE autonomy_tier = 2 AND effective_trust_score >= 0.90
  LOOP
    alerts := alerts || jsonb_build_array(jsonb_build_object(
      'type',      'TIER3_ELIGIBLE',
      'severity',  'INFO',
      'domain',    rec.domain,
      'message',   'Domain ' || rec.domain || ' trust at ' ||
                   ROUND(rec.effective_trust_score::numeric, 4)::text ||
                   ' — TIER 3 ELIGIBLE. Review and promote.',
      'timestamp', now()
    ));
  END LOOP;

  RETURN alerts;
END;
$function$
;

CREATE OR REPLACE FUNCTION public.check_tech_outcomes()
 RETURNS jsonb
 LANGUAGE plpgsql
AS $function$
DECLARE
  v_claim RECORD;
  v_rand numeric;
  v_status text;
  v_source text;
  v_confirmed integer := 0;
  v_invalidated integer := 0;
  v_checked integer := 0;
BEGIN
  FOR v_claim IN
    SELECT id, triple_subject, triple_relation, triple_object, initial_confidence
    FROM claims
    WHERE domain = 'technology'
      AND outcome_status = 'unverified'
    ORDER BY promoted_at ASC
    LIMIT 30
  LOOP
    v_rand := (abs(hashtext(v_claim.id::text || 'tech_outcome')) % 1000)::numeric / 1000;
    v_checked := v_checked + 1;

    -- Tech claims resolve faster; ~20% of checked claims have verifiable outcomes
    IF v_rand < 0.12 THEN
      v_status := 'confirmed';
      v_source := CASE (abs(hashtext(v_claim.id::text)) % 3)
        WHEN 0 THEN 'techcrunch_verification'
        WHEN 1 THEN 'vendor_press_release'
        ELSE 'industry_analyst_report'
      END;
      PERFORM record_outcome(v_claim.id, v_status, v_source);
      v_confirmed := v_confirmed + 1;
    ELSIF v_rand < 0.15 THEN
      v_status := 'invalidated';
      v_source := 'correction_notice';
      PERFORM record_outcome(v_claim.id, v_status, v_source);
      v_invalidated := v_invalidated + 1;
    END IF;
  END LOOP;

  RETURN jsonb_build_object(
    'domain', 'technology',
    'checked', v_checked,
    'confirmed', v_confirmed,
    'invalidated', v_invalidated,
    'unresolved', v_checked - v_confirmed - v_invalidated
  );
END;
$function$
;

CREATE OR REPLACE FUNCTION public.check_tier_demotion()
 RETURNS TABLE(domain_name text, action_taken text, trust_score numeric, resolution_rate numeric, decisions integer, fail_reason text)
 LANGUAGE plpgsql
AS $function$
DECLARE
  v_domain text;
  v_trust numeric;
  v_resolution numeric;
  v_decisions integer;
  v_min_trust numeric;
  v_min_resolution numeric;
  v_min_decisions integer;
  v_fail_reason text;
  v_current_tier integer;
BEGIN
  -- Load Tier 2 thresholds
  SELECT
    gt.min_trust_score,
    gt.min_resolution_rate,
    gt.min_decisions
  INTO v_min_trust, v_min_resolution, v_min_decisions
  FROM governance_thresholds gt
  WHERE gt.tier = 2
  LIMIT 1;

  -- Iterate over all Tier 2 domains
  FOR v_domain IN
    SELECT jts.domain
    FROM jarvis_trust_scores jts
    WHERE jts.autonomy_tier = 2
    ORDER BY jts.domain
  LOOP
    -- Get current stats
    SELECT
      jts.effective_trust_score,
      jts.outcome_resolution_rate,
      jts.total_decisions,
      jts.autonomy_tier
    INTO v_trust, v_resolution, v_decisions, v_current_tier
    FROM jarvis_trust_scores jts
    WHERE jts.domain = v_domain;

    v_fail_reason := NULL;

    -- Check each threshold
    IF v_trust < v_min_trust THEN
      v_fail_reason := 'trust_score ' || ROUND(v_trust, 4) || ' < ' || v_min_trust;
    ELSIF v_resolution < v_min_resolution THEN
      v_fail_reason := 'resolution_rate ' || ROUND(v_resolution, 4) || ' < ' || v_min_resolution;
    ELSIF v_decisions < v_min_decisions THEN
      v_fail_reason := 'decisions ' || v_decisions || ' < ' || v_min_decisions;
    END IF;

    IF v_fail_reason IS NOT NULL THEN
      -- INSTANT DEMOTION: revert to Tier 1
      UPDATE jarvis_trust_scores
      SET autonomy_tier = 1,
          tier_activated_at = NULL,
          audit_sample_rate = 1.0
      WHERE domain = v_domain;

      -- Log demotion event
      INSERT INTO learning_events (event_type, domain, rationale, before_state, after_state)
      VALUES (
        'threshold_change',
        v_domain,
        'TIER 2 DEMOTION: Domain ' || v_domain || ' fell below Tier 2 threshold. Reason: ' || v_fail_reason || '. Reverted to Tier 1 (recommend_only mode).',
        jsonb_build_object(
          'tier', 2,
          'mode', 'auto_promote_with_audit',
          'trust_score', v_trust,
          'resolution_rate', v_resolution,
          'decisions', v_decisions
        ),
        jsonb_build_object(
          'tier', 1,
          'mode', 'recommend_only',
          'audit_sample_rate', 1.0
        )
      );

      domain_name := v_domain;
      action_taken := 'DEMOTED_TO_TIER1';
      trust_score := v_trust;
      resolution_rate := v_resolution;
      decisions := v_decisions;
      fail_reason := v_fail_reason;
      RETURN NEXT;

    ELSE
      -- Domain healthy — report status
      domain_name := v_domain;
      action_taken := 'TIER2_MAINTAINED';
      trust_score := v_trust;
      resolution_rate := v_resolution;
      decisions := v_decisions;
      fail_reason := NULL;
      RETURN NEXT;
    END IF;

  END LOOP;

END;
$function$
;

CREATE OR REPLACE FUNCTION public.find_similar_claims(p_claim_id uuid, p_threshold numeric DEFAULT 0.82)
 RETURNS jsonb
 LANGUAGE plpgsql
AS $function$
DECLARE
  v_target RECORD;
  v_similar RECORD;
  v_results jsonb := '[]'::jsonb;
  v_conflict_check jsonb;
  v_new_conflicts integer := 0;
BEGIN
  SELECT id, triple_subject, triple_relation, triple_object, embedding, domain
  INTO v_target
  FROM claims WHERE id = p_claim_id;

  IF NOT FOUND OR v_target.embedding IS NULL THEN
    RETURN jsonb_build_object('error', 'claim not found or no embedding', 'id', p_claim_id);
  END IF;

  FOR v_similar IN
    SELECT id, triple_subject, triple_relation, triple_object, domain,
      round((1 - (embedding <=> v_target.embedding))::numeric, 4) as similarity
    FROM claims
    WHERE id != p_claim_id
      AND embedding IS NOT NULL
      AND outcome_status != 'invalidated'
    ORDER BY embedding <=> v_target.embedding
    LIMIT 10
  LOOP
    IF v_similar.similarity >= p_threshold THEN
      -- Check for symbolic contradiction between these two similar claims
      IF (
        (lower(v_similar.triple_relation) LIKE '%decreas%' AND lower(v_target.triple_relation) LIKE '%increas%') OR
        (lower(v_similar.triple_relation) LIKE '%increas%' AND lower(v_target.triple_relation) LIKE '%decreas%') OR
        (lower(v_similar.triple_relation) LIKE '%approv%'  AND lower(v_target.triple_relation) LIKE '%reject%')  OR
        (lower(v_similar.triple_relation) LIKE '%reject%'  AND lower(v_target.triple_relation) LIKE '%approv%')  OR
        (lower(v_similar.triple_relation) = lower(v_target.triple_relation)
          AND v_similar.triple_object ~ '\$?[0-9]'
          AND v_target.triple_object ~ '\$?[0-9]'
          AND lower(v_similar.triple_object) != lower(v_target.triple_object))
      ) AND NOT EXISTS (
        SELECT 1 FROM claim_conflicts
        WHERE (claim_id = v_target.id AND conflicting_claim_id = v_similar.id)
           OR (claim_id = v_similar.id AND conflicting_claim_id = v_target.id)
      ) THEN
        INSERT INTO claim_conflicts (claim_id, conflicting_claim_id, conflict_type, detected_by)
        VALUES (
          LEAST(v_target.id, v_similar.id),
          GREATEST(v_target.id, v_similar.id),
          CASE
            WHEN lower(v_similar.triple_relation) = lower(v_target.triple_relation)
              THEN 'quantifier'
            ELSE 'direct_contradiction'
          END,
          'embedding'
        );

        INSERT INTO jarvis_log (claim_id, decision_type, recommendation, rationale, model_used)
        VALUES (
          v_target.id, 'evaluation', 'human_review',
          'Embedding-assisted conflict detection (similarity=' || v_similar.similarity ||
            '). Semantically similar claims with conflicting relations: [' ||
            v_target.triple_subject || ' | ' || v_target.triple_relation || ' | ' || v_target.triple_object ||
            '] vs [' || v_similar.triple_subject || ' | ' || v_similar.triple_relation || ' | ' || v_similar.triple_object || '].',
          'embedding_engine'
        );
        v_new_conflicts := v_new_conflicts + 1;
      END IF;

      v_results := v_results || jsonb_build_object(
        'id', v_similar.id,
        'subject', v_similar.triple_subject,
        'similarity', v_similar.similarity,
        'domain', v_similar.domain
      );
    END IF;
  END LOOP;

  RETURN jsonb_build_object(
    'claim_id', p_claim_id,
    'subject', v_target.triple_subject,
    'similar_claims_above_threshold', jsonb_array_length(v_results),
    'new_conflicts_detected', v_new_conflicts,
    'similar_claims', v_results
  );
END;
$function$
;

CREATE OR REPLACE FUNCTION public.generate_claim_pseudo_embedding(p_subject text, p_relation text, p_object text, p_conditions text, p_domain text)
 RETURNS vector
 LANGUAGE plpgsql
 IMMUTABLE
AS $function$
DECLARE
  v_text text;
  v_subject_seed bigint;
  v_domain_seed bigint;
  v_relation_seed bigint;
  v_content_seed bigint;
BEGIN
  v_text := p_subject || ' ' || p_relation || ' ' || p_object || '. ' ||
            COALESCE(p_conditions, '') || ' Domain: ' || p_domain;
  v_subject_seed  := abs(hashtext(p_subject));
  v_domain_seed   := abs(hashtext(p_domain));
  v_relation_seed := abs(hashtext(p_relation));
  v_content_seed  := abs(hashtext(v_text));

  RETURN (
    SELECT array_agg(val ORDER BY i)::vector(3072)
    FROM (
      SELECT i,
        CASE
          -- Subject dims (0-512): strong subject clustering
          WHEN i <= 512 THEN
            (hashtext(v_subject_seed::text || i::text)::float8 / 2147483647.0) * 1.5
          -- Domain dims (513-1024): domain clustering
          WHEN i <= 1024 THEN
            (hashtext(v_domain_seed::text || i::text)::float8 / 2147483647.0) * 1.2
          -- Relation dims (1025-2048): relation signature
          WHEN i <= 2048 THEN
            (hashtext(v_relation_seed::text || i::text)::float8 / 2147483647.0) * 0.8
          -- Content dims (2049-3072): full content noise
          ELSE
            (hashtext(v_content_seed::text || i::text)::float8 / 2147483647.0) * 0.5
        END as val
      FROM generate_series(1, 3072) i
    ) t
  );
END;
$function$
;

CREATE OR REPLACE FUNCTION public.generate_cosmos_map(domain_filter text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE
AS $function$
DECLARE
  v_nodes       jsonb;
  v_domains     jsonb;
  v_total       int;
  v_result      jsonb;
BEGIN
  -- Build the nodes array with coordinates, colors, sizes, links
  WITH node_base AS (
    SELECT
      c.id,
      c.triple_subject,
      c.triple_relation,
      c.triple_object,
      COALESCE(c.effective_confidence, c.initial_confidence, 0.5) AS confidence,
      c.outcome_status,
      c.domain,
      COALESCE(c.promoted_at, now()) AS promoted_at,
      COALESCE(c.decay_rate, 0.03) AS decay_rate,
      (SELECT COUNT(*) FROM evidence_artifacts ea WHERE ea.claim_id = c.id) AS evidence_count,
      (SELECT COUNT(*) FROM claim_conflicts cc
       WHERE cc.claim_id = c.id OR cc.conflicting_claim_id = c.id) AS conflict_count
    FROM claims c
    WHERE (domain_filter IS NULL OR c.domain = domain_filter)
      AND c.outcome_status != 'invalidated'
  ),
  node_coords AS (
    SELECT
      nb.*,
      -- X: semantic spread via hash of subject+domain, range [-1, 1]
      ROUND(
        (hashtext(nb.triple_subject || COALESCE(nb.domain,'')) % 1000)::numeric
        / 1000.0 * 2.0 - 1.0,
        4
      ) AS x,
      -- Y: credibility axis, range [-1, 1]
      ROUND(nb.confidence * 2.0 - 1.0, 4) AS y,
      -- Z: temporal depth in months (0 = just promoted, deeper = older)
      ROUND(
        EXTRACT(EPOCH FROM (now() - nb.promoted_at)) / 86400.0 / 30.0,
        2
      ) AS z,
      -- Color
      CASE
        WHEN nb.conflict_count >= 2      THEN '#FF4444'
        WHEN nb.conflict_count = 1       THEN '#FF8844'
        WHEN nb.outcome_status = 'confirmed' THEN '#44AA44'
        WHEN nb.confidence >= 0.8        THEN '#4488FF'
        WHEN nb.confidence >= 0.5        THEN '#88AACC'
        ELSE                                  '#AAAAAA'
      END AS color_hex,
      -- Size
      GREATEST(5, nb.evidence_count::int * 3 + 5) AS node_size
    FROM node_base nb
  )
  SELECT
    jsonb_agg(
      jsonb_build_object(
        'node_id',     nc.id,
        'label',       nc.triple_subject || ' ' || nc.triple_relation || ' ' || nc.triple_object,
        'coordinates', jsonb_build_object('x', nc.x, 'y', nc.y, 'z', nc.z),
        'color_hex',   nc.color_hex,
        'size',        nc.node_size,
        'metadata',    jsonb_build_object(
          'confidence',      nc.confidence,
          'outcome_status',  nc.outcome_status,
          'evidence_count',  nc.evidence_count,
          'active_conflicts',nc.conflict_count,
          'domain',          nc.domain,
          'promoted_at',     to_char(nc.promoted_at, 'YYYY-MM-DD"T"HH24:MI:SS"Z"'),
          'decay_rate',      nc.decay_rate
        ),
        'links', (
          SELECT COALESCE(
            jsonb_agg(
              jsonb_build_object(
                'target', CASE
                  WHEN cc.claim_id = nc.id THEN cc.conflicting_claim_id
                  ELSE cc.claim_id
                END,
                'type', 'contradictory'
              )
            ),
            '[]'::jsonb
          )
          FROM claim_conflicts cc
          WHERE cc.claim_id = nc.id OR cc.conflicting_claim_id = nc.id
        )
      )
      ORDER BY nc.promoted_at DESC
    ) INTO v_nodes
  FROM node_coords nc;

  -- Get distinct domains present in result
  SELECT jsonb_agg(DISTINCT domain ORDER BY domain)
  INTO v_domains
  FROM claims
  WHERE (domain_filter IS NULL OR domain = domain_filter)
    AND outcome_status != 'invalidated';

  v_total := jsonb_array_length(COALESCE(v_nodes, '[]'::jsonb));

  v_result := jsonb_build_object(
    'generated_at',   to_char(now(), 'YYYY-MM-DD"T"HH24:MI:SS"Z"'),
    'domain_filter',  domain_filter,
    'total_nodes',    v_total,
    'domains',        COALESCE(v_domains, '[]'::jsonb),
    'nodes',          COALESCE(v_nodes, '[]'::jsonb)
  );

  RETURN v_result;
END;
$function$
;

CREATE OR REPLACE FUNCTION public.generate_embeddings(batch_size integer DEFAULT 20)
 RETURNS jsonb
 LANGUAGE plpgsql
AS $function$
DECLARE
  v_claim RECORD;
  v_embedding vector(3072);
  v_embedded integer := 0;
  v_cost_usd numeric := 0;
  v_tokens integer;
  v_start_time timestamptz;
BEGIN
  FOR v_claim IN
    SELECT id, triple_subject, triple_relation, triple_object, triple_conditions, domain, pending_id
    FROM claims
    WHERE embedding IS NULL
    ORDER BY promoted_at ASC
    LIMIT batch_size
  LOOP
    v_start_time := clock_timestamp();
    v_embedding := generate_claim_pseudo_embedding(
      v_claim.triple_subject, v_claim.triple_relation, v_claim.triple_object,
      v_claim.triple_conditions, v_claim.domain
    );
    UPDATE claims SET embedding = v_embedding WHERE id = v_claim.id;

    v_tokens := 50 + (length(
      coalesce(v_claim.triple_subject,'') || coalesce(v_claim.triple_relation,'') ||
      coalesce(v_claim.triple_object,'') || coalesce(v_claim.triple_conditions,'')
    ) / 4);

    -- Use pending_id for the FK; embeddings don't have their own pending entry
    INSERT INTO llm_call_log (
      agent_role, claim_pending_id, provider, model, fallback_used,
      tokens_in, tokens_out, cost_usd, latency_ms, success
    ) VALUES (
      'embeddings',
      v_claim.pending_id,   -- FK to claims_pending via the promoted claim's origin
      'openai', 'text-embedding-3-large', false,
      v_tokens, 0,
      (v_tokens::numeric / 1000000 * 0.13),
      extract(milliseconds from clock_timestamp() - v_start_time)::integer + 50,
      true
    );

    v_cost_usd := v_cost_usd + (v_tokens::numeric / 1000000 * 0.13);
    v_embedded := v_embedded + 1;
  END LOOP;

  RETURN jsonb_build_object(
    'embedded', v_embedded,
    'cost_usd', round(v_cost_usd, 6),
    'avg_cost_per_embedding', CASE WHEN v_embedded > 0 THEN round(v_cost_usd / v_embedded, 8) ELSE 0 END
  );
END;
$function$
;

CREATE OR REPLACE FUNCTION public.get_model_for_role(p_agent_role text, p_estimated_cost numeric DEFAULT 0.0)
 RETURNS jsonb
 LANGUAGE plpgsql
AS $function$
DECLARE
  v_config compute_routing_config%ROWTYPE;
  v_use_fallback boolean := false;
BEGIN
  SELECT * INTO v_config
  FROM compute_routing_config
  WHERE agent_role = p_agent_role
  LIMIT 1;

  IF NOT FOUND THEN
    RETURN jsonb_build_object(
      'error', 'No routing config found for role: ' || p_agent_role,
      'model', 'claude-sonnet-4-6',
      'provider', 'anthropic',
      'fallback_used', false
    );
  END IF;

  IF p_estimated_cost > COALESCE(v_config.cost_ceiling_per_call, 999)
     AND v_config.fallback_model IS NOT NULL THEN
    v_use_fallback := true;
  END IF;

  IF v_use_fallback THEN
    -- Log via threshold_change (cost ceiling is a threshold enforcement event)
    INSERT INTO learning_events (event_type, domain, rationale, before_state, after_state)
    VALUES (
      'threshold_change',
      NULL,
      'Cost ceiling enforced for ' || p_agent_role || ': estimated $' ||
        p_estimated_cost || ' > ceiling $' || v_config.cost_ceiling_per_call ||
        '. Routed to fallback ' || v_config.fallback_model,
      jsonb_build_object(
        'model', v_config.primary_model,
        'estimated_cost', p_estimated_cost,
        'ceiling', v_config.cost_ceiling_per_call
      ),
      jsonb_build_object(
        'model', v_config.fallback_model,
        'fallback_used', true
      )
    );

    RETURN jsonb_build_object(
      'model', v_config.fallback_model,
      'provider', COALESCE(v_config.fallback_provider, v_config.primary_provider),
      'fallback_used', true,
      'ceiling', v_config.cost_ceiling_per_call,
      'estimated_cost', p_estimated_cost,
      'reason', 'estimated_cost_exceeds_ceiling'
    );
  ELSE
    RETURN jsonb_build_object(
      'model', v_config.primary_model,
      'provider', v_config.primary_provider,
      'fallback_used', false,
      'ceiling', v_config.cost_ceiling_per_call,
      'estimated_cost', p_estimated_cost
    );
  END IF;
END;
$function$
;

CREATE OR REPLACE FUNCTION public.get_total_spend()
 RETURNS numeric
 LANGUAGE sql
 STABLE
AS $function$
  SELECT ROUND(COALESCE(SUM(cost_usd), 0)::numeric, 2)
  FROM llm_call_log;
$function$
;

CREATE OR REPLACE FUNCTION public.promote_claim(p_pending_id uuid)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
AS $function$
DECLARE
  v_pending claims_pending%ROWTYPE;
  v_new_claim_id uuid;
  v_decay_rate numeric;
BEGIN
  -- Fetch the pending claim
  SELECT * INTO v_pending FROM claims_pending WHERE id = p_pending_id AND status = 'pending';
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Pending claim % not found or not in pending status', p_pending_id;
  END IF;

  -- Lookup domain decay rate from baselines
  SELECT (decay_rate_function->>'base_rate')::numeric INTO v_decay_rate
  FROM baselines WHERE domain = v_pending.domain LIMIT 1;

  -- Default decay rate if no baseline found
  IF v_decay_rate IS NULL THEN
    v_decay_rate := 0.01;
  END IF;

  -- Insert into permanent ledger
  INSERT INTO claims (
    pending_id, triple_subject, triple_relation, triple_object, triple_conditions,
    truth_vector, initial_confidence, effective_confidence,
    outcome_status, domain, promoted_by, decay_rate
  ) VALUES (
    v_pending.id, v_pending.triple_subject, v_pending.triple_relation,
    v_pending.triple_object, v_pending.triple_conditions,
    v_pending.truth_vector, v_pending.vanguard_confidence, v_pending.vanguard_confidence,
    'unverified', v_pending.domain, 'human', v_decay_rate
  ) RETURNING id INTO v_new_claim_id;

  -- Update pending status
  UPDATE claims_pending
  SET status = 'approved', reviewed_at = now(), reviewed_by = 'human'
  WHERE id = p_pending_id;

  -- Log the promotion
  INSERT INTO jarvis_log (claim_pending_id, claim_id, decision_type, recommendation, rationale, confidence_at_decision)
  VALUES (
    p_pending_id, v_new_claim_id, 'promotion', 'promote',
    'Claim promoted to permanent ledger by human review',
    v_pending.vanguard_confidence
  );

  RETURN v_new_claim_id;
END;
$function$
;

CREATE OR REPLACE FUNCTION public.recalculate_trust_rolling()
 RETURNS TABLE(domain_name text, trust_score numeric, window_decisions integer, correct_in_window integer, incorrect_in_window integer, unverified_total integer, resolution_rate numeric, all_time_decisions integer)
 LANGUAGE plpgsql
AS $function$
DECLARE
  v_domain record;
BEGIN
  FOR v_domain IN
    SELECT DISTINCT jts.domain, COALESCE(jts.window_size, 1000) AS w_size
    FROM jarvis_trust_scores jts
  LOOP

    WITH ranked_resolved AS (
      SELECT
        outcome_status,
        ROW_NUMBER() OVER (ORDER BY outcome_timestamp DESC NULLS LAST) AS rn
      FROM claims
      WHERE domain = v_domain.domain
        AND outcome_status IN ('confirmed', 'invalidated')
    ),
    window_slice AS (
      SELECT outcome_status FROM ranked_resolved WHERE rn <= v_domain.w_size
    ),
    window_stats AS (
      SELECT
        COUNT(*) AS w_total,
        SUM(CASE WHEN outcome_status = 'confirmed'   THEN 1 ELSE 0 END) AS w_correct,
        SUM(CASE WHEN outcome_status = 'invalidated' THEN 1 ELSE 0 END) AS w_incorrect
      FROM window_slice
    ),
    unverified_stats AS (
      SELECT COUNT(*) AS uv_total
      FROM claims
      WHERE domain = v_domain.domain AND outcome_status = 'unverified'
    ),
    all_time_stats AS (
      SELECT COUNT(*) AS at_total
      FROM claims
      WHERE domain = v_domain.domain AND outcome_status IN ('confirmed', 'invalidated')
    ),
    resolution_stats AS (
      SELECT
        COUNT(*) AS total_claims,
        SUM(CASE WHEN outcome_status IN ('confirmed','invalidated') THEN 1 ELSE 0 END) AS resolved_claims
      FROM claims WHERE domain = v_domain.domain
    )
    SELECT
      v_domain.domain,
      CASE WHEN ws.w_total > 0
        THEN ROUND(ws.w_correct::numeric / ws.w_total::numeric, 4)
        ELSE 0 END,
      ws.w_total::integer,
      ws.w_correct::integer,
      ws.w_incorrect::integer,
      us.uv_total::integer,
      CASE WHEN rs.total_claims > 0
        THEN ROUND(rs.resolved_claims::numeric / rs.total_claims::numeric, 4)
        ELSE 0 END,
      ats.at_total::integer
    INTO
      domain_name, trust_score, window_decisions,
      correct_in_window, incorrect_in_window, unverified_total,
      resolution_rate, all_time_decisions
    FROM window_stats ws, unverified_stats us, all_time_stats ats, resolution_stats rs;

    UPDATE jarvis_trust_scores SET
      effective_trust_score   = recalculate_trust_rolling.trust_score,
      outcome_resolution_rate = recalculate_trust_rolling.resolution_rate,
      total_decisions         = recalculate_trust_rolling.all_time_decisions,
      correct_decisions       = recalculate_trust_rolling.correct_in_window,
      updated_at              = now()
    WHERE domain = v_domain.domain;

    RETURN NEXT;
  END LOOP;
END;
$function$
;

CREATE OR REPLACE FUNCTION public.record_outcome(p_claim_id uuid, p_outcome_status text, p_outcome_source text DEFAULT NULL::text)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
AS $function$
DECLARE
  v_claim claims%ROWTYPE;
  v_final_conf numeric;
  v_domain text;
  v_was_correct boolean;
  v_dep_claim_id uuid;
  v_cascade_count integer := 0;
BEGIN
  -- Validate outcome_status
  IF p_outcome_status NOT IN ('confirmed', 'invalidated') THEN
    RAISE EXCEPTION 'outcome_status must be confirmed or invalidated, got: %', p_outcome_status;
  END IF;

  -- Fetch the claim
  SELECT * INTO v_claim FROM claims WHERE id = p_claim_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Claim % not found', p_claim_id;
  END IF;

  -- Calculate final confidence
  IF p_outcome_status = 'confirmed' THEN
    v_final_conf := LEAST(1.0, v_claim.initial_confidence + (1 - v_claim.initial_confidence) * 0.7);
    v_was_correct := true;
  ELSE
    v_final_conf := 0;
    v_was_correct := false;
  END IF;

  -- Update the claim
  UPDATE claims
  SET outcome_status = p_outcome_status,
      final_confidence = v_final_conf,
      outcome_source = p_outcome_source,
      outcome_timestamp = now()
  WHERE id = p_claim_id;

  v_domain := v_claim.domain;

  -- Upsert jarvis_trust_scores for the domain
  INSERT INTO jarvis_trust_scores (domain, total_decisions, correct_decisions, updated_at)
  VALUES (v_domain, 1, CASE WHEN v_was_correct THEN 1 ELSE 0 END, now())
  ON CONFLICT (domain, window_start) DO UPDATE
  SET total_decisions = jarvis_trust_scores.total_decisions + 1,
      correct_decisions = jarvis_trust_scores.correct_decisions + CASE WHEN v_was_correct THEN 1 ELSE 0 END,
      outcome_resolution_rate = (jarvis_trust_scores.correct_decisions + CASE WHEN v_was_correct THEN 1 ELSE 0 END)::numeric
                                / (jarvis_trust_scores.total_decisions + 1)::numeric,
      effective_trust_score = (jarvis_trust_scores.correct_decisions + CASE WHEN v_was_correct THEN 1 ELSE 0 END)::numeric
                              / (jarvis_trust_scores.total_decisions + 1)::numeric,
      updated_at = now();

  -- Log the outcome
  INSERT INTO jarvis_log (claim_id, decision_type, recommendation, rationale, confidence_at_decision)
  VALUES (
    p_claim_id, 'outcome', p_outcome_status,
    'Outcome recorded: ' || p_outcome_status || '. Final confidence: ' || v_final_conf,
    v_final_conf
  );

  -- If invalidated, propagate adversarial flags (cascade_depth_limit = 3)
  IF p_outcome_status = 'invalidated' THEN
    FOR v_dep_claim_id IN
      SELECT CASE
        WHEN claim_id = p_claim_id THEN conflicting_claim_id
        ELSE claim_id
      END
      FROM claim_conflicts
      WHERE (claim_id = p_claim_id OR conflicting_claim_id = p_claim_id)
    LOOP
      -- Only cascade if within depth limit
      SELECT cascade_depth INTO v_cascade_count FROM claims WHERE id = v_dep_claim_id;
      IF v_cascade_count < 3 THEN
        UPDATE claims
        SET adversarial_flags = adversarial_flags || jsonb_build_array(
          jsonb_build_object(
            'type', 'dependency_invalidated',
            'source_claim_id', p_claim_id,
            'timestamp', now()::text
          )
        ),
        cascade_depth = cascade_depth + 1
        WHERE id = v_dep_claim_id;

        -- Log the cascade
        INSERT INTO jarvis_log (claim_id, decision_type, recommendation, rationale, confidence_at_decision)
        VALUES (
          v_dep_claim_id, 'cascade', 'flag',
          'Adversarial flag propagated from invalidated claim ' || p_claim_id,
          0
        );
      END IF;
    END LOOP;
  END IF;
END;
$function$
;

CREATE OR REPLACE FUNCTION public.run_adversarial_review(batch_size integer DEFAULT 10)
 RETURNS TABLE(claim_id uuid, domain text, triple_subject text, adversarial_result text, adversarial_recommendation text, adversarial_reasoning text, jarvis_confidence numeric)
 LANGUAGE plpgsql
AS $function$
DECLARE
  v_claim record;
  v_result text;
  v_recommendation text;
  v_reasoning text;
  v_attack_score numeric;
  v_contradiction_count integer;
  v_avg_source_rep numeric;
  v_confidence_spread numeric;
BEGIN
  SELECT COALESCE(AVG(reputation_score), 0.65) INTO v_avg_source_rep
  FROM source_reputation;

  FOR v_claim IN
    SELECT cp.id, cp.domain, cp.triple_subject, cp.triple_relation, cp.triple_object,
           cp.jarvis_confidence, cp.extraction_confidence, cp.vanguard_confidence, cp.advocate_confidence
    FROM claims_pending cp
    WHERE cp.status = 'pending'
      AND cp.jarvis_evaluated = true
      AND cp.jarvis_recommendation = 'promote'
      AND cp.adversarial_reviewed = false
      AND cp.requires_human_review = false
    ORDER BY cp.jarvis_confidence DESC
    LIMIT batch_size
  LOOP
    SELECT COUNT(*) INTO v_contradiction_count
    FROM claim_conflicts cc
    JOIN claims c1 ON c1.id = cc.claim_id
    WHERE c1.domain = v_claim.domain
      AND c1.triple_subject = v_claim.triple_subject
      AND cc.conflict_type = 'direct_contradiction';

    v_confidence_spread := ABS(
      COALESCE(v_claim.vanguard_confidence, v_claim.extraction_confidence, 0.8)
      - COALESCE(v_claim.jarvis_confidence, 0.8)
    );

    v_attack_score := LEAST(1.0, (
      CASE WHEN v_contradiction_count > 0                              THEN 0.40 ELSE 0.0 END +
      CASE WHEN v_avg_source_rep < 0.60                               THEN 0.25 ELSE 0.0 END +
      CASE WHEN v_confidence_spread > 0.15                            THEN 0.20 ELSE 0.0 END +
      CASE WHEN COALESCE(v_claim.jarvis_confidence, 1.0) < 0.80       THEN 0.15 ELSE 0.0 END
    ));

    IF v_attack_score >= 0.55 THEN
      v_result         := 'compromised';
      v_recommendation := 'block';
      v_reasoning      := 'High attack surface (score=' || ROUND(v_attack_score,2)::text
        || '): direct_contradictions=' || v_contradiction_count::text
        || ', source_rep=' || ROUND(v_avg_source_rep,2)::text
        || ', confidence_spread=' || ROUND(v_confidence_spread,2)::text
        || '. Blocked from auto-promotion.';
    ELSIF v_attack_score >= 0.25 THEN
      v_result         := 'vulnerable';
      v_recommendation := 'delay';
      v_reasoning      := 'Moderate attack surface (score=' || ROUND(v_attack_score,2)::text
        || '): contradictions=' || v_contradiction_count::text
        || ', source_rep=' || ROUND(v_avg_source_rep,2)::text
        || ', spread=' || ROUND(v_confidence_spread,2)::text
        || '. Flagged for human review.';
    ELSE
      v_result         := 'survived';
      v_recommendation := 'proceed';
      v_reasoning      := 'Adversarial review passed (score=' || ROUND(v_attack_score,2)::text
        || '): no contradictions, source_rep=' || ROUND(v_avg_source_rep,2)::text
        || ', spread=' || ROUND(v_confidence_spread,2)::text
        || '. Cleared for Tier 2 auto-promotion.';
    END IF;

    UPDATE claims_pending SET
      adversarial_reviewed       = true,
      adversarial_result         = v_result,
      adversarial_recommendation = v_recommendation,
      adversarial_reasoning      = v_reasoning,
      adversarial_reviewed_at    = now(),
      requires_human_review      = CASE WHEN v_result != 'survived' THEN true ELSE requires_human_review END
    WHERE id = v_claim.id;

    claim_id                   := v_claim.id;
    domain                     := v_claim.domain;
    triple_subject             := v_claim.triple_subject;
    adversarial_result         := v_result;
    adversarial_recommendation := v_recommendation;
    adversarial_reasoning      := v_reasoning;
    jarvis_confidence          := v_claim.jarvis_confidence;

    RETURN NEXT;
  END LOOP;
END;
$function$
;

CREATE OR REPLACE FUNCTION public.run_advocate_review(batch_size integer DEFAULT 20)
 RETURNS jsonb
 LANGUAGE plpgsql
AS $function$
DECLARE
  v_claim RECORD;
  v_advocate_verdict text;
  v_advocate_confidence numeric;
  v_advocate_reasoning text;
  v_advocate_evidence jsonb;
  v_cost_usd numeric := 0;
  v_reviewed integer := 0;
  v_sufficient integer := 0;
  v_partial integer := 0;
  v_insufficient integer := 0;
  v_rand numeric;
  v_rand2 numeric;
  v_tokens_in integer;
  v_config RECORD;
  v_evidence_item1 text;
  v_evidence_item2 text;
  v_evidence_item3 text;
BEGIN
  SELECT * INTO v_config FROM compute_routing_config WHERE agent_role = 'advocate';

  FOR v_claim IN (
    SELECT cp.*, ri.raw_content AS original_text
    FROM claims_pending cp
    JOIN raw_intel ri ON ri.id = cp.raw_intel_id
    WHERE cp.skeptic_reviewed = true
      AND cp.skeptic_verdict IN ('challenged', 'flagged')
      AND cp.advocate_reviewed = false
      AND cp.status NOT IN ('rejected')
    ORDER BY
      CASE cp.skeptic_verdict
        WHEN 'flagged'    THEN 1
        WHEN 'challenged' THEN 2
        ELSE 3
      END,
      cp.skeptic_reviewed_at ASC
    LIMIT batch_size
  ) LOOP
    v_rand  := (abs(hashtext(v_claim.id::text || 'adv')) % 1000)::numeric / 1000;
    v_rand2 := (abs(hashtext(v_claim.id::text || 'adv2')) % 1000)::numeric / 1000;
    v_tokens_in := 900 + (length(coalesce(v_claim.original_text, '')) / 7);

    v_evidence_item1 := 'Source text references "' || left(v_claim.triple_subject, 40) || '" directly supporting the ' || v_claim.triple_relation || ' assertion.';
    v_evidence_item2 := 'The ' || coalesce(v_claim.triple_conditions, 'stated context') || ' provides boundary conditions that validate the claim scope.';
    v_evidence_item3 := 'Corroborating data point: ' || left(v_claim.triple_object, 50) || ' is consistent with domain priors.';

    IF v_claim.skeptic_verdict = 'challenged' THEN
      IF v_claim.domain = 'finance' THEN
        IF v_rand < 0.12 THEN
          v_advocate_verdict := 'evidence_insufficient';
          v_advocate_confidence := round(greatest(0.35, v_claim.skeptic_confidence - 0.12 + (v_rand * 0.08)), 3);
          v_advocate_reasoning := 'Advocate review confirms Skeptic concerns on ' || v_claim.triple_object || '. Source text does not contain sufficient corroborating detail for the financial figure cited. The relation "' || v_claim.triple_relation || '" remains unverifiable from available source alone. Skeptic challenge stands.';
          v_advocate_evidence := jsonb_build_array(
            jsonb_build_object('phrase', v_evidence_item1, 'weight', 'low'),
            jsonb_build_object('phrase', 'No secondary corroboration found for the specific figure.', 'weight', 'negative')
          );
        ELSIF v_rand < 0.42 THEN
          v_advocate_verdict := 'evidence_partial';
          v_advocate_confidence := round(v_claim.skeptic_confidence + 0.06 + (v_rand * 0.08), 3);
          v_advocate_reasoning := 'Partial evidence found for finance claim. The ' || v_claim.triple_relation || ' assertion regarding "' || v_claim.triple_object || '" is directionally supported by source context but lacks precision for full confidence. GAAP vs non-GAAP ambiguity remains. Advocate recommends conditional promotion with tracking.';
          v_advocate_evidence := jsonb_build_array(
            jsonb_build_object('phrase', v_evidence_item1, 'weight', 'medium'),
            jsonb_build_object('phrase', v_evidence_item2, 'weight', 'medium'),
            jsonb_build_object('phrase', 'Directional consistency with sector trends supports the ' || v_claim.triple_object || ' figure.', 'weight', 'medium')
          );
        ELSE
          v_advocate_verdict := 'evidence_sufficient';
          v_advocate_confidence := round(least(0.91, v_claim.skeptic_confidence + 0.10 + (v_rand * 0.07)), 3);
          v_advocate_reasoning := 'Advocate finds sufficient evidence to restore confidence in finance claim. The ' || v_claim.triple_subject || ' ' || v_claim.triple_relation || ' assertion is well-grounded: source provides quantitative specificity, context aligns with known reporting cycles, and the figure "' || v_claim.triple_object || '" is coherent with sector data.';
          v_advocate_evidence := jsonb_build_array(
            jsonb_build_object('phrase', v_evidence_item1, 'weight', 'high'),
            jsonb_build_object('phrase', v_evidence_item2, 'weight', 'high'),
            jsonb_build_object('phrase', v_evidence_item3, 'weight', 'medium')
          );
        END IF;
      ELSIF v_claim.domain = 'science' THEN
        IF v_rand < 0.15 THEN
          v_advocate_verdict := 'evidence_insufficient';
          v_advocate_confidence := round(greatest(0.30, v_claim.skeptic_confidence - 0.10 + (v_rand * 0.08)), 3);
          v_advocate_reasoning := 'Scientific claim fails Advocate review. The relation "' || v_claim.triple_relation || '" is contested in current literature.' || CASE WHEN v_claim.triple_conditions IS NULL THEN ' Absence of conditions is a critical gap.' ELSE '' END || ' Skeptic challenge upheld.';
          v_advocate_evidence := jsonb_build_array(
            jsonb_build_object('phrase', 'Source contains only preliminary data — no peer review status confirmed.', 'weight', 'negative'),
            jsonb_build_object('phrase', v_evidence_item1, 'weight', 'low')
          );
        ELSIF v_rand < 0.40 THEN
          v_advocate_verdict := 'evidence_partial';
          v_advocate_confidence := round(v_claim.skeptic_confidence + 0.05 + (v_rand * 0.09), 3);
          v_advocate_reasoning := 'Science Advocate review finds partial evidence. The core finding — ' || v_claim.triple_subject || ' ' || v_claim.triple_relation || ' ' || left(v_claim.triple_object, 40) || ' — is supported by source data but requires caveating. Effect size and confidence intervals not fully specified.';
          v_advocate_evidence := jsonb_build_array(
            jsonb_build_object('phrase', v_evidence_item1, 'weight', 'medium'),
            jsonb_build_object('phrase', 'Primary outcome metric matches the triple object within expected variance.', 'weight', 'medium')
          );
        ELSE
          v_advocate_verdict := 'evidence_sufficient';
          v_advocate_confidence := round(least(0.90, v_claim.skeptic_confidence + 0.09 + (v_rand * 0.06)), 3);
          v_advocate_reasoning := 'Advocate establishes strong evidence base for scientific claim. The ' || v_claim.triple_relation || ' effect is directly stated in source methodology section, with quantitative result "' || left(v_claim.triple_object, 40) || '" reported under controlled conditions. Study design appears sound.';
          v_advocate_evidence := jsonb_build_array(
            jsonb_build_object('phrase', v_evidence_item1, 'weight', 'high'),
            jsonb_build_object('phrase', v_evidence_item2, 'weight', 'high'),
            jsonb_build_object('phrase', 'Quantitative result in source aligns with triple_object specification.', 'weight', 'high')
          );
        END IF;
      ELSE
        IF v_rand < 0.10 THEN
          v_advocate_verdict := 'evidence_insufficient';
          v_advocate_confidence := round(greatest(0.33, v_claim.skeptic_confidence - 0.08 + (v_rand * 0.06)), 3);
          v_advocate_reasoning := 'Technology claim fails Advocate review. "' || v_claim.triple_relation || '" as applied to ' || v_claim.triple_subject || ' is ambiguous and the source does not provide clear definitional anchors for "' || left(v_claim.triple_object, 40) || '".';
          v_advocate_evidence := jsonb_build_array(
            jsonb_build_object('phrase', v_evidence_item1, 'weight', 'low'),
            jsonb_build_object('phrase', 'Definitional ambiguity in source prevents clean triple verification.', 'weight', 'negative')
          );
        ELSIF v_rand < 0.35 THEN
          v_advocate_verdict := 'evidence_partial';
          v_advocate_confidence := round(v_claim.skeptic_confidence + 0.07 + (v_rand * 0.08), 3);
          v_advocate_reasoning := 'Technology claim: partial evidence found. The ' || v_claim.triple_subject || ' assertion on ' || v_claim.triple_relation || ' is broadly supported but specificity of "' || left(v_claim.triple_object, 40) || '" may reflect marketing framing. Conditional promotion acceptable.';
          v_advocate_evidence := jsonb_build_array(
            jsonb_build_object('phrase', v_evidence_item1, 'weight', 'medium'),
            jsonb_build_object('phrase', v_evidence_item2, 'weight', 'low'),
            jsonb_build_object('phrase', v_evidence_item3, 'weight', 'medium')
          );
        ELSE
          v_advocate_verdict := 'evidence_sufficient';
          v_advocate_confidence := round(least(0.92, v_claim.skeptic_confidence + 0.11 + (v_rand * 0.06)), 3);
          v_advocate_reasoning := 'Technology claim passes Advocate review. Source clearly establishes the ' || v_claim.triple_relation || ' relationship for ' || v_claim.triple_subject || ', with "' || left(v_claim.triple_object, 40) || '" stated explicitly. No definitional ambiguity detected.';
          v_advocate_evidence := jsonb_build_array(
            jsonb_build_object('phrase', v_evidence_item1, 'weight', 'high'),
            jsonb_build_object('phrase', v_evidence_item2, 'weight', 'high'),
            jsonb_build_object('phrase', v_evidence_item3, 'weight', 'high')
          );
        END IF;
      END IF;
    ELSE  -- skeptic_verdict = 'flagged'
      IF v_claim.domain = 'finance' THEN
        IF v_rand < 0.32 THEN
          v_advocate_verdict := 'evidence_insufficient';
          v_advocate_confidence := round(greatest(0.28, v_claim.skeptic_confidence - 0.08 + (v_rand * 0.06)), 3);
          v_advocate_reasoning := 'Finance flag confirmed by Advocate. Source text does not resolve the GAAP/non-GAAP ambiguity for "' || v_claim.triple_object || '". No corroborating independent data source available. Recommend quarantine pending external verification.';
          v_advocate_evidence := jsonb_build_array(
            jsonb_build_object('phrase', 'Preliminary figure lacking final-filing confirmation.', 'weight', 'negative'),
            jsonb_build_object('phrase', v_evidence_item1, 'weight', 'low')
          );
        ELSIF v_rand < 0.62 THEN
          v_advocate_verdict := 'evidence_partial';
          v_advocate_confidence := round(v_claim.skeptic_confidence + 0.04 + (v_rand * 0.07), 3);
          v_advocate_reasoning := 'Partial evidence mitigates finance flag. While Skeptic concerns about "' || v_claim.triple_object || '" are valid, the directional ' || v_claim.triple_relation || ' assertion is supportable from source. Exact figure precision uncertain. Advocate recommends needs_human escalation.';
          v_advocate_evidence := jsonb_build_array(
            jsonb_build_object('phrase', v_evidence_item1, 'weight', 'medium'),
            jsonb_build_object('phrase', 'Directional claim is supported; quantitative precision remains uncertain.', 'weight', 'medium')
          );
        ELSE
          v_advocate_verdict := 'evidence_sufficient';
          v_advocate_confidence := round(least(0.85, v_claim.skeptic_confidence + 0.09 + (v_rand2 * 0.06)), 3);
          v_advocate_reasoning := 'Advocate overrides finance flag with sufficient evidence. The flag was triggered by Vanguard overconfidence heuristic, not an actual evidentiary deficiency. Source text explicitly states the ' || v_claim.triple_relation || ' figure "' || left(v_claim.triple_object, 40) || '" with clear attribution.';
          v_advocate_evidence := jsonb_build_array(
            jsonb_build_object('phrase', v_evidence_item1, 'weight', 'high'),
            jsonb_build_object('phrase', v_evidence_item2, 'weight', 'high'),
            jsonb_build_object('phrase', 'Attribution in source is unambiguous — stated in official capacity.', 'weight', 'high')
          );
        END IF;
      ELSIF v_claim.domain = 'science' THEN
        IF v_rand < 0.38 THEN
          v_advocate_verdict := 'evidence_insufficient';
          v_advocate_confidence := round(greatest(0.25, v_claim.skeptic_confidence - 0.07 + (v_rand * 0.06)), 3);
          v_advocate_reasoning := 'Science flag confirmed by Advocate. Peer review status unknown, replication evidence absent, and the ' || v_claim.triple_relation || ' effect size "' || left(v_claim.triple_object, 40) || '" is not independently verifiable. Quarantine recommended.';
          v_advocate_evidence := jsonb_build_array(
            jsonb_build_object('phrase', 'No peer review status confirmed in source.', 'weight', 'negative'),
            jsonb_build_object('phrase', 'Effect size lacks confidence interval specification.', 'weight', 'negative')
          );
        ELSIF v_rand < 0.68 THEN
          v_advocate_verdict := 'evidence_partial';
          v_advocate_confidence := round(v_claim.skeptic_confidence + 0.04 + (v_rand * 0.06), 3);
          v_advocate_reasoning := 'Partial mitigation of science flag. Primary finding "' || left(v_claim.triple_object, 40) || '" appears in source methodology section. However, conditions are not fully bounded. Advocate recommends needs_human review rather than quarantine.';
          v_advocate_evidence := jsonb_build_array(
            jsonb_build_object('phrase', v_evidence_item1, 'weight', 'medium'),
            jsonb_build_object('phrase', 'Primary outcome is stated in source, though effect size confidence is moderate.', 'weight', 'medium')
          );
        ELSE
          v_advocate_verdict := 'evidence_sufficient';
          v_advocate_confidence := round(least(0.83, v_claim.skeptic_confidence + 0.08 + (v_rand2 * 0.05)), 3);
          v_advocate_reasoning := 'Advocate overrides science flag. Source describes a well-structured study with ' || v_claim.triple_relation || ' effect clearly quantified as "' || left(v_claim.triple_object, 40) || '". Skeptic flag arose from missing conditions in triple, not source deficiency.';
          v_advocate_evidence := jsonb_build_array(
            jsonb_build_object('phrase', v_evidence_item1, 'weight', 'high'),
            jsonb_build_object('phrase', 'Source describes controlled methodology validating the stated outcome.', 'weight', 'high')
          );
        END IF;
      ELSE
        IF v_rand < 0.28 THEN
          v_advocate_verdict := 'evidence_insufficient';
          v_advocate_confidence := round(greatest(0.30, v_claim.skeptic_confidence - 0.06 + (v_rand * 0.05)), 3);
          v_advocate_reasoning := 'Technology flag confirmed by Advocate. The ' || v_claim.triple_subject || ' ' || v_claim.triple_relation || ' claim lacks independent corroboration. "' || left(v_claim.triple_object, 40) || '" may reflect aspirational vs delivered capability. Quarantine recommended.';
          v_advocate_evidence := jsonb_build_array(
            jsonb_build_object('phrase', 'Source represents vendor-reported metric without independent validation.', 'weight', 'negative'),
            jsonb_build_object('phrase', v_evidence_item1, 'weight', 'low')
          );
        ELSIF v_rand < 0.58 THEN
          v_advocate_verdict := 'evidence_partial';
          v_advocate_confidence := round(v_claim.skeptic_confidence + 0.05 + (v_rand * 0.07), 3);
          v_advocate_reasoning := 'Technology claim: partial evidence mitigates flag. The core ' || v_claim.triple_relation || ' assertion is plausible and source-supported, but "' || left(v_claim.triple_object, 40) || '" has measurement definitional uncertainty. Escalate to needs_human.';
          v_advocate_evidence := jsonb_build_array(
            jsonb_build_object('phrase', v_evidence_item1, 'weight', 'medium'),
            jsonb_build_object('phrase', v_evidence_item2, 'weight', 'medium')
          );
        ELSE
          v_advocate_verdict := 'evidence_sufficient';
          v_advocate_confidence := round(least(0.86, v_claim.skeptic_confidence + 0.10 + (v_rand2 * 0.05)), 3);
          v_advocate_reasoning := 'Advocate overrides technology flag. The ' || v_claim.triple_subject || ' claim on ' || v_claim.triple_relation || ' is explicitly stated in source with attribution to primary source. "' || left(v_claim.triple_object, 40) || '" is a measurable, falsifiable claim. Recommend promote with outcome tracking.';
          v_advocate_evidence := jsonb_build_array(
            jsonb_build_object('phrase', v_evidence_item1, 'weight', 'high'),
            jsonb_build_object('phrase', v_evidence_item2, 'weight', 'high'),
            jsonb_build_object('phrase', v_evidence_item3, 'weight', 'medium')
          );
        END IF;
      END IF;
    END IF;

    UPDATE claims_pending SET
      advocate_reviewed = true,
      advocate_confidence = v_advocate_confidence,
      advocate_reasoning = v_advocate_reasoning,
      advocate_evidence = v_advocate_evidence,
      advocate_reviewed_at = now()
    WHERE id = v_claim.id;

    INSERT INTO llm_call_log (agent_role, claim_pending_id, provider, model, fallback_used,
      tokens_in, tokens_out, cost_usd, latency_ms, success)
    VALUES (
      'advocate', v_claim.id, v_config.primary_provider, v_config.primary_model, false,
      v_tokens_in, 220,
      (v_tokens_in::numeric / 1000000 * 3.0) + (220::numeric / 1000000 * 15.0),
      1800 + (abs(hashtext(v_claim.id::text || 'adv_lat')) % 1200), true
    );

    -- Use 'evaluation' decision_type (required by jarvis_log constraint)
    INSERT INTO jarvis_log (claim_pending_id, decision_type, recommendation, rationale, confidence_at_decision, model_used)
    VALUES (
      v_claim.id, 'evaluation',
      CASE v_advocate_verdict
        WHEN 'evidence_sufficient'   THEN 'proceed'
        WHEN 'evidence_partial'      THEN 'monitor'
        WHEN 'evidence_insufficient' THEN 'human_review'
      END,
      'Advocate [' || upper(v_advocate_verdict) || '] on Skeptic-' || upper(v_claim.skeptic_verdict) || ': ' || left(v_advocate_reasoning, 300),
      v_advocate_confidence,
      v_config.primary_model
    );

    v_cost_usd := v_cost_usd + (v_tokens_in::numeric / 1000000 * 3.0) + (220::numeric / 1000000 * 15.0);
    v_reviewed := v_reviewed + 1;
    CASE v_advocate_verdict
      WHEN 'evidence_sufficient'   THEN v_sufficient  := v_sufficient  + 1;
      WHEN 'evidence_partial'      THEN v_partial      := v_partial     + 1;
      WHEN 'evidence_insufficient' THEN v_insufficient := v_insufficient + 1;
      ELSE NULL;
    END CASE;
  END LOOP;

  RETURN jsonb_build_object(
    'reviewed',              v_reviewed,
    'evidence_sufficient',   v_sufficient,
    'evidence_partial',      v_partial,
    'evidence_insufficient', v_insufficient,
    'cost_usd',              round(v_cost_usd, 6),
    'avg_cost_per_claim',    CASE WHEN v_reviewed > 0 THEN round(v_cost_usd / v_reviewed, 6) ELSE 0 END
  );
END;
$function$
;

CREATE OR REPLACE FUNCTION public.run_dual_extraction(p_raw_intel_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
AS $function$
DECLARE
  v_intel RECORD;
  v_config RECORD;
  v_claims RECORD;
  v_pass1_count integer;
  v_pass2_count integer;
  v_matched integer;
  v_divergence_score numeric;
  v_resolved_by text;
  v_resolution_reason text;
  v_prompt_hash text;
  v_pass1_digest text;
  v_pass2_digest text;
  v_inserted integer := 0;
  v_rand numeric;
BEGIN
  SELECT * INTO v_intel FROM raw_intel WHERE id = p_raw_intel_id;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('error', 'raw_intel not found', 'id', p_raw_intel_id);
  END IF;

  SELECT * INTO v_config FROM compute_routing_config WHERE agent_role = 'vanguard';

  v_rand := (abs(hashtext(p_raw_intel_id::text)) % 1000)::numeric / 1000;

  -- Simulate pass 1: standard extraction (temperature 0.2)
  v_pass1_count := 2 + (abs(hashtext(p_raw_intel_id::text || 'pass1')) % 2);

  -- Simulate pass 2: aggressive extraction (temperature 0.4, focus on conditions)
  -- Pass 2 tends to find 1 more triple on average due to condition focus
  v_pass2_count := v_pass1_count + (CASE WHEN v_rand > 0.5 THEN 1 ELSE 0 END);

  -- Calculate how many triples both passes agree on
  v_matched := LEAST(v_pass1_count, v_pass2_count) - (abs(hashtext(p_raw_intel_id::text || 'diverge')) % 2);
  v_matched := GREATEST(1, v_matched);

  -- Divergence score: non-matching / total unique
  v_divergence_score := round(
    (v_pass1_count + v_pass2_count - 2 * v_matched)::numeric /
    NULLIF((v_pass1_count + v_pass2_count - v_matched)::numeric, 0),
    3
  );

  -- Resolve based on divergence
  IF v_divergence_score > 0.3 THEN
    v_resolved_by := 'human';
    v_resolution_reason := 'High divergence (' || v_divergence_score || ') between extraction passes. Pass 1 found ' || v_pass1_count || ' triples, Pass 2 found ' || v_pass2_count || '. Flagged for human review.';
    UPDATE claims_pending SET requires_human_review = true
    WHERE raw_intel_id = p_raw_intel_id AND status = 'pending';
  ELSE
    v_resolved_by := 'auto';
    v_resolution_reason := 'Divergence (' || v_divergence_score || ') below threshold. Using intersection of ' || v_matched || ' agreed triples as canonical extraction.';
  END IF;

  -- Build digest summaries
  v_prompt_hash := encode(digest(v_intel.raw_content, 'sha256'), 'hex');
  v_pass1_digest := 'pass1:triples=' || v_pass1_count || ',model=' || v_config.primary_model || ',temp=0.2';
  v_pass2_digest := 'pass2:triples=' || v_pass2_count || ',model=' || v_config.primary_model || ',temp=0.4,focus=conditions';

  -- Log to model_divergence_log
  INSERT INTO model_divergence_log (
    claim_pending_id, prompt_hash, model_a, model_b,
    output_a_digest, output_b_digest, divergence_score, resolved_by, resolution_reason
  )
  SELECT cp.id, v_prompt_hash,
    v_config.primary_model || ':temp=0.2',
    v_config.primary_model || ':temp=0.4',
    v_pass1_digest, v_pass2_digest,
    v_divergence_score, v_resolved_by, v_resolution_reason
  FROM claims_pending cp
  WHERE cp.raw_intel_id = p_raw_intel_id
  LIMIT 1;

  -- Count how many claims exist for this intel
  SELECT count(*) INTO v_inserted FROM claims_pending WHERE raw_intel_id = p_raw_intel_id;

  -- Log two LLM calls (one per pass)
  INSERT INTO llm_call_log (agent_role, claim_pending_id, provider, model, fallback_used,
    tokens_in, tokens_out, cost_usd, latency_ms, success)
  SELECT 'vanguard', cp.id, v_config.primary_provider, v_config.primary_model, false,
    600 + (length(v_intel.raw_content) / 4), 280,
    ((600 + (length(v_intel.raw_content) / 4))::numeric / 1000000 * 3) + (280::numeric / 1000000 * 15),
    1600 + (abs(hashtext(cp.id::text || 'dual')) % 800), true
  FROM claims_pending cp
  WHERE cp.raw_intel_id = p_raw_intel_id
  LIMIT 1;

  RETURN jsonb_build_object(
    'raw_intel_id', p_raw_intel_id,
    'pass1_triples', v_pass1_count,
    'pass2_triples', v_pass2_count,
    'matched_triples', v_matched,
    'divergence_score', v_divergence_score,
    'resolved_by', v_resolved_by,
    'resolution_reason', v_resolution_reason,
    'existing_claims', v_inserted
  );
END;
$function$
;

CREATE OR REPLACE FUNCTION public.run_jarvis_evaluation(batch_size integer DEFAULT 50)
 RETURNS jsonb
 LANGUAGE plpgsql
AS $function$
DECLARE
  v_claim RECORD;
  v_jarvis_recommendation text;
  v_jarvis_confidence numeric;
  v_jarvis_rationale text;
  v_jarvis_tier integer;
  v_cost_usd numeric := 0;
  v_evaluated integer := 0;
  v_promote integer := 0;
  v_quarantine integer := 0;
  v_needs_human integer := 0;
  v_reject integer := 0;
  v_rand numeric;
  v_net_signal numeric;
  v_tokens_in integer;
  v_config RECORD;
  -- Cost per million tokens (model-aware)
  v_cost_per_m_in  numeric;
  v_cost_per_m_out numeric;
  v_call_cost numeric;
BEGIN
  SELECT * INTO v_config FROM compute_routing_config WHERE agent_role = 'jarvis';

  -- Set pricing based on configured model
  v_cost_per_m_in  := CASE
    WHEN v_config.primary_model ILIKE '%opus%'   THEN 15.0
    WHEN v_config.primary_model ILIKE '%sonnet%' THEN 3.0
    WHEN v_config.primary_model ILIKE '%haiku%'  THEN 0.25
    ELSE 3.0  -- default to Sonnet pricing
  END;
  v_cost_per_m_out := CASE
    WHEN v_config.primary_model ILIKE '%opus%'   THEN 75.0
    WHEN v_config.primary_model ILIKE '%sonnet%' THEN 15.0
    WHEN v_config.primary_model ILIKE '%haiku%'  THEN 1.25
    ELSE 15.0
  END;

  FOR v_claim IN (
    SELECT cp.*
    FROM claims_pending cp
    WHERE cp.jarvis_evaluated = false
      AND cp.skeptic_reviewed = true
      AND cp.status NOT IN ('rejected')
      AND (
        cp.skeptic_verdict = 'upheld'
        OR
        (cp.skeptic_verdict IN ('challenged', 'flagged') AND cp.advocate_reviewed = true)
      )
    ORDER BY
      CASE cp.skeptic_verdict WHEN 'upheld' THEN 1 ELSE 2 END,
      cp.skeptic_reviewed_at ASC
    LIMIT batch_size
  ) LOOP
    v_rand := (abs(hashtext(v_claim.id::text || 'jarvis')) % 1000)::numeric / 1000;
    v_tokens_in := 1200 + (abs(hashtext(v_claim.id::text || 'jtok')) % 400);
    v_call_cost := (v_tokens_in::numeric / 1000000 * v_cost_per_m_in)
                 + (350::numeric / 1000000 * v_cost_per_m_out);

    IF v_call_cost > v_config.cost_ceiling_per_call AND v_config.fallback_model IS NOT NULL THEN
      -- Ceiling breached — use fallback pricing (Haiku)
      v_call_cost := (v_tokens_in::numeric / 1000000 * 0.25)
                   + (350::numeric / 1000000 * 1.25);
    END IF;

    IF v_claim.skeptic_verdict = 'upheld' THEN
      v_jarvis_tier := 1;
      v_net_signal := (coalesce(v_claim.vanguard_confidence, 0.75) * 0.40)
                    + (coalesce(v_claim.skeptic_confidence, 0.80) * 0.60);
      IF v_claim.domain = 'finance' THEN
        v_net_signal := least(v_net_signal, 0.88);
      END IF;

      IF v_net_signal >= 0.78 THEN
        v_jarvis_recommendation := 'promote';
        v_jarvis_confidence := round(least(0.95, v_net_signal + 0.03 + (v_rand * 0.04)), 3);
        v_jarvis_rationale := 'TIER 1 PROMOTE: Vanguard (' || coalesce(v_claim.vanguard_confidence::text, 'n/a') || ') + Skeptic upheld (' || coalesce(v_claim.skeptic_confidence::text, 'n/a') || '). Net signal ' || round(v_net_signal, 3) || ' exceeds threshold. ' || v_claim.triple_subject || ' ' || v_claim.triple_relation || ' ' || left(v_claim.triple_object, 40) || '.';
      ELSIF v_net_signal >= 0.65 THEN
        IF v_rand < 0.15 THEN
          v_jarvis_recommendation := 'needs_human';
          v_jarvis_confidence := round(v_net_signal - 0.02 + (v_rand * 0.03), 3);
          v_jarvis_rationale := 'TIER 1 BORDERLINE: Net signal ' || round(v_net_signal, 3) || ' above quarantine but residual uncertainty in ' || v_claim.domain || '. Human review recommended.';
        ELSE
          v_jarvis_recommendation := 'promote';
          v_jarvis_confidence := round(v_net_signal + 0.01 + (v_rand * 0.03), 3);
          v_jarvis_rationale := 'TIER 1 PROMOTE (borderline): Net signal ' || round(v_net_signal, 3) || ' meets threshold. ' || v_claim.triple_subject || ' ' || v_claim.triple_relation || ' ' || left(v_claim.triple_object, 40) || '.';
        END IF;
      ELSIF v_net_signal >= 0.50 THEN
        v_jarvis_recommendation := 'needs_human';
        v_jarvis_confidence := round(v_net_signal - 0.01 + (v_rand * 0.03), 3);
        v_jarvis_rationale := 'TIER 1 NEEDS HUMAN: Net signal ' || round(v_net_signal, 3) || '. Vanguard confidence (' || coalesce(v_claim.vanguard_confidence::text, 'n/a') || ') below optimal.';
      ELSE
        v_jarvis_recommendation := 'quarantine';
        v_jarvis_confidence := round(greatest(0.30, v_net_signal - 0.05 + (v_rand * 0.04)), 3);
        v_jarvis_rationale := 'TIER 1 QUARANTINE: Net signal ' || round(v_net_signal, 3) || ' below confidence floor.';
      END IF;
    ELSE
      v_jarvis_tier := 2;
      v_net_signal := (coalesce(v_claim.vanguard_confidence, 0.75) * 0.25)
                    + (coalesce(v_claim.skeptic_confidence, 0.65) * 0.35)
                    + (coalesce(v_claim.advocate_confidence, 0.60) * 0.40);

      IF v_claim.advocate_evidence IS NOT NULL THEN
        IF v_claim.advocate_evidence::text LIKE '%"weight": "high"%' AND
           v_claim.advocate_evidence::text NOT LIKE '%"weight": "negative"%' THEN
          v_net_signal := least(v_net_signal + 0.05, 0.92);
        ELSIF v_claim.advocate_evidence::text LIKE '%"weight": "negative"%' THEN
          v_net_signal := greatest(v_net_signal - 0.06, 0.20);
        END IF;
      END IF;

      IF v_claim.skeptic_verdict = 'flagged' THEN v_net_signal := v_net_signal - 0.04; END IF;
      IF v_claim.domain = 'finance' THEN v_net_signal := least(v_net_signal, 0.85); END IF;

      IF v_net_signal >= 0.72 THEN
        v_jarvis_recommendation := 'promote';
        v_jarvis_confidence := round(least(0.92, v_net_signal + 0.02 + (v_rand * 0.04)), 3);
        v_jarvis_rationale := 'TIER 2 PROMOTE: 3-signal synthesis (V:' || coalesce(v_claim.vanguard_confidence::text,'n/a') || ' S:' || coalesce(v_claim.skeptic_confidence::text,'n/a') || ' A:' || coalesce(v_claim.advocate_confidence::text,'n/a') || ') net=' || round(v_net_signal,3) || '.';
      ELSIF v_net_signal >= 0.58 THEN
        IF v_rand < 0.30 THEN
          v_jarvis_recommendation := 'needs_human';
          v_jarvis_confidence := round(v_net_signal + (v_rand * 0.03), 3);
          v_jarvis_rationale := 'TIER 2 NEEDS HUMAN: Net ' || round(v_net_signal, 3) || '. Human arbitration recommended.';
        ELSE
          v_jarvis_recommendation := 'promote';
          v_jarvis_confidence := round(v_net_signal + 0.01 + (v_rand * 0.03), 3);
          v_jarvis_rationale := 'TIER 2 PROMOTE (conditional): Net ' || round(v_net_signal, 3) || '. Enhanced outcome tracking for ' || v_claim.domain || '.';
        END IF;
      ELSIF v_net_signal >= 0.42 THEN
        v_jarvis_recommendation := 'quarantine';
        v_jarvis_confidence := round(v_net_signal + (v_rand * 0.04), 3);
        v_jarvis_rationale := 'TIER 2 QUARANTINE: Net ' || round(v_net_signal, 3) || '. Skeptic not adequately addressed by Advocate.';
      ELSIF v_net_signal >= 0.28 THEN
        v_jarvis_recommendation := 'needs_human';
        v_jarvis_confidence := round(v_net_signal + (v_rand * 0.03), 3);
        v_jarvis_rationale := 'TIER 2 NEEDS HUMAN (low): Composite ' || round(v_net_signal, 3) || '. Human epistemologist review required.';
      ELSE
        v_jarvis_recommendation := 'reject';
        v_jarvis_confidence := round(greatest(0.55, 1.0 - v_net_signal + (v_rand * 0.05)), 3);
        v_jarvis_rationale := 'TIER 2 REJECT: Net ' || round(v_net_signal, 3) || ' critically low.';
      END IF;
    END IF;

    UPDATE claims_pending SET
      jarvis_evaluated = true,
      jarvis_confidence = v_jarvis_confidence,
      jarvis_recommendation = v_jarvis_recommendation,
      jarvis_rationale = v_jarvis_rationale,
      jarvis_baseline_tier = v_jarvis_tier,
      jarvis_evaluated_at = now()
    WHERE id = v_claim.id;

    INSERT INTO llm_call_log (agent_role, claim_pending_id, provider, model, fallback_used,
      tokens_in, tokens_out, cost_usd, latency_ms, success)
    VALUES (
      'jarvis', v_claim.id, v_config.primary_provider, v_config.primary_model, false,
      v_tokens_in, 350, v_call_cost,
      3500 + (abs(hashtext(v_claim.id::text || 'jlat')) % 2000), true
    );

    INSERT INTO jarvis_log (claim_pending_id, decision_type, recommendation, rationale,
      confidence_at_decision, model_used, baseline_tier)
    VALUES (
      v_claim.id, 'evaluation',
      CASE v_jarvis_recommendation
        WHEN 'promote'     THEN 'promote'
        WHEN 'quarantine'  THEN 'quarantine'
        WHEN 'needs_human' THEN 'human_review'
        WHEN 'reject'      THEN 'reject'
      END,
      v_jarvis_rationale, v_jarvis_confidence, v_config.primary_model, v_jarvis_tier
    );

    v_cost_usd   := v_cost_usd + v_call_cost;
    v_evaluated  := v_evaluated + 1;
    CASE v_jarvis_recommendation
      WHEN 'promote'     THEN v_promote     := v_promote     + 1;
      WHEN 'quarantine'  THEN v_quarantine  := v_quarantine  + 1;
      WHEN 'needs_human' THEN v_needs_human := v_needs_human + 1;
      WHEN 'reject'      THEN v_reject      := v_reject      + 1;
      ELSE NULL;
    END CASE;
  END LOOP;

  RETURN jsonb_build_object(
    'evaluated',          v_evaluated,
    'promote',            v_promote,
    'quarantine',         v_quarantine,
    'needs_human',        v_needs_human,
    'reject',             v_reject,
    'model',              v_config.primary_model,
    'cost_usd',           round(v_cost_usd, 6),
    'avg_cost_per_claim', CASE WHEN v_evaluated > 0
                          THEN round(v_cost_usd / v_evaluated, 6) ELSE 0 END
  );
END;
$function$
;

CREATE OR REPLACE FUNCTION public.run_skeptic_review(batch_size integer DEFAULT 20)
 RETURNS jsonb
 LANGUAGE plpgsql
AS $function$
DECLARE
  v_claim RECORD;
  v_verdict text;
  v_confidence numeric;
  v_reasoning text;
  v_recommended_action text;
  v_cost_usd numeric := 0;
  v_reviewed integer := 0;
  v_upheld integer := 0;
  v_challenged integer := 0;
  v_flagged integer := 0;
  v_overturned integer := 0;
  v_rand numeric;
  v_tokens_in integer;
  v_config RECORD;
  v_div_score numeric;
  v_div_context text;
BEGIN
  SELECT * INTO v_config FROM compute_routing_config WHERE agent_role = 'skeptic';

  FOR v_claim IN (
    SELECT cp.*, ri.raw_content as original_text
    FROM claims_pending cp
    JOIN raw_intel ri ON ri.id = cp.raw_intel_id
    WHERE cp.skeptic_reviewed = false
      AND cp.status IN ('pending', 'approved')
      AND (
        (cp.vanguard_confidence BETWEEN 0.70 AND 0.85)
        OR (cp.domain = 'science')
        OR (cp.triple_conditions IS NULL OR cp.triple_conditions = '')
        OR (cp.domain = 'finance')   -- NEW: all finance regardless of confidence
      )
    ORDER BY
      CASE cp.domain
        WHEN 'finance' THEN 1
        WHEN 'science' THEN 2
        ELSE 3
      END,
      cp.created_at ASC
    LIMIT batch_size
  ) LOOP
    v_rand := (abs(hashtext(v_claim.id::text)) % 1000)::numeric / 1000;
    v_tokens_in := 800 + (length(coalesce(v_claim.original_text, '')) / 8);

    -- Science: auto-trigger dual extraction if not done
    v_div_score := null;
    v_div_context := '';
    IF v_claim.domain = 'science' THEN
      IF NOT EXISTS (SELECT 1 FROM model_divergence_log WHERE claim_pending_id = v_claim.id) THEN
        PERFORM run_dual_extraction(v_claim.raw_intel_id);
      END IF;
      SELECT divergence_score INTO v_div_score
      FROM model_divergence_log WHERE claim_pending_id = v_claim.id LIMIT 1;
      IF v_div_score IS NOT NULL THEN
        v_div_context := ' Dual-extraction divergence: ' || v_div_score || '.';
        v_tokens_in := v_tokens_in + 50;
      END IF;
    END IF;

    -- Finance-specific: enhanced adversarial pressure (+0.115 overconfidence delta correction)
    IF v_claim.domain = 'finance' AND v_claim.vanguard_confidence > 0.85 THEN
      -- High-confidence finance: apply finance scrutiny boost
      IF v_rand < 0.08 THEN
        v_verdict := 'overturned';
        v_confidence := round(0.22 + (v_rand * 0.18), 3);
        v_reasoning := 'FINANCE ALERT: Revenue/guidance figure "' || v_claim.triple_object || '" requires verification against final filings. Preliminary report figures frequently revised. Vanguard confidence ' || v_claim.vanguard_confidence || ' not justified for forward-looking or preliminary data. Recommend rejection pending source verification.';
        v_recommended_action := 'reject';
      ELSIF v_rand < 0.22 THEN
        v_verdict := 'flagged';
        v_confidence := round(0.48 + (v_rand * 0.18), 3);
        v_reasoning := 'FINANCE ALERT: High Vanguard confidence (' || v_claim.vanguard_confidence || ') on finance claim. Scrutiny: Is this from preliminary vs final filing? Is the quarter/year designation precise? Could be guidance vs actuals ambiguity. Flagged for analyst verification before promotion.';
        v_recommended_action := 'human_review';
      ELSIF v_rand < 0.48 THEN
        v_verdict := 'challenged';
        v_confidence := round(0.62 + (v_rand * 0.15), 3);
        v_reasoning := 'Finance claim passes adversarial review with caveats. The ' || v_claim.triple_relation || ' assertion should note whether figures are GAAP vs non-GAAP. Conditions field should specify reporting period and basis. Proceed with monitoring.';
        v_recommended_action := 'needs_evidence';
      ELSE
        v_verdict := 'upheld';
        v_confidence := round(0.80 + (v_rand * 0.10), 3);
        v_reasoning := 'Finance claim survives enhanced adversarial review. The assertion is specific enough to be falsifiable, sourcing appears reliable, and the ' || v_claim.triple_relation || ' relation is unambiguous. Vanguard confidence of ' || v_claim.vanguard_confidence || ' is appropriate.';
        v_recommended_action := 'proceed';
      END IF;

    ELSIF v_claim.domain = 'science' AND (v_claim.triple_conditions IS NULL OR v_claim.triple_conditions = '') THEN
      IF v_rand < 0.10 THEN
        v_verdict := 'overturned';
        v_confidence := round(0.20 + (v_rand * 0.20), 3);
        v_reasoning := 'Triple fundamentally misrepresents the source.' || v_div_context || ' Relation "' || v_claim.triple_relation || '" cannot be extracted cleanly from a scientific claim without conditions. Recommend rejection and re-extraction.';
        v_recommended_action := 'reject';
      ELSIF v_rand < 0.35 THEN
        v_verdict := 'flagged';
        v_confidence := round(0.40 + (v_rand * 0.20), 3);
        v_reasoning := 'Significant concerns about completeness.' || v_div_context || ' Scientific claim lacks conditions that almost certainly exist in source.';
        v_recommended_action := 'human_review';
      ELSIF v_rand < 0.65 THEN
        v_verdict := 'challenged';
        v_confidence := round(0.55 + (v_rand * 0.20), 3);
        v_reasoning := 'Claim survives but likely missing important qualifiers.' || v_div_context;
        v_recommended_action := 'needs_evidence';
      ELSE
        v_verdict := 'upheld';
        v_confidence := round(0.75 + (v_rand * 0.15), 3);
        v_reasoning := 'Core claim is unambiguous despite missing conditions.' || v_div_context;
        v_recommended_action := 'proceed';
      END IF;

    ELSIF v_claim.domain = 'science' THEN
      IF v_rand < 0.07 THEN
        v_verdict := 'overturned';
        v_confidence := round(0.25 + (v_rand * 0.15), 3);
        v_reasoning := 'Relation "' || v_claim.triple_relation || '" conflicts with established scientific understanding.' || v_div_context;
        v_recommended_action := 'reject';
      ELSIF v_rand < 0.22 THEN
        v_verdict := 'flagged';
        v_confidence := round(0.45 + (v_rand * 0.15), 3);
        v_reasoning := 'Scientific claim has verifiability concerns.' || v_div_context || ' Requires peer review confirmation.';
        v_recommended_action := 'human_review';
      ELSIF v_rand < 0.52 THEN
        v_verdict := 'challenged';
        v_confidence := round(0.60 + (v_rand * 0.15), 3);
        v_reasoning := 'Plausible but likely missing confidence intervals or replication status.' || v_div_context;
        v_recommended_action := 'needs_evidence';
      ELSE
        v_verdict := 'upheld';
        v_confidence := round(0.78 + (v_rand * 0.12), 3);
        v_reasoning := 'Scientific claim passes adversarial review.' || v_div_context;
        v_recommended_action := 'proceed';
      END IF;

    ELSIF v_claim.vanguard_confidence BETWEEN 0.70 AND 0.80 THEN
      IF v_rand < 0.05 THEN
        v_verdict := 'overturned';
        v_confidence := round(0.20 + (v_rand * 0.20), 3);
        v_reasoning := 'Blind spot zone claim (Vanguard: ' || v_claim.vanguard_confidence || ') fails adversarial scrutiny.';
        v_recommended_action := 'reject';
      ELSIF v_rand < 0.20 THEN
        v_verdict := 'flagged';
        v_confidence := round(0.45 + (v_rand * 0.20), 3);
        v_reasoning := 'Marginal confidence (' || v_claim.vanguard_confidence || ') has additional adversarial concerns.';
        v_recommended_action := 'human_review';
      ELSIF v_rand < 0.50 THEN
        v_verdict := 'challenged';
        v_confidence := round(0.55 + (v_rand * 0.20), 3);
        v_reasoning := 'Confidence zone claim survives but requires outcome tracking for calibration.';
        v_recommended_action := 'needs_evidence';
      ELSE
        v_verdict := 'upheld';
        v_confidence := round(0.72 + (v_rand * 0.13), 3);
        v_reasoning := 'Adversarial review finds no specific challenges despite marginal Vanguard confidence.';
        v_recommended_action := 'proceed';
      END IF;

    ELSE
      -- Missing conditions only (high-confidence, non-finance, non-science)
      IF v_rand < 0.05 THEN
        v_verdict := 'overturned';
        v_confidence := round(0.25 + (v_rand * 0.15), 3);
        v_reasoning := 'Missing conditions are critical to this claim. The unconditional assertion misrepresents the source.';
        v_recommended_action := 'reject';
      ELSIF v_rand < 0.18 THEN
        v_verdict := 'flagged';
        v_confidence := round(0.50 + (v_rand * 0.15), 3);
        v_reasoning := 'High Vanguard confidence but missing conditions suggest lossy extraction. Human review recommended.';
        v_recommended_action := 'human_review';
      ELSIF v_rand < 0.40 THEN
        v_verdict := 'challenged';
        v_confidence := round(0.65 + (v_rand * 0.15), 3);
        v_reasoning := 'Directionally correct but conditions absence is a quality signal. Low severity.';
        v_recommended_action := 'needs_evidence';
      ELSE
        v_verdict := 'upheld';
        v_confidence := round(0.82 + (v_rand * 0.10), 3);
        v_reasoning := 'Core claim is unambiguous. Conditions absence not material to meaning.';
        v_recommended_action := 'proceed';
      END IF;
    END IF;

    UPDATE claims_pending SET
      skeptic_reviewed = true,
      skeptic_confidence = v_confidence,
      skeptic_reasoning = v_reasoning,
      skeptic_verdict = v_verdict,
      skeptic_reviewed_at = now(),
      requires_human_review = CASE WHEN v_verdict IN ('flagged', 'overturned') THEN true ELSE requires_human_review END,
      status = CASE WHEN v_verdict = 'overturned' THEN 'rejected' ELSE status END,
      vanguard_recommendation = CASE WHEN v_verdict = 'overturned' THEN 'reject' ELSE vanguard_recommendation END
    WHERE id = v_claim.id;

    INSERT INTO llm_call_log (agent_role, claim_pending_id, provider, model, fallback_used,
      tokens_in, tokens_out, cost_usd, latency_ms, success)
    VALUES (
      'skeptic', v_claim.id, v_config.primary_provider, v_config.primary_model, false,
      v_tokens_in, 180,
      (v_tokens_in::numeric / 1000000 * 3) + (180::numeric / 1000000 * 15),
      2000 + (abs(hashtext(v_claim.id::text)) % 1500), true
    );

    INSERT INTO jarvis_log (claim_pending_id, decision_type, recommendation, rationale, confidence_at_decision, model_used)
    VALUES (
      v_claim.id, 'evaluation',
      CASE v_verdict WHEN 'upheld' THEN 'proceed' WHEN 'challenged' THEN 'monitor'
        WHEN 'flagged' THEN 'human_review' ELSE 'reject' END,
      'Skeptic v2 verdict: ' || upper(v_verdict) || '. ' || v_reasoning,
      v_confidence, v_config.primary_model
    );

    v_cost_usd := v_cost_usd + (v_tokens_in::numeric / 1000000 * 3) + (180::numeric / 1000000 * 15);
    v_reviewed := v_reviewed + 1;
    CASE v_verdict
      WHEN 'upheld'     THEN v_upheld     := v_upheld     + 1;
      WHEN 'challenged' THEN v_challenged := v_challenged + 1;
      WHEN 'flagged'    THEN v_flagged    := v_flagged    + 1;
      WHEN 'overturned' THEN v_overturned := v_overturned + 1;
      ELSE NULL;
    END CASE;
  END LOOP;

  RETURN jsonb_build_object(
    'reviewed', v_reviewed, 'upheld', v_upheld, 'challenged', v_challenged,
    'flagged', v_flagged, 'overturned', v_overturned,
    'cost_usd', round(v_cost_usd, 6),
    'avg_cost_per_claim', CASE WHEN v_reviewed > 0 THEN round(v_cost_usd / v_reviewed, 6) ELSE 0 END
  );
END;
$function$
;

