"""Full-protocol smoke: spawn archie-mcp over stdio exactly as Claude Desktop
does (MCP initialize / tools list / tools call), including one real mutation
round-trip through the tool layer so auto-snapshot is exercised.
Run: .venv/Scripts/python.exe tools/smoke_mcp_stdio.py
"""
import asyncio
import json
import sys

sys.stdout.reconfigure(encoding="utf-8")

from mcp import ClientSession, StdioServerParameters  # noqa: E402
from mcp.client.stdio import stdio_client  # noqa: E402

EXE = r"B:\repos\archie-ai\.venv\Scripts\archie-mcp.exe"
FAILURES = []


def check(label, cond, detail=""):
    print(f"[{'PASS' if cond else 'FAIL'}] {label} {detail}")
    if not cond:
        FAILURES.append(label)


def payload(res):
    text = res.content[0].text if res.content else "{}"
    try:
        return json.loads(text)
    except json.JSONDecodeError:
        return {"_raw": text}


async def main():
    params = StdioServerParameters(command=EXE, args=[])
    async with stdio_client(params) as (read, write):
        async with ClientSession(read, write) as s:
            init = await s.initialize()
            check("initialize", init.serverInfo.name == "archie",
                  f"{init.serverInfo.name} proto={init.protocolVersion}")

            tools = await s.list_tools()
            names = sorted(t.name for t in tools.tools)
            check("18 tools listed", len(names) == 18, len(names))

            hc = payload(await s.call_tool("health_check", {}))
            check("health_check: sketchup connected",
                  hc.get("sketchup_connected") is True,
                  f"ext={hc.get('extension_version')} su={hc.get('sketchup')}")

            mi = payload(await s.call_tool("get_model_info",
                                           {"include_top_level": False}))
            check("get_model_info via MCP", mi.get("containers", 0) > 900,
                  f"containers={mi.get('containers')}")

            ops = await s.call_tool("list_openings", {})
            data = json.loads(ops.content[0].text) if not ops.isError else []
            # FastMCP list-returning tools may deliver one content item per
            # element; normalize
            if isinstance(data, dict):
                data = [json.loads(c.text) for c in ops.content]
            w1 = [o for o in data
                  if "PROPUESTA" in o.get("container_path", "")
                  and abs(o.get("width", 0) - 1.50) < 0.02
                  and abs(o.get("height", 0) - 1.80) < 0.02
                  and o.get("center", [0, 0, 9])[2] < 3.0]
            check("PB-W1 found via MCP", len(w1) == 1,
                  w1[0]["id"] if w1 else data[:1])

            if w1:
                r1 = payload(await s.call_tool("resize_opening", {
                    "opening_id": w1[0]["id"], "width": 1.2, "height": 1.0,
                    "sill": 0.9}))
                check("MCP resize verified", r1.get("verified") is True,
                      r1.get("achieved"))
                check("auto-snapshot fired", bool(r1.get("snapshot")),
                      (r1.get("snapshot") or {}).get("file",
                                                     r1.get("snapshot")))
                r2 = payload(await s.call_tool("resize_opening", {
                    "opening_id": r1.get("new_id", w1[0]["id"]),
                    "width": 1.5, "height": 1.8, "sill": 0.5}))
                check("MCP resize back verified", r2.get("verified") is True,
                      r2.get("achieved"))

            vs = payload(await s.call_tool("list_versions", {}))
            check("versions listed via MCP",
                  len(vs.get("versions", [])) >= 3, len(vs.get("versions", [])))

    print()
    if FAILURES:
        print("FAILURES:", FAILURES)
        sys.exit(1)
    print("ALL PASS (stdio)")


if __name__ == "__main__":
    asyncio.run(main())
