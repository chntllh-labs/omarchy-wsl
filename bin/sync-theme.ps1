#requires -Version 5.1
<#
.SYNOPSIS
  Apply an Omarchy color scheme to Windows Terminal (settings.json).

.DESCRIPTION
  Adds or updates one color scheme in the "schemes" array of every Windows
  Terminal settings.json it finds (Microsoft.WindowsTerminal* packages: Stable,
  Preview, Canary; and the unpackaged location), then points one profile
  ("Omarchy" by default, see -ProfileName) or profiles.defaults
  (-ApplyToDefaults) at that scheme.

  The file is edited structurally. A JSONC parser (comments and trailing commas
  allowed, as Windows Terminal accepts them) finds the root "schemes" array and
  the "profiles" list; schemes and profiles are matched by their "name" member
  inside those arrays only, so a profile called "Nord" is never mistaken for
  the Nord scheme. Only the text of the matching scheme objects and of the
  target profile's "colorScheme" value is rewritten. Comments and formatting
  everywhere else stay byte for byte; comments inside a scheme object that is
  replaced are lost. (Parsing with ConvertFrom-Json and writing the object back
  would drop every comment in the file, so this script does not do that.)

  Before anything is written the new text is parsed again and compared with the
  original: apart from the scheme objects and the colorScheme values, the
  document must be unchanged. Any parse or verification error leaves the file
  untouched and makes the script fail (terminating error, non-zero exit code);
  the success message is printed only when every target was handled.

  Backups: the first change to a file keeps a copy as settings.json.omarchy-orig,
  which is never overwritten. Every write also rotates settings.json.bak, .bak.1
  ... .bak.4. -Restore copies .omarchy-orig back (-RestoreFrom Latest uses .bak);
  the current file goes into the .bak rotation first, so a restore can be undone.
  Writes are atomic (temporary file in the same directory, then File.Replace).
  Unchanged files are not rewritten.

  Only Windows Terminal is changed. This script does not touch VS Code.

.PARAMETER Theme
  Built-in theme: TokyoNight (default), CatppuccinMocha, Nord, Dracula.

.PARAMETER ProfileName
  Windows Terminal profile whose colorScheme is set (default Omarchy).

.PARAMETER ApplyToDefaults
  Set profiles.defaults.colorScheme instead of a single profile.

.PARAMETER SettingsPath
  Explicit settings.json path(s) instead of discovering Windows Terminal installs.

.PARAMETER DryRun
  Validate and report the change without writing.

.PARAMETER Status
  List the settings files found and their backups.

.PARAMETER Restore
  Restore settings.json from a backup (see -RestoreFrom).

.PARAMETER RestoreFrom
  Original (default): settings.json.omarchy-orig. Latest: settings.json.bak.

.PARAMETER ListThemes
  List the built-in themes.

.PARAMETER NoRun
  Define the functions and return (for tests that dot-source this script).

.EXAMPLE
  powershell.exe -ExecutionPolicy Bypass -File .\bin\sync-theme.ps1 -Theme Nord

.EXAMPLE
  powershell.exe -ExecutionPolicy Bypass -File .\bin\sync-theme.ps1 -Restore
#>

[CmdletBinding()]
param(
  [Parameter(Position = 0)]
  [string]$Theme = 'TokyoNight',

  [ValidatePattern('^[^\x00-\x1f]{1,128}\z')]
  [string]$ProfileName = 'Omarchy',

  [switch]$ApplyToDefaults,

  [string[]]$SettingsPath = @(),

  [switch]$DryRun,

  [switch]$Status,

  [switch]$Restore,

  [ValidateSet('Original', 'Latest')]
  [string]$RestoreFrom = 'Original',

  [switch]$ListThemes,

  [switch]$NoRun
)

Set-StrictMode -Version 2.0

function Write-Step { param([string]$Message) Write-Host "[*] $Message" -ForegroundColor Cyan }
function Write-Success { param([string]$Message) Write-Host "[+] $Message" -ForegroundColor Green }
function Write-Warn { param([string]$Message) Write-Host "[!] $Message" -ForegroundColor Yellow }
function Write-Err { param([string]$Message) Write-Host "[-] $Message" -ForegroundColor Red }

$script:MaxRotatingBackups = 5
$script:OriginalSuffix = '.omarchy-orig'

# -----------------------------------------------------------------------------
# 1. Built-in palettes (Windows Terminal scheme keys only)
# -----------------------------------------------------------------------------
$script:SchemeKeyOrder = @(
  'name', 'background', 'foreground', 'cursorColor', 'selectionBackground',
  'black', 'red', 'green', 'yellow', 'blue', 'purple', 'cyan', 'white',
  'brightBlack', 'brightRed', 'brightGreen', 'brightYellow', 'brightBlue', 'brightPurple', 'brightCyan', 'brightWhite'
)

$script:ThemesCatalog = [ordered]@{
  'TokyoNight'      = [ordered]@{
    name = 'Tokyo Night'; background = '#1a1b26'; foreground = '#c0caf5'; cursorColor = '#c0caf5'; selectionBackground = '#283457'
    black = '#15161e'; red = '#f7768e'; green = '#9ece6a'; yellow = '#e0af68'; blue = '#7aa2f7'; purple = '#bb9af7'; cyan = '#7dcfff'; white = '#a9b1d6'
    brightBlack = '#414868'; brightRed = '#f7768e'; brightGreen = '#9ece6a'; brightYellow = '#e0af68'; brightBlue = '#7aa2f7'; brightPurple = '#bb9af7'; brightCyan = '#7dcfff'; brightWhite = '#c0caf5'
  }
  'CatppuccinMocha' = [ordered]@{
    name = 'Catppuccin Mocha'; background = '#1e1e2e'; foreground = '#cdd6f4'; cursorColor = '#f5e0dc'; selectionBackground = '#585b70'
    black = '#45475a'; red = '#f38ba8'; green = '#a6e3a1'; yellow = '#f9e2af'; blue = '#89b4fa'; purple = '#cba6f7'; cyan = '#94e2d5'; white = '#bac2de'
    brightBlack = '#585b70'; brightRed = '#f38ba8'; brightGreen = '#a6e3a1'; brightYellow = '#f9e2af'; brightBlue = '#89b4fa'; brightPurple = '#cba6f7'; brightCyan = '#94e2d5'; brightWhite = '#a6adc8'
  }
  'Nord'            = [ordered]@{
    name = 'Nord'; background = '#2e3440'; foreground = '#d8dee9'; cursorColor = '#d8dee9'; selectionBackground = '#434c5e'
    black = '#3b4252'; red = '#bf616a'; green = '#a3be8c'; yellow = '#ebcb8b'; blue = '#81a1c1'; purple = '#b48ead'; cyan = '#88c0d0'; white = '#e5e9f0'
    brightBlack = '#4c566a'; brightRed = '#bf616a'; brightGreen = '#a3be8c'; brightYellow = '#ebcb8b'; brightBlue = '#81a1c1'; brightPurple = '#b48ead'; brightCyan = '#8fbcbb'; brightWhite = '#eceff4'
  }
  'Dracula'         = [ordered]@{
    name = 'Dracula'; background = '#282a36'; foreground = '#f8f8f2'; cursorColor = '#f8f8f2'; selectionBackground = '#44475a'
    black = '#21222c'; red = '#ff5555'; green = '#50fa7b'; yellow = '#f1fa8c'; blue = '#bd93f9'; purple = '#ff79c6'; cyan = '#8be9fd'; white = '#f8f8f2'
    brightBlack = '#6272a4'; brightRed = '#ff6e6e'; brightGreen = '#69ff94'; brightYellow = '#ffffa5'; brightBlue = '#d6acff'; brightPurple = '#ff92df'; brightCyan = '#a4ffff'; brightWhite = '#ffffff'
  }
}

function Get-OmarchyScheme {
  param([Parameter(Mandatory = $true)][string]$Theme)
  $key = $Theme -replace '[-_ ]', ''
  foreach ($k in $script:ThemesCatalog.Keys) {
    if ($k -ieq $key) { return $script:ThemesCatalog[$k] }
  }
  return $null
}

# -----------------------------------------------------------------------------
# 2. Target discovery (Windows Terminal only)
# -----------------------------------------------------------------------------
function Find-WindowsTerminalTargets {
  $targets = @()
  $localAppData = $env:LOCALAPPDATA
  if ([string]::IsNullOrWhiteSpace($localAppData) -or -not (Test-Path -LiteralPath $localAppData)) { return }

  $pkgDir = Join-Path $localAppData 'Packages'
  if (Test-Path -LiteralPath $pkgDir) {
    foreach ($pkg in @(Get-ChildItem -LiteralPath $pkgDir -Directory -Filter 'Microsoft.WindowsTerminal*' -ErrorAction SilentlyContinue)) {
      $settingsFile = Join-Path $pkg.FullName 'LocalState\settings.json'
      $edition = 'stable'
      if ($pkg.Name -match 'Preview') { $edition = 'preview' } elseif ($pkg.Name -match 'Canary') { $edition = 'canary' }
      $targets += [pscustomobject]@{ Edition = $edition; Path = $settingsFile; Exists = (Test-Path -LiteralPath $settingsFile) }
    }
  }

  $unpackaged = Join-Path $localAppData 'Microsoft\Windows Terminal\settings.json'
  if (Test-Path -LiteralPath (Split-Path -Parent $unpackaged)) {
    $targets += [pscustomobject]@{ Edition = 'unpackaged'; Path = $unpackaged; Exists = (Test-Path -LiteralPath $unpackaged) }
  }
  return $targets
}

# -----------------------------------------------------------------------------
# 3. JSONC parser with source spans
#    Nodes: Object (Members: Name, Key, Value), Array (Elements), String, Literal.
#    Start/End are character offsets; End is exclusive.
# -----------------------------------------------------------------------------
$script:JsoncTrivia = New-Object System.Text.RegularExpressions.Regex('\G(?:\s+|//[^\n]*|/\*[\s\S]*?\*/)*')
$script:JsoncString = New-Object System.Text.RegularExpressions.Regex('\G"(?:[^"\\\u0000-\u001f]|\\(?:["\\/bfnrt]|u[0-9a-fA-F]{4}))*"')
$script:JsoncLiteral = New-Object System.Text.RegularExpressions.Regex('\G(?:-?(?:0|[1-9][0-9]*)(?:\.[0-9]+)?(?:[eE][+-]?[0-9]+)?|true|false|null)(?![A-Za-z0-9_.])')

function New-JsoncError {
  param($P, [string]$Message)
  $before = $P.Text.Substring(0, [Math]::Min($P.Pos, $P.Text.Length))
  $line = ([regex]::Matches($before, "`n")).Count + 1
  $column = $before.Length - $before.LastIndexOf("`n")
  return "JSONC syntax error at line ${line}, column ${column}: $Message"
}

function Skip-JsoncTrivia {
  param($P)
  $m = $script:JsoncTrivia.Match($P.Text, $P.Pos)
  if ($m.Success) { $P.Pos += $m.Length }
}

function ConvertFrom-JsonStringLiteral {
  param([string]$Literal)
  $inner = $Literal.Substring(1, $Literal.Length - 2)
  if ($inner.IndexOf('\') -lt 0) { return $inner }
  $sb = New-Object System.Text.StringBuilder
  for ($i = 0; $i -lt $inner.Length; $i++) {
    $c = $inner[$i]
    if ($c -ne '\') { [void]$sb.Append($c); continue }
    $i++
    switch -CaseSensitive ([string]$inner[$i]) {
      'b' { [void]$sb.Append([char]8) }
      'f' { [void]$sb.Append([char]12) }
      'n' { [void]$sb.Append([char]10) }
      'r' { [void]$sb.Append([char]13) }
      't' { [void]$sb.Append([char]9) }
      'u' { [void]$sb.Append([char][Convert]::ToInt32($inner.Substring($i + 1, 4), 16)); $i += 4 }
      default { [void]$sb.Append($inner[$i]) }
    }
  }
  return $sb.ToString()
}

function Read-JsoncString {
  param($P)
  $m = $script:JsoncString.Match($P.Text, $P.Pos)
  if (-not $m.Success) { throw (New-JsoncError $P 'invalid string') }
  $node = [pscustomobject]@{ Type = 'String'; Start = $P.Pos; End = $P.Pos + $m.Length; Value = (ConvertFrom-JsonStringLiteral $m.Value) }
  $P.Pos += $m.Length
  return $node
}

function Read-JsoncObject {
  param($P)
  $start = $P.Pos
  $P.Pos++
  $members = New-Object System.Collections.Generic.List[object]
  while ($true) {
    Skip-JsoncTrivia $P
    if ($P.Pos -ge $P.Text.Length) { throw (New-JsoncError $P 'unterminated object') }
    if ($P.Text[$P.Pos] -eq '}') { $P.Pos++; break }
    if ($P.Text[$P.Pos] -ne '"') { throw (New-JsoncError $P 'expected a property name') }
    $key = Read-JsoncString $P
    Skip-JsoncTrivia $P
    if ($P.Pos -ge $P.Text.Length -or $P.Text[$P.Pos] -ne ':') { throw (New-JsoncError $P "expected ':'") }
    $P.Pos++
    $value = Read-JsoncValue $P
    $members.Add([pscustomobject]@{ Name = $key.Value; Key = $key; Value = $value })
    Skip-JsoncTrivia $P
    if ($P.Pos -ge $P.Text.Length) { throw (New-JsoncError $P 'unterminated object') }
    if ($P.Text[$P.Pos] -eq ',') { $P.Pos++; continue }
    if ($P.Text[$P.Pos] -eq '}') { $P.Pos++; break }
    throw (New-JsoncError $P "expected ',' or '}'")
  }
  return [pscustomobject]@{ Type = 'Object'; Start = $start; End = $P.Pos; Members = $members.ToArray() }
}

function Read-JsoncArray {
  param($P)
  $start = $P.Pos
  $P.Pos++
  $elements = New-Object System.Collections.Generic.List[object]
  while ($true) {
    Skip-JsoncTrivia $P
    if ($P.Pos -ge $P.Text.Length) { throw (New-JsoncError $P 'unterminated array') }
    if ($P.Text[$P.Pos] -eq ']') { $P.Pos++; break }
    $elements.Add((Read-JsoncValue $P))
    Skip-JsoncTrivia $P
    if ($P.Pos -ge $P.Text.Length) { throw (New-JsoncError $P 'unterminated array') }
    if ($P.Text[$P.Pos] -eq ',') { $P.Pos++; continue }
    if ($P.Text[$P.Pos] -eq ']') { $P.Pos++; break }
    throw (New-JsoncError $P "expected ',' or ']'")
  }
  return [pscustomobject]@{ Type = 'Array'; Start = $start; End = $P.Pos; Elements = $elements.ToArray() }
}

function Read-JsoncValue {
  param($P)
  Skip-JsoncTrivia $P
  if ($P.Pos -ge $P.Text.Length) { throw (New-JsoncError $P 'unexpected end of input') }
  $c = $P.Text[$P.Pos]
  if ($c -eq '{') { return (Read-JsoncObject $P) }
  if ($c -eq '[') { return (Read-JsoncArray $P) }
  if ($c -eq '"') { return (Read-JsoncString $P) }
  $m = $script:JsoncLiteral.Match($P.Text, $P.Pos)
  if (-not $m.Success) { throw (New-JsoncError $P "unexpected character '$c'") }
  $node = [pscustomobject]@{ Type = 'Literal'; Start = $P.Pos; End = $P.Pos + $m.Length; Value = $m.Value }
  $P.Pos += $m.Length
  return $node
}

function ConvertFrom-Jsonc {
  param([Parameter(Mandatory = $true)][AllowEmptyString()][string]$Text)
  $P = @{ Text = $Text; Pos = 0 }
  if ($Text.Length -gt 0 -and $Text[0] -eq [char]0xFEFF) { $P.Pos = 1 }
  $root = Read-JsoncValue $P
  Skip-JsoncTrivia $P
  if ($P.Pos -lt $Text.Length) { throw (New-JsoncError $P 'unexpected content after the top-level value') }
  return $root
}

function Test-JsoncValid {
  param([AllowEmptyString()][string]$JsoncText)
  try { [void](ConvertFrom-Jsonc -Text $JsoncText); return $true } catch { return $false }
}

function Get-JsoncMember {
  # Members named exactly $Name (JSON keys are case-sensitive).
  param($Object, [string]$Name)
  if ($null -eq $Object -or $Object.Type -ne 'Object') { return }
  foreach ($m in $Object.Members) { if ($m.Name -ceq $Name) { $m } }
}

function Get-JsoncStringMemberValue {
  param($Object, [string]$Name)
  $m = @(Get-JsoncMember $Object $Name)
  if ($m.Count -gt 0 -and $m[$m.Count - 1].Value.Type -eq 'String') { return $m[$m.Count - 1].Value.Value }
  return $null
}

function ConvertTo-JsonStringLiteral {
  param([AllowEmptyString()][string]$Value)
  $sb = New-Object System.Text.StringBuilder
  [void]$sb.Append('"')
  foreach ($ch in $Value.ToCharArray()) {
    $code = [int]$ch
    if ($ch -eq '"') { [void]$sb.Append('\"') }
    elseif ($ch -eq '\') { [void]$sb.Append('\\') }
    elseif ($code -eq 10) { [void]$sb.Append('\n') }
    elseif ($code -eq 13) { [void]$sb.Append('\r') }
    elseif ($code -eq 9) { [void]$sb.Append('\t') }
    elseif ($code -lt 32) { [void]$sb.Append(('\u{0:x4}' -f $code)) }
    else { [void]$sb.Append($ch) }
  }
  [void]$sb.Append('"')
  return $sb.ToString()
}

function ConvertTo-JsoncCanonical {
  # Compact, comment-free rendering used to compare documents. $Skip decides
  # which object members / array elements to leave out: it receives
  # (kind, path, node) and returns $true to skip.
  param($Node, [string]$Path = '', [scriptblock]$Skip = $null)
  switch ($Node.Type) {
    'Object' {
      $parts = New-Object System.Collections.Generic.List[string]
      foreach ($m in $Node.Members) {
        $childPath = '{0}/{1}' -f $Path, $m.Name
        if ($Skip -and (& $Skip 'member' $childPath $m.Value $Node)) { continue }
        $parts.Add((ConvertTo-JsonStringLiteral $m.Name) + ':' + (ConvertTo-JsoncCanonical -Node $m.Value -Path $childPath -Skip $Skip))
      }
      return '{' + ($parts.ToArray() -join ',') + '}'
    }
    'Array' {
      $parts = New-Object System.Collections.Generic.List[string]
      foreach ($e in $Node.Elements) {
        $childPath = '{0}/[]' -f $Path
        if ($Skip -and (& $Skip 'element' $childPath $e $Node)) { continue }
        $parts.Add((ConvertTo-JsoncCanonical -Node $e -Path $childPath -Skip $Skip))
      }
      return '[' + ($parts.ToArray() -join ',') + ']'
    }
    'String' { return (ConvertTo-JsonStringLiteral $Node.Value) }
    default { return [string]$Node.Value }
  }
}

# -----------------------------------------------------------------------------
# 4. Structural edits
# -----------------------------------------------------------------------------
function Get-LineIndent {
  param([string]$Text, [int]$Position)
  $lineStart = $Text.LastIndexOf("`n", [Math]::Max(0, $Position - 1))
  $lineStart = if ($Position -eq 0) { 0 } else { $lineStart + 1 }
  $i = $lineStart
  while ($i -lt $Text.Length -and ($Text[$i] -eq ' ' -or $Text[$i] -eq "`t")) { $i++ }
  return [pscustomobject]@{ Indent = $Text.Substring($lineStart, $i - $lineStart); StartsLine = ($i -eq $Position) }
}

function Get-ChildIndent {
  # Indentation for a new member/element of $Container.
  param([string]$Text, $Container, [string]$Unit)
  $children = @()
  if ($Container.Type -eq 'Object') { $children = @($Container.Members | ForEach-Object { $_.Key }) }
  else { $children = @($Container.Elements) }
  foreach ($child in $children) {
    $info = Get-LineIndent -Text $Text -Position $child.Start
    if ($info.StartsLine) { return $info.Indent }
  }
  return (Get-LineIndent -Text $Text -Position $Container.Start).Indent + $Unit
}

function ConvertTo-SchemeJson {
  param($Scheme, [string]$Indent, [string]$Unit, [string]$NewLine)
  $keys = @($script:SchemeKeyOrder | Where-Object { $Scheme.Contains($_) })
  $lines = New-Object System.Collections.Generic.List[string]
  $lines.Add('{')
  for ($i = 0; $i -lt $keys.Count; $i++) {
    $comma = if ($i -lt $keys.Count - 1) { ',' } else { '' }
    $lines.Add(('{0}{1}{2}: {3}{4}' -f $Indent, $Unit, (ConvertTo-JsonStringLiteral $keys[$i]), (ConvertTo-JsonStringLiteral ([string]$Scheme[$keys[$i]])), $comma))
  }
  $lines.Add($Indent + '}')
  return ($lines.ToArray() -join $NewLine)
}

function New-TextEdit {
  param([int]$Start, [int]$End, [string]$Text)
  [pscustomobject]@{ Start = $Start; End = $End; Text = $Text }
}

function Invoke-TextEdits {
  param([string]$Text, [object[]]$Edits)
  $sorted = @($Edits | Sort-Object -Property @{ Expression = 'Start'; Descending = $true }, @{ Expression = 'End'; Descending = $true })
  for ($i = 1; $i -lt $sorted.Count; $i++) {
    if ($sorted[$i].End -gt $sorted[$i - 1].Start -or ($sorted[$i].Start -eq $sorted[$i - 1].Start)) {
      throw 'Internal error: overlapping edits.'
    }
  }
  $sb = New-Object System.Text.StringBuilder($Text)
  foreach ($e in $sorted) {
    [void]$sb.Remove($e.Start, $e.End - $e.Start)
    [void]$sb.Insert($e.Start, $e.Text)
  }
  return $sb.ToString()
}

function Get-SetMemberEdits {
  # Edits that make $Object."$Name" equal $ValueText: replace every existing
  # value of that member, or insert the member first in the object.
  param([string]$Text, $Object, [string]$Name, [string]$ValueText, [string]$Unit, [string]$NewLine)
  $edits = New-Object System.Collections.Generic.List[object]
  $existing = @(Get-JsoncMember $Object $Name)
  if ($existing.Count -gt 0) {
    foreach ($m in $existing) { $edits.Add((New-TextEdit $m.Value.Start $m.Value.End $ValueText)) }
    return , $edits.ToArray()
  }
  $indent = Get-ChildIndent -Text $Text -Container $Object -Unit $Unit
  $member = '{0}: {1}' -f (ConvertTo-JsonStringLiteral $Name), $ValueText
  if ($Object.Members.Count -gt 0) {
    $edits.Add((New-TextEdit ($Object.Start + 1) ($Object.Start + 1) ($NewLine + $indent + $member + ',')))
  } else {
    $closing = (Get-LineIndent -Text $Text -Position $Object.Start).Indent
    $edits.Add((New-TextEdit ($Object.Start + 1) ($Object.Start + 1) ($NewLine + $indent + $member + $NewLine + $closing)))
  }
  return , $edits.ToArray()
}

function Get-ThemeEdits {
  param(
    [Parameter(Mandatory = $true)][string]$Text,
    [Parameter(Mandatory = $true)]$Root,
    [Parameter(Mandatory = $true)]$Scheme,
    [string]$ProfileName = 'Omarchy',
    [switch]$ToDefaults
  )
  if ($Root.Type -ne 'Object') { throw 'settings.json does not contain a JSON object at the top level.' }
  $newLine = if ($Text.Contains("`r`n")) { "`r`n" } else { "`n" }
  $unit = '    '
  $firstMemberIndent = Get-ChildIndent -Text $Text -Container $Root -Unit '    '
  if ($firstMemberIndent.Length -gt 0) { $unit = $firstMemberIndent }

  $schemeName = [string]$Scheme['name']
  $nameLiteral = ConvertTo-JsonStringLiteral $schemeName
  $edits = New-Object System.Collections.Generic.List[object]
  $rootInserts = New-Object System.Collections.Generic.List[string]
  $notes = New-Object System.Collections.Generic.List[string]
  $profileFound = $true

  # --- schemes ---------------------------------------------------------------
  $schemesMembers = @(Get-JsoncMember $Root 'schemes')
  if ($schemesMembers.Count -eq 0) {
    $memberIndent = Get-ChildIndent -Text $Text -Container $Root -Unit $unit
    $rootInserts.Add(('"schemes": [{0}{1}{2}{3}{0}{4}]' -f $newLine, ($memberIndent + $unit), (ConvertTo-SchemeJson $Scheme ($memberIndent + $unit) $unit $newLine), '', $memberIndent))
    $notes.Add("added a 'schemes' array with '$schemeName'")
  } else {
    $schemes = $schemesMembers[$schemesMembers.Count - 1].Value
    if ($schemes.Type -ne 'Array') { throw "'schemes' is not an array; refusing to edit." }
    $matched = @($schemes.Elements | Where-Object { $_.Type -eq 'Object' -and (Get-JsoncStringMemberValue $_ 'name') -ceq $schemeName })
    if ($matched.Count -gt 0) {
      foreach ($element in $matched) {
        $indent = (Get-LineIndent -Text $Text -Position $element.Start).Indent
        $edits.Add((New-TextEdit $element.Start $element.End (ConvertTo-SchemeJson $Scheme $indent $unit $newLine)))
      }
      $notes.Add("updated scheme '$schemeName'")
    } else {
      $indent = Get-ChildIndent -Text $Text -Container $schemes -Unit $unit
      $schemeText = ConvertTo-SchemeJson $Scheme $indent $unit $newLine
      if ($schemes.Elements.Count -gt 0) {
        $last = $schemes.Elements[$schemes.Elements.Count - 1]
        $edits.Add((New-TextEdit $last.End $last.End (',' + $newLine + $indent + $schemeText)))
      } else {
        $closing = (Get-LineIndent -Text $Text -Position $schemes.Start).Indent
        $edits.Add((New-TextEdit ($schemes.Start + 1) ($schemes.Start + 1) ($newLine + $indent + $schemeText + $newLine + $closing)))
      }
      $notes.Add("added scheme '$schemeName'")
    }
  }

  # --- profiles ------------------------------------------------------------------
  $profilesMembers = @(Get-JsoncMember $Root 'profiles')
  $profiles = $null
  if ($profilesMembers.Count -gt 0) { $profiles = $profilesMembers[$profilesMembers.Count - 1].Value }

  if ($ToDefaults) {
    if ($null -eq $profiles) {
      $memberIndent = Get-ChildIndent -Text $Text -Container $Root -Unit $unit
      $rootInserts.Add(('"profiles": {{{0}{1}"defaults": {{ "colorScheme": {2} }},{0}{1}"list": []{0}{3}}}' -f $newLine, ($memberIndent + $unit), $nameLiteral, $memberIndent))
    } elseif ($profiles.Type -eq 'Object') {
      $defaultsMembers = @(Get-JsoncMember $profiles 'defaults')
      if ($defaultsMembers.Count -eq 0) {
        foreach ($e in (Get-SetMemberEdits -Text $Text -Object $profiles -Name 'defaults' -ValueText ('{{ "colorScheme": {0} }}' -f $nameLiteral) -Unit $unit -NewLine $newLine)) { $edits.Add($e) }
      } else {
        $defaults = $defaultsMembers[$defaultsMembers.Count - 1].Value
        if ($defaults.Type -ne 'Object') { throw "'profiles.defaults' is not an object; refusing to edit." }
        foreach ($e in (Get-SetMemberEdits -Text $Text -Object $defaults -Name 'colorScheme' -ValueText $nameLiteral -Unit $unit -NewLine $newLine)) { $edits.Add($e) }
      }
    } else {
      throw "'profiles' is a plain array (old format) with no 'defaults'; use -ProfileName instead of -ApplyToDefaults."
    }
    $notes.Add("set profiles.defaults.colorScheme to '$schemeName'")
  } else {
    $list = $null
    if ($null -ne $profiles -and $profiles.Type -eq 'Array') { $list = $profiles }
    elseif ($null -ne $profiles -and $profiles.Type -eq 'Object') {
      $listMembers = @(Get-JsoncMember $profiles 'list')
      if ($listMembers.Count -gt 0 -and $listMembers[$listMembers.Count - 1].Value.Type -eq 'Array') { $list = $listMembers[$listMembers.Count - 1].Value }
    }
    $targets = @()
    if ($null -ne $list) { $targets = @($list.Elements | Where-Object { $_.Type -eq 'Object' -and (Get-JsoncStringMemberValue $_ 'name') -ceq $ProfileName }) }
    if ($targets.Count -eq 0) {
      $profileFound = $false
      $notes.Add("profile '$ProfileName' not found in profiles.list; only the scheme was installed")
    } else {
      foreach ($t in $targets) {
        foreach ($e in (Get-SetMemberEdits -Text $Text -Object $t -Name 'colorScheme' -ValueText $nameLiteral -Unit $unit -NewLine $newLine)) { $edits.Add($e) }
      }
      $notes.Add("set colorScheme of profile '$ProfileName' to '$schemeName'")
    }
  }

  if ($rootInserts.Count -gt 0) {
    $memberIndent = Get-ChildIndent -Text $Text -Container $Root -Unit $unit
    $joined = ($rootInserts.ToArray() | ForEach-Object { $newLine + $memberIndent + $_ }) -join ','
    if ($Root.Members.Count -gt 0) { $joined += ',' } else { $joined += $newLine }
    $edits.Add((New-TextEdit ($Root.Start + 1) ($Root.Start + 1) $joined))
  }

  [pscustomobject]@{ Edits = $edits.ToArray(); Notes = $notes.ToArray(); ProfileFound = $profileFound }
}

function Get-MaskedDocument {
  # Canonical text of the document without the parts this script may change.
  param($Root, [string]$SchemeName, [string]$ProfileName, [switch]$ToDefaults)
  $skip = {
    param($kind, $path, $node, $parent)
    if ($kind -eq 'element' -and $path -ceq '/schemes/[]' -and $node.Type -eq 'Object' -and (Get-JsoncStringMemberValue $node 'name') -ceq $SchemeName) { return $true }
    if ($kind -eq 'member' -and $path -like '*/colorScheme') {
      if ($ToDefaults -and $path -ceq '/profiles/defaults/colorScheme') { return $true }
      if (-not $ToDefaults -and ($path -ceq '/profiles/list/[]/colorScheme' -or $path -ceq '/profiles/[]/colorScheme') -and (Get-JsoncStringMemberValue $parent 'name') -ceq $ProfileName) { return $true }
    }
    return $false
  }
  $text = ConvertTo-JsoncCanonical -Node $Root -Skip $skip
  # Members this script may create from nothing compare equal to absent ones.
  $text = $text.Replace(',"defaults":{}', '').Replace('"defaults":{},', '').Replace('{"defaults":{}}', '{}')
  $text = $text.Replace(',"schemes":[]', '').Replace('"schemes":[],', '').Replace('{"schemes":[]}', '{}')
  $text = $text.Replace(',"profiles":{"list":[]}', '').Replace('"profiles":{"list":[]},', '').Replace('{"profiles":{"list":[]}}', '{}')
  return $text
}

function Test-ThemeResult {
  # Verifies the edited document: the scheme is present with the exact colors,
  # the target colorScheme points at it, and nothing else changed.
  param($OldRoot, $NewRoot, $Scheme, [string]$ProfileName, [switch]$ToDefaults, [bool]$ProfileFound)
  $schemeName = [string]$Scheme['name']
  $expected = '{' + ((@($script:SchemeKeyOrder | Where-Object { $Scheme.Contains($_) }) | ForEach-Object { (ConvertTo-JsonStringLiteral $_) + ':' + (ConvertTo-JsonStringLiteral ([string]$Scheme[$_])) }) -join ',') + '}'

  $schemes = @(Get-JsoncMember $NewRoot 'schemes')
  if ($schemes.Count -eq 0 -or $schemes[$schemes.Count - 1].Value.Type -ne 'Array') { return "no 'schemes' array after the edit" }
  $found = @($schemes[$schemes.Count - 1].Value.Elements | Where-Object { $_.Type -eq 'Object' -and (Get-JsoncStringMemberValue $_ 'name') -ceq $schemeName })
  if ($found.Count -eq 0) { return "scheme '$schemeName' missing after the edit" }
  foreach ($f in $found) {
    if ((ConvertTo-JsoncCanonical -Node $f) -cne $expected) { return "scheme '$schemeName' does not have the expected colors" }
  }

  $profiles = @(Get-JsoncMember $NewRoot 'profiles')
  if ($ToDefaults) {
    $defaults = $null
    if ($profiles.Count -gt 0) { $defaults = @(Get-JsoncMember ($profiles[$profiles.Count - 1].Value) 'defaults') }
    if ($null -eq $defaults -or $defaults.Count -eq 0 -or (Get-JsoncStringMemberValue ($defaults[$defaults.Count - 1].Value) 'colorScheme') -cne $schemeName) {
      return 'profiles.defaults.colorScheme was not set'
    }
  } elseif ($ProfileFound) {
    $p = $profiles[$profiles.Count - 1].Value
    $list = $p
    if ($p.Type -eq 'Object') { $list = @(Get-JsoncMember $p 'list')[0].Value }
    foreach ($e in @($list.Elements | Where-Object { $_.Type -eq 'Object' -and (Get-JsoncStringMemberValue $_ 'name') -ceq $ProfileName })) {
      if ((Get-JsoncStringMemberValue $e 'colorScheme') -cne $schemeName) { return "profile '$ProfileName' does not point at '$schemeName'" }
    }
  }

  $before = Get-MaskedDocument -Root $OldRoot -SchemeName $schemeName -ProfileName $ProfileName -ToDefaults:$ToDefaults
  $after = Get-MaskedDocument -Root $NewRoot -SchemeName $schemeName -ProfileName $ProfileName -ToDefaults:$ToDefaults
  if ($before -cne $after) { return 'the edit changed parts of settings.json other than the scheme and colorScheme' }
  return $null
}

function Update-WindowsTerminalSettingsText {
  # Pure function: returns the new text (or throws). Used by the file updater and the tests.
  param(
    [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Text,
    [Parameter(Mandatory = $true)]$Scheme,
    [string]$ProfileName = 'Omarchy',
    [switch]$ToDefaults
  )
  $oldRoot = ConvertFrom-Jsonc -Text $Text
  $plan = Get-ThemeEdits -Text $Text -Root $oldRoot -Scheme $Scheme -ProfileName $ProfileName -ToDefaults:$ToDefaults
  $newText = Invoke-TextEdits -Text $Text -Edits $plan.Edits
  try {
    $newRoot = ConvertFrom-Jsonc -Text $newText
  } catch {
    throw "Internal verification failed, the edited JSONC does not parse: $($_.Exception.Message)"
  }
  $problem = Test-ThemeResult -OldRoot $oldRoot -NewRoot $newRoot -Scheme $Scheme -ProfileName $ProfileName -ToDefaults:$ToDefaults -ProfileFound $plan.ProfileFound
  if ($problem) { throw "Internal verification failed: $problem" }
  [pscustomobject]@{ Text = $newText; Notes = $plan.Notes; ProfileFound = $plan.ProfileFound; Changed = ($newText -cne $Text) }
}

# -----------------------------------------------------------------------------
# 5. Files: read, backups, atomic write
# -----------------------------------------------------------------------------
function Read-SettingsFile {
  param([Parameter(Mandatory = $true)][string]$Path)
  $bytes = [System.IO.File]::ReadAllBytes($Path)
  $bom = $bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF
  $offset = 0
  if ($bom) { $offset = 3 }
  try {
    $text = (New-Object System.Text.UTF8Encoding($false, $true)).GetString($bytes, $offset, $bytes.Length - $offset)
  } catch {
    throw "$Path is not valid UTF-8; Windows Terminal expects UTF-8."
  }
  [pscustomobject]@{ Text = $text; Bom = $bom }
}

function Save-SettingsBackups {
  # Keeps the very first version as <file>.omarchy-orig (never overwritten) and
  # rotates <file>.bak, .bak.1 ... .bak.(N-1).
  param([Parameter(Mandatory = $true)][string]$Path)
  if (-not (Test-Path -LiteralPath $Path)) { return }
  $orig = $Path + $script:OriginalSuffix
  if (-not (Test-Path -LiteralPath $orig)) { Copy-Item -LiteralPath $Path -Destination $orig }
  $max = $script:MaxRotatingBackups
  $oldest = '{0}.bak.{1}' -f $Path, ($max - 1)
  if (Test-Path -LiteralPath $oldest) { Remove-Item -LiteralPath $oldest -Force }
  for ($i = $max - 2; $i -ge 1; $i--) {
    $src = '{0}.bak.{1}' -f $Path, $i
    if (Test-Path -LiteralPath $src) { Move-Item -LiteralPath $src -Destination ('{0}.bak.{1}' -f $Path, ($i + 1)) -Force }
  }
  if (Test-Path -LiteralPath "$Path.bak") { Move-Item -LiteralPath "$Path.bak" -Destination "$Path.bak.1" -Force }
  Copy-Item -LiteralPath $Path -Destination "$Path.bak"
}

function Write-AtomicFile {
  param(
    [Parameter(Mandatory = $true)][string]$FilePath,
    [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Content,
    [switch]$Bom
  )
  $dir = Split-Path -Path $FilePath -Parent
  if ($dir -and -not (Test-Path -LiteralPath $dir)) { [void](New-Item -ItemType Directory -Path $dir -Force) }
  $tmpPath = Join-Path $dir ('{0}.omarchy_tmp.{1}' -f [System.IO.Path]::GetFileName($FilePath), [guid]::NewGuid().ToString('N'))
  try {
    [System.IO.File]::WriteAllText($tmpPath, $Content, (New-Object System.Text.UTF8Encoding([bool]$Bom)))
    # Windows Terminal watches settings.json and may hold it open briefly.
    $delayMs = 50
    for ($attempt = 1; $attempt -le 5; $attempt++) {
      try {
        if (Test-Path -LiteralPath $FilePath) {
          [System.IO.File]::Replace($tmpPath, $FilePath, [System.Management.Automation.Language.NullString]::Value)
        } else {
          [System.IO.File]::Move($tmpPath, $FilePath)
        }
        return
      } catch {
        if ($attempt -eq 5) { throw "Could not replace ${FilePath}: $($_.Exception.Message)" }
        Start-Sleep -Milliseconds $delayMs
        $delayMs *= 2
      }
    }
  } finally {
    if (Test-Path -LiteralPath $tmpPath) { Remove-Item -LiteralPath $tmpPath -Force -ErrorAction SilentlyContinue }
  }
}

function Update-WindowsTerminalSettings {
  # Returns $true on success (including "already up to date"), throws on failure.
  param(
    [Parameter(Mandatory = $true)][string]$FilePath,
    [Parameter(Mandatory = $true)]$SchemeData,
    [string]$TargetProfile = 'Omarchy',
    [bool]$ToDefaults = $false,
    [bool]$IsDryRun = $false
  )
  Write-Step "Windows Terminal settings: $FilePath"
  $bom = $false
  if (Test-Path -LiteralPath $FilePath) {
    $file = Read-SettingsFile -Path $FilePath
    $text = $file.Text
    $bom = $file.Bom
  } else {
    Write-Warn 'settings.json does not exist yet; starting from a minimal file.'
    $text = "{`r`n    `"`$schema`": `"https://aka.ms/terminal-profiles-schema`",`r`n    `"profiles`": {`r`n        `"defaults`": {},`r`n        `"list`": []`r`n    },`r`n    `"schemes`": []`r`n}`r`n"
  }

  try {
    $result = Update-WindowsTerminalSettingsText -Text $text -Scheme $SchemeData -ProfileName $TargetProfile -ToDefaults:$ToDefaults
  } catch {
    throw "Left $FilePath unchanged: $($_.Exception.Message)"
  }
  if ($result.Changed) { foreach ($note in $result.Notes) { Write-Step $note } }
  if (-not $result.ProfileFound) { Write-Warn "Profile '$TargetProfile' was not found; pass -ProfileName or -ApplyToDefaults to select the scheme automatically." }

  if (-not $result.Changed -and (Test-Path -LiteralPath $FilePath)) {
    Write-Success "Already up to date: $FilePath"
    return $true
  }
  if ($IsDryRun) {
    Write-Success "[DRY-RUN] Verified the update for $FilePath (not written)"
    return $true
  }
  Save-SettingsBackups -Path $FilePath
  Write-AtomicFile -FilePath $FilePath -Content $result.Text -Bom:$bom
  Write-Success "Synchronized '$($SchemeData['name'])' to $FilePath"
  return $true
}

function Restore-WindowsTerminalSettings {
  param([Parameter(Mandatory = $true)][string]$FilePath, [string]$From = 'Original', [bool]$IsDryRun = $false)
  $source = if ($From -eq 'Latest') { "$FilePath.bak" } else { $FilePath + $script:OriginalSuffix }
  if (-not (Test-Path -LiteralPath $source)) { Write-Warn "No backup to restore for $FilePath ($source missing)"; return $false }
  $content = Read-SettingsFile -Path $source
  if ($IsDryRun) { Write-Success "[DRY-RUN] Would restore $FilePath from $source"; return $true }
  Save-SettingsBackups -Path $FilePath
  Write-AtomicFile -FilePath $FilePath -Content $content.Text -Bom:$content.Bom
  Write-Success "Restored $FilePath from $source (previous version kept as $FilePath.bak)"
  return $true
}

# -----------------------------------------------------------------------------
# 6. Orchestrator
# -----------------------------------------------------------------------------
function Invoke-ThemeSync {
  param(
    [string]$Theme = 'TokyoNight',
    [string]$ProfileName = 'Omarchy',
    [switch]$ApplyToDefaults,
    [string[]]$SettingsPath = @(),
    [switch]$DryRun,
    [switch]$Status,
    [switch]$Restore,
    [string]$RestoreFrom = 'Original',
    [switch]$ListThemes
  )
  $ErrorActionPreference = 'Stop'

  if ($ListThemes) {
    Write-Host 'Available built-in themes:' -ForegroundColor Cyan
    foreach ($k in $script:ThemesCatalog.Keys) { Write-Host ("  - {0} ({1})" -f $k, $script:ThemesCatalog[$k]['name']) }
    return
  }

  if ($SettingsPath.Count -gt 0) {
    $targets = @($SettingsPath | ForEach-Object {
        $full = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($_)
        [pscustomobject]@{ Edition = 'explicit'; Path = $full; Exists = (Test-Path -LiteralPath $full) }
      })
  } else {
    $targets = @(Find-WindowsTerminalTargets)
  }

  if ($Status) {
    Write-Host 'Windows Terminal settings files:' -ForegroundColor Cyan
    if ($targets.Count -eq 0) { Write-Host '  (none found)' -ForegroundColor DarkGray }
    foreach ($t in $targets) {
      $state = if ($t.Exists) { 'found' } else { 'not created yet' }
      $orig = if (Test-Path -LiteralPath ($t.Path + $script:OriginalSuffix)) { 'original kept' } else { 'no original backup' }
      $baks = @(Get-ChildItem -LiteralPath (Split-Path -Parent $t.Path) -Filter ((Split-Path -Leaf $t.Path) + '.bak*') -ErrorAction SilentlyContinue).Count
      Write-Host ("  - [{0}] {1} ({2}; {3}; {4} rotating backup(s))" -f $t.Edition, $t.Path, $state, $orig, $baks)
    }
    return
  }

  if ($targets.Count -eq 0) {
    Write-Step 'Windows Terminal settings not found on this host; nothing to do.'
    return
  }

  $failed = New-Object System.Collections.Generic.List[string]
  if ($Restore) {
    $restored = 0
    foreach ($t in $targets) {
      try {
        if (Restore-WindowsTerminalSettings -FilePath $t.Path -From $RestoreFrom -IsDryRun:$DryRun) { $restored++ }
      } catch {
        Write-Err $_.Exception.Message
        $failed.Add($t.Path)
      }
    }
    if ($failed.Count -gt 0) { throw ("Restore failed for {0} of {1} file(s): {2}" -f $failed.Count, $targets.Count, ($failed.ToArray() -join ', ')) }
    Write-Success "Restored $restored file(s)."
    return
  }

  $scheme = Get-OmarchyScheme -Theme $Theme
  if ($null -eq $scheme) { throw "Theme '$Theme' not found. Run with -ListThemes to see the available themes." }
  Write-Step "Theme: $($scheme['name'])"
  if ($DryRun) { Write-Warn 'Dry run: nothing will be written.' }

  foreach ($t in $targets) {
    try {
      [void](Update-WindowsTerminalSettings -FilePath $t.Path -SchemeData $scheme -TargetProfile $ProfileName -ToDefaults ([bool]$ApplyToDefaults) -IsDryRun ([bool]$DryRun))
    } catch {
      Write-Err $_.Exception.Message
      $failed.Add($t.Path)
    }
  }
  if ($failed.Count -gt 0) {
    throw ("Theme sync failed for {0} of {1} file(s); those files were not changed: {2}" -f $failed.Count, $targets.Count, ($failed.ToArray() -join ', '))
  }
  Write-Success 'Theme synchronization completed successfully.'
}

if (-not $NoRun) {
  Invoke-ThemeSync -Theme $Theme -ProfileName $ProfileName -ApplyToDefaults:$ApplyToDefaults -SettingsPath $SettingsPath `
    -DryRun:$DryRun -Status:$Status -Restore:$Restore -RestoreFrom $RestoreFrom -ListThemes:$ListThemes
}
