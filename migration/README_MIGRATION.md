# NOOSPHERE v2 — Database Migration Guide
**From: bdpvvclndurhuzxzrlma (retired)**
**To: isfhndnwydnqbmvixddm (your project)**

---

## Overview

Run the 5 SQL files in order using the **Supabase SQL Editor** at:
`https://supabase.com/dashboard/project/isfhndnwydnqbmvixddm/sql/new`

Each file is idempotent (`ON CONFLICT DO NOTHING`) — safe to re-run if something fails.

---

## Step-by-Step

### Step 1 — Schema (run `01_schema.sql`)
Creates all 18 tables with correct column types, defaults, and foreign keys.
Enables required extensions: `uuid-ossp`, `vector`, `pg_net`.

> **Expected result:** 18 tables created, no errors.

---

### Step 2 — Seed Data (run `02_seed_data.sql`)
Inserts configuration rows:
- 3 governance tier thresholds
- 4 domain baselines
- 27 source reputation scores
- 7 agent routing configs
- 3 jarvis trust scores (THE critical rows — domain trust state, tiers, 90-day clock)
- 3 failure clusters (Phase 6 artifacts — marked as simulation)

> **Expected result:** ~50 rows inserted across config tables.

---

### Step 3 — Functions (run `03_functions.sql`)
Creates all 24 NOOSPHERE pipeline functions:
`apply_decay`, `auto_promote_tier2`, `check_contradictions`, `check_failure_clusters`,
`check_financial_outcomes`, `check_science_outcomes`, `check_system_alerts`,
`check_tech_outcomes`, `check_tier_demotion`, `find_similar_claims`,
`generate_claim_pseudo_embedding`, `generate_cosmos_map`, `generate_embeddings`,
`get_model_for_role`, `get_total_spend`, `promote_claim`, `recalculate_trust_rolling`,
`record_outcome`, `run_adversarial_review`, `run_advocate_review`,
`run_dual_extraction`, `run_jarvis_evaluation`, `run_skeptic_review`, `bulk_promote`.

> **Expected result:** 24 functions created, no errors.

---

### Step 4a — Raw Intel Stubs (run `04a_raw_intel_stubs.sql`)
Inserts stub rows into `raw_intel` needed to satisfy the FK chain:
`raw_intel` ← `claims_pending` ← `claims`

> **Expected result:** ~608 raw_intel stubs inserted.

---

### Step 4b — Claims Pending Stubs (run `04b_claims_pending_stubs.sql`)
Inserts stub rows into `claims_pending` (needed as FK for claims).

> **Expected result:** ~984 claims_pending stubs inserted.

> **Note:** The Supabase SQL Editor may time out on large files.
> If it does, split the file in half (copy rows 1-500 first, then 501-end).

---

### Step 5 — Claims Data (run `05_claims_data.sql`)
Inserts all 984 claims (the full NOOSPHERE corpus):
- 860 confirmed, 124 invalidated
- 53 tier2-promoted (adversarial-survived)
- All 3 domains: finance=336, science=282, technology=366

> **⚠️ This is a 922KB file.** The SQL editor may struggle.
> **Option A:** Paste in batches. The file has 10 labeled batches (100 rows each).
> **Option B:** Use the Supabase CLI:
> ```bash
> psql "postgresql://postgres:[password]@db.isfhndnwydnqbmvixddm.supabase.co:5432/postgres" -f migration/05_claims_data.sql
> ```
> Find the database password at: Dashboard → Settings → Database → Connection string

---

## Verification Query

After all 5 files run, paste this into the SQL Editor to confirm:

```sql
SELECT
  (SELECT COUNT(*) FROM claims) AS total_claims,
  (SELECT COUNT(*) FROM claims WHERE outcome_status='confirmed') AS confirmed,
  (SELECT COUNT(*) FROM claims WHERE outcome_status='invalidated') AS invalidated,
  (SELECT COUNT(*) FROM jarvis_trust_scores) AS trust_rows,
  (SELECT COUNT(*) FROM compute_routing_config) AS routing_rows,
  (SELECT domain || ':tier' || autonomy_tier || ':trust' || ROUND(effective_trust_score::numeric,4)::text
   FROM jarvis_trust_scores WHERE domain='technology') AS tech_status,
  (SELECT domain || ':tier' || autonomy_tier || ':trust' || ROUND(effective_trust_score::numeric,4)::text
   FROM jarvis_trust_scores WHERE domain='science') AS science_status,
  (SELECT domain || ':tier' || autonomy_tier || ':trust' || ROUND(effective_trust_score::numeric,4)::text
   FROM jarvis_trust_scores WHERE domain='finance') AS finance_status;
```

**Expected output:**
```
total_claims: 984
confirmed: 860
invalidated: 124
trust_rows: 3
routing_rows: 7
tech_status: technology:tier2:trust0.8934
science_status: science:tier2:trust0.8794
finance_status: finance:tier1:trust0.8482
```

---

## Deploy Edge Functions

After the SQL migration, deploy the two API Edge Functions via the **Supabase Dashboard**:

### Option A: Dashboard (easiest)
1. Go to: Dashboard → Edge Functions → Create new function
2. Create `serve-cosmos-map` → paste content from `supabase/functions/serve-cosmos-map/index.ts`
3. Create `send-alerts` → paste content from `supabase/functions/send-alerts/index.ts`
4. Set `verify_jwt: false` for both (they're public APIs)

### Option B: Supabase CLI
```bash
npm install -g supabase
supabase link --project-ref isfhndnwydnqbmvixddm
supabase functions deploy serve-cosmos-map --no-verify-jwt
supabase functions deploy send-alerts --no-verify-jwt
```

---

## Update GitHub Secrets

After migration, update these secrets in the repo → Settings → Secrets:

| Secret | New Value |
|--------|-----------|
| `SUPABASE_URL` | `https://isfhndnwydnqbmvixddm.supabase.co` |
| `SUPABASE_SERVICE_ROLE_KEY` | *(your service role key — already provided)* |
| `ANTHROPIC_API_KEY` | *(your Anthropic API key)* |

The `SUPABASE_URL` secret has already been updated in the repo.
The `SUPABASE_SERVICE_ROLE_KEY` will be set once confirmed.

---

## New API Endpoints (after Edge Function deployment)

| Endpoint | URL |
|----------|-----|
| Cosmos Map API | `https://isfhndnwydnqbmvixddm.supabase.co/functions/v1/serve-cosmos-map` |
| Alert API | `https://isfhndnwydnqbmvixddm.supabase.co/functions/v1/send-alerts` |

Update `OPERATIONAL_HANDOFF.md` and `cosmos-canvas.html` with these new URLs after deployment.
