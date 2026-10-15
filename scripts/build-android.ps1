param([switch]$Release, [switch]$Offline, [switch]$Detailed, [string]$BetaServiceUrl, [switch]$VenicePersonal, [string]$VeniceRelayDefines, [string]$AppDefines, [string]$PilotLoginDefines)
. "$PSScriptRoot\env.ps1"
. "$PSScriptRoot\build-profile.ps1"
$privateDefineFile = $null
if ($AppDefines -and ($VenicePersonal -or $VeniceRelayDefines -or $BetaServiceUrl -or $Detailed)) { throw 'Cannot mix public profile and private/legacy build options.' }
$profileConfig = $null
if ($AppDefines) {
    $profileConfig = Read-DefineMap $AppDefines
    Assert-AppBuildDefines $profileConfig 'public'
} elseif ($VeniceRelayDefines -or $VenicePersonal) {
    $profileConfig = Get-PilotBuildDefines -RelayPath $VeniceRelayDefines -LoginPath $PilotLoginDefines
}
if ($env:DART_DEFINES -or $env:FLUTTER_TOOL_ARGS) { throw 'Unexpected build environment overrides.' }
if ($VeniceRelayDefines -and ($VenicePersonal -or $Detailed -or $BetaServiceUrl)) { throw 'Relay build cannot mix credentials, verbose logging or beta service.' }
if ($VenicePersonal -and $Detailed) { throw 'Verbose logs are not allowed for a personal-key build.' }
Push-Location $ProjectRoot
try {
    if ($VenicePersonal) {
        $localKeyFile = Join-Path ([Environment]::GetFolderPath('Desktop')) 'VENICE_APIKEY.txt'
        $localKeys = @([regex]::Matches([IO.File]::ReadAllText($localKeyFile), 'VENICE_INFERENCE_KEY_[A-Za-z0-9_-]{20,200}') | ForEach-Object { $_.Value } | Select-Object -Unique)
        if ($localKeys.Count -ne 1) { throw 'Expected exactly one personal Venice key.' }
        $profileConfig.VENICE_LOCAL_TEST_KEY = $localKeys[0]
        $localKeys = $null
    }
    if ($profileConfig) { $privateDefineFile = Write-TemporaryDefines $profileConfig }
    $ndkBin = "$env:ANDROID_HOME\ndk\28.2.13676358\toolchains\llvm\prebuilt\windows-x86_64\bin"
    $profile = if ($Release) { 'release' } else { 'debug' }
    $env:CARGO_TARGET_AARCH64_LINUX_ANDROID_LINKER = "$ndkBin\clang.exe"
    $env:CARGO_TARGET_X86_64_LINUX_ANDROID_LINKER = "$ndkBin\clang.exe"
    $env:CARGO_TARGET_AARCH64_LINUX_ANDROID_RUSTFLAGS = '-C link-arg=--target=aarch64-linux-android24 -C link-arg=-Wl,-z,max-page-size=16384'
    $env:CARGO_TARGET_X86_64_LINUX_ANDROID_RUSTFLAGS = '-C link-arg=--target=x86_64-linux-android24 -C link-arg=-Wl,-z,max-page-size=16384'
    foreach ($entry in @(@('aarch64-linux-android','arm64-v8a'),@('x86_64-linux-android','x86_64'))) {
        $cargoArgs = @('build','--locked','--jobs','2','-p','haptics_core','--target',$entry[0])
        if ($Release) { $cargoArgs += '--release' }
        Invoke-Checked cargo $cargoArgs
        $dest = "app\android\app\src\main\jniLibs\$($entry[1])"
        New-Item -ItemType Directory -Path $dest -Force | Out-Null
        Copy-Item -LiteralPath "$env:CARGO_TARGET_DIR\$($entry[0])\$profile\libhaptics_core.so" -Destination $dest -Force
    }
    Sync-App -PilotAssets:($null -ne $profileConfig -and $profileConfig.APP_EDITION -eq 'pilot')
    Push-Location $StagedApp
    try {
        $pubArgs = @('--no-version-check','pub','get','--enforce-lockfile')
        if ($Offline) { $pubArgs += '--offline' }
        Invoke-Checked flutter $pubArgs
        $buildArgs = @('--no-version-check','build','apk',"--$profile",'--target-platform','android-arm64,android-x64')
        if ($profileConfig) {
            $version = [regex]::Match((Get-Content "$ProjectRoot/app/pubspec.yaml" -Raw), '(?m)^version:\s*(\S+)').Groups[1].Value
            $buildArgs += @('--dart-define=VENICE_TEST_ENTRY=true', "--dart-define=APP_VERSION=$version", "--dart-define-from-file=$privateDefineFile")
        }
        if ($BetaServiceUrl) {
            if ($BetaServiceUrl -notmatch '^(https://[^/?#@]+/?|http://127\.0\.0\.1:\d+/?)$') { throw 'Beta service must use HTTPS or an explicit loopback port' }
            $buildArgs += @("--dart-define=BETA_SERVICE_URL=$BetaServiceUrl", "--dart-define=VENICE_TEST_ENTRY=false")
        }
        if ($Detailed) { $buildArgs += '--verbose' }
        if ($Offline) {
            # Flutter 3.47 skips release registrant regeneration with --no-pub.
            # Only the generated staging file is adjusted; pub get restores it for tests.
            if ($Release) {
                $registrant = Join-Path $StagedApp 'android\app\src\main\java\io\flutter\plugins\GeneratedPluginRegistrant.java'
                $java = Get-Content -LiteralPath $registrant -Raw
                $pattern = '(?ms)^    try \{\r?\n      flutterEngine\.getPlugins\(\)\.add\(new dev\.flutter\.plugins\.integration_test\.IntegrationTestPlugin\(\)\);\r?\n    \} catch \(Exception e\) \{\r?\n      Log\.e\(TAG, "Error registering plugin integration_test,[^\r\n]+\r?\n    \}\r?\n'
                if ([regex]::Matches($java, $pattern).Count -ne 1) { throw 'Unexpected integration registrant; offline release requires review' }
                # Windows PowerShell's utf8 encoding adds a BOM rejected by javac.
                [IO.File]::WriteAllText($registrant, [regex]::Replace($java, $pattern, ''), [Text.UTF8Encoding]::new($false))
            }
            $buildArgs += '--no-pub'
        }
        Invoke-Checked flutter $buildArgs
        if ($Release) {
            $apkPath = Join-Path $StagedApp 'build\app\outputs\flutter-apk\app-release.apk'
            Add-Type -AssemblyName System.IO.Compression.FileSystem
            $archive = [System.IO.Compression.ZipFile]::OpenRead($apkPath)
            try {
                $nativeFiles = @(
                    $archive.Entries | Where-Object { $_.FullName -like 'lib/*' } |
                    Select-Object -ExpandProperty FullName
                )
                $abis = @($nativeFiles | ForEach-Object { $_.Split('/')[1] } | Sort-Object -Unique)
                if (($abis -join ',') -ne 'arm64-v8a,x86_64') { throw 'APK contains unexpected native architectures' }
                foreach ($abi in $abis) {
                    foreach ($library in @('libapp.so','libflutter.so','libhaptics_core.so')) {
                        if ($nativeFiles -notcontains "lib/$abi/$library") { throw "APK is missing $abi/$library" }
                    }
                }
                Write-Output 'APK architecture completeness verified: ARM64 and x86_64.'
            } finally { $archive.Dispose() }
        }
    } finally { Pop-Location }
} finally {
    Pop-Location
    if ($privateDefineFile) { Remove-Item -LiteralPath $privateDefineFile -Force }
}
