# prestart.ps1 - run by run-provider.cmd before every provider start (as SYSTEM).
#  1. Fixes the clock against the coordinator. Campus networks often block NTP, and a
#     clock more than 5 minutes off makes every heartbeat fail until the provider is
#     marked DEPARTED.
#  2. Prints this machine's current ZeroTier IP on stdout (empty if none), so the
#     runner always advertises the right address.
# Log lines go to stderr, which the runner appends to provider.log.

$ErrorActionPreference = 'Continue'
. (Join-Path $PSScriptRoot 'common.ps1')

$cfg = Read-JsonFile (Join-Path $script:InstallDir 'config.json')
if ($null -eq $cfg) { exit 0 }

$cli = Get-ZeroTierCli
$ip = $null
for ($i = 0; $i -lt 24; $i++) {          # after a reboot ZeroTier can take ~1-2 min
    if ($cli) { $ip = (Get-ZeroTierNetwork $cli $cfg.zerotier_network_id).Ip }
    if ($ip) { break }
    Start-Sleep -Seconds 5
}

$server = $null
for ($i = 0; $i -lt 6 -and $null -eq $server; $i++) {
    $server = Get-CoordinatorEpoch $cfg.microservice_url
    if ($null -eq $server) { Start-Sleep -Seconds 5 }
}
if ($null -ne $server) {
    $skew = (Get-NowEpoch) - $server
    if ([Math]::Abs($skew) -gt 30) {
        try {
            Set-Date -Date ([DateTimeOffset]::FromUnixTimeSeconds($server).UtcDateTime.ToLocalTime()) | Out-Null
            [Console]::Error.WriteLine("[prestart] clock was ${skew}s off the coordinator; corrected")
        } catch {
            [Console]::Error.WriteLine("[prestart] clock is ${skew}s off and could not be corrected: $($_.Exception.Message)")
        }
    }
} else {
    [Console]::Error.WriteLine("[prestart] coordinator not reachable yet; clock not checked")
}

if ($ip) { Write-Output $ip }
