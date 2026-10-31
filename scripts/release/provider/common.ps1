# common.ps1 - shared paths and helpers for the Vyomanaut provider scripts.
# Windows PowerShell 5.1 compatible. ASCII only (PS 5.1 misreads UTF-8 without BOM).
# Dot-sourced by install.ps1, prestart.ps1, vyomanaut.ps1 and uninstall.ps1.

$script:InstallDir   = Join-Path $env:ProgramFiles 'Vyomanaut'
$script:DataRoot     = Join-Path $env:ProgramData 'Vyomanaut'
$script:DataDir      = Join-Path $script:DataRoot 'data'
$script:LogDir       = Join-Path $script:DataRoot 'logs'
$script:LogFile      = Join-Path $script:LogDir 'provider.log'
$script:InstallLog   = Join-Path $script:LogDir 'install.log'
$script:StopFlag     = Join-Path $script:DataRoot 'STOP'
$script:StateFile    = Join-Path $script:DataRoot 'installed.json'
$script:FwStateFile  = Join-Path $script:DataRoot 'firewall.txt'
$script:RegFile      = Join-Path $script:DataDir 'registration.json'
$script:ProviderExe  = Join-Path $script:InstallDir 'provider.exe'
$script:RunnerFile   = Join-Path $script:InstallDir 'run-provider.cmd'
$script:TaskName     = 'Vyomanaut Provider'
$script:FwRuleName   = 'Vyomanaut Provider (TCP-In)'
$script:FwMetricsRuleName = 'Vyomanaut Provider Metrics (TCP-In)'
$script:MenuDir      = Join-Path $env:ProgramData 'Microsoft\Windows\Start Menu\Programs\Vyomanaut'
$script:TranscriptPath = $null

# ---------------------------------------------------------------- console output
function Write-Step([string]$n, [string]$msg) { Write-Host ''; Write-Host "[$n] $msg" -ForegroundColor Cyan }
function Write-Ok([string]$msg)   { Write-Host "    OK  $msg" -ForegroundColor Green }
function Write-Info([string]$msg) { Write-Host "    $msg" }
function Write-Warn([string]$msg) { Write-Host "    WARNING: $msg" -ForegroundColor Yellow }
function Stop-WithError([string]$msg) {
    Write-Host ''
    Write-Host "ERROR: $msg" -ForegroundColor Red
    if ($script:TranscriptPath) {
        Write-Host "Setup log (show it to the operator if you need help): $($script:TranscriptPath)"
        try { Stop-Transcript | Out-Null } catch { }
    }
    exit 1
}

# Draws a yellow box around a few lines, for the things a person must act on.
function Write-Box([string[]]$lines, [string]$color = 'Yellow') {
    $w = 0
    foreach ($l in $lines) { if ($l.Length -gt $w) { $w = $l.Length } }
    $bar = '+' + ('-' * ($w + 4)) + '+'
    Write-Host ''
    Write-Host "    $bar" -ForegroundColor $color
    foreach ($l in $lines) { Write-Host ('    |  ' + $l.PadRight($w) + '  |') -ForegroundColor $color }
    Write-Host "    $bar" -ForegroundColor $color
}

function Test-IsAdmin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    return (New-Object Security.Principal.WindowsPrincipal($id)).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Read-JsonFile([string]$path) {
    if (-not (Test-Path $path)) { return $null }
    try { return (Get-Content -Raw -Path $path | ConvertFrom-Json) } catch { return $null }
}

function Get-NowEpoch { return [int64]([DateTimeOffset]::UtcNow.ToUnixTimeSeconds()) }

function Format-Epoch([int64]$epoch) {
    return [DateTimeOffset]::FromUnixTimeSeconds($epoch).LocalDateTime.ToString('ddd d MMM yyyy, HH:mm')
}

# Last four digits of a phone number, for messages that should not show all of it.
function Get-PhoneTail([string]$phone) {
    $d = ($phone -replace '\D', '')
    if ($d.Length -ge 4) { return $d.Substring($d.Length - 4) }
    return $d
}

# ---------------------------------------------------------------- IPv4 / CIDR helpers
function Test-IPv4([string]$s) {
    if ($s -notmatch '^\d{1,3}(\.\d{1,3}){3}$') { return $false }
    foreach ($o in $s.Split('.')) { if ([int]$o -gt 255) { return $false } }
    return $true
}

# '10.147.17.5/24' -> '10.147.17.0/24'. Returns $null for anything that is not IPv4 CIDR.
# Plain arithmetic (no bit operators) so it behaves the same on every PowerShell version.
function Get-CidrNetwork([string]$cidr) {
    $parts = $cidr.Split('/')
    if ($parts.Count -ne 2 -or -not (Test-IPv4 $parts[0])) { return $null }
    $prefix = 0
    if (-not [int]::TryParse($parts[1], [ref]$prefix) -or $prefix -lt 0 -or $prefix -gt 32) { return $null }
    $o = $parts[0].Split('.')
    $v = [uint64]$o[0] * 16777216 + [uint64]$o[1] * 65536 + [uint64]$o[2] * 256 + [uint64]$o[3]
    $size = [uint64][Math]::Pow(2, 32 - $prefix)
    $net = [uint64][Math]::Floor($v / $size) * $size
    $a = [Math]::Floor($net / 16777216) % 256
    $b = [Math]::Floor($net / 65536) % 256
    $c = [Math]::Floor($net / 256) % 256
    $d = $net % 256
    return ('{0}.{1}.{2}.{3}/{4}' -f $a, $b, $c, $d, $prefix)
}

# Host part of a URL such as http://10.147.17.1:8080 -> 10.147.17.1
function Get-UrlHost([string]$url) {
    try { return ([Uri]$url).Host } catch { return $null }
}

# ---------------------------------------------------------------- ZeroTier
function Get-ZeroTierCli {
    $candidates = @(
        (Join-Path ${env:ProgramFiles(x86)} 'ZeroTier\One\zerotier-cli.bat'),
        (Join-Path $env:ProgramFiles 'ZeroTier\One\zerotier-cli.bat')
    )
    foreach ($c in $candidates) { if ($c -and (Test-Path $c)) { return $c } }
    return $null
}

# Runs zerotier-cli with -j and returns parsed JSON, or $null on failure.
function Invoke-ZeroTierJson([string]$cli, [string[]]$cliArgs) {
    try {
        $raw = & $cli -j @cliArgs 2>$null | Out-String
        if (-not $raw.Trim()) { return $null }
        return ($raw | ConvertFrom-Json)
    } catch { return $null }
}

# Returns @{ Status = 'OK' | 'REQUESTING_CONFIGURATION' | 'ACCESS_DENIED' | 'NOT_JOINED' | ...;
#            Ip = '10.x.x.x' or $null; Subnet = '10.x.x.0/24' or $null; Name = network name }
function Get-ZeroTierNetwork([string]$cli, [string]$networkId) {
    $result = @{ Status = 'NOT_JOINED'; Ip = $null; Subnet = $null; Name = '' }
    $nets = Invoke-ZeroTierJson $cli @('listnetworks')
    if ($null -eq $nets) { $result.Status = 'NO_ANSWER'; return $result }
    foreach ($n in @($nets)) {
        if ([string]$n.nwid -eq $networkId) {
            $result.Status = [string]$n.status
            $result.Name = [string]$n.name
            foreach ($a in @($n.assignedAddresses)) {
                $s = [string]$a
                $ip = $s.Split('/')[0]
                if (Test-IPv4 $ip) {
                    $result.Ip = $ip
                    $result.Subnet = Get-CidrNetwork $s
                    break
                }
            }
        }
    }
    return $result
}

# ---------------------------------------------------------------- coordinator
# Returns the coordinator's unix time, or $null if unreachable.
function Get-CoordinatorEpoch([string]$url) {
    try {
        $r = Invoke-RestMethod -Uri "$url/api/v1/time" -TimeoutSec 8 -UseBasicParsing
        if ($r.unix_epoch) { return [int64]$r.unix_epoch }
    } catch { }
    return $null
}

# Sets the clock from the coordinator when it is more than $maxSkew seconds off.
# Returns the skew that was found (positive = this PC is ahead), or $null if unreachable.
function Sync-ClockToCoordinator([string]$url, [int]$maxSkew = 30) {
    $server = Get-CoordinatorEpoch $url
    if ($null -eq $server) { return $null }
    $skew = (Get-NowEpoch) - $server
    if ([Math]::Abs($skew) -gt $maxSkew) {
        Set-Date -Date ([DateTimeOffset]::FromUnixTimeSeconds($server).UtcDateTime.ToLocalTime()) | Out-Null
    }
    return $skew
}

# Reads the body of a failed web request. Works on Windows PowerShell 5.1 and PowerShell 7
# (ErrorDetails is not reliably filled on 5.1, so the response stream is read directly).
function Get-WebErrorBody($errorRecord) {
    try {
        if ($errorRecord.ErrorDetails -and $errorRecord.ErrorDetails.Message) { return [string]$errorRecord.ErrorDetails.Message }
        $resp = $errorRecord.Exception.Response
        if ($null -ne $resp -and $resp.GetType().GetMethod('GetResponseStream')) {
            $sr = New-Object System.IO.StreamReader($resp.GetResponseStream())
            try { return $sr.ReadToEnd() } finally { $sr.Dispose() }
        }
    } catch { }
    return ''
}

# Asks the coordinator about this PC's registration.
# Returns 'valid', 'expired' (token older than its 7-day life), 'stale' (the coordinator
# was reset: it no longer recognises this PC's token or has no such provider), 'none'
# (no registration on disk) or 'unknown' (coordinator unreachable or an answer we do not
# understand). Only a clear "invalid token" or "provider not found" counts as stale, so
# a hiccup can never cause a good registration to be set aside.
function Test-Registration([string]$url) {
    $reg = Read-JsonFile $script:RegFile
    if ($null -eq $reg) {
        if (Test-Path $script:RegFile) { return 'stale' }   # present but unreadable
        return 'none'
    }
    if (-not $reg.provider_id -or -not $reg.token) { return 'stale' }
    try {
        Invoke-WebRequest -Uri "$url/api/v1/provider/$($reg.provider_id)/status" -UseBasicParsing -TimeoutSec 10 `
            -Headers @{ Authorization = "Bearer $($reg.token)" } | Out-Null
        return 'valid'
    } catch {
        $resp = $_.Exception.Response
        if ($null -eq $resp) { return 'unknown' }
        $code = [int]$resp.StatusCode
        $body = Get-WebErrorBody $_
        if ($code -eq 401 -and $body -match 'expired') { return 'expired' }
        if ($code -eq 401 -and $body -match 'invalid token') { return 'stale' }
        if ($code -eq 403) { return 'stale' }
        if ($code -eq 404 -and $body -match 'provider not found') { return 'stale' }
        return 'unknown'
    }
}

# This PC's record as the coordinator sees it (status, score, stored_chunks, ...), or $null.
function Get-ProviderNetworkStatus([string]$url) {
    $reg = Read-JsonFile $script:RegFile
    if ($null -eq $reg -or -not $reg.provider_id -or -not $reg.token) { return $null }
    try {
        return Invoke-RestMethod -Uri "$url/api/v1/provider/$($reg.provider_id)/status" -UseBasicParsing -TimeoutSec 8 `
            -Headers @{ Authorization = "Bearer $($reg.token)" }
    } catch { return $null }
}

# ---------------------------------------------------------------- firewall
# Two inbound rules, both limited to provider.exe:
#   - the provider port, reachable only from the ZeroTier network (not the cafe/campus Wi-Fi)
#   - the metrics port, reachable only from the operator's Prometheus (the coordinator by default)
# The rules are rewritten only when the addresses change; firewall.txt remembers the last set.
function Set-ProviderFirewall([int]$port, [string]$subnet, [int]$metricsPort, [string[]]$metricsFrom) {
    $remote = 'Any'
    if ($subnet) { $remote = $subnet }
    $metricsList = @($metricsFrom | Where-Object { $_ })
    $wanted = "port=$port from=$remote metrics=$metricsPort from=$($metricsList -join ',')"
    $have = ''
    if (Test-Path $script:FwStateFile) { $have = (Get-Content -Raw -Path $script:FwStateFile).Trim() }
    $rulesPresent = [bool](Get-NetFirewallRule -DisplayName $script:FwRuleName -ErrorAction SilentlyContinue)
    if ($have -eq $wanted -and $rulesPresent) { return $false }

    Get-NetFirewallRule -DisplayName $script:FwRuleName -ErrorAction SilentlyContinue | Remove-NetFirewallRule
    Get-NetFirewallRule -DisplayName $script:FwMetricsRuleName -ErrorAction SilentlyContinue | Remove-NetFirewallRule
    New-NetFirewallRule -DisplayName $script:FwRuleName -Direction Inbound -Action Allow -Protocol TCP `
        -LocalPort $port -RemoteAddress $remote -Program $script:ProviderExe -Profile Any `
        -Description 'Vyomanaut: storage traffic from the event ZeroTier network only' | Out-Null
    if ($metricsPort -gt 0 -and $metricsList.Count -gt 0) {
        New-NetFirewallRule -DisplayName $script:FwMetricsRuleName -Direction Inbound -Action Allow -Protocol TCP `
            -LocalPort $metricsPort -RemoteAddress $metricsList -Program $script:ProviderExe -Profile Any `
            -Description 'Vyomanaut: read-only metrics for the operator dashboard' | Out-Null
    }
    Set-Content -Path $script:FwStateFile -Value $wanted -Encoding ASCII
    return $true
}

function Remove-ProviderFirewall {
    Get-NetFirewallRule -DisplayName $script:FwRuleName -ErrorAction SilentlyContinue | Remove-NetFirewallRule
    Get-NetFirewallRule -DisplayName $script:FwMetricsRuleName -ErrorAction SilentlyContinue | Remove-NetFirewallRule
    Remove-Item -Force -Path $script:FwStateFile -ErrorAction SilentlyContinue
}

# Who may read the metrics port: the bundle's explicit list, else the coordinator's host.
function Get-MetricsAllowList($cfg) {
    $list = @()
    foreach ($a in @($cfg.metrics_allow_from)) { if ($a) { $list += [string]$a } }
    if ($list.Count -eq 0) {
        $h = Get-UrlHost ([string]$cfg.microservice_url)
        if ($h -and (Test-IPv4 $h)) { $list += $h }
    }
    return $list
}

# ---------------------------------------------------------------- power settings
# Reads the current AC timeout (seconds) of a SUB_SLEEP setting. powercfg's labels are
# translated on non-English Windows, so this reads the last two hex values it prints,
# which are always the AC and DC indexes, in that order.
function Get-PowerAcSeconds([string]$setting) {
    try {
        $out = & powercfg.exe /query SCHEME_CURRENT SUB_SLEEP $setting 2>$null | Out-String
        $hex = @([regex]::Matches($out, '0x[0-9a-fA-F]{8}') | ForEach-Object { $_.Value })
        if ($hex.Count -lt 2) { return $null }
        return [Convert]::ToInt64($hex[$hex.Count - 2].Substring(2), 16)
    } catch { return $null }
}

# Remembers the current sleep timeouts (once - an upgrade never overwrites them), then
# turns sleep off while on mains power. A sleeping provider looks DEPARTED.
function Disable-SleepOnAc($state) {
    $saved = $null
    if ($state -and $state.power_restore) { $saved = $state.power_restore }
    if ($null -eq $saved) {
        $saved = [ordered]@{
            standby_ac_seconds   = Get-PowerAcSeconds 'STANDBYIDLE'
            hibernate_ac_seconds = Get-PowerAcSeconds 'HIBERNATEIDLE'
        }
    }
    & powercfg.exe /change standby-timeout-ac 0 | Out-Null
    & powercfg.exe /change hibernate-timeout-ac 0 | Out-Null
    return $saved
}

function Restore-SleepOnAc($saved) {
    if ($null -eq $saved) { return $false }
    $done = $false
    if ($null -ne $saved.standby_ac_seconds) {
        & powercfg.exe /setacvalueindex SCHEME_CURRENT SUB_SLEEP STANDBYIDLE ([int64]$saved.standby_ac_seconds) | Out-Null
        $done = $true
    }
    if ($null -ne $saved.hibernate_ac_seconds) {
        & powercfg.exe /setacvalueindex SCHEME_CURRENT SUB_SLEEP HIBERNATEIDLE ([int64]$saved.hibernate_ac_seconds) | Out-Null
        $done = $true
    }
    if ($done) { & powercfg.exe /setactive SCHEME_CURRENT | Out-Null }
    return $done
}

# ---------------------------------------------------------------- event expiry
# A bundle carries an end date (build_provider_bundle.ps1 -ValidDays). After it the
# provider stops by itself, so a volunteer who forgets to uninstall is not left with a
# background program trying to reach a coordinator that no longer exists.
function Test-BundleExpired($cfg) {
    if ($null -eq $cfg -or -not $cfg.expires_unix) { return $false }
    return ((Get-NowEpoch) -gt [int64]$cfg.expires_unix)
}

# ---------------------------------------------------------------- local metrics
# Sums the samples of a few daemon metrics from this PC's own metrics endpoint.
function Get-LocalMetrics([string]$ip, [int]$port) {
    if (-not $ip -or $port -le 0) { return $null }
    try {
        $text = (Invoke-WebRequest -Uri "http://${ip}:$port/metrics" -UseBasicParsing -TimeoutSec 4).Content
    } catch { return $null }
    $want = @('vyomanaut_daemon_chunks_stored_total', 'vyomanaut_daemon_audit_responses_sent_total',
              'vyomanaut_daemon_heartbeat_sent_total', 'vyomanaut_daemon_content_hash_failures_total',
              'vyomanaut_daemon_ram_constrained')
    $m = @{}
    foreach ($line in ($text -split "`n")) {
        if ($line -match '^([a-z_]+)(\{[^}]*\})?\s+([0-9.eE+-]+)\s*$' -and $want -contains $Matches[1]) {
            $v = 0.0
            if ([double]::TryParse($Matches[3], [Globalization.NumberStyles]::Float, [Globalization.CultureInfo]::InvariantCulture, [ref]$v)) {
                if ($m.ContainsKey($Matches[1])) { $m[$Matches[1]] += $v } else { $m[$Matches[1]] = $v }
            }
        }
    }
    return $m
}

# ---------------------------------------------------------------- the background provider
function Stop-Provider {
    New-Item -ItemType File -Force -Path $script:StopFlag | Out-Null
    $t = Get-ScheduledTask -TaskName $script:TaskName -ErrorAction SilentlyContinue
    if ($t) { Stop-ScheduledTask -TaskName $script:TaskName -ErrorAction SilentlyContinue }
    Get-Process -Name 'provider' -ErrorAction SilentlyContinue |
        Where-Object { $_.Path -eq $script:ProviderExe } |
        Stop-Process -Force -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 2
}

function Start-Provider {
    Remove-Item -Force -Path $script:StopFlag -ErrorAction SilentlyContinue
    Enable-ScheduledTask -TaskName $script:TaskName -ErrorAction SilentlyContinue | Out-Null
    Start-ScheduledTask -TaskName $script:TaskName
}

function Test-ProviderRunning {
    $p = Get-Process -Name 'provider' -ErrorAction SilentlyContinue | Where-Object { $_.Path -eq $script:ProviderExe }
    return [bool]$p
}

# provider.exe processes that are NOT this installation - typically a window left open
# from the older join.ps1 method. Two providers on one PC fight over the same port.
function Get-OtherProviderProcesses {
    return @(Get-Process -Name 'provider' -ErrorAction SilentlyContinue |
        Where-Object { $_.Path -and $_.Path -ne $script:ProviderExe })
}

# What a provider status means, in words a volunteer understands.
function Get-StatusExplanation([string]$status) {
    switch ($status) {
        'PENDING_ONBOARDING' { return 'registered - waiting for the first check-in' }
        'VETTING'            { return 'on probation - the network is testing this PC (usually 10-30 minutes)' }
        'ACTIVE'             { return 'storing data for the network - thank you!' }
        'DEPARTED'           { return 'the network thinks this PC left - try Vyomanaut Restart, then tell the operator' }
        default              { return '' }
    }
}
