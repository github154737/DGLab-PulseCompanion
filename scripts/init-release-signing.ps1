# Run once by the release maintainer; never by CI or ordinary app users.
. "$PSScriptRoot/env.ps1"
$signingRoot = Join-Path $env:USERPROFILE '.aihaptics/release-signing'
$propertiesFile = Join-Path $signingRoot 'signing.properties'
$keyFile = Join-Path $signingRoot 'release.jks'
if ((Test-Path -LiteralPath $keyFile) -or (Test-Path -LiteralPath $propertiesFile)) {
    throw 'Signing identity already exists. Back it up; do not replace an update signing key.'
}
if (-not $env:JAVA_HOME) { throw 'Set JAVA_HOME to a JDK first.' }
New-Item -ItemType Directory -Path $signingRoot -Force | Out-Null
$identity = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
& icacls $signingRoot /inheritance:r /grant:r "*${identity}:(OI)(CI)F" '*S-1-5-18:(OI)(CI)F' | Out-Null
if ($LASTEXITCODE -ne 0) { throw 'Cannot protect signing directory.' }
$random = New-Object byte[] 32
$rng = [Security.Cryptography.RandomNumberGenerator]::Create()
$rng.GetBytes($random)
$rng.Dispose()
$previousPassword = $env:AIHAPTICS_KEY_PASSWORD
try {
    $env:AIHAPTICS_KEY_PASSWORD = [Convert]::ToBase64String($random)
    & (Join-Path $env:JAVA_HOME 'bin/keytool.exe') -genkeypair -keystore $keyFile -storetype JKS -alias release -keyalg RSA -keysize 3072 -validity 10000 -dname 'CN=AI Haptics community release' -storepass:env AIHAPTICS_KEY_PASSWORD -keypass:env AIHAPTICS_KEY_PASSWORD
    if ($LASTEXITCODE -ne 0) { throw 'Signing identity generation failed.' }
    $safePath = $keyFile.Replace('\','/').Replace(':','\:')
    $content = "storeFile=$safePath`nstorePassword=$env:AIHAPTICS_KEY_PASSWORD`nkeyAlias=release`nkeyPassword=$env:AIHAPTICS_KEY_PASSWORD`n"
    [IO.File]::WriteAllText($propertiesFile, $content, [Text.UTF8Encoding]::new($false))
} finally { $env:AIHAPTICS_KEY_PASSWORD = $previousPassword }
Write-Output 'Release identity created outside the repository. Back up the entire .aihaptics/release-signing directory securely; it is needed for future updates.'
