# Run as administrator once. Restricts inbound access to the current LAN.
param([string]$LanAddress)
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\relay-paths.ps1"
$bundle = Read-RelayBundle (Initialize-RelayHome)
if (-not $LanAddress) { $LanAddress = $bundle.Config.host }
$port = $bundle.Config.port
$ruleName = 'AI Haptics Venice LAN Relay 9443'
if (-not (Get-NetFirewallRule -DisplayName $ruleName -ErrorAction SilentlyContinue)) {
    New-NetFirewallRule -DisplayName $ruleName -Direction Inbound -Action Allow -Protocol TCP -LocalPort $port -LocalAddress $LanAddress -RemoteAddress LocalSubnet -Profile Any | Out-Null
}
Write-Output 'LAN relay firewall rule is ready.'
