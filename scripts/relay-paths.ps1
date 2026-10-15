# Shared by startup, provisioning, firewall and APK packaging. Do not put
# persistent relay credentials under MSIX-virtualized LocalAppData.
function Get-RelayHome {
    Join-Path $env:USERPROFILE '.aihaptics\venice-relay'
}

function Get-RelayLegacyRoots {
    $roots = @()
    # Explicit package paths work from Explorer as well as packaged Codex.
    $packages = Join-Path $env:USERPROFILE 'AppData\Local\Packages'
    if (Test-Path -LiteralPath $packages) {
        $roots += @(Get-ChildItem -LiteralPath $packages -Directory -Filter 'OpenAI.Codex*' |
            ForEach-Object { Join-Path $_.FullName 'LocalCache\Local\AIHaptics' })
    }
    if ($env:LOCALAPPDATA) { $roots += Join-Path $env:LOCALAPPDATA 'AIHaptics' }
    $roots += Join-Path $env:USERPROFILE 'AppData\Local\AIHaptics'
    @($roots | Select-Object -Unique)
}

function Read-RelayBundle {
    param([string]$Folder)
    $path = Join-Path $Folder 'config.json'
    try { $config = [IO.File]::ReadAllText($path) | ConvertFrom-Json }
    catch { throw "中继配置无法读取或格式损坏：$path。未生成或替换手机配对凭据。" }
    if (-not $config.host -or $config.port -lt 1 -or $config.port -gt 65535 -or
        -not $config.token -or $config.token.Length -lt 20) {
        throw "中继配置字段不完整：$path。请恢复原配置。"
    }
    $files = @{}
    foreach ($field in @('certificate', 'privateKey', 'keyFile')) {
        $reference = [string]$config.$field
        if (-not $reference) { throw "中继配置缺少 $field。" }
        # Certificates were created beside config.json. Prefer that physical
        # sibling over an old path which can point into a different MSIX view.
        $sibling = Join-Path $Folder ([IO.Path]::GetFileName($reference))
        $resolved = if (Test-Path -LiteralPath $sibling -PathType Leaf) { $sibling } else { $reference }
        if (-not (Test-Path -LiteralPath $resolved -PathType Leaf)) {
            throw "中继文件缺失（$field）：$resolved。原配对凭据未被替换。"
        }
        $files[$field] = $resolved
    }
    $certBytes = [IO.File]::ReadAllBytes($files.certificate)
    $definesPath = Join-Path $Folder 'android-defines.json'
    if (-not (Test-Path -LiteralPath $definesPath -PathType Leaf)) {
        throw "缺少与手机包对应的 android-defines.json：$Folder。请恢复原文件。"
    }
    try { $defines = [IO.File]::ReadAllText($definesPath) | ConvertFrom-Json }
    catch { throw "手机配对配置格式损坏：$definesPath。" }
    $url = "https://$($config.host):$($config.port)/api/v1"
    if ($defines.VENICE_RELAY_URL -ne $url -or $defines.VENICE_RELAY_TOKEN -cne $config.token -or
        $defines.VENICE_RELAY_CERT -cne [Convert]::ToBase64String($certBytes)) {
        throw "中继与手机配对配置不一致：$Folder。为避免破坏已安装的手机包，已停止自动处理。"
    }
    [pscustomobject]@{Folder=$Folder;Config=$config;Files=$files;Defines=$definesPath;
        Identity=($url + '|' + $config.token + '|' + [Convert]::ToBase64String($certBytes))}
}

function Copy-RelayBundle {
    param($Bundle, [string]$Destination)
    New-Item -ItemType Directory -Path $Destination -Force | Out-Null
    $config = $Bundle.Config | ConvertTo-Json -Depth 12 | ConvertFrom-Json
    foreach ($entry in @(@('certificate','server.pem'),@('privateKey','server-key.pem'),@('keyFile','supplier-key.txt'))) {
        $target = Join-Path $Destination $entry[1]
        if ([IO.Path]::GetFullPath($Bundle.Files[$entry[0]]) -ne [IO.Path]::GetFullPath($target)) {
            [IO.File]::WriteAllBytes($target, [IO.File]::ReadAllBytes($Bundle.Files[$entry[0]]))
        }
        $config.($entry[0]) = $target
    }
    $defines = Join-Path $Destination 'android-defines.json'
    if ([IO.Path]::GetFullPath($Bundle.Defines) -ne [IO.Path]::GetFullPath($defines)) {
        [IO.File]::WriteAllBytes($defines, [IO.File]::ReadAllBytes($Bundle.Defines))
    }
    # Write config last and replace atomically. An interrupted copy cannot look
    # like a complete new installation. Keep unknown fields, including proxy.
    $path = Join-Path $Destination 'config.json'
    $temp = "$path.$([guid]::NewGuid().ToString('N')).tmp"
    [IO.File]::WriteAllText($temp, ($config | ConvertTo-Json -Depth 12), [Text.UTF8Encoding]::new($false))
    if (Test-Path -LiteralPath $path) {
        # Windows PowerShell 5.1 converts a null string argument to "", which
        # File.Replace rejects. Use an explicit temporary backup filename.
        $previous = "$temp.previous"
        [IO.File]::Replace($temp,$path,$previous)
        [IO.File]::Delete($previous)
    }
    else { [IO.File]::Move($temp,$path) }
}

function Initialize-RelayHome {
    param([string]$HomePath = (Get-RelayHome), [string[]]$LegacyRoots = (Get-RelayLegacyRoots), [switch]$AllowMissing)
    $configPath = Join-Path $HomePath 'config.json'
    if (Test-Path -LiteralPath $configPath) {
        $bundle = Read-RelayBundle $HomePath
        # Repair stale internal file references after moving this directory.
        if ($bundle.Files.certificate -ne $bundle.Config.certificate -or
            $bundle.Files.privateKey -ne $bundle.Config.privateKey -or
            $bundle.Files.keyFile -ne $bundle.Config.keyFile) {
            Copy-RelayBundle $bundle $HomePath
            $bundle = Read-RelayBundle $HomePath
        }
    } else {
        $folders = @((Join-Path $HomePath 'recovery')) + @($LegacyRoots | ForEach-Object { Join-Path $_ 'venice-relay' })
        $candidates = @()
        foreach ($folder in ($folders | Select-Object -Unique)) {
            if (Test-Path -LiteralPath (Join-Path $folder 'config.json')) {
                $candidates += Read-RelayBundle $folder
            }
        }
        if ($candidates.Count -eq 0) {
            if ($AllowMissing) { return $HomePath }
            throw "没有找到原中继配置。固定位置：$HomePath。已检查普通目录和 Codex 隔离目录；请恢复原配置，不能重新生成手机凭据。"
        }
        if (@($candidates.Identity | Select-Object -Unique).Count -ne 1) {
            throw '检测到多套不同的中继配对配置，已停止自动迁移。请确认手机包对应哪一套；未覆盖任何凭据。'
        }
        Copy-RelayBundle $candidates[0] $HomePath
        $bundle = Read-RelayBundle $HomePath
    }
    # Local recovery copy, outside the repository and cloud-synced Desktop.
    $recovery = Join-Path $HomePath 'recovery'
    if (-not (Test-Path -LiteralPath (Join-Path $recovery 'config.json'))) {
        Copy-RelayBundle $bundle $recovery
    }
    $HomePath
}

function Find-RelayDart {
    foreach ($root in (Get-RelayLegacyRoots)) {
        $dart = Join-Path $root 'tools\flutter\bin\cache\dart-sdk\bin\dart.exe'
        if (Test-Path -LiteralPath $dart -PathType Leaf) { return $dart }
    }
    $command = Get-Command dart.exe -ErrorAction SilentlyContinue
    if ($command) { return $command.Source }
    throw '未找到 Dart 编译工具。已有中继程序仍可直接运行；首次构建或升级需要恢复 Flutter/Dart 工具目录。'
}
