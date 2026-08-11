"""Archie beta installer — registers the MCP server with Claude Desktop.

Run from the unzipped beta folder (any OS):
    uv run --no-project python install/install.py
or  python install/install.py          (any Python 3.8+)

What it does:
  1. checks that `uv` is on PATH (tells you how to get it if not)
  2. writes ~/Archie/config.json with safe defaults if missing
  3. backs up Claude Desktop's config, then adds/updates the `archie` server
     entry pointing at the bundled server source (run via uv)
  4. prints the two manual steps (install .rbz in SketchUp; restart apps)

It never deletes anything and can be re-run safely.
"""
import json
import platform
import shutil
import sys
from datetime import datetime
from pathlib import Path

HERE = Path(__file__).resolve().parent
SERVER_DIR = (HERE.parent / "server").resolve()


def fail(msg: str) -> None:
    print(f"\n[X] {msg}")
    sys.exit(1)


def claude_config_path() -> Path:
    sysname = platform.system()
    if sysname == "Darwin":
        return Path.home() / "Library" / "Application Support" / "Claude" / "claude_desktop_config.json"
    if sysname == "Windows":
        import os
        return Path(os.environ.get("APPDATA", Path.home() / "AppData" / "Roaming")) / "Claude" / "claude_desktop_config.json"
    return Path.home() / ".config" / "Claude" / "claude_desktop_config.json"


def main() -> None:
    print("Archie beta installer")
    print("=" * 40)

    if not SERVER_DIR.joinpath("pyproject.toml").exists():
        fail(f"server source not found at {SERVER_DIR} — run this from the unzipped beta folder")

    uv = shutil.which("uv")
    if not uv:
        fail("`uv` is not installed. Install it first:\n"
             "    macOS:   curl -LsSf https://astral.sh/uv/install.sh | sh\n"
             "    Windows: powershell -c \"irm https://astral.sh/uv/install.ps1 | iex\"\n"
             "then re-run this installer.")
    print(f"[ok] uv found: {uv}")

    home = Path.home() / "Archie"
    home.mkdir(exist_ok=True)
    cfg_file = home / "config.json"
    if not cfg_file.exists():
        cfg_file.write_text(json.dumps({
            "port": 9876, "host": "127.0.0.1", "autostart": True,
            "dev_mode": False, "log_dir": None,
            "autosnapshot": True, "max_versions": 20,
        }, indent=2), encoding="utf-8")
        print(f"[ok] created {cfg_file}")
    else:
        print(f"[ok] kept existing {cfg_file}")

    cc = claude_config_path()
    cc.parent.mkdir(parents=True, exist_ok=True)
    config = {}
    if cc.exists():
        backup = cc.with_suffix(f".backup-{datetime.now():%Y%m%d-%H%M%S}.json")
        shutil.copy2(cc, backup)
        print(f"[ok] backed up Claude config -> {backup.name}")
        try:
            config = json.loads(cc.read_text(encoding="utf-8"))
        except json.JSONDecodeError:
            fail(f"{cc} is not valid JSON — fix or delete it, then re-run")
    config.setdefault("mcpServers", {})["archie"] = {
        "command": "uv",
        "args": ["run", "--project", str(SERVER_DIR), "archie-mcp"],
    }
    cc.write_text(json.dumps(config, indent=2), encoding="utf-8")
    print(f"[ok] registered 'archie' in {cc}")

    rbz = sorted(HERE.parent.glob("archie_sketchup_v*.rbz"))
    print("\nDone! Two manual steps remain:")
    print("  1. SketchUp -> Window -> Extension Manager -> Install Extension ->")
    print(f"     {rbz[-1] if rbz else 'archie_sketchup_v*.rbz (in this folder)'}")
    print("     (if blocked: Window -> Preferences -> Extensions -> policy 'Unrestricted')")
    print("     Then RESTART SketchUp — the Archie server starts automatically.")
    print("  2. FULLY quit Claude Desktop (system tray/menu bar -> Quit) and reopen.")
    print("\nTest: open a saved .skp in SketchUp, then ask Claude:")
    print('     "Run health_check on Archie"')


if __name__ == "__main__":
    main()
