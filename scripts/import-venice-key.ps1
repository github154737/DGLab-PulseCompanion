param(
    [Parameter(Mandatory=$true, ParameterSetName='Text')][string]$KeyFile,
    [Parameter(Mandatory=$true, ParameterSetName='Image')][string]$ImagePath
)
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Security
$privateDir = Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'AIHaptics\private\venice'
New-Item -ItemType Directory -Path $privateDir -Force | Out-Null
$identity = [Security.Principal.WindowsIdentity]::GetCurrent().Name
& icacls $privateDir /inheritance:r /grant:r "${identity}:(OI)(CI)F" | Out-Null
if ($LASTEXITCODE -ne 0) { throw 'Unable to restrict local credential directory.' }
$rawBytes = $null
try {
    if ($PSCmdlet.ParameterSetName -eq 'Text') {
        $rawText = [IO.File]::ReadAllText((Resolve-Path -LiteralPath $KeyFile).Path)
    } else {
        # Offline Windows OCR: neither image nor recognized text leaves this PC.
        Add-Type -AssemblyName System.Runtime.WindowsRuntime
        $null = [Windows.Storage.StorageFile, Windows.Storage, ContentType=WindowsRuntime]
        $null = [Windows.Storage.Streams.IRandomAccessStream, Windows.Storage.Streams, ContentType=WindowsRuntime]
        $null = [Windows.Graphics.Imaging.BitmapDecoder, Windows.Graphics.Imaging, ContentType=WindowsRuntime]
        $null = [Windows.Graphics.Imaging.SoftwareBitmap, Windows.Graphics.Imaging, ContentType=WindowsRuntime]
        $null = [Windows.Media.Ocr.OcrEngine, Windows.Foundation, ContentType=WindowsRuntime]
        function Await-WinRT($Operation, [Type]$ResultType) {
            $method = [System.WindowsRuntimeSystemExtensions].GetMethods() | Where-Object {
                $_.Name -eq 'AsTask' -and $_.IsGenericMethod -and $_.GetParameters().Count -eq 1 -and
                $_.GetParameters()[0].ParameterType.Name -eq 'IAsyncOperation`1'
            } | Select-Object -First 1
            $task = $method.MakeGenericMethod($ResultType).Invoke($null, @($Operation))
            $task.GetAwaiter().GetResult()
        }
        $file = Await-WinRT ([Windows.Storage.StorageFile]::GetFileFromPathAsync((Resolve-Path -LiteralPath $ImagePath).Path)) ([Windows.Storage.StorageFile])
        $stream = Await-WinRT ($file.OpenAsync([Windows.Storage.FileAccessMode]::Read)) ([Windows.Storage.Streams.IRandomAccessStream])
        try {
            $decoder = Await-WinRT ([Windows.Graphics.Imaging.BitmapDecoder]::CreateAsync($stream)) ([Windows.Graphics.Imaging.BitmapDecoder])
            $bitmap = Await-WinRT ($decoder.GetSoftwareBitmapAsync()) ([Windows.Graphics.Imaging.SoftwareBitmap])
            try {
                $engine = [Windows.Media.Ocr.OcrEngine]::TryCreateFromUserProfileLanguages()
                $result = Await-WinRT ($engine.RecognizeAsync($bitmap)) ([Windows.Media.Ocr.OcrResult])
                # The dedicated key field is above the sample curl command.
                $keyLine = @($result.Lines | Where-Object { $_.Text -match 'VENICE' }) | Select-Object -First 1
                $rawText = $keyLine.Text -replace '\s', ''
                $rawText = $rawText -replace '^VENICE_?INFERENCE_?KEY_?', 'VENICE_INFERENCE_KEY_'
            } finally { if ($bitmap) { $bitmap.Dispose() } }
        } finally { $stream.Dispose() }
    }
    $matches = @([regex]::Matches($rawText, 'VENICE_INFERENCE_KEY_[A-Za-z0-9_-]{20,200}') | ForEach-Object { $_.Value } | Select-Object -Unique)
    if ($matches.Count -ne 1) {
        throw 'Credential could not be read unambiguously. Use a local text file.'
    }
    $rawBytes = [Text.Encoding]::UTF8.GetBytes($matches[0])
    $sealed = [Security.Cryptography.ProtectedData]::Protect($rawBytes, $null, [Security.Cryptography.DataProtectionScope]::CurrentUser)
    # Verify the local cryptographic round trip; this is not API authentication.
    $verified = [Security.Cryptography.ProtectedData]::Unprotect($sealed, $null, [Security.Cryptography.DataProtectionScope]::CurrentUser)
    try {
        if ([Convert]::ToBase64String($rawBytes) -cne [Convert]::ToBase64String($verified)) { throw 'Encryption check failed.' }
    } finally { [Array]::Clear($verified, 0, $verified.Length) }
    [IO.File]::WriteAllBytes((Join-Path $privateDir 'api-key.sealed'), $sealed)
    Write-Output 'Venice credential encrypted for this Windows user. No API request was made.'
} catch {
    # Never print OCR content, credential bytes or exceptions that could contain them.
    Write-Output ('Import diagnostic: ' + $_.Exception.GetType().Name + ' at line ' + $_.InvocationInfo.ScriptLineNumber)
    throw 'Venice credential import failed. Check the source file and local Windows OCR support.'
} finally {
    if ($rawBytes) { [Array]::Clear($rawBytes, 0, $rawBytes.Length) }
    $rawText = $null; $matches = $null; $result = $null
}
