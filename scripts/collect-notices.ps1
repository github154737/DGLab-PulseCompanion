param([switch]$Offline)
. "$PSScriptRoot\env.ps1"
$noticeRoot = Join-Path $ProjectRoot 'docs\third-party'
New-Item -ItemType Directory -Path $noticeRoot -Force | Out-Null
$inventory = [System.Collections.Generic.List[object]]::new()
Push-Location $ProjectRoot
try {
    foreach ($scope in @('core','protocol-test-only')) {
        $cargoOptions = @('metadata','--locked','--format-version','1')
        if ($Offline) { $cargoOptions += '--offline' }
        if ($scope -eq 'protocol-test-only') { $cargoOptions += @('--manifest-path','protocol/Cargo.toml') }
        $metadataText = & cargo @cargoOptions
        if ($LASTEXITCODE -ne 0) { throw 'cargo metadata failed' }
        $metadata = $metadataText | ConvertFrom-Json
        foreach ($package in $metadata.packages) {
            if (-not $package.source) { continue }
            $noticeFiles = @()
            $directory = Split-Path $package.manifest_path -Parent
            foreach ($license in (Get-ChildItem -LiteralPath $directory -File | Where-Object { $_.Name -match '^(LICENSE|COPYING|NOTICE)' })) {
                $name = "rust-$($package.name)-$($package.version)-$($license.Name).txt"
                Copy-Item -LiteralPath $license.FullName -Destination (Join-Path $noticeRoot $name) -Force
                $noticeFiles += "docs/third-party/$name"
            }
            if ($noticeFiles.Count -eq 0) {
                $fallback = switch -Regex ($package.name) {
                    '^buttplug_' { 'upstream-buttplug-LICENSE.txt'; break }
                    '^jsonschema-' { 'upstream-jsonschema-LICENSE.txt'; break }
                    '^(uuid-simd|vsimd)$' { 'upstream-simd-LICENSE.txt'; break }
                    '^r-efi$' { "rust-r-efi-$($package.version)-AUTHORS.txt"; break }
                }
                if ($fallback -and (Test-Path -LiteralPath (Join-Path $noticeRoot $fallback))) { $noticeFiles += "docs/third-party/$fallback" }
            }
            $inventory.Add([ordered]@{ecosystem='Rust';scope=$scope;name=$package.name;version=$package.version;license=$package.license;repository=$package.repository;notices=$noticeFiles})
        }
    }
    $configPath = Join-Path $StagedApp '.dart_tool\package_config.json'
    $config = Get-Content -LiteralPath $configPath -Raw | ConvertFrom-Json
    foreach ($package in $config.packages) {
        if ($package.name -eq 'haptics_lab') { continue }
        $uri = [Uri]::new([Uri]::new($configPath),$package.rootUri)
        $directory = $uri.LocalPath
        $noticeFiles = @()
        foreach ($license in (Get-ChildItem -LiteralPath $directory -File | Where-Object { $_.Name -match '^(LICENSE|COPYING|NOTICE)' })) {
            $name = "dart-$($package.name)-$($license.Name).txt"
            Copy-Item -LiteralPath $license.FullName -Destination (Join-Path $noticeRoot $name) -Force
            $noticeFiles += "docs/third-party/$name"
        }
        if ($noticeFiles.Count -eq 0 -and $directory -like '*flutter*packages*') { $noticeFiles += 'docs/third-party/Flutter-LICENSE.txt' }
        $inventory.Add([ordered]@{ecosystem='Dart';scope='app-and-development-tools';name=$package.name;version_source='app/pubspec.lock';notices=$noticeFiles})
    }
    $flutterCommand = (Get-Command flutter -ErrorAction Stop).Source
    $flutterSdk = Split-Path (Split-Path $flutterCommand -Parent) -Parent
    Copy-Item -LiteralPath (Join-Path $flutterSdk 'LICENSE') -Destination "$noticeRoot\Flutter-LICENSE.txt" -Force
    New-Item -ItemType Directory -Path "$ProjectRoot\reports" -Force | Out-Null
    $inventory | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath "$ProjectRoot\reports\dependency-inventory.json" -Encoding utf8
    $inventory | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath "$ProjectRoot\docs\third-party-inventory.json" -Encoding utf8
    $assetRoot = Join-Path $ProjectRoot 'app\assets'
    New-Item -ItemType Directory -Path $assetRoot -Force | Out-Null
    $coreNotices = [System.Text.StringBuilder]::new()
    [void]$coreNotices.AppendLine('Rust control core: third-party notices')
    foreach ($entry in $inventory | Where-Object { $_.scope -eq 'core' }) {
        [void]$coreNotices.AppendLine("`n===== $($entry.name) $($entry.version) — $($entry.license) =====")
        foreach ($notice in $entry.notices) { [void]$coreNotices.AppendLine((Get-Content -LiteralPath (Join-Path $ProjectRoot $notice) -Raw)) }
    }
    $coreNotices.ToString() | Set-Content -LiteralPath "$assetRoot\rust-third-party-notices.txt" -Encoding utf8
    Write-Output "Collected $($inventory.Count) dependency records."
} finally { Pop-Location }
