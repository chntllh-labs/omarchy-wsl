#requires -Version 5.1
<#
.SYNOPSIS
  Adversarially hardened, hardware-adaptive .wslconfig generator for Omarchy-WSL.

.DESCRIPTION
  Detects host OS version, hypervisor capabilities, memory, and core count.
  Emits an optimal .wslconfig tailored for modern Windows 11 (mirrored networking,
  DNS tunneling, auto-proxy) or safely falls back to resilient NAT for Windows 10
  to prevent hypervisor boot failure (0x80070057).

.PARAMETER DryRun
  Print the configuration to stdout without writing to $env:USERPROFILE\.wslconfig.

.PARAMETER ForceNAT
  Force traditional NAT mode even on Windows 11 (useful for restrictive third-party VPNs).

.PARAMETER OutputPath
  Custom destination path for the generated configuration file.
#>

[CmdletBinding()]
param(
  [switch]$DryRun,
  [switch]$ForceNAT,
  [string]$OutputPath = ""
)

$ErrorActionPreference = "Stop"

function Write-Info { param([string]$Msg) Write-Host "[*] $Msg" -ForegroundColor Cyan }
Write-Info "Inspecting host system capabilities for WSL configuration..."

# 1. Detect OS Version & Build
$os = [System.Environment]::OSVersion.Version
$build = $os.Build
$isWin11MirroredCapable = ($build -ge 22621) # Windows 11 22H2+

# 2. Detect CPU Architecture & Cores
$rawArch = if ($env:PROCESSOR_ARCHITEW6432) { $env:PROCESSOR_ARCHITEW6432 } else { $env:PROCESSOR_ARCHITECTURE }
$logicalProcessors = [System.Environment]::ProcessorCount

# 3. Detect Host RAM
$totalRamBytes = (Get-CimInstance Win32_PhysicalMemory | Measure-Object -Property Capacity -Sum).Sum
$totalRamGB = [math]::Round($totalRamBytes / 1GB)

# Sizing heuristics:
# Allocate up to 75% of RAM for WSL, leaving plenty of headroom for Windows host OS.
# For Snapdragon X Elite 64GB, WSL gets ~48GB. For 32GB hosts, WSL gets ~24GB. For 16GB hosts, WSL gets 12GB.
$wslMemoryGB = [math]::Max(4, [math]::Round($totalRamGB * 0.75))
$wslSwapGB = [math]::Min(16, [math]::Max(4, [math]::Round($wslMemoryGB * 0.25)))

Write-Info "Detected Windows Build: $build"
Write-Info "Host Architecture: $rawArch ($logicalProcessors logical cores, ${totalRamGB}GB RAM)"
Write-Info "Calculated WSL allocation: ${wslMemoryGB}GB RAM, ${wslSwapGB}GB swap, $logicalProcessors cores"

$networkingMode = "mirrored"
$dnsTunneling = "true"
$autoProxy = "true"
$hostAddressLoopback = "true"
$firewall = "true"

if ($ForceNAT -or -not $isWin11MirroredCapable) {
  if (-not $isWin11MirroredCapable) {
    Write-Host "[!] Host is Windows 10 / Build < 22621. Falling back to resilient NAT mode." -ForegroundColor Yellow
  } else {
    Write-Host "[!] User specified -ForceNAT. Configuring NAT mode." -ForegroundColor Yellow
  }
  $networkingMode = "NAT"
  $dnsTunneling = "false"
  $autoProxy = "false"
  $hostAddressLoopback = "false"
  $firewall = "false"
} else {
  Write-Host "[+] Windows 11 Build $build detected: Enabling Mirrored Networking & DNS Tunneling." -ForegroundColor Green
}

# 4. Generate .wslconfig content
$sb = [System.Text.StringBuilder]::new()
[void]$sb.AppendLine("# ==============================================================================")
[void]$sb.AppendLine("# Omarchy-WSL Host Virtualization Configuration (.wslconfig)")
[void]$sb.AppendLine("# Generated on $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') for Build $build")
[void]$sb.AppendLine("# ==============================================================================")
[void]$sb.AppendLine("[wsl2]")
[void]$sb.AppendLine("memory=${wslMemoryGB}GB")
[void]$sb.AppendLine("processors=$logicalProcessors")
[void]$sb.AppendLine("swap=${wslSwapGB}GB")
[void]$sb.AppendLine("swapFile=%USERPROFILE%\\.wsl-swap.vhdx")
[void]$sb.AppendLine("autoMemoryReclaim=gradual")
[void]$sb.AppendLine("pageReporting=true")
[void]$sb.AppendLine("nestedVirtualization=true")
[void]$sb.AppendLine("")

if ($networkingMode -eq "mirrored") {
  [void]$sb.AppendLine("# Modern Windows 11 Mirrored Networking & Corporate Resilience")
  [void]$sb.AppendLine("networkingMode=mirrored")
  [void]$sb.AppendLine("dnsTunneling=true")
  [void]$sb.AppendLine("autoProxy=true")
  [void]$sb.AppendLine("hostAddressLoopback=true")
  [void]$sb.AppendLine("firewall=true")
  [void]$sb.AppendLine("# Ports ignored from mirroring (bind purely inside guest)")
  [void]$sb.AppendLine("ignoredPorts=5353,5355")
} else {
  [void]$sb.AppendLine("# Resilient Legacy NAT Fallback")
  [void]$sb.AppendLine("networkingMode=NAT")
  [void]$sb.AppendLine("dnsTunneling=false")
  [void]$sb.AppendLine("autoProxy=false")
}

[void]$sb.AppendLine("")
[void]$sb.AppendLine("[experimental]")
[void]$sb.AppendLine("autoMemoryReclaim=gradual")
[void]$sb.AppendLine("sparseVhd=true")

$configContent = $sb.ToString()

if ($DryRun) {
  Write-Host ""
  Write-Host "--- [DRY RUN PREVIEW] ---" -ForegroundColor Cyan
  Write-Host $configContent
  Write-Host "-------------------------" -ForegroundColor Cyan
  return
}

$targetPath = if ([string]::IsNullOrWhiteSpace($OutputPath)) {
  Join-Path $env:USERPROFILE ".wslconfig"
} else {
  $OutputPath
}

if (Test-Path $targetPath) {
  $backupPath = "$targetPath.bak.$(Get-Date -Format 'yyyyMMddHHmmss')"
  Write-Info "Backing up existing .wslconfig to $backupPath..."
  Copy-Item -Path $targetPath -Destination $backupPath -Force
}

Write-Info "Writing .wslconfig to $targetPath..."
[System.IO.File]::WriteAllText($targetPath, $configContent, [System.Text.Encoding]::UTF8)
Write-Host "[+] Successfully installed .wslconfig! Restart WSL via 'wsl --shutdown' to apply." -ForegroundColor Green
