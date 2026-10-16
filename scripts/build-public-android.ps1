param([switch]$Offline, [switch]$CheckOnly, [string]$ConfigPath)
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\env.ps1"
# Keep generated Dart source paths out of a personal Windows profile.
$StagedApp = Join-Path ([Environment]::GetFolderPath('CommonApplicationData')) 'AIHaptics/public-build/app'
. "$PSScriptRoot\build-profile.ps1"
if (-not $ConfigPath) { $ConfigPath = Join-Path $ProjectRoot 'config/public.json' }
$config = Read-DefineMap $ConfigPath
Assert-AppBuildDefines $config 'public'
if ($env:DART_DEFINES -or $env:FLUTTER_TOOL_ARGS) { throw 'Unexpected build environment overrides.' }
if ($CheckOnly) { Write-Output 'Public profile valid. No build or API call performed.'; return }
if (-not $env:AIHAPTICS_SIGNING_PROPERTIES) {
    $env:AIHAPTICS_SIGNING_PROPERTIES = Join-Path $env:USERPROFILE '.aihaptics/release-signing/signing.properties'
}
if (-not (Test-Path -LiteralPath $env:AIHAPTICS_SIGNING_PROPERTIES)) {
    throw 'Run scripts/init-release-signing.ps1 once before creating a public release.'
}
& "$PSScriptRoot\build-android.ps1" -Release -Offline:$Offline -AppDefines $ConfigPath
if ($LASTEXITCODE -ne 0) { throw 'Public Android build failed.' }
$version = [regex]::Match((Get-Content "$ProjectRoot/app/pubspec.yaml" -Raw), '(?m)^version:\s*([^+\s]+)').Groups[1].Value
New-Item -ItemType Directory -Path (Join-Path $ProjectRoot 'artifacts') -Force | Out-Null
Copy-Item -LiteralPath (Join-Path $StagedApp 'build/app/outputs/flutter-apk/app-release.apk') -Destination (Join-Path $ProjectRoot "artifacts/AIHaptics-$version-public-android.apk") -Force
Write-Output 'Public build completed. Run the release checklist before publishing; no upload performed.'
