param([switch]$Release, [switch]$Offline, [string]$BetaServiceUrl)
. "$PSScriptRoot\env.ps1"
Push-Location $ProjectRoot
try {
    $cargoArgs = @('build','--locked','-p','haptics_core')
    $profile = 'debug'
    if ($Release) { $cargoArgs += '--release'; $profile = 'release' }
    Invoke-Checked cargo $cargoArgs
    New-Item -ItemType Directory -Path 'app\native' -Force | Out-Null
    Copy-Item -LiteralPath "$env:CARGO_TARGET_DIR\$profile\haptics_core.dll" -Destination 'app\native\haptics_core.dll' -Force
    Sync-App
    Push-Location $StagedApp
    try {
        $pubArgs = @('pub','get','--enforce-lockfile')
        if ($Offline) { $pubArgs += '--offline' }
        Invoke-Checked flutter $pubArgs
        Ensure-PluginJunctions $StagedApp
        $registrant = Get-Content -LiteralPath 'windows/flutter/generated_plugin_registrant.cc' -Raw
        if ($registrant -notmatch 'RecordWindowsPluginCApiRegisterWithRegistrar') { throw 'Windows recorder registration is missing' }
        $buildArgs = @('build','windows',"--$profile",'--no-pub')
        if ($BetaServiceUrl) {
            if ($BetaServiceUrl -notmatch '^(https://[^/?#@]+/?|http://127\.0\.0\.1:\d+/?)$') { throw 'Beta service must use HTTPS or an explicit loopback port' }
            $buildArgs += "--dart-define=BETA_SERVICE_URL=$BetaServiceUrl"
        }
        Invoke-Checked flutter $buildArgs
    } finally { Pop-Location }
} finally { Pop-Location }
