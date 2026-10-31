# vyomanaut.ps1 - everyday commands for an installed Vyomanaut provider.
#   vyomanaut.ps1 status | earnings | logs | restart | stop | start | inspect | uninstall
# The Start-menu shortcuts call this. Windows PowerShell 5.1 compatible. ASCII only.
param(
    [Parameter(Position = 0)] [string]$Command = 'status',
    [switch]$Pause
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'common.ps1')

# The data folder is administrators-only, so every command runs elevated.
if (-not (Test-IsAdmin)) {
    $argList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$PSCommandPath`"", $Command)
    if ($Pause) { $argList += '-Pause' }
    Start-Process -FilePath 'powershell.exe' -ArgumentList $argList -Verb RunAs
    exit
}

$cfg = Read-JsonFile (Join-Path $script:InstallDir 'config.json')
$state = Read-JsonFile $script:StateFile
if ($null -eq $cfg) { Stop-WithError 'Vyomanaut is not installed on this PC.' }
$Url = [string]$cfg.microservice_url
$MetricsPort = 0
if ($null -ne $cfg.metrics_port) { $MetricsPort = [int]$cfg.metrics_port }

function Write-Row([string]$label, [string]$value, [string]$color = 'Gray') {
    Write-Host ('    {0,-13}' -f $label) -NoNewline
    Write-Host $value -ForegroundColor $color
}

function Show-Status {
    Write-Host ''
    Write-Host '  Vyomanaut provider status' -ForegroundColor White
    Write-Host ''

    # this PC
    $t = Get-ScheduledTask -TaskName $script:TaskName -ErrorAction SilentlyContinue
    $running = Test-ProviderRunning
    if (Test-BundleExpired $cfg) {
        Write-Row 'Provider' ("stopped - the event ended on {0}. Please run 'Vyomanaut Uninstall'." -f (Format-Epoch ([int64]$cfg.expires_unix))) 'Yellow'
    } elseif ($running) {
        Write-Row 'Provider' 'running' 'Green'
    } elseif (Test-Path $script:StopFlag) {
        Write-Row 'Provider' "stopped on purpose - use 'Vyomanaut Restart' to resume" 'Yellow'
    } elseif (-not $t) {
        Write-Row 'Provider' 'background task missing - run Install.cmd again' 'Red'
    } else {
        Write-Row 'Provider' "NOT running - try 'Vyomanaut Restart'" 'Red'
    }

    # ZeroTier
    $ip = $null
    $cli = Get-ZeroTierCli
    if ($cli) {
        $info = Invoke-ZeroTierJson $cli @('info')
        $net = Get-ZeroTierNetwork $cli ([string]$cfg.zerotier_network_id).ToLower()
        $ip = $net.Ip
        $online = $false
        if ($info) { $online = [bool]$info.online }
        if ($online -and $net.Status -eq 'OK') {
            $extra = ''
            if ($info.tcpFallbackActive) { $extra = ' (slow TCP relay - UDP is blocked here)' }
            Write-Row 'ZeroTier' "connected, this PC is $($net.Ip)$extra" 'Green'
        } else {
            Write-Row 'ZeroTier' "not connected (network status: $($net.Status))" 'Red'
        }
        if ($state -and $net.Ip -and $state.ip -and $state.ip -ne $net.Ip) {
            Write-Info "             (address changed since setup, was $($state.ip); picked up on the next restart)"
        }
    } else {
        Write-Row 'ZeroTier' 'not installed' 'Red'
    }

    # coordinator + this PC's standing in the network
    $server = Get-CoordinatorEpoch $Url
    if ($null -ne $server) {
        $skew = (Get-NowEpoch) - $server
        $c = 'Green'; $note = ''
        if ([Math]::Abs($skew) -gt 120) { $c = 'Yellow'; $note = ' - too far off, Vyomanaut Restart fixes it' }
        Write-Row 'Coordinator' "reachable, clock offset ${skew}s$note" $c
        $st = Get-ProviderNetworkStatus $Url
        if ($st) {
            $color = 'Gray'
            if ($st.status -eq 'ACTIVE') { $color = 'Green' } elseif ($st.status -eq 'DEPARTED') { $color = 'Red' } elseif ($st.status -eq 'VETTING') { $color = 'Yellow' }
            Write-Row 'Network role' ("{0} - {1}" -f $st.status, (Get-StatusExplanation ([string]$st.status))) $color
            $score = 'not scored yet'
            if ($null -ne $st.score_composite) { $score = ('{0:N0}%' -f ([double]$st.score_composite * 100)) }
            Write-Row 'Reliability' ("{0}, {1} audits passed in a row" -f $score, $st.consecutive_audit_passes)
            Write-Row 'Fragments' ("{0} stored for the network" -f $st.stored_chunks)
        } else {
            switch (Test-Registration $Url) {
                'stale'   { Write-Row 'Network role' 'unknown to this coordinator (it was reset) - run Install.cmd again' 'Red' }
                'expired' { Write-Row 'Network role' 'registration expired (older than 7 days) - ask the operator' 'Red' }
                'none'    { Write-Row 'Network role' 'not registered - run Install.cmd again' 'Red' }
                default   { Write-Row 'Network role' 'could not ask the coordinator' 'Yellow' }
            }
        }
    } else {
        Write-Row 'Coordinator' "NOT reachable at $Url" 'Red'
    }

    # local metrics (only what this PC itself reports)
    if ($MetricsPort -gt 0 -and $ip -and $running) {
        $m = Get-LocalMetrics $ip $MetricsPort
        if ($null -ne $m) {
            Write-Row 'Activity' ("{0} audit answers, {1} check-ins since the last start" -f `
                [int]$m['vyomanaut_daemon_audit_responses_sent_total'], [int]$m['vyomanaut_daemon_heartbeat_sent_total'])
            if ($m['vyomanaut_daemon_content_hash_failures_total'] -gt 0) { Write-Row 'Disk check' 'a stored fragment failed its integrity check - tell the operator' 'Red' }
            if ($m['vyomanaut_daemon_ram_constrained'] -gt 0) { Write-Row 'Memory' 'low free RAM - close some programs' 'Yellow' }
        } else {
            Write-Row 'Activity' "metrics not answering yet on ${ip}:$MetricsPort" 'Yellow'
        }
    }

    if ($state) { Write-Row 'Sharing' "$($state.storage_gb) GB (bundle $($state.version))" }
    if ($cfg.expires_unix -and -not (Test-BundleExpired $cfg)) { Write-Row 'Event ends' (Format-Epoch ([int64]$cfg.expires_unix)) }

    Write-Host ''
    Write-Host '  Last log lines:' -ForegroundColor White
    if (Test-Path $script:LogFile) { Get-Content -Path $script:LogFile -Tail 12 | ForEach-Object { Write-Host "    $_" } } else { Write-Info '(no log yet)' }
}

switch ($Command.ToLower()) {
    'status'   { Show-Status }
    'earnings' { & $script:ProviderExe earnings "--microservice-url=$Url" "--data-dir=$($script:DataDir)" }
    'logs'     { if (Test-Path $script:LogFile) { Start-Process notepad.exe -ArgumentList "`"$($script:LogFile)`"" } else { Write-Info 'no log yet' } }
    'stop'     { Stop-Provider; Write-Ok "stopped (stays stopped after a reboot until you use 'Vyomanaut Restart')" }
    'start'    { Start-Provider; Write-Ok 'started' }
    'restart'  {
        if (Test-BundleExpired $cfg) { Stop-WithError 'This event has ended, so the provider will not start again. Use Vyomanaut Uninstall.' }
        Write-Info 'restarting (this also re-syncs the clock and the ZeroTier address)...'
        Stop-Provider; Start-Provider; Start-Sleep -Seconds 8; Show-Status
    }
    'inspect'  {
        Write-Info 'Stopping the provider briefly to look at what it stores...'
        Stop-Provider
        & $script:ProviderExe inspect "--data-dir=$($script:DataDir)"
        Start-Provider
    }
    'uninstall' { & (Join-Path $script:InstallDir 'uninstall.ps1') }
    default    { Write-Host 'usage: vyomanaut.ps1 status | earnings | logs | restart | stop | start | inspect | uninstall' }
}

if ($Pause) { Write-Host ''; Read-Host 'Press Enter to close' | Out-Null }
