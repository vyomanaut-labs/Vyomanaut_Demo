# install.ps1 - Vyomanaut provider installer for Windows (launched by Install.cmd).
# Windows PowerShell 5.1 compatible. ASCII only.
#
# What it does:
#   1. installs ZeroTier and joins the demo network, then waits for the operator to approve this PC
#   2. checks the coordinator is reachable and fixes the clock
#   3. installs provider.exe to C:\Program Files\Vyomanaut (data in C:\ProgramData\Vyomanaut)
#   4. opens the provider port in Windows Firewall
#   5. onboards: storage size, phone number, 6-digit code from the operator
#   6. registers a startup task so the provider runs in the background and survives reboots
#
# Running it again on an installed PC upgrades provider.exe and keeps the registration.

$ErrorActionPreference = 'Stop'
$Here = $PSScriptRoot
. (Join-Path $Here 'common.ps1')

Write-Host ''
Write-Host '  Vyomanaut provider setup' -ForegroundColor White
Write-Host '  Your PC will store encrypted fragments of other people''s files.'
Write-Host '  It never sees file names or readable data.'

# ---------------------------------------------------------------- preflight
Write-Step '1/8' 'Checking this PC'
if (-not (Test-IsAdmin)) { Stop-WithError 'Run Install.cmd as administrator (right-click > Run as administrator).' }
if (-not [Environment]::Is64BitOperatingSystem) { Stop-WithError 'A 64-bit Windows is required.' }
$cfg = Read-JsonFile (Join-Path $Here 'config.json')
if ($null -eq $cfg) { Stop-WithError 'config.json is missing next to install.ps1. Re-extract the whole zip.' }
if (-not (Test-Path (Join-Path $Here 'provider.exe'))) { Stop-WithError 'provider.exe is missing. Re-extract the whole zip (some antivirus tools quarantine it - check yours).' }
$Url  = [string]$cfg.microservice_url
$Nwid = [string]$cfg.zerotier_network_id
$Port = [int]$cfg.listen_port
$existingReg = Test-Path (Join-Path $script:DataDir 'registration.json')
Write-Ok "bundle version $($cfg.version)"
if ($existingReg) { Write-Info 'This PC is already registered - upgrading in place, no new code needed.' }

# ---------------------------------------------------------------- ZeroTier
Write-Step '2/8' 'ZeroTier private network'
$cli = Get-ZeroTierCli
if (-not $cli) {
    $msi = Join-Path $Here 'ZeroTierOne.msi'
    if (Test-Path $msi) {
        Write-Info 'Installing ZeroTier (allow any network/driver prompt)...'
        $p = Start-Process -FilePath 'msiexec.exe' -ArgumentList @('/i', "`"$msi`"", '/qn', '/norestart') -Wait -PassThru
        if ($p.ExitCode -ne 0 -and $p.ExitCode -ne 3010) { Stop-WithError "ZeroTier install failed (msiexec exit $($p.ExitCode))." }
    } elseif (Get-Command winget -ErrorAction SilentlyContinue) {
        Write-Info 'Installing ZeroTier with winget...'
        & winget install --id ZeroTier.ZeroTierOne -e --silent --accept-package-agreements --accept-source-agreements | Out-Host
    } else {
        Stop-WithError 'ZeroTier is not installed and no installer is available. Install it from zerotier.com, then run Install.cmd again.'
    }
    for ($i = 0; $i -lt 30 -and -not $cli; $i++) { Start-Sleep -Seconds 2; $cli = Get-ZeroTierCli }
    if (-not $cli) { Stop-WithError 'ZeroTier installed but zerotier-cli was not found. Reboot and run Install.cmd again.' }
}
$svc = Get-Service -Name 'ZeroTierOneService' -ErrorAction SilentlyContinue
if ($svc -and $svc.Status -ne 'Running') { Start-Service -Name 'ZeroTierOneService'; Start-Sleep -Seconds 3 }

$info = $null
for ($i = 0; $i -lt 15 -and $null -eq $info; $i++) { $info = Invoke-ZeroTierJson $cli @('info'); if ($null -eq $info) { Start-Sleep -Seconds 2 } }
if ($null -eq $info) { Stop-WithError 'The ZeroTier service is not answering. Run: Restart-Service ZeroTierOneService, then Install.cmd again.' }
$ztAddress = [string]$info.address
Write-Ok "ZeroTier running, this PC's ZeroTier address is $ztAddress"

$net = Get-ZeroTierNetwork $cli $Nwid
if ($net.Status -eq 'NOT_JOINED') { & $cli join $Nwid | Out-Null; Start-Sleep -Seconds 3; $net = Get-ZeroTierNetwork $cli $Nwid }
if (-not ($net.Status -eq 'OK' -and $net.Ip)) {
    Write-Host ''
    Write-Host '    +-----------------------------------------------------------+' -ForegroundColor Yellow
    Write-Host "    |  Tell the operator to approve ZeroTier address: $ztAddress  |" -ForegroundColor Yellow
    Write-Host '    +-----------------------------------------------------------+' -ForegroundColor Yellow
    Write-Info 'Waiting for approval (this window will continue by itself)...'
    $deadline = (Get-Date).AddMinutes(30)
    $last = ''
    while ((Get-Date) -lt $deadline) {
        Start-Sleep -Seconds 5
        $net = Get-ZeroTierNetwork $cli $Nwid
        if ($net.Status -eq 'OK' -and $net.Ip) { break }
        if ($net.Status -ne $last) { Write-Info "status: $($net.Status)"; $last = $net.Status }
    }
    if (-not ($net.Status -eq 'OK' -and $net.Ip)) { Stop-WithError 'Not approved within 30 minutes. Run Install.cmd again once the operator has approved this PC.' }
}
$MyIp = $net.Ip
Write-Ok "joined the network, this PC's address is $MyIp"
$info = Invoke-ZeroTierJson $cli @('info')
if ($info -and $info.tcpFallbackActive) { Write-Warn 'ZeroTier is using its slow TCP relay (UDP is blocked here). It works, just slower.' }

# ---------------------------------------------------------------- coordinator + clock
Write-Step '3/8' 'Reaching the coordinator'
$server = $null
for ($i = 0; $i -lt 12 -and $null -eq $server; $i++) {
    $server = Get-CoordinatorEpoch $Url
    if ($null -eq $server) { Start-Sleep -Seconds 5 }
}
if ($null -eq $server) {
    Stop-WithError "Cannot reach the coordinator at $Url. Check the operator's laptop is on and its ZeroTier is connected, then run Install.cmd again."
}
Write-Ok "coordinator reachable at $Url"
$skew = (Get-NowEpoch) - $server
if ([Math]::Abs($skew) -gt 30) {
    Set-Date -Date ([DateTimeOffset]::FromUnixTimeSeconds($server).UtcDateTime.ToLocalTime()) | Out-Null
    Write-Ok "clock was $skew s off - corrected"
} else {
    Write-Ok 'clock is in sync'
}

# ---------------------------------------------------------------- files
Write-Step '4/8' 'Installing files'
if ($existingReg -or (Get-ScheduledTask -TaskName $script:TaskName -ErrorAction SilentlyContinue)) { Stop-Provider }
New-Item -ItemType Directory -Force -Path $script:InstallDir, $script:DataDir, $script:LogDir | Out-Null
foreach ($f in @('provider.exe', 'config.json', 'common.ps1', 'prestart.ps1', 'vyomanaut.ps1', 'uninstall.ps1', 'Uninstall.cmd')) {
    Copy-Item -Force -Path (Join-Path $Here $f) -Destination $script:InstallDir
}
# Only SYSTEM and Administrators may read the data folder: it holds this PC's identity seed.
& icacls.exe $script:DataRoot /inheritance:r /grant:r '*S-1-5-18:(OI)(CI)F' '*S-1-5-32-544:(OI)(CI)F' /T /C /Q | Out-Null
Write-Ok "program: $($script:InstallDir)"
Write-Ok "data:    $($script:DataRoot) (admins only)"

# ---------------------------------------------------------------- firewall
Write-Step '5/8' 'Windows Firewall'
Get-NetFirewallRule -DisplayName $script:FwRuleName -ErrorAction SilentlyContinue | Remove-NetFirewallRule
New-NetFirewallRule -DisplayName $script:FwRuleName -Direction Inbound -Action Allow -Protocol TCP `
    -LocalPort $Port -Program $script:ProviderExe -Profile Any | Out-Null
Write-Ok "inbound TCP $Port allowed for provider.exe"

# ---------------------------------------------------------------- onboarding
Write-Step '6/8' 'Registering with the network'
$state = Read-JsonFile $script:StateFile
if ($existingReg) {
    $reg = Read-JsonFile (Join-Path $script:DataDir 'registration.json')
    $StorageGB = [int]$reg.declared_storage_gb
    if ($StorageGB -le 0 -and $state) { $StorageGB = [int]$state.storage_gb }
    if ($StorageGB -le 0) { $StorageGB = [int]$cfg.default_storage_gb }
    Write-Ok "already registered ($StorageGB GB) - skipping"
} else {
    $drive = Get-PSDrive -Name ($script:DataRoot.Substring(0, 1))
    $freeGB = [int][Math]::Floor($drive.Free / 1GB)
    $maxGB = $freeGB - 5
    if ($maxGB -lt 10) { Stop-WithError "Only $freeGB GB free on drive $($drive.Name):. At least 15 GB free is needed." }
    $def = [Math]::Min([int]$cfg.default_storage_gb, $maxGB)
    while ($true) {
        $ans = Read-Host "    How many GB to share? (10 - $maxGB, Enter = $def)"
        if (-not $ans) { $StorageGB = $def; break }
        $n = 0
        if ([int]::TryParse($ans.Trim(), [ref]$n) -and $n -ge 10 -and $n -le $maxGB) { $StorageGB = $n; break }
        Write-Warn "enter a whole number between 10 and $maxGB"
    }
    while ($true) {
        $raw = Read-Host '    Your mobile number (e.g. 9876543210 or +919876543210)'
        $Phone = ($raw -replace '[\s\-\(\)]', '')
        if ($Phone -match '^[6-9]\d{9}$') { $Phone = '+91' + $Phone }
        if ($Phone -match '^\+\d{8,15}$') { break }
        Write-Warn 'that does not look like a phone number - try again'
    }
    Write-Info ''
    Write-Info "A 6-digit code will be generated for $Phone. Ask the operator to read it to you."
    Write-Info ''
    $ok = $false
    for ($attempt = 1; $attempt -le 3 -and -not $ok; $attempt++) {
        $ErrorActionPreference = 'Continue'
        & $script:ProviderExe onboard "--microservice-url=$Url" "--phone=$Phone" "--storage-gb=$StorageGB" `
            "--data-dir=$($script:DataDir)" "--listen-port=$Port" "--advertise-addr=$MyIp" `
            "--city=$($cfg.city)" "--region=$($cfg.region)"
        $code = $LASTEXITCODE
        $ErrorActionPreference = 'Stop'
        if ($code -eq 0) { $ok = $true } elseif ($attempt -lt 3) { Write-Warn 'registration failed - trying again (a new code will be sent)' }
    }
    if (-not $ok) { Stop-WithError 'Registration failed 3 times. Check the code with the operator and run Install.cmd again.' }
    Write-Ok "registered, sharing $StorageGB GB"
}

# ---------------------------------------------------------------- background task
Write-Step '7/8' 'Setting up the background service'
$runner = Join-Path $script:InstallDir 'run-provider.cmd'
$runnerLines = @(
    '@echo off',
    'rem Generated by install.ps1 - restarts the provider if it ever stops. Create the STOP file to end the loop.',
    'setlocal',
    "set `"LOG=$($script:LogFile)`"",
    ':loop',
    "if exist `"$($script:StopFlag)`" exit /b 0",
    'if exist "%LOG%" for %%A in ("%LOG%") do if %%~zA GTR 20971520 move /y "%LOG%" "%LOG%.old" >nul',
    "set `"IP=$MyIp`"",
    "for /f `"usebackq delims=`" %%i in (``powershell -NoProfile -ExecutionPolicy Bypass -File `"$($script:InstallDir)\prestart.ps1`" 2^>^>`"%LOG%`"``) do set `"IP=%%i`"",
    'echo [%date% %time%] starting provider, advertising %IP% >> "%LOG%"',
    "`"$($script:ProviderExe)`" run --mode=demo --microservice-url=$Url --data-dir=`"$($script:DataDir)`" --declared-storage-gb=$StorageGB --listen-port=$Port --advertise-addr=%IP% >> `"%LOG%`" 2>&1",
    'echo [%date% %time%] provider exited with code %errorlevel%, restarting in 15s >> "%LOG%"',
    'ping -n 16 127.0.0.1 >nul',
    'goto loop'
)
Set-Content -Path $runner -Value $runnerLines -Encoding ASCII

$action    = New-ScheduledTaskAction -Execute 'cmd.exe' -Argument "/c `"`"$runner`"`""
$trigger   = New-ScheduledTaskTrigger -AtStartup
$principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
$settings  = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable `
    -ExecutionTimeLimit ([TimeSpan]::Zero) -RestartCount 999 -RestartInterval (New-TimeSpan -Minutes 1) -MultipleInstances IgnoreNew
Register-ScheduledTask -TaskName $script:TaskName -Action $action -Trigger $trigger -Principal $principal `
    -Settings $settings -Description 'Vyomanaut storage provider (runs in the background, starts at boot)' -Force | Out-Null

# Keep the PC awake while plugged in: a sleeping provider looks DEPARTED after 10 minutes.
& powercfg.exe /change standby-timeout-ac 0 | Out-Null
& powercfg.exe /change hibernate-timeout-ac 0 | Out-Null
Write-Ok 'starts automatically at boot, restarts itself if it stops'
Write-Ok 'sleep disabled while on mains power'

# ---------------------------------------------------------------- shortcuts + state
New-Item -ItemType Directory -Force -Path $script:MenuDir | Out-Null
$shell = New-Object -ComObject WScript.Shell
$tool = Join-Path $script:InstallDir 'vyomanaut.ps1'
$links = @(
    @{ Name = 'Vyomanaut Status';   Cmd = 'status' },
    @{ Name = 'Vyomanaut Earnings'; Cmd = 'earnings' },
    @{ Name = 'Vyomanaut Logs';     Cmd = 'logs' },
    @{ Name = 'Vyomanaut Restart';  Cmd = 'restart' },
    @{ Name = 'Vyomanaut Uninstall'; Cmd = 'uninstall' }
)
foreach ($l in $links) {
    $s = $shell.CreateShortcut((Join-Path $script:MenuDir "$($l.Name).lnk"))
    $s.TargetPath = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $s.Arguments = "-NoProfile -ExecutionPolicy Bypass -File `"$tool`" $($l.Cmd) -Pause"
    $s.WorkingDirectory = $script:InstallDir
    $s.Save()
}
$desk = $shell.CreateShortcut((Join-Path ([Environment]::GetFolderPath('CommonDesktopDirectory')) 'Vyomanaut Status.lnk'))
$desk.TargetPath = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$desk.Arguments = "-NoProfile -ExecutionPolicy Bypass -File `"$tool`" status -Pause"
$desk.WorkingDirectory = $script:InstallDir
$desk.Save()

[ordered]@{
    version          = $cfg.version
    installed_at     = (Get-Date).ToString('s')
    microservice_url = $Url
    zerotier_network = $Nwid
    zerotier_address = $ztAddress
    ip               = $MyIp
    listen_port      = $Port
    storage_gb       = $StorageGB
} | ConvertTo-Json | Set-Content -Path $script:StateFile -Encoding ASCII

# ---------------------------------------------------------------- start + verify
Write-Step '8/8' 'Starting the provider'
Start-Provider
$running = $false
for ($i = 0; $i -lt 30 -and -not $running; $i++) { Start-Sleep -Seconds 2; $running = Test-ProviderRunning }
if ($running) {
    Write-Ok 'provider is running'
} else {
    Write-Warn "provider has not started yet - open 'Vyomanaut Logs' from the Start menu, or check $($script:LogFile)"
}

Write-Host ''
Write-Host '  Setup complete.' -ForegroundColor Green
Write-Host "  This PC:      $MyIp  (ZeroTier $ztAddress)"
Write-Host "  Sharing:      $StorageGB GB"
Write-Host "  Coordinator:  $Url"
Write-Host ''
Write-Host '  The network now vets this PC; it usually becomes ACTIVE in 10-30 minutes.'
Write-Host '  Keep it switched on and connected. It keeps running after you close this window,'
Write-Host '  and starts again by itself after a reboot.'
Write-Host "  Check on it any time with 'Vyomanaut Status' on the desktop."
