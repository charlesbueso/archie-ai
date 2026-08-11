"""Build Archie distribution artifacts into dist/:

  archie_sketchup_v{V}.rbz   SketchUp extension (install via Extension Manager)
  archie-{V}.mcpb            Claude Desktop one-click bundle (MCP Bundle)
  archie-beta-{V}.zip        everything a beta user needs: rbz + mcpb +
                             server source + installer scripts + install guide

Cross-platform: pure zipfile, no .NET, no rubyzip. The .mcpb is packed with
the official CLI (npx @anthropic-ai/mcpb) when available, else plain zip
(the format is a zip archive with manifest.json at root).
"""
from __future__ import annotations

import json
import re
import shutil
import subprocess
import sys
import zipfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
DIST = ROOT / "dist"


def version() -> str:
    text = (ROOT / "server" / "archie_mcp" / "__init__.py").read_text(encoding="utf-8")
    return re.search(r'__version__ = "([^"]+)"', text).group(1)


def build_rbz(v: str) -> Path:
    out = DIST / f"archie_sketchup_v{v}.rbz"
    with zipfile.ZipFile(out, "w", zipfile.ZIP_DEFLATED) as z:
        z.write(ROOT / "extension" / "archie_mcp.rb", "archie_mcp.rb")
        for f in sorted((ROOT / "extension" / "archie_mcp").glob("*.rb")):
            z.write(f, f"archie_mcp/{f.name}")
    return out


def mcpb_manifest(v: str) -> dict:
    return {
        "manifest_version": "0.4",
        "name": "archie-sketchup",
        "display_name": "Archie — SketchUp for Claude",
        "version": v,
        "description": ("Edit real SketchUp models from Claude: typed geometry tools "
                        "(openings, slabs), automatic snapshot versioning, and "
                        "client/project management. Requires the Archie SketchUp "
                        "extension (bundled .rbz) running in SketchUp."),
        "author": {"name": "Archie"},
        "server": {
            "type": "uv",
            "entry_point": "server/archie_mcp/server.py",
            "mcp_config": {
                "command": "uv",
                "args": ["run", "--project", "${__dirname}/server", "archie-mcp"],
            },
        },
        "compatibility": {
            "platforms": ["darwin", "win32"],
            "runtimes": {"python": ">=3.10,<4"},
        },
    }


def build_mcpb(v: str) -> Path:
    staging = DIST / "mcpb-staging"
    if staging.exists():
        shutil.rmtree(staging)
    (staging / "server").mkdir(parents=True)
    (staging / "manifest.json").write_text(
        json.dumps(mcpb_manifest(v), indent=2), encoding="utf-8")
    shutil.copy2(ROOT / "server" / "pyproject.toml", staging / "server")
    pkg = staging / "server" / "archie_mcp"
    pkg.mkdir()
    for f in sorted((ROOT / "server" / "archie_mcp").glob("*.py")):
        shutil.copy2(f, pkg)

    out = DIST / f"archie-{v}.mcpb"
    out.unlink(missing_ok=True)
    try:
        subprocess.run(["npx", "-y", "@anthropic-ai/mcpb", "pack",
                        str(staging), str(out)],
                       check=True, capture_output=True, text=True, timeout=300,
                       shell=(sys.platform == "win32"))
        packer = "official mcpb CLI"
    except (subprocess.CalledProcessError, subprocess.TimeoutExpired,
            FileNotFoundError) as e:
        detail = getattr(e, "stderr", "") or str(e)
        print(f"  (mcpb CLI unavailable/failed -> plain zip fallback: {detail[:200]})")
        with zipfile.ZipFile(out, "w", zipfile.ZIP_DEFLATED) as z:
            for f in sorted(staging.rglob("*")):
                if f.is_file():
                    z.write(f, f.relative_to(staging).as_posix())
        packer = "zip fallback"
    print(f"  packed with: {packer}")
    return out


def build_beta_zip(v: str, rbz: Path, mcpb: Path) -> Path:
    out = DIST / f"archie-beta-{v}.zip"
    with zipfile.ZipFile(out, "w", zipfile.ZIP_DEFLATED) as z:
        z.write(rbz, rbz.name)
        z.write(mcpb, mcpb.name)
        z.write(ROOT / "docs" / "INSTALL_BETA.md", "INSTALL_BETA.md")
        for f in sorted((ROOT / "install").glob("*")):
            if f.is_file():
                z.write(f, f"install/{f.name}")
        z.write(ROOT / "server" / "pyproject.toml", "server/pyproject.toml")
        for f in sorted((ROOT / "server" / "archie_mcp").glob("*.py")):
            z.write(f, f"server/archie_mcp/{f.name}")
    return out


def main() -> None:
    DIST.mkdir(exist_ok=True)
    v = version()
    print(f"building Archie {v}")
    rbz = build_rbz(v)
    print(f"  {rbz.name}  {rbz.stat().st_size:,} bytes")
    mcpb = build_mcpb(v)
    print(f"  {mcpb.name}  {mcpb.stat().st_size:,} bytes")
    beta = build_beta_zip(v, rbz, mcpb)
    print(f"  {beta.name}  {beta.stat().st_size:,} bytes")
    print("done")


if __name__ == "__main__":
    main()
