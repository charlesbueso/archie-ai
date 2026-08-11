<#
.SYNOPSIS
    One-command setup for the SketchUp <-> Claude MCP validation rig.

.DESCRIPTION
    Idempotent. Safe to re-run. From a clean Windows machine this will:
      1. Check prerequisites (git, python, SketchUp)
      2. Clone (or update) the upstream sketchup-mcp repo into vendor/
      3. Create a venv and install the Python MCP server from source, editable
      4. Build the SketchUp extension package (dist/su_mcp_v1.6.0.rbz)
      5. Register the MCP server with Claude Code at project scope (.mcp.json)
      6. Print the manual GUI steps that cannot be scripted

    It does NOT modify anything under vendor/ - upstream is used as-is.

.PARAMETER IncludeClaudeDesktop
    Also merge a "sketchup" entry into %APPDATA%\Claude\claude_desktop_config.json.
    Off by default; Claude Code is the primary client. See SETUP.md.

.PARAMETER SkipClientRegistration
    Build everything but do not touch any MCP client config.

.EXAMPLE
    .\setup.ps1
#>
[CmdletBinding()]
param(
    [switch]$IncludeClaudeDesktop,
    [switch]$SkipClientRegistration
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

# --- configuration ------------------------------------------------------------
$Root       = $PSScriptRoot
$VendorDir  = Join-Path $Root 'vendor\sketchup-mcp'
$VenvDir    = Join-Path $Root '.venv'
$DistDir    = Join-Path $Root 'dist'
$RepoUrl    = 'https://github.com/mhyrr/sketchup-mcp.git'

# Pinned so every machine gets the same bridge. Bump deliberately, not by drift.
$RepoCommit = 'aa096f04d3d7b22a70860368f2b576343feac405'

# Upstream declares mcp[cli]>=1.3.0 with no upper bound. mcp 2.x removed
# mcp.server.fastmcp, so an unconstrained install produces a server that cannot
# import. Constrain here rather than editing upstream's pyproject.toml.
$McpPin     = 'mcp[cli]>=1.3.0,<2'

# --- helpers ------------------------------------------------------------------
function Write-Step { param([string]$m) Write-Host "`n=== $m" -ForegroundColor Cyan }
function Write-Ok   { param([string]$m) Write-Host "  [ok]   $m" -ForegroundColor Green }
function Write-Info { param([string]$m) Write-Host "  [info] $m" -ForegroundColor DarkGray }
function Write-Warn { param([string]$m) Write-Host "  [warn] $m" -ForegroundColor Yellow }

function Test-Command {
    param([string]$Name)
    $c = Get-Command $Name -ErrorAction SilentlyContinue
    if ($c) { return $c.Source } else { return $null }
}

# Windows PowerShell 5.1 turns any stderr output from a native exe into a
# NativeCommandError, which $ErrorActionPreference='Stop' escalates to a
# terminating error - even on exit code 0. git, uv and the MCP server all log to
# stderr normally, so route every native call through here and judge success by
# the exit code alone.
function Invoke-Native {
    param(
        [Parameter(Mandatory)][string]$Exe,
        [string[]]$Arguments = @(),
        [string]$ErrorMessage = 'command failed'
    )
    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $output = & $Exe @Arguments 2>&1 | Out-String
        $code = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $prev
    }
    if ($code -ne 0) {
        Write-Host $output -ForegroundColor Red
        throw "$ErrorMessage (exit $code)"
    }
    return $output
}

# --- 1. prerequisites ---------------------------------------------------------
Write-Step '1/6  Checking prerequisites'

$gitPath = Test-Command 'git'
if (-not $gitPath) { throw 'git not found on PATH. Install Git for Windows: https://git-scm.com/download/win' }
Write-Ok "git         $gitPath"

$pythonPath = Test-Command 'python'
if (-not $pythonPath) { throw 'python not found on PATH. Install Python 3.10+: https://www.python.org/downloads/' }
$pyVer = ((Invoke-Native python @('--version') 'python --version failed') -replace '^Python\s+', '').Trim()
$pyParts = $pyVer -split '\.'
$pyMajorMinor = [version]"$($pyParts[0]).$($pyParts[1])"
if ($pyMajorMinor -lt [version]'3.10') { throw "Python 3.10+ required, found $pyVer" }
Write-Ok "python      $pyVer  ($pythonPath)"

$uvPath = Test-Command 'uv'
if ($uvPath) { Write-Ok "uv          $uvPath  (fast path)" }
else         { Write-Info 'uv not found - falling back to venv + pip (slower, still fine)' }

# SketchUp is only needed at test time, not to build. Warn, do not fail.
$suDirs = Get-ChildItem 'C:\Program Files\SketchUp' -Directory -ErrorAction SilentlyContinue
if ($suDirs) {
    foreach ($d in $suDirs) { Write-Ok "SketchUp    $($d.FullName)" }
} else {
    Write-Warn 'No SketchUp install found under C:\Program Files\SketchUp.'
    Write-Warn 'Setup will still complete, but you cannot run the test without it.'
}

# --- 2. upstream repo ---------------------------------------------------------
Write-Step '2/6  Fetching upstream sketchup-mcp'

if (-not (Test-Path (Join-Path $VendorDir '.git'))) {
    New-Item -ItemType Directory -Force (Split-Path $VendorDir) | Out-Null
    Write-Info "cloning $RepoUrl"
    Invoke-Native git @('clone', '--quiet', $RepoUrl, $VendorDir) 'git clone failed' | Out-Null
} else {
    Write-Info 'repo already present, fetching updates'
    Invoke-Native git @('-C', $VendorDir, 'fetch', '--quiet', 'origin') 'git fetch failed' | Out-Null
}

$current = (Invoke-Native git @('-C', $VendorDir, 'rev-parse', 'HEAD') 'git rev-parse failed').Trim()
if ($current -ne $RepoCommit) {
    Write-Info "checking out pinned commit $($RepoCommit.Substring(0,8))"
    Invoke-Native git @('-C', $VendorDir, 'checkout', '--quiet', $RepoCommit) "could not check out pinned commit $RepoCommit" | Out-Null
}
Write-Ok "vendor/sketchup-mcp @ $($RepoCommit.Substring(0,8))"

# sanity-check the layout matches what we build against
foreach ($rel in @('su_mcp\su_mcp.rb', 'su_mcp\extension.json', 'su_mcp\su_mcp\main.rb', 'src\sketchup_mcp\server.py')) {
    if (-not (Test-Path (Join-Path $VendorDir $rel))) {
        throw "upstream layout changed - expected file missing: $rel"
    }
}
Write-Ok 'upstream layout verified'

# --- 3. python environment ----------------------------------------------------
Write-Step '3/6  Setting up Python environment'

$venvPython = Join-Path $VenvDir 'Scripts\python.exe'

if (-not (Test-Path $venvPython)) {
    Write-Info 'creating venv'
    if ($uvPath) { Invoke-Native uv @('venv', $VenvDir) 'uv venv failed' | Out-Null }
    else         { Invoke-Native python @('-m', 'venv', $VenvDir) 'python -m venv failed' | Out-Null }
} else {
    Write-Info 'venv already exists'
}
if (-not (Test-Path $venvPython)) { throw "venv creation failed - $venvPython not found" }

Write-Info 'installing sketchup-mcp from source (editable)'
if ($uvPath) {
    Invoke-Native uv @('pip', 'install', '--quiet', '--python', $venvPython, '-e', $VendorDir, $McpPin) 'uv pip install failed' | Out-Null
} else {
    Invoke-Native $venvPython @('-m', 'pip', 'install', '--quiet', '--upgrade', 'pip') 'pip upgrade failed' | Out-Null
    Invoke-Native $venvPython @('-m', 'pip', 'install', '--quiet', '-e', $VendorDir, $McpPin) 'pip install failed' | Out-Null
}

# Verify the install rather than trusting the exit code. The server logs a
# startup banner to stderr on import, so this must tolerate stderr output.
$importCheck = Invoke-Native $venvPython @('-c', 'from sketchup_mcp import server; print(type(server.mcp).__name__)') 'sketchup_mcp failed to import'
if ($importCheck -notmatch 'FastMCP') {
    Write-Host $importCheck -ForegroundColor Red
    throw 'sketchup_mcp imported but did not expose a FastMCP server - check the mcp version pin'
}
$mcpVer = (Invoke-Native $venvPython @('-c', "import importlib.metadata as m; print(m.version('mcp'))") 'could not read mcp version').Trim()
Write-Ok "sketchup_mcp imports cleanly (mcp $mcpVer)"

$serverExe = Join-Path $VenvDir 'Scripts\sketchup-mcp.exe'
if (-not (Test-Path $serverExe)) { throw "console script missing: $serverExe" }
Write-Ok "server entry point  $serverExe"

# --- 4. build the .rbz --------------------------------------------------------
Write-Step '4/6  Building the SketchUp extension (.rbz)'

Add-Type -AssemblyName System.IO.Compression.FileSystem
Add-Type -AssemblyName System.IO.Compression

$rbzSrc = Join-Path $VendorDir 'su_mcp'
$extVer = (Get-Content (Join-Path $rbzSrc 'extension.json') -Raw | ConvertFrom-Json).version
New-Item -ItemType Directory -Force $DistDir | Out-Null
$rbzOut = Join-Path $DistDir "su_mcp_v$extVer.rbz"
if (Test-Path $rbzOut) { Remove-Item $rbzOut -Force }

# Mirrors vendor/sketchup-mcp/su_mcp/package.rb, which needs the rubyzip gem and
# a standalone Ruby. SketchUp's Ruby is embedded, so we zip with .NET instead.
# Entry names MUST use forward slashes for SketchUp's extractor.
$entries = [ordered]@{
    'su_mcp.rb'      = Join-Path $rbzSrc 'su_mcp.rb'
    'extension.json' = Join-Path $rbzSrc 'extension.json'
    'su_mcp/main.rb' = Join-Path $rbzSrc 'su_mcp\main.rb'
}

$zip = [System.IO.Compression.ZipFile]::Open($rbzOut, [System.IO.Compression.ZipArchiveMode]::Create)
try {
    foreach ($name in $entries.Keys) {
        $entry  = $zip.CreateEntry($name, [System.IO.Compression.CompressionLevel]::Optimal)
        $writer = New-Object System.IO.BinaryWriter($entry.Open())
        try { $writer.Write([System.IO.File]::ReadAllBytes($entries[$name])) }
        finally { $writer.Close() }
    }
} finally { $zip.Dispose() }

# Verify the archive really contains what SketchUp needs.
$verify = [System.IO.Compression.ZipFile]::OpenRead($rbzOut)
try { $names = $verify.Entries | ForEach-Object { $_.FullName } }
finally { $verify.Dispose() }
foreach ($required in @('su_mcp.rb', 'extension.json', 'su_mcp/main.rb')) {
    if ($names -notcontains $required) { throw "built .rbz is missing entry: $required" }
}
Write-Ok "built  $rbzOut"

# --- 5. MCP client registration ----------------------------------------------
Write-Step '5/6  Registering the MCP server with a client'

if ($SkipClientRegistration) {
    Write-Info 'skipped (-SkipClientRegistration)'
} else {
    # Claude Code, project scope. .mcp.json is a generated artifact: it holds an
    # absolute path, so it is rewritten per machine rather than committed as-is.
    $mcpJson = Join-Path $Root '.mcp.json'
    $config = @{ mcpServers = @{} }
    if (Test-Path $mcpJson) {
        try {
            $existing = Get-Content $mcpJson -Raw | ConvertFrom-Json
            if ($existing.PSObject.Properties.Name -contains 'mcpServers') {
                foreach ($p in $existing.mcpServers.PSObject.Properties) {
                    $config.mcpServers[$p.Name] = $p.Value
                }
            }
        } catch { Write-Warn 'existing .mcp.json was unreadable, regenerating' }
    }
    $config.mcpServers['sketchup'] = [ordered]@{
        type    = 'stdio'
        command = $serverExe
        args    = @()
        env     = @{}
    }
    ($config | ConvertTo-Json -Depth 10) | Out-File $mcpJson -Encoding utf8
    Write-Ok "Claude Code    $mcpJson"

    if ($IncludeClaudeDesktop) {
        $desktopDir = Join-Path $env:APPDATA 'Claude'
        if (-not (Test-Path $desktopDir)) {
            Write-Warn 'Claude Desktop config dir not found - is Claude Desktop installed?'
        } else {
            $desktopCfg = Join-Path $desktopDir 'claude_desktop_config.json'
            $d = @{ mcpServers = @{} }
            if (Test-Path $desktopCfg) {
                Copy-Item $desktopCfg "$desktopCfg.bak" -Force   # never clobber blindly
                try {
                    $existing = Get-Content $desktopCfg -Raw | ConvertFrom-Json
                    if ($existing.PSObject.Properties.Name -contains 'mcpServers') {
                        foreach ($p in $existing.mcpServers.PSObject.Properties) {
                            $d.mcpServers[$p.Name] = $p.Value
                        }
                    }
                } catch { Write-Warn 'existing desktop config unreadable, backed up to .bak' }
            }
            $d.mcpServers['sketchup'] = [ordered]@{ command = $serverExe; args = @() }
            ($d | ConvertTo-Json -Depth 10) | Out-File $desktopCfg -Encoding utf8
            Write-Ok "Claude Desktop $desktopCfg  (previous version saved as .bak)"
        }
    } else {
        Write-Info 'Claude Desktop not configured (pass -IncludeClaudeDesktop to add it)'
    }
}

# --- 6. what the script cannot do --------------------------------------------
Write-Step '6/6  Manual steps (these need the SketchUp GUI)'

Write-Host @"

  1. Install the extension
       SketchUp -> Window -> Extension Manager -> Install Extension
       Choose: $rbzOut
     If it is rejected as unsigned:
       Window -> Preferences -> Extensions -> Extension Policy -> Unrestricted
     Then restart SketchUp.

  2. Confirm it loaded (SketchUp Ruby Console: Window -> Ruby Console)
       Sketchup.extensions['Sketchup MCP Server']
     Should return an extension object, not nil.

  3. Open test\scratch.skp (build it per test\SCRATCH_MODEL.md), then start the bridge
       Extensions -> MCP Server -> Start Server
     The Ruby Console should print: Server started and listening

  4. Approve the server in Claude Code (one time, first run only)
       claude
     Accept the prompt to trust the project MCP server, then: /mcp

  Full walkthrough and troubleshooting: SETUP.md
  The test itself:                      test\TEST.md

"@ -ForegroundColor White

Write-Host "Setup complete.`n" -ForegroundColor Green
