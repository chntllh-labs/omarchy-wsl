<#
.SYNOPSIS
    Omarchy WSL: Windows Explorer "Open in Omarchy Terminal" context menu & Quick Access pin.

.DESCRIPTION
    Registers per-user (HKCU, no administrator rights) Explorer verbs on:
      * folder background  (HKCU\Software\Classes\Directory\Background\shell)
      * folders            (HKCU\Software\Classes\Directory\shell)
      * drive roots        (HKCU\Software\Classes\Drive\shell)
    that open Windows Terminal on the Omarchy profile in the clicked directory,
    falling back to wsl.exe --cd when Windows Terminal is not installed. Works for
    \\wsl.localhost\Omarchy\... folders too (WSL maps them back to Linux paths).

    Windows 11 shows classic shell verbs under "Show more options" (Shift+F10 /
    Shift+right-click). Top-level placement requires an IExplorerCommand handler
    shipped in a signed sparse package, which is out of scope for a script.

    Path quoting: the directory is passed as "%V." — a bare "%V" breaks on drive
    roots because C:\" escapes the closing quote (microsoft/terminal#4571);
    Win32 path normalisation strips the trailing dot from every other path.

.PARAMETER Distro
    WSL distribution name (default: Omarchy).
.PARAMETER TerminalProfile
    Windows Terminal profile name (default: same as Distro).
.PARAMETER Label
    Menu text (default: "Open in Omarchy Terminal").
.PARAMETER Extended
    Only show the verb on Shift+right-click.
.PARAMETER PinQuickAccess
    Also pin \\wsl.localhost\<Distro>\home\<user> to Explorer Quick Access.
.PARAMETER Uninstall
    Remove the verbs (and the Quick Access pin when combined with -PinQuickAccess).

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File register-explorer-context-menu.ps1 -PinQuickAccess
.EXAMPLE
    powershell -ExecutionPolicy Bypass -File register-explorer-context-menu.ps1 -Uninstall
#>
[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [ValidatePattern('^[A-Za-z0-9._-]{1,64}$')]
    [string]$Distro = 'Omarchy',

    [ValidatePattern('^[A-Za-z0-9 ._()-]{1,64}$')]
    [string]$TerminalProfile = '',

    [ValidatePattern('^[^"%&|<>^]{1,80}$')]
    [string]$Label = 'Open in Omarchy Terminal',

    [switch]$Extended,
    [switch]$PinQuickAccess,
    [switch]$Uninstall
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if (-not $TerminalProfile) { $TerminalProfile = $Distro }
$VerbKey = 'OmarchyTerminal'
$Roots = @(
    'HKCU:\Software\Classes\Directory\Background\shell',
    'HKCU:\Software\Classes\Directory\shell',
    'HKCU:\Software\Classes\Drive\shell'
)

function Write-Step([string]$Message) { Write-Host "[omarchy] $Message" -ForegroundColor Cyan }

function Resolve-Launcher {
    # Windows Terminal is an App Execution Alias; Explorer can start it by its
    # absolute alias path even when WindowsApps is missing from PATH.
    $alias = Join-Path $env:LOCALAPPDATA 'Microsoft\WindowsApps\wt.exe'
    if (Test-Path -LiteralPath $alias) {
        return '"{0}" -w 0 new-tab -p "{1}" -d "%V."' -f $alias, $TerminalProfile
    }
    $wsl = @(
        (Join-Path $env:ProgramFiles 'WSL\wsl.exe'),
        (Join-Path $env:SystemRoot 'System32\wsl.exe')
    ) | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
    if (-not $wsl) { throw 'Neither Windows Terminal nor wsl.exe was found.' }
    # --cd accepts absolute Windows paths, including \\wsl.localhost UNC paths.
    return '"{0}" -d {1} --cd "%V."' -f $wsl, $Distro
}

function Resolve-Icon {
    $dest = Join-Path $env:LOCALAPPDATA 'Omarchy\omarchy.ico'
    $src = "\\wsl.localhost\$Distro\usr\share\omarchy\assets\omarchy.ico"
    try {
        if (-not (Test-Path -LiteralPath $dest) -and (Test-Path -LiteralPath $src)) {
            New-Item -ItemType Directory -Force -Path (Split-Path $dest) | Out-Null
            Copy-Item -LiteralPath $src -Destination $dest -Force
        }
    } catch { }
    if (Test-Path -LiteralPath $dest) { return $dest }
    $wslIcon = Join-Path $env:ProgramFiles 'WSL\wsl.exe'
    if (Test-Path -LiteralPath $wslIcon) { return "$wslIcon,0" }
    return $null
}

function Get-HomeUnc {
    # Ask the distro for the default user's home rather than guessing it.
    $linuxHome = (& wsl.exe -d $Distro --exec sh -c 'printf %s "$HOME"' 2>$null)
    if (-not $linuxHome -or $linuxHome -notmatch '^/[A-Za-z0-9._/@-]+$') { throw "Could not determine the $Distro home directory." }
    return "\\wsl.localhost\$Distro" + ($linuxHome -replace '/', '\')
}

function Set-QuickAccessPin([bool]$Pin) {
    $unc = Get-HomeUnc
    $shell = New-Object -ComObject Shell.Application
    $qa = $shell.Namespace('shell:::{679f85cb-0220-4080-b29b-5540cc05aab6}')
    $item = $qa.Items() | Where-Object { $_.Path -eq $unc } | Select-Object -First 1
    if ($Pin) {
        # 'pintohome' toggles, so only invoke it when the folder is not pinned.
        if ($item) { Write-Step "Quick Access: already pinned ($unc)"; return }
        if ($PSCmdlet.ShouldProcess($unc, 'Pin to Quick Access')) {
            $folder = $shell.Namespace($unc)
            if (-not $folder) { throw "Cannot open $unc (is the distro installed?)" }
            $folder.Self.InvokeVerb('pintohome')
            Write-Step "Quick Access: pinned $unc"
        }
    } elseif ($item) {
        if ($PSCmdlet.ShouldProcess($unc, 'Unpin from Quick Access')) {
            $item.InvokeVerb('unpinfromhome')
            Write-Step "Quick Access: unpinned $unc"
        }
    }
}

if ($Uninstall) {
    foreach ($root in $Roots) {
        $key = Join-Path $root $VerbKey
        if ((Test-Path -LiteralPath $key) -and $PSCmdlet.ShouldProcess($key, 'Remove')) {
            Remove-Item -LiteralPath $key -Recurse -Force
            Write-Step "Removed $key"
        }
    }
    if ($PinQuickAccess) { Set-QuickAccessPin $false }
    return
}

$command = Resolve-Launcher
$icon = Resolve-Icon
foreach ($root in $Roots) {
    $key = Join-Path $root $VerbKey
    if (-not $PSCmdlet.ShouldProcess($key, "Register '$Label' -> $command")) { continue }
    New-Item -Path "$key\command" -Force | Out-Null
    Set-ItemProperty -LiteralPath $key -Name '(default)' -Value $Label
    if ($icon) { Set-ItemProperty -LiteralPath $key -Name 'Icon' -Value $icon }
    if ($Extended) {
        New-ItemProperty -LiteralPath $key -Name 'Extended' -Value '' -PropertyType String -Force | Out-Null
    } else {
        Remove-ItemProperty -LiteralPath $key -Name 'Extended' -ErrorAction SilentlyContinue
    }
    Set-ItemProperty -LiteralPath "$key\command" -Name '(default)' -Value $command
    Write-Step "Registered $key"
}
Write-Step "Command: $command"
Write-Step 'Windows 11: the entry appears under "Show more options" (Shift+right-click).'

if ($PinQuickAccess) { Set-QuickAccessPin $true }
