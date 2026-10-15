param([ValidateSet('status','invite5','manage','recover')][string]$Action='status',[string]$CommandJson)
. "$PSScriptRoot\env.ps1"
$stateDir = Join-Path $TaskRoot 'private\beta-service'
Push-Location $StagedApp
try {
    if ($Action -in @('manage','recover') -and -not $CommandJson) { throw 'CommandJson is required for this action' }
    & dart run tool/beta_admin.dart $stateDir $Action $CommandJson
    if ($LASTEXITCODE -ne 0) { throw 'Admin operation did not complete' }
} finally { Pop-Location }
