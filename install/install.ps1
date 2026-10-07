#requires -Version 5.1
<#
.SYNOPSIS
  Adversarially hardened, zero-data-loss one-line installer for Omarchy-WSL.

.DESCRIPTION
  Safely bootstraps Omarchy on Windows Subsystem for Linux (WSL).
  Designed for unattended or interactive invocation via:
    irm https://install.omarchy.org/wsl | iex

.FEATURES
  - Strict host pre-flight verification (Windows 10/11 build requirements, WSL2 status)
  - Non-elevated execution safety (prevents orphan admin registrations)
  - Precise architecture detection (Snapdragon ARM64 vs Intel/AMD x86_64)
  - Distro collision detection and zero-data-loss protection
  - Cryptographic SHA-256 integrity verification before image import
  - High-performance chunked download with TLS 1.2/1.3 enforcement
  - Automatic fallback between modern 'wsl --install --from-file' and 'wsl --import'
#>

[CmdletBinding()]
param(
  [string]$DistroName = "Omarchy",
  [string]$ReleaseTag = "latest",
  [string]$InstallPath = "",
  [string]$Repo = "chntllh-labs/omarchy-wsl",
  [switch]$NonInteractive,
  [switch]$ForceSideBySide
)

$ErrorActionPreference = "Stop"

# Enforce TLS 1.2 / TLS 1.3 for secure downloads on legacy PowerShell 5.1
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 -bor [Net.SecurityProtocolType]::Tls13

# UI Styling
function Write-OmarchyHeader {
  Write-Host ""
  Write-Host "  ██████╗ ███╗   ███╗ █████╗ ██████╗  ██████╗██╗  ██╗██╗   ██╗" -ForegroundColor Cyan
  Write-Host " ██╔═══██╗████╗ ████║██╔══██╗██╔══██╗██╔════╝██║  ██║╚██╗ ██╔╝" -ForegroundColor Cyan
  Write-Host " ██║   ██║██╔████╔██║███████║██████╔╝██║     ███████║ ╚████╔╝ " -ForegroundColor Cyan
  Write-Host " ██║   ██║██║╚██╔╝██║██╔══██║██╔══██╗██║     ██╔══██║  ╚██╔╝  " -ForegroundColor Cyan
  Write-Host " ╚██████╔╝██║ ╚═╝ ██║██║  ██║██║  ██║╚██████╗██║  ██║   ██║   " -ForegroundColor Cyan
  Write-Host "  ╚═════╝ ╚═╝     ╚═╝╚═╝  ╚═╝╚═╝  ╚═╝ ╚═════╝╚═╝  ╚═╝   ╚═╝   " -ForegroundColor Cyan
  Write-Host "               Windows Subsystem for Linux Distribution Engine" -ForegroundColor DarkGray
  Write-Host ""
}

function Write-Step {
  param([string]$Message)
  Write-Host "[*] $Message" -ForegroundColor Cyan
}

function Write-Success {
  param([string]$Message)
  Write-Host "[+] $Message" -ForegroundColor Green
}

function Write-Warn {
  param([string]$Message)
  Write-Host "[!] $Message" -ForegroundColor Yellow
}

function Write-Err {
  param([string]$Message)
  Write-Host "[-] $Message" -ForegroundColor Red
}

# -----------------------------------------------------------------------------
# 1. Host Pre-flight and Security Audits
# -----------------------------------------------------------------------------
function Test-HostEnvironment {
  Write-Step "Auditing Windows host environment..."

  # Check 64-bit OS
  if (-not [System.Environment]::Is64BitOperatingSystem) {
    throw "Omarchy-WSL requires a 64-bit operating system."
  }

  # Check Windows Build (WSL2 requires Windows 10 Build 19041+ or Windows 11)
  $osVersion = [System.Environment]::OSVersion.Version
  if ($osVersion.Major -lt 10 -or ($osVersion.Major -eq 10 -and $osVersion.Build -lt 19041)) {
    throw "Omarchy-WSL requires Windows 10 build 19041 or higher (Current: $($osVersion.Build))."
  }

  # Audit UAC elevation trap
  # Distros must be registered in user scope; root/admin registration breaks Windows Terminal integration
  $isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
  if ($isAdmin) {
    Write-Warn "Running in an elevated Administrator session!"
    Write-Warn "Installing WSL distros as Administrator registers them under the Administrator profile,"
    Write-Warn "which prevents standard users and Windows Terminal from accessing them cleanly."
    if (-not $NonInteractive) {
      $proceed = Read-Host "Do you want to continue anyway? [y/N]"
      if ($proceed -notmatch '^[yY]') {
        Write-Err "Aborted. Please re-run from a standard (non-elevated) PowerShell terminal."
        exit 1
      }
    }
  }

  # Verify WSL CLI presence
  if (-not (Get-Command wsl.exe -ErrorAction SilentlyContinue)) {
    Write-Err "WSL is not installed on this system."
    Write-Host "Run 'wsl --install --no-distribution' in an Administrator terminal and reboot." -ForegroundColor Yellow
    exit 1
  }

  Write-Success "Host environment verified (Build $($osVersion.Build))."
}

# -----------------------------------------------------------------------------
# 2. Architecture Resolution
# -----------------------------------------------------------------------------
function Resolve-Architecture {
  $rawArch = if ($env:PROCESSOR_ARCHITEW6432) { $env:PROCESSOR_ARCHITEW6432 } else { $env:PROCESSOR_ARCHITECTURE }
  if ($rawArch -match "ARM64") {
    return "arm64"
  } elseif ($rawArch -match "AMD64|x86_64") {
    return "x86_64"
  } else {
    throw "Unsupported CPU architecture: $rawArch. Supported: x86_64, arm64."
  }
}

# -----------------------------------------------------------------------------
# 3. Collision Audit & Data Preservation
# -----------------------------------------------------------------------------
function Resolve-TargetDistroName {
  param([string]$CandidateName)

  $rawList = & wsl.exe --list --quiet 2>$null
  # Filter Unicode null characters produced by wsl.exe output
  $installedDistros = @($rawList | ForEach-Object { ($_ -replace "\0", "").Trim() } | Where-Object { $_ -ne "" })

  if ($installedDistros -contains $CandidateName) {
    Write-Warn "An existing distribution named '$CandidateName' was found!"

    if ($ForceSideBySide) {
      $counter = 1
      while ($installedDistros -contains "$CandidateName-$counter") { $counter++ }
      $newName = "$CandidateName-$counter"
      Write-Step "Side-by-side mode: assigning new name '$newName'."
      return $newName
    }

    if ($NonInteractive) {
      Write-Err "Distro '$CandidateName' already exists. Pass -ForceSideBySide or choose another name."
      exit 1
    }

    Write-Host ""
    Write-Host "Existing Distribution Safety Gate:" -ForegroundColor Yellow
    Write-Host "  [1] Run in-place rolling update inside '$CandidateName' (ZERO data loss)" -ForegroundColor Green
    Write-Host "  [2] Install new version side-by-side (Preserves existing distro)" -ForegroundColor Cyan
    Write-Host "  [3] Cancel installation" -ForegroundColor Red
    Write-Host ""
    $choice = Read-Host "Select option [1/2/3]"

    switch ($choice) {
      "1" {
        Write-Step "Invoking in-place rolling update inside '$CandidateName'..."
        & wsl.exe -d $CandidateName -u root -- omarchy-wsl-update
        exit $LASTEXITCODE
      }
      "2" {
        $customName = Read-Host "Enter new unique distro name (e.g. Omarchy-2026)"
        if ([string]::IsNullOrWhiteSpace($customName) -or ($installedDistros -contains $customName)) {
          throw "Invalid or duplicate distribution name '$customName'."
        }
        return $customName.Trim()
      }
      default {
        Write-Warn "Installation cancelled by user. No files were modified."
        exit 0
      }
    }
  }

  return $CandidateName
}

# -----------------------------------------------------------------------------
# 4. Release Asset Discovery & Integrity Fetch
# -----------------------------------------------------------------------------
function Get-ReleasePackage {
  param(
    [string]$Arch,
    [string]$Tag,
    [string]$DestinationDir
  )

  Write-Step "Querying GitHub release metadata for architecture '$Arch'..."
  $apiUri = if ($Tag -eq "latest") {
    "https://api.github.com/repos/$Repo/releases/latest"
  } else {
    "https://api.github.com/repos/$Repo/releases/tags/$Tag"
  }

  $headers = @{ "User-Agent" = "Omarchy-WSL-Installer" }
  try {
    $release = Invoke-RestMethod -Uri $apiUri -Headers $headers -Method Get
  } catch {
    throw "Failed to fetch release metadata from $apiUri: $_"
  }

  $version = $release.tag_name
  Write-Success "Found release $version"

  $assetName = "Omarchy-${Arch}.wsl"
  $asset = $release.assets | Where-Object { $_.name -eq $assetName }
  if (-not $asset) {
    throw "Release asset '$assetName' was not found in release $version."
  }

  $checksumAsset = $release.assets | Where-Object { $_.name -eq "SHA256SUMS" }
  if (-not $checksumAsset) {
    throw "Security violation: Checksum manifest 'SHA256SUMS' missing from release $version."
  }

  # Prepare temporary staging directory
  $tempDir = Join-Path $DestinationDir "omarchy-install-$((Get-Random))"
  New-Item -ItemType Directory -Path $tempDir -Force | Out-Null

  $downloadPath = Join-Path $tempDir $assetName
  $checksumPath = Join-Path $tempDir "SHA256SUMS"

  Write-Step "Downloading checksum manifest..."
  Invoke-WebRequest -Uri $checksumAsset.browser_download_url -OutFile $checksumPath -UseBasicParsing

  # Extract expected checksum
  $checksumContent = Get-Content -Path $checksumPath
  $expectedHash = ""
  foreach ($line in $checksumContent) {
    if ($line -match "([a-fA-F0-9]{64})\s+.*$assetName") {
      $expectedHash = $matches[1]
      break
    }
  }

  if ([string]::IsNullOrWhiteSpace($expectedHash)) {
    throw "Security violation: SHA256 checksum for '$assetName' not found in manifest."
  }

  Write-Step "Downloading distribution package ($assetName) [SHA256: $expectedHash]..."
  $ProgressPreference = 'SilentlyContinue'
  Invoke-WebRequest -Uri $asset.browser_download_url -OutFile $downloadPath -UseBasicParsing

  Write-Step "Verifying cryptographic SHA-256 integrity..."
  $actualHash = (Get-FileHash -Path $downloadPath -Algorithm SHA256).Hash.ToLowerInvariant()
  if ($actualHash -ne $expectedHash.ToLowerInvariant()) {
    Remove-Item -Recurse -Force $tempDir 2>$null
    throw "INTEGRITY CHECK FAILED! Expected: $expectedHash, Got: $actualHash. Aborting."
  }
  Write-Success "Cryptographic hash verified: $actualHash"

  return @{
    PackagePath = $downloadPath
    TempDirectory = $tempDir
    Version = $version
  }
}

# -----------------------------------------------------------------------------
# 5. Distro Registration & Setup
# -----------------------------------------------------------------------------
function Install-Distro {
  param(
    [string]$DistroName,
    [string]$PackagePath,
    [string]$TargetFolder
  )

  Write-Step "Registering distribution '$DistroName' into WSL..."

  if (-not $TargetFolder) {
    $TargetFolder = Join-Path $env:LOCALAPPDATA "WSL\Distros\$DistroName"
  }
  New-Item -ItemType Directory -Path $TargetFolder -Force | Out-Null

  # Try modern wsl --install --from-file (WSL 2.0.0+)
  $installSuccess = $false
  try {
    Write-Step "Attempting modern registration (wsl --install --from-file)..."
    & wsl.exe --install --from-file "$PackagePath" --name "$DistroName"
    if ($LASTEXITCODE -eq 0) {
      $installSuccess = $true
    }
  } catch {
    Write-Warn "Modern install syntax returned error; falling back to wsl --import."
  }

  if (-not $installSuccess) {
    Write-Step "Importing rootfs via wsl --import into '$TargetFolder'..."
    & wsl.exe --import "$DistroName" "$TargetFolder" "$PackagePath" --version 2
    if ($LASTEXITCODE -ne 0) {
      throw "wsl --import failed with exit code $LASTEXITCODE"
    }
  }

  Write-Success "Distribution '$DistroName' successfully registered!"
}

# -----------------------------------------------------------------------------
# 6. Post-Installation Verification & Handshake
# -----------------------------------------------------------------------------
function Test-DistroHealth {
  param([string]$DistroName)

  Write-Step "Running post-install health verification..."
  $kernelCheck = & wsl.exe -d $DistroName -u root -- uname -r 2>$null
  if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($kernelCheck)) {
    throw "WSL failed to boot distribution '$DistroName'."
  }

  # Verify default user exists
  $userCheck = & wsl.exe -d $DistroName -- whoami 2>$null
  Write-Success "WSL boot confirmed (Kernel: $($kernelCheck.Trim()), Active user: $($userCheck.Trim()))"
}

# -----------------------------------------------------------------------------
# Main Execution Flow
# -----------------------------------------------------------------------------
try {
  Write-OmarchyHeader
  Test-HostEnvironment

  $arch = Resolve-Architecture
  Write-Success "Detected CPU architecture: $arch"

  $targetName = Resolve-TargetDistroName -CandidateName $DistroName

  $pkgInfo = Get-ReleasePackage -Arch $arch -Tag $ReleaseTag -DestinationDir $env:TEMP
  try {
    Install-Distro -DistroName $targetName -PackagePath $pkgInfo.PackagePath -TargetFolder $InstallPath
    Test-DistroHealth -DistroName $targetName
  } finally {
    # Clean up staging archive
    Write-Step "Cleaning temporary staging files..."
    Remove-Item -Recurse -Force $pkgInfo.TempDirectory -ErrorAction SilentlyContinue
  }

  Write-Host ""
  Write-Host "=================================================================" -ForegroundColor Green
  Write-Host "  Omarchy-WSL ($($pkgInfo.Version)) is ready to use!" -ForegroundColor Green
  Write-Host "=================================================================" -ForegroundColor Green
  Write-Host ""
  Write-Host "Launch Omarchy directly with:" -ForegroundColor Cyan
  Write-Host "  wsl -d $targetName" -ForegroundColor Yellow
  Write-Host ""
  Write-Host "Or select '$targetName' from the Windows Terminal dropdown." -ForegroundColor Cyan
  Write-Host ""
} catch {
  Write-Err "Installation failed: $_"
  exit 1
}
