param([switch]$Offline)
# Personal Android build only. Contains the local operator's API key.
. "$PSScriptRoot/env.ps1"
Sync-App
Push-Location $StagedApp
try {
    Invoke-Checked flutter @('analyze','--no-pub')
    Invoke-Checked flutter @('test','--no-pub','--concurrency=1','test/warm_revision_test.dart','test/network_trace_test.dart','test/warm_layout_test.dart','test/venice_chat_page_test.dart','test/venice_speech_page_test.dart','test/venice_mobile_page_test.dart','test/venice_wave_test.dart','test/venice_wave_page_test.dart','test/venice_recorder_test.dart','test/venice_transcription_test.dart','test/venice_chat_test.dart')
} finally { Pop-Location }
& "$PSScriptRoot/build-android.ps1" -Release -Offline:$Offline -VenicePersonal
if (-not $?) { throw 'Android build failed.' }
$releaseVersion = [regex]::Match((Get-Content "$ProjectRoot/app/pubspec.yaml" -Raw), '(?m)^version:\s*(\d+\.\d+\.\d+)\+\d+').Groups[1].Value
if (-not $releaseVersion) { throw 'Missing version.' }
$apkOutput = Join-Path $ProjectRoot "artifacts/AIHapticsLab-$releaseVersion-venice-personal-android.apk"
Copy-Item -LiteralPath "$StagedApp/build/app/outputs/flutter-apk/app-release.apk" -Destination $apkOutput -Force
Write-Output "Personal APK ready: $apkOutput"
Write-Output 'Contains a personal API key. Do not distribute to testers.'
