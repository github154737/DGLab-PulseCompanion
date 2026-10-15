param(
    [switch]$ConfigureProvider,
    [switch]$InitializeOnly,
    [string]$ProviderKeyFile,
    [string]$ProviderHost = 'llm-ya8qfzufnzplkk5j.cn-beijing.maas.aliyuncs.com',
    [switch]$Background
)
. "$PSScriptRoot\env.ps1"
$stateDir = Join-Path $TaskRoot 'private\beta-service'
New-Item -ItemType Directory -Path $stateDir -Force | Out-Null
# Restrict operator tokens and exports to this Windows user before creating them.
$identity = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name
& icacls $stateDir /inheritance:r /grant:r "${identity}:(OI)(CI)F" | Out-Null
if ($LASTEXITCODE -ne 0) { throw 'Unable to restrict private service state directory' }
$savedKey = Join-Path $stateDir 'provider-key.clixml'
$savedHost = Join-Path $stateDir 'provider-host.txt'
if ($ProviderKeyFile) {
    $raw = [IO.File]::ReadAllText((Resolve-Path -LiteralPath $ProviderKeyFile).Path)
    $keyCandidates = [regex]::Matches($raw, 'sk-[A-Za-z0-9._-]+')
    if ($keyCandidates.Count -ne 1) { throw 'Expected exactly one provider key in the supplied file' }
    if ($ProviderHost -notmatch '^llm-[a-z0-9-]+\.cn-beijing\.maas\.aliyuncs\.com$') { throw 'Invalid Beijing workspace host' }
    ConvertTo-SecureString $keyCandidates[0].Value -AsPlainText -Force | Export-Clixml -LiteralPath $savedKey
    [IO.File]::WriteAllText($savedHost, $ProviderHost)
    $raw = $null; $keyCandidates = $null
}
if ($InitializeOnly) {
    Sync-App
    Push-Location $StagedApp
    try { & dart run tool/beta_seed.dart $stateDir; if ($LASTEXITCODE -ne 0) { throw 'Beta initialization failed' } }
    finally { Pop-Location }
    return
}
if ($Background) {
    $listener = Get-NetTCPConnection -State Listen -LocalPort 8790 -ErrorAction SilentlyContinue
    if ($listener -and $ProviderKeyFile) {
        $serviceProcess = Get-Process -Id $listener.OwningProcess
        $expectedService = Join-Path $ProjectRoot 'artifacts\beta-service-0.6.1\beta_service.exe'
        if ($serviceProcess.Path -ne $expectedService) { throw 'Port 8790 belongs to another process; configuration saved for the next service start' }
        $adminHeaders = @{Authorization=('Bearer ' + [IO.File]::ReadAllText("$stateDir/owner-token").Trim())}
        $status = Invoke-RestMethod 'http://127.0.0.1:8790/admin/status' -Headers $adminHeaders -TimeoutSec 3
        if ($status.active -ne 0 -or $status.pending -ne 0) { throw 'Configuration saved; end active sessions before restarting the service' }
        Stop-Process -Id $serviceProcess.Id
        $serviceProcess.WaitForExit(5000) | Out-Null
        $listener = $null
    }
    if ($listener) {
        $health = Invoke-RestMethod 'http://127.0.0.1:8790/health' -TimeoutSec 3
        if (-not $health.ok -or -not $health.provider_configured) { throw 'Port 8790 is occupied or provider configuration is missing' }
        Write-Output 'Local service is already ready.'
        return
    }
    $launchArgs = '-NoProfile -ExecutionPolicy Bypass -File "' + $PSCommandPath + '"'
    $process = Start-Process powershell.exe -ArgumentList $launchArgs -WindowStyle Hidden -PassThru -RedirectStandardOutput "$stateDir/service.log" -RedirectStandardError "$stateDir/service-error.log"
    for ($attempt = 0; $attempt -lt 30; $attempt++) {
        Start-Sleep -Milliseconds 500
        if ($process.HasExited) { throw 'Local service exited during startup; inspect private service-error.log' }
        try {
            $health = Invoke-RestMethod 'http://127.0.0.1:8790/health' -TimeoutSec 1
            if ($health.ok -and $health.provider_configured) { Write-Output 'Local service ready on 127.0.0.1:8790.'; return }
        } catch { }
    }
    throw 'Local service did not become ready within 15 seconds'
}
if ($ConfigureProvider) {
    $env:HAPTICS_PROVIDER_HOST = Read-Host 'Beijing API Host (domain only)'
    $providerSecret = Read-Host 'Provider API Key (private; memory only)' -AsSecureString
    $pointer = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($providerSecret)
    try { $env:HAPTICS_PROVIDER_KEY = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($pointer) }
    finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($pointer) }
} elseif (Test-Path -LiteralPath $savedKey) {
    $providerSecret = Import-Clixml -LiteralPath $savedKey
    $pointer = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($providerSecret)
    try { $env:HAPTICS_PROVIDER_KEY = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($pointer) }
    finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($pointer) }
    $env:HAPTICS_PROVIDER_HOST = [IO.File]::ReadAllText($savedHost).Trim()
}
$executable = Join-Path $ProjectRoot 'artifacts\beta-service-0.6.1\beta_service.exe'
try {
    if (-not (Test-Path -LiteralPath $executable)) { throw 'Build the 0.6.1 standalone service first' }
    & $executable $stateDir
    if ($LASTEXITCODE -ne 0) { throw 'Local service startup failed' }
} finally {
    Remove-Item Env:HAPTICS_PROVIDER_KEY -ErrorAction SilentlyContinue
    Remove-Item Env:HAPTICS_PROVIDER_HOST -ErrorAction SilentlyContinue
}
