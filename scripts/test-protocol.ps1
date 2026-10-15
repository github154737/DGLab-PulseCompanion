. "$PSScriptRoot\env.ps1"
$protocolTarget = Join-Path $TaskRoot 'build\protocol'
Push-Location $ProjectRoot
try {
    $env:CARGO_TARGET_DIR = $protocolTarget
    Invoke-Checked cargo @('+stable-x86_64-pc-windows-msvc','build','--locked','--manifest-path','protocol/Cargo.toml')
    $env:HAPTICS_CORE_LIBRARY = "$TaskRoot\build\rust\debug\haptics_core.dll"
    Sync-App
    Push-Location $StagedApp
    try {
        Invoke-Checked dart @('run','tool/protocol_smoke.dart',"$protocolTarget\debug\haptics-protocol-simulator.exe","$ProjectRoot\reports\protocol-smoke.json")
        Invoke-Checked dart @('run','tool/gateway_smoke.dart',"$protocolTarget\debug\haptics-protocol-simulator.exe","$ProjectRoot\reports\gateway-smoke.json")
    } finally { Pop-Location }
} finally { Pop-Location }
