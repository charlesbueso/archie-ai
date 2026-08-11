"""Tool-call logging in the exact JSONL shape the dashboard already renders
({ts, direction, payload} with tools/call framing), so dashboard/index.html
keeps working unchanged against the new server."""
from __future__ import annotations

import json
import time
from pathlib import Path

from .config import CFG

_LOG = Path(CFG["log_dir"]) / "mcp_calls.jsonl"


def _append(direction: str, payload) -> None:
    try:
        entry = {"ts": time.time(), "direction": direction, "payload": payload}
        with _LOG.open("a", encoding="utf-8") as f:
            f.write(json.dumps(entry, ensure_ascii=False) + "\n")
    except OSError:
        pass  # logging must never break a tool call


def log_call(name: str, args: dict) -> None:
    _append("to_server", {"method": "tools/call",
                          "params": {"name": name, "arguments": args}})


def log_result(name: str, result) -> None:
    text = json.dumps(result, ensure_ascii=False, default=str)
    if len(text) > 6000:
        text = text[:6000] + "...(truncated)"
    _append("from_server", {"jsonrpc": "2.0",
                            "result": {"tool": name,
                                       "content": [{"type": "text", "text": text}]}})


def log_error(name: str, error: Exception) -> None:
    _append("from_server", {"jsonrpc": "2.0",
                            "error": {"tool": name, "message": str(error),
                                      "type": type(error).__name__}})
