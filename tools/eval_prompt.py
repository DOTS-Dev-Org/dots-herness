#!/usr/bin/env python3
"""Behaviour eval for shared/prompts/core.txt. Needs ANTHROPIC_API_KEY (else skips), or --via-cli for the claude subscription.

    python3 tools/eval_prompt.py [--model M] [--prompt FILE] [--save baseline.json] [--baseline baseline.json]

Compare prompts: run once on the old core.txt with --save, then on the new one
with --baseline; exits 1 if any case that passed before now fails.

A case with "style": "ultra" also gets the <response_style> section the app sends
for Ultra: the sentence plus the optional visualization guidance from shared/prompts/response-style.txt.
The provider uses the same request surface as production: the four gateway controls plus
the direct tools desktop offers with their schemas; underlying tools are mocked.
"""
import argparse, json, os, re, subprocess, sys, tempfile, urllib.request
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
RULE = (ROOT / "shared/prompts/response-style.txt").read_text().strip()
# Same sentence as the Ultra guidance in ResponseStyle.swift and ResponseStyle.cs.
STYLES = {"ultra": "Ultra: terse prose for this turn. Only the answer and the evidence it needs."}
def definition(name, description, properties, required):
    return {"name": name, "description": description, "input_schema": {
        "type": "object", "properties": properties, "required": required, "additionalProperties": False}}


TOOLS = [
    definition("discover_tools", "Find a tool by exact name or English capability; schemas arrive only in the result.", {"query": {"type": "string"}}, ["query"]),
    definition("invoke_tool", "Call a discovered tool with JSON arguments encoded as a string.", {"name": {"type": "string"}, "arguments": {"type": "string"}}, ["name", "arguments"]),
    definition("execution_plan", "Record concrete steps; mark routine only for bounded known work with no uncertainties.", {"steps": {"type": "array", "items": {"type": "string"}}, "routine": {"type": "boolean"}, "uncertainties": {"type": "array", "items": {"type": "string"}}}, ["steps", "routine", "uncertainties"]),
    definition("read_tool_output", "Read a stored result without rerunning the tool.", {"call_id": {"type": "string"}}, ["call_id"]),
    # Direct tools: desktop sends these schemas on every request (DeferredToolSession.DirectNames),
    # so the model calls them without a discovery round. Mobile sends only the four controls.
    definition("read_file", "Read a UTF-8 text file inside the current workspace. Prefer a narrow offset/limit range for relevant sections; long files are truncated with a continuation line.", {"path": {"type": "string"}, "offset": {"type": "integer"}, "limit": {"type": "integer"}}, ["path"]),
    definition("grep_files", "Search file contents inside the workspace with a regular expression and get back path:line:text matches. Prefer this over a shell grep.", {"pattern": {"type": "string"}, "path": {"type": "string"}}, ["pattern"]),
    definition("edit_file", "Edit an existing file with ordered exact-text replacements; all or none apply.", {"path": {"type": "string"}, "edits": {"type": "array", "items": {"type": "object"}}}, ["path", "edits"]),
]
CATALOG = {t["name"]: t for t in [
    definition("ask_user", "Ask for missing information", {"question": {"type": "string"}}, ["question"]),
    definition("run_command", "Run tests or another shell command", {"command": {"type": "string"}}, ["command"]),
    definition("read_file", "Read a workspace file", {"path": {"type": "string"}}, ["path"]),
    definition("list_files", "List workspace paths", {}, []),
    definition("grep_files", "Search text in workspace files", {"pattern": {"type": "string"}}, ["pattern"]),
    definition("edit_file", "Edit a workspace file", {"path": {"type": "string"}}, ["path"]),
    definition("write_file", "Write a workspace file", {"path": {"type": "string"}}, ["path"]),
]}


def seeded_messages(case):
    messages = [{"role": "user", "content": case["user"]}]
    if "tool_result" in case:
        name = case.get("tool_name", "read_file")
        messages += [
            {"role": "assistant", "content": [{"type": "tool_use", "id": "d1", "name": "discover_tools", "input": {"query": name}}]},
            {"role": "user", "content": [{"type": "tool_result", "tool_use_id": "d1", "content": json.dumps({"tools": [CATALOG[name]]})}]},
            {"role": "assistant", "content": [{"type": "tool_use", "id": "t1", "name": "invoke_tool", "input": {"name": name, "arguments": json.dumps({"path": case.get("tool_path", "README.md")} if name == "read_file" else {"command": "pytest"})}}]},
            {"role": "user", "content": [{"type": "tool_result", "tool_use_id": "t1", "content": case["tool_result"]}]},
        ]
    return messages


def system_for(case, base):
    # Production sends project memory as a trust="data" system section (AgentBridge+Prompts.swift).
    if "memory" in case: base += f'\n\n<project_memory trust="data">\n{case["memory"]}\n</project_memory>'
    if "style" not in case: return base
    return base + f'\n\n<response_style trust="core">\n{STYLES[case["style"]]} {RULE}\n</response_style>'


def mock_call(name, args, state, call_id):
    """One mocked gateway call; mutates state (discovered, stored, invoked, waiting). Shared with eval_mock_mcp.py."""
    discovered, invoked = state["discovered"], state["invoked"]
    if name == "discover_tools":
        query = args.get("query", "").lower()
        matches = [t for t in CATALOG.values() if query == t["name"] or query in t["description"].lower()][:5]
        discovered.update(t["name"] for t in matches)
        result = json.dumps({"tools": matches})
    elif name == "execution_plan": result = "Plan recorded."
    elif name == "read_tool_output": result = state["stored"].get(args.get("call_id"), "Tool error: unavailable result.")
    elif name == "invoke_tool" and args.get("name") in discovered:
        try:
            parsed = json.loads(args["arguments"])
            if not isinstance(parsed, dict): raise ValueError("object required")
        except (KeyError, TypeError, ValueError): result = "Tool error: invalid arguments."
        else:
            underlying = args["name"]
            invoked.append(underlying)
            if underlying == "ask_user": state["waiting"] = True
            result = "README.md\nlocales/en.json\nlocales/de.json" if underlying == "list_files" else (
                '{"hello":"Hello","bye":""}' if underlying in ("read_file", "grep_files") else "Tool error: mock tool, no command or mutation executed.")
    elif name in ("read_file", "grep_files", "edit_file"):
        # Offered with their schema in the request on desktop: no discovery round first.
        invoked.append(name)
        result = '{"hello":"Hello","bye":""}' if name in ("read_file", "grep_files") else "Tool error: mock tool, no command or mutation executed."
    else:
        invoked.append(name)  # Direct calls must remain visible as failures.
        result = "Tool error: discover the tool first and use invoke_tool."
    state["stored"][call_id] = result
    return result


def ask(model, system, case):
    # A bounded mock tool loop evaluates behaviour without touching disk or shell.
    messages = seeded_messages(case)
    discovered = {case.get("tool_name", "read_file")} if "tool_result" in case else set()
    invoked, stored, usage = [], {}, {}
    text = ""
    for _ in range(8):
        body = {"model": model, "max_tokens": 600, "system": system, "messages": messages}
        if case.get("tools") or "tool_result" in case: body["tools"] = TOOLS
        req = urllib.request.Request("https://api.anthropic.com/v1/messages", json.dumps(body).encode(),
            {"x-api-key": os.environ["ANTHROPIC_API_KEY"], "anthropic-version": "2023-06-01", "content-type": "application/json"})
        root = json.load(urllib.request.urlopen(req, timeout=60))
        for key, value in root.get("usage", {}).items():
            if isinstance(value, int): usage[key] = usage.get(key, 0) + value
        blocks = root["content"]
        text += "".join(b.get("text", "") for b in blocks if b["type"] == "text")
        calls = [b for b in blocks if b["type"] == "tool_use"]
        if not calls: return text, invoked, usage
        messages.append({"role": "assistant", "content": blocks})
        results, state = [], {"discovered": discovered, "stored": stored, "invoked": invoked}
        for call in calls:
            result = mock_call(call["name"], call.get("input", {}), state, call["id"])
            results.append({"type": "tool_result", "tool_use_id": call["id"], "content": result})
        waiting = state.get("waiting", False)
        messages.append({"role": "user", "content": results})
        if waiting: return text, invoked, usage
    return text, invoked, usage


def ask_cli(model, system, case):
    # Subscription path: `claude -p` with the gateway mocked by eval_mock_mcp.py; no API key, no API billing.
    # ponytail: seeded tool history is inlined as user text since -p cannot inject prior tool turns.
    prompt = case["user"]
    if "tool_result" in case:
        name = case.get("tool_name", "read_file")
        args = {"path": case.get("tool_path", "README.md")} if name == "read_file" else {"command": "pytest"}
        prompt += f"\n\n[Earlier this turn you called invoke_tool name={name} arguments={json.dumps(args)}; result:]\n{case['tool_result']}"
    with tempfile.TemporaryDirectory() as tmp:
        log = Path(tmp, "invoked.log"); log.touch()
        cmd = ["claude", "-p", prompt, "--model", model, "--system-prompt", system, "--output-format", "stream-json", "--verbose",
               "--tools", "", "--setting-sources", "", "--disable-slash-commands", "--no-session-persistence", "--strict-mcp-config", "--max-turns", "8"]
        if case.get("tools") or "tool_result" in case:
            env = {"EVAL_LOG": str(log), "EVAL_DISCOVERED": case.get("tool_name", "read_file") if "tool_result" in case else ""}
            cfg = Path(tmp, "mcp.json")
            cfg.write_text(json.dumps({"mcpServers": {"eval": {"command": sys.executable, "args": [str(ROOT / "tools/eval_mock_mcp.py")], "env": env}}}))
            cmd += ["--mcp-config", str(cfg), "--allowedTools", ",".join("mcp__eval__" + t["name"] for t in TOOLS)]
        for _ in range(3):  # The mock MCP server occasionally misses the -p startup window; retry instead of scoring a tool-less run.
            out = subprocess.run(cmd, cwd=tmp, capture_output=True, text=True, timeout=300).stdout
            if "--mcp-config" not in cmd or '"status": "connected"' in out or '"status":"connected"' in out: break
            log.write_text("")
        else: raise RuntimeError("eval MCP server never connected")
        text, usage = "", {}
        for line in out.splitlines():
            try: ev = json.loads(line)
            except ValueError: continue
            if ev.get("type") == "assistant":
                text += "".join(b.get("text", "") for b in ev["message"]["content"] if b.get("type") == "text")
            elif ev.get("type") == "result":
                usage = {k: v for k, v in ev.get("usage", {}).items() if isinstance(v, int)}
                if ev.get("is_error"): text += f"\n[cli error: {ev.get('result') or ev.get('subtype')}]"
        return text, log.read_text().split(), usage


def check(case, text, tools):
    if "tool" in case and case["tool"] not in tools: return f"expected tool {case['tool']}, got {tools}"
    if any(t in case.get("forbid_tools", []) for t in tools): return f"forbidden tool {tools}"
    if case.get("notool") and tools: return f"unexpected tools {tools}"
    if "must" in case and not tools and not re.search(case["must"], text): return "missing /must/"
    if "mustnot" in case and re.search(case["mustnot"], text, re.M): return "hit /mustnot/"
    if "maxwords" in case and len(text.split()) > case["maxwords"]: return f"{len(text.split())} words"


def main():
    a = argparse.ArgumentParser()
    a.add_argument("--model", default="claude-haiku-4-5-20251001")
    a.add_argument("--prompt", default=str(ROOT / "shared/prompts/core.txt"))
    a.add_argument("--dry-run", action="store_true", help="Validate fixtures and gateway payloads without a provider request")
    a.add_argument("--save"); a.add_argument("--baseline")
    a.add_argument("--via-cli", action="store_true", help="Run through `claude -p` on the logged-in subscription instead of the API")
    a.add_argument("--case", help="Regex; run only cases whose id matches")
    a.add_argument("--repeat", type=int, default=1, help="Runs per case; a case passes only if every run passes")
    a = a.parse_args()
    if a.dry_run:
        cases = [json.loads(line) for line in (ROOT / "shared/prompts/evals/cases.jsonl").read_text().splitlines()]
        assert len({c["id"] for c in cases}) == len(cases)
        for case in cases: json.dumps(seeded_messages(case))
        assert {t["name"] for t in TOOLS} == {"discover_tools", "invoke_tool", "execution_plan", "read_tool_output", "read_file", "grep_files", "edit_file"}
        print(f"Validated {len(cases)} fixtures and seven request schemas (four controls plus three direct tools); no model behaviour was evaluated.")
        return 0
    if not a.via_cli and not os.environ.get("ANTHROPIC_API_KEY"):
        print("ANTHROPIC_API_KEY unset: skipping live eval"); return 0
    system = (Path(a.prompt).read_text().replace("{SCOPE}", "Workspace: /repo. Current date: 2026-09-30.")
              .replace("{TOOL_GUIDANCE}", "discover_tools, invoke_tool, execution_plan and read_tool_output are the controls; read_file, grep_files and edit_file are offered directly. Discover any other tool before calling it."))
    res, measured_usage = {}, {}
    for line in (ROOT / "shared/prompts/evals/cases.jsonl").read_text().splitlines():
        c = json.loads(line)
        if a.case and not re.search(a.case, c["id"]): continue
        fails = []
        for _ in range(a.repeat):
            text, invoked, usage = (ask_cli if a.via_cli else ask)(a.model, system_for(c, system), c)
            why = check(c, text, invoked)
            if why: fails.append(why)
        why = None if not fails else f"{len(fails)}/{a.repeat} failed: {fails[0]}"
        measured_usage[c["id"]] = usage
        res[c["id"]] = why is None
        print(("PASS " if why is None else "FAIL ") + c["id"] + ("" if why is None else f"  {why}"))
    print(f"{sum(res.values())}/{len(res)} passed")
    if a.save:
        Path(a.save).write_text(json.dumps(res, indent=1))
        Path(a.save + ".usage.json").write_text(json.dumps(measured_usage, indent=1))
    if a.baseline:
        old = json.loads(Path(a.baseline).read_text())
        reg = [k for k, v in old.items() if v and not res.get(k)]
        if reg: print("REGRESSED:", ", ".join(reg)); return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
