param([switch]$Restart, [switch]$CheckOnly)
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\relay-paths.ps1"
$project = Split-Path $PSScriptRoot -Parent
$mutex = [Threading.Mutex]::new($false, ('Local\AIHapticsRelay-' + [Security.Principal.WindowsIdentity]::GetCurrent().User.Value))
$locked = $false
try {
    try { $locked = $mutex.WaitOne(15000) }
    catch [Threading.AbandonedMutexException] { $locked = $true }
    if (-not $locked) { throw '另一个中继启动操作尚未完成，请稍后再试。' }
    $relayHome = Initialize-RelayHome
    $configFile = Join-Path $relayHome 'config.json'
    $bundle = Read-RelayBundle $relayHome
    $config = $bundle.Config
    $source = Join-Path $project 'app\tool\venice_relay.dart'
    $sourceHash = (Get-FileHash -LiteralPath $source).Hash
    $exe = Join-Path $relayHome 'venice-relay.exe'
    $buildFile = Join-Path $relayHome 'runtime-build.json'
    $build = $null
    if (Test-Path -LiteralPath $buildFile) {
        try { $build = [IO.File]::ReadAllText($buildFile) | ConvertFrom-Json } catch { $build = $null }
    }
    $needsBuild = -not (Test-Path -LiteralPath $exe) -or -not $build -or $build.sourceHash -ne $sourceHash
    $listeners = @(Get-NetTCPConnection -LocalPort $config.port -State Listen -ErrorAction SilentlyContinue)
    $owner = $null
    if ($listeners.Count -gt 0) {
        $ownerIds = @($listeners.OwningProcess | Select-Object -Unique)
        if ($ownerIds.Count -ne 1) { throw '中继端口存在多个占用进程，未停止任何进程。' }
        $owner = Get-CimInstance Win32_Process -Filter "ProcessId=$($ownerIds[0])"
        $knownConfigs = @($configFile) + @((Get-RelayLegacyRoots) | ForEach-Object { Join-Path $_ 'venice-relay\config.json' })
        $ownExe = $owner.ExecutablePath -eq $exe -and $owner.CommandLine.Contains($configFile)
        $ownDart = $owner.Name -in @('dart.exe','dartvm.exe') -and $owner.CommandLine.Contains($source) -and
            @($knownConfigs | Where-Object { $owner.CommandLine.Contains($_) }).Count -gt 0
        if (-not $ownExe -and -not $ownDart) { throw '中继端口被其他程序占用，未停止它。请先检查端口占用。' }
        if (-not $needsBuild -and -not $Restart -and $ownExe) {
            & $exe --check $configFile 2>$null | Out-Null
            if ($LASTEXITCODE -eq 0) {
                Write-Host "中继已在运行，HTTPS 和配对凭据检查通过。地址：https://$($config.host):$($config.port)"
                exit 0
            }
        }
    }
    if ($CheckOnly) { throw '中继尚未就绪。请双击“启动Venice中继.cmd”启动或修复运行状态。' }
    # Build before stopping the old relay. Normal launches need no SDK/Codex.
    if ($needsBuild) {
        $dart = Find-RelayDart
        $pending = Join-Path $relayHome 'venice-relay-next.exe'
        Write-Host '正在准备独立中继程序（只在首次启动或程序升级时执行）…'
        & $dart compile exe $source -o $pending *> (Join-Path $relayHome 'runtime-build.log')
        if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $pending)) { throw '中继程序编译失败；旧服务未被停止。请查看固定配置目录中的 runtime-build.log。' }
    }
    $addresses = @(Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue | Select-Object -ExpandProperty IPAddress)
    if ($config.host -notin $addresses) { throw "电脑当前没有原局域网地址 $($config.host)。请恢复同一 Wi-Fi/IP；不要重新生成配对证书。" }
    if ($owner) { Stop-Process -Id $owner.ProcessId -ErrorAction Stop; Start-Sleep -Milliseconds 300 }
    if ($needsBuild) {
        Copy-Item -LiteralPath $pending -Destination $exe -Force
        [IO.File]::WriteAllText($buildFile, (@{sourceHash=$sourceHash} | ConvertTo-Json), [Text.UTF8Encoding]::new($false))
    }
    $process = Start-Process -FilePath $exe -ArgumentList @('"' + $configFile + '"') -WorkingDirectory $project -WindowStyle Hidden -PassThru -RedirectStandardOutput (Join-Path $relayHome 'service.log') -RedirectStandardError (Join-Path $relayHome 'service-error.log')
    $ready = $false
    for ($attempt = 0; $attempt -lt 15; $attempt++) {
        Start-Sleep -Milliseconds 400
        if ($process.HasExited) { break }
        & $exe --check $configFile 2>$null | Out-Null
        if ($LASTEXITCODE -eq 0) { $ready = $true; break }
    }
    if (-not $ready) {
        if (-not $process.HasExited) { $process.Kill() }
        throw '中继启动未通过 HTTPS/配对凭据自检。配置已保留，请检查固定目录中的 service-error.log。'
    }
    [IO.File]::WriteAllText((Join-Path $relayHome 'running.json'), (@{pid=$process.Id;sourceHash=$sourceHash} | ConvertTo-Json), [Text.UTF8Encoding]::new($false))
    Write-Host "中继启动成功：https://$($config.host):$($config.port)"
    Write-Host "固定配置目录：$relayHome"
    Write-Host '可以关闭此窗口；后台中继会继续运行。电脑须保持开机和 VPN 连通，手机连接同一 Wi-Fi。'
} catch {
    Write-Host ("中继未启动：" + $_.Exception.Message) -ForegroundColor Red
    exit 1
} finally {
    if ($locked) { $mutex.ReleaseMutex() }
    $mutex.Dispose()
}