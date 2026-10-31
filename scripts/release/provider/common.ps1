# common.ps1 - shared paths and helpers for the Vyomanaut provider scripts.
# Windows PowerShell 5.1 compatible. ASCII only (PS 5.1 misreads UTF-8 without BOM).

$script:InstallDir = Join-Path $env:ProgramFiles 'Vyomanaut'
$script:DataRoot   = Join-Path $env:ProgramData 'Vyomanaut'
$script:DataDir    = Join-Path $script:DataRoot 'data'
$script:LogDir     = Join-Path $script:DataRoot 'logs'
$script:LogFile    = Join-Path $script:LogDir 'provider.log'
$script:StopFlag   = Join-Path $script:DataRoot 'STOP'
$script:StateFile  = Join-Path $script:DataRoot 'installed.json'
$script:ProviderExe = Join-Path $script:InstallDir 'provider.exe'
$script:TaskName   = 'Vyomanaut Provider'
$script:FwRuleName = 'Vyomanaut Provider (TCP-In)'
$script:MenuDir    = Join-Path $env:ProgramData 'Microsoft\Windows\Start Menu\Programs\Vyomanaut'

function Write-Step([string]$n, [string]$msg) { Write-Host ''; Write-Host "[$n] $msg" -ForegroundColor Cyan }
function Write-Ok([string]$msg)   { Write-Host "    OK  $msg" -ForegroundColor Green }
function Write-Info([string]$msg) { Write-Host "    $msg" }
function Write-Warn([string]$msg) { Write-Host "    WARNING: $msg" -ForegroundColor Yellow }
function Stop-WithError([string]$msg) {
    Write-Host ''
    Write-Host "ERROR: $msg" -ForegroundColor Red
    exit 1
}

function Test-IsAdmin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    return (New-Object Security.Principal.WindowsPrincipal($id)).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Read-JsonFile([string]$path) {
    if (-not (Test-Path $path)) { return $null }
    return (Get-Content -Raw -Path $path | ConvertFrom-Json)
}

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

# Returns @{ Status = 'OK' | 'REQUESTING_CONFIGURATION' | ...; Ip = '10.x.x.x' or $null }
function Get-ZeroTierNetwork([string]$cli, [string]$networkId) {
    $result = @{ Status = 'NOT_JOINED'; Ip = $null }
    $nets = Invoke-ZeroTierJson $cli @('listnetworks')
    if ($null -eq $nets) { return $result }
    foreach ($n in @($nets)) {
        if ($n.nwid -eq $networkId) {
            $result.Status = [string]$n.status
            foreach ($a in @($n.assignedAddresses)) {
                $ip = ([string]$a).Split('/')[0]
                if ($ip -match '^\d{1,3}(\.\d{1,3}){3}$') { $result.Ip = $ip; break }
            }
        }
    }
    return $result
}

# Returns the coordinator's unix time, or $null if unreachable.
function Get-CoordinatorEpoch([string]$url) {
    try {
        $r = Invoke-RestMethod -Uri "$url/api/v1/time" -TimeoutSec 8 -UseBasicParsing
        if ($r.unix_epoch) { return [int64]$r.unix_epoch }
    } catch { }
    return $null
}

function Get-NowEpoch { return [int64]([DateTimeOffset]::UtcNow.ToUnixTimeSeconds()) }

# Starts / stops the background provider.
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
