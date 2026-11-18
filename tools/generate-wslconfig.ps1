#requires -Version 5.1
<#
.SYNOPSIS
  Merge Omarchy-WSL's recommended WSL 2 settings into %USERPROFILE%\.wslconfig.

.DESCRIPTION
  Sizes memory, swap and processors from the Windows host (never from inside a
  WSL guest, which only sees the memory WSL already gave it), chooses mirrored
  or NAT networking from the Windows build, and merges the result into the
  existing .wslconfig:

    * Only the keys this script manages are written. Every other section, key,
      comment and blank line is kept exactly as it was.
    * A managed key found in the wrong section (for example hostAddressLoopback
      under [wsl2], where WSL reports "Unknown key" and ignores it), an old
      [experimental] spelling of a key that now lives in [wsl2], or a second
      copy of a managed key is commented out with a reason. Nothing is deleted.
    * The change is shown as a unified diff. The file is written only with
      -Force or after you answer "y". -DryRun never writes anything.
    * The previous file is copied to .wslconfig.bak-<yyyyMMdd-HHmmss>, the new
      content goes to a temporary file in the same directory and is then moved
      over the original.
    * Output is UTF-8 without a BOM, with CRLF line endings. WSL opens the file
      in text mode with ccs=UTF-8 (microsoft/WSL WslCoreConfig.cpp), so a BOM
      or LF-only endings would also work; CRLF is what WSL Settings writes and
      what Notepad expects.

  The script never runs `wsl --shutdown` (that would stop every running
  distribution). New settings take effect after the next WSL VM start.

  Profiles
    Desktop  Interactive workstation (default). WSLg stays on. vmIdleTimeout
             and instanceIdleTimeout are left alone, so WSL keeps its defaults:
             a distro stops 15 s after its last process exits and the VM 60 s
             after the last distro stops.
    Server   Headless, always-on host. Sets [wsl2] vmIdleTimeout=-1 and
             [general] instanceIdleTimeout=-1, so WSL never idle-stops the VM
             or the distro and systemd services, tmux, containers and sshd keep
             running with no session attached. vmIdleTimeout=-1 alone is not
             enough: the distro instance would still stop 15 s after its last
             client exits. Also sets guiApplications=false: a headless host has
             no use for the WSLg system distro (Weston, XWayland, PulseAudio and
             an RDP client to the Windows desktop); -KeepGui keeps it on.
             Combine with tools/register-wsl-autostart.ps1 to start the distro
             at logon or boot.

  Key placement, verified on 2026-11-18 against
  https://learn.microsoft.com/en-us/windows/wsl/wsl-config (page dated
  2026-10-16) and microsoft/WSL src/windows/common/WslCoreConfig.{h,cpp}:
    [wsl2]          memory processors swap nestedVirtualization guiApplications
                    vmIdleTimeout networkingMode dnsTunneling firewall autoProxy
                    localhostForwarding
    [general]       instanceIdleTimeout
    [experimental]  autoMemoryReclaim sparseVhd hostAddressLoopback ignoredPorts
  networkingMode, dnsTunneling, firewall and autoProxy were promoted to [wsl2];
  WSL still accepts the old [experimental] spelling as an alias. autoMemoryReclaim,
  sparseVhd, hostAddressLoopback and ignoredPorts exist only under [experimental].

  Never emitted: nestedVirtualization on ARM64 hosts or before Windows 11;
  localhostForwarding in mirrored mode (WSL ignores it there); hostAddressLoopback
  and ignoredPorts in NAT mode (they only apply to mirrored networking).

.PARAMETER Profile
  Desktop (default) or Server. See the description.

.PARAMETER HardwarePreset
  Auto (default) sizes from the detected RAM. The presets pin the allocation:
  Laptop-16GB, Pro-32GB, Workstation-64GB, Server-128GB. Memory is still clamped
  to the host's RAM minus -WindowsReserveGB. Alias: -ProfileOverride.

.PARAMETER RamOverrideGB
  Explicit WSL memory in GB (clamped to host RAM minus -WindowsReserveGB).

.PARAMETER CpuOverride
  Explicit processor count (clamped to the host's logical processor count).

.PARAMETER SwapOverrideGB
  Explicit swap size in GB. Values below 4 are raised to 4.

.PARAMETER WindowsReserveGB
  RAM that is never handed to WSL (default 4).

.PARAMETER ForceNAT
  Use NAT networking even where mirrored networking is available (for VPN
  clients that break with mirrored mode). Also turns dnsTunneling and autoProxy off.

.PARAMETER KeepGui
  With -Profile Server: keep guiApplications=true.

.PARAMETER WslConfigPath
  File to merge into (default %USERPROFILE%\.wslconfig). Alias: -OutputPath.

.PARAMETER HostMemoryGB
  Host RAM in GB instead of querying CIM. Required when not running on Windows.

.PARAMETER HostLogicalProcessors
  Host logical processor count instead of querying CIM.

.PARAMETER HostArch
  x64 or arm64 instead of detecting the host architecture.

.PARAMETER HostBuild
  Windows build number instead of reading it (22621+ enables mirrored mode).

.PARAMETER DryRun
  Show the plan and the diff and print the resulting file. Writes nothing.

.PARAMETER Force
  Write without asking for confirmation.

.PARAMETER Quiet
  Print nothing but the resulting file (with -DryRun) and errors.

.PARAMETER NoRun
  Define the functions and return (for tests that dot-source this script).

.EXAMPLE
  .\tools\generate-wslconfig.ps1 -DryRun

.EXAMPLE
  .\tools\generate-wslconfig.ps1 -Profile Server -Force

.EXAMPLE
  .\tools\generate-wslconfig.ps1 -DryRun -Quiet -HostMemoryGB 64 -HostLogicalProcessors 16 -HostArch arm64 -HostBuild 26100 -WslConfigPath ./test.wslconfig
#>

[CmdletBinding()]
param(
  [ValidateSet('Desktop', 'Server')]
  [string]$Profile = 'Desktop',

  [Alias('ProfileOverride')]
  [ValidateSet('Auto', 'Laptop-16GB', 'Pro-32GB', 'Workstation-64GB', 'Server-128GB')]
  [string]$HardwarePreset = 'Auto',

  [ValidateRange(0, 4096)]
  [int]$RamOverrideGB = 0,

  [ValidateRange(0, 4096)]
  [int]$CpuOverride = 0,

  [ValidateRange(0, 4096)]
  [int]$SwapOverrideGB = 0,

  [ValidateRange(1, 256)]
  [int]$WindowsReserveGB = 4,

  [switch]$ForceNAT,

  [switch]$KeepGui,

  [Alias('OutputPath')]
  [string]$WslConfigPath = '',

  [ValidateRange(0.0, 65536.0)]
  [double]$HostMemoryGB = 0,

  [ValidateRange(0, 4096)]
  [int]$HostLogicalProcessors = 0,

  [ValidateSet('Auto', 'x64', 'arm64')]
  [string]$HostArch = 'Auto',

  [ValidateRange(0, 999999)]
  [int]$HostBuild = 0,

  [switch]$DryRun,

  [switch]$Force,

  [switch]$Quiet,

  [switch]$NoRun
)

Set-StrictMode -Version 2.0

# -----------------------------------------------------------------------------
# Key -> section table. Source of truth: microsoft/WSL
# src/windows/common/WslCoreConfig.h (ConfigSetting::*), cross-checked with
# https://learn.microsoft.com/en-us/windows/wsl/wsl-config. Used to place every
# emitted key and to flag unknown or misplaced keys in an existing file.
# -----------------------------------------------------------------------------
$script:OmwWslKeySection = [ordered]@{
  # [wsl2]
  'kernel'                      = 'wsl2'
  'kernelCommandLine'           = 'wsl2'
  'kernelModules'               = 'wsl2'
  'memory'                      = 'wsl2'
  'processors'                  = 'wsl2'
  'swap'                        = 'wsl2'
  'swapFile'                    = 'wsl2'
  'debugConsole'                = 'wsl2'
  'earlyBootLogging'            = 'wsl2'
  'localhostForwarding'         = 'wsl2'
  'nestedVirtualization'        = 'wsl2'
  'virtio9p'                    = 'wsl2'
  'virtiofs'                    = 'wsl2'
  'kernelDebugPort'             = 'wsl2'
  'gpuSupport'                  = 'wsl2'
  'guiApplications'             = 'wsl2'
  'systemDistro'                = 'wsl2'
  'telemetry'                   = 'wsl2'
  'vmIdleTimeout'               = 'wsl2'
  'debugConsoleLogFile'         = 'wsl2'
  'kernelBootTimeout'           = 'wsl2'
  'distributionStartTimeout'    = 'wsl2'
  'virtio'                      = 'wsl2'
  'hostFileSystemAccess'        = 'wsl2'
  'mountDeviceTimeout'          = 'wsl2'
  'hardwarePerformanceCounters' = 'wsl2'
  'networkingMode'              = 'wsl2'
  'vmSwitch'                    = 'wsl2'
  'macAddress'                  = 'wsl2'
  'dhcp'                        = 'wsl2'
  'dhcpTimeout'                 = 'wsl2'
  'ipv6'                        = 'wsl2'
  'dnsProxy'                    = 'wsl2'
  'safeMode'                    = 'wsl2'
  'defaultVhdSize'              = 'wsl2'
  'crashDumpFolder'             = 'wsl2'
  'maxCrashDumpCount'           = 'wsl2'
  'dnsTunneling'                = 'wsl2'
  'firewall'                    = 'wsl2'
  'autoProxy'                   = 'wsl2'
  'loadKernelModules'           = 'wsl2'
  'loadDefaultKernelModules'    = 'wsl2'
  'isolateDistroCgroup'         = 'wsl2'
  # [general]
  'distributionInstallPath'     = 'general'
  'instanceIdleTimeout'         = 'general'
  # [experimental]
  'autoMemoryReclaim'           = 'experimental'
  'sparseVhd'                   = 'experimental'
  'bestEffortDnsParsing'        = 'experimental'
  'dnsTunnelingIpAddress'       = 'experimental'
  'initialAutoProxyTimeout'     = 'experimental'
  'ignoredPorts'                = 'experimental'
  'hostAddressLoopback'         = 'experimental'
  'setVersionDebug'             = 'experimental'
  'swiotlb'                     = 'experimental'
  'virtioFsAggregateShares'     = 'experimental'
}

# Old [experimental] spellings that WSL still reads as aliases of [wsl2] keys.
$script:OmwWslLegacyAlias = @('networkingMode', 'dnsTunneling', 'firewall', 'autoProxy')

$script:OmwQuiet = $false

function Write-OmwInfo([string]$Message) { if (-not $script:OmwQuiet) { Write-Host "[*] $Message" -ForegroundColor Cyan } }
function Write-OmwOk([string]$Message) { if (-not $script:OmwQuiet) { Write-Host "[+] $Message" -ForegroundColor Green } }
function Write-OmwNote([string]$Message) { if (-not $script:OmwQuiet) { Write-Host "[!] $Message" -ForegroundColor Yellow } }

# -----------------------------------------------------------------------------
# Pure helpers (no host access; unit-tested under pwsh on Linux)
# -----------------------------------------------------------------------------
function Get-OmwKeySection {
  param([Parameter(Mandatory = $true)][string]$Key)
  if ($script:OmwWslKeySection.Contains($Key)) { return $script:OmwWslKeySection[$Key] }
  return $null
}

function Resolve-OmwArch {
  # Any probe that reports ARM64 wins: x64 emulation on Windows on ARM hides
  # ARM64 from the process environment, never the other way round.
  param([AllowEmptyCollection()][AllowNull()][string[]]$Candidates)
  $values = @($Candidates | Where-Object { $_ } | ForEach-Object { $_.Trim().ToUpperInvariant() })
  if ($values -contains 'ARM64' -or $values -contains 'AARCH64') { return 'arm64' }
  if ($values -contains 'AMD64' -or $values -contains 'X64' -or $values -contains 'X86_64') { return 'x64' }
  throw ("Unsupported host architecture ({0}). WSL 2 distributions need x64 or arm64." -f ($values -join ', '))
}

function Get-OmwResourcePlan {
  param(
    [Parameter(Mandatory = $true)][double]$TotalRamGB,
    [Parameter(Mandatory = $true)][int]$LogicalProcessors,
    [string]$HardwarePreset = 'Auto',
    [int]$RamOverrideGB = 0,
    [int]$CpuOverride = 0,
    [int]$SwapOverrideGB = 0,
    [int]$WindowsReserveGB = 4
  )
  if ($TotalRamGB -le 0) { throw 'TotalRamGB must be positive.' }
  if ($LogicalProcessors -lt 1) { throw 'LogicalProcessors must be at least 1.' }

  $notes = New-Object System.Collections.Generic.List[string]
  switch ($HardwarePreset) {
    'Laptop-16GB' { $tier = 'Preset: Laptop (16GB RAM)'; $memory = 8; $swap = 4 }
    'Pro-32GB' { $tier = 'Preset: Pro (32GB RAM)'; $memory = 24; $swap = 8 }
    'Workstation-64GB' { $tier = 'Preset: Workstation (64GB RAM)'; $memory = 48; $swap = 16 }
    'Server-128GB' { $tier = 'Preset: Server (128GB RAM)'; $memory = 112; $swap = 16 }
    default {
      if ($TotalRamGB -le 8.5) {
        $tier = 'Low-memory host (8GB or less)'
        $memory = [Math]::Max(2, [Math]::Floor($TotalRamGB * 0.5)); $swap = 4
      } elseif ($TotalRamGB -le 18) {
        $tier = 'Laptop (16GB tier)'
        $memory = 8; $swap = 4
      } elseif ($TotalRamGB -le 36) {
        $tier = 'Pro (32GB tier)'
        $memory = [Math]::Floor($TotalRamGB - 8); $swap = 8
      } elseif ($TotalRamGB -le 72) {
        $tier = 'Workstation (64GB tier)'
        $memory = [Math]::Floor($TotalRamGB * 0.75); $swap = 16
      } else {
        $tier = 'Large workstation or server (more than 72GB)'
        $memory = [Math]::Floor($TotalRamGB - 16); $swap = 16
      }
    }
  }

  if ($RamOverrideGB -gt 0) { $memory = $RamOverrideGB; $notes.Add("memory override: ${RamOverrideGB}GB") }
  if ($SwapOverrideGB -gt 0) { $swap = $SwapOverrideGB; $notes.Add("swap override: ${SwapOverrideGB}GB") }

  $processors = $LogicalProcessors
  if ($CpuOverride -gt 0) {
    if ($CpuOverride -gt $LogicalProcessors) {
      $notes.Add("processor override $CpuOverride exceeds the host's $LogicalProcessors logical processors; using $LogicalProcessors")
    } else {
      $processors = $CpuOverride
      $notes.Add("processor override: $CpuOverride")
    }
  }

  # Never hand WSL more than the host's RAM minus the Windows reserve.
  $ceiling = [Math]::Floor($TotalRamGB - $WindowsReserveGB)
  if ($ceiling -lt 2) { $ceiling = [Math]::Max(1, [Math]::Floor($TotalRamGB / 2)) }
  if ($memory -gt $ceiling) {
    $notes.Add(("memory {0}GB exceeds host RAM ({1}GB) minus the {2}GB Windows reserve; using {3}GB" -f $memory, $TotalRamGB, $WindowsReserveGB, $ceiling))
    $memory = $ceiling
  }
  if ($memory -lt 1) { $memory = 1 }

  # swap=0 is refused: without swap, file-backed pages are refaulted from the
  # virtual disk under memory pressure, which stalls the whole VM.
  if ($swap -lt 4) {
    $notes.Add("swap ${swap}GB raised to the 4GB minimum")
    $swap = 4
  }

  [pscustomobject]@{
    Tier           = $tier
    MemoryGB       = [int]$memory
    SwapGB         = [int]$swap
    Processors     = [int]$processors
    HostRamGB      = $TotalRamGB
    HostReservedGB = [Math]::Round($TotalRamGB - $memory, 1)
    Notes          = $notes.ToArray()
  }
}

function New-OmwSetting {
  param([string]$Section, [string]$Key, [string]$Value)
  [pscustomobject]@{ Section = $Section; Key = $Key; Value = $Value }
}

function Get-OmwDesiredSettings {
  # Returns the managed settings, in output order: [wsl2], [general], [experimental].
  param(
    [Parameter(Mandatory = $true)]$Plan,
    [ValidateSet('Desktop', 'Server')][string]$ConfigProfile = 'Desktop',
    [ValidateSet('x64', 'arm64')][string]$Arch = 'x64',
    [int]$Build = 0,
    [switch]$ForceNAT,
    [switch]$KeepGui
  )
  $mirrored = ($Build -ge 22621) -and (-not $ForceNAT)
  $win11 = $Build -ge 22000
  $settings = New-Object System.Collections.Generic.List[object]

  $settings.Add((New-OmwSetting 'wsl2' 'memory' ('{0}GB' -f $Plan.MemoryGB)))
  $settings.Add((New-OmwSetting 'wsl2' 'processors' ([string]$Plan.Processors)))
  $settings.Add((New-OmwSetting 'wsl2' 'swap' ('{0}GB' -f $Plan.SwapGB)))
  # Nested virtualization needs Windows 11 on x64; ARM64 hosts do not support it.
  if ($Arch -eq 'x64' -and $win11) { $settings.Add((New-OmwSetting 'wsl2' 'nestedVirtualization' 'true')) }
  if ($ConfigProfile -eq 'Server' -and -not $KeepGui) {
    $settings.Add((New-OmwSetting 'wsl2' 'guiApplications' 'false'))
  } else {
    $settings.Add((New-OmwSetting 'wsl2' 'guiApplications' 'true'))
  }
  if ($ConfigProfile -eq 'Server') { $settings.Add((New-OmwSetting 'wsl2' 'vmIdleTimeout' '-1')) }
  if ($mirrored) {
    $settings.Add((New-OmwSetting 'wsl2' 'networkingMode' 'mirrored'))
    $settings.Add((New-OmwSetting 'wsl2' 'dnsTunneling' 'true'))
    $settings.Add((New-OmwSetting 'wsl2' 'firewall' 'true'))
    $settings.Add((New-OmwSetting 'wsl2' 'autoProxy' 'true'))
  } else {
    $settings.Add((New-OmwSetting 'wsl2' 'networkingMode' 'NAT'))
    $settings.Add((New-OmwSetting 'wsl2' 'dnsTunneling' 'false'))
    $settings.Add((New-OmwSetting 'wsl2' 'autoProxy' 'false'))
    $settings.Add((New-OmwSetting 'wsl2' 'localhostForwarding' 'true'))
  }

  if ($ConfigProfile -eq 'Server') { $settings.Add((New-OmwSetting 'general' 'instanceIdleTimeout' '-1')) }

  # gradual: hand idle page cache back to Windows slowly instead of dropping
  # it all at once (dropCache, the WSL default), which cold-starts every build.
  $settings.Add((New-OmwSetting 'experimental' 'autoMemoryReclaim' 'gradual'))
  # Sparse VHDs are opt-in and Microsoft gates converting a distro to sparse
  # behind --allow-unsafe; keep new VHDs fixed-allocation.
  $settings.Add((New-OmwSetting 'experimental' 'sparseVhd' 'false'))
  if ($mirrored) {
    $settings.Add((New-OmwSetting 'experimental' 'hostAddressLoopback' 'true'))
    # mDNS and LLMNR: Windows owns these ports; let Linux daemons bind them too.
    $settings.Add((New-OmwSetting 'experimental' 'ignoredPorts' '5353,5355'))
  }

  foreach ($s in $settings) {
    $expected = Get-OmwKeySection $s.Key
    if ($expected -ne $s.Section) { throw "Internal error: $($s.Key) belongs in [$expected], not [$($s.Section)]." }
  }
  return , $settings.ToArray()
}

function Split-OmwIniValue {
  # Splits "value  # comment" the way WSL's parser does: an unquoted # starts a
  # comment, backslash escapes the next character.
  param([AllowEmptyString()][string]$Rest)
  $inQuote = $false
  for ($i = 0; $i -lt $Rest.Length; $i++) {
    $c = $Rest[$i]
    if ($c -eq '\') { $i++; continue }
    if ($c -eq '"') { $inQuote = -not $inQuote; continue }
    if ($c -eq '#' -and -not $inQuote) {
      return [pscustomobject]@{ Value = $Rest.Substring(0, $i).Trim(); Comment = $Rest.Substring($i) }
    }
  }
  return [pscustomobject]@{ Value = $Rest.Trim(); Comment = '' }
}

function ConvertFrom-OmwIniText {
  # Line model of a .wslconfig. Kind: Blank, Comment, Section, Key or Other.
  param([AllowEmptyString()][AllowNull()][string]$Text)
  $lines = New-Object System.Collections.Generic.List[object]
  if ([string]::IsNullOrEmpty($Text)) { return , $lines.ToArray() }
  if ($Text[0] -eq [char]0xFEFF) { $Text = $Text.Substring(1) }
  $raw = New-Object System.Collections.Generic.List[string]
  $raw.AddRange([string[]][regex]::Split($Text, "\r\n|\n|\r"))
  if ($raw.Count -gt 0 -and $raw[$raw.Count - 1] -eq '') { $raw.RemoveAt($raw.Count - 1) }

  $section = ''
  foreach ($line in $raw) {
    $t = $line.TrimStart(' ', "`t")
    $entry = [pscustomobject]@{ Raw = $line; Kind = 'Other'; Section = $section; Key = $null; Value = $null; Comment = '' }
    if ($t.Length -eq 0) {
      $entry.Kind = 'Blank'
    } elseif ($t[0] -eq '#') {
      $entry.Kind = 'Comment'
    } elseif ($t -match '^\[\s*([A-Za-z][A-Za-z0-9]*)\s*\]\s*(#.*)?$') {
      $section = $Matches[1].ToLowerInvariant()
      $entry.Kind = 'Section'
      $entry.Section = $section
    } elseif ($t -match '^([A-Za-z][A-Za-z0-9]*)\s*=(.*)$') {
      $parts = Split-OmwIniValue $Matches[2]
      $entry.Kind = 'Key'
      $entry.Key = $Matches[1]
      $entry.Value = $parts.Value
      $entry.Comment = $parts.Comment
    }
    $lines.Add($entry)
  }
  return , $lines.ToArray()
}

function Merge-OmwWslConfig {
  # Merges the desired settings into existing .wslconfig text. Returns
  # Text (CRLF, final newline), Lines, Changes and Notices.
  param(
    [AllowEmptyString()][AllowNull()][string]$ExistingText,
    [Parameter(Mandatory = $true)][object[]]$Desired,
    [string[]]$NewFileHeader = @()
  )
  $parsed = ConvertFrom-OmwIniText $ExistingText
  $wanted = @{}
  $managed = @{}
  foreach ($d in $Desired) {
    $wanted[('{0}.{1}' -f $d.Section, $d.Key)] = $d
    $managed[$d.Key] = $d
  }
  $done = @{}
  $anchor = @{}
  $out = New-Object System.Collections.Generic.List[string]
  $changes = New-Object System.Collections.Generic.List[string]
  $notices = New-Object System.Collections.Generic.List[string]

  if ($parsed.Count -eq 0) { foreach ($h in $NewFileHeader) { $out.Add($h) } }

  foreach ($l in $parsed) {
    if ($l.Kind -eq 'Section') {
      $out.Add($l.Raw)
      $anchor[$l.Section] = $out.Count - 1
      continue
    }
    if ($l.Kind -ne 'Key') { $out.Add($l.Raw); continue }

    $id = '{0}.{1}' -f $l.Section, $l.Key
    $where = if ($l.Section) { "[$($l.Section)]" } else { '(no section)' }
    if ($wanted.ContainsKey($id)) {
      $d = $wanted[$id]
      if ($done.ContainsKey($id)) {
        $out.Add(('# disabled by omarchy-wsl (duplicate {0} {1}; WSL only reads the first): {2}' -f $where, $d.Key, $l.Raw.Trim()))
        $changes.Add("disabled duplicate $where $($l.Key)")
      } else {
        $done[$id] = $true
        if ($l.Value -ieq $d.Value) {
          $out.Add($l.Raw)
        } else {
          $line = '{0}={1}' -f $d.Key, $d.Value
          if ($l.Comment) { $line = '{0} {1}' -f $line, $l.Comment }
          $out.Add($line)
          $changes.Add(('set [{0}] {1}={2} (was {3})' -f $d.Section, $d.Key, $d.Value, $l.Value))
        }
      }
    } elseif ($managed.ContainsKey($l.Key)) {
      $d = $managed[$l.Key]
      $reason = 'WSL reads {0} from [{1}]' -f $d.Key, $d.Section
      if ($l.Section -eq 'experimental' -and $script:OmwWslLegacyAlias -contains $l.Key) {
        $reason = 'old [experimental] spelling of [{0}] {1}' -f $d.Section, $d.Key
      }
      $out.Add(('# disabled by omarchy-wsl ({0}): {1}' -f $reason, $l.Raw.Trim()))
      $changes.Add("disabled $where $($l.Key): moved to [$($d.Section)]")
    } else {
      $out.Add($l.Raw)
      $known = Get-OmwKeySection $l.Key
      if ($null -eq $known) {
        $notices.Add("$where $($l.Key) is not a key current WSL knows; WSL warns about it at every start (left unchanged)")
      } elseif ($known -ne $l.Section -and -not ($l.Section -eq 'experimental' -and $script:OmwWslLegacyAlias -contains $l.Key)) {
        $notices.Add("$where $($l.Key) belongs in [$known]; WSL ignores it where it is (left unchanged)")
      }
    }
    if ($l.Section) { $anchor[$l.Section] = $out.Count - 1 }
  }

  $pending = [ordered]@{}
  foreach ($d in $Desired) {
    if ($done.ContainsKey(('{0}.{1}' -f $d.Section, $d.Key))) { continue }
    if (-not $pending.Contains($d.Section)) { $pending[$d.Section] = New-Object System.Collections.Generic.List[string] }
    $pending[$d.Section].Add(('{0}={1}' -f $d.Key, $d.Value))
    $changes.Add(('add [{0}] {1}={2}' -f $d.Section, $d.Key, $d.Value))
  }
  $existingSections = @($pending.Keys | Where-Object { $anchor.ContainsKey($_) } | Sort-Object -Property @{ Expression = { $anchor[$_] } } -Descending)
  foreach ($section in $existingSections) {
    $out.InsertRange($anchor[$section] + 1, $pending[$section])
  }
  foreach ($section in @($pending.Keys)) {
    if ($anchor.ContainsKey($section)) { continue }
    if ($out.Count -gt 0 -and $out[$out.Count - 1].Trim().Length -gt 0) { $out.Add('') }
    $out.Add("[$section]")
    $out.AddRange($pending[$section])
  }

  [pscustomobject]@{
    Text    = ($out.ToArray() -join "`r`n") + "`r`n"
    Lines   = $out.ToArray()
    Changes = $changes.ToArray()
    Notices = $notices.ToArray()
  }
}

function Get-OmwUnifiedDiff {
  # Minimal unified diff (LCS based); .wslconfig files are small.
  param(
    [AllowEmptyCollection()][string[]]$OldLines = @(),
    [AllowEmptyCollection()][string[]]$NewLines = @(),
    [string]$OldLabel = 'a/.wslconfig',
    [string]$NewLabel = 'b/.wslconfig',
    [int]$Context = 3
  )
  if ($null -eq $OldLines) { $OldLines = @() }
  if ($null -eq $NewLines) { $NewLines = @() }
  $n = $OldLines.Count
  $m = $NewLines.Count
  $lcs = New-Object 'int[][]' ($n + 1)
  for ($i = 0; $i -le $n; $i++) { $lcs[$i] = New-Object 'int[]' ($m + 1) }
  for ($i = $n - 1; $i -ge 0; $i--) {
    for ($j = $m - 1; $j -ge 0; $j--) {
      if ($OldLines[$i] -ceq $NewLines[$j]) { $lcs[$i][$j] = $lcs[$i + 1][$j + 1] + 1 }
      elseif ($lcs[$i + 1][$j] -ge $lcs[$i][$j + 1]) { $lcs[$i][$j] = $lcs[$i + 1][$j] }
      else { $lcs[$i][$j] = $lcs[$i][$j + 1] }
    }
  }
  # ops: Op (' ', '-', '+'), Old (old lines before this op), New, Text
  $ops = New-Object System.Collections.Generic.List[object]
  $i = 0; $j = 0
  while ($i -lt $n -and $j -lt $m) {
    if ($OldLines[$i] -ceq $NewLines[$j]) { $ops.Add(@(' ', $i, $j, $OldLines[$i])); $i++; $j++ }
    elseif ($lcs[$i + 1][$j] -ge $lcs[$i][$j + 1]) { $ops.Add(@('-', $i, $j, $OldLines[$i])); $i++ }
    else { $ops.Add(@('+', $i, $j, $NewLines[$j])); $j++ }
  }
  while ($i -lt $n) { $ops.Add(@('-', $i, $j, $OldLines[$i])); $i++ }
  while ($j -lt $m) { $ops.Add(@('+', $i, $j, $NewLines[$j])); $j++ }

  $changed = @(for ($k = 0; $k -lt $ops.Count; $k++) { if ($ops[$k][0] -ne ' ') { $k } })
  if ($changed.Count -eq 0) { return , @() }

  $result = New-Object System.Collections.Generic.List[string]
  $result.Add("--- $OldLabel")
  $result.Add("+++ $NewLabel")
  $c = 0
  while ($c -lt $changed.Count) {
    $start = [Math]::Max(0, $changed[$c] - $Context)
    $last = $changed[$c]
    while (($c + 1) -lt $changed.Count -and ($changed[$c + 1] - $last) -le (2 * $Context)) { $c++; $last = $changed[$c] }
    $end = [Math]::Min($ops.Count - 1, $last + $Context)
    $oldCount = 0; $newCount = 0
    $body = New-Object System.Collections.Generic.List[string]
    for ($k = $start; $k -le $end; $k++) {
      $op = $ops[$k]
      if ($op[0] -ne '+') { $oldCount++ }
      if ($op[0] -ne '-') { $newCount++ }
      $body.Add($op[0] + $op[3])
    }
    $oldStart = $ops[$start][1]; if ($oldCount -gt 0) { $oldStart++ }
    $newStart = $ops[$start][2]; if ($newCount -gt 0) { $newStart++ }
    $result.Add(('@@ -{0},{1} +{2},{3} @@' -f $oldStart, $oldCount, $newStart, $newCount))
    $result.AddRange($body)
    $c++
  }
  return , $result.ToArray()
}

function Get-OmwNormalizedText {
  param([AllowEmptyString()][AllowNull()][string]$Text)
  if ([string]::IsNullOrEmpty($Text)) { return '' }
  if ($Text[0] -eq [char]0xFEFF) { $Text = $Text.Substring(1) }
  $t = [regex]::Replace($Text, "\r\n|\n|\r", "`r`n")
  if (-not $t.EndsWith("`r`n")) { $t += "`r`n" }
  return $t
}

# -----------------------------------------------------------------------------
# Host access
# -----------------------------------------------------------------------------
function Test-OmwWindows {
  if ($PSVersionTable.PSEdition -ne 'Core') { return $true }
  return [bool](Get-Variable -Name IsWindows -ValueOnly -ErrorAction SilentlyContinue)
}

function Get-OmwHostFacts {
  param([double]$MemoryGB = 0, [int]$LogicalProcessors = 0, [string]$Arch = 'Auto', [int]$Build = 0)
  $onWindows = Test-OmwWindows
  if ($MemoryGB -le 0) {
    if (-not $onWindows) { throw 'Not running on Windows: pass -HostMemoryGB (and -HostLogicalProcessors, -HostArch, -HostBuild).' }
    $bytes = 0.0
    try {
      foreach ($module in @(Get-CimInstance -ClassName Win32_PhysicalMemory -ErrorAction Stop)) { $bytes += [double]$module.Capacity }
    } catch { $bytes = 0.0 }
    if ($bytes -le 0) {
      try { $bytes = [double](Get-CimInstance -ClassName Win32_ComputerSystem -ErrorAction Stop).TotalPhysicalMemory } catch { $bytes = 0.0 }
    }
    if ($bytes -le 0) { throw 'Could not read the installed RAM through CIM. Pass -HostMemoryGB <GB>.' }
    $MemoryGB = [Math]::Round($bytes / 1GB, 1)
  }
  if ($LogicalProcessors -le 0) {
    $LogicalProcessors = [Environment]::ProcessorCount
    if ($onWindows) {
      try {
        $count = [int](Get-CimInstance -ClassName Win32_ComputerSystem -ErrorAction Stop).NumberOfLogicalProcessors
        if ($count -gt 0) { $LogicalProcessors = $count }
      } catch { }
    }
  }
  if ($Arch -eq 'Auto') {
    if (-not $onWindows) { throw 'Not running on Windows: pass -HostArch x64|arm64.' }
    $candidates = @()
    try { $candidates += [Environment]::GetEnvironmentVariable('PROCESSOR_ARCHITECTURE', 'Machine') } catch { }
    $candidates += $env:PROCESSOR_ARCHITEW6432
    $candidates += $env:PROCESSOR_ARCHITECTURE
    try { $candidates += [string][System.Runtime.InteropServices.RuntimeInformation]::OSArchitecture } catch { }
    $Arch = Resolve-OmwArch $candidates
  }
  if ($Build -le 0) {
    if (-not $onWindows) { throw 'Not running on Windows: pass -HostBuild <build number>.' }
    $Build = [Environment]::OSVersion.Version.Build
  }
  [pscustomobject]@{ MemoryGB = $MemoryGB; LogicalProcessors = $LogicalProcessors; Arch = $Arch; Build = $Build }
}

function Read-OmwTextFile {
  # Returns $null when the file does not exist. Accepts UTF-8 (with or without
  # BOM) and UTF-16 with BOM; refuses anything that is not valid UTF-8.
  param([Parameter(Mandatory = $true)][string]$Path)
  if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $null }
  $bytes = [System.IO.File]::ReadAllBytes($Path)
  if ($bytes.Length -ge 2 -and $bytes[0] -eq 0xFF -and $bytes[1] -eq 0xFE) { return [System.Text.Encoding]::Unicode.GetString($bytes, 2, $bytes.Length - 2) }
  if ($bytes.Length -ge 2 -and $bytes[0] -eq 0xFE -and $bytes[1] -eq 0xFF) { return [System.Text.Encoding]::BigEndianUnicode.GetString($bytes, 2, $bytes.Length - 2) }
  $offset = 0
  if ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) { $offset = 3 }
  try {
    return (New-Object System.Text.UTF8Encoding($false, $true)).GetString($bytes, $offset, $bytes.Length - $offset)
  } catch {
    throw "$Path is not valid UTF-8 text. WSL reads .wslconfig as UTF-8; re-save it as UTF-8 and run this script again."
  }
}

function Write-OmwFileAtomic {
  param([Parameter(Mandatory = $true)][string]$Path, [Parameter(Mandatory = $true)][string]$Text)
  $dir = Split-Path -Parent $Path
  if ($dir -and -not (Test-Path -LiteralPath $dir)) { [void](New-Item -ItemType Directory -Path $dir -Force) }
  $tmp = Join-Path $dir ('.wslconfig.tmp-' + [guid]::NewGuid().ToString('N'))
  try {
    [System.IO.File]::WriteAllText($tmp, $Text, (New-Object System.Text.UTF8Encoding($false)))
    if (Test-Path -LiteralPath $Path) {
      try {
        # ReplaceFile keeps the original file's ACL and attributes.
        [System.IO.File]::Replace($tmp, $Path, [System.Management.Automation.Language.NullString]::Value)
      } catch {
        Move-Item -LiteralPath $tmp -Destination $Path -Force
      }
    } else {
      Move-Item -LiteralPath $tmp -Destination $Path
    }
  } finally {
    if (Test-Path -LiteralPath $tmp) { Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue }
  }
}

function Backup-OmwFile {
  param([Parameter(Mandatory = $true)][string]$Path)
  $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
  $backup = '{0}.bak-{1}' -f $Path, $stamp
  $n = 1
  while (Test-Path -LiteralPath $backup) { $n++; $backup = '{0}.bak-{1}-{2}' -f $Path, $stamp, $n }
  Copy-Item -LiteralPath $Path -Destination $backup
  return $backup
}

function Confirm-OmwWrite {
  param([string]$Path)
  try {
    $answer = Read-Host "Write these changes to $Path? [y/N]"
  } catch {
    return $false
  }
  return ([string]$answer).Trim() -match '^(y|yes)\z'
}

function Invoke-OmwWslConfigGenerator {
  param(
    [string]$ConfigProfile = 'Desktop',
    [string]$HardwarePreset = 'Auto',
    [int]$RamOverrideGB = 0,
    [int]$CpuOverride = 0,
    [int]$SwapOverrideGB = 0,
    [int]$WindowsReserveGB = 4,
    [switch]$ForceNAT,
    [switch]$KeepGui,
    [string]$WslConfigPath = '',
    [double]$HostMemoryGB = 0,
    [int]$HostLogicalProcessors = 0,
    [string]$HostArch = 'Auto',
    [int]$HostBuild = 0,
    [switch]$DryRun,
    [switch]$Force
  )
  $ErrorActionPreference = 'Stop'

  $facts = Get-OmwHostFacts -MemoryGB $HostMemoryGB -LogicalProcessors $HostLogicalProcessors -Arch $HostArch -Build $HostBuild
  $plan = Get-OmwResourcePlan -TotalRamGB $facts.MemoryGB -LogicalProcessors $facts.LogicalProcessors -HardwarePreset $HardwarePreset `
    -RamOverrideGB $RamOverrideGB -CpuOverride $CpuOverride -SwapOverrideGB $SwapOverrideGB -WindowsReserveGB $WindowsReserveGB
  $desired = Get-OmwDesiredSettings -Plan $plan -ConfigProfile $ConfigProfile -Arch $facts.Arch -Build $facts.Build -ForceNAT:$ForceNAT -KeepGui:$KeepGui
  $mirrored = ($facts.Build -ge 22621) -and (-not $ForceNAT)

  if ($WslConfigPath) {
    $target = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($WslConfigPath)
  } elseif (Test-OmwWindows) {
    if (-not $env:USERPROFILE) { throw 'USERPROFILE is not set; pass -WslConfigPath.' }
    $target = Join-Path $env:USERPROFILE '.wslconfig'
  } elseif ($DryRun) {
    $target = $null
  } else {
    throw 'Not running on Windows: pass -WslConfigPath (or use -DryRun).'
  }

  $existing = $null
  if ($target) { $existing = Read-OmwTextFile -Path $target }
  $label = if ($target) { $target } else { '%USERPROFILE%\.wslconfig' }

  Write-OmwInfo ("Host: {0}GB RAM, {1} logical processors, {2}, Windows build {3}" -f $facts.MemoryGB, $facts.LogicalProcessors, $facts.Arch, $facts.Build)
  Write-OmwInfo ("Profile: {0}. Sizing: {1} -> memory {2}GB, swap {3}GB, {4} processors; {5}GB stays with Windows" -f $ConfigProfile, $plan.Tier, $plan.MemoryGB, $plan.SwapGB, $plan.Processors, $plan.HostReservedGB)
  if ($mirrored) {
    Write-OmwInfo 'Networking: mirrored (Windows 11 22H2 or later)'
  } elseif ($ForceNAT) {
    Write-OmwInfo 'Networking: NAT (-ForceNAT)'
  } else {
    Write-OmwInfo ("Networking: NAT (mirrored mode needs Windows 11 22H2, build 22621; this is build {0})" -f $facts.Build)
  }
  foreach ($note in $plan.Notes) { Write-OmwNote $note }

  $header = @(
    '# .wslconfig: WSL 2 settings for this Windows user.',
    '# Reference: https://learn.microsoft.com/en-us/windows/wsl/wsl-config',
    ('# Written by Omarchy-WSL tools/generate-wslconfig.ps1 (-Profile {0}). Running it again' -f $ConfigProfile),
    '# updates only the keys it manages and keeps every other line.',
    ''
  )
  $merge = Merge-OmwWslConfig -ExistingText $existing -Desired $desired -NewFileHeader $header
  foreach ($notice in $merge.Notices) { Write-OmwNote $notice }

  if ($ConfigProfile -eq 'Desktop') {
    foreach ($l in (ConvertFrom-OmwIniText $existing)) {
      if ($l.Kind -eq 'Key' -and ($l.Key -eq 'vmIdleTimeout' -or $l.Key -eq 'instanceIdleTimeout') -and $l.Value -eq '-1') {
        Write-OmwNote ("[{0}] {1}=-1 is a Server-profile setting; the Desktop profile leaves it unchanged" -f $l.Section, $l.Key)
      }
    }
  }

  $oldNormalized = Get-OmwNormalizedText $existing
  if ($null -ne $existing -and $oldNormalized -ceq $merge.Text) {
    Write-OmwOk "$label is already up to date; nothing to write."
    if ($DryRun) { Write-Output $merge.Text }
    return
  }

  $oldLines = New-Object System.Collections.Generic.List[string]
  if ($null -ne $existing) { foreach ($l in (ConvertFrom-OmwIniText $existing)) { $oldLines.Add($l.Raw) } }
  if (-not $script:OmwQuiet) {
    Write-Host ''
    foreach ($line in (Get-OmwUnifiedDiff -OldLines $oldLines.ToArray() -NewLines $merge.Lines -OldLabel "$label (current)" -NewLabel "$label (new)")) {
      $color = 'Gray'
      if ($line.StartsWith('+')) { $color = 'Green' } elseif ($line.StartsWith('-')) { $color = 'Red' } elseif ($line.StartsWith('@@')) { $color = 'Cyan' }
      Write-Host $line -ForegroundColor $color
    }
    Write-Host ''
  }

  if ($DryRun) {
    Write-OmwInfo 'Dry run: nothing was written. Resulting file:'
    Write-Output $merge.Text
    return
  }

  if (-not $Force -and -not (Confirm-OmwWrite -Path $target)) {
    Write-OmwNote "No changes written. Re-run with -Force to write $target without asking."
    return
  }

  if ($null -ne $existing) {
    $backup = Backup-OmwFile -Path $target
    Write-OmwOk "Backed up the previous file to $backup"
  }
  Write-OmwFileAtomic -Path $target -Text $merge.Text
  Write-OmwOk "Wrote $target"
  Write-OmwInfo 'WSL reads .wslconfig when its VM starts. To apply now, save your work in every'
  Write-OmwInfo 'distribution and run: wsl --shutdown'
}

if (-not $NoRun) {
  $script:OmwQuiet = [bool]$Quiet
  Invoke-OmwWslConfigGenerator -ConfigProfile $Profile -HardwarePreset $HardwarePreset -RamOverrideGB $RamOverrideGB `
    -CpuOverride $CpuOverride -SwapOverrideGB $SwapOverrideGB -WindowsReserveGB $WindowsReserveGB -ForceNAT:$ForceNAT `
    -KeepGui:$KeepGui -WslConfigPath $WslConfigPath -HostMemoryGB $HostMemoryGB -HostLogicalProcessors $HostLogicalProcessors `
    -HostArch $HostArch -HostBuild $HostBuild -DryRun:$DryRun -Force:$Force
}
