# install.ps1 - Vyomanaut provider installer for Windows (launched by Install.cmd).
# Windows PowerShell 5.1 compatible. ASCII only.
#
# Assumes the PC is (or is about to be) connected to the event's ZeroTier network.
#   1. checks this PC and verifies the bundle (SHA256SUMS)
#   2. finds the ZeroTier connection and this PC's address on it
#   3. reaches the coordinator and fixes the clock
#   4. asks the only two questions (GB to share, mobile number) up front
#   5. installs to C:\Program Files\Vyomanaut, data in C:\ProgramData\Vyomanaut (admins only),
#      and opens the provider port to the ZeroTier network only and the metrics port to the
#      operator only
#   6. registers with a 6-digit code read out by the operator
#   7. starts a background task (survives reboots, stops itself when the event ends) and
#      checks the network can see this PC
#
# Running it again upgrades in place and keeps the registration. If the coordinator was
# reset for a new session, the old registration is detected and replaced automatically.
#
# Optional, for scripted lab installs (from an elevated PowerShell):
#   .\install.ps1 -StorageGB 20 -Phone 9876543210
param(
    [int]$StorageGB = 0,
    [string]$Phone = ''
)

$ErrorActionPreference = 'Stop'
$Here = $PSScriptRoot
. (Join-Path $Here 'common.ps1')

$script:TranscriptPath = Join-Path $env:TEMP ('vyomanaut-install-{0}.log' -f (Get-Date -Format 'yyyyMMdd-HHmmss'))
try { Start-Transcript -Path $script:TranscriptPath -Force | Out-Null } catch { $script:TranscriptPath = $null }

Write-Host ''
Write-Host '  ==========================================================' -ForegroundColor White
Write-Host '   Vyomanaut provider setup' -ForegroundColor White
Write-Host '  ==========================================================' -ForegroundColor White
Write-Host '   Your PC will store encrypted fragments of other people''s'
Write-Host '   files. It never sees file names or readable data, and it'
Write-Host '   only uses the disk space you choose.'
Write-Host ''
Write-Host '   Takes about 2 minutes. You will need:'
Write-Host '     - this PC connected to the event ZeroTier network'
Write-Host '     - your mobile number'
Write-Host '     - a 6-digit code the operator reads out to you'

# ---------------------------------------------------------------- 1. preflight
Write-Step '1/7' 'Checking this PC and the setup files'
if (-not (Test-IsAdmin)) { Stop-WithError 'Run Install.cmd as administrator (right-click > Run as administrator).' }
if (-not [Environment]::Is64BitOperatingSystem) { Stop-WithError 'A 64-bit Windows is required.' }
$cfg = Read-JsonFile (Join-Path $Here 'config.json')
if ($null -eq $cfg) { Stop-WithError 'config.json is missing next to install.ps1. Extract the WHOLE zip first, then run Install.cmd from the extracted folder.' }
if (-not (Test-Path (Join-Path $Here 'provider.exe'))) {
    Stop-WithError 'provider.exe is missing. Extract the whole zip again. If it disappears after extracting, your antivirus removed it - allow it or add an exclusion for this folder.'
}

# Files copied from a browser download carry a "came from the internet" mark; clear it so
# the background task can run them without prompts.
Get-ChildItem -Path $Here -File | Unblock-File -ErrorAction SilentlyContinue

# Verify every file against the manifest written by the operator's build.
$sums = Join-Path $Here 'SHA256SUMS'
if (Test-Path $sums) {
    $checked = 0
    foreach ($line in (Get-Content -Path $sums)) {
        if ($line -notmatch '^([0-9a-fA-F]{64}) [ *](.+)$') { continue }
        $expect = $Matches[1].ToLower(); $name = $Matches[2].Trim()
        $f = Join-Path $Here $name
        if (-not (Test-Path $f)) { Stop-WithError "$name is missing from this folder. Extract the whole zip again." }
        if ((Get-FileHash -Algorithm SHA256 -Path $f).Hash.ToLower() -ne $expect) {
            Stop-WithError "$name does not match the operator's build (damaged or modified). Get a fresh copy of the zip from the operator."
        }
        $checked++
    }
    $fp = (Get-FileHash -Algorithm SHA256 -Path $sums).Hash.Substring(0, 8)
    Write-Ok ("bundle verified ({0} files), fingerprint {1}-{2}" -f $checked, $fp.Substring(0, 4), $fp.Substring(4, 4))
} else {
    Write-Warn 'this bundle has no SHA256SUMS file, so it cannot be verified'
}
$Url  = [string]$cfg.microservice_url
$Nwid = ([string]$cfg.zerotier_network_id).ToLower()
$Port = [int]$cfg.listen_port
$MetricsPort = 0
if ($null -ne $cfg.metrics_port) { $MetricsPort = [int]$cfg.metrics_port }
$MetricsFrom = Get-MetricsAllowList $cfg
Write-Ok "bundle $($cfg.version)"
if (Test-BundleExpired $cfg) {
    Stop-WithError ("This bundle was for an event that ended on {0}. Ask the operator for the current one." -f (Format-Epoch ([int64]$cfg.expires_unix)))
}

$others = Get-OtherProviderProcesses
if ($others.Count -gt 0) {
    Write-Warn 'another Vyomanaut provider is already running on this PC (probably an old join.ps1 window):'
    foreach ($p in $others) { Write-Info "  PID $($p.Id)  $($p.Path)" }
    $a = Read-Host '    Stop it so this installation can use the port? [Y/n]'
    if ($a -match '^[Nn]') { Stop-WithError 'Close the other provider window first, then run Install.cmd again.' }
    $others | Stop-Process -Force -ErrorAction SilentlyContinue
    Write-Ok 'stopped'
}

# ---------------------------------------------------------------- 2. ZeroTier
Write-Step '2/7' 'ZeroTier connection'
$cli = Get-ZeroTierCli
if (-not $cli) {
    $msi = Join-Path $Here 'ZeroTierOne.msi'
    if (Test-Path $msi) {
        Write-Info 'ZeroTier is not installed - installing the copy in this bundle (allow any network prompt)...'
        $p = Start-Process -FilePath 'msiexec.exe' -ArgumentList @('/i', "`"$msi`"", '/qn', '/norestart') -Wait -PassThru
        if ($p.ExitCode -ne 0 -and $p.ExitCode -ne 3010) { Stop-WithError "ZeroTier install failed (msiexec exit $($p.ExitCode))." }
        for ($i = 0; $i -lt 30 -and -not $cli; $i++) { Start-Sleep -Seconds 2; $cli = Get-ZeroTierCli }
    }
    if (-not $cli) {
        Write-Box @(
            'ZeroTier is not installed on this PC.',
            '',
            '1. Install it from  https://www.zerotier.com/download/',
            "2. Join network     $Nwid",
            '3. Ask the operator to approve this PC',
            '4. Run Install.cmd again'
        )
        try { Start-Process 'https://www.zerotier.com/download/' } catch { }
        Stop-WithError 'ZeroTier is needed first (see the box above).'
    }
}
$svc = Get-Service -Name 'ZeroTierOneService' -ErrorAction SilentlyContinue
if ($svc -and $svc.Status -ne 'Running') {
    Write-Info 'starting the ZeroTier service...'
    Start-Service -Name 'ZeroTierOneService'
    Start-Sleep -Seconds 3
}
$info = $null
for ($i = 0; $i -lt 15 -and $null -eq $info; $i++) { $info = Invoke-ZeroTierJson $cli @('info'); if ($null -eq $info) { Start-Sleep -Seconds 2 } }
if ($null -eq $info) { Stop-WithError 'The ZeroTier service is not answering. Open Services, restart "ZeroTier One", then run Install.cmd again.' }
$ztAddress = [string]$info.address

$net = Get-ZeroTierNetwork $cli $Nwid
if ($net.Status -eq 'OK' -and $net.Ip) {
    Write-Ok "connected to the event network, this PC is $($net.Ip)"
} else {
    if ($net.Status -eq 'NOT_JOINED') {
        Write-Info "this PC has not joined network $Nwid yet - joining now"
        & $cli join $Nwid | Out-Null
        Start-Sleep -Seconds 3
        $net = Get-ZeroTierNetwork $cli $Nwid
    }
    if (-not ($net.Status -eq 'OK' -and $net.Ip)) {
        Write-Box @(
            'Ask the operator to approve this PC in ZeroTier.',
            '',
            "ZeroTier address:  $ztAddress",
            "Network:           $Nwid"
        )
        Write-Info 'Waiting for approval - this window continues by itself (Ctrl+C to give up)...'
        $deadline = (Get-Date).AddMinutes(30)
        $last = ''
        while ((Get-Date) -lt $deadline) {
            Start-Sleep -Seconds 5
            $net = Get-ZeroTierNetwork $cli $Nwid
            if ($net.Status -eq 'OK' -and $net.Ip) { break }
            if ($net.Status -ne $last) {
                $hint = ''
                if ($net.Status -eq 'ACCESS_DENIED') { $hint = ' (not approved yet)' }
                if ($net.Status -eq 'REQUESTING_CONFIGURATION') { $hint = ' (contacting ZeroTier)' }
                Write-Info "status: $($net.Status)$hint"
                $last = $net.Status
            }
        }
        if (-not ($net.Status -eq 'OK' -and $net.Ip)) { Stop-WithError 'Not approved within 30 minutes. Run Install.cmd again once the operator has approved this PC.' }
        Write-Ok "approved, this PC is $($net.Ip)"
    }
}
$MyIp = $net.Ip
$Subnet = $net.Subnet
$info = Invoke-ZeroTierJson $cli @('info')
if ($info -and $info.tcpFallbackActive) { Write-Warn 'ZeroTier is using its slow TCP relay (UDP is blocked on this network). It works, just slower.' }
$coordHost = Get-UrlHost $Url
if ($Subnet -and (Test-IPv4 $coordHost) -and (Get-CidrNetwork "$coordHost/$($Subnet.Split('/')[1])") -ne $Subnet) {
    Write-Warn "the coordinator ($coordHost) is not on this ZeroTier network ($Subnet) - is this the right bundle?"
}

# ---------------------------------------------------------------- 3. coordinator + clock
Write-Step '3/7' 'Reaching the coordinator'
$skew = $null
for ($i = 0; $i -lt 12 -and $null -eq $skew; $i++) {
    try { $skew = Sync-ClockToCoordinator $Url 30 } catch { Stop-WithError "Could not set the clock: $($_.Exception.Message)" }
    if ($null -eq $skew) {
        if ($i -eq 0) { Write-Info "no answer from $Url yet, retrying for a minute..." }
        Start-Sleep -Seconds 5
    }
}
if ($null -eq $skew) {
    Stop-WithError "Cannot reach the coordinator at $Url. Check the operator's laptop is on and connected to ZeroTier, then run Install.cmd again."
}
Write-Ok "coordinator answering at $Url"
if ([Math]::Abs($skew) -gt 30) { Write-Ok "clock was $skew s off - corrected" } else { Write-Ok 'clock is in sync' }

# ---------------------------------------------------------------- 4. registration state + questions
Write-Step '4/7' 'Your details'
$state = Read-JsonFile $script:StateFile
$regState = Test-Registration $Url
$needOnboard = $true
switch ($regState) {
    'valid'   { $needOnboard = $false; Write-Ok 'this PC is already registered with this network - keeping it (no new code needed)' }
    'expired' { $needOnboard = $false; Write-Warn 'this PC''s registration is older than 7 days and has expired. It will be kept, but ask the operator - you may need to uninstall and join again with a different number.' }
    'unknown' {
        $needOnboard = $false
        Write-Warn 'could not confirm the existing registration with the coordinator - keeping it'
    }
    'stale'   {
        Write-Info 'This PC was registered with an earlier session of the network, which has since been reset.'
        Write-Info 'Its old data is useless now; it will be set aside and this PC registered again.'
    }
    default   { }
}

if ($needOnboard) {
    $drive = Get-PSDrive -Name ($script:DataRoot.Substring(0, 1))
    $freeGB = [int][Math]::Floor($drive.Free / 1GB)
    $maxGB = $freeGB - 5
    if ($maxGB -lt 10) { Stop-WithError "Only $freeGB GB free on drive $($drive.Name):. At least 15 GB free is needed." }
    $def = [Math]::Min([int]$cfg.default_storage_gb, $maxGB)
    if ($StorageGB -lt 10 -or $StorageGB -gt $maxGB) {
        if ($StorageGB -ne 0) { Write-Warn "-StorageGB $StorageGB is outside 10-$maxGB" }
        while ($true) {
            $ans = Read-Host "    How many GB of disk to share? (10 - $maxGB, press Enter for $def)"
            if (-not $ans) { $StorageGB = $def; break }
            $n = 0
            if ([int]::TryParse($ans.Trim(), [ref]$n) -and $n -ge 10 -and $n -le $maxGB) { $StorageGB = $n; break }
            Write-Warn "type a whole number between 10 and $maxGB"
        }
    }
    while ($true) {
        if (-not $Phone) { $Phone = Read-Host '    Your mobile number (e.g. 9876543210)' }
        $Phone = ($Phone -replace '[\s\-\(\)]', '')
        if ($Phone -match '^[6-9]\d{9}$') { $Phone = '+91' + $Phone }
        if ($Phone -match '^\+[1-9]\d{7,14}$') { break }
        Write-Warn 'that does not look like a mobile number - try again'
        $Phone = ''
    }
    Write-Ok "sharing $StorageGB GB, number ending $(Get-PhoneTail $Phone)"
} else {
    $reg = Read-JsonFile $script:RegFile
    $StorageGB = [int]$reg.declared_storage_gb
    if ($StorageGB -le 0 -and $state) { $StorageGB = [int]$state.storage_gb }
    if ($StorageGB -le 0) { $StorageGB = [int]$cfg.default_storage_gb }
    Write-Ok "sharing $StorageGB GB"
}

# ---------------------------------------------------------------- 5. files + firewall
Write-Step '5/7' 'Installing'
New-Item -ItemType Directory -Force -Path $script:InstallDir, $script:DataRoot | Out-Null
if (Get-ScheduledTask -TaskName $script:TaskName -ErrorAction SilentlyContinue) { Stop-Provider }
if ($needOnboard -and $regState -eq 'stale' -and (Test-Path $script:DataDir)) {
    $old = Join-Path $script:DataRoot 'data.previous'
    Remove-Item -Recurse -Force -Path $old -ErrorAction SilentlyContinue
    Move-Item -Path $script:DataDir -Destination $old
    Write-Ok 'old registration set aside (data.previous - deleted on the next reset or by Uninstall)'
}
New-Item -ItemType Directory -Force -Path $script:DataDir, $script:LogDir | Out-Null
foreach ($f in @('provider.exe', 'config.json', 'common.ps1', 'prestart.ps1', 'vyomanaut.ps1', 'uninstall.ps1', 'Uninstall.cmd', 'README.txt')) {
    $src = Join-Path $Here $f
    if (Test-Path $src) { Copy-Item -Force -Path $src -Destination $script:InstallDir }
}
# Only SYSTEM and Administrators may read the data folder: it holds this PC's identity
# seed and its network token.
& icacls.exe $script:DataRoot /inheritance:r /grant:r '*S-1-5-18:(OI)(CI)F' '*S-1-5-32-544:(OI)(CI)F' /T /C /Q | Out-Null
Write-Ok "program: $($script:InstallDir)"
Write-Ok "data:    $($script:DataRoot) (administrators only)"

Set-ProviderFirewall $Port $Subnet $MetricsPort $MetricsFrom | Out-Null
$fromText = 'any address'
if ($Subnet) { $fromText = "the ZeroTier network ($Subnet) only" }
Write-Ok "firewall: storage port $Port open to $fromText"
if ($MetricsPort -gt 0 -and $MetricsFrom.Count -gt 0) {
    Write-Ok "firewall: metrics port $MetricsPort open to the operator ($($MetricsFrom -join ', ')) only"
} elseif ($MetricsPort -gt 0) {
    Write-Warn 'metrics are on but no operator address is known, so the metrics port stays closed'
}

# ---------------------------------------------------------------- 6. onboarding
Write-Step '6/7' 'Registering with the network'
if (-not $needOnboard) {
    Write-Ok 'already registered - skipped'
} else {
    $tail = Get-PhoneTail $Phone
    Write-Box @(
        "Tell the operator:  'my number ends $tail'",
        'They will read you a 6-digit code. Type it below.'
    ) 'Cyan'
    $ok = $false
    for ($attempt = 1; $attempt -le 3 -and -not $ok; $attempt++) {
        $ErrorActionPreference = 'Continue'
        & $script:ProviderExe onboard "--microservice-url=$Url" "--phone=$Phone" "--storage-gb=$StorageGB" `
            "--data-dir=$($script:DataDir)" "--listen-port=$Port" "--advertise-addr=$MyIp" `
            "--city=$($cfg.city)" "--region=$($cfg.region)"
        $code = $LASTEXITCODE
        $ErrorActionPreference = 'Stop'
        if ($code -eq 0) { $ok = $true }
        elseif ($attempt -lt 3) { Write-Warn "that did not work - trying again with a NEW code for the number ending $tail" }
    }
    if (-not $ok) {
        Stop-WithError 'Registration failed 3 times. Check the number and the code with the operator, then run Install.cmd again.'
    }
    Write-Ok 'registered'
}

# ---------------------------------------------------------------- 7. background task + verify
Write-Step '7/7' 'Starting the background service'
$metricsLine = 'set "METRICS="'
if ($MetricsPort -gt 0) { $metricsLine = "if not `"%IP%`"==`"`" (set `"METRICS=--metrics-addr=%IP%:$MetricsPort`") else (set `"METRICS=`")" }
$runnerLines = @(
    '@echo off',
    'rem Generated by install.ps1. Restarts the provider if it ever stops.',
    'rem Create C:\ProgramData\Vyomanaut\STOP to end the loop (Vyomanaut Stop does this).',
    'setlocal',
    "set `"LOG=$($script:LogFile)`"",
    ':loop',
    "if exist `"$($script:StopFlag)`" exit /b 0",
    'if exist "%LOG%" for %%A in ("%LOG%") do if %%~zA GTR 20971520 move /y "%LOG%" "%LOG%.old" >nul',
    "set `"IP=$MyIp`"",
    "for /f `"usebackq delims=`" %%i in (``powershell -NoProfile -ExecutionPolicy Bypass -File `"$($script:InstallDir)\prestart.ps1`" 2^>^>`"%LOG%`"``) do set `"IP=%%i`"",
    "if exist `"$($script:StopFlag)`" exit /b 0",
    $metricsLine,
    'echo [%date% %time%] starting provider, advertising %IP% >> "%LOG%"',
    "`"$($script:ProviderExe)`" run --mode=demo --microservice-url=$Url --data-dir=`"$($script:DataDir)`" --declared-storage-gb=$StorageGB --listen-port=$Port --advertise-addr=%IP% %METRICS% >> `"%LOG%`" 2>&1",
    'echo [%date% %time%] provider exited with code %errorlevel%, restarting in 15s >> "%LOG%"',
    'ping -n 16 127.0.0.1 >nul',
    'goto loop'
)
Set-Content -Path $script:RunnerFile -Value $runnerLines -Encoding ASCII

$action    = New-ScheduledTaskAction -Execute 'cmd.exe' -Argument "/c `"`"$($script:RunnerFile)`"`""
$trigger   = New-ScheduledTaskTrigger -AtStartup
$principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
$settings  = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable `
    -ExecutionTimeLimit ([TimeSpan]::Zero) -RestartCount 999 -RestartInterval (New-TimeSpan -Minutes 1) -MultipleInstances IgnoreNew
Register-ScheduledTask -TaskName $script:TaskName -Action $action -Trigger $trigger -Principal $principal `
    -Settings $settings -Description 'Vyomanaut storage provider (runs in the background, starts at boot, stops when the event ends)' -Force | Out-Null
Write-Ok 'starts at boot, restarts itself if it stops'

$powerRestore = Disable-SleepOnAc $state
Write-Ok 'sleep turned off while plugged in (Uninstall puts your old setting back)'

# Start-menu and desktop shortcuts
New-Item -ItemType Directory -Force -Path $script:MenuDir | Out-Null
$shell = New-Object -ComObject WScript.Shell
$tool = Join-Path $script:InstallDir 'vyomanaut.ps1'
$psExe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$links = @(
    @{ Name = 'Vyomanaut Status';    Cmd = 'status' },
    @{ Name = 'Vyomanaut Earnings';  Cmd = 'earnings' },
    @{ Name = 'Vyomanaut Logs';      Cmd = 'logs' },
    @{ Name = 'Vyomanaut Restart';   Cmd = 'restart' },
    @{ Name = 'Vyomanaut Stop';      Cmd = 'stop' },
    @{ Name = 'Vyomanaut Uninstall'; Cmd = 'uninstall' }
)
foreach ($l in $links) {
    $s = $shell.CreateShortcut((Join-Path $script:MenuDir "$($l.Name).lnk"))
    $s.TargetPath = $psExe
    $s.Arguments = "-NoProfile -ExecutionPolicy Bypass -File `"$tool`" $($l.Cmd) -Pause"
    $s.WorkingDirectory = $script:InstallDir
    $s.Save()
}
$desk = $shell.CreateShortcut((Join-Path ([Environment]::GetFolderPath('CommonDesktopDirectory')) 'Vyomanaut Status.lnk'))
$desk.TargetPath = $psExe
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
    subnet           = $Subnet
    listen_port      = $Port
    metrics_port     = $MetricsPort
    storage_gb       = $StorageGB
    expires_unix     = $cfg.expires_unix
    power_restore    = $powerRestore
} | ConvertTo-Json | Set-Content -Path $script:StateFile -Encoding ASCII

Start-Provider
$running = $false
for ($i = 0; $i -lt 30 -and -not $running; $i++) { Start-Sleep -Seconds 2; $running = Test-ProviderRunning }
if (-not $running) {
    Write-Warn "the provider has not started yet - open 'Vyomanaut Logs' from the Start menu, or check $($script:LogFile)"
} else {
    Write-Ok 'provider running'
    # End-to-end check: the coordinator has received this PC's first heartbeat.
    Write-Info 'waiting for the network to see this PC (up to a minute)...'
    $seen = $null
    for ($i = 0; $i -lt 20 -and $null -eq $seen; $i++) {
        Start-Sleep -Seconds 3
        $st = Get-ProviderNetworkStatus $Url
        if ($st -and $st.last_heartbeat_ts) { $seen = $st }
    }
    if ($seen) { Write-Ok "the network sees this PC: $($seen.status)" }
    else { Write-Warn 'no check-in seen yet. It may just be slow - open Vyomanaut Status in a few minutes.' }
    if ($MetricsPort -gt 0) {
        $m = Get-LocalMetrics $MyIp $MetricsPort
        if ($null -ne $m) { Write-Ok "metrics served on ${MyIp}:$MetricsPort for the operator's dashboard" }
    }
}

try { Stop-Transcript | Out-Null } catch { }
if ($script:TranscriptPath -and (Test-Path $script:TranscriptPath)) {
    Move-Item -Force -Path $script:TranscriptPath -Destination $script:InstallLog -ErrorAction SilentlyContinue
}

$endText = ''
if ($cfg.expires_unix) { $endText = Format-Epoch ([int64]$cfg.expires_unix) }
$summary = @(
    'Setup complete.',
    '',
    "This PC:      $MyIp  (ZeroTier $ztAddress)",
    "Sharing:      $StorageGB GB",
    '',
    'Becomes ACTIVE in about 10-30 minutes. Until then it is on probation.',
    'Keep it switched on, plugged in and with the lid OPEN (a closed lid sleeps).',
    'It keeps running after you close this window and restarts after a reboot.',
    "Check on it any time: 'Vyomanaut Status' on the desktop."
)
if ($endText) { $summary += "Stops by itself on $endText. Uninstall from the Start menu any time." }
Write-Box $summary 'Green'
