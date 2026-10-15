param([string]$Device = 'emulator-5560', [switch]$Offline)
. "$PSScriptRoot\env.ps1"
Sync-App
$env:HAPTICS_REPORT_DIR = "$ProjectRoot\reports"
Push-Location $StagedApp
try {
    $pubArgs = @('pub','get','--enforce-lockfile')
    $driveArgs = @('drive','--driver','test_driver/integration_test.dart','--target','integration_test/app_test.dart','-d',$Device)
    if ($Offline) { $pubArgs += '--offline'; $driveArgs += '--no-pub' }
    Invoke-Checked flutter $pubArgs
    Invoke-Checked flutter $driveArgs
} finally { Pop-Location }
