. "$PSScriptRoot\env.ps1"
& "$PSScriptRoot/start-beta-service.ps1" -Background
$clientVersion = (Get-Content -LiteralPath "$ProjectRoot/reports/venice-speech-artifact.json" -Raw | ConvertFrom-Json).version
if ($clientVersion -notmatch '^\d+\.\d+\.\d+$') { throw 'Invalid packaged version.' }
$client = Join-Path $ProjectRoot "artifacts/windows-$clientVersion-beta-local/haptics_lab.exe"
if (-not (Test-Path -LiteralPath $client)) { throw 'Local desktop client has not been packaged' }
Start-Process -FilePath $client -WorkingDirectory (Split-Path $client)
