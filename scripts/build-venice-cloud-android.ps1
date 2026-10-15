param([switch]$Offline, [switch]$CheckOnly, [string]$RelayDefines, [string]$PilotLoginDefines)
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\env.ps1"
. "$PSScriptRoot\build-profile.ps1"
$defines = if ($RelayDefines) { $RelayDefines } else { Join-Path $env:USERPROFILE '.aihaptics\venice-cloud-relay\android-defines.json' }
if (-not (Test-Path -LiteralPath $defines)) { throw 'Deploy and verify the cloud relay first.' }
$config = Get-Content -LiteralPath $defines -Raw | ConvertFrom-Json
if ($config.VENICE_RELAY_KIND -ne 'cloud' -or $config.VENICE_RELAY_URL -notlike 'https://*' -or -not $config.VENICE_RELAY_TOKEN -or -not $config.VENICE_RELAY_CERT) { throw 'Invalid cloud relay build configuration.' }
$checked = Get-PilotBuildDefines -RelayPath $defines -LoginPath $PilotLoginDefines
if ($env:DART_DEFINES -or $env:FLUTTER_TOOL_ARGS) { throw 'Unexpected build environment overrides.' }
if ($CheckOnly) { Write-Output 'Pilot profile valid; existing login credentials and relay preserved. No build or API call performed.'; return }
& "$PSScriptRoot\build-android.ps1" -Release -Offline:$Offline -VeniceRelayDefines $defines -PilotLoginDefines $PilotLoginDefines
if ($LASTEXITCODE -ne 0) { throw 'Android cloud relay build failed' }
$version = [regex]::Match((Get-Content "$ProjectRoot/app/pubspec.yaml" -Raw), '(?m)^version:\s*([^+\s]+)').Groups[1].Value
$destination = Join-Path $ProjectRoot "artifacts\AIHapticsLab-$version-venice-cloud-relay-android.apk"
Copy-Item -LiteralPath (Join-Path $StagedApp 'build\app\outputs\flutter-apk\app-release.apk') -Destination $destination -Force
Write-Output "Built: $destination"
Write-Output 'Private cloud test build. Contains restricted relay token; never distribute publicly.'
