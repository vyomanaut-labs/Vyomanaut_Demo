# uninstall.ps1 - removes the Vyomanaut provider from this PC and puts back what setup changed.
# Tells the network first (provider depart) so repair starts straight away instead of
# waiting for the departure timeout. Windows PowerShell 5.1 compatible. ASCII only.
param([switch]$Yes)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'common.ps1')
if (-not (Test-IsAdmin)) { Stop-WithError 'Run Uninstall.cmd as administrator.' }

$cfg = Read-JsonFile (Join-Path $script:InstallDir 'config.json')
if ($null -eq $cfg) { $cfg = Read-JsonFile (Join-Path $PSScriptRoot 'config.json') }
$state = Read-JsonFile $script:StateFile

Write-Host ''
Write-Host '  This removes the Vyomanaut provider from this PC.' -ForegroundColor White
Write-Host '  The fragments stored here will be rebuilt elsewhere by the network.'
if (-not $Yes) {
    $ans = Read-Host '  Type YES to continue'
    if ($ans -ne 'YES') { Write-Host '  Cancelled.'; exit 0 }
}

Write-Step '1/6' 'Stopping the provider'
if (Test-Path $script:DataRoot) { Stop-Provider } else { Get-Process -Name 'provider' -ErrorAction SilentlyContinue | Where-Object { $_.Path -eq $script:ProviderExe } | Stop-Process -Force -ErrorAction SilentlyContinue }
Write-Ok 'stopped'

Write-Step '2/6' 'Telling the network this PC is leaving'
$departed = $false
if (-not (Test-Path $script:RegFile)) {
    Write-Info 'this PC never finished registering - nothing to tell the network'
    $departed = $true
} elseif ((Test-Path $script:ProviderExe) -and $cfg) {
    $reg = Test-Registration ([string]$cfg.microservice_url)
    if ($reg -eq 'stale') {
        Write-Info 'the network this PC joined has already been reset - nothing to tell it'
        $departed = $true
    } else {
        $ErrorActionPreference = 'Continue'
        & $script:ProviderExe depart "--microservice-url=$($cfg.microservice_url)" "--data-dir=$($script:DataDir)"
        $departed = ($LASTEXITCODE -eq 0)
        $ErrorActionPreference = 'Stop'
    }
}
if ($departed) { Write-Ok 'done' } else { Write-Warn 'could not reach the coordinator - the network will notice on its own after its timeout' }

Write-Step '3/6' 'Removing the background task, firewall rules and shortcuts'
Unregister-ScheduledTask -TaskName $script:TaskName -Confirm:$false -ErrorAction SilentlyContinue
Remove-ProviderFirewall
Remove-Item -Recurse -Force -Path $script:MenuDir -ErrorAction SilentlyContinue
Remove-Item -Force -Path (Join-Path ([Environment]::GetFolderPath('CommonDesktopDirectory')) 'Vyomanaut Status.lnk') -ErrorAction SilentlyContinue
Write-Ok 'removed'

Write-Step '4/6' 'Sleep settings'
if ($state -and (Restore-SleepOnAc $state.power_restore)) { Write-Ok 'your previous sleep settings are back' }
else { Write-Info 'previous sleep settings unknown - set them again in Settings > System > Power if you want' }

Write-Step '5/6' 'ZeroTier'
$cli = Get-ZeroTierCli
if ($cli -and $cfg) {
    $leave = $true
    if (-not $Yes) {
        $a = Read-Host '    Leave the event ZeroTier network? [Y/n]'
        $leave = ($a -notmatch '^[Nn]')
    }
    if ($leave) { & $cli leave ([string]$cfg.zerotier_network_id).ToLower() | Out-Null; Write-Ok 'left the network' }
    Write-Info 'ZeroTier itself stays installed (remove it from Settings > Apps if you want).'
} else {
    Write-Info 'nothing to do'
}

Write-Step '6/6' 'Deleting files'
$deleteData = $departed
if (-not $departed -and -not $Yes) {
    $a = Read-Host '    Delete the stored data anyway? Keeping it lets you rejoin as the same provider. [y/N]'
    $deleteData = ($a -match '^[Yy]')
}
if ($deleteData) { Remove-Item -Recurse -Force -Path $script:DataRoot -ErrorAction SilentlyContinue; Write-Ok "deleted $($script:DataRoot)" }
else {
    Remove-Item -Force -Path $script:StateFile, $script:StopFlag -ErrorAction SilentlyContinue
    Remove-Item -Recurse -Force -Path (Join-Path $script:DataRoot 'data.previous') -ErrorAction SilentlyContinue
    Write-Info "kept $($script:DataRoot)"
}
# This script may be running from the install folder, so delete it a few seconds after exit.
Start-Process -FilePath 'cmd.exe' -WindowStyle Hidden -ArgumentList "/c ping -n 4 127.0.0.1 >nul & rmdir /s /q `"$($script:InstallDir)`""
Write-Ok "removing $($script:InstallDir)"
Write-Host ''
Write-Host '  Vyomanaut has been removed. Thank you for sharing your disk!' -ForegroundColor Green
