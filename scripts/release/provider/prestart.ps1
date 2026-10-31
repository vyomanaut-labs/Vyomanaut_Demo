# prestart.ps1 - run by run-provider.cmd before every provider start (as SYSTEM).
#  1. Event over? (config.json expires_unix) -> creates the STOP flag so the runner exits
#     and stays stopped, even after reboots, until the volunteer uninstalls.
#  2. Waits for this PC's ZeroTier address (after a reboot ZeroTier can take a minute or two).
#  3. Keeps the firewall rules pointed at the current ZeroTier network and operator.
#  4. Fixes the clock against the coordinator. Campus and event networks often block NTP,
#     and a clock more than 5 minutes off makes every heartbeat fail until the provider is
#     marked DEPARTED. Contacting the coordinator here also wakes up the ZeroTier path.
#  5. Prints this PC's ZeroTier IP on stdout (empty if none), so the runner always
#     advertises - and serves metrics on - the right address.
# Log lines go to stderr, which the runner appends to provider.log.

$ErrorActionPreference = 'Continue'
. (Join-Path $PSScriptRoot 'common.ps1')
function Write-Log([string]$m) { [Console]::Error.WriteLine("[prestart] $m") }

$cfg = Read-JsonFile (Join-Path $script:InstallDir 'config.json')
if ($null -eq $cfg) { exit 0 }

if (Test-BundleExpired $cfg) {
    New-Item -ItemType File -Force -Path $script:StopFlag | Out-Null
    Write-Log ("this event ended on {0}; the provider is stopped for good. Use 'Vyomanaut Uninstall' to remove it." -f (Format-Epoch ([int64]$cfg.expires_unix)))
    exit 0
}

$cli = Get-ZeroTierCli
$net = $null
for ($i = 0; $i -lt 24; $i++) {
    if ($cli) {
        $net = Get-ZeroTierNetwork $cli ([string]$cfg.zerotier_network_id).ToLower()
        if ($net.Ip) { break }
    }
    Start-Sleep -Seconds 5
}
if (-not ($net -and $net.Ip)) { Write-Log 'no ZeroTier address yet; starting with the address from setup' }

if ($net -and $net.Subnet) {
    try {
        $metricsPort = 0
        if ($null -ne $cfg.metrics_port) { $metricsPort = [int]$cfg.metrics_port }
        if (Set-ProviderFirewall ([int]$cfg.listen_port) $net.Subnet $metricsPort (Get-MetricsAllowList $cfg)) {
            Write-Log "firewall rules updated for $($net.Subnet)"
        }
    } catch {
        Write-Log "could not update the firewall rules: $($_.Exception.Message)"
    }
}

$skew = $null
for ($i = 0; $i -lt 6 -and $null -eq $skew; $i++) {
    try {
        $skew = Sync-ClockToCoordinator ([string]$cfg.microservice_url) 30
    } catch {
        Write-Log "clock is off and could not be corrected: $($_.Exception.Message)"
        break
    }
    if ($null -eq $skew) { Start-Sleep -Seconds 5 }
}
if ($null -eq $skew) { Write-Log 'coordinator not reachable yet; clock not checked' }
elseif ([Math]::Abs($skew) -gt 30) { Write-Log "clock was ${skew}s off the coordinator; corrected" }

if ($net -and $net.Ip) { Write-Output $net.Ip }
