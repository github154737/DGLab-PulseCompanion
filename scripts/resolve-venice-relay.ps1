param([switch]$AllowMissing)
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [Text.UTF8Encoding]::new($false)
. "$PSScriptRoot\relay-paths.ps1"
try { Initialize-RelayHome -AllowMissing:$AllowMissing }
catch { Write-Host $_.Exception.Message -ForegroundColor Red; exit 1 }
