# scripts/demo/demo_env.ps1 - shared by the operator-side PowerShell 7 helpers
# (metrics.ps1, otp_feed.ps1, scripts/release/*.ps1). Dot-source it.
#
# up.ps1 writes $STATE_DIR\env.ps1 ($env:KEY = "value" lines) and up.sh writes
# $STATE_DIR/env (KEY=VALUE lines). Both are PARSED here, never executed, so a helper
# can read the running demo's values on either platform without trusting the file as code.

function Get-DemoStateDir {
    if ($env:VYOMANAUT_DEMO_STATE_DIR) { return $env:VYOMANAUT_DEMO_STATE_DIR }
    if ($IsWindows -or $env:OS -eq 'Windows_NT') { return (Join-Path $env:TEMP 'vyomanaut-demo') }
    return '/tmp/vyomanaut-demo'
}

# Returns a hashtable of the current demo run's values (MICROSERVICE_URL, ADMIN_API_KEY,
# OTP_LOG, BIN_DIR, PGHOST, ...), or an empty hashtable when no demo has been started.
function Read-DemoEnv([string]$stateDir = (Get-DemoStateDir)) {
    $vals = @{}
    foreach ($name in @('env.ps1', 'env')) {
        $f = Join-Path $stateDir $name
        if (-not (Test-Path $f)) { continue }
        foreach ($line in Get-Content -Path $f) {
            if ($line -match '^\s*\$env:([A-Z_][A-Z0-9_]*)\s*=\s*"(.*)"\s*$') { $vals[$Matches[1]] = $Matches[2] }
            elseif ($line -match '^\s*([A-Z_][A-Z0-9_]*)=(.*)$') { $vals[$Matches[1]] = $Matches[2].Trim().Trim('"') }
        }
        if ($vals.Count -gt 0) { break }
    }
    return $vals
}

# The ZeroTier networks this machine has joined: @{ Nwid; Status; Ip; Name }[].
# zerotier-cli needs admin rights on Windows and sudo on macOS/Linux; returns @() when it
# cannot be asked.
function Get-LocalZeroTierNetworks {
    $cli = $null
    foreach ($c in @(
            (Join-Path ${env:ProgramFiles(x86)} 'ZeroTier\One\zerotier-cli.bat'),
            (Join-Path "$env:ProgramFiles" 'ZeroTier\One\zerotier-cli.bat'),
            '/usr/local/bin/zerotier-cli', '/usr/sbin/zerotier-cli', '/usr/bin/zerotier-cli')) {
        if ($c -and (Test-Path $c)) { $cli = $c; break }
    }
    if (-not $cli) { return @() }
    try {
        $raw = & $cli -j listnetworks 2>$null | Out-String
        $nets = $raw | ConvertFrom-Json
    } catch { return @() }
    $out = @()
    foreach ($n in @($nets)) {
        $ip = $null
        foreach ($a in @($n.assignedAddresses)) { $h = ([string]$a).Split('/')[0]; if ($h -match '^\d+\.\d+\.\d+\.\d+$') { $ip = $h; break } }
        $out += @{ Nwid = [string]$n.nwid; Status = [string]$n.status; Ip = $ip; Name = [string]$n.name }
    }
    return $out
}
