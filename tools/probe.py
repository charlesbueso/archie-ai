"""Send a Ruby file to the Archie bridge and print the result.

Avoids shell-quoting hell when probing SketchUp during development.
Usage: python tools/probe.py <ruby-file> [port]
"""
import json
import socket
import sys
from pathlib import Path

path = Path(sys.argv[1])
port = int(sys.argv[2]) if len(sys.argv) > 2 else 9876
sys.stdout.reconfigure(encoding="utf-8")

s = socket.create_connection(("127.0.0.1", port), timeout=30)
f = s.makefile("r", encoding="utf-8")
s.sendall((json.dumps({"id": 1, "method": "eval_ruby",
                       "params": {"code": path.read_text(encoding="utf-8")}}) + "\n").encode())
resp = json.loads(f.readline())
if resp.get("error"):
    print("ERROR:", resp["error"])
    sys.exit(1)
print(resp["result"]["result"])
