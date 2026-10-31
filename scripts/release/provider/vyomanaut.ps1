# vyomanaut.ps1 - everyday commands for an installed Vyomanaut provider.
#   vyomanaut.ps1 status | earnings | logs | restart | stop | start | inspect | uninstall
# The Start-menu shortcuts call this. Windows PowerShell 5.1 compatible. ASCII only.
param(
    [Parameter(Position = 0)] [string]$Command = 'status',
    [switch]$Pause
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'common.ps1')

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

function Show-Status {
    Write-Host ''
    Write-Host '  Vyomanaut provider status' -ForegroundColor White
    $t = Get-ScheduledTask -TaskName $script:TaskName -ErrorAction SilentlyContinue
    $taskState = 'missing'
    if ($t) { $taskState = [string]$t.State }
    if (Test-ProviderRunning) { Write-Ok "provider running (task: $taskState)" } else { Write-Warn "provider NOT running (task: $taskState) - try 'Vyomanaut Restart'" }
    if (Test-Path $script:StopFlag) { Write-Warn 'stopped on purpose (STOP flag present) - use restart to resume' }

    $cli = Get-ZeroTierCli
    if ($cli) {
        $info = Invoke-ZeroTierJson $cli @('info')
        $net = Get-ZeroTierNetwork $cli $cfg.zerotier_network_id
        $online = $false; $zt = '?'
        if ($info) { $online = [bool]$info.online; $zt = [string]$info.address }
        if ($online -and $net.Status -eq 'OK') { Write-Ok "ZeroTier $zt connected, IP $($net.Ip)" } else { Write-Warn "ZeroTier $zt network status: $($net.Status)" }
        if ($state -and $net.Ip -and $state.ip -ne $net.Ip) { Write-Info "(IP changed since install: was $($state.ip); the provider picks up the new one on restart)" }
    } else { Write-Warn 'ZeroTier is not installed' }

    $server = Get-CoordinatorEpoch $Url
    if ($null -ne $server) {
        $skew = (Get-NowEpoch) - $server
        Write-Ok "coordinator reachable ($Url), clock offset $skew s"
        if ([Math]::Abs($skew) -gt 120) { Write-Warn 'clock offset over 2 minutes - restart the provider to resync it' }
    } else { Write-Warn "coordinator NOT reachable at $Url" }

    if ($state) { Write-Info "sharing $($state.storage_gb) GB, bundle $($state.version)" }
    Write-Host ''
    Write-Host '  Last log lines:' -ForegroundColor White
    if (Test-Path $script:LogFile) { Get-Content -Path $script:LogFile -Tail 15 | ForEach-Object { Write-Host "    $_" } } else { Write-Info '(no log yet)' }
}

switch ($Command.ToLower()) {
    'status'   { Show-Status }
    'earnings' { & $script:ProviderExe earnings "--microservice-url=$Url" "--data-dir=$($script:DataDir)" }
    'logs'     { if (Test-Path $script:LogFile) { Start-Process notepad.exe -ArgumentList "`"$($script:LogFile)`"" } else { Write-Info 'no log yet' } }
    'stop'     { Stop-Provider; Write-Ok 'stopped (stays stopped after reboot until you run restart)' }
    'start'    { Start-Provider; Write-Ok 'started' }
    'restart'  { Stop-Provider; Start-Provider; Start-Sleep -Seconds 5; Show-Status }
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
