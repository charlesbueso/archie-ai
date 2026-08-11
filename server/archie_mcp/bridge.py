"""NDJSON-over-TCP client for the Archie SketchUp extension.

Persistent connection with exactly-one-reply-per-request framing — the
replacement for upstream sketchup-mcp's one-request-per-socket protocol whose
unread handshake made every session's first call return a stale response.
"""
from __future__ import annotations

import json
import socket
import threading

from .config import CFG


class BridgeError(RuntimeError):
    """The SketchUp side reported an error for this request."""


class BridgeDown(ConnectionError):
    """SketchUp (or the Archie extension server) is not reachable."""


class Bridge:
    def __init__(self, host: str | None = None, port: int | None = None):
        self.host = host or CFG["host"]
        self.port = port or CFG["port"]
        self._sock: socket.socket | None = None
        self._file = None
        self._id = 0
        self._lock = threading.Lock()

    def _connect(self) -> None:
        self.close()
        try:
            self._sock = socket.create_connection((self.host, self.port), timeout=10)
        except OSError as e:
            raise BridgeDown(
                f"cannot reach SketchUp on {self.host}:{self.port} — is SketchUp "
                f"open with the Archie extension running? ({e})"
            ) from e
        self._file = self._sock.makefile("r", encoding="utf-8")

    def close(self) -> None:
        for obj in (self._file, self._sock):
            try:
                if obj:
                    obj.close()
            except OSError:
                pass
        self._file = None
        self._sock = None

    def _roundtrip(self, payload: str, timeout: float) -> dict:
        if self._sock is None:
            self._connect()
        assert self._sock is not None
        self._sock.settimeout(timeout)
        self._sock.sendall(payload.encode("utf-8"))
        line = self._file.readline()
        if not line:
            raise ConnectionError("bridge closed the connection")
        return json.loads(line)

    def send(self, method: str, params: dict | None = None, timeout: float = 300.0) -> dict:
        """Call a bridge method; reconnects once on a dead socket."""
        with self._lock:
            self._id += 1
            payload = json.dumps(
                {"id": self._id, "method": method, "params": params or {}}
            ) + "\n"
            try:
                resp = self._roundtrip(payload, timeout)
            except BridgeDown:
                raise
            except (OSError, ConnectionError, json.JSONDecodeError):
                self._connect()  # one reconnect, then let failures surface
                resp = self._roundtrip(payload, timeout)
            if resp.get("error"):
                err = resp["error"]
                raise BridgeError(f"{method}: {err.get('message')} [{err.get('type')}]")
            return resp.get("result", {})


_bridge: Bridge | None = None


def bridge() -> Bridge:
    global _bridge
    if _bridge is None:
        _bridge = Bridge()
    return _bridge
