#!/usr/bin/env python3
"""Stdio MCP server exposing eval_prompt.py's mocked request tools to `claude -p`.

Env: EVAL_LOG (file; each underlying tool invocation appended as a line),
EVAL_DISCOVERED (comma-separated tool names already discovered by the seeded history).
"""
import json, os, sys
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from eval_prompt import TOOLS, mock_call

state = {"discovered": set(filter(None, os.environ.get("EVAL_DISCOVERED", "").split(","))), "stored": {}, "invoked": []}


def reply(id_, result):
    sys.stdout.write(json.dumps({"jsonrpc": "2.0", "id": id_, "result": result}) + "\n"); sys.stdout.flush()


for line in sys.stdin:
    msg = json.loads(line)
    method, id_ = msg.get("method"), msg.get("id")
    if id_ is None: continue  # notifications
    if method == "initialize":
        reply(id_, {"protocolVersion": msg["params"].get("protocolVersion", "2025-06-18"),
                    "capabilities": {"tools": {}}, "serverInfo": {"name": "eval", "version": "1"}})
    elif method == "tools/list":
        reply(id_, {"tools": [{"name": t["name"], "description": t["description"], "inputSchema": t["input_schema"]} for t in TOOLS]})
    elif method == "tools/call":
        p = msg["params"]
        before = len(state["invoked"])
        text = mock_call(p["name"], p.get("arguments") or {}, state, call_id=str(id_))
        with open(os.environ["EVAL_LOG"], "a") as f:
            for name in state["invoked"][before:]: f.write(name + "\n")
        reply(id_, {"content": [{"type": "text", "text": text}]})
    else:
        sys.stdout.write(json.dumps({"jsonrpc": "2.0", "id": id_, "error": {"code": -32601, "message": method}}) + "\n"); sys.stdout.flush()
