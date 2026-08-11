"""Mock of the SketchUp Ruby TCP server on port 9876.

Diagnostic only. Lets you prove the Claude -> MCP -> TCP chain works without
launching SketchUp, so that when something breaks during a real test you know
whether the fault is the Python bridge or the SketchUp extension.

Mirrors su_mcp/su_mcp/main.rb: reads one newline-terminated JSON-RPC request
per connection, writes one response, then closes the socket.

    python tools/mock_sketchup.py
"""
import json
import socket
import threading

HOST, PORT = "127.0.0.1", 9876


def handle(conn: socket.socket) -> None:
    with conn:
        buf = b""
        while not buf.endswith(b"\n"):
            chunk = conn.recv(4096)
            if not chunk:
                return
            buf += chunk

        req = json.loads(buf.decode("utf-8"))
        name = req.get("params", {}).get("name", "?")
        args = req.get("params", {}).get("arguments", {})
        print(f"  <- {name} {json.dumps(args)[:120]}")

        if name == "eval_ruby":
            text = f"MOCK: evaluated [{args.get('code', '')}]"
        elif name == "get_selection":
            text = json.dumps({"selection": [], "note": "MOCK"})
        else:
            text = f"MOCK: {name} ok"

        # main.rb response shape
        resp = {
            "jsonrpc": "2.0",
            "result": {"content": [{"type": "text", "text": text}],
                       "isError": False, "success": True},
            "id": req.get("id"),
        }
        conn.sendall(json.dumps(resp).encode("utf-8") + b"\n")
        print(f"  -> {text[:120]}")


def main() -> None:
    srv = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    srv.bind((HOST, PORT))
    srv.listen(5)
    print(f"mock SketchUp listening on {HOST}:{PORT} (Ctrl-C to stop)")
    try:
        while True:
            conn, _ = srv.accept()
            threading.Thread(target=handle, args=(conn,), daemon=True).start()
    except KeyboardInterrupt:
        print("\nstopped")
    finally:
        srv.close()


if __name__ == "__main__":
    main()
