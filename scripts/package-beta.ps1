param([string]$Version='0.6.2', [string]$ServiceVersion='0.6.1')
. "$PSScriptRoot\env.ps1"
if ($Version -notmatch '^\d+\.\d+\.\d+$') { throw 'Invalid version' }
if ($ServiceVersion -notmatch '^\d+\.\d+\.\d+$') { throw 'Invalid service version' }
$artifacts = Join-Path $ProjectRoot 'artifacts'
$bundle = Join-Path $artifacts "windows-$Version-beta-local"
$windowsSource = Join-Path $StagedApp 'build\windows\x64\runner\Release'
$apkSource = Join-Path $StagedApp 'build\app\outputs\flutter-apk\app-release.apk'
if (-not (Test-Path -LiteralPath "$windowsSource/haptics_lab.exe") -or -not (Test-Path -LiteralPath $apkSource)) { throw 'Build both beta clients first' }
if (-not (Test-Path -LiteralPath "$windowsSource/record_windows_plugin.dll")) { throw 'Windows microphone plugin is missing; package rejected' }
New-Item -ItemType Directory -Path $bundle -Force | Out-Null
& robocopy $windowsSource $bundle /E /NFL /NDL /NJH /NJS /NP | Out-Null
if ($LASTEXITCODE -ge 8) { throw 'Bundle copy failed' }
& robocopy "$ProjectRoot/docs/third-party" "$bundle/third-party" /E /NFL /NDL /NJH /NJS /NP | Out-Null
if ($LASTEXITCODE -ge 8) { throw 'Notices copy failed' }
Copy-Item -LiteralPath "$ProjectRoot/docs/v0.6-bcd.md" -Destination "$bundle/使用说明.md" -Force
@'
AI Haptics Lab 0.6.2 - LOCAL BETA / SIMULATION ONLY

Start the project-owned beta service before connecting this client.
This build uses http://127.0.0.1:8790. It is not a deployed public service.
Windows automatically authenticates to this local service using the current user's private profile.
Android requires an invitation. No provider API key goes into either client.
Run haptics_lab.exe with this entire folder intact.
Voice upload starts only after clicking the microphone button.
Autonomous simulation requires separate local approval. Stop revokes all plans.
Camera and physical output are not available in this beta entry point.
Android local testing requires an intentional USB/emulator port reverse.
Real microphone quality, ARM64 hardware and full-duplex speaker mode are not accepted yet.
See 使用说明.md for deployment, account recovery and precise verification limits.
'@ | Set-Content -LiteralPath "$bundle/README.txt" -Encoding utf8
$apk = Join-Path $artifacts "AIHapticsLab-$Version-beta-local-android.apk"
Copy-Item -LiteralPath $apkSource -Destination $apk -Force
$zip = Join-Path $artifacts "AIHapticsLab-$Version-beta-local-windows-x64.zip"
Compress-Archive -Path "$bundle/*" -DestinationPath $zip -Force
$inventory = foreach ($file in @($apk,$zip,"$artifacts/beta-service-$ServiceVersion/beta_service.exe","$artifacts/beta-service-$ServiceVersion/beta_admin.exe")) {
    $fileVersion = if ($file -like "*/beta-service-$ServiceVersion/*") { $ServiceVersion } else { $Version }
    [ordered]@{ file=$file;bytes=(Get-Item -LiteralPath $file).Length;sha256=(Get-FileHash -LiteralPath $file -Algorithm SHA256).Hash.ToLowerInvariant();version=$fileVersion;provider_credentials_included=$false;public_deployment_verified=$false }
}
$inventory | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath "$ProjectRoot/reports/bcd-artifacts.json" -Encoding utf8
Write-Output 'Local beta client packages and standalone Windows service inventory written.'
