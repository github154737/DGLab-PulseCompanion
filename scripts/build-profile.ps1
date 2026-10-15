$ErrorActionPreference = 'Stop'

function Read-DefineMap([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { throw 'Build configuration is missing. See docs/source-configuration.md.' }
    $value = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
    if ($value -isnot [pscustomobject]) { throw 'Build configuration must be a JSON object.' }
    $map = @{}
    foreach ($property in $value.PSObject.Properties) { $map[$property.Name] = $property.Value }
    return $map
}

function Assert-AppBuildDefines([hashtable]$Config, [string]$ExpectedEdition) {
    $allowed = @('APP_EDITION','APP_LOGIN_ENABLED','APP_DEVELOPER_TOOLS','VENICE_TEST_ENTRY','APP_VERSION',
        'PILOT_ADMIN_HASH','PILOT_USER_HASHES','VENICE_RELAY_KIND','VENICE_RELAY_URL','VENICE_RELAY_TOKEN','VENICE_RELAY_CERT','VENICE_LOCAL_TEST_KEY')
    foreach ($key in $Config.Keys) {
        if ($key -notin $allowed) { throw 'Unknown build configuration field. Refusing unchecked defines.' }
    }
    if ($Config.APP_EDITION -notin @('public','pilot') -or ($ExpectedEdition -and $Config.APP_EDITION -ne $ExpectedEdition)) {
        throw 'Build edition mismatch.'
    }
    foreach ($key in @('APP_LOGIN_ENABLED','APP_DEVELOPER_TOOLS','VENICE_TEST_ENTRY')) {
        if ($Config[$key] -isnot [bool]) { throw 'Build switches must be JSON booleans.' }
    }
    if (-not $Config.VENICE_TEST_ENTRY) { throw 'This profile must use the current application entry.' }
    if ($Config.ContainsKey('APP_VERSION') -and $Config.APP_VERSION -notmatch '^\d+\.\d+\.\d+(\+\d+)?$') { throw 'Invalid application version.' }
    if ($Config.APP_EDITION -eq 'public') {
        if ($Config.APP_LOGIN_ENABLED) { throw 'Public builds cannot enable pilot login.' }
        foreach ($key in @('PILOT_ADMIN_HASH','PILOT_USER_HASHES','VENICE_RELAY_KIND','VENICE_RELAY_URL','VENICE_RELAY_TOKEN','VENICE_RELAY_CERT','VENICE_LOCAL_TEST_KEY')) {
            if ($Config.ContainsKey($key)) { throw 'Public builds cannot contain private service or login fields, even empty ones.' }
        }
    } else {
        if (-not $Config.APP_LOGIN_ENABLED -or $Config.APP_DEVELOPER_TOOLS) { throw 'Pilot builds require role-based login.' }
        if ($Config.PILOT_ADMIN_HASH -cnotmatch '^[a-f0-9]{64}$' -or $Config.PILOT_USER_HASHES -cnotmatch '^[a-f0-9]{64}(,[a-f0-9]{64})*$') { throw 'Pilot credential hashes are missing or invalid.' }
        $codes = @($Config.PILOT_USER_HASHES.Split(','))
        if (@($codes | Select-Object -Unique).Count -ne $codes.Count -or $codes -contains $Config.PILOT_ADMIN_HASH) { throw 'Duplicate pilot credentials are not allowed.' }
        if ($Config.VENICE_RELAY_URL) {
            $uri = $null
            if (-not [Uri]::TryCreate($Config.VENICE_RELAY_URL, [UriKind]::Absolute, [ref]$uri) -or
                $uri.Scheme -ne 'https' -or $uri.UserInfo -or $uri.Query -or $uri.Fragment -or
                -not $Config.VENICE_RELAY_TOKEN -or -not $Config.VENICE_RELAY_CERT -or $Config.VENICE_LOCAL_TEST_KEY) { throw 'Invalid private relay configuration.' }
            try { $null = [Convert]::FromBase64String($Config.VENICE_RELAY_CERT) } catch { throw 'Invalid relay certificate encoding.' }
        } elseif ($Config.VENICE_RELAY_TOKEN -or $Config.VENICE_RELAY_CERT) { throw 'Relay credentials require a relay address.' }
    }
}

function Get-PilotBuildDefines([string]$RelayPath, [string]$LoginPath) {
    if (-not $LoginPath) { $LoginPath = Join-Path $env:USERPROFILE '.aihaptics\pilot-access\login-defines.json' }
    $map = Read-DefineMap $LoginPath
    if ($RelayPath) {
        $relay = Read-DefineMap $RelayPath
        foreach ($key in $relay.Keys) {
            if ($key -notin @('VENICE_RELAY_KIND','VENICE_RELAY_URL','VENICE_RELAY_TOKEN','VENICE_RELAY_CERT')) { throw 'Unexpected relay field.' }
            $map[$key] = $relay[$key]
        }
    }
    $map.APP_EDITION = 'pilot'; $map.APP_LOGIN_ENABLED = $true
    $map.APP_DEVELOPER_TOOLS = $false; $map.VENICE_TEST_ENTRY = $true
    Assert-AppBuildDefines $map 'pilot'
    return $map
}

function Write-TemporaryDefines([hashtable]$Config) {
    Assert-AppBuildDefines $Config $Config.APP_EDITION
    if ($env:DART_DEFINES -or $env:FLUTTER_TOOL_ARGS) { throw 'Clear DART_DEFINES and FLUTTER_TOOL_ARGS before a profile build.' }
    $path = Join-Path ([IO.Path]::GetTempPath()) ('aihaptics-build-' + [Guid]::NewGuid().ToString('N') + '.json')
    [IO.File]::WriteAllText($path, ($Config | ConvertTo-Json), [Text.UTF8Encoding]::new($false))
    return $path
}
