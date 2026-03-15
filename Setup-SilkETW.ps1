#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Automated setup script for SilkETW / SilkService on Windows.

.DESCRIPTION
    This script automates every step from the manual.txt:
      1. Downloads the latest SilkETW release from GitHub.
      2. Extracts and copies the SilkService folder to C:\SilkService.
      3. Unblocks all downloaded files.
      4. Creates SilkServiceConfig.xml with DNS and PowerShell ETW collectors.
      5. Patches SilkService.exe.config to point at the config file.
      6. Creates the log output directory (C:\edr).
      7. Installs SilkService as a Windows service via InstallUtil.
      8. Starts the service and confirms its status.

.PARAMETER InstallPath
    Directory where SilkService will be installed. Default: C:\SilkService

.PARAMETER LogPath
    Directory where ETW collector JSON logs are written. Default: C:\edr

.PARAMETER SkipDownload
    If set, skips the download step and expects SilkService files to already
    exist at InstallPath.

.EXAMPLE
    .\Setup-SilkETW.ps1
    .\Setup-SilkETW.ps1 -InstallPath "D:\SilkService" -LogPath "D:\edr"
#>

[CmdletBinding()]
param(
    [string]$InstallPath = "C:\SilkService",
    [string]$LogPath     = "C:\edr",
    [switch]$SkipDownload
)

# -- Helpers -----------------------------------------------------------------
Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Write-Step  { param([string]$Msg) Write-Host "`n>> $Msg" -ForegroundColor Cyan }
function Write-Ok    { param([string]$Msg) Write-Host "   [OK] $Msg" -ForegroundColor Green }
function Write-Warn  { param([string]$Msg) Write-Host "   [WARN] $Msg" -ForegroundColor Yellow }

# -- Prerequisite - Visual C++ 2015-2022 Redistributable (x86) --------------
#
#   SilkETW / SilkService depends on the VC++ x86 runtime.
#   Install it BEFORE anything else, otherwise the service will fail to start.
#   Download: https://aka.ms/vs/17/release/vc_redist.x86.exe
#
Write-Step "Prerequisite - Checking Visual C++ 2015-2022 Redistributable (x86)"

# Detect by searching the Uninstall registry hives for the VC++ 2015-2022 x86 package
$vcppInstalled = Get-ChildItem -Path @(
        "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall",
        "HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall"
    ) -ErrorAction SilentlyContinue |
    Get-ItemProperty -ErrorAction SilentlyContinue |
    Where-Object {
        $_.PSObject.Properties.Name -contains 'DisplayName' -and
        $_.DisplayName -match "Microsoft Visual C\+\+ 201[5-9]|202[0-9].*Redistributable.*x86"
    } |
    Select-Object -First 1

if ($vcppInstalled) {
    Write-Ok "VC++ Redistributable (x86) already installed: $($vcppInstalled.DisplayName)"
}
else {
    Write-Warn "Visual C++ 2015-2022 Redistributable (x86) was NOT detected on this system."
    Write-Host ""
    Write-Host "   SilkETW requires this runtime to operate correctly." -ForegroundColor Yellow
    Write-Host "   Download URL: https://aka.ms/vs/17/release/vc_redist.x86.exe" -ForegroundColor Yellow
    Write-Host ""

    $vcppChoice = Read-Host "   Do you want this script to download and install it now? [Y/N]"

    if ($vcppChoice -match "^[Yy]") {
        $vcRedistUrl      = "https://aka.ms/vs/17/release/vc_redist.x86.exe"
        $vcRedistInstaller = Join-Path $env:TEMP "vc_redist.x86.exe"

        Write-Host "   Downloading vc_redist.x86.exe ..."
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        Invoke-WebRequest -Uri $vcRedistUrl -OutFile $vcRedistInstaller -UseBasicParsing

        Write-Host "   Installing - please follow any UAC prompts ..."
        $proc = Start-Process -FilePath $vcRedistInstaller `
                              -ArgumentList "/install", "/quiet", "/norestart" `
                              -Wait -PassThru

        Remove-Item $vcRedistInstaller -Force -ErrorAction SilentlyContinue

        if ($proc.ExitCode -eq 0 -or $proc.ExitCode -eq 3010) {
            Write-Ok "VC++ Redistributable (x86) installed successfully."
            if ($proc.ExitCode -eq 3010) {
                Write-Warn "A reboot is recommended to complete the VC++ installation."
            }
        }
        else {
            Write-Warn "Installer exited with code $($proc.ExitCode). Verify manually before continuing."
        }
    }
    else {
        Write-Warn "Skipping VC++ installation. Install it manually before starting SilkService:"
        Write-Host "   https://aka.ms/vs/17/release/vc_redist.x86.exe" -ForegroundColor Yellow
        $continueAnyway = Read-Host "   Continue setup anyway? [Y/N]"
        if ($continueAnyway -notmatch "^[Yy]") {
            Write-Host "Setup aborted by user." -ForegroundColor Red
            exit 1
        }
    }
}

# -- Step 1 - Download the latest release from GitHub ------------------------
if (-not $SkipDownload) {
    Write-Step "Step 1/8 - Downloading latest SilkETW release from GitHub"

    $apiUrl   = "https://api.github.com/repos/mandiant/SilkETW/releases/latest"
    $headers  = @{ "User-Agent" = "SilkETW-Setup-Script" }

    try {
        $release  = Invoke-RestMethod -Uri $apiUrl -Headers $headers
        $asset    = $release.assets | Where-Object { $_.name -like "*.zip" } | Select-Object -First 1

        if (-not $asset) {
            throw "No .zip asset found in the latest release."
        }

        $zipUrl   = $asset.browser_download_url
        $zipFile  = Join-Path $env:TEMP $asset.name

        Write-Host "   Downloading $($asset.name) ..."
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        Invoke-WebRequest -Uri $zipUrl -OutFile $zipFile -UseBasicParsing
        Write-Ok "Downloaded to $zipFile"
    }
    catch {
        Write-Warn "Automatic download failed: $_"
        Write-Host "   Please download manually from https://github.com/mandiant/SilkETW/releases"
        Write-Host "   Place the extracted SilkService folder at: $InstallPath"
        Read-Host  "   Press Enter once the files are in place to continue"
        $SkipDownload = $true          # skip extraction too
    }
}

# -- Step 2 - Extract and copy SilkService to InstallPath --------------------
if (-not $SkipDownload) {
    Write-Step "Step 2/8 - Extracting archive to $InstallPath"

    $extractDir = Join-Path $env:TEMP "SilkETW_extract"
    if (Test-Path $extractDir) { Remove-Item $extractDir -Recurse -Force }
    Expand-Archive -Path $zipFile -DestinationPath $extractDir -Force

    # Look for the SilkService subfolder inside the extracted content
    $silkFolder = Get-ChildItem -Path $extractDir -Directory -Recurse |
                  Where-Object { $_.Name -eq "SilkService" } |
                  Select-Object -First 1

    if (-not $silkFolder) {
        # If no subfolder named SilkService, use the root of extracted content
        $silkFolder = Get-Item $extractDir
    }

    if (-not (Test-Path $InstallPath)) { New-Item -ItemType Directory -Path $InstallPath -Force | Out-Null }
    Copy-Item -Path (Join-Path $silkFolder.FullName "*") -Destination $InstallPath -Recurse -Force
    Write-Ok "Files copied to $InstallPath"

    # Cleanup temp files
    Remove-Item $extractDir -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item $zipFile    -Force           -ErrorAction SilentlyContinue
}
else {
    Write-Step "Step 2/8 - Skipping download/extract (using existing files at $InstallPath)"
    if (-not (Test-Path $InstallPath)) {
        throw "InstallPath does not exist: $InstallPath"
    }
}

# -- Step 3 - Unblock all files ------------------------------------------------
Write-Step "Step 3/8 - Unblocking all files in $InstallPath"
Get-ChildItem $InstallPath -Recurse | Unblock-File
Write-Ok "All files unblocked"

# -- Step 4 - Create SilkServiceConfig.xml -----------------------------------
Write-Step "Step 4/8 - Writing SilkServiceConfig.xml"

# ─────────────────────────────────────────────────────────────────────────────
# Define every ETW collector you want here.
# Add or remove hashtables freely — the loop below will automatically call
# New-Guid once per collector, so you never have to manage GUIDs manually.
#
# Required keys : ProviderName, CollectorType, OutputType, FileName, Comment
# Optional keys : UserKeywords  (omit the key entirely if not needed)
# ─────────────────────────────────────────────────────────────────────────────
$collectors = @(
    @{
        Comment       = "DNS Collector"
        ProviderName  = "Microsoft-Windows-DNS-Client"
        CollectorType = "user"
        OutputType    = "file"
        FileName      = "dns.json"
    },
    @{
        Comment       = "PowerShell Collector"
        ProviderName  = "Microsoft-Windows-PowerShell"
        CollectorType = "user"
        UserKeywords  = "0x20"
        OutputType    = "file"
        FileName      = "powershell.json"
    }
    # ── Add more collectors below this line ───────────────────────────────────
    # @{
    #     Comment       = "Sysmon Collector"
    #     ProviderName  = "Microsoft-Windows-Sysmon"
    #     CollectorType = "user"
    #     OutputType    = "file"
    #     FileName      = "sysmon.json"
    # },
)

# Build the XML — one fresh New-Guid per collector block, no matter how many
Write-Host "   Generating GUIDs and building XML for $($collectors.Count) collector(s):"
$collectorXml = foreach ($col in $collectors) {
    $guid = (New-Guid).ToString()
    Write-Host "     [$guid]  $($col.Comment)"

    # Build the optional <UserKeywords> line only when the key is present
    $userKeywordsLine = if ($col.ContainsKey("UserKeywords")) {
        "    <UserKeywords>$($col.UserKeywords)</UserKeywords>`n  "
    } else { "" }

    @"
  <!-- $($col.Comment) -->
  <ETWCollector>
    <Guid>$guid</Guid>
    <CollectorType>$($col.CollectorType)</CollectorType>
    <ProviderName>$($col.ProviderName)</ProviderName>
    $($userKeywordsLine)<OutputType>$($col.OutputType)</OutputType>
    <Path>$LogPath\$($col.FileName)</Path>
  </ETWCollector>
"@
}

$configXml = @"
<?xml version="1.0" encoding="utf-8"?>
<SilkServiceConfig>
$($collectorXml -join "`n")
</SilkServiceConfig>
"@

$configPath = Join-Path $InstallPath "SilkServiceConfig.xml"
Set-Content -Path $configPath -Value $configXml -Encoding UTF8
Write-Ok "Created $configPath"

# -- Step 5 - Patch SilkService.exe.config -----------------------------------
Write-Step "Step 5/8 - Writing SilkService.exe.config"

$exeConfig = @"
<?xml version="1.0" encoding="utf-8" ?>
<configuration>
  <startup>
    <supportedRuntime version="v4.0" sku=".NETFramework,Version=v4.5" />
  </startup>
  <appSettings>
    <add key="ConfigFile" value="$configPath" />
  </appSettings>
</configuration>
"@

$exeConfigPath = Join-Path $InstallPath "SilkService.exe.config"
Set-Content -Path $exeConfigPath -Value $exeConfig -Encoding UTF8
Write-Ok "Created $exeConfigPath"

# -- Step 6 - Ensure log output directory exists -----------------------------
Write-Step "Step 6/8 - Ensuring log directory exists at $LogPath"
if (-not (Test-Path $LogPath)) {
    New-Item -ItemType Directory -Path $LogPath -Force | Out-Null
    Write-Ok "Created $LogPath"
}
else {
    Write-Ok "$LogPath already exists"
}

# -- Step 7 - Install SilkService via InstallUtil ----------------------------
Write-Step "Step 7/8 - Installing SilkService as a Windows service"

$installUtil = "C:\Windows\Microsoft.NET\Framework\v4.0.30319\InstallUtil.exe"
$silkExe     = Join-Path $InstallPath "SilkService.exe"

if (-not (Test-Path $installUtil)) {
    throw "InstallUtil not found at $installUtil - is .NET Framework 4.x installed?"
}
if (-not (Test-Path $silkExe)) {
    throw "SilkService.exe not found at $silkExe - check that extraction succeeded."
}

# Uninstall first if service already exists (idempotent re-installs)
$existingSvc = Get-Service -Name "SilkService" -ErrorAction SilentlyContinue
if ($existingSvc) {
    Write-Host "   Existing SilkService found - stopping and removing first ..."
    Stop-Service "SilkService" -Force -ErrorAction SilentlyContinue
    & $installUtil /u $silkExe | Out-Null
}

& $installUtil $silkExe
if ($LASTEXITCODE -ne 0) {
    throw "InstallUtil failed with exit code $LASTEXITCODE."
}
Write-Ok "SilkService installed successfully"

# -- Step 8 - Start & verify --------------------------------------------------
Write-Step "Step 8/8 - Starting SilkService and verifying status"

Start-Service "SilkService"
Start-Sleep -Seconds 2

$svc = Get-Service "SilkService"
if ($svc.Status -eq "Running") {
    Write-Ok "SilkService is RUNNING"
}
else {
    Write-Warn "SilkService status: $($svc.Status) - check the Windows Event Log for errors."
}

# -- Summary -----------------------------------------------------------------
Write-Host "`n========================================" -ForegroundColor Cyan
Write-Host " SilkETW Setup Complete" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "  Install path : $InstallPath"
Write-Host "  Config file  : $configPath"
Write-Host "  Log directory: $LogPath"
Write-Host "  Service      : SilkService ($($svc.Status))"
Write-Host "========================================`n" -ForegroundColor Cyan
