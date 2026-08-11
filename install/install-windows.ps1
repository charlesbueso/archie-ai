# Archie beta installer (Windows). Right-click -> Run with PowerShell, or:
#   powershell -ExecutionPolicy Bypass -File install\install-windows.ps1
$ErrorActionPreference = "Stop"
Set-Location $PSScriptRoot

if (-not (Get-Command uv -ErrorAction SilentlyContinue)) {
    Write-Host "uv is required (fast Python manager). Install now? [y/N]" -NoNewline
    $yn = Read-Host " "
    if ($yn -eq "y") {
        Invoke-RestMethod https://astral.sh/uv/install.ps1 | Invoke-Expression
        $env:Path = "$env:USERPROFILE\.local\bin;$env:Path"
    } else {
        Write-Host "aborted - install uv first: powershell -c `"irm https://astral.sh/uv/install.ps1 | iex`""
        exit 1
    }
}

$py = Get-Command python -ErrorAction SilentlyContinue
if ($py) {
    python install.py
} else {
    uv run --no-project python install.py
}
