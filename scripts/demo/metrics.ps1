#Requires -Version 7.0
# scripts/demo/metrics.ps1 - keep the Prometheus provider-target list in step with the
# ZeroTier network, so the operator never hand-edits targets JSON during a demo.
#
# Each provider installed from the bundle serves read-only daemon metrics on
# <its-zerotier-ip>:9091, reachable only from the coordinator (install.ps1's firewall rule).
# Prometheus (deployments/observability) reads its targets from a JSON file it hot-reloads
# every 15s. The missing piece has always been the IP -> desk mapping, because the
# coordinator's admin API exposes a provider's phone number but not its ZeroTier IP. The
# one place that holds both the IP and a human name is ZeroTier Central.
#
# MODES
#   sync   (default)  Pull the network's members from ZeroTier Central and write one target
#                     per authorized, online member to providers.json (and the coordinator
#                     to microservice.json). Needs a ZeroTier Central API token.
#   watch             sync in a loop (default every 20s) for the whole bring-up.
#   add               Add one target by hand: -Ip and -Desk. No token needed.
#   remove            Remove one target by -Ip or -Desk.
#   list              Print the current target file.
#
# The Central token is read from -Token, then $env:ZEROTIER_CENTRAL_TOKEN. Create one at
# my.zerotier.com -> Account -> API Access Tokens. It is used only to READ members of the
# one network you pass, over https to my.zerotier.com, and is never written to disk.
[CmdletBinding()]
param(
    [ValidateSet('sync', 'watch', 'add', 'remove', 'list')]
    [string]$Mode = 'sync',

    [string]$NetworkId = $env:VYOMANAUT_NETWORK_ID,
    [string]$Token = $env:ZEROTIER_CENTRAL_TOKEN,

    [int]$MetricsPort = 9091,
    [int]$ApiPort = 8080,

    # add / remove
    [string]$Ip = '',
    [string]$Desk = '',

    [int]$IntervalSeconds = 20,
    [string]$TargetsDir = '',
    # Only for testing against a stand-in server.
    [string]$CentralUrl = 'https://my.zerotier.com'
)

$ErrorActionPreference = 'Stop'

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$RepoRoot = Resolve-Path (Join-Path $ScriptDir '../..')
if (-not $TargetsDir) { $TargetsDir = Join-Path $RepoRoot 'deployments/observability/targets' }
$ProvidersFile = Join-Path $TargetsDir 'providers.json'
$MicroFile = Join-Path $TargetsDir 'microservice.json'

. (Join-Path $ScriptDir 'demo_env.ps1')

function Write-Log($m) { Write-Host "[metrics] $m" }

function Read-Targets([string]$path) {
    if (-not (Test-Path $path)) { return @() }
    $raw = (Get-Content -Raw -Path $path).Trim()
    if (-not $raw) { return @() }
    try { return @($raw | ConvertFrom-Json) } catch { Write-Log "warning: $path is not valid JSON; treating it as empty"; return @() }
}

# Writes targets as pretty JSON, atomically (temp file + move) so Prometheus never reads a
# half-written file mid-reload.
function Write-Targets([string]$path, $targets) {
    $json = @($targets) | ConvertTo-Json -Depth 5
    if ($null -eq $json) { $json = '[]' }
    if ($targets.Count -eq 1) { $json = "[$json]" }   # ConvertTo-Json drops the array for one item
    $tmp = "$path.tmp"
    Set-Content -Path $tmp -Value $json -Encoding UTF8
    Move-Item -Force -Path $tmp -Destination $path
}

function New-Target([string]$ip, [int]$port, [string]$desk, [string]$phone) {
    $labels = [ordered]@{ desk = $desk }
    if ($phone) { $labels.phone = $phone }
    return [ordered]@{ targets = @("${ip}:$port"); labels = $labels }
}

function Resolve-NetworkId {
    if ($NetworkId) { return $NetworkId }
    $env = Read-DemoEnv
    # not in env; try the one network this operator machine has actually joined
    $joined = @(Get-LocalZeroTierNetworks | Where-Object { $_.Status -eq 'OK' })
    if ($joined.Count -eq 1) { return $joined[0].Nwid }
    return $null
}

function Get-CentralMembers([string]$nwid) {
    if (-not $Token) {
        throw "A ZeroTier Central API token is needed for '$Mode'. Pass -Token, or set ZEROTIER_CENTRAL_TOKEN, or use '-Mode add' to add targets by hand. Create a token at my.zerotier.com -> Account -> API Access Tokens."
    }
    $headers = @{ Authorization = "token $Token" }
    return @(Invoke-RestMethod -Uri "$CentralUrl/api/v1/network/$nwid/member" -Headers $headers -TimeoutSec 15)
}

function Invoke-Sync {
    $nwid = Resolve-NetworkId
    if (-not $nwid) { throw 'Could not work out the ZeroTier network ID. Pass -NetworkId, or set VYOMANAUT_NETWORK_ID.' }
    $members = Get-CentralMembers $nwid

    $coordHost = $null
    $env = Read-DemoEnv
    if ($env['MICROSERVICE_URL']) { try { $coordHost = ([Uri]$env['MICROSERVICE_URL']).Host } catch { } }

    $providerTargets = @()
    $coordTargets = @()
    foreach ($m in $members) {
        if (-not $m.config.authorized) { continue }
        $ip = $null
        foreach ($a in @($m.config.ipAssignments)) { if ($a -match '^\d+\.\d+\.\d+\.\d+$') { $ip = $a; break } }
        if (-not $ip) { continue }
        $name = [string]$m.name
        if (-not $name) { $name = $ip }
        if ($coordHost -and $ip -eq $coordHost) {
            $coordTargets += New-Target $ip $ApiPort 'COORDINATOR' ''
            continue
        }
        # online only, so a desk that left for the day drops out on the next sync
        # Central reports `online` on current API versions; older ones only give lastOnline
        # (ms since epoch), so fall back to "seen in the last 5 minutes".
        $online = $false
        if ($null -ne $m.online) { $online = [bool]$m.online }
        elseif ($m.lastOnline) { $online = (([DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds() - [int64]$m.lastOnline) -lt 300000) }
        if (-not $online) { continue }
        $providerTargets += New-Target $ip $MetricsPort $name ''
    }

    Write-Targets $ProvidersFile $providerTargets
    if ($coordTargets.Count -gt 0) { Write-Targets $MicroFile $coordTargets }
    $extra = ''
    if ($coordTargets.Count -gt 0) { $extra = ' + coordinator' }
    Write-Log ("wrote {0} provider target(s){1}. Prometheus reloads within ~15s; check http://localhost:9090/targets" -f $providerTargets.Count, $extra)
}

switch ($Mode) {
    'list' {
        Write-Log "providers ($ProvidersFile):"
        Read-Targets $ProvidersFile | ForEach-Object { Write-Host ('  {0,-22} {1}' -f ($_.targets -join ','), $_.labels.desk) }
        Write-Log "coordinator ($MicroFile):"
        Read-Targets $MicroFile | ForEach-Object { Write-Host ('  {0,-22} {1}' -f ($_.targets -join ','), $_.labels.desk) }
    }
    'add' {
        if ($Ip -notmatch '^\d+\.\d+\.\d+\.\d+$') { throw "add needs a ZeroTier IPv4 address: -Ip 10.x.x.x" }
        if (-not $Desk) { $Desk = $Ip }
        $t = Read-Targets $ProvidersFile | Where-Object { ($_.targets -join ',') -notmatch "(^|,)$([regex]::Escape($Ip)):" }
        $t = @($t) + (New-Target $Ip $MetricsPort $Desk '')
        Write-Targets $ProvidersFile $t
        Write-Log "added ${Ip}:$MetricsPort as '$Desk'. It turns green in Prometheus once that PC's provider is serving metrics."
    }
    'remove' {
        if (-not $Ip -and -not $Desk) { throw 'remove needs -Ip or -Desk' }
        $t = Read-Targets $ProvidersFile | Where-Object {
            $keep = $true
            if ($Ip -and (($_.targets -join ',') -match "(^|,)$([regex]::Escape($Ip)):")) { $keep = $false }
            if ($Desk -and ($_.labels.desk -eq $Desk)) { $keep = $false }
            $keep
        }
        Write-Targets $ProvidersFile $t
        Write-Log 'removed.'
    }
    'watch' {
        Write-Log "syncing every ${IntervalSeconds}s from ZeroTier Central; Ctrl-C to stop."
        while ($true) {
            try { Invoke-Sync } catch { Write-Log "warning: $($_.Exception.Message)" }
            Start-Sleep -Seconds $IntervalSeconds
        }
    }
    default { Invoke-Sync }
}
