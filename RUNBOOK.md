# NOOSPHERE v2 — Runbook
**Step-by-step operations for autonomous system management**
Last updated: 2026-03-25

---

## How to Run a Manual Pipeline Cycle

```bash
# Full cycle (all 13 steps)
cd /path/to/noosphere
pip install supabase anthropic
export SUPABASE_URL=https://bdpvvclndurhuzxzrlma.supabase.co
export SUPABASE_SERVICE_ROLE_KEY=<your_key>
export ANTHROPIC_API_KEY=<your_key>
python noosphere_daemon.py

# Health check only (no pipeline execution, no LLM calls)
python noosphere_daemon.py --health

# Single step only (e.g., just recalculate trust)
python noosphere_daemon.py --step 10
```

**Pipeline steps reference:**

| Step | Function |
|------|----------|
| 1 | Ingest fresh raw intel |
| 2 | Vanguard extraction |
| 3 | Skeptic review |
| 4 | Advocate review |
| 5 | Jarvis evaluation |
| 6 | Adversarial review |
| 7 | Auto-promote Tier 2 |
| 8 | Check outcomes |
| 9 | Apply confidence decay |
| 10 | Recalculate rolling-window trust |
| 11 | Check tier demotion guards |
| 12 | Check failure clusters |
| 13 | Generate cycle report |

---

## How to Check System Health

**Option A — Alert API (recommended):**
```bash
curl https://bdpvvclndurhuzxzrlma.supabase.co/functions/v1/send-alerts | jq '.'
```

**Option B — Direct SQL:**
```sql
-- Trust scores + tiers
SELECT domain, autonomy_tier, effective_trust_score, total_decisions, correct_decisions
FROM jarvis_trust_scores ORDER BY domain;

-- Active alerts
SELECT check_system_alerts();

-- Total spend
SELECT get_total_spend();

-- Corpus summary
SELECT domain, COUNT(*) AS total,
  COUNT(*) FILTER (WHERE outcome_status='confirmed') AS confirmed,
  COUNT(*) FILTER (WHERE outcome_status='unverified') AS unverified
FROM claims GROUP BY domain ORDER BY domain;
```

**Option C — Daemon health check:**
```bash
python noosphere_daemon.py --health
```

**Option D — Cosmos Canvas:**
Open `cosmos-canvas.html` in a browser. The Phase 6 static version is embedded.
For live data: `https://bdpvvclndurhuzxzrlma.supabase.co/functions/v1/serve-cosmos-map`

---

## How to Investigate a Demotion

When you receive a `DEMOTION` alert for a domain:

```sql
-- 1. Check current trust state
SELECT domain, autonomy_tier, effective_trust_score, total_decisions,
       correct_decisions, outcome_resolution_rate, clean_cluster_start
FROM jarvis_trust_scores WHERE domain = 'finance';

-- 2. Find recent incorrect decisions
SELECT c.id, c.triple_subject, c.triple_relation, c.triple_object,
       c.outcome_status, c.outcome_timestamp,
       c.effective_confidence, c.promoted_by
FROM claims c
WHERE c.domain = 'finance'
  AND c.outcome_status = 'invalidated'
  AND c.outcome_timestamp > NOW() - INTERVAL '30 days'
ORDER BY c.outcome_timestamp DESC
LIMIT 20;

-- 3. Check failure cluster details
SELECT domain, incorrect_count, total_in_window, trust_penalty_applied,
       triggered, created_at
FROM failure_clusters
WHERE domain = 'finance'
ORDER BY created_at DESC;

-- 4. Check learning events for demotion record
SELECT event_type, domain, before_state, after_state, rationale, created_at
FROM learning_events
WHERE domain = 'finance'
ORDER BY created_at DESC
LIMIT 10;
```

**Key diagnostic questions:**
- Is the demotion from a genuine accuracy drop or a simulation artifact?
- What types of claims are being invalidated? (subject, relation patterns)
- Is the source reputation degraded? (`SELECT * FROM source_reputation ORDER BY reputation_score ASC LIMIT 20`)
- Did a failure cluster trigger?

---

## How to Recover a Demoted Domain

Finance is currently at Tier 1 (trust: 0.8482, threshold: 0.85).

```sql
-- Step 1: Check how many correct decisions are needed
SELECT
  domain,
  effective_trust_score,
  0.85 AS tier2_threshold,
  total_decisions,
  correct_decisions,
  CEIL(0.85 * total_decisions - correct_decisions) AS correct_needed_for_t2
FROM jarvis_trust_scores WHERE domain = 'finance';
-- Result: ~18 more correct decisions needed

-- Step 2: After pipeline cycles have run, recalculate trust
SELECT recalculate_trust_rolling();

-- Step 3: Check if threshold crossed
SELECT domain, effective_trust_score, autonomy_tier
FROM jarvis_trust_scores WHERE domain = 'finance';

-- Step 4: If trust >= 0.85, manually restore Tier 2 if auto-demotion guard hasn't done it
UPDATE jarvis_trust_scores
SET autonomy_tier = 2, updated_at = NOW()
WHERE domain = 'finance' AND effective_trust_score >= 0.85;

-- Step 5: Reset failure cluster (if artifacts remain)
UPDATE failure_clusters
SET triggered = false
WHERE domain = 'finance' AND trust_penalty_applied IS NOT NULL;
-- Then reset clean clock
UPDATE jarvis_trust_scores
SET clean_cluster_start = NOW()
WHERE domain = 'finance';
```

---

## How to Check Tier 3 Readiness

```sql
-- Full readiness assessment
SELECT
  jts.domain,
  jts.effective_trust_score,
  jts.autonomy_tier,
  jts.promotion_threshold,
  -- Trust gap
  (jts.promotion_threshold - jts.effective_trust_score) AS trust_gap,
  -- Rolling window
  LEAST(jts.total_decisions, 1000) AS window_size,
  jts.correct_decisions,
  -- Decisions needed
  GREATEST(0, CEIL(
    jts.promotion_threshold * LEAST(jts.total_decisions, 1000)
    - jts.correct_decisions
  )) AS correct_decisions_needed,
  -- 90-day clock
  EXTRACT(DAYS FROM (NOW() - jts.clean_cluster_start))::int AS clean_days_elapsed,
  GREATEST(0, 90 - EXTRACT(DAYS FROM (NOW() - jts.clean_cluster_start))::int) AS clean_days_remaining,
  -- Active failure clusters
  (SELECT COUNT(*) FROM failure_clusters fc
   WHERE fc.domain = jts.domain AND fc.triggered = true) AS active_clusters,
  -- Readiness verdict
  CASE
    WHEN jts.effective_trust_score >= jts.promotion_threshold
     AND EXTRACT(DAYS FROM (NOW() - jts.clean_cluster_start)) >= 90
     AND (SELECT COUNT(*) FROM failure_clusters fc
          WHERE fc.domain = jts.domain AND fc.triggered = true) = 0
    THEN 'TIER_3_READY ✓'
    WHEN jts.effective_trust_score >= jts.promotion_threshold
    THEN 'TRUST OK — AWAITING 90-DAY CLOCK'
    ELSE 'TRUST INSUFFICIENT'
  END AS verdict
FROM jarvis_trust_scores jts
ORDER BY jts.domain;
```

**As of 2026-03-25 expected output:**
- Technology: trust 0.8934, gap 0.0066, ~3 correct needed → Tier 3 ready after ~1 cycle + 90-day clock
- Science: trust 0.8794, gap 0.0206, ~6 correct needed → Tier 3 ready after ~1 cycle + 90-day clock
- Finance: trust 0.8482, Tier 1 → must recover Tier 2 first, then ~2 more cycles

---

## How to Add a New Ingestion Source

```sql
-- 1. Register the source in source_reputation
INSERT INTO source_reputation (source_url, reputation_score, domain_affinity)
VALUES ('https://example.com/feed', 0.70, 'technology');

-- 2. Insert raw intel manually (or via the Vanguard Edge Function)
INSERT INTO raw_intel (source_url, content_hash, raw_content, source_type, domain_hint, processed)
VALUES (
  'https://example.com/feed',
  md5('article content here'),
  'article content here',
  'rss',
  'technology',
  false
);

-- 3. The daemon's step 2 (Vanguard) will pick it up on the next cycle
```

To add a source that the daemon auto-fetches, add it to the ingestion config in step 1 of `noosphere_daemon.py`. The current implementation checks `raw_intel` for unprocessed records; external fetch logic is in the Vanguard Edge Function.

---

## How to Add a New Domain

```sql
-- 1. Add trust score record for new domain
INSERT INTO jarvis_trust_scores (
  domain, autonomy_tier, effective_trust_score, outcome_resolution_rate,
  total_decisions, correct_decisions, promotion_threshold, clean_cluster_start
) VALUES (
  'health', 1, 0.5000, 0.0000, 0, 0, 0.90, NOW()
);

-- 2. Add routing config for each agent role
INSERT INTO compute_routing_config (agent_role, domain, model, max_tokens, temperature)
VALUES
  ('vanguard',    'health', 'claude-sonnet-4-5', 4096, 0.3),
  ('skeptic',     'health', 'claude-sonnet-4-5', 4096, 0.5),
  ('advocate',    'health', 'claude-sonnet-4-5', 4096, 0.5),
  ('jarvis',      'health', 'claude-sonnet-4-5', 8192, 0.2),
  ('adversarial', 'health', 'claude-sonnet-4-5', 4096, 0.7);

-- 3. Update DOMAIN_NAMES in cosmos-canvas.html to include 'health'
-- 4. Update DOMAIN_COLORS, CLUSTER_CX, OUTCOMES, TRUST in cosmos-canvas.html
-- 5. The daemon will start processing 'health' domain claims automatically
```

---

## How to Adjust the Promotion Threshold

```sql
-- Raise threshold for a specific domain (e.g., require 95% for technology)
UPDATE jarvis_trust_scores
SET promotion_threshold = 0.95
WHERE domain = 'technology';

-- Verify
SELECT domain, promotion_threshold FROM jarvis_trust_scores;

-- Note: auto_promote_tier2() reads COALESCE(promotion_threshold, 0.90)
-- so this takes effect immediately on the next cycle
```

---

## How to Read the Cosmos Canvas

Open `cosmos-canvas.html` in any browser. No server required.

**Controls:**
- **Domain toggles** — show/hide finance (blue), science (orange), technology (purple)
- **⚡ tier2 only** — filter to the 53 autonomously-promoted claims
- **🛡 adversarial filter** — same as tier2 (all 53 are adversarial-survived)
- **conflict edges** — show/hide the 8 known contradiction pairs

**Visual encoding:**
- Node **size** = confidence (larger = higher confidence)
- Node **opacity** = outcome (bright = confirmed, dim = invalidated)
- **Gold ring** = jarvis_tier2 promoted claim
- **Cyan inner ring** = adversarial shield (survived review)
- **Red dashed outline** (finance cluster) = Tier 1 demotion zone
- **Green dashed ring** = 85% Tier 2 threshold boundary

**Side panel:**
- Trust bars show current score vs. 85% threshold line + Phase 5 ghost marker
- Δ deltas show Phase 5 → Phase 6 change
- Outcome bars show confirmed/invalidated distribution (0 unverified in Phase 6)
- 90-day clock shows clean cluster window progress

**For live data**, connect the canvas to the API:
```javascript
const COSMOS_API = 'https://bdpvvclndurhuzxzrlma.supabase.co/functions/v1/serve-cosmos-map'
const data = await fetch(COSMOS_API).then(r => r.json())
// data.nodes, data.trust_scores, data.total_nodes
```

---

## How to Interpret the Alert Webhook

The `send-alerts` Edge Function POST payload:
```json
{
  "system": "noosphere-v2",
  "timestamp": "2026-03-25T05:00:00Z",
  "health": "ALERTS_ACTIVE",
  "alert_count": 5,
  "alerts": [
    {
      "type": "DEMOTION",
      "severity": "HIGH",
      "domain": "finance",
      "message": "Domain finance at Tier 1 (trust: 0.8482)",
      "timestamp": "..."
    }
  ],
  "corpus": { "total_claims": 984, "total_spend_usd": 61.36 },
  "trust_scores": [...]
}
```

**Alert type reference:**

| Type | Severity | Action Required |
|------|----------|----------------|
| `DEMOTION` | HIGH | Domain lost autonomy tier. Investigate accuracy drop. |
| `FAILURE_CLUSTER` | CRITICAL | Systematic failure pattern detected. Review demoted claims. |
| `AUDIT_BACKLOG` | MEDIUM | Flagged claims awaiting human review. Process audit queue. |
| `COST_ALERT` | HIGH | Daily spend > $5. Check for runaway LLM calls. |
| `TRUST_WARNING` | MEDIUM | Domain approaching demotion threshold. Monitor next 2 cycles. |
| `90_DAY_APPROACHING` | INFO | Clean window ending soon. No action needed unless clusters trigger. |
| `TIER3_ELIGIBLE` | INFO | Domain crossed 0.90 threshold. **Build `auto_promote_tier3()` and activate.** |

**Current known alerts (2026-03-25) — no action required:**
- All FAILURE_CLUSTER alerts are Phase 6 bulk resolution artifacts (not real failures)
- COST_ALERT will clear after 24h (Phase 7 build session)
- DEMOTION (finance) is real — will resolve as pipeline cycles accumulate correct decisions

---

## How to Promote a Domain to Tier 3 (when ready)

**Prerequisites (all must be true):**
1. `effective_trust_score >= 0.90`
2. No active failure clusters (`triggered = false` for all clusters)
3. 90-day clean window complete (`clean_cluster_start + 90 days < NOW()`)
4. `auto_promote_tier3()` function deployed (not yet built — Phase 8 prerequisite)

**When Technology crosses 0.90 (expected: first pipeline cycle after 2026-03-25):**

```sql
-- 1. Confirm readiness
SELECT * FROM check_system_alerts();  -- should show TIER3_ELIGIBLE alert

-- 2. Deploy auto_promote_tier3() function (build analogous to auto_promote_tier2)
-- See OPERATIONAL_HANDOFF.md §4 for function patterns

-- 3. Activate Tier 3
UPDATE jarvis_trust_scores
SET autonomy_tier = 3
WHERE domain = 'technology' AND effective_trust_score >= 0.90;

-- 4. Run first Tier 3 promotion cycle
SELECT auto_promote_tier3();

-- 5. Update Cosmos Canvas with new tier3 visual markers
-- 6. Set up stricter audit sampling (suggest 5% for Tier 3)
```

---

## Emergency Procedures

### Stop all autonomous operations
```bash
# GitHub Actions: go to repo → Actions → Disable workflow
# Or set DAEMON_BATCH_SIZE=0 in secrets to neutralize without disabling
```

### Rollback a bad promotion batch
```sql
-- Find claims promoted in last N hours
SELECT id, domain, triple_subject, triple_relation, triple_object,
       promoted_at, promoted_by
FROM claims
WHERE promoted_at > NOW() - INTERVAL '2 hours'
  AND promoted_by = 'jarvis_tier2'
ORDER BY promoted_at DESC;

-- Revert: move back to unverified, remove promotion metadata
UPDATE claims
SET promoted_by = NULL, promoted_at = NULL, outcome_status = 'unverified'
WHERE id IN ('<id1>', '<id2>');

-- Recalculate trust after rollback
SELECT recalculate_trust_rolling();
```

### Force trust recalculation after manual data fix
```bash
python noosphere_daemon.py --step 10   # recalculate_trust_rolling only
python noosphere_daemon.py --step 11   # demotion check only
python noosphere_daemon.py --step 12   # failure cluster check only
```
