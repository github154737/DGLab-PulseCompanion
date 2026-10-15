$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\relay-paths.ps1"
$testRoot = Join-Path ([IO.Path]::GetTempPath()) ('aihaptics-relay-path-test-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $testRoot | Out-Null
$script:passed = 0
function Assert-True($Value, [string]$Name) {
    if (-not $Value) { throw "FAILED: $Name" }
    $script:passed++
    Write-Host "PASS: $Name"
}
function Assert-Throws([scriptblock]$Action, [string]$Name) {
    $threw = $false
    try { & $Action | Out-Null } catch { $threw = $true }
    Assert-True $threw $Name
}
function New-Fixture([string]$Folder, [string]$Id = 'one') {
    New-Item -ItemType Directory -Path $Folder -Force | Out-Null
    $cert = [Text.Encoding]::UTF8.GetBytes("test-certificate-$Id")
    [IO.File]::WriteAllBytes((Join-Path $Folder 'server.pem'), $cert)
    [IO.File]::WriteAllText((Join-Path $Folder 'server-key.pem'), "test-private-$Id")
    [IO.File]::WriteAllText((Join-Path $Folder 'supplier-key.txt'), "test-supplier-$Id")
    $token = 'fixture-only-long-pairing-token-' + $Id
    $config = @{host='192.168.2.6';port=9443;token=$token;proxy='http://127.0.0.1:9999';
        certificate='C:\missing-msix-view\server.pem';privateKey='C:\missing-msix-view\server-key.pem';keyFile='C:\missing-msix-view\supplier-key.txt'}
    [IO.File]::WriteAllText((Join-Path $Folder 'config.json'), ($config | ConvertTo-Json))
    $defines = @{VENICE_RELAY_URL='https://192.168.2.6:9443/api/v1';VENICE_RELAY_TOKEN=$token;VENICE_RELAY_CERT=[Convert]::ToBase64String($cert)}
    [IO.File]::WriteAllText((Join-Path $Folder 'android-defines.json'), ($defines | ConvertTo-Json))
}
try {
    $legacy = Join-Path $testRoot 'package-view'
    $old = Join-Path $legacy 'venice-relay'
    $stable = Join-Path $testRoot 'stable'
    New-Fixture $old
    $before = Read-RelayBundle $old
    $resolved = Initialize-RelayHome -HomePath $stable -LegacyRoots @($legacy)
    $after = Read-RelayBundle $stable
    Assert-True ($resolved -eq $stable -and $before.Identity -ceq $after.Identity) 'Package-only legacy migration preserves pairing'
    foreach ($name in @('server.pem','server-key.pem','supplier-key.txt','android-defines.json')) {
        Assert-True ((Get-FileHash (Join-Path $old $name)).Hash -eq (Get-FileHash (Join-Path $stable $name)).Hash) "Preserves bytes: $name"
    }
    Assert-True ($after.Config.proxy -eq $before.Config.proxy) 'Preserves optional proxy settings'
    Assert-True ($after.Config.keyFile -eq (Join-Path $stable 'supplier-key.txt')) 'Supplier key is independent of Desktop'
    Assert-True ((Read-RelayBundle (Join-Path $stable 'recovery')).Identity -ceq $before.Identity) 'Recovery bundle preserves pairing'
    # Delete only the fixture config; recovery must restore the same identity.
    Remove-Item -LiteralPath (Join-Path $stable 'config.json')
    Initialize-RelayHome -HomePath $stable -LegacyRoots @() | Out-Null
    Assert-True ((Read-RelayBundle $stable).Identity -ceq $before.Identity) 'Missing config recovers without rotating credentials'
    $other = Join-Path $testRoot 'other'
    New-Fixture (Join-Path $other 'venice-relay') 'two'
    Initialize-RelayHome -HomePath $stable -LegacyRoots @($other) | Out-Null
    Assert-True ((Read-RelayBundle $stable).Identity -ceq $before.Identity) 'Canonical config wins over unrelated legacy config'
    $conflict = Join-Path $testRoot 'conflict'
    Assert-Throws { Initialize-RelayHome -HomePath $conflict -LegacyRoots @($legacy,$other) } 'Conflicting identities require explicit recovery'
    Assert-True (-not (Test-Path (Join-Path $conflict 'config.json'))) 'Conflict writes no replacement config'
    $duplicate = Join-Path $testRoot 'duplicate'
    New-Fixture (Join-Path $duplicate 'venice-relay')
    $same = Join-Path $testRoot 'same'
    Initialize-RelayHome -HomePath $same -LegacyRoots @($legacy,$duplicate) | Out-Null
    Assert-True ((Read-RelayBundle $same).Identity -ceq $before.Identity) 'Duplicate views of one identity are accepted'
    $bad = Join-Path $testRoot 'bad'
    New-Fixture $bad
    [IO.File]::WriteAllText((Join-Path $bad 'config.json'), '{broken')
    Assert-Throws { Initialize-RelayHome -HomePath $bad -LegacyRoots @($legacy) } 'Corrupt canonical config is not silently overwritten'
    Assert-True ([IO.File]::ReadAllText((Join-Path $bad 'config.json')) -eq '{broken') 'Corrupt config retained for diagnosis'
    $missing = Join-Path $testRoot 'missing-file'
    New-Fixture $missing
    Remove-Item -LiteralPath (Join-Path $missing 'server-key.pem')
    Assert-Throws { Initialize-RelayHome -HomePath $missing -LegacyRoots @() } 'Missing private key blocks startup'
    $stale = Join-Path $testRoot 'stale'
    New-Fixture $stale
    Initialize-RelayHome -HomePath $stale -LegacyRoots @() | Out-Null
    Assert-True ((Read-RelayBundle $stale).Config.certificate -eq (Join-Path $stale 'server.pem')) 'Moved bundle repairs stale internal paths'
    $empty = Join-Path $testRoot 'empty'
    Assert-True ((Initialize-RelayHome -HomePath $empty -LegacyRoots @() -AllowMissing) -eq $empty -and -not (Test-Path $empty)) 'Provisioning lookup does not invent credentials'
    Assert-Throws { Initialize-RelayHome -HomePath $empty -LegacyRoots @() } 'Missing installation fails clearly'
    $localBefore = $env:LOCALAPPDATA
    $homeBefore = Get-RelayHome
    try {
        $env:LOCALAPPDATA = Join-Path $testRoot 'unrelated-appdata'
        Assert-True ((Get-RelayHome) -eq $homeBefore) 'Stable directory ignores LocalAppData virtualization'
    } finally { $env:LOCALAPPDATA = $localBefore }
    Write-Host "All $script:passed relay path assertions passed."
} finally {
    # Remove only this test's unique, resolved child under the system temp path.
    $resolvedTest = [IO.Path]::GetFullPath($testRoot)
    $resolvedTemp = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\') + '\'
    if ($resolvedTest.StartsWith($resolvedTemp, [StringComparison]::OrdinalIgnoreCase) -and
        [IO.Path]::GetFileName($resolvedTest).StartsWith('aihaptics-relay-path-test-')) {
        Remove-Item -LiteralPath $resolvedTest -Recurse -Force
    } else { throw 'Refused cleanup outside the test temp directory' }
}
