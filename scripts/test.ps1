param([switch]$Offline)
. "$PSScriptRoot\env.ps1"
Push-Location $ProjectRoot
try {
    Invoke-Checked cargo @('fmt','--all','--','--check')
    Invoke-Checked cargo @('clippy','--locked','--all-targets','--','-D','warnings')
    Invoke-Checked cargo @('test','--workspace','--locked')
    Invoke-Checked cargo @('build','--workspace','--locked')
    $env:HAPTICS_CORE_LIBRARY = "$env:CARGO_TARGET_DIR\debug\haptics_core.dll"
    Sync-App
    Push-Location $StagedApp
    try {
        $pubArgs = @('--no-version-check','pub','get','--enforce-lockfile')
        if ($Offline) { $pubArgs += '--offline' }
        Invoke-Checked flutter $pubArgs
        Invoke-Checked flutter @('--no-version-check','analyze','--no-pub')
        Invoke-Checked flutter @('--no-version-check','test','--no-pub')
    } finally { Pop-Location }
} finally { Pop-Location }
