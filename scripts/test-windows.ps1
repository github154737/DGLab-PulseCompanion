param([switch]$Offline)
. "$PSScriptRoot\env.ps1"
Sync-App
$env:HAPTICS_REPORT_DIR = "$ProjectRoot\reports"
Push-Location $StagedApp
try {
    $pubArgs = @('pub','get','--enforce-lockfile')
    if ($Offline) { $pubArgs += '--offline' }
    Invoke-Checked flutter $pubArgs
    Ensure-PluginJunctions $StagedApp
    Invoke-Checked flutter @('drive','--no-pub','--driver','test_driver/desktop_test.dart','--target','integration_test/desktop_test.dart','-d','windows')
} finally { Pop-Location }
