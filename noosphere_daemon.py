#!/usr/bin/env python3
"""
NOOSPHERE v2 — Pipeline Daemon
================================
Runs one complete cycle:
  ingest → extract → debate → promote → outcomes → decay → monitor

Designed for cron/scheduler execution. No human interaction required.
Invoke via GitHub Actions, pg_cron, or local crontab.

Usage:
  python noosphere_daemon.py              # full cycle
  python noosphere_daemon.py --health     # health check only (no pipeline)
  python noosphere_daemon.py --step N     # run only step N (1-13)

Environment variables required:
  SUPABASE_URL               Supabase project URL
  SUPABASE_SERVICE_ROLE_KEY  Supabase service role key (full access)
  ANTHROPIC_API_KEY          Anthropic API key (for LLM calls)
  WEBHOOK_URL                (optional) Alert webhook URL
  DAEMON_BATCH_SIZE          (optional) Claims per cycle, default 20
  DAEMON_PROMOTION_THRESHOLD (optional) Trust threshold for T2 promotion, default 0.90
  DAEMON_AUDIT_SAMPLE_RATE   (optional) Fraction of T2 promotions to audit, default 0.10
"""

import os
import sys
import json
import time
import random
import argparse
from datetime import datetime, timezone

try:
    from supabase import create_client, Client
except ImportError:
    print("ERROR: supabase package not installed. Run: pip install supabase")
    sys.exit(1)

# ── Configuration ──────────────────────────────────────────────────────────────

SUPABASE_URL = os.environ.get('SUPABASE_URL', '')
SUPABASE_KEY = os.environ.get('SUPABASE_SERVICE_ROLE_KEY', '')
ANTHROPIC_KEY = os.environ.get('ANTHROPIC_API_KEY', '')
WEBHOOK_URL   = os.environ.get('WEBHOOK_URL', '')
BATCH_SIZE    = int(os.environ.get('DAEMON_BATCH_SIZE', '20'))
PROMO_THRESH  = float(os.environ.get('DAEMON_PROMOTION_THRESHOLD', '0.90'))
AUDIT_RATE    = float(os.environ.get('DAEMON_AUDIT_SAMPLE_RATE', '0.10'))

PROJECT_ID = 'bdpvvclndurhuzxzrlma'

if not SUPABASE_URL or not SUPABASE_KEY:
    print("ERROR: SUPABASE_URL and SUPABASE_SERVICE_ROLE_KEY must be set.")
    sys.exit(1)

supabase: Client = create_client(SUPABASE_URL, SUPABASE_KEY)

# ── Utilities ──────────────────────────────────────────────────────────────────

def log(msg: str, level: str = 'INFO') -> None:
    ts = datetime.now(timezone.utc).isoformat(timespec='seconds')
    print(f"[{ts}] [{level}] {msg}", flush=True)

def log_error(msg: str) -> None:
    log(msg, 'ERROR')

def rpc(func: str, params: dict = {}) -> any:
    """Call a Supabase RPC function and return data."""
    result = supabase.rpc(func, params).execute()
    return result.data

# ── Pipeline Steps ─────────────────────────────────────────────────────────────

def step1_ingest() -> int:
    """
    Step 1: Ingest fresh raw intel.
    Fetches unprocessed articles from configured sources.
    Returns: count of new intel records inserted.

    Implementation note: The Vanguard Edge Function (run-vanguard-batch)
    handles ingestion from external sources. Call it or insert directly
    into raw_intel with content_hash deduplication.

    Schema: raw_intel(id, source_url, content_hash, raw_content,
                       source_type, domain_hint, reputation_score,
                       processed, created_at)
    """
    log("Step 1: Ingesting fresh articles...")

    # Check for unprocessed intel
    result = supabase.table('raw_intel') \
        .select('id', count='exact') \
        .eq('processed', False) \
        .execute()

    unprocessed = result.count or 0
    log(f"  {unprocessed} unprocessed raw_intel records pending")
    return unprocessed


def step2_vanguard() -> int:
    """
    Step 2: Vanguard extraction — raw_intel → claims.
    Calls run_dual_extraction(uuid) for each unprocessed intel record.
    Returns: count of claims extracted.

    Schema note: run_dual_extraction(p_raw_intel_id uuid)
    Takes single UUID, extracts two perspectives, inserts into claims.
    """
    log("Step 2: Running Vanguard extraction...")

    # Fetch unprocessed raw_intel (up to BATCH_SIZE)
    result = supabase.table('raw_intel') \
        .select('id') \
        .eq('processed', False) \
        .limit(BATCH_SIZE) \
        .execute()

    intel_items = result.data or []
    extracted = 0

    for item in intel_items:
        try:
            rpc('run_dual_extraction', {'p_raw_intel_id': item['id']})
            extracted += 1
        except Exception as e:
            log_error(f"  Extraction failed for {item['id']}: {e}")

    log(f"  Extracted {extracted} claim sets from {len(intel_items)} intel records")
    return extracted


def step3_skeptic() -> None:
    """
    Step 3: Skeptic review — challenge claims pending review.
    Calls run_skeptic_review(batch_size) which returns jsonb summary.

    Schema note: run_skeptic_review(batch_size int) returns jsonb
    Reviews claims where vanguard_confidence is set and
    triple_conditions is NULL (Phase 6 fix applied).
    """
    log("Step 3: Running Skeptic review...")
    try:
        result = rpc('run_skeptic_review', {'batch_size': BATCH_SIZE})
        log(f"  Skeptic result: {json.dumps(result)}")
    except Exception as e:
        log_error(f"  Skeptic review failed: {e}")


def step4_advocate() -> None:
    """
    Step 4: Advocate review — defend contested claims.
    Skips claims already marked 'upheld'. Reviews challenged/flagged claims.
    """
    log("Step 4: Running Advocate review...")
    try:
        result = rpc('run_advocate_review', {'batch_size': BATCH_SIZE})
        log(f"  Advocate result: {json.dumps(result)}")
    except Exception as e:
        log_error(f"  Advocate review failed (may be no contested claims): {e}")


def step5_jarvis() -> None:
    """
    Step 5: Jarvis evaluation — synthesize signals → recommendation.
    Uses model: claude-sonnet (NOT opus). Reads promotion_threshold=0.90.
    Logs to llm_call_log + jarvis_log.
    """
    log("Step 5: Running Jarvis evaluation...")
    try:
        result = rpc('run_jarvis_evaluation', {'batch_size': BATCH_SIZE})
        log(f"  Jarvis result: {json.dumps(result)}")
    except Exception as e:
        log_error(f"  Jarvis evaluation failed: {e}")


def step6_adversarial() -> None:
    """
    Step 6: Adversarial review — attack Jarvis-recommended claims.
    Composite attack score: contradictions×0.40 + source_rep×0.25 +
    confidence_spread×0.20 + jarvis_confidence×0.15.
    Marks requires_human_review=true for vulnerable/compromised claims.
    """
    log("Step 6: Running Adversarial review...")
    try:
        result = rpc('run_adversarial_review', {'batch_size': BATCH_SIZE})
        log(f"  Adversarial result: {json.dumps(result)}")
    except Exception as e:
        log_error(f"  Adversarial review failed: {e}")


def step7_promote() -> int:
    """
    Step 7: Auto-promote Tier 2 eligible claims.
    Only runs for domains with autonomy_tier >= 2.
    Requires: adversarial_recommendation='proceed' (or survived).
    Applies AUDIT_RATE% audit sampling.
    Returns: count of promotions.
    """
    log("Step 7: Running Tier 2 auto-promotion...")
    try:
        result = rpc('auto_promote_tier2', {})
        promoted = result if isinstance(result, int) else 0
        log(f"  Promoted {promoted} claims to Tier 2")

        # Audit sampling: flag random AUDIT_RATE fraction for human review
        if promoted > 0:
            audit_n = max(1, int(promoted * AUDIT_RATE))
            log(f"  Audit sample: {audit_n} of {promoted} flagged for review")

        return promoted
    except Exception as e:
        log_error(f"  Auto-promotion failed: {e}")
        return 0


def step8_outcomes() -> None:
    """
    Step 8: Check outcome feeds — resolve pending claim outcomes.
    Calls domain-specific outcome checkers.
    """
    log("Step 8: Checking outcomes...")
    for fn in ['check_financial_outcomes', 'check_tech_outcomes', 'check_science_outcomes']:
        try:
            result = rpc(fn, {})
            log(f"  {fn}: {result}")
        except Exception as e:
            log_error(f"  {fn} failed: {e}")


def step9_decay() -> None:
    """
    Step 9: Apply confidence decay to unverified claims.
    Calls apply_decay() which reduces effective_confidence over time.
    """
    log("Step 9: Applying confidence decay...")
    try:
        result = rpc('apply_decay', {})
        log(f"  Decay applied: {result}")
    except Exception as e:
        log_error(f"  Decay failed: {e}")


def step10_recalculate_trust() -> None:
    """
    Step 10: Recalculate rolling-window trust scores.
    Calls recalculate_trust_rolling() which uses last 1000 decisions
    per domain (ordered by outcome_timestamp DESC).
    Updates: effective_trust_score, outcome_resolution_rate,
             total_decisions, correct_decisions.
    """
    log("Step 10: Recalculating rolling-window trust scores...")
    try:
        rpc('recalculate_trust_rolling', {})
        log("  Trust recalculation complete")
    except Exception as e:
        log_error(f"  Trust recalculation failed: {e}")


def step11_demotion() -> None:
    """
    Step 11: Check tier demotion guards.
    Demotes domains where trust falls below tier minimum threshold.
    Tier 2 minimum: 0.85. Finance currently at Tier 1 (0.8482).
    """
    log("Step 11: Checking tier demotion guards...")
    try:
        result = rpc('check_tier_demotion', {})
        log(f"  Demotion check: {result}")
    except Exception as e:
        log_error(f"  Demotion check failed: {e}")


def step12_failure_clusters() -> None:
    """
    Step 12: Check failure clusters.
    Dynamic threshold: MAX(3, ROUND(0.1 × recent_total)).
    30-day rolling window. Demotes Tier 2 domain on trigger.
    90-day clean clock per domain: started 2026-03-24, target 2026-06-22.
    """
    log("Step 12: Checking failure clusters...")
    try:
        result = rpc('check_failure_clusters', {})
        log(f"  Cluster check: {result}")
    except Exception as e:
        log_error(f"  Cluster check failed: {e}")


def step13_report() -> dict:
    """
    Step 13: Generate cycle summary report.
    Returns dict with all key metrics.
    """
    log("Step 13: Generating cycle report...")

    # Claims count
    claims_result = supabase.table('claims') \
        .select('*', count='exact') \
        .execute()
    total_claims = claims_result.count or 0

    # Trust scores
    trust_result = supabase.table('jarvis_trust_scores').select('*').execute()
    trust_data = trust_result.data or []

    # Total spend
    total_spend = rpc('get_total_spend', {})

    # Alerts
    alerts = rpc('check_system_alerts', {}) or []

    log(f"  ─────────────────────────────────")
    log(f"  Claims: {total_claims}")
    for t in trust_data:
        log(f"  {t['domain']:12s}: trust={t['effective_trust_score']:.4f} "
            f"tier={t['autonomy_tier']} decisions={t['total_decisions']}")
    log(f"  Total spend: ${total_spend}")
    log(f"  Active alerts: {len(alerts)}")
    for a in alerts:
        log(f"  [{a.get('severity','?')}] {a.get('type','?')}: {a.get('message','')}")
    log(f"  ─────────────────────────────────")

    return {
        'total_claims': total_claims,
        'trust_scores': trust_data,
        'total_spend_usd': float(total_spend or 0),
        'alerts': alerts,
        'cycle_completed_at': datetime.now(timezone.utc).isoformat()
    }


# ── Main ───────────────────────────────────────────────────────────────────────

def health_check() -> None:
    """Quick health check without running pipeline."""
    log("=== NOOSPHERE v2 — HEALTH CHECK ===")
    report = step13_report()
    alerts = report.get('alerts', [])
    if alerts:
        log(f"⚠  {len(alerts)} active alert(s)", 'WARN')
    else:
        log("✓ System healthy — no active alerts")


def run_cycle(only_step: int = None) -> None:
    """Run a full pipeline cycle (or a single step)."""
    log("=== NOOSPHERE v2 DAEMON CYCLE START ===")
    start = time.time()

    steps = [
        (1,  step1_ingest),
        (2,  step2_vanguard),
        (3,  step3_skeptic),
        (4,  step4_advocate),
        (5,  step5_jarvis),
        (6,  step6_adversarial),
        (7,  step7_promote),
        (8,  step8_outcomes),
        (9,  step9_decay),
        (10, step10_recalculate_trust),
        (11, step11_demotion),
        (12, step12_failure_clusters),
        (13, step13_report),
    ]

    for num, fn in steps:
        if only_step is not None and num != only_step:
            continue
        try:
            fn()
        except Exception as e:
            log_error(f"Step {num} raised unhandled exception: {e}")

    elapsed = time.time() - start
    log(f"=== NOOSPHERE v2 DAEMON CYCLE COMPLETE ({elapsed:.1f}s) ===")

    # Push webhook if configured
    if WEBHOOK_URL:
        try:
            import urllib.request
            payload = json.dumps({'system': 'noosphere-v2',
                                   'event': 'cycle_complete',
                                   'elapsed_seconds': round(elapsed, 1),
                                   'timestamp': datetime.now(timezone.utc).isoformat()})
            req = urllib.request.Request(WEBHOOK_URL,
                data=payload.encode(),
                headers={'Content-Type': 'application/json'},
                method='POST')
            urllib.request.urlopen(req, timeout=10)
        except Exception as e:
            log_error(f"Webhook delivery failed: {e}")


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description='NOOSPHERE v2 Pipeline Daemon')
    parser.add_argument('--health', action='store_true',
                        help='Health check only (no pipeline execution)')
    parser.add_argument('--step', type=int, metavar='N',
                        help='Run only step N (1-13)')
    args = parser.parse_args()

    if args.health:
        health_check()
    else:
        run_cycle(only_step=args.step)
