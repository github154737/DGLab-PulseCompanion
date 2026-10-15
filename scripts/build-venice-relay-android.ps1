param([switch]$Offline)
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\env.ps1"
. "$PSScriptRoot\relay-paths.ps1"
$defines = Join-Path (Initialize-RelayHome) 'android-defines.json'
if (-not (Test-Path -LiteralPath $defines)) { throw 'Configure the LAN relay first.' }
& "$PSScriptRoot\build-android.ps1" -Release -Offline:$Offline -VeniceRelayDefines $defines
if ($LASTEXITCODE -ne 0) { throw 'Android relay build failed' }
$version = [regex]::Match((Get-Content "$ProjectRoot/app/pubspec.yaml" -Raw), '(?m)^version:\s*([^+\s]+)').Groups[1].Value
$destination = Join-Path $ProjectRoot "artifacts\AIHapticsLab-$version-venice-lan-relay-android.apk"
Copy-Item -LiteralPath (Join-Path $StagedApp 'build\app\outputs\flutter-apk\app-release.apk') -Destination $destination -Force
Write-Output "Built: $destination"
Write-Output 'LAN test build. Requires the configured computer; contains relay access token, not supplier key.'
