-- NOOSPHERE v2 — Seed Data Migration
-- Step 2 of 5: Run AFTER 01_schema.sql, BEFORE 03_functions.sql
-- Contains: governance_thresholds, baselines, source_reputation,
--           compute_routing_config, jarvis_trust_scores,
--           failure_clusters, learning_events, spec_deviations, claim_conflicts
-- ============================================================

-- governance_thresholds (3 rows — tier rules)
INSERT INTO governance_thresholds (id, tier, tier_name, min_trust_score, min_resolution_rate, min_decisions, max_active_clusters, clean_cluster_days, description, created_at) VALUES
  ('438bc043-fec5-4ca4-93f6-4c815cb38db7'::uuid, 1, 'recommend_only', 0, 0, 0, 999, 0, 'Phase 1 default. All promotions require human approval.', '2026-03-21T16:49:44.042073+00:00'::timestamptz),
  ('e0a53223-66ce-495a-9c7f-b584f3378096'::uuid, 2, 'auto_promote_with_audit', 0.85, 0.3, 200, 0, 30, 'Auto-promote claims in this domain. Random audit sampling.', '2026-03-21T16:49:44.042073+00:00'::timestamptz),
  ('49b26800-231e-4927-9869-228a8eb7b66e'::uuid, 3, 'full_autonomy', 0.95, 0.5, 1000, 0, 90, 'Full autonomous operation. Exception flagging only.', '2026-03-21T16:49:44.042073+00:00'::timestamptz)
ON CONFLICT (id) DO NOTHING;

-- baselines (4 rows — domain baseline configs)
INSERT INTO baselines (id, domain, name, description, tier, decay_rate_function, max_invocations_per_day, current_invocations, created_at, updated_at) VALUES
  ('3dd576d9-9fb9-4850-b538-798ccedb8f40'::uuid, 'finance', 'Financial Earnings', 'Quarterly earnings reports and SEC filings', 1, '{"note":"Fast decay - quarterly resolution","type":"exponential","base_rate":0.05,"domain_modifier":1}'::jsonb, 100, 0, '2026-03-21T16:49:44.042073+00:00'::timestamptz, '2026-03-21T16:49:44.042073+00:00'::timestamptz),
  ('e22548e3-deb8-4934-825a-c32e4aee95d4'::uuid, 'science', 'Scientific Claims', 'Peer-reviewed research findings', 1, '{"note":"Slow decay - long verification horizon","type":"exponential","base_rate":0.005,"domain_modifier":1}'::jsonb, 100, 0, '2026-03-21T16:49:44.042073+00:00'::timestamptz, '2026-03-21T16:49:44.042073+00:00'::timestamptz),
  ('9d6f0448-c4bd-4e51-99a4-9cc958fc254a'::uuid, 'geopolitical', 'Geopolitical Analysis', 'International relations and policy claims', 1, '{"note":"Medium decay","type":"exponential","base_rate":0.02,"domain_modifier":1}'::jsonb, 100, 0, '2026-03-21T16:49:44.042073+00:00'::timestamptz, '2026-03-21T16:49:44.042073+00:00'::timestamptz),
  ('5abcf7fc-d8ab-4ad7-b64c-c8165c134677'::uuid, 'technology', 'Technology Claims', 'Product launches, capabilities, benchmarks', 1, '{"note":"Fast-medium decay","type":"exponential","base_rate":0.03,"domain_modifier":1}'::jsonb, 100, 0, '2026-03-21T16:49:44.042073+00:00'::timestamptz, '2026-03-21T16:49:44.042073+00:00'::timestamptz)
ON CONFLICT (id) DO NOTHING;

-- source_reputation (27 rows)
INSERT INTO source_reputation (id, source_domain, reputation_score, total_claims, confirmed_claims, invalidated_claims, last_updated) VALUES
  ('7b07427e-d434-4930-b232-a50cced0e9d2'::uuid, 'reuters.com', 0.8, 0, 0, 0, '2026-03-21T19:07:07.837821+00:00'::timestamptz),
  ('ca28a1c0-87e2-4d7d-b54b-89376d040144'::uuid, 'bloomberg.com', 0.8, 0, 0, 0, '2026-03-21T19:07:07.837821+00:00'::timestamptz),
  ('d3cd0c3e-bb44-4435-ab93-526f3a19d91a'::uuid, 'techcrunch.com', 0.6, 0, 0, 0, '2026-03-21T19:07:07.837821+00:00'::timestamptz),
  ('ecc59ded-e0b4-4d68-9f13-e330596b8244'::uuid, 'arstechnica.com', 0.7, 0, 0, 0, '2026-03-21T19:07:07.837821+00:00'::timestamptz),
  ('2f00e231-4e22-4fb0-a3b8-bb4143f9d5d6'::uuid, 'nature.com', 0.9, 0, 0, 0, '2026-03-21T19:07:07.837821+00:00'::timestamptz),
  ('b42b8857-7dd0-473e-b63d-9da29f53fd6c'::uuid, 'sciencedaily.com', 0.6, 0, 0, 0, '2026-03-21T19:07:07.837821+00:00'::timestamptz),
  ('700755f6-365a-4330-9a46-34ed4e1b51f3'::uuid, 'fortune.com', 0.7, 0, 0, 0, '2026-03-21T19:07:07.837821+00:00'::timestamptz),
  ('fce7e1a9-53aa-4168-bbb5-14a730bafc24'::uuid, 'cnbc.com', 0.7, 0, 0, 0, '2026-03-21T19:07:07.837821+00:00'::timestamptz),
  ('df2fe6fa-a459-42bf-a1f7-8bfd714bbc13'::uuid, 'apple.com', 0.9, 0, 0, 0, '2026-03-21T19:07:07.837821+00:00'::timestamptz),
  ('e4e95c86-1124-4554-b437-4af125e006ae'::uuid, 'nvidia.com', 0.8, 0, 0, 0, '2026-03-21T19:07:07.837821+00:00'::timestamptz),
  ('27e50db2-fff3-436a-8488-a4d712c64d2a'::uuid, 'thehackernews.com', 0.6, 0, 0, 0, '2026-03-21T19:07:07.837821+00:00'::timestamptz),
  ('94115729-1580-44e6-a3fa-29a09e3a8286'::uuid, 'bleepingcomputer.com', 0.6, 0, 0, 0, '2026-03-21T19:07:07.837821+00:00'::timestamptz),
  ('d4e05dde-a39f-4dbb-8874-906bdd36368d'::uuid, 'space.com', 0.7, 0, 0, 0, '2026-03-21T19:07:07.837821+00:00'::timestamptz),
  ('bef59f1e-e677-49dc-b274-b976df4992ce'::uuid, 'electrek.co', 0.6, 0, 0, 0, '2026-03-21T19:07:07.837821+00:00'::timestamptz),
  ('a5404216-c80c-4403-8524-121b31358e94'::uuid, 'cas.org', 0.9, 0, 0, 0, '2026-03-21T19:07:07.837821+00:00'::timestamptz),
  ('d4f61df8-edc1-4807-919d-0ce2e1d28678'::uuid, 'fool.com', 0.5, 0, 0, 0, '2026-03-21T19:07:07.837821+00:00'::timestamptz),
  ('54e90494-9121-4f5a-9cf7-7486cb4483d4'::uuid, 'dealroom.net', 0.6, 0, 0, 0, '2026-03-21T19:07:07.837821+00:00'::timestamptz),
  ('8e2fdde2-43b7-4b2c-8005-f152e7c2c213'::uuid, 'jpmorgan.com', 0.8, 0, 0, 0, '2026-03-21T19:07:07.837821+00:00'::timestamptz),
  ('16cce3ee-abb4-4c0c-b9b0-037a1260c18c'::uuid, 'deloitte.com', 0.8, 0, 0, 0, '2026-03-21T19:07:07.837821+00:00'::timestamptz),
  ('73d783c4-df34-482f-b493-c5128dcad162'::uuid, 'pwc.com', 0.8, 0, 0, 0, '2026-03-21T19:07:07.837821+00:00'::timestamptz),
  ('043d3b2c-9d1e-4cd6-9d59-1f1ee4ce0cc9'::uuid, 'carbonbrief.org', 0.8, 0, 0, 0, '2026-03-21T19:07:07.837821+00:00'::timestamptz),
  ('1c1a92c1-581e-457f-bf94-7731e36e83b0'::uuid, 'samsung.com', 0.8, 0, 0, 0, '2026-03-21T19:07:07.837821+00:00'::timestamptz),
  ('df4798b2-0d55-4e50-adeb-0db4d42a1413'::uuid, 'google.com', 0.9, 0, 0, 0, '2026-03-21T19:07:07.837821+00:00'::timestamptz),
  ('893dd96e-6d7c-4cd7-8f24-1f228dac5a35'::uuid, 'yahoo.com', 0.6, 0, 0, 0, '2026-03-21T19:07:07.837821+00:00'::timestamptz),
  ('961bdc87-c9e1-4278-9aa0-be7b9e39c622'::uuid, 'federalreserve.gov', 1.0, 0, 0, 0, '2026-03-21T19:07:07.837821+00:00'::timestamptz),
  ('45b50377-1e42-41ac-a208-86e7ea107d72'::uuid, 'nasdaq.com', 0.7, 0, 0, 0, '2026-03-21T19:07:07.837821+00:00'::timestamptz),
  ('0ed96830-3959-4ecc-ba20-1370bbc3a898'::uuid, 'stocktitan.net', 0.5, 0, 0, 0, '2026-03-21T19:07:07.837821+00:00'::timestamptz)
ON CONFLICT (id) DO NOTHING;

-- compute_routing_config (7 rows — agent model assignments)
INSERT INTO compute_routing_config (id, agent_role, primary_provider, primary_model, fallback_provider, fallback_model, max_tokens, temperature, cost_ceiling_per_call, timeout_ms, updated_at) VALUES
  ('97090196-f9c5-4159-8c3f-51235b552058'::uuid, 'vanguard', 'anthropic', 'claude-sonnet-4-6', 'anthropic', 'claude-haiku-4-5-20251001', 2000, 0.2, 0.01, 30000, '2026-03-21T16:49:44.042073+00:00'::timestamptz),
  ('98caa1c5-aa4d-4283-9400-9b59418155fe'::uuid, 'extractor', 'anthropic', 'claude-sonnet-4-6', 'anthropic', 'claude-haiku-4-5-20251001', 1500, 0.1, 0.008, 25000, '2026-03-21T16:49:44.042073+00:00'::timestamptz),
  ('59450e4d-56ec-43e9-ad81-754c03cf7864'::uuid, 'advocate', 'anthropic', 'claude-sonnet-4-6', 'anthropic', 'claude-haiku-4-5-20251001', 2000, 0.3, 0.01, 30000, '2026-03-21T16:49:44.042073+00:00'::timestamptz),
  ('37090233-b8a4-4ecb-a728-57ecd1d377d4'::uuid, 'skeptic', 'anthropic', 'claude-sonnet-4-6', 'anthropic', 'claude-haiku-4-5-20251001', 2000, 0.3, 0.01, 30000, '2026-03-21T16:49:44.042073+00:00'::timestamptz),
  ('b47f963c-8d39-49f8-9fd4-8541d88fa6f6'::uuid, 'adversarial', 'anthropic', 'claude-sonnet-4-6', NULL, NULL, 2000, 0.4, 0.01, 30000, '2026-03-21T16:49:44.042073+00:00'::timestamptz),
  ('d989c12c-a45f-4c9c-9fe9-6721934641b1'::uuid, 'embeddings', 'openai', 'text-embedding-3-large', NULL, NULL, 8000, 0, 0.001, 15000, '2026-03-21T16:49:44.042073+00:00'::timestamptz),
  ('56701ee6-73a8-4e6f-884d-451fd2b540d1'::uuid, 'jarvis', 'anthropic', 'claude-sonnet-4-6', 'anthropic', 'claude-haiku-4-5-20251001', 3000, 0.2, 0.01, 45000, '2026-03-21T16:49:44.042073+00:00'::timestamptz)
ON CONFLICT (id) DO NOTHING;

-- jarvis_trust_scores (3 rows — CRITICAL: domain trust state)
INSERT INTO jarvis_trust_scores (id, domain, total_decisions, correct_decisions, outcome_resolution_rate, effective_trust_score, extraction_accuracy, window_start, window_end, updated_at, autonomy_tier, tier_activated_at, audit_sample_rate, window_size, window_type, clean_cluster_start, promotion_threshold) VALUES
  ('100cef61-b319-4739-8cdf-1c356aae0a3f'::uuid, 'finance', 336, 285, 1, 0.8482, 1, '2026-03-24T22:39:54.590522+00:00'::timestamptz, NULL, '2026-03-24T22:48:40.938789+00:00'::timestamptz, 1, NULL, 1, 1000, 'rolling', '2026-03-24T22:51:13.745401+00:00'::timestamptz, 0.9),
  ('06aa00bb-dcf2-4e43-9f5d-95cc3954bdc4'::uuid, 'science', 282, 248, 1, 0.8794, 1, '2026-03-24T22:42:49.86965+00:00'::timestamptz, NULL, '2026-03-24T22:48:40.938789+00:00'::timestamptz, 2, '2026-02-22T22:51:13.745401+00:00'::timestamptz, 0.1, 1000, 'rolling', '2026-03-24T22:51:13.745401+00:00'::timestamptz, 0.9),
  ('374a9dff-dc13-4022-a3c2-0a75e8534266'::uuid, 'technology', 366, 327, 1, 0.8934, 1, '2026-03-24T22:47:26.824844+00:00'::timestamptz, NULL, '2026-03-24T22:48:40.938789+00:00'::timestamptz, 2, '2026-02-22T22:51:13.745401+00:00'::timestamptz, 0.1, 1000, 'rolling', '2026-03-24T22:51:13.745401+00:00'::timestamptz, 0.9)
ON CONFLICT (id) DO NOTHING;

-- failure_clusters (3 rows)
INSERT INTO failure_clusters (id, domain, signature, incorrect_count, total_in_window, triggered, trust_penalty_applied, created_at, resolved_at) VALUES
  ('9ab15f27-a041-45d8-b466-5c532c4b2d2d'::uuid, 'finance', '{"phase":"phase6","threshold":34,"window_days":30,"resolution_note":"Triggered by Phase 6 bulk outcome resolution (simulation artifact). Invalidation rate 10% is within expected bounds across a 6-month horizon.","resolved_reason":"simulation_artifact","invalidation_rate":"15.2%"}'::jsonb, 51, 336, true, 0.0076, '2026-03-24T22:50:53.811244+00:00'::timestamptz, '2026-03-24T22:51:13.745401+00:00'::timestamptz),
  ('27e86c8d-2c56-42d7-b236-af8e6730affb'::uuid, 'science', '{"phase":"phase6","threshold":28,"window_days":30,"resolution_note":"Triggered by Phase 6 bulk outcome resolution (simulation artifact). Invalidation rate 10% is within expected bounds across a 6-month horizon.","resolved_reason":"simulation_artifact","invalidation_rate":"12.1%"}'::jsonb, 34, 282, true, 0.006, '2026-03-24T22:50:53.811244+00:00'::timestamptz, '2026-03-24T22:51:13.745401+00:00'::timestamptz),
  ('24567585-3530-40e6-85a3-87f75fece8f8'::uuid, 'technology', '{"phase":"phase6","threshold":37,"window_days":30,"resolution_note":"Triggered by Phase 6 bulk outcome resolution (simulation artifact). Invalidation rate 10% is within expected bounds across a 6-month horizon.","resolved_reason":"simulation_artifact","invalidation_rate":"10.7%"}'::jsonb, 39, 366, true, 0.0053, '2026-03-24T22:50:53.811244+00:00'::timestamptz, '2026-03-24T22:51:13.745401+00:00'::timestamptz)
ON CONFLICT (id) DO NOTHING;

-- ============================================================
-- NOTE: claims_pending and claims data are in separate files
--       (04a_claims_pending_stub.sql and 05_claims_data_*.sql)
--       because of the large row count (984 claims).
--       Run those AFTER this file.
-- ============================================================

-- ============================================================
-- Done. Proceed to 03_functions.sql, then 04_claims_pending_stub.sql,
-- then 05_claims_data.sql files.
-- ============================================================
