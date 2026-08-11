"""Transparent stdio proxy for the sketchup MCP server.

Sits between the MCP client (Claude Code) and the real sketchup-mcp.exe,
relaying every byte unchanged in both directions while appending a copy of
each JSON-RPC message to logs/mcp_calls.jsonl. This exists so we get full
visibility into everything crossing the MCP boundary without touching
vendor/sketchup-mcp, which setup.ps1 treats as pristine upstream.

Point .mcp.json's "sketchup" command at this script (via the venv python)
instead of at sketchup-mcp.exe directly.
"""
import json
import pathlib
import subprocess
import sys
import threading
import time

ROOT = pathlib.Path(__file__).resolve().parent.parent
LOG_PATH = ROOT / "logs" / "mcp_calls.jsonl"
SERVER_EXE = ROOT / ".venv" / "Scripts" / "sketchup-mcp.exe"

LOG_PATH.parent.mkdir(parents=True, exist_ok=True)
_log_lock = threading.Lock()


def log(direction, payload):
    entry = {"ts": time.time(), "direction": direction, "payload": payload}
    with _log_lock, LOG_PATH.open("a", encoding="utf-8") as f:
        f.write(json.dumps(entry, ensure_ascii=False) + "\n")


def pump(src, dst, direction):
    for raw in iter(src.readline, b""):
        dst.write(raw)
        dst.flush()
        line = raw.decode("utf-8", errors="replace").strip()
        if not line:
            continue
        try:
            payload = json.loads(line)
        except json.JSONDecodeError:
            payload = line
        log(direction, payload)


def main():
    proc = subprocess.Popen(
        [str(SERVER_EXE)],
        stdin=subprocess.PIPE,
        stdout=subprocess.PIPE,
        stderr=None,  # inherit - keep the server's own diagnostics visible as before
    )
    t_in = threading.Thread(target=pump, args=(sys.stdin.buffer, proc.stdin, "to_server"), daemon=True)
    t_out = threading.Thread(target=pump, args=(proc.stdout, sys.stdout.buffer, "from_server"), daemon=True)
    t_in.start()
    t_out.start()
    proc.wait()


if __name__ == "__main__":
    main()
