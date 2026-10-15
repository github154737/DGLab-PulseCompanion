param([switch]$ConfirmPaidRequests)
$ErrorActionPreference = 'Stop'
if (-not $ConfirmPaidRequests) { throw 'Pass -ConfirmPaidRequests for one chat and one synthetic-audio transcription request.' }
. "$PSScriptRoot/env.ps1"
Add-Type -AssemblyName System.Security
Add-Type -AssemblyName System.Speech
$probeRaw = $null
$probeSynth = $null
$probeAudio = $null
try {
    $probeRaw = [Security.Cryptography.ProtectedData]::Unprotect(
        [IO.File]::ReadAllBytes((Join-Path $TaskRoot 'private/venice/api-key.sealed')),
        $null, [Security.Cryptography.DataProtectionScope]::CurrentUser)
    $probeSynth = New-Object System.Speech.Synthesis.SpeechSynthesizer
    $probeAudio = New-Object IO.MemoryStream
    $probeFormat = New-Object System.Speech.AudioFormat.SpeechAudioFormatInfo(16000, [System.Speech.AudioFormat.AudioBitsPerSample]::Sixteen, [System.Speech.AudioFormat.AudioChannel]::Mono)
    $probeSynth.SetOutputToAudioStream($probeAudio, $probeFormat)
    $probeSynth.Speak('Hello. This is a speech recognition test.')
    $probeSynth.SetOutputToNull()
    $probePayload = @{key=[Text.Encoding]::UTF8.GetString($probeRaw).Trim();pcm=[Convert]::ToBase64String($probeAudio.ToArray())} | ConvertTo-Json -Compress
    $probeInfo = New-Object Diagnostics.ProcessStartInfo
    $probeInfo.FileName = Join-Path $TaskRoot 'tools/flutter/bin/cache/dart-sdk/bin/dart.exe'
    $probeInfo.Arguments = 'run app/tool/venice_live_probe.dart'
    $probeInfo.WorkingDirectory = $ProjectRoot
    $probeInfo.UseShellExecute = $false
    $probeInfo.CreateNoWindow = $true
    $probeInfo.RedirectStandardInput = $true
    $probeInfo.RedirectStandardOutput = $true
    $probeInfo.RedirectStandardError = $true
    $probeInfo.StandardOutputEncoding = [Text.Encoding]::UTF8
    $probeProcess = [Diagnostics.Process]::Start($probeInfo)
    $probeProcess.StandardInput.Write($probePayload)
    $probeProcess.StandardInput.Close()
    $probeOutput = $probeProcess.StandardOutput.ReadToEndAsync()
    $probeErrors = $probeProcess.StandardError.ReadToEndAsync()
    if (-not $probeProcess.WaitForExit(110000)) { $probeProcess.Kill(); throw 'Live check timed out.' }
    if ($probeProcess.ExitCode -ne 0) { throw 'Live check failed locally; provider data suppressed.' }
    $probeResult = $probeOutput.Result | ConvertFrom-Json
    $probeResult | ConvertTo-Json | Set-Content -LiteralPath "$ProjectRoot/reports/venice-live-check.json" -Encoding utf8
    $probeResult | ConvertTo-Json
} finally {
    if ($probeRaw) { [Array]::Clear($probeRaw,0,$probeRaw.Length) }
    if ($probeSynth) { $probeSynth.Dispose() }
    if ($probeAudio) { $probeAudio.Dispose() }
    $probePayload = $null
}
