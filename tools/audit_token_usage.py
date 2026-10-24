#!/usr/bin/env python3
"""Read HerNess usage counters without exporting prompts, account IDs or code.

Provider token counters and local UTF-8/JSON sizes are deliberately separate.
This never calls a provider or changes conversations/settings.
"""
import argparse
import collections
import hashlib
import json
from pathlib import Path


def counter(event, key):
    value = event.get(key)
    return value if isinstance(value, int) and not isinstance(value, bool) and value >= 0 else None


def measured_input(event):
    total = counter(event, "totalInputTokens")
    if total is not None:
        return total
    raw = counter(event, "inputTokens")
    if raw is None:
        return None
    if event.get("api") == "anthropic":
        return raw + (counter(event, "cachedTokens") or 0) + (counter(event, "cacheWriteTokens") or 0)
    return raw


def totals(events):
    inputs = [measured_input(event) for event in events]
    cached = sum(counter(event, "cachedTokens") or 0 for event in events)
    total = sum(value for value in inputs if value is not None)
    cache_reported = sum(counter(event, "cachedTokens") is not None for event in events)
    return {
        "requests": len(events),
        "input_reported_requests": sum(value is not None for value in inputs),
        "cache_reported_requests": cache_reported,
        "input_tokens": total,
        "cached_input_tokens": cached,
        "cache_write_tokens": sum(counter(event, "cacheWriteTokens") or 0 for event in events),
        "fresh_input_tokens_on_cache_reported_requests": sum(
            max(0, value - counter(event, "cachedTokens"))
            for event, value in zip(events, inputs)
            if value is not None and counter(event, "cachedTokens") is not None
        ),
        "output_tokens": sum(counter(event, "outputTokens") or 0 for event in events),
        "reasoning_tokens": sum(counter(event, "reasoningTokens") or 0 for event in events),
        "reasoning_reported_requests": sum(counter(event, "reasoningTokens") is not None for event in events),
        "retries": sum(counter(event, "retryCount") or 0 for event in events),
        "peak_input_tokens": max((value for value in inputs if value is not None), default=0),
        "raw_cache_share": cached / total if total and cache_reported == len(events) else None,
        "strategies": dict(collections.Counter(event.get("strategy", "unknown") for event in events)),
    }


def context_sizes(conversation):
    messages = conversation.get("modelContext") or []
    roles = collections.Counter()
    tools = collections.Counter()
    provider_items = collections.Counter()
    duplicates = collections.Counter()
    seen = set()
    for message in messages:
        body = (message.get("content") or "").encode("utf-8")
        roles[message.get("role", "unknown")] += len(body)
        if message.get("role") == "tool":
            name = message.get("name", "unknown")
            tools[name] += len(body)
            identity = (name, hashlib.sha256(body).digest())
            if identity in seen:
                duplicates[name] += len(body)
            seen.add(identity)
        for item in message.get("providerItems") or []:
            provider_items[item.get("type", "unknown")] += len(
                json.dumps(item, ensure_ascii=False, separators=(",", ":")).encode("utf-8")
            )
    return {
        "messages": len(messages),
        "body_utf8_bytes_by_role": dict(roles),
        "tool_result_utf8_bytes_by_tool": dict(tools),
        "exact_duplicate_tool_result_utf8_bytes": dict(duplicates),
        "provider_item_json_bytes_by_type": dict(provider_items),
        "note": "Current retained context only. JSON bytes of encrypted reasoning are not provider token counts.",
    }


def compaction(events):
    """Compaction verdicts logged since compactionTrace existed; older events have none."""
    traced = [event["compactionTrace"] for event in events if isinstance(event.get("compactionTrace"), dict)]
    strategies = [event.get("strategy") for event in events if isinstance(event.get("compactionTrace"), dict)]
    return {
        "traced_requests": len(traced),
        "rewriting_prunes": sum(strategy not in (None, "none") for strategy in strategies),
        "strategies": dict(collections.Counter(strategies)),
        "context_windows": dict(collections.Counter(trace.get("contextWindow") for trace in traced)),
        "trigger_tokens": dict(collections.Counter(trace.get("triggerTokens") for trace in traced)),
        "route_changed_requests": sum(bool(trace.get("routeChanged")) for trace in traced),
        "forced_requests": sum(bool(trace.get("forced")) for trace in traced),
    }


def audit(events, conversations):
    routes = collections.defaultdict(list)
    chats = collections.defaultdict(list)
    for event in events:
        routes[(event.get("provider", "unknown"), event.get("model", "unknown"), event.get("api", "unknown"))].append(event)
        chats[event.get("conversationID")].append(event)
    by_id = {conversation.get("id"): conversation for conversation in conversations}
    return {
        "measurement": "Saved provider usage counters; no new provider requests",
        "totals": totals(events),
        "efforts": dict(collections.Counter(event.get("selectedEffort", "unreported") for event in events)),
        "compaction": compaction(events),
        "routes": [dict(provider=route[0], model=route[1], api=route[2], **totals(group)) for route, group in sorted(routes.items())],
        "largest_chats": [
            dict(rank=rank, **totals(group), current_retained_context=context_sizes(by_id.get(chat_id, {})))
            for rank, (chat_id, group) in enumerate(
                sorted(chats.items(), key=lambda entry: totals(entry[1])["input_tokens"], reverse=True)[:5], 1
            )
        ],
    }


def main():
    support = Path.home() / "Library/Application Support/DotsHarness"
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--usage", type=Path, default=support / "context-usage.json")
    parser.add_argument("--sessions", type=Path, default=support / "sessions.json")
    parser.add_argument("--output", type=Path)
    args = parser.parse_args()
    events = json.loads(args.usage.read_text())
    conversations = json.loads(args.sessions.read_text()) if args.sessions.exists() else []
    result = json.dumps(audit(events, conversations), ensure_ascii=False, indent=2) + "\n"
    if args.output:
        args.output.write_text(result)
    else:
        print(result, end="")


if __name__ == "__main__":
    main()
