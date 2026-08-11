"""Raw NDJSON-TCP smoke test for the Archie SketchUp extension.

Usage: python tools/smoke_tcp.py [method] [json-params]
With no args, runs the standard read-only suite.
"""
import json
import socket
import sys
import time

HOST, PORT = "127.0.0.1", 9877
_id = 0


def call(sock_file, sock, method, params=None, timeout=120):
    global _id
    _id += 1
    req = {"id": _id, "method": method, "params": params or {}}
    sock.sendall((json.dumps(req) + "\n").encode("utf-8"))
    sock.settimeout(timeout)
    line = sock_file.readline()
    if not line:
        raise ConnectionError("server closed connection")
    resp = json.loads(line)
    if "error" in resp and resp["error"]:
        raise RuntimeError(f"{method} -> {resp['error']}")
    return resp["result"]


def main():
    s = socket.create_connection((HOST, PORT), timeout=10)
    f = s.makefile("r", encoding="utf-8")
    t0 = time.time()

    if len(sys.argv) > 1:
        method = sys.argv[1]
        params = json.loads(sys.argv[2]) if len(sys.argv) > 2 else {}
        out = call(f, s, method, params)
        print(json.dumps(out, indent=1, ensure_ascii=False)[:6000])
        return

    print("ping        :", call(f, s, "ping"))
    print("archie_info :", call(f, s, "archie_info"))
    ref = call(f, s, "get_model_ref")
    print("model_ref   :", ref)
    info = call(f, s, "get_model_info", {"include_top_level": False})
    print("model_info  : containers=%s slabs=%s storeys=%s" % (
        info["containers"], len(info["slabs"]), info["storeys"]))
    for sl in info["slabs"]:
        print("   slab pid=%-6s z=%.2f..%.2f t=%.3f area=%.1f %s" % (
            sl["pid"], sl["z_bottom"], sl["z_top"], sl["thickness"], sl["area_m2"],
            sl["path"][:40]))
    ops = call(f, s, "list_openings", {})
    print("openings    : %d" % len(ops))
    for o in ops:
        print("   %-9s %5.2f x %5.2f sill %5.2f  id=%s  %s" % (
            o["kind"], o["width"], o["height"], o["sill_above_floor"],
            o["id"], o["container_path"][:36]))
    # second ping proves the connection SURVIVED all previous calls —
    # the upstream bridge's one-request-per-connection bug is dead.
    print("ping again  :", call(f, s, "ping"))
    print("elapsed %.1fs" % (time.time() - t0))


if __name__ == "__main__":
    main()
