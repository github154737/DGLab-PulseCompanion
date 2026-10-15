$ErrorActionPreference = 'Stop'
$script:ProjectRoot = Split-Path $PSScriptRoot -Parent
# SDK/build cache only. Persistent relay credentials use relay-paths.ps1;
# they must not depend on this possibly MSIX-virtualized LocalAppData path.
$localDataRoot = $env:LOCALAPPDATA
if ([string]::IsNullOrWhiteSpace($localDataRoot)) {
    $localDataRoot = [Environment]::GetFolderPath('LocalApplicationData')
}
if ([string]::IsNullOrWhiteSpace($localDataRoot)) {
    throw 'Windows LocalAppData is unavailable. Start from the Windows account used to configure this project.'
}
$script:TaskRoot = Join-Path $localDataRoot 'AIHaptics'
$env:PATH = "$env:USERPROFILE\.cargo\bin;$TaskRoot\tools\flutter\bin;$env:PATH"
$buildEnvironment = Join-Path $env:USERPROFILE '.aihaptics/build-env.json'
if (Test-Path -LiteralPath $buildEnvironment) {
    $localBuild = Get-Content -LiteralPath $buildEnvironment -Raw | ConvertFrom-Json
    if (-not $env:JAVA_HOME -and $localBuild.javaHome) { $env:JAVA_HOME = $localBuild.javaHome }
}
if (-not $env:JAVA_HOME) {
    $studioJava = Join-Path $env:ProgramFiles 'Android/Android Studio/jbr'
    if (Test-Path -LiteralPath $studioJava) { $env:JAVA_HOME = $studioJava }
}
if (-not $env:ANDROID_HOME) { $env:ANDROID_HOME = Join-Path $env:USERPROFILE 'AppData\Local\Android\Sdk' }
$env:ANDROID_SDK_ROOT = $env:ANDROID_HOME
$env:CARGO_TARGET_DIR = Join-Path $TaskRoot 'build\rust'
$env:FLUTTER_SUPPRESS_ANALYTICS = 'true'
$env:CI = 'true'
$script:StagedApp = Join-Path $TaskRoot 'build\app'
function Sync-App {
    param([switch]$PilotAssets)
    New-Item -ItemType Directory -Path $StagedApp -Force | Out-Null
    # Do not overwrite Flutter-generated registration with stale source copies.
    & robocopy "$ProjectRoot\app" $StagedApp /E /XJ /XD build .dart_tool .idea .git ephemeral /XF local.properties .flutter-plugins-dependencies .flutter-plugins generated_plugin_registrant.cc generated_plugin_registrant.h generated_plugins.cmake GeneratedPluginRegistrant.java /NFL /NDL /NJH /NJS /NP | Out-Null
    if ($LASTEXITCODE -ge 8) { throw "Staging failed with robocopy exit code $LASTEXITCODE" }
    # Always overwrite this asset: public staging must not retain a pilot bundle.
    $waveSource = Join-Path $ProjectRoot 'app/assets/user-waveforms.zip'
    if ($PilotAssets) {
        $waveSource = Join-Path $env:USERPROFILE '.aihaptics/pilot-assets/user-waveforms.zip'
        if (-not (Test-Path -LiteralPath $waveSource)) { throw 'Private waveform bundle missing; see docs/building.md.' }
    }
    Copy-Item -LiteralPath $waveSource -Destination (Join-Path $StagedApp 'assets/user-waveforms.zip') -Force
    Ensure-PluginJunctions $StagedApp
}
function Ensure-PluginJunctions {
    param([string]$AppDir)
    $configPath = Join-Path $AppDir '.flutter-plugins-dependencies'
    if (-not (Test-Path -LiteralPath $configPath)) { return }
    $config = Get-Content -LiteralPath $configPath -Raw | ConvertFrom-Json
    $cmakePaths = [System.Collections.Generic.List[string]]::new()
    $junctionRoot = Join-Path $AppDir 'windows\flutter\ephemeral\.plugin_symlinks'
    New-Item -ItemType Directory -Path $junctionRoot -Force | Out-Null
    foreach ($plugin in $config.plugins.windows) {
        if ($plugin.name -notmatch '^[a-z0-9_]+$') { throw 'Unexpected plugin name' }
        # Flutter serializes Windows plugin paths with doubled separators.
        $target = [System.IO.Path]::GetFullPath(($plugin.path -replace '\\{2,}', '\')).TrimEnd('\','/')
        if (-not (Test-Path -LiteralPath $target -PathType Container)) { throw 'Plugin directory missing' }
        $cmakePaths.Add(('set(AIHAPTICS_PLUGIN_{0} "{1}")' -f $plugin.name, $target.Replace('\','/')))
        $junction = Join-Path $junctionRoot $plugin.name
        $existing = Get-Item -LiteralPath $junction -Force -ErrorAction SilentlyContinue
        if ($existing -and $existing.LinkType -eq 'Junction' -and $existing.Target -ne $target) {
            Remove-Item -LiteralPath $junction -Force
        }
        if (-not (Test-Path -LiteralPath $junction)) {
            New-Item -ItemType Junction -Path $junction -Value $target | Out-Null
        }
    }
    $cmakePaths | Set-Content -LiteralPath (Join-Path $AppDir 'windows\flutter\plugin_paths.cmake') -Encoding utf8
}
function Invoke-Checked {
    param([string]$Exe, [string[]]$Arguments)
    & $Exe @Arguments
    if ($LASTEXITCODE -ne 0) { throw "$Exe failed with exit code $LASTEXITCODE" }
}
