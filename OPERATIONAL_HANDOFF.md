# NOOSPHERE v2 — Operational Handoff
**System hardened for independent operation — Phase 7 (The Severance)**
Last updated: 2026-03-25 | Status: AUTONOMOUS

---

## 1. Project Identity

| Field | Value |
|-------|-------|
| Project name | noosphere-v2 |
| Supabase project ID | `isfhndnwydnqbmvixddm` |
| Supabase URL | `https://isfhndnwydnqbmvixddm.supabase.co` |
| Cosmos Canvas | `/Users/trumac/Desktop/NOOSPHEREV2/cosmos-canvas.html` |
| Cosmos Map API | `https://isfhndnwydnqbmvixddm.supabase.co/functions/v1/serve-cosmos-map` |
| Alert API | `https://isfhndnwydnqbmvixddm.supabase.co/functions/v1/send-alerts` |
| Vanguard API | `https://isfhndnwydnqbmvixddm.supabase.co/functions/v1/run-vanguard-batch` |
| Daemon script | `noosphere_daemon.py` |
| Workflow | `.github/workflows/noosphere-daemon.yml` |

---

## 2. Table Inventory (18 tables)

| Table | Purpose |
|-------|---------|
| `raw_intel` | Inbound articles/sources before extraction. `processed=false` = pending. |
| `source_reputation` | Trust score per source URL (0–1). Used by Vanguard & Adversarial. |
| `claims` | Core knowledge graph nodes. Every extracted, debated, and promoted claim. |
| `claims_pending` | Staging area: claims under debate (skeptic/advocate). Not yet in `claims`. |
| `claim_conflicts` | Contradiction edges between claims. `conflict_type='direct_contradiction'`. |
| `jarvis_trust_scores` | Per-domain trust state: score, tier, window stats, clean clock. |
| `jarvis_pending_queue` | Queue of claims awaiting Jarvis evaluation. |
| `jarvis_log` | Detailed per-claim Jarvis reasoning log. |
| `llm_call_log` | Every LLM API call: model, tokens, cost, agent role. |
| `learning_events` | System-level events: promotions, demotions, cluster triggers. |
| `failure_clusters` | Detected failure patterns. `triggered=true` = active. |
| `compute_routing_config` | Agent role → model mapping + token budgets. |
| `pipeline_metrics` | Cycle-level throughput stats. |
| `agent_debates` | Full transcript of Skeptic↔Advocate debates. |
| `spec_deviations` | Build bible: deviations from original spec with rationale. |
| `outcome_cache` | Cached external outcome lookups (rate limit protection). |
| `audit_log` | Human review queue for flagged promotions. |
| `embedding_cache` | Cached vector embeddings for claims. |

---

## 3. Edge Functions

| Function | URL | Auth | Purpose |
|----------|-----|------|---------|
| `serve-cosmos-map` | `/functions/v1/serve-cosmos-map` | None (public) | Live CosmosMap JSON. Query: `?domain=finance\|science\|technology`. 5-min cache. |
| `send-alerts` | `/functions/v1/send-alerts` | None (public) | Runs `check_system_alerts()`, pushes to WEBHOOK_URL if set. |
| `run-vanguard-batch` | `/functions/v1/run-vanguard-batch` | JWT | Vanguard extraction from raw_intel. Pre-existing from Phase 1. |

**Verifying the Cosmos Map API:**
```bash
curl https://isfhndnwydnqbmvixddm.supabase.co/functions/v1/serve-cosmos-map | jq '.total_nodes'
# Expected: 984

curl "https://isfhndnwydnqbmvixddm.supabase.co/functions/v1/serve-cosmos-map?domain=technology" | jq '.trust_scores'
```

**Verifying the Alert API:**
```bash
curl https://isfhndnwydnqbmvixddm.supabase.co/functions/v1/send-alerts | jq '.health'
# Current: "ALERTS_ACTIVE" (known state: Finance T1, failure clusters from Phase 6)
```

---

## 4. SQL Functions

| Function | Signature | Purpose |
|----------|-----------|---------|
| `promote_claim` | `(p_claim_id uuid, p_tier int)` | Manually promote a claim to a specific tier |
| `record_outcome` | `(p_claim_id uuid, p_status text)` | Record confirmed/invalidated outcome for a claim |
| `apply_decay` | `()` | Reduce effective_confidence on unverified claims |
| `recalculate_trust_rolling` | `()` | Recompute rolling-window trust for all domains (window=1000) |
| `check_tier_demotion` | `()` | Demote domains whose trust falls below tier minimum |
| `check_failure_clusters` | `(p_window_days int DEFAULT 30)` | Detect failure clusters, apply trust penalties |
| `auto_promote_tier2` | `()` | Autonomously promote eligible claims in Tier 2 domains |
| `check_system_alerts` | `()` | Return jsonb array of active alerts |
| `get_total_spend` | `()` | Return total LLM spend in USD |
| `generate_cosmos_map` | `(domain_filter text DEFAULT NULL)` | DB-side cosmos map generation (used by edge function) |
| `run_dual_extraction` | `(p_raw_intel_id uuid)` | Vanguard: extract two claim perspectives from one intel record |
| `run_skeptic_review` | `(batch_size int DEFAULT 10)` | Skeptic: challenge pending claims, returns jsonb summary |
| `run_adversarial_review` | `(batch_size int DEFAULT 10)` | Attack Jarvis-recommended claims before promotion |
| `recalculate_trust_rolling` | `()` | Rolling window trust recalculation |

---

## 5. Daemon Execution Schedule

**Recommended:** GitHub Actions (free tier, no infrastructure to manage)

| Schedule | Cron expression | Invocations/day |
|----------|----------------|-----------------|
| Default | `0 6,18 * * *` | 2× (6 AM + 6 PM UTC) |
| Aggressive | `0 */6 * * *` | 4× (every 6h) |
| Light | `0 6 * * *` | 1× (once/day) |

**Manual trigger:**
```bash
python noosphere_daemon.py           # full cycle
python noosphere_daemon.py --health  # health check only
python noosphere_daemon.py --step 10 # trust recalculation only
```

**GitHub Actions setup:**
1. Push repo to GitHub
2. Add secrets: `SUPABASE_URL`, `SUPABASE_SERVICE_ROLE_KEY`, `ANTHROPIC_API_KEY`, `WEBHOOK_URL` (optional)
3. The workflow at `.github/workflows/noosphere-daemon.yml` activates automatically

---

## 6. Environment Variables

| Variable | Required | Default | Purpose |
|----------|----------|---------|---------|
| `SUPABASE_URL` | ✅ | — | Supabase project URL |
| `SUPABASE_SERVICE_ROLE_KEY` | ✅ | — | Full DB access key |
| `ANTHROPIC_API_KEY` | ✅ | — | LLM calls (Vanguard, Jarvis, etc.) |
| `WEBHOOK_URL` | Optional | — | Alert push destination (Slack, Discord, etc.) |
| `DAEMON_BATCH_SIZE` | Optional | 20 | Claims processed per step per cycle |
| `DAEMON_PROMOTION_THRESHOLD` | Optional | 0.90 | Trust required for Tier 2→Tier 3 |
| `DAEMON_AUDIT_SAMPLE_RATE` | Optional | 0.10 | Fraction of T2 promotions flagged for audit |

---

## 7. The Ten System Laws

1. **Truth is provisional.** No claim is permanently true — all decay toward unverified unless continuously confirmed.
2. **Trust is earned.** Autonomy tier is a function of historical accuracy, not seniority.
3. **Rolling windows prevent original sin.** Early mistakes don't permanently anchor a domain's trust.
4. **Every promotion must survive adversarial review.** No claim reaches autonomy without attack simulation.
5. **Failure clusters trigger demotion.** Systematic errors in a domain reduce its autonomy tier automatically.
6. **The 90-day clock is absolute.** Clean cluster windows cannot be gamed or reset without genuine clean runs.
7. **Cost is a first-class constraint.** Daily spend alerts at $5. Total budget ceiling tracked.
8. **Audit sampling is non-negotiable.** 10% of Tier 2 promotions are flagged for human spot-check.
9. **The system corrects its own corrections.** Trust scores update based on outcomes, not intentions.
10. **Severance is the goal.** Human intervention is the exception, not the rule.

---

## 8. Tier Definitions

| Tier | Trust Threshold | Autonomy | Notes |
|------|----------------|----------|-------|
| Tier 1 | < 0.85 | None — human review required | Finance currently here (0.8482) |
| Tier 2 | ≥ 0.85 | Auto-promote with adversarial gate | Science (0.8794) + Technology (0.8934) |
| Tier 3 | ≥ 0.90 + 90 clean days | Full autonomous promotion | Target: Q3 2026 |

**Promotion path to Tier 3:**
- Trust score ≥ 0.90 on rolling window (last 1000 decisions)
- No active failure cluster in past 30 days
- 90-day clean cluster window completed (target: 2026-06-22)
- Adversarial review clearance on each promoted claim

---

## 9. 90-Day Clean Clock

| Domain | Clock Started | Target Date | Days Remaining (as of 2026-03-25) |
|--------|--------------|-------------|----------------------------------|
| Finance | 2026-03-24 | 2026-06-22 | ~89 days |
| Science | 2026-03-24 | 2026-06-22 | ~89 days |
| Technology | 2026-03-24 | 2026-06-22 | ~89 days |

The clock runs independently of pipeline cycles. No new failure clusters must trigger in any domain for the clock to complete.

---

## 10. Current Trust Scores (as of Phase 7 handoff)

| Domain | Trust Score | Tier | Decisions | Correct | Gap to T3 |
|--------|-------------|------|-----------|---------|-----------|
| Finance | 0.8482 | **Tier 1 ↓** | 336 | 285 | −0.0518 (T2 first) |
| Science | 0.8794 | Tier 2 | 282 | 248 | −0.0206 |
| Technology | 0.8934 | Tier 2 | 366 | 327 | −0.0066 |

**Technology is ~3 correct decisions from Tier 3 threshold.** One cycle at 90% accuracy crosses it.

---

## 11. Budget Status

| Metric | Value |
|--------|-------|
| Total budget | $75.00 |
| Total spend (Phase 7 handoff) | $61.36 |
| Remaining | $13.64 |
| Spend per cycle (estimated) | $0.50–$2.00 |
| LLM calls to date | ~5,016 |
| Cost alert threshold | $5.00/day |
| Active cost alert | YES — $8.13 today (build session artifact) |

---

## 12. Active Alerts (as of 2026-03-25)

| Alert Type | Severity | Detail |
|-----------|---------|--------|
| DEMOTION | HIGH | Finance at Tier 1 (trust: 0.8482) |
| FAILURE_CLUSTER | CRITICAL | Finance: 51 incorrect / 336 total (Phase 6 bulk resolution artifact) |
| FAILURE_CLUSTER | CRITICAL | Science: 34 incorrect / 282 total (Phase 6 bulk resolution artifact) |
| FAILURE_CLUSTER | CRITICAL | Technology: 39 incorrect / 366 total (Phase 6 bulk resolution artifact) |
| COST_ALERT | HIGH | $8.13 today (Phase 7 build session — will clear after 24h) |

**All failure cluster alerts are simulation artifacts** from Phase 6 bulk outcome resolution. Science and Technology clusters do NOT indicate real systematic failure — trust scores are healthy. Finance cluster reflects the genuine Cycle 17 demotion event. See Phase 6 Completion Report for full context.

---

## 13. Build History

| Phase | Description | Date | Claims | Spend |
|-------|-------------|------|--------|-------|
| Phase 1 | Core schema + agent framework | 2026-01 | 0 | ~$2 |
| Phase 2 | Vanguard extraction + raw intel pipeline | 2026-01 | ~100 | ~$8 |
| Phase 3 | Skeptic + Advocate debate layer | 2026-02 | ~300 | ~$12 |
| Phase 4 | Jarvis evaluation + trust scoring | 2026-02 | ~500 | ~$15 |
| Phase 5 | Tier 2 promotions + demotion guard | 2026-03 | 931 | ~$18 |
| Phase 6 | Rolling window + adversarial + cycles 17-22 | 2026-03-24 | 984 | ~$6 |
| Phase 7 | The Severance — autonomous operation | 2026-03-25 | 984 | ~$0.50 |

---

## 14. File Structure

```
NOOSPHEREV2/
├── cosmos-canvas.html              Phase 6 visualization (static HTML/React)
├── noosphere_daemon.py             Pipeline daemon (full autonomous cycle)
├── .env.example                    Environment variable template
├── OPERATIONAL_HANDOFF.md          This document
├── RUNBOOK.md                      Step-by-step operations guide
├── PHASE6_COMPLETION_REPORT.md     Phase 6 analysis and Tier 3 trajectory
├── "NOOSPHERE V2 documentation"    Original specification directory
└── .github/
    └── workflows/
        └── noosphere-daemon.yml    GitHub Actions cron schedule
```
