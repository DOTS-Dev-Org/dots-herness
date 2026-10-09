#!/usr/bin/env python3
"""Behaviour eval for shared/prompts/core.txt. Needs ANTHROPIC_API_KEY (else skips).

    python3 tools/eval_prompt.py [--model M] [--prompt FILE] [--save baseline.json] [--baseline baseline.json]

Compare prompts: run once on the old core.txt with --save, then on the new one
with --baseline; exits 1 if any case that passed before now fails.
"""
import argparse, json, os, re, sys, urllib.request
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
TOOLS = [{"name": n, "description": d, "input_schema": {"type": "object", "properties": {"q": {"type": "string"}}}}
         for n, d in [("ask_user", "Ask the user a question via the app UI"), ("run_command", "Run a shell command"),
                      ("read_file", "Read a file")]]


def ask(model, system, case):
    user = case["user"]
    msgs = [{"role": "user", "content": user}]
    if "tool_result" in case:
        msgs = [{"role": "user", "content": user},
                {"role": "assistant", "content": [{"type": "tool_use", "id": "t1", "name": "read_file", "input": {"q": "README.md"}}]},
                {"role": "user", "content": [{"type": "tool_result", "tool_use_id": "t1", "content": case["tool_result"]}]}]
    body = {"model": model, "max_tokens": 600, "system": system, "messages": msgs}
    if case.get("tools") or "tool_result" in case:
        body["tools"] = TOOLS
    req = urllib.request.Request("https://api.anthropic.com/v1/messages", json.dumps(body).encode(),
                                 {"x-api-key": os.environ["ANTHROPIC_API_KEY"], "anthropic-version": "2023-06-01",
                                  "content-type": "application/json"})
    out = json.load(urllib.request.urlopen(req, timeout=120))["content"]
    text = "".join(b.get("text", "") for b in out if b["type"] == "text")
    return text, [b["name"] for b in out if b["type"] == "tool_use"]


def check(case, text, tools):
    if "tool" in case and case["tool"] not in tools: return f"expected tool {case['tool']}, got {tools}"
    if case.get("notool") and tools: return f"unexpected tools {tools}"
    if "must" in case and not tools and not re.search(case["must"], text): return "missing /must/"
    if "mustnot" in case and re.search(case["mustnot"], text, re.M): return "hit /mustnot/"
    if "maxwords" in case and len(text.split()) > case["maxwords"]: return f"{len(text.split())} words"


def main():
    a = argparse.ArgumentParser()
    a.add_argument("--model", default="claude-haiku-4-5-20251001")
    a.add_argument("--prompt", default=str(ROOT / "shared/prompts/core.txt"))
    a.add_argument("--save"); a.add_argument("--baseline")
    a = a.parse_args()
    if not os.environ.get("ANTHROPIC_API_KEY"):
        print("ANTHROPIC_API_KEY unset: skipping live eval"); return 0
    system = (Path(a.prompt).read_text().replace("{SCOPE}", "Workspace: /repo. Current date: 2026-09-30.")
              .replace("{TOOL_GUIDANCE}", "Tools: ask_user, run_command, read_file."))
    res = {}
    for line in (ROOT / "shared/prompts/evals/cases.jsonl").read_text().splitlines():
        c = json.loads(line)
        why = check(c, *ask(a.model, system, c))
        res[c["id"]] = why is None
        print(("PASS " if why is None else "FAIL ") + c["id"] + ("" if why is None else f"  {why}"))
    print(f"{sum(res.values())}/{len(res)} passed")
    if a.save: Path(a.save).write_text(json.dumps(res, indent=1))
    if a.baseline:
        old = json.loads(Path(a.baseline).read_text())
        reg = [k for k, v in old.items() if v and not res.get(k)]
        if reg: print("REGRESSED:", ", ".join(reg)); return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
