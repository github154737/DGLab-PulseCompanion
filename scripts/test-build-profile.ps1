$ErrorActionPreference = 'Stop'
. "$PSScriptRoot/build-profile.ps1"
$count = 0
function Expect-Rejection([scriptblock]$Action) {
    $rejected = $false
    try { & $Action } catch { $rejected = $true }
    if (-not $rejected) { throw 'Invalid profile was accepted.' }
    $script:count++
}
$public = @{ APP_EDITION='public'; APP_LOGIN_ENABLED=$false; APP_DEVELOPER_TOOLS=$false; VENICE_TEST_ENTRY=$true }
Assert-AppBuildDefines $public 'public'; $count++
foreach ($field in @('PILOT_ADMIN_HASH','PILOT_USER_HASHES','VENICE_RELAY_URL','VENICE_RELAY_TOKEN','VENICE_RELAY_CERT','VENICE_LOCAL_TEST_KEY','BETA_SERVICE_URL','UNKNOWN_KEY')) {
    $candidate = $public.Clone(); $candidate[$field] = 'fixture'
    Expect-Rejection { Assert-AppBuildDefines $candidate 'public' }
}
$candidate=$public.Clone(); $candidate.APP_LOGIN_ENABLED=$true
Expect-Rejection { Assert-AppBuildDefines $candidate 'public' }
$candidate=$public.Clone(); $candidate.APP_VERSION='fixture-secret-not-a-version'
Expect-Rejection { Assert-AppBuildDefines $candidate 'public' }
$candidate=$public.Clone(); $candidate.APP_LOGIN_ENABLED='false'
Expect-Rejection { Assert-AppBuildDefines $candidate 'public' }
$candidate=$public.Clone(); $candidate.VENICE_TEST_ENTRY=$false
Expect-Rejection { Assert-AppBuildDefines $candidate 'public' }
$pilot=@{ APP_EDITION='pilot'; APP_LOGIN_ENABLED=$true; APP_DEVELOPER_TOOLS=$false; VENICE_TEST_ENTRY=$true; PILOT_ADMIN_HASH=('a'*64); PILOT_USER_HASHES=('b'*64) }
Assert-AppBuildDefines $pilot 'pilot'; $count++
Expect-Rejection { Assert-AppBuildDefines $pilot 'public' }
$candidate=$pilot.Clone(); $candidate.APP_LOGIN_ENABLED=$false
Expect-Rejection { Assert-AppBuildDefines $candidate 'pilot' }
$candidate=$pilot.Clone(); $candidate.APP_DEVELOPER_TOOLS=$true
Expect-Rejection { Assert-AppBuildDefines $candidate 'pilot' }
$candidate=$pilot.Clone(); $candidate.PILOT_USER_HASHES=('a'*64)
Expect-Rejection { Assert-AppBuildDefines $candidate 'pilot' }
$candidate=$pilot.Clone(); $candidate.PILOT_ADMIN_HASH=''
Expect-Rejection { Assert-AppBuildDefines $candidate 'pilot' }
$candidate=$pilot.Clone(); $candidate.VENICE_RELAY_TOKEN='fixture'
Expect-Rejection { Assert-AppBuildDefines $candidate 'pilot' }
$path=Write-TemporaryDefines $public
try { Assert-AppBuildDefines (Read-DefineMap $path) 'public'; $count++ }
finally { Remove-Item -LiteralPath $path }
$previous=$env:DART_DEFINES
try { $env:DART_DEFINES='fixture'; Expect-Rejection { $null=Write-TemporaryDefines $public } }
finally { $env:DART_DEFINES=$previous }
Write-Output "$count build-profile checks passed. No builds or network calls."
