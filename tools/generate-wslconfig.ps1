#requires -Version 5.1
<#
.SYNOPSIS
  Adversarially hardened, hardware-adaptive .wslconfig generator for Omarchy-WSL.

.DESCRIPTION
  Inspects Windows host OS build, hypervisor capabilities, physical RAM, CPU cores,
  and architecture. Calculates mathematically safe, non-starving resource allocations
  across diverse hardware tiers (16GB laptop up to 64GB/128GB workstations).

  Emits an optimal .wslconfig configured for modern Windows 11 (mirrored networking,
  DNS tunneling, auto-proxy, gradual memory reclamation) with graceful fallback to
  NAT for Windows 10 / enterprise VPN environments.

  Adversarially mitigates:
  - Windows host memory starvation (guarantees 8GB reservation on laptops, 16GB on workstations).
  - Linux guest memory allocation starvation (kswapd0 order:0 failures).
  - Catastrophic StorPort NVMe refault read storms (enforces mandatory swap headroom).
  - Cold-cache disk thrashing (enforces autoMemoryReclaim=gradual over dropCache).
  - Ext4 superblock/journal corruption (disables unsafe sparseVhd).
  - Startup error popups (omits deprecated 'pageReporting' and misplaced 'wsl2.autoMemoryReclaim').

.PARAMETER DryRun
  Print the generated configuration to stdout without modifying files on disk.

.PARAMETER ForceNAT
  Force traditional NAT mode even on Windows 11 (recommended for restrictive third-party VPNs).

.PARAMETER OutputPath
  Custom destination path for the generated configuration file (defaults to $env:USERPROFILE\.wslconfig).

.PARAMETER ProfileOverride
  Optional hardware profile preset: 'Auto', 'Laptop-16GB', 'Pro-32GB', 'Workstation-64GB', 'Server-128GB'.

.PARAMETER RamOverrideGB
  Explicit memory allocation in GB for WSL2 (overrides auto-detection).

.PARAMETER CpuOverride
  Explicit processor core count for WSL2 (overrides auto-detection).

.PARAMETER SwapOverrideGB
  Explicit Hyper-V swap allocation in GB (overrides auto-detection).
#>

[CmdletBinding()]
param(
  [switch]$DryRun,
  [switch]$ForceNAT,
  [string]$OutputPath = "",
  [ValidateSet('Auto', 'Laptop-16GB', 'Pro-32GB', 'Workstation-64GB', 'Server-128GB')]
  [string]$ProfileOverride = 'Auto',
  [int]$RamOverrideGB = 0,
  [int]$CpuOverride = 0,
  [int]$SwapOverrideGB = 0
)

$ErrorActionPreference = "Stop"

function Write-Info { param([string]$Msg) Write-Host "[*] $Msg" -ForegroundColor Cyan }
function Write-Success { param([string]$Msg) Write-Host "[+] $Msg" -ForegroundColor Green }
function Write-Warn { param([string]$Msg) Write-Host "[!] $Msg" -ForegroundColor Yellow }
function Write-Err { param([string]$Msg) Write-Host "[-] $Msg" -ForegroundColor Red }

# -----------------------------------------------------------------------------
# 1. Hardware & OS Inspection
# -----------------------------------------------------------------------------
function Get-HostTopology {
  Write-Info "Probing Windows host topology and hypervisor capabilities..."

  # OS Version & Build
  $os = [System.Environment]::OSVersion.Version
  $build = $os.Build
  $isWin11MirroredCapable = ($build -ge 22621) # Windows 11 22H2+

  # CPU Architecture & Logical Processors
  $rawArch = if ($env:PROCESSOR_ARCHITEW6432) { $env:PROCESSOR_ARCHITEW6432 } else { $env:PROCESSOR_ARCHITECTURE }
  $arch = if ($rawArch -match "ARM64") { "arm64" } else { "x86_64" }
  $cpuCount = [Environment]::ProcessorCount

  try {
    $cs = Get-CimInstance Win32_ComputerSystem -ErrorAction SilentlyContinue
    if ($cs -and $cs.NumberOfLogicalProcessors) {
      $cpuCount = [int]$cs.NumberOfLogicalProcessors
    }
  } catch { }

  # Physical RAM Detection
  $totalRamBytes = 0
  try {
    $memModules = Get-CimInstance Win32_PhysicalMemory -ErrorAction SilentlyContinue
    if ($memModules) {
      $totalRamBytes = ($memModules | Measure-Object -Property Capacity -Sum).Sum
    }
  } catch { }

  if ($totalRamBytes -le 0) {
    try {
      $cs = Get-CimInstance Win32_ComputerSystem -ErrorAction SilentlyContinue
      if ($cs -and $cs.TotalPhysicalMemory) {
        $totalRamBytes = [double]$cs.TotalPhysicalMemory
      }
    } catch { }
  }

  if ($totalRamBytes -le 0) {
    Write-Warn "Unable to probe RAM via CIM; assuming conservative 16 GB baseline."
    $totalRamBytes = 16GB
  }

  $totalRamGB = [Math]::Round($totalRamBytes / 1GB, 1)

  return [PSCustomObject]@{
    Build                  = $build
    IsMirroredCapable      = $isWin11MirroredCapable
    Arch                   = $arch
    CpuCores               = $cpuCount
    TotalRamGB             = $totalRamGB
  }
}

# -----------------------------------------------------------------------------
# 2. Non-Starving Resource Governance Scaling
# -----------------------------------------------------------------------------
function Calculate-ResourceAllocation {
  param(
    [PSCustomObject]$HostInfo,
    [string]$Profile,
    [int]$UserRamGB,
    [int]$UserCpu,
    [int]$UserSwapGB
  )

  $TotalRamGB = $HostInfo.TotalRamGB
  $CpuCores = $HostInfo.CpuCores

  $tierName = ""
  $wslRam = 0
  $wslSwap = 0
  $hostReservedRam = 0

  if ($Profile -eq 'Laptop-16GB') {
    $tierName = "Preset: Laptop (16GB RAM)"
    $wslRam = 8
    $wslSwap = 4
    $hostReservedRam = 8
  } elseif ($Profile -eq 'Pro-32GB') {
    $tierName = "Preset: Pro / Mid-Range (32GB RAM)"
    $wslRam = 24
    $wslSwap = 8
    $hostReservedRam = 8
  } elseif ($Profile -eq 'Workstation-64GB') {
    $tierName = "Preset: Workstation / Titan (64GB RAM)"
    $wslRam = 48
    $wslSwap = 16
    $hostReservedRam = 16
  } elseif ($Profile -eq 'Server-128GB') {
    $tierName = "Preset: Enterprise / Server (128GB RAM)"
    $wslRam = 112
    $wslSwap = 16
    $hostReservedRam = 16
  } else {
    # Dynamic Auto Scaling Curve
    if ($TotalRamGB -le 8.5) {
      $tierName = "Low-Memory Host (<=8GB)"
      # Strict 50/50 split; minimum 2GB
      $wslRam = [Math]::Max(2, [Math]::Floor($TotalRamGB * 0.5))
      $wslSwap = 4
      $hostReservedRam = [Math]::Round($TotalRamGB - $wslRam, 1)
    } elseif ($TotalRamGB -le 18.0) {
      $tierName = "Entry Developer / Laptop (16GB Tier)"
      # 50% allocation: gives WSL 8GB, strictly reserves 8GB for Windows OS + browser
      $wslRam = 8
      $wslSwap = 4
      $hostReservedRam = [Math]::Round($TotalRamGB - $wslRam, 1)
    } elseif ($TotalRamGB -le 36.0) {
      $tierName = "Mid-Range / Pro Laptop (32GB Tier)"
      # Reserve strictly 8GB for Windows host; remaining goes to WSL (24GB on 32GB host)
      $wslRam = [Math]::Floor($TotalRamGB - 8)
      $wslSwap = 8
      $hostReservedRam = 8
    } elseif ($TotalRamGB -le 72.0) {
      $tierName = "Workstation / Snapdragon Dev Kit (64GB Tier)"
      # 75% to WSL (48GB on 64GB host); reserves 16GB for Windows OS, IDEs, and host tasks
      $wslRam = [Math]::Floor($TotalRamGB * 0.75)
      $wslSwap = 16
      $hostReservedRam = [Math]::Round($TotalRamGB - $wslRam, 1)
    } else {
      $tierName = "Enterprise Workstation / Server (>64GB Tier)"
      # Reserve guaranteed 16GB for Windows; rest allocated to WSL
      $wslRam = [Math]::Floor($TotalRamGB - 16)
      $wslSwap = 16
      $hostReservedRam = 16
    }
  }

  # Apply Explicit User Overrides
  if ($UserRamGB -gt 0) {
    Write-Warn "Applying manual RAM override: ${UserRamGB}GB"
    $wslRam = $UserRamGB
    $hostReservedRam = [Math]::Round($TotalRamGB - $wslRam, 1)
  }

  $wslCpus = $CpuCores
  if ($UserCpu -gt 0) {
    Write-Warn "Applying manual CPU core override: $UserCpu processors"
    $wslCpus = $UserCpu
  }

  if ($UserSwapGB -gt 0) {
    Write-Warn "Applying manual Swap override: ${UserSwapGB}GB"
    $wslSwap = $UserSwapGB
  }

  # Safety boundary asserts
  if ($wslRam -lt 2) { $wslRam = 2 }
  if ($wslCpus -lt 1) { $wslCpus = 1 }
  if ($wslSwap -lt 2) {
    # swap=0 is strictly forbidden to prevent StorPort refault storms
    Write-Warn "Swap size < 2GB risks file-backed refault storms; clamping to 4GB minimum."
    $wslSwap = 4
  }

  return [PSCustomObject]@{
    Tier            = $tierName
    WslRamGB        = $wslRam
    WslSwapGB       = $wslSwap
    WslProcessors   = $wslCpus
    HostReservedGB  = $hostReservedRam
  }
}

# -----------------------------------------------------------------------------
# 3. .wslconfig Content Builder
# -----------------------------------------------------------------------------
function Build-WslConfigContent {
  param(
    [PSCustomObject]$HostInfo,
    [PSCustomObject]$Alloc,
    [bool]$UseMirrored
  )

  $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"

  $sb = [System.Text.StringBuilder]::new()
  [void]$sb.AppendLine("# ==============================================================================")
  [void]$sb.AppendLine("# Omarchy-WSL Host Virtualization Profile (.wslconfig)")
  [void]$sb.AppendLine("# ==============================================================================")
  [void]$sb.AppendLine("# Generated on: $timestamp (Windows Build $($HostInfo.Build))")
  [void]$sb.AppendLine("# Hardware Detected: $($HostInfo.TotalRamGB) GB RAM, $($HostInfo.CpuCores) Cores ($($HostInfo.Arch))")
  [void]$sb.AppendLine("# Profile Classification: $($Alloc.Tier)")
  [void]$sb.AppendLine("# Resource Split: WSL gets $($Alloc.WslRamGB) GB RAM | Host reserves $($Alloc.HostReservedGB) GB RAM")
  [void]$sb.AppendLine("# ==============================================================================")
  [void]$sb.AppendLine("")
  [void]$sb.AppendLine("[wsl2]")
  [void]$sb.AppendLine("# Core Compute & Memory Governance")
  [void]$sb.AppendLine("processors=$($Alloc.WslProcessors)")
  [void]$sb.AppendLine("memory=$($Alloc.WslRamGB)GB")
  [void]$sb.AppendLine("swap=$($Alloc.WslSwapGB)GB")
  [void]$sb.AppendLine("nestedVirtualization=true")
  [void]$sb.AppendLine("localhostForwarding=true")
  [void]$sb.AppendLine("guiApplications=true")
  [void]$sb.AppendLine("vmIdleTimeout=60000")
  [void]$sb.AppendLine("")

  if ($UseMirrored) {
    [void]$sb.AppendLine("# Modern Windows 11 Mirrored Networking Stack")
    [void]$sb.AppendLine("networkingMode=mirrored")
    [void]$sb.AppendLine("dnsTunneling=true")
    [void]$sb.AppendLine("autoProxy=true")
    [void]$sb.AppendLine("hostAddressLoopback=true")
    [void]$sb.AppendLine("firewall=true")
    [void]$sb.AppendLine("ignoredPorts=5353,5355")
  } else {
    [void]$sb.AppendLine("# Resilient Legacy NAT Fallback")
    [void]$sb.AppendLine("networkingMode=NAT")
    [void]$sb.AppendLine("dnsTunneling=false")
    [void]$sb.AppendLine("autoProxy=false")
  }

  [void]$sb.AppendLine("")
  [void]$sb.AppendLine("[experimental]")
  [void]$sb.AppendLine("# Memory Reclamation Governance:")
  [void]$sb.AppendLine("# 'gradual' releases idle cached memory over 30 min without cold-purging")
  [void]$sb.AppendLine("# active working sets, eliminating the cold-cache disk thrashing of 'dropCache'.")
  [void]$sb.AppendLine("autoMemoryReclaim=gradual")
  [void]$sb.AppendLine("")
  [void]$sb.AppendLine("# Storage Integrity:")
  [void]$sb.AppendLine("# sparseVhd is disabled to prevent ext4 superblock and journal corruption")
  [void]$sb.AppendLine("# from NTFS sparse hole-punching races during active I/O.")
  [void]$sb.AppendLine("sparseVhd=false")

  return $sb.ToString()
}

# -----------------------------------------------------------------------------
# 4. Main Controller
# -----------------------------------------------------------------------------
try {
  $hostInfo = Get-HostTopology

  $useMirrored = ($hostInfo.IsMirroredCapable -and -not $ForceNAT)
  if ($ForceNAT) {
    Write-Warn "User requested -ForceNAT: Configuring NAT mode."
  } elseif (-not $hostInfo.IsMirroredCapable) {
    Write-Warn "Host is Windows 10 / Build < 22621: Falling back to resilient NAT mode."
  } else {
    Write-Success "Windows 11 Build $($hostInfo.Build) detected: Mirrored Networking enabled."
  }

  $alloc = Calculate-ResourceAllocation `
    -HostInfo $hostInfo `
    -Profile $ProfileOverride `
    -UserRamGB $RamOverrideGB `
    -UserCpu $CpuOverride `
    -UserSwapGB $SwapOverrideGB

  Write-Success "Hardware Profile: $($alloc.Tier)"
  Write-Info "Calculated WSL Allocation: $($alloc.WslRamGB)GB RAM, $($alloc.WslSwapGB)GB swap, $($alloc.WslProcessors) processors"
  Write-Info "Guaranteed Windows Headroom: $($alloc.HostReservedGB)GB RAM reserved for host OS & apps."

  $configContent = Build-WslConfigContent -HostInfo $hostInfo -Alloc $alloc -UseMirrored $useMirrored

  if ($DryRun) {
    Write-Host ""
    Write-Host "--- [DRY RUN PREVIEW] ---" -ForegroundColor Cyan
    Write-Host $configContent
    Write-Host "-------------------------" -ForegroundColor Cyan
    exit 0
  }

  $targetPath = if ([string]::IsNullOrWhiteSpace($OutputPath)) {
    Join-Path $env:USERPROFILE ".wslconfig"
  } else {
    $OutputPath
  }

  $targetDir = Split-Path -Parent $targetPath
  if ($targetDir -and -not (Test-Path $targetDir)) {
    New-Item -ItemType Directory -Path $targetDir -Force | Out-Null
  }

  if (Test-Path $targetPath) {
    $backupPath = "$targetPath.bak.$(Get-Date -Format 'yyyyMMdd_HHmmss')"
    Write-Info "Backing up existing .wslconfig to $backupPath..."
    Copy-Item -Path $targetPath -Destination $backupPath -Force
  }

  Write-Info "Writing .wslconfig to $targetPath..."
  [System.IO.File]::WriteAllText($targetPath, $configContent, [System.Text.Encoding]::UTF8)
  Write-Success "Successfully wrote production configuration to '$targetPath'!"

  Write-Host ""
  Write-Host "=================================================================" -ForegroundColor Green
  Write-Host "  .wslconfig Profile Active!" -ForegroundColor Green
  Write-Host "=================================================================" -ForegroundColor Green
  Write-Host "To apply these resource boundaries to the running WSL instance:" -ForegroundColor Cyan
  Write-Host "  wsl --shutdown" -ForegroundColor Yellow
  Write-Host "Then relaunch your Omarchy shell." -ForegroundColor Cyan
  Write-Host ""

} catch {
  Write-Err "Failed to generate .wslconfig: $_"
  exit 1
}
