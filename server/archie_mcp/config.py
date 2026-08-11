"""Configuration. Single source of truth is ~/Archie/config.json, shared with
the Ruby extension so the two halves can never disagree about the port."""
from __future__ import annotations

import json
import os
from pathlib import Path

DEFAULTS = {
    "port": 9876,
    "host": "127.0.0.1",
    "autostart": True,
    "dev_mode": False,
    "log_dir": None,
    "autosnapshot": True,
    "max_versions": 20,
}


def home() -> Path:
    env = os.environ.get("ARCHIE_HOME")
    return Path(env) if env else Path.home() / "Archie"


def load() -> dict:
    cfg = dict(DEFAULTS)
    path = home() / "config.json"
    try:
        if path.exists():
            data = json.loads(path.read_text(encoding="utf-8"))
            if isinstance(data, dict):
                cfg.update(data)
        else:
            # first run: materialize defaults so users have a file to edit
            home().mkdir(parents=True, exist_ok=True)
            path.write_text(json.dumps(DEFAULTS, indent=2), encoding="utf-8")
    except OSError:
        pass
    if not cfg.get("log_dir"):
        cfg["log_dir"] = str(home() / "logs")
    cfg["db_path"] = str(home() / "archie.db")
    Path(cfg["log_dir"]).mkdir(parents=True, exist_ok=True)
    return cfg


CFG = load()
