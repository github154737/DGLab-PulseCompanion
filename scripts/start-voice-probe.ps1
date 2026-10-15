. "$PSScriptRoot\env.ps1"
$probeDart = Join-Path $TaskRoot 'tools\flutter\bin\cache\dart-sdk\bin\dart.exe'
$probeLibrary = Join-Path $TaskRoot 'build\rust\release\haptics_core.dll'
if (-not (Test-Path -LiteralPath $probeLibrary)) { throw 'Build the release native core first.' }
$env:HAPTICS_CORE_LIBRARY = $probeLibrary
Sync-App
Push-Location $StagedApp
try {
    if (-not (Test-Path -LiteralPath '.dart_tool\package_config.json')) {
        Invoke-Checked flutter @('pub','get','--offline','--enforce-lockfile')
    }
    Invoke-Checked $probeDart @('run','tool/voice_probe.dart',"$ProjectRoot\reports\voice-probe-live.json")
} finally { Pop-Location }
