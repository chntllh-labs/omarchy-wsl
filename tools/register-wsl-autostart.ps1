#requires -Version 5.1
<#
.SYNOPSIS
  Start a WSL distribution automatically at logon (default) or at boot.

.DESCRIPTION
  Registers (or with -Unregister removes) a Task Scheduler task that runs

      wsl.exe -d <Distro> --exec /bin/true

  which boots the WSL VM and the distribution, so systemd and its services
  (sshd, containers, tailscaled, user services with linger) are up before the
  first terminal opens.

  How long the distribution stays up afterwards is decided by .wslconfig, not
  by this task:
    * With tools/generate-wslconfig.ps1 -Profile Server ([wsl2] vmIdleTimeout=-1
      and [general] instanceIdleTimeout=-1) WSL never idle-stops the VM or the
      distribution, so the short /bin/true run is enough.
    * Otherwise WSL stops the distribution about 15 s after its last process
      exits. -KeepAlive adds a second action, `--exec /bin/sleep infinity`, that
      holds the distribution open for as long as the task runs.

  Launcher: by default the task uses %ProgramFiles%\WSL\wslg.exe when it exists.
  wslg.exe takes the same arguments as wsl.exe (both call WslClient::Main in
  microsoft/WSL) but is a GUI-subsystem program, so no console window flashes
  at logon and the -KeepAlive process stays hidden. Otherwise the task uses
  %SystemRoot%\System32\wsl.exe. Override with -Launcher Wsl or -Launcher Wslg.

  Trigger and account trade-offs
    At logon (default): runs as you, with your interactive token, only while you
      are logged on. No administrator rights and no stored password are needed.
    -AtStartup: starts the distribution at boot, before anyone logs on. Needs an
      elevated PowerShell (boot triggers are admin-only) and a logon type that
      works without an interactive session:
        S4U (default with -AtStartup): no password is stored. The task gets a
          non-interactive token without network credentials, so it cannot reach
          SMB shares or other resources that need your password. Some WSL builds
          may refuse to start a distribution from such a token; if the task's
          last result is an error, switch to -LogonType Password.
        Password: Task Scheduler stores your password (LSA secret) and logs you
          on as a batch job. Works like a normal logon, but the task stops
          working when your password changes until you register it again, and
          the account needs the "Log on as a batch job" right.
      Either way, when you log on later, wsl.exe attaches to the instance the
      task started (WSL keys instances by user, not by logon session).

  After `wsl --shutdown` the distribution stays down until the next trigger.
  Start it again with: Start-ScheduledTask -TaskPath '<TaskPath>' -TaskName '<TaskName>'

.PARAMETER Distro
  WSL distribution name (default Omarchy). Must match ^[A-Za-z0-9._-]{1,64}\z.

.PARAMETER TaskName
  Task name (default "Omarchy WSL autostart (<Distro>)").

.PARAMETER TaskPath
  Task Scheduler folder (default \).

.PARAMETER AtStartup
  Trigger at boot instead of at logon (needs an elevated PowerShell).

.PARAMETER LogonType
  Auto (Interactive at logon, S4U at startup), Interactive, S4U or Password.

.PARAMETER Credential
  Account password for -LogonType Password (prompted for when omitted).

.PARAMETER KeepAlive
  Also run `--exec /bin/sleep infinity`, keeping the distribution running while
  the task runs (no time limit).

.PARAMETER Launcher
  Auto (default), Wsl or Wslg. See the description.

.PARAMETER DelaySeconds
  Delay after logon/boot before the task starts (default 15).

.PARAMETER UserId
  Account the task runs as (default: the current user, DOMAIN\user).

.PARAMETER Unregister
  Remove the task.

.PARAMETER DryRun
  Print the task definition (Task Scheduler XML) and change nothing.

.PARAMETER Force
  Replace an existing task with the same name; register even when the
  distribution is not installed yet.

.PARAMETER NoRun
  Define the functions and return (for tests that dot-source this script).

.EXAMPLE
  .\tools\register-wsl-autostart.ps1

.EXAMPLE
  .\tools\register-wsl-autostart.ps1 -KeepAlive -DryRun

.EXAMPLE
  # elevated PowerShell, headless host
  .\tools\register-wsl-autostart.ps1 -AtStartup -Force

.EXAMPLE
  .\tools\register-wsl-autostart.ps1 -Unregister
#>

[CmdletBinding()]
param(
  [ValidatePattern('^[A-Za-z0-9._-]{1,64}\z')]
  [string]$Distro = 'Omarchy',

  [ValidatePattern('^[A-Za-z0-9 ._()-]{1,128}\z')]
  [string]$TaskName = '',

  [ValidatePattern('^\\([A-Za-z0-9 ._-]+\\)*\z')]
  [string]$TaskPath = '\',

  [switch]$AtStartup,

  [ValidateSet('Auto', 'Interactive', 'S4U', 'Password')]
  [string]$LogonType = 'Auto',

  [System.Management.Automation.PSCredential]$Credential,

  [switch]$KeepAlive,

  [ValidateSet('Auto', 'Wsl', 'Wslg')]
  [string]$Launcher = 'Auto',

  [ValidateRange(0, 3600)]
  [int]$DelaySeconds = 15,

  [ValidatePattern('^[^\x00-\x1f]{1,256}\z')]
  [string]$UserId = '',

  [switch]$Unregister,

  [switch]$DryRun,

  [switch]$Force,

  [switch]$NoRun
)

Set-StrictMode -Version 2.0

$script:OmwDistroPattern = '^[A-Za-z0-9._-]{1,64}\z'
$script:OmwWslExe = '%SystemRoot%\System32\wsl.exe'
$script:OmwWslgExe = '%ProgramFiles%\WSL\wslg.exe'

function Write-OmwInfo([string]$Message) { Write-Host "[*] $Message" -ForegroundColor Cyan }
function Write-OmwOk([string]$Message) { Write-Host "[+] $Message" -ForegroundColor Green }
function Write-OmwNote([string]$Message) { Write-Host "[!] $Message" -ForegroundColor Yellow }

# -----------------------------------------------------------------------------
# Pure helpers (unit-tested under pwsh on Linux)
# -----------------------------------------------------------------------------
function Get-OmwDefaultTaskName {
  param([Parameter(Mandatory = $true)][string]$Distro)
  return "Omarchy WSL autostart ($Distro)"
}

function Resolve-OmwLogonType {
  # Returns the Task Scheduler logon type: InteractiveToken, S4U or Password.
  param([string]$LogonType = 'Auto', [switch]$AtStartup)
  switch ($LogonType) {
    'Interactive' {
      if ($AtStartup) { throw '-AtStartup needs -LogonType S4U or Password: an interactive-token task cannot run before you log on.' }
      return 'InteractiveToken'
    }
    'S4U' { return 'S4U' }
    'Password' { return 'Password' }
    default { if ($AtStartup) { return 'S4U' } else { return 'InteractiveToken' } }
  }
}

function ConvertTo-OmwXmlText {
  param([AllowEmptyString()][string]$Text)
  return [System.Security.SecurityElement]::Escape($Text)
}

function New-OmwAutostartTaskXml {
  param(
    [Parameter(Mandatory = $true)][string]$Distro,
    [Parameter(Mandatory = $true)][string]$UserId,
    [ValidateSet('Logon', 'Startup')][string]$Trigger = 'Logon',
    [ValidateSet('InteractiveToken', 'S4U', 'Password')][string]$LogonType = 'InteractiveToken',
    [string]$Command = '%SystemRoot%\System32\wsl.exe',
    [switch]$KeepAlive,
    [ValidateRange(0, 3600)][int]$DelaySeconds = 15
  )
  if ($Distro -notmatch $script:OmwDistroPattern) { throw "Invalid distribution name '$Distro'." }
  if ($UserId -notmatch '^[^\x00-\x1f]{1,256}\z') { throw 'Invalid user id.' }
  if ($Trigger -eq 'Startup' -and $LogonType -eq 'InteractiveToken') { throw 'A startup trigger needs the S4U or Password logon type.' }

  $user = ConvertTo-OmwXmlText $UserId
  $cmd = ConvertTo-OmwXmlText $Command
  $delay = ''
  if ($DelaySeconds -gt 0) { $delay = "`r`n      <Delay>PT{0}S</Delay>" -f $DelaySeconds }
  if ($Trigger -eq 'Startup') {
    $triggerXml = "    <BootTrigger>`r`n      <Enabled>true</Enabled>$delay`r`n    </BootTrigger>"
    $when = 'at boot'
  } else {
    $triggerXml = "    <LogonTrigger>`r`n      <Enabled>true</Enabled>`r`n      <UserId>$user</UserId>$delay`r`n    </LogonTrigger>"
    $when = 'at logon'
  }
  $timeLimit = 'PT5M'
  $holdText = ''
  if ($KeepAlive) {
    $timeLimit = 'PT0S'
    $holdText = ' and keeps it running (/bin/sleep infinity)'
  }
  $description = ConvertTo-OmwXmlText ("Starts the {0} WSL distribution {1}{2}. Created by Omarchy-WSL tools/register-wsl-autostart.ps1." -f $Distro, $when, $holdText)

  $actions = New-Object System.Collections.Generic.List[string]
  $actions.Add("    <Exec>`r`n      <Command>$cmd</Command>`r`n      <Arguments>-d $Distro --exec /bin/true</Arguments>`r`n    </Exec>")
  if ($KeepAlive) {
    $actions.Add("    <Exec>`r`n      <Command>$cmd</Command>`r`n      <Arguments>-d $Distro --exec /bin/sleep infinity</Arguments>`r`n    </Exec>")
  }

  $lines = @(
    '<?xml version="1.0"?>',
    '<Task version="1.2" xmlns="http://schemas.microsoft.com/windows/2004/02/mit/task">',
    '  <RegistrationInfo>',
    "    <Author>$user</Author>",
    "    <Description>$description</Description>",
    '  </RegistrationInfo>',
    '  <Triggers>',
    $triggerXml,
    '  </Triggers>',
    '  <Principals>',
    '    <Principal id="Author">',
    "      <UserId>$user</UserId>",
    "      <LogonType>$LogonType</LogonType>",
    '      <RunLevel>LeastPrivilege</RunLevel>',
    '    </Principal>',
    '  </Principals>',
    '  <Settings>',
    '    <MultipleInstancesPolicy>IgnoreNew</MultipleInstancesPolicy>',
    '    <DisallowStartIfOnBatteries>false</DisallowStartIfOnBatteries>',
    '    <StopIfGoingOnBatteries>false</StopIfGoingOnBatteries>',
    '    <AllowHardTerminate>true</AllowHardTerminate>',
    '    <StartWhenAvailable>true</StartWhenAvailable>',
    '    <RunOnlyIfNetworkAvailable>false</RunOnlyIfNetworkAvailable>',
    '    <IdleSettings>',
    '      <StopOnIdleEnd>false</StopOnIdleEnd>',
    '      <RestartOnIdle>false</RestartOnIdle>',
    '    </IdleSettings>',
    '    <AllowStartOnDemand>true</AllowStartOnDemand>',
    '    <Enabled>true</Enabled>',
    '    <Hidden>false</Hidden>',
    '    <RunOnlyIfIdle>false</RunOnlyIfIdle>',
    '    <WakeToRun>false</WakeToRun>',
    "    <ExecutionTimeLimit>$timeLimit</ExecutionTimeLimit>",
    '    <Priority>7</Priority>',
    '  </Settings>',
    '  <Actions Context="Author">',
    ($actions.ToArray() -join "`r`n"),
    '  </Actions>',
    '</Task>'
  )
  return ($lines -join "`r`n") + "`r`n"
}

function Test-OmwServerIdleSettings {
  # True when .wslconfig text sets both idle timeouts to -1.
  param([AllowEmptyString()][AllowNull()][string]$Text)
  if ([string]::IsNullOrEmpty($Text)) { return $false }
  $section = ''
  $vm = $false
  $instance = $false
  foreach ($line in [regex]::Split($Text, "\r\n|\n|\r")) {
    $t = $line.Trim()
    if ($t -match '^\[\s*([A-Za-z][A-Za-z0-9]*)\s*\]') { $section = $Matches[1].ToLowerInvariant(); continue }
    if ($t -match '^([A-Za-z][A-Za-z0-9]*)\s*=\s*(-?[0-9]+)\s*(#.*)?$') {
      if ($section -eq 'wsl2' -and $Matches[1] -eq 'vmIdleTimeout' -and $Matches[2] -eq '-1') { $vm = $true }
      if ($section -eq 'general' -and $Matches[1] -eq 'instanceIdleTimeout' -and $Matches[2] -eq '-1') { $instance = $true }
    }
  }
  return ($vm -and $instance)
}

function ConvertFrom-OmwWslList {
  # `wsl.exe --list --quiet` prints UTF-16LE unless WSL_UTF8=1; strip NULs either way.
  param([AllowEmptyCollection()][AllowNull()][object[]]$Lines)
  $names = New-Object System.Collections.Generic.List[string]
  foreach ($line in @($Lines)) {
    if ($null -eq $line) { continue }
    $clean = ([string]$line -replace "`0", '').Trim()
    if ($clean) { $names.Add($clean) }
  }
  return , $names.ToArray()
}

# -----------------------------------------------------------------------------
# Host access (Windows only)
# -----------------------------------------------------------------------------
function Test-OmwWindows {
  if ($PSVersionTable.PSEdition -ne 'Core') { return $true }
  return [bool](Get-Variable -Name IsWindows -ValueOnly -ErrorAction SilentlyContinue)
}

function Get-OmwCurrentUserId {
  if (Test-OmwWindows) {
    try { return [System.Security.Principal.WindowsIdentity]::GetCurrent().Name } catch { }
  }
  $domain = [Environment]::UserDomainName
  if ($domain) { return '{0}\{1}' -f $domain, [Environment]::UserName }
  return [Environment]::UserName
}

function Test-OmwElevated {
  if (-not (Test-OmwWindows)) { return $false }
  $principal = New-Object System.Security.Principal.WindowsPrincipal([System.Security.Principal.WindowsIdentity]::GetCurrent())
  return $principal.IsInRole([System.Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Resolve-OmwLauncher {
  param([ValidateSet('Auto', 'Wsl', 'Wslg')][string]$Launcher = 'Auto')
  if ($Launcher -eq 'Wsl') { return $script:OmwWslExe }
  if ($Launcher -eq 'Wslg') { return $script:OmwWslgExe }
  if ((Test-OmwWindows) -and $env:ProgramFiles -and (Test-Path -LiteralPath (Join-Path $env:ProgramFiles 'WSL\wslg.exe'))) {
    return $script:OmwWslgExe
  }
  return $script:OmwWslExe
}

function Get-OmwInstalledDistros {
  $previous = $env:WSL_UTF8
  try {
    $env:WSL_UTF8 = '1'
    $output = & wsl.exe --list --quiet 2>$null
    return (ConvertFrom-OmwWslList -Lines @($output))
  } finally {
    $env:WSL_UTF8 = $previous
  }
}

function Invoke-OmwAutostart {
  param(
    [string]$Distro = 'Omarchy',
    [string]$TaskName = '',
    [string]$TaskPath = '\',
    [switch]$AtStartup,
    [string]$LogonType = 'Auto',
    [System.Management.Automation.PSCredential]$Credential,
    [switch]$KeepAlive,
    [string]$Launcher = 'Auto',
    [int]$DelaySeconds = 15,
    [string]$UserId = '',
    [switch]$Unregister,
    [switch]$DryRun,
    [switch]$Force
  )
  $ErrorActionPreference = 'Stop'
  if (-not $TaskName) { $TaskName = Get-OmwDefaultTaskName -Distro $Distro }
  $fullName = '{0}{1}' -f $TaskPath, $TaskName

  if ($Unregister) {
    if ($DryRun) { Write-OmwInfo "Dry run: would remove the scheduled task $fullName"; return }
    if (-not (Test-OmwWindows)) { throw 'Task Scheduler is only available on Windows.' }
    $task = Get-ScheduledTask -TaskName $TaskName -TaskPath $TaskPath -ErrorAction SilentlyContinue
    if (-not $task) { Write-OmwNote "No scheduled task named $fullName; nothing to remove."; return }
    Unregister-ScheduledTask -TaskName $TaskName -TaskPath $TaskPath -Confirm:$false
    Write-OmwOk "Removed $fullName"
    return
  }

  $taskLogonType = Resolve-OmwLogonType -LogonType $LogonType -AtStartup:$AtStartup
  if (-not $UserId) { $UserId = Get-OmwCurrentUserId }
  $trigger = 'Logon'
  if ($AtStartup) { $trigger = 'Startup' }
  $command = Resolve-OmwLauncher -Launcher $Launcher
  $xml = New-OmwAutostartTaskXml -Distro $Distro -UserId $UserId -Trigger $trigger -LogonType $taskLogonType `
    -Command $command -KeepAlive:$KeepAlive -DelaySeconds $DelaySeconds

  Write-OmwInfo ("Task {0}: {1} {2} -d {3} --exec /bin/true{4}, as {5} ({6})" -f $fullName, $(if ($AtStartup) { 'at boot' } else { 'at logon' }), $command, $Distro, $(if ($KeepAlive) { ', then --exec /bin/sleep infinity' } else { '' }), $UserId, $taskLogonType)
  if ($AtStartup) { Write-OmwNote 'Startup tasks must be registered from an elevated PowerShell.' }

  if (-not $KeepAlive -and (Test-OmwWindows) -and $env:USERPROFILE) {
    $wslconfig = Join-Path $env:USERPROFILE '.wslconfig'
    $text = $null
    if (Test-Path -LiteralPath $wslconfig) { $text = [System.IO.File]::ReadAllText($wslconfig) }
    if (-not (Test-OmwServerIdleSettings -Text $text)) {
      Write-OmwNote 'Without [wsl2] vmIdleTimeout=-1 and [general] instanceIdleTimeout=-1 in .wslconfig, WSL stops the'
      Write-OmwNote 'distribution about 15 s after /bin/true exits. Run tools/generate-wslconfig.ps1 -Profile Server, or use -KeepAlive.'
    }
  }

  if ($DryRun) {
    Write-OmwInfo 'Dry run: nothing was registered. Task definition:'
    Write-Output $xml
    return
  }

  if (-not (Test-OmwWindows)) { throw 'Task Scheduler is only available on Windows (use -DryRun to print the task).' }
  if ($AtStartup -and -not (Test-OmwElevated)) { throw '-AtStartup needs an elevated PowerShell (Run as administrator).' }

  $installed = Get-OmwInstalledDistros
  if ($installed -notcontains $Distro) {
    if (-not $Force) { throw "No WSL distribution named '$Distro' is installed (wsl --list). Install it first, or pass -Force." }
    Write-OmwNote "No WSL distribution named '$Distro' is installed yet; registering anyway (-Force)."
  }

  $existing = Get-ScheduledTask -TaskName $TaskName -TaskPath $TaskPath -ErrorAction SilentlyContinue
  if ($existing -and -not $Force) {
    Write-OmwNote "A scheduled task named $fullName already exists; pass -Force to replace it."
    return
  }

  $register = @{ TaskName = $TaskName; TaskPath = $TaskPath; Xml = $xml; Force = $true }
  if ($taskLogonType -eq 'Password') {
    if (-not $Credential) { $Credential = Get-Credential -UserName $UserId -Message "Password for $UserId (stored by Task Scheduler)" }
    if (-not $Credential) { throw 'A credential is required for -LogonType Password.' }
    $register.User = $Credential.UserName
    $register.Password = $Credential.GetNetworkCredential().Password
  }
  Register-ScheduledTask @register | Out-Null
  Write-OmwOk "Registered $fullName"
  Write-OmwInfo ("Run it now: Start-ScheduledTask -TaskPath '{0}' -TaskName '{1}'" -f $TaskPath, $TaskName)
  Write-OmwInfo 'Remove it:  .\tools\register-wsl-autostart.ps1 -Unregister'
}

if (-not $NoRun) {
  Invoke-OmwAutostart -Distro $Distro -TaskName $TaskName -TaskPath $TaskPath -AtStartup:$AtStartup -LogonType $LogonType `
    -Credential $Credential -KeepAlive:$KeepAlive -Launcher $Launcher -DelaySeconds $DelaySeconds -UserId $UserId `
    -Unregister:$Unregister -DryRun:$DryRun -Force:$Force
}
