param([switch]$EmbedLocalKey, [string]$PilotLoginDefines)
# Run from PowerShell, including the PyCharm terminal. No cloud API calls.
. "$PSScriptRoot/env.ps1"
New-Item -ItemType Directory -Path "$ProjectRoot/reports" -Force | Out-Null
Sync-App -PilotAssets
$buildVersionMatch = [regex]::Match((Get-Content -LiteralPath "$ProjectRoot/app/pubspec.yaml" -Raw), '(?m)^version:\s*(\d+\.\d+\.\d+\+\d+)\s*$')
if (-not $buildVersionMatch.Success) { throw 'Missing application version.' }
$buildVersion = $buildVersionMatch.Groups[1].Value
$privateDefineFile = $null
. "$PSScriptRoot/build-profile.ps1"
$pilotConfig = Get-PilotBuildDefines -LoginPath $PilotLoginDefines
if ($EmbedLocalKey) {
    $localKeyFile = Join-Path ([Environment]::GetFolderPath('Desktop')) 'VENICE_APIKEY.txt'
    $localKeyMatches = @([regex]::Matches([IO.File]::ReadAllText($localKeyFile), 'VENICE_INFERENCE_KEY_[A-Za-z0-9_-]{20,200}') | ForEach-Object { $_.Value } | Select-Object -Unique)
    if ($localKeyMatches.Count -ne 1) { throw 'Expected exactly one local Venice key.' }
    $pilotConfig.VENICE_LOCAL_TEST_KEY = $localKeyMatches[0]
    $localKeyMatches = $null
}
$privateDefineFile = Write-TemporaryDefines $pilotConfig
$localDefineArguments = @("--dart-define-from-file=$privateDefineFile")
Push-Location $StagedApp
try {
    Write-Output 'Checking application source...'
    & flutter analyze --no-pub *> "$ProjectRoot/reports/venice-rebuild-analyze.log"
    if ($LASTEXITCODE -ne 0) { throw 'Analysis failed. See reports/venice-rebuild-analyze.log.' }
    Write-Output 'Running local API regression tests...'
    & flutter test --no-pub test/api_model_provider_test.dart test/api_response_validation_test.dart test/venice_chat_test.dart test/venice_chat_page_test.dart test/venice_local_key_test.dart test/venice_speech_page_test.dart test/venice_recorder_test.dart test/venice_transcription_test.dart *> "$ProjectRoot/reports/venice-rebuild-tests.log"
    if ($LASTEXITCODE -ne 0) { throw 'Tests failed. See reports/venice-rebuild-tests.log.' }
    & flutter test --no-pub --dart-define=VENICE_LOCAL_TEST_KEY=VENICE_INFERENCE_KEY_synthetic_test_only test/venice_embedded_key_test.dart *> "$ProjectRoot/reports/venice-embedded-key-test.log"
    if ($LASTEXITCODE -ne 0) { throw 'Embedded key test failed. See reports/venice-embedded-key-test.log.' }
    & flutter test --no-pub test/venice_wave_test.dart test/venice_wave_page_test.dart test/physical_protocol_test.dart *> "$ProjectRoot/reports/venice-wave-tests.log"
    if ($LASTEXITCODE -ne 0) { throw 'Waveform tests failed. See reports/venice-wave-tests.log.' }
    Write-Output 'Building Windows release...'
    & flutter build windows --release --no-pub --target lib/main.dart "--dart-define=APP_VERSION=$buildVersion" @localDefineArguments *> "$ProjectRoot/reports/venice-rebuild-build.log"
    if ($LASTEXITCODE -ne 0) { throw 'Build failed. See reports/venice-rebuild-build.log.' }
} finally {
    Pop-Location
    if ($privateDefineFile) { Remove-Item -LiteralPath $privateDefineFile -Force }
}
& "$PSScriptRoot/package-venice-test.ps1" -EmbeddedLocalKey:$EmbedLocalKey
if (-not $?) { throw 'Packaging failed.' }
Write-Output 'Finished. Run the root Venice launcher or artifacts/Start-Venice.cmd inside the versioned folder.'
