param([string]$Version = '0.5.0')
. "$PSScriptRoot\env.ps1"
if ($Version -notmatch '^\d+\.\d+\.\d+$') { throw 'Invalid package version' }
$destination = Join-Path $ProjectRoot 'artifacts'
$windowsBundle = Join-Path $destination "windows-$Version"
$windowsSource = Join-Path $StagedApp 'build\windows\x64\runner\Release'
$androidSource = Join-Path $StagedApp 'build\app\outputs\flutter-apk\app-release.apk'
if (-not (Test-Path -LiteralPath "$windowsSource\haptics_lab.exe") -or -not (Test-Path -LiteralPath $androidSource)) {
    throw 'Build both release targets before packaging.'
}
New-Item -ItemType Directory -Path $windowsBundle -Force | Out-Null
& robocopy $windowsSource $windowsBundle /E /NFL /NDL /NJH /NJS /NP | Out-Null
if ($LASTEXITCODE -ge 8) { throw 'Windows package copy failed' }
& robocopy "$ProjectRoot\docs\third-party" "$windowsBundle\third-party" /E /NFL /NDL /NJH /NJS /NP | Out-Null
if ($LASTEXITCODE -ge 8) { throw 'Notice copy failed' }
Copy-Item -LiteralPath "$ProjectRoot\reports\dependency-inventory.json" -Destination $windowsBundle -Force
& robocopy "$ProjectRoot\examples" "$windowsBundle\examples" /E /NFL /NDL /NJH /NJS /NP | Out-Null
if ($LASTEXITCODE -ge 8) { throw 'Example copy failed' }
Copy-Item -LiteralPath "$ProjectRoot\docs\v0.2-plan-and-interfaces.md" -Destination "$windowsBundle\waveforms-and-connections.md" -Force
Copy-Item -LiteralPath "$ProjectRoot\docs\v0.2.1-review.md" -Destination "$windowsBundle\v0.2.1-review.md" -Force
Copy-Item -LiteralPath "$ProjectRoot\docs\v0.3-api-and-chat.md" -Destination "$windowsBundle\model-api-and-chat.md" -Force
Copy-Item -LiteralPath "$ProjectRoot\docs\v0.3.1-review.md" -Destination "$windowsBundle\v0.3.1-review.md" -Force
Copy-Item -LiteralPath "$ProjectRoot\docs\v0.4-conversation-experience.md" -Destination "$windowsBundle\conversation-experience.md" -Force
Copy-Item -LiteralPath "$ProjectRoot\docs\v0.5-feature-parity.md" -Destination "$windowsBundle\feature-guide.md" -Force
Copy-Item -LiteralPath "$ProjectRoot\docs\v0.5-review.md" -Destination "$windowsBundle\v0.5-review.md" -Force
@"
AI Haptics Lab $Version — simulation and explicitly enabled Coyote 3.0 output

Run haptics_lab.exe. Keep this entire folder together.
Connect a simulator, authorize a 30-second session, then choose a short preset.
The red Stop button revokes authorization and invalidates pending model replies.
Import JSON waveforms, preview them, and adjust relative gain in chat.
The demo assistant uses fixed rules; local or HTTPS Chat Completions APIs can be configured.
Model settings and conversation preferences can be explicitly saved locally.
API keys, conversation history, and control grants are never saved by that feature.
Each assistant reply retains its actual action receipt, including cancelled follow-ups.
Choose a compatible imported waveform for the conversation experience.
Start a 30-second conversation experience for continuous simulated waveforms.
DG-LAB V4 supports discovery and short, bounded Coyote 3.0 output tasks.
Select a device, set A/B caps, and explicitly enable physical output for 30 seconds.
Intiface remains a discovery-only adapter in this release.
Physical output has protocol tests but has NOT been verified on actual hardware.
New: 24 original patterns, independent A/B controls, character cards, automatic
rounds, original branching stories and save slots, content JSON/ZIP imports,
Chinese/English UI, opt-in camera/microphone, guide and release-feed checks.
Camera images reach the model only when the separate sharing switch is enabled.
See feature-guide.md for supported formats and differences from the reference.

This is an unsigned local development build. Windows requires the Visual C++
runtime. Third-party notices are included; Flutter also bundles NOTICES.Z.
Source, test reports and build instructions are in the accompanying repository.
"@ | Set-Content -LiteralPath "$windowsBundle\README.txt" -Encoding utf8
$apk = Join-Path $destination "AIHapticsLab-$Version-android-internal.apk"
Copy-Item -LiteralPath $androidSource -Destination $apk -Force
$zip = Join-Path $destination "AIHapticsLab-$Version-windows-x64.zip"
Compress-Archive -Path "$windowsBundle\*" -DestinationPath $zip -Force
$artifacts = foreach ($file in @($apk,$zip)) {
    [ordered]@{
        file = 'artifacts/' + (Split-Path $file -Leaf)
        bytes = (Get-Item -LiteralPath $file).Length
        sha256 = (Get-FileHash -LiteralPath $file -Algorithm SHA256).Hash.ToLowerInvariant()
        simulated_output_only = $false
        physical_adapter = 'DG-LAB V4 / Coyote 3.0; explicit local enable'
        physical_hardware_verified = $false
        version = $Version
    }
}
$artifacts | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath "$ProjectRoot\reports\artifacts.json" -Encoding utf8
Write-Output "Packages and SHA-256 inventory written to $destination"
