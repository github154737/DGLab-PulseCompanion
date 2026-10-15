$ErrorActionPreference = 'Stop'
$veniceRoot = Split-Path $PSScriptRoot -Parent
$veniceVersion = (Get-Content -LiteralPath "$veniceRoot/reports/venice-speech-artifact.json" -Raw | ConvertFrom-Json).version
if ($veniceVersion -notmatch '^\d+\.\d+\.\d+$') { throw 'Invalid packaged version.' }
$veniceClient = Join-Path $veniceRoot "artifacts/windows-$veniceVersion-beta-local/haptics_lab.exe"
if (-not (Test-Path -LiteralPath $veniceClient)) { throw 'Venice test client has not been packaged.' }
# Interactive test app: opens directly into Venice, with no Qwen backend startup.
Start-Process -FilePath $veniceClient -ArgumentList '--venice' -WorkingDirectory (Split-Path $veniceClient)
