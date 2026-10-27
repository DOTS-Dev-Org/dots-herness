#!/usr/bin/env python3
"""Report token composition and observed cache changes without reading prompt text.

Usage: python3 tools/context_economy_report.py --last 20 [--input context-usage.json]
Composition is estimated; provider usage and cache evidence are reported separately.
Before/after compaction differences are observations, not causal billing attribution.
"""
import argparse
import collections
import json
from pathlib import Path


def summarize(events):
    main = [e for e in events if e.get('requestKind') == 'main']
    fields = ('totalInputTokens', 'uncachedInputTokens', 'cachedTokens', 'cacheWriteTokens', 'outputTokens', 'reasoningTokens')
    totals = {k: sum(e.get(k, 0) or 0 for e in main) for k in fields}
    composition = collections.Counter()
    for event in main:
        composition.update({k: v for k, v in event.get('inputComposition', {}).items() if k.endswith('Tokens')})
    previous = {}
    comparisons = []
    for event in main:
        key = (event.get('conversationID'), event.get('provider'), event.get('model'))
        before = previous.get(key)
        trace = event.get('compactionTrace') or {}
        if before and event.get('strategy') not in (None, 'none'):
            comparisons.append({
                'strategy': event.get('strategy'),
                'before': {k: before.get(k) for k in fields[:4]},
                'after': {k: event.get(k) for k in fields[:4]},
                'cache_evidence': (event.get('cacheReuseEvidence') or {}).get('classification', 'unknown'),
            })
        previous[key] = event
    summaries = [e for e in events if e.get('requestKind') == 'compactionSummary']
    return {
        'main_requests': len(main),
        'provider_reported_totals': totals,
        'provider_field_coverage': {k: sum(isinstance(e.get(k), int) for e in main) for k in fields},
        'fresh_input_tokens_in_reported_totals': totals['uncachedInputTokens'] + totals['cacheWriteTokens'],
        'raw_cache_ratio': totals['cachedTokens'] / totals['totalInputTokens'] if totals['totalInputTokens'] else None,
        'cache_evidence_counts': dict(collections.Counter((e.get('cacheReuseEvidence') or {}).get('classification', 'unknown') for e in main)),
        'estimated_composition': dict(composition),
        'selected_effort_counts': dict(collections.Counter(e.get('selectedEffort', 'unknown') for e in main)),
        'requested_effort_counts': dict(collections.Counter(e.get('requestedEffort') or 'unavailable' for e in main)),
        'compaction_summary_requests': len(summaries),
        'compaction_summary_input_tokens': sum(e.get('totalInputTokens', 0) or 0 for e in summaries),
        'compaction_summary_output_tokens': sum(e.get('outputTokens', 0) or 0 for e in summaries),
        'compaction_cache_observations': comparisons,
        'note': 'Composition is estimated. Raw cache ratios do not prove eligible-prefix reuse or billing savings. Before/after observations may include new input and routing effects.',
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--input', type=Path, default=Path.home() / 'Library/Application Support/DotsHarness/context-usage.json')
    parser.add_argument('--last', type=int)
    parser.add_argument('--baseline', type=Path, help='Compare with a saved report for a comparable workload')
    args = parser.parse_args()
    events = json.loads(args.input.read_text())
    if args.last: events = events[-max(1, args.last):]
    report = summarize(events)
    if args.baseline:
        baseline = json.loads(args.baseline.read_text())
        report['baseline_comparison'] = {
            'before_main_requests': baseline.get('main_requests'),
            'after_main_requests': report['main_requests'],
            'reported_token_deltas': {k: value - baseline.get('provider_reported_totals', {}).get(k, 0) for k, value in report['provider_reported_totals'].items()},
            'note': 'Only comparable tasks, providers and model settings support a savings comparison; different windows are descriptive only.',
        }
    print(json.dumps(report, indent=2, ensure_ascii=False))


if __name__ == '__main__': main()
