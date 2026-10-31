#Requires -Version 7.0
<#
.SYNOPSIS
  Builds the Windows provider bundle: an obfuscated provider.exe plus a
  one-click installer. Run this on the OPERATOR's laptop, never on a provider PC.

.DESCRIPTION
  1. Checks that Go 1.26.2 and git are installed, and installs garble v0.17.0 if needed.
  2. Clones the public repo (github.com/vyomanaut-labs/Vyomanaut_Demo) at -Ref
     into a temp folder. BOTH the code and the installer files
     (scripts/release/provider) are taken from that clone, so the bundle never
     depends on your working copy - push your changes before building.
  3. Builds cmd/provider for windows/amd64 with CGO off (the Windows provider
     uses BadgerDB, so no gcc/MSYS2 is needed) through garble:
       garble -literals -seed=random build -trimpath -ldflags "-s -w"
  4. Writes config.json (coordinator URL, ZeroTier network ID, port, region).
  5. Downloads the ZeroTier MSI so the provider PC needs no internet for it.
  6. Zips everything into dist\VyomanautProvider-<version>.zip and prints its SHA-256.

  The bundle contains NO source code, NO .git folder, and NO secrets. Each
  provider generates its own identity seed on first run.

  The garble seed is written ONLY to dist\build-<version>.log on this machine.
  Keep that file to yourself: anyone holding it can reverse the name obfuscation
  ("garble reverse"), which is also how you decode an obfuscated crash trace.

.EXAMPLE
  ./scripts/release/build_provider_bundle.ps1 -MicroserviceUrl http://10.35.114.52:8080 -NetworkId 0123456789abcdef
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)] [string]$MicroserviceUrl,
    [Parameter(Mandatory = $true)] [string]$NetworkId,
    [string]$Ref = "main",
    [string]$RepoUrl = "https://github.com/vyomanaut-labs/Vyomanaut_Demo.git",
    [int]$ListenPort = 30303,
    [int]$DefaultStorageGB = 10,
    [string]$City = "Pune",
    [ValidateSet("Delhi NCR", "Mumbai", "Bangalore", "Hyderabad", "Chennai", "Kolkata", "Pune", "Ahmedabad", "Other")]
    [string]$Region = "Pune",
    [string]$OutDir = "",
    # Skip garble and do a plain stripped build (faster, for debugging only).
    [switch]$NoObfuscate,
    # Don't bundle the ZeroTier MSI; the installer then falls back to winget.
    [switch]$SkipZeroTier,
    # Take installer files from this checkout instead of the cloned repo (testing unpushed edits).
    [switch]$UseLocalTemplates
)

$ErrorActionPreference = "Stop"
$GoVersionRequired = "go1.26.2"
$GarbleVersion     = "v0.17.0"   # v0.17.x is the last garble line that supports Go 1.26 (v0.18 needs 1.27)
$ZeroTierMsiUrl    = "https://download.zerotier.com/dist/ZeroTier%20One.msi"

function Log($m)  { Write-Host "[build] $m" -ForegroundColor Cyan }
function Fail($m) { Write-Host "[build] ERROR: $m" -ForegroundColor Red; exit 1 }

# ── inputs ────────────────────────────────────────────────────────────────
if ($NetworkId -notmatch '^[0-9a-fA-F]{16}$') { Fail "-NetworkId must be the 16-hex-char ZeroTier network ID" }
if ($MicroserviceUrl -notmatch '^https?://[^/\s]+(:\d+)?/?$') { Fail "-MicroserviceUrl must look like http://10.x.x.x:8080" }
$MicroserviceUrl = $MicroserviceUrl.TrimEnd('/')
if ($DefaultStorageGB -lt 10) { Fail "-DefaultStorageGB must be >= 10 (the coordinator rejects less)" }

$ScriptDir   = $PSScriptRoot
if (-not $OutDir) { $OutDir = Join-Path (Resolve-Path (Join-Path $ScriptDir "..\..")) "dist" }
New-Item -ItemType Directory -Force -Path $OutDir | Out-Null

# ── toolchain ─────────────────────────────────────────────────────────────
foreach ($t in "go", "git") {
    if (-not (Get-Command $t -ErrorAction SilentlyContinue)) { Fail "$t is not on PATH" }
}
$goVer = (& go env GOVERSION).Trim()
if ($goVer -ne $GoVersionRequired) { Fail "need $GoVersionRequired (garble $GarbleVersion is built for it), found $goVer" }

$gopathBin = Join-Path (& go env GOPATH).Trim() "bin"
$garble = Join-Path $gopathBin $(if ($IsWindows) { "garble.exe" } else { "garble" })
if (-not $NoObfuscate) {
    $haveGarble = (Test-Path $garble) -and ((& $garble version 2>$null | Select-Object -First 1) -match [regex]::Escape($GarbleVersion))
    if (-not $haveGarble) {
        Log "installing garble $GarbleVersion"
        & go install "mvdan.cc/garble@$GarbleVersion"
        if ($LASTEXITCODE -ne 0) { Fail "go install garble failed" }
    }
}

# ── fresh clone of the public repo ───────────────────────────────────────
$work = Join-Path ([IO.Path]::GetTempPath()) ("vyo-build-" + [Guid]::NewGuid().ToString("N").Substring(0, 8))
Log "cloning $RepoUrl ($Ref) into a temp folder"
& git clone --quiet --depth 1 --branch $Ref $RepoUrl $work
if ($LASTEXITCODE -ne 0) { Fail "git clone failed (is -Ref '$Ref' a branch or tag?)" }
$commit = (& git -C $work rev-parse --short=12 HEAD).Trim()

# Installer files come from the SAME clone as the code, so a bundle is fully
# reproducible from the repo at -Ref. -UseLocalTemplates is only for testing
# installer edits before they are pushed.
$TemplateDir = Join-Path $work "scripts\release\provider"
if ($UseLocalTemplates) {
    $TemplateDir = Join-Path $ScriptDir "provider"
    Write-Host "[build] warning: using LOCAL installer files from $TemplateDir, not the repo's" -ForegroundColor Yellow
}
if (-not (Test-Path (Join-Path $TemplateDir "install.ps1"))) {
    Fail "installer files not found in $TemplateDir. Push scripts/release/provider to '$Ref' first, or pass -UseLocalTemplates"
}
$stamp  = (Get-Date).ToUniversalTime().ToString("yyyyMMdd-HHmm")
$version = "$stamp-$commit"
$stage = Join-Path $OutDir "VyomanautProvider-$version"
if (Test-Path $stage) { Remove-Item -Recurse -Force $stage }
New-Item -ItemType Directory -Force -Path $stage | Out-Null
$buildLog = Join-Path $OutDir "build-$version.log"

# ── build provider.exe ────────────────────────────────────────────────────
$exe = Join-Path $stage "provider.exe"
$savedEnv = @{ GOOS = $env:GOOS; GOARCH = $env:GOARCH; CGO_ENABLED = $env:CGO_ENABLED; GOFLAGS = $env:GOFLAGS }
try {
    $env:GOOS = "windows"; $env:GOARCH = "amd64"; $env:CGO_ENABLED = "0"; $env:GOFLAGS = "-mod=readonly"
    Push-Location $work
    if ($NoObfuscate) {
        Log "building provider.exe (plain, stripped) — NOT obfuscated"
        & go build -trimpath -ldflags "-s -w" -o $exe ./cmd/provider 2>&1 | Tee-Object -FilePath $buildLog
    } else {
        # -literals : encrypt string/number literals (URLs, messages) in the binary
        # -seed=random : fresh obfuscation each build; the seed lands in the build log only
        # no -tiny : -tiny strips panic messages, which would make a lab crash undebuggable
        Log "building provider.exe with garble (takes 2-4 minutes)"
        & $garble -literals -seed=random build -trimpath -ldflags "-s -w" -o $exe ./cmd/provider 2>&1 | Tee-Object -FilePath $buildLog
    }
    if ($LASTEXITCODE -ne 0 -or -not (Test-Path $exe)) { Fail "build failed — see $buildLog" }
} finally {
    Pop-Location
    foreach ($k in $savedEnv.Keys) {
        if ($null -eq $savedEnv[$k]) { Remove-Item "env:$k" -ErrorAction SilentlyContinue }
        else { Set-Item -Path "env:$k" -Value $savedEnv[$k] }
    }
}

# Leak check: the exe must not contain your local paths or the repo's package paths in clear text.
$bytes = [IO.File]::ReadAllBytes($exe)
$text  = [Text.Encoding]::ASCII.GetString($bytes)
$leaks = @($env:USERPROFILE, $work, "Vyomanaut_V2/internal/") | Where-Object { $_ -and $text.Contains($_) }
if ($leaks -and -not $NoObfuscate) { Fail "provider.exe still contains: $($leaks -join ', ')" }
Log ("provider.exe built: {0:N1} MB" -f ($bytes.Length / 1MB))

# ── ZeroTier MSI ──────────────────────────────────────────────────────────
if (-not $SkipZeroTier) {
    Log "downloading the ZeroTier installer"
    try {
        Invoke-WebRequest -Uri $ZeroTierMsiUrl -OutFile (Join-Path $stage "ZeroTierOne.msi") -UseBasicParsing
    } catch {
        Write-Host "[build] warning: ZeroTier download failed ($($_.Exception.Message)); the installer will use winget instead" -ForegroundColor Yellow
    }
}

# ── installer files + config ─────────────────────────────────────────────
Copy-Item -Path (Join-Path $TemplateDir "*") -Destination $stage -Recurse -Force
# Windows needs CRLF in .cmd files (goto/labels misbehave with LF) whatever git checked out.
Get-ChildItem -Path $stage -Include *.cmd, *.ps1, *.txt -Recurse | ForEach-Object {
    $t = [IO.File]::ReadAllText($_.FullName) -replace "`r?`n", "`r`n"
    [IO.File]::WriteAllText($_.FullName, $t, [Text.Encoding]::ASCII)
}
[ordered]@{
    version             = $version
    microservice_url    = $MicroserviceUrl
    zerotier_network_id = $NetworkId.ToLower()
    listen_port         = $ListenPort
    default_storage_gb  = $DefaultStorageGB
    city                = $City
    region              = $Region
    mode                = "demo"
} | ConvertTo-Json | Set-Content -Path (Join-Path $stage "config.json") -Encoding UTF8

# ── zip + hash ────────────────────────────────────────────────────────────
$zip = "$stage.zip"
if (Test-Path $zip) { Remove-Item -Force $zip }
Compress-Archive -Path (Join-Path $stage "*") -DestinationPath $zip
$sha = (Get-FileHash -Algorithm SHA256 $zip).Hash
Add-Content -Path $buildLog -Value "`ncommit=$commit ref=$Ref version=$version sha256=$sha"
Remove-Item -Recurse -Force $work -ErrorAction SilentlyContinue

Write-Host ""
Log "DONE"
Log "bundle : $zip"
Log "sha256 : $sha"
Log "log    : $buildLog   (contains the garble seed — keep private)"
Write-Host ""
Write-Host "Copy the zip to each provider PC, extract it, right-click Install.cmd -> Run as administrator."
