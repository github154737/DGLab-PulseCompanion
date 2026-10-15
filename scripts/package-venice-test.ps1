param([string]$Version, [switch]$EmbeddedLocalKey)
. "$PSScriptRoot/env.ps1"
if (-not $Version) {
    $versionMatch = [regex]::Match((Get-Content -LiteralPath "$ProjectRoot/app/pubspec.yaml" -Raw), '(?m)^version:\s*(\d+\.\d+\.\d+)\+\d+\s*$')
    if (-not $versionMatch.Success) { throw 'Missing application version.' }
    $Version = $versionMatch.Groups[1].Value
}
if ($Version -notmatch '^\d+\.\d+\.\d+$') { throw 'Invalid version.' }
$veniceSource = Join-Path $StagedApp 'build/windows/x64/runner/Release'
$veniceBundle = Join-Path $ProjectRoot "artifacts/windows-$Version-beta-local"
$veniceExe = Join-Path $veniceSource 'haptics_lab.exe'
if (-not (Test-Path -LiteralPath $veniceExe) -or -not (Test-Path -LiteralPath "$veniceSource/record_windows_plugin.dll")) {
    throw 'Windows application or microphone plugin is missing.'
}
if ((Get-Item -LiteralPath $veniceExe).VersionInfo.FileVersion -notlike "$Version+*") { throw 'Wrong source build version.' }
New-Item -ItemType Directory -Path $veniceBundle -Force | Out-Null
& robocopy $veniceSource $veniceBundle /E /NFL /NDL /NJH /NJS /NP | Out-Null
if ($LASTEXITCODE -ge 8) { throw 'Bundle copy failed.' }
& robocopy "$ProjectRoot/docs/third-party" "$veniceBundle/third-party" /E /NFL /NDL /NJH /NJS /NP | Out-Null
if ($LASTEXITCODE -ge 8) { throw 'Notices copy failed.' }
# Scan binary and text files with built-in .NET APIs so packaging also works
# in a normal PyCharm terminal without ripgrep on PATH. Keep overlap so a
# credential spanning two chunks is detected. Never print matching content.
$veniceCredentialPattern = [regex]'VENICE_INFERENCE_KEY_[A-Za-z0-9_-]{20,200}'
foreach ($veniceFile in (Get-ChildItem -LiteralPath $veniceBundle -Recurse -File -Force)) {
    $veniceStream = [System.IO.File]::OpenRead($veniceFile.FullName)
    try {
        $veniceBuffer = New-Object byte[] 65536
        $veniceTail = ''
        while (($veniceRead = $veniceStream.Read($veniceBuffer, 0, $veniceBuffer.Length)) -gt 0) {
            $veniceChunk = $veniceTail + [System.Text.Encoding]::ASCII.GetString($veniceBuffer, 0, $veniceRead)
            if ($veniceCredentialPattern.IsMatch($veniceChunk)) {
                if (-not $EmbeddedLocalKey) { throw 'Unexpected credential-like content in package.' }
            }
            $veniceTail = $veniceChunk.Substring([Math]::Max(0, $veniceChunk.Length - 256))
        }
    } finally { $veniceStream.Dispose() }
}
@'
@echo off
start "" "%~dp0haptics_lab.exe" --venice
'@ | Set-Content -LiteralPath "$veniceBundle/Start-Venice.cmd" -Encoding ascii
@'
AI Haptics Lab - Venice speech input / text output - Windows local test

Run Start-Venice.cmd to open the test page directly. No Qwen backend is needed.
Models: stt-xai-v1 -> venice-uncensored-1-2 (Venice Uncensored 1.2).
Endpoints: /api/v1/audio/transcriptions and /api/v1/chat/completions.

1. Prepare API credits, then enable manual sending on the page.
2. Click Start recording. The microphone stays local until transcription.
3. Click Stop and transcribe. The WAV recording is uploaded to Venice.
4. The transcript is displayed and, by default, sent to the text model.
   Disable automatic sending to edit the transcript before sending it.

Recordings are limited to 60 seconds and held only in memory, never saved as
audio files. The duration cap stops recording locally and waits for a click
to upload. Cancel, leaving the page, or hiding the application cancels the
round. Requests already submitted may still be billed by the provider.
Failures are not retried automatically. Chat failure keeps the transcript so
retrying chat does not repeat the audio upload. There is no voice playback or
camera. The waveform panel provides simulation and optional DG-LAB 4 relay
output for built-in protocol frames. Imported .pulse files have shape preview
and byte-for-byte export only; their physical conversion is not yet verified.

The local operator key is loaded from Windows DPAPI storage, outside this
package. Windows resolves its current-user local-data folder directly;
the key path does not depend on the launching terminal or working directory.
No credentials or user conversations are included here. This is not an APK
or a remotely deployed test service.

Verification records are maintained in the project's reports folder. Checks
include real microphone capture with local mock services and an opt-in live
page test using synthetic speech with Venice STT and chat. They do not measure
the user's own microphone recognition quality or guarantee account balance.
'@ | Set-Content -LiteralPath "$veniceBundle/README.txt" -Encoding utf8
$veniceZip = Join-Path $ProjectRoot "artifacts/AIHapticsLab-$Version-venice-windows-x64.zip"
if ($EmbeddedLocalKey) {
    'PRIVATE LOCAL TEST BUILD - Contains an embedded personal API key. Do not distribute. Run Start-Venice.cmd. No key import is needed.' |
        Set-Content -LiteralPath "$veniceBundle/README.txt" -Encoding utf8
}
# ZIP cannot represent pre-1980 timestamps carried by some license files.
# Normalize only copies in the distribution folder, never source files.
Get-ChildItem -LiteralPath $veniceBundle -Recurse -File | Where-Object {
    $_.LastWriteTime.Year -lt 1980 -or $_.LastWriteTime.Year -gt 2107
} | ForEach-Object { $_.LastWriteTime = [datetime]'2000-01-01' }
Compress-Archive -Path "$veniceBundle/*" -DestinationPath $veniceZip -Force
[ordered]@{version=$Version;artifact=$veniceZip;bytes=(Get-Item -LiteralPath $veniceZip).Length;sha256=(Get-FileHash -LiteralPath $veniceZip -Algorithm SHA256).Hash.ToLowerInvariant();embedded_local_key=[bool]$EmbeddedLocalKey;credential_pattern_scan=$(if ($EmbeddedLocalKey) {'private_build_key_allowed'} else {'passed'})} |
    ConvertTo-Json | Set-Content -LiteralPath "$ProjectRoot/reports/venice-speech-artifact.json" -Encoding utf8
Write-Output 'Venice Windows test package is ready; no API calls were made.'
