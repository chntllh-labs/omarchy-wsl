#requires -Version 5.1
<#
.SYNOPSIS
  Install Omarchy-WSL from a GitHub release.

.DESCRIPTION
  Run from a normal (not elevated) PowerShell window:

    irm https://raw.githubusercontent.com/chntllh-labs/omarchy-wsl/main/install/install.ps1 | iex

  With parameters:

    & ([scriptblock]::Create((irm https://raw.githubusercontent.com/chntllh-labs/omarchy-wsl/main/install/install.ps1))) -DistroName Omarchy-Dev -VerifyAttestation

  Steps:
    1. Checks the host: 64-bit Windows 10 2004 (build 19041) or later with WSL
       installed. The installer never elevates. If WSL is missing it stops and
       tells you to run `wsl --install --no-distribution` as administrator.
    2. Picks the image for this machine: Omarchy-x86_64.wsl on x64 or
       Omarchy-arm64.wsl on ARM64 (ARM64 is detected even from emulated x64
       PowerShell).
    3. Reads the release (latest, or -ReleaseTag) from the GitHub API, then
       downloads SHA256SUMS and the image from that same release and compares
       the SHA-256 before WSL sees the file.
    4. With -VerifyAttestation, runs `gh attestation verify` on the image (needs
       the GitHub CLI, signed in). Otherwise it prints the commands for the
       optional provenance and signature checks.
    5. Installs with `wsl --install --from-file <image> --name <name>`
       (WSL 2.4.4 or later), which runs Omarchy's first-start setup (OOBE).
       Older WSL gets `wsl --import`; WSL skips the OOBE for imported
       distributions, so Omarchy's first-boot profile hook runs the setup on
       the first interactive root login instead.
    6. Checks that the distribution boots.

  If a distribution with the same name exists, the installer offers to update
  it in place (runs `omarchy-update` inside it), to install a second copy next
  to it, or to stop. With -NonInteractive it stops unless -ForceSideBySide.

  What the checksum proves: SHA256SUMS is published with the image in the same
  GitHub release, so a match proves the download is complete and unmodified in
  transit, not who built it. The release workflow also publishes SLSA build
  provenance (GitHub artifact attestations) for the images and a Sigstore
  (cosign keyless) signature of SHA256SUMS; verifying either proves the files
  came from this repository's release workflow.

  This script never calls `exit` (under `irm | iex` that would close your
  PowerShell window). Failures are reported as terminating errors, so
  `powershell -File install.ps1` still exits non-zero.

.PARAMETER DistroName
  Name to register (default Omarchy).

.PARAMETER ReleaseTag
  Release to install: latest (default) or a tag such as v4.5.0.

.PARAMETER InstallPath
  Directory for the distribution's virtual disk (default: chosen by WSL; for
  `wsl --import`, %LOCALAPPDATA%\wsl\<DistroName>).

.PARAMETER Repo
  GitHub repository (default chntllh-labs/omarchy-wsl).

.PARAMETER NonInteractive
  Never prompt. Implies -NoLaunch.

.PARAMETER ForceSideBySide
  If the name is taken, install as <DistroName>-1, -2, ... instead.

.PARAMETER VerifyAttestation
  Also verify the image's build provenance with `gh attestation verify`.

.PARAMETER NoLaunch
  Register only; the first-start setup runs the first time you open the distribution.

.PARAMETER NoRun
  Define the functions and return (for tests that dot-source this script).
#>

[CmdletBinding()]
param(
  [ValidatePattern('^[A-Za-z0-9._-]{1,64}\z')]
  [string]$DistroName = 'Omarchy',

  [ValidatePattern('^(latest|v[0-9]+(\.[0-9]+){1,3}([-+][0-9A-Za-z.-]{1,32})?)\z')]
  [string]$ReleaseTag = 'latest',

  [ValidatePattern('^[^"\x00-\x1f]{0,240}\z')]
  [string]$InstallPath = '',

  [ValidatePattern('^[A-Za-z0-9][A-Za-z0-9-]{0,38}/[A-Za-z0-9._-]{1,100}\z')]
  [string]$Repo = 'chntllh-labs/omarchy-wsl',

  [switch]$NonInteractive,

  [switch]$ForceSideBySide,

  [switch]$VerifyAttestation,

  [switch]$NoLaunch,

  [switch]$NoRun
)

$script:OmwDistroNamePattern = '^[A-Za-z0-9._-]{1,64}\z'
$script:OmwMinFromFileVersion = [version]'2.4.4'

function Write-OmwStep([string]$Message) { Write-Host "[*] $Message" -ForegroundColor Cyan }
function Write-OmwOk([string]$Message) { Write-Host "[+] $Message" -ForegroundColor Green }
function Write-OmwWarn([string]$Message) { Write-Host "[!] $Message" -ForegroundColor Yellow }
function Write-OmwFail([string]$Message) { Write-Host "[-] $Message" -ForegroundColor Red }

function Write-OmwBanner {
  $banner = @'

   ___                            _
  / _ \ _ __ ___   __ _ _ __ ___| |__  _   _
 | | | | '_ ` _ \ / _` | '__/ __| '_ \| | | |
 | |_| | | | | | | (_| | | | (__| | | | |_| |
  \___/|_| |_| |_|\__,_|_|  \___|_| |_|\__, |
                                       |___/   for WSL

'@
  Write-Host $banner -ForegroundColor Cyan
}

# -----------------------------------------------------------------------------
# Pure helpers (unit-tested under pwsh on Linux; no host access)
# -----------------------------------------------------------------------------
function Resolve-OmwHostArchitecture {
  # Any probe reporting ARM64 wins: x64 emulation on Windows on ARM shows AMD64
  # to the process, never the other way round. Returns x86_64 or arm64.
  param([AllowNull()][AllowEmptyCollection()][string[]]$Candidates)
  $values = @($Candidates | Where-Object { $_ } | ForEach-Object { $_.Trim().ToUpperInvariant() })
  if ($values -contains 'ARM64' -or $values -contains 'AARCH64') { return 'arm64' }
  if ($values -contains 'AMD64' -or $values -contains 'X64' -or $values -contains 'X86_64') { return 'x86_64' }
  throw ("Unsupported CPU architecture ({0}). Omarchy-WSL ships x86_64 and arm64 images." -f ($values -join ', '))
}

function Get-OmwAssetName {
  param([Parameter(Mandatory = $true)][string]$Architecture)
  switch -Regex ($Architecture.Trim()) {
    '^(?i:x86_64|amd64|x64)\z' { return 'Omarchy-x86_64.wsl' }
    '^(?i:arm64|aarch64)\z' { return 'Omarchy-arm64.wsl' }
    default { throw "No Omarchy-WSL image for architecture '$Architecture' (x86_64 and arm64 only)." }
  }
}

function ConvertFrom-OmwSha256Sums {
  # Parses GNU coreutils sha256sum output ("<hash>  <name>" or "<hash> *<name>").
  # Returns an ordinal (case-sensitive) name -> lowercase hash dictionary.
  param([AllowEmptyString()][AllowNull()][string]$Text)
  $map = New-Object 'System.Collections.Generic.Dictionary[string,string]' ([System.StringComparer]::Ordinal)
  if ([string]::IsNullOrEmpty($Text)) { return , $map }
  foreach ($raw in [regex]::Split($Text, "\r\n|\n|\r")) {
    $line = $raw.Trim()
    if (-not $line -or $line.StartsWith('#')) { continue }
    if ($line -notmatch '^([0-9A-Fa-f]{64}) [ *](.+)\z') { continue }
    $hash = $Matches[1].ToLowerInvariant()
    $name = $Matches[2]
    if ($name.StartsWith('./')) { $name = $name.Substring(2) }
    if ($map.ContainsKey($name) -and $map[$name] -ne $hash) { throw "SHA256SUMS lists '$name' twice with different hashes." }
    $map[$name] = $hash
  }
  return , $map
}

function Get-OmwExpectedSha256 {
  param([Parameter(Mandatory = $true)]$Sums, [Parameter(Mandatory = $true)][string]$Name)
  if (-not $Sums.ContainsKey($Name)) { throw "SHA256SUMS has no entry for '$Name'; refusing to install an unverified image." }
  return $Sums[$Name]
}

function ConvertFrom-OmwWslVersionText {
  # First version number in `wsl --version` output (localized; first line is the WSL version).
  param([AllowNull()][AllowEmptyCollection()][object[]]$Lines)
  foreach ($line in @($Lines)) {
    if ($null -eq $line) { continue }
    $clean = ([string]$line) -replace "`0", ''
    if ($clean -match '([0-9]+\.[0-9]+\.[0-9]+(\.[0-9]+)?)') { return [version]$Matches[1] }
  }
  return $null
}

function Test-OmwFromFileSupported {
  param([AllowNull()][version]$Version)
  if ($null -eq $Version) { return $false }
  return ($Version -ge $script:OmwMinFromFileVersion)
}

function ConvertFrom-OmwWslList {
  # `wsl.exe --list --quiet` prints UTF-16LE unless WSL_UTF8=1; strip NULs either way.
  param([AllowNull()][AllowEmptyCollection()][object[]]$Lines)
  $names = New-Object System.Collections.Generic.List[string]
  foreach ($line in @($Lines)) {
    if ($null -eq $line) { continue }
    $clean = ([string]$line -replace "`0", '').Trim()
    if ($clean) { $names.Add($clean) }
  }
  return , $names.ToArray()
}

function Get-OmwFreeName {
  param([Parameter(Mandatory = $true)][string]$Base, [AllowEmptyCollection()][string[]]$Installed = @())
  for ($n = 1; $n -lt 1000; $n++) {
    $candidate = '{0}-{1}' -f $Base, $n
    if ($Installed -notcontains $candidate -and $candidate -match $script:OmwDistroNamePattern) { return $candidate }
  }
  throw "Could not find a free name based on '$Base'."
}

function Get-OmwReleaseAssetUrl {
  param([Parameter(Mandatory = $true)][string]$Repo, [Parameter(Mandatory = $true)][string]$Tag, [Parameter(Mandatory = $true)][string]$Name)
  return ('https://github.com/{0}/releases/download/{1}/{2}' -f $Repo, [uri]::EscapeDataString($Tag), [uri]::EscapeDataString($Name))
}

function Get-OmwVerificationCommands {
  # The optional, stronger checks: build provenance and the signed checksum list.
  param([Parameter(Mandatory = $true)][string]$Repo, [Parameter(Mandatory = $true)][string]$AssetName)
  return @(
    ('gh attestation verify {0} --repo {1}' -f $AssetName, $Repo),
    ("cosign verify-blob --bundle SHA256SUMS.sigstore.json --certificate-identity-regexp 'https://github.com/{0}/.github/workflows/release.yml@refs/tags/v.*' --certificate-oidc-issuer https://token.actions.githubusercontent.com SHA256SUMS" -f $Repo)
  )
}

# -----------------------------------------------------------------------------
# Host access (Windows)
# -----------------------------------------------------------------------------
function Test-OmwWindows {
  if ($PSVersionTable.PSEdition -ne 'Core') { return $true }
  return [bool](Get-Variable -Name IsWindows -ValueOnly -ErrorAction SilentlyContinue)
}

function Invoke-OmwWslCapture {
  # Runs wsl.exe and captures stdout. Native stderr must not become a
  # terminating error under $ErrorActionPreference = 'Stop' (Windows PowerShell 5.1).
  param([string[]]$Arguments)
  $ErrorActionPreference = 'Continue'
  $output = & wsl.exe @Arguments 2>$null
  [pscustomobject]@{ Output = @($output); ExitCode = $LASTEXITCODE }
}

function Get-OmwInstalledDistros {
  $r = Invoke-OmwWslCapture -Arguments @('--list', '--quiet')
  if ($r.ExitCode -ne 0) { return , @() }
  return (ConvertFrom-OmwWslList -Lines $r.Output)
}

function Get-OmwArchitectureProbes {
  $probes = New-Object System.Collections.Generic.List[string]
  try { $probes.Add([Environment]::GetEnvironmentVariable('PROCESSOR_ARCHITECTURE', 'Machine')) } catch { }
  $probes.Add($env:PROCESSOR_ARCHITEW6432)
  $probes.Add($env:PROCESSOR_ARCHITECTURE)
  try { $probes.Add([string][System.Runtime.InteropServices.RuntimeInformation]::OSArchitecture) } catch { }
  return , $probes.ToArray()
}

function Test-OmwElevated {
  $principal = New-Object System.Security.Principal.WindowsPrincipal([System.Security.Principal.WindowsIdentity]::GetCurrent())
  return $principal.IsInRole([System.Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Assert-OmwHost {
  # Returns $false when the user declines to continue.
  param([switch]$NonInteractive)
  Write-OmwStep 'Checking Windows and WSL...'
  if (-not (Test-OmwWindows)) { throw 'Omarchy-WSL installs on Windows only.' }
  if (-not [Environment]::Is64BitOperatingSystem) { throw 'Omarchy-WSL needs 64-bit Windows.' }
  $os = [Environment]::OSVersion.Version
  if ($os.Major -lt 10 -or $os.Build -lt 19041) { throw "Omarchy-WSL needs Windows 10 version 2004 (build 19041) or later; this is build $($os.Build)." }

  if (Test-OmwElevated) {
    Write-OmwWarn 'This PowerShell window is elevated (Run as administrator).'
    Write-OmwWarn 'WSL registers distributions per Windows user, so install from a normal window as the user who will use Omarchy.'
    if (-not $NonInteractive) {
      $answer = Read-Host 'Continue anyway? [y/N]'
      if ($answer -notmatch '^(y|yes)\z') { Write-OmwWarn 'Stopped. Nothing was changed.'; return $false }
    }
  }

  if (-not (Get-Command wsl.exe -CommandType Application -ErrorAction SilentlyContinue)) {
    throw "WSL is not installed. In an elevated PowerShell run 'wsl --install --no-distribution', restart Windows, then run this installer again."
  }
  Write-OmwOk "Windows build $($os.Build), WSL present."
  return $true
}

function Enable-OmwTls12 {
  # Windows PowerShell 5.1 on older .NET defaults to SSL3/TLS 1.0, which GitHub
  # rejects. Add TLS 1.2 unless .NET already lets the OS choose (SystemDefault = 0).
  try {
    $current = [Net.ServicePointManager]::SecurityProtocol
    if ([int]$current -ne 0 -and -not ($current -band [Net.SecurityProtocolType]::Tls12)) {
      [Net.ServicePointManager]::SecurityProtocol = $current -bor [Net.SecurityProtocolType]::Tls12
    }
  } catch { }
}

function Get-OmwRelease {
  param([Parameter(Mandatory = $true)][string]$Repo, [Parameter(Mandatory = $true)][string]$Tag)
  if ($Tag -eq 'latest') { $uri = "https://api.github.com/repos/$Repo/releases/latest" }
  else { $uri = "https://api.github.com/repos/$Repo/releases/tags/$Tag" }
  $headers = @{ 'User-Agent' = 'omarchy-wsl-installer'; 'Accept' = 'application/vnd.github+json' }
  try {
    $release = Invoke-RestMethod -Uri $uri -Headers $headers -UseBasicParsing
  } catch {
    throw "Could not read the release from $uri ($($_.Exception.Message))."
  }
  $resolved = [string]$release.tag_name
  if ($resolved -notmatch '^[A-Za-z0-9._+-]{1,64}\z') { throw "Unexpected release tag '$resolved' from $uri." }
  $names = @($release.assets | ForEach-Object { [string]$_.name })
  [pscustomobject]@{ Tag = $resolved; AssetNames = $names }
}

function Save-OmwDownload {
  param([Parameter(Mandatory = $true)][string]$Uri, [Parameter(Mandatory = $true)][string]$Path)
  try {
    Invoke-WebRequest -Uri $Uri -OutFile $Path -UseBasicParsing -Headers @{ 'User-Agent' = 'omarchy-wsl-installer' }
  } catch {
    throw "Download failed: $Uri ($($_.Exception.Message))."
  }
}

function Resolve-OmwInstallPlan {
  # Returns Action = Install | Update | Cancel and the distribution name.
  param(
    [Parameter(Mandatory = $true)][string]$DistroName,
    [AllowEmptyCollection()][string[]]$Installed = @(),
    [switch]$NonInteractive,
    [switch]$ForceSideBySide
  )
  if ($Installed -notcontains $DistroName) { return [pscustomobject]@{ Action = 'Install'; Name = $DistroName } }

  Write-OmwWarn "A WSL distribution named '$DistroName' already exists."
  if ($ForceSideBySide) {
    $name = Get-OmwFreeName -Base $DistroName -Installed $Installed
    Write-OmwStep "Installing next to it as '$name'."
    return [pscustomobject]@{ Action = 'Install'; Name = $name }
  }
  if ($NonInteractive) {
    throw "'$DistroName' already exists. Update it from inside with 'omarchy-update', or pass -ForceSideBySide or another -DistroName."
  }
  Write-Host ''
  Write-Host "  [1] Update '$DistroName' in place (runs omarchy-update inside it; your files stay)" -ForegroundColor Green
  Write-Host '  [2] Install another copy next to it under a new name' -ForegroundColor Cyan
  Write-Host '  [3] Cancel' -ForegroundColor Red
  Write-Host ''
  $choice = Read-Host 'Choose 1, 2 or 3'
  switch ($choice) {
    '1' { return [pscustomobject]@{ Action = 'Update'; Name = $DistroName } }
    '2' {
      $suggested = Get-OmwFreeName -Base $DistroName -Installed $Installed
      $name = (Read-Host "New name [$suggested]").Trim()
      if (-not $name) { $name = $suggested }
      if ($name -notmatch $script:OmwDistroNamePattern) { throw "Invalid distribution name '$name' (letters, digits, '.', '_', '-'; up to 64)." }
      if ($Installed -contains $name) { throw "A distribution named '$name' already exists." }
      return [pscustomobject]@{ Action = 'Install'; Name = $name }
    }
    default { return [pscustomobject]@{ Action = 'Cancel'; Name = $DistroName } }
  }
}

function Install-OmwDistro {
  # Interactive wsl.exe calls run as plain statements so the first-start setup
  # gets the console. Records the method used in $State.Method.
  param(
    [Parameter(Mandatory = $true)][string]$Name,
    [Parameter(Mandatory = $true)][string]$Package,
    [string]$InstallPath = '',
    [AllowNull()][version]$WslVersion,
    [switch]$NoLaunch,
    [Parameter(Mandatory = $true)][hashtable]$State
  )
  $ErrorActionPreference = 'Continue'
  if (Test-OmwFromFileSupported $WslVersion) {
    $arguments = @('--install', '--from-file', $Package, '--name', $Name)
    if ($InstallPath) { $arguments += @('--location', $InstallPath) }
    if ($NoLaunch) { $arguments += '--no-launch' }
    Write-OmwStep ("Installing: wsl {0}" -f ($arguments -join ' '))
    if (-not $NoLaunch) {
      Write-OmwStep "WSL now starts '$Name' for its first-time setup. When the Omarchy shell appears, setup is done:"
      Write-OmwStep "type 'exit' to come back here and finish the installation."
    }
    & wsl.exe @arguments
    $rc = $LASTEXITCODE
    if ($rc -eq 0) { $State.Method = 'install'; return }
    if ((Get-OmwInstalledDistros) -contains $Name) {
      throw "WSL registered '$Name' but its first start failed (exit $rc). Run 'wsl -d $Name' to see the error, or remove it with 'wsl --unregister $Name'."
    }
    Write-OmwWarn "wsl --install --from-file failed (exit $rc); trying wsl --import instead."
  } else {
    $shown = if ($WslVersion) { [string]$WslVersion } else { 'unknown (wsl --version failed)' }
    Write-OmwWarn "WSL version $shown has no 'wsl --install --from-file' (needs 2.4.4 or later; update with 'wsl --update'). Using wsl --import."
  }

  if (-not $InstallPath) { $InstallPath = Join-Path $env:LOCALAPPDATA ('wsl\' + $Name) }
  [void](New-Item -ItemType Directory -Force -Path $InstallPath -ErrorAction Stop)
  Write-OmwStep "Importing into $InstallPath"
  & wsl.exe --import $Name $InstallPath $Package --version 2
  if ($LASTEXITCODE -ne 0) { throw "wsl --import failed (exit $LASTEXITCODE)." }
  $State.Method = 'import'
}

function Test-OmwDistroHealth {
  param([Parameter(Mandatory = $true)][string]$Name)
  Write-OmwStep "Checking that '$Name' boots..."
  $r = Invoke-OmwWslCapture -Arguments @('-d', $Name, '-u', 'root', '--exec', 'uname', '-r')
  $kernel = (($r.Output | ForEach-Object { [string]$_ }) -join '').Trim()
  if ($r.ExitCode -ne 0 -or -not $kernel) { throw "WSL could not start '$Name' (wsl -d $Name -u root --exec uname -r exited $($r.ExitCode))." }
  Write-OmwOk "'$Name' boots (Linux kernel $kernel)."
}

function Invoke-OmwInstall {
  param(
    [string]$DistroName = 'Omarchy',
    [string]$ReleaseTag = 'latest',
    [string]$InstallPath = '',
    [string]$Repo = 'chntllh-labs/omarchy-wsl',
    [switch]$NonInteractive,
    [switch]$ForceSideBySide,
    [switch]$VerifyAttestation,
    [switch]$NoLaunch
  )
  $ErrorActionPreference = 'Stop'
  $ProgressPreference = 'SilentlyContinue'
  Set-StrictMode -Version 2.0
  if ($NonInteractive) { $NoLaunch = $true }

  $previousUtf8 = $env:WSL_UTF8
  $tempDir = $null
  try {
    Write-OmwBanner
    if (-not (Assert-OmwHost -NonInteractive:$NonInteractive)) { return }
    $env:WSL_UTF8 = '1'

    $versionProbe = Invoke-OmwWslCapture -Arguments @('--version')
    $wslVersion = $null
    if ($versionProbe.ExitCode -eq 0) { $wslVersion = ConvertFrom-OmwWslVersionText -Lines $versionProbe.Output }

    $arch = Resolve-OmwHostArchitecture -Candidates (Get-OmwArchitectureProbes)
    $asset = Get-OmwAssetName -Architecture $arch
    Write-OmwOk "Architecture: $arch -> $asset"

    $plan = Resolve-OmwInstallPlan -DistroName $DistroName -Installed (Get-OmwInstalledDistros) -NonInteractive:$NonInteractive -ForceSideBySide:$ForceSideBySide
    if ($plan.Action -eq 'Cancel') { Write-OmwWarn 'Cancelled. Nothing was changed.'; return }
    if ($plan.Action -eq 'Update') {
      Write-OmwStep "Running omarchy-update inside '$($plan.Name)'..."
      $ErrorActionPreference = 'Continue'
      & wsl.exe -d $plan.Name -- omarchy-update
      $rc = $LASTEXITCODE
      $ErrorActionPreference = 'Stop'
      if ($rc -ne 0) { throw "omarchy-update in '$($plan.Name)' failed (exit $rc). Open it with 'wsl -d $($plan.Name)' and run omarchy-update there." }
      Write-OmwOk "'$($plan.Name)' is up to date."
      return
    }
    $name = $plan.Name

    Enable-OmwTls12
    Write-OmwStep "Reading release '$ReleaseTag' of $Repo..."
    $release = Get-OmwRelease -Repo $Repo -Tag $ReleaseTag
    foreach ($required in @($asset, 'SHA256SUMS')) {
      if ($release.AssetNames -notcontains $required) { throw "Release $($release.Tag) has no '$required' asset." }
    }
    Write-OmwOk "Release $($release.Tag)"

    $tempDir = Join-Path ([System.IO.Path]::GetTempPath()) ('omarchy-wsl-' + [guid]::NewGuid().ToString('N'))
    [void](New-Item -ItemType Directory -Path $tempDir)
    $sumsPath = Join-Path $tempDir 'SHA256SUMS'
    $packagePath = Join-Path $tempDir $asset

    Save-OmwDownload -Uri (Get-OmwReleaseAssetUrl -Repo $Repo -Tag $release.Tag -Name 'SHA256SUMS') -Path $sumsPath
    $expected = Get-OmwExpectedSha256 -Sums (ConvertFrom-OmwSha256Sums -Text ([System.IO.File]::ReadAllText($sumsPath))) -Name $asset
    Write-OmwStep "Downloading $asset (expected SHA-256 $expected)..."
    Save-OmwDownload -Uri (Get-OmwReleaseAssetUrl -Repo $Repo -Tag $release.Tag -Name $asset) -Path $packagePath
    $actual = (Get-FileHash -LiteralPath $packagePath -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($actual -ne $expected) { throw "SHA-256 mismatch for $asset (expected $expected, got $actual). Nothing was installed." }
    Write-OmwOk "SHA-256 matches SHA256SUMS of release $($release.Tag)."

    $commands = Get-OmwVerificationCommands -Repo $Repo -AssetName $asset
    if ($VerifyAttestation) {
      $gh = Get-Command gh -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
      if (-not $gh) { throw "-VerifyAttestation needs the GitHub CLI: 'winget install GitHub.cli', then 'gh auth login'. Nothing was installed." }
      Write-OmwStep "Verifying build provenance: gh attestation verify $asset --repo $Repo"
      $ErrorActionPreference = 'Continue'
      & $gh.Source attestation verify $packagePath --repo $Repo
      $rc = $LASTEXITCODE
      $ErrorActionPreference = 'Stop'
      if ($rc -ne 0) { throw "gh attestation verify failed (exit $rc). Nothing was installed." }
      Write-OmwOk 'Build provenance verified.'
    } else {
      Write-Host ''
      Write-OmwStep 'Optional stronger checks (who built the image, not just that it arrived intact).'
      Write-Host ("    Files: https://github.com/{0}/releases/tag/{1}" -f $Repo, $release.Tag)
      foreach ($c in $commands) { Write-Host "    $c" }
      Write-Host '    Or re-run this installer with -VerifyAttestation to run the gh check automatically.'
      Write-Host ''
    }

    $state = @{ Method = $null }
    Install-OmwDistro -Name $name -Package $packagePath -InstallPath $InstallPath -WslVersion $wslVersion -NoLaunch:$NoLaunch -State $state
    Write-OmwOk "Registered '$name' ($($state.Method))."
    Test-OmwDistroHealth -Name $name

    Write-Host ''
    Write-OmwOk "Omarchy-WSL $($release.Tag) is installed as '$name'."
    if ($state.Method -eq 'import') {
      Write-OmwWarn "Imported distributions skip WSL's first-start setup. Omarchy's first-boot hook"
      Write-OmwWarn "creates your user on the first interactive root login: run 'wsl -d $name -u root'."
    }
    Write-Host "    Start it:        wsl -d $name   (or pick it in Windows Terminal)"
    Write-Host '    Update it later: omarchy-update   (inside Omarchy)'
    Write-Host ("    Optional: tune WSL with tools/generate-wslconfig.ps1 and start it at logon with tools/register-wsl-autostart.ps1 (https://github.com/{0}/tree/main/tools)" -f $Repo)
    Write-Host ''
  } finally {
    $env:WSL_UTF8 = $previousUtf8
    if ($tempDir -and (Test-Path -LiteralPath $tempDir)) { Remove-Item -LiteralPath $tempDir -Recurse -Force -ErrorAction SilentlyContinue }
  }
}

if (-not $NoRun) {
  try {
    Invoke-OmwInstall -DistroName $DistroName -ReleaseTag $ReleaseTag -InstallPath $InstallPath -Repo $Repo `
      -NonInteractive:$NonInteractive -ForceSideBySide:$ForceSideBySide -VerifyAttestation:$VerifyAttestation -NoLaunch:$NoLaunch
  } catch {
    Write-OmwFail "Omarchy-WSL installation failed: $($_.Exception.Message)"
    throw
  }
}
