#requires -Version 5.1
<#
.SYNOPSIS
  Tests for the Windows-side tools. Plain PowerShell, no Pester.

.DESCRIPTION
  Covers tools/generate-wslconfig.ps1, tools/register-wsl-autostart.ps1,
  install/install.ps1, bin/sync-theme.ps1,
  tools/register-explorer-context-menu.{ps1,reg} and
  distributions/DistributionInfo.fragment.json, and parses every *.ps1 in the
  repository (as UTF-8 and, for files without a BOM, the way Windows
  PowerShell 5.1 reads them: Windows-1252).

  Runs under pwsh on Linux: no Windows API is touched. The scripts are driven
  through their test seams (-DryRun, -NoRun, -Host*, -WslConfigPath,
  -SettingsPath, -UserId, -Launcher).

  Output: one "PASS: ", "FAIL: " or "SKIP: " line per check, then a summary.
  Exit code 1 when a check failed. tests/test_windows_tools.sh wraps this file.
#>
[CmdletBinding()]
param()

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$env:NO_COLOR = '1'

$script:Root = Split-Path -Parent $PSScriptRoot
$script:Run = 0
$script:Passed = 0
$script:Failed = 0
$script:Skipped = 0
$script:Pwsh = [System.Diagnostics.Process]::GetCurrentProcess().MainModule.FileName
$script:Temp = Join-Path ([System.IO.Path]::GetTempPath()) ('omw-wintools-' + [guid]::NewGuid().ToString('N'))
[void](New-Item -ItemType Directory -Path $script:Temp)
$script:OnWindows = ($PSVersionTable.PSEdition -ne 'Core') -or [bool](Get-Variable -Name IsWindows -ValueOnly -ErrorAction SilentlyContinue)

$Gen = Join-Path $script:Root 'tools/generate-wslconfig.ps1'
$Auto = Join-Path $script:Root 'tools/register-wsl-autostart.ps1'
$Install = Join-Path $script:Root 'install/install.ps1'
$Theme = Join-Path $script:Root 'bin/sync-theme.ps1'
$CtxPs1 = Join-Path $script:Root 'tools/register-explorer-context-menu.ps1'
$CtxReg = Join-Path $script:Root 'tools/register-explorer-context-menu.reg'
$CtxUnreg = Join-Path $script:Root 'tools/unregister-explorer-context-menu.reg'
$Example = Join-Path $script:Root 'wsl/wslconfig.example'
$Fragment = Join-Path $script:Root 'distributions/DistributionInfo.fragment.json'
$Spec = Join-Path $script:Root 'DISTRIBUTION-LIFECYCLE-SPEC.md'
$Owned = @($Gen, $Auto, $Install, $Theme, $CtxPs1, (Join-Path $script:Root 'tests/test_windows_tools.ps1'))

# -----------------------------------------------------------------------------
# Harness
# -----------------------------------------------------------------------------
function Pass([string]$Name) { $script:Run++; $script:Passed++; Write-Output "PASS: $Name" }
function Fail([string]$Name, [string]$Detail = '') {
  $script:Run++; $script:Failed++
  Write-Output "FAIL: $Name"
  if ($Detail) { Write-Output ('      ' + $Detail) }
}
function Skip([string]$Name) { $script:Skipped++; Write-Output "SKIP: $Name" }
function Section([string]$Name) { Write-Output ''; Write-Output ">>> $Name" }
function Invoke-Section {
  # An unexpected error fails this section only; the next sections still run.
  param([string]$Name, [scriptblock]$Body)
  Section $Name
  try { & $Body } catch { Fail ('{0}: unexpected error' -f $Name) ($_.Exception.Message + ' ' + $_.InvocationInfo.PositionMessage) }
}

function Check {
  param([string]$Name, [scriptblock]$Test)
  try {
    $result = @(& $Test)
    if ($result.Count -gt 0 -and $result[$result.Count - 1] -is [bool] -and $result[$result.Count - 1]) {
      Pass $Name
    } else {
      $shown = ($result | ForEach-Object { [string]$_ }) -join ' | '
      if ($shown.Length -gt 300) { $shown = $shown.Substring(0, 300) + '...' }
      Fail $Name ("check returned: " + $shown)
    }
  } catch {
    Fail $Name $_.Exception.Message
  }
}

function Test-Throws {
  param([scriptblock]$Block, [string]$Like = '*')
  try { $null = & $Block } catch { return ($_.Exception.Message -like $Like) }
  return $false
}

function Invoke-TestScript {
  # Runs a script in a fresh pwsh/powershell process; returns Text and ExitCode.
  param([string]$Path, [string[]]$Arguments = @())
  $ErrorActionPreference = 'Continue'
  $out = & $script:Pwsh -NoProfile -NonInteractive -File $Path @Arguments 2>&1 | ForEach-Object { [string]$_ }
  $code = $LASTEXITCODE
  $text = ((@($out) -join "`n") -replace "\x1b\[[0-9;?]*[A-Za-z]", '')
  [pscustomobject]@{ Text = $text; ExitCode = $code }
}

function Get-Bytes([string]$Path) { return [System.IO.File]::ReadAllBytes($Path) }
function Test-SameBytes($A, $B) { return ([Convert]::ToBase64String($A) -ceq [Convert]::ToBase64String($B)) }
function Write-Utf8([string]$Path, [string]$Text, [switch]$Bom) {
  [System.IO.File]::WriteAllText($Path, $Text, (New-Object System.Text.UTF8Encoding([bool]$Bom)))
}
function New-TestDir([string]$Name) {
  $d = Join-Path $script:Temp $Name
  [void](New-Item -ItemType Directory -Path $d)
  return $d
}

function Read-TestIni {
  # Minimal .wslconfig reader for assertions: Section (lowercase), Key, Value.
  param([string]$Text)
  $section = ''
  $entries = New-Object System.Collections.Generic.List[object]
  foreach ($line in ($Text -split "`r?`n")) {
    $t = $line.Trim()
    if (-not $t -or $t.StartsWith('#')) { continue }
    if ($t -match '^\[([A-Za-z0-9]+)\]$') { $section = $Matches[1].ToLowerInvariant(); continue }
    if ($t -match '^([A-Za-z][A-Za-z0-9]*)\s*=\s*(.*)$') {
      $entries.Add([pscustomobject]@{ Section = $section; Key = $Matches[1]; Value = $Matches[2].Trim() })
      continue
    }
    throw "unexpected .wslconfig line: '$line'"
  }
  return , $entries.ToArray()
}

function Get-IniValue {
  param($Entries, [string]$Section, [string]$Key)
  foreach ($e in $Entries) { if ($e.Section -eq $Section -and $e.Key -ceq $Key) { return $e.Value } }
  return $null
}

function Get-IniCanonical {
  param($Entries)
  return ((@($Entries | ForEach-Object { '{0}.{1}={2}' -f $_.Section, $_.Key, $_.Value }) | Sort-Object) -join "`n")
}

function ConvertFrom-TestJsonc {
  # Independent JSONC reader for assertions: strip comments and trailing commas, then ConvertFrom-Json.
  param([string]$Text)
  if ($Text.Length -gt 0 -and $Text[0] -eq [char]0xFEFF) { $Text = $Text.Substring(1) }
  $sb = New-Object System.Text.StringBuilder
  $i = 0
  $n = $Text.Length
  $inString = $false
  while ($i -lt $n) {
    $c = $Text[$i]
    if ($inString) {
      [void]$sb.Append($c)
      if ($c -eq '\' -and $i + 1 -lt $n) { [void]$sb.Append($Text[$i + 1]); $i += 2; continue }
      if ($c -eq '"') { $inString = $false }
      $i++
      continue
    }
    if ($c -eq '"') { $inString = $true; [void]$sb.Append($c); $i++; continue }
    if ($c -eq '/' -and $i + 1 -lt $n -and $Text[$i + 1] -eq '/') { while ($i -lt $n -and $Text[$i] -ne "`n") { $i++ }; continue }
    if ($c -eq '/' -and $i + 1 -lt $n -and $Text[$i + 1] -eq '*') {
      $i += 2
      while ($i + 1 -lt $n -and -not ($Text[$i] -eq '*' -and $Text[$i + 1] -eq '/')) { $i++ }
      $i += 2
      continue
    }
    [void]$sb.Append($c)
    $i++
  }
  $json = [regex]::Replace($sb.ToString(), ',(\s*[}\]])', '$1')
  return ($json | ConvertFrom-Json)
}

function Get-ScriptAst([string]$Path) {
  $tokens = $null
  $errors = $null
  $ast = [System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$tokens, [ref]$errors)
  return [pscustomobject]@{ Ast = $ast; Errors = @($errors); Tokens = @($tokens) }
}

function Get-ExitStatementCount([string]$Path) {
  $p = Get-ScriptAst $Path
  return @($p.Ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.ExitStatementAst] }, $true)).Count
}

$VerifiedSection = @{
  memory = 'wsl2'; processors = 'wsl2'; swap = 'wsl2'; nestedVirtualization = 'wsl2'; guiApplications = 'wsl2'
  vmIdleTimeout = 'wsl2'; networkingMode = 'wsl2'; dnsTunneling = 'wsl2'; firewall = 'wsl2'; autoProxy = 'wsl2'
  localhostForwarding = 'wsl2'; instanceIdleTimeout = 'general'
  autoMemoryReclaim = 'experimental'; sparseVhd = 'experimental'; hostAddressLoopback = 'experimental'; ignoredPorts = 'experimental'
}

try {
  Invoke-Section '0. PowerShell sources: parse, Windows PowerShell 5.1 compatibility' {
    $allPs1 = @(Get-ChildItem -LiteralPath $script:Root -Recurse -File -Filter '*.ps1' -Force | Where-Object { $_.FullName -notmatch '[\\/]\.git[\\/]' })
    Check "Found PowerShell scripts in the repository ($($allPs1.Count))" { $allPs1.Count -ge 6 }
    $cp1252 = [System.Text.Encoding]::GetEncoding(1252)
    foreach ($f in $allPs1) {
      $rel = $f.FullName.Substring($script:Root.Length + 1)
      Check "$rel parses without errors (Parser.ParseFile)" { (Get-ScriptAst $f.FullName).Errors.Count -eq 0 }
      $bytes = Get-Bytes $f.FullName
      $hasBom = $bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF
      if (-not $hasBom) {
        Check "$rel parses as Windows PowerShell 5.1 reads it (no BOM: Windows-1252)" {
          $t = $null; $e = $null
          [void][System.Management.Automation.Language.Parser]::ParseInput($cp1252.GetString($bytes), [ref]$t, [ref]$e)
          @($e).Count -eq 0
        }
      }
    }
    foreach ($path in $Owned) {
      $rel = $path.Substring($script:Root.Length + 1)
      Check "$rel is ASCII-only (identical under every Windows code page)" { @((Get-Bytes $path) | Where-Object { $_ -gt 127 }).Count -eq 0 }
      Check "$rel uses no PowerShell 7-only syntax or parameters" {
        $p = Get-ScriptAst $path
        $bad = @($p.Ast.FindAll({
              param($n)
              $type = $n.GetType().Name
              if ($type -eq 'TernaryExpressionAst' -or $type -eq 'PipelineChainAst') { return $true }
              if ($n -is [System.Management.Automation.Language.BinaryExpressionAst] -and $n.Operator.ToString() -eq 'QuestionQuestion') { return $true }
              if ($n -is [System.Management.Automation.Language.AssignmentStatementAst] -and $n.Operator.ToString() -eq 'QuestionQuestionEquals') { return $true }
              if ($n -is [System.Management.Automation.Language.MemberExpressionAst] -and $n.PSObject.Properties['NullConditional'] -and $n.NullConditional) { return $true }
              if ($n -is [System.Management.Automation.Language.CommandParameterAst] -and @('AsHashtable', 'AsByteStream', 'Parallel', 'SkipCertificateCheck') -contains $n.ParameterName) { return $true }
              if ($n -is [System.Management.Automation.Language.CommandAst] -and @('Join-String', 'Test-Json', 'Get-Error') -contains $n.GetCommandName()) { return $true }
              return $false
            }, $true))
        $bad.Count -eq 0
      }
    }
    foreach ($path in @($Install, $Auto, $Gen, $Theme)) {
      $rel = $path.Substring($script:Root.Length + 1)
      Check "$rel contains no 'exit' statement (safe under irm | iex and dot-sourcing)" { (Get-ExitStatementCount $path) -eq 0 }
    }
    foreach ($path in @($Install, $Auto, $Theme, $CtxPs1)) {
      $rel = $path.Substring($script:Root.Length + 1)
      Check "$rel anchors every ValidatePattern with \z, never `$" {
        $patterns = @((Get-ScriptAst $path).Ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.AttributeAst] -and $n.TypeName.Name -eq 'ValidatePattern' }, $true) | ForEach-Object { [string]$_.PositionalArguments[0].Value })
        $patterns.Count -gt 0 -and @($patterns | Where-Object { -not $_.EndsWith('\z') }).Count -eq 0
      }
    }

  }

  Invoke-Section '1. tools/generate-wslconfig.ps1' {
    & {
      . $Gen -NoRun
      $script:OmwQuiet = $true

      Check 'Key table: every managed key is in the section verified against Microsoft docs and WslCoreConfig.h' {
        $bad = @($VerifiedSection.Keys | Where-Object { (Get-OmwKeySection $_) -ne $VerifiedSection[$_] })
        $bad.Count -eq 0
      }
      Check 'Key table: autoMemoryReclaim and sparseVhd are [experimental]-only (no [wsl2] alias)' {
        (Get-OmwKeySection 'autoMemoryReclaim') -eq 'experimental' -and (Get-OmwKeySection 'sparseVhd') -eq 'experimental' -and
        ($script:OmwWslLegacyAlias -notcontains 'autoMemoryReclaim') -and ($script:OmwWslLegacyAlias -notcontains 'sparseVhd')
      }
      Check 'Key table: pageReporting is not a WSL key' { $null -eq (Get-OmwKeySection 'pageReporting') }

      $sizing = @(
        @{ Ram = 4; Mem = 2; Swap = 4 }, @{ Ram = 8; Mem = 4; Swap = 4 }, @{ Ram = 16; Mem = 8; Swap = 4 },
        @{ Ram = 32; Mem = 24; Swap = 8 }, @{ Ram = 64; Mem = 48; Swap = 16 }, @{ Ram = 128; Mem = 112; Swap = 16 }
      )
      foreach ($c in $sizing) {
        Check ("Auto sizing: {0}GB host -> memory {1}GB, swap {2}GB, all processors" -f $c.Ram, $c.Mem, $c.Swap) {
          $p = Get-OmwResourcePlan -TotalRamGB $c.Ram -LogicalProcessors 12
          $p.MemoryGB -eq $c.Mem -and $p.SwapGB -eq $c.Swap -and $p.Processors -eq 12
        }
      }
      Check 'Clamp: Workstation-64GB preset on a 32GB host -> 28GB (RAM minus 4GB reserve)' { (Get-OmwResourcePlan -TotalRamGB 32 -LogicalProcessors 8 -HardwarePreset 'Workstation-64GB').MemoryGB -eq 28 }
      Check 'Clamp: -RamOverrideGB 100 on a 64GB host -> 60GB' { (Get-OmwResourcePlan -TotalRamGB 64 -LogicalProcessors 8 -RamOverrideGB 100).MemoryGB -eq 60 }
      Check 'Clamp: -WindowsReserveGB 12 on a 32GB host -> 20GB' { (Get-OmwResourcePlan -TotalRamGB 32 -LogicalProcessors 8 -WindowsReserveGB 12).MemoryGB -eq 20 }
      Check 'Clamp: -CpuOverride above the host count -> host count' { (Get-OmwResourcePlan -TotalRamGB 32 -LogicalProcessors 16 -CpuOverride 64).Processors -eq 16 }
      Check '-CpuOverride below the host count is honoured' { (Get-OmwResourcePlan -TotalRamGB 32 -LogicalProcessors 16 -CpuOverride 6).Processors -eq 6 }
      Check 'Swap is never below 4GB (-SwapOverrideGB 1 -> 4)' { (Get-OmwResourcePlan -TotalRamGB 32 -LogicalProcessors 8 -SwapOverrideGB 1).SwapGB -eq 4 }
      Check 'Presets: Laptop/Pro/Workstation/Server -> 8/24/48/112GB on a 256GB host' {
        ((Get-OmwResourcePlan -TotalRamGB 256 -LogicalProcessors 8 -HardwarePreset 'Laptop-16GB').MemoryGB -eq 8) -and
        ((Get-OmwResourcePlan -TotalRamGB 256 -LogicalProcessors 8 -HardwarePreset 'Pro-32GB').MemoryGB -eq 24) -and
        ((Get-OmwResourcePlan -TotalRamGB 256 -LogicalProcessors 8 -HardwarePreset 'Workstation-64GB').MemoryGB -eq 48) -and
        ((Get-OmwResourcePlan -TotalRamGB 256 -LogicalProcessors 8 -HardwarePreset 'Server-128GB').MemoryGB -eq 112)
      }
      Check 'Host arch: any ARM64 probe wins (x64 PowerShell emulated on Windows on ARM)' { (Resolve-OmwArch @('ARM64', 'AMD64', 'X64')) -eq 'arm64' }
      Check 'Host arch: AMD64 and 32-bit PowerShell on x64 -> x64' { (Resolve-OmwArch @('AMD64')) -eq 'x64' -and (Resolve-OmwArch @($null, 'x86', 'AMD64')) -eq 'x64' }
      Check 'Host arch: 32-bit-only hosts are refused' { Test-Throws { Resolve-OmwArch @('x86') } '*Unsupported*' }
      Check 'Unified diff: changed line' {
        $d = Get-OmwUnifiedDiff -OldLines @('a', 'b', 'c') -NewLines @('a', 'x', 'c')
        ($d -join '|') -ceq '--- a/.wslconfig|+++ b/.wslconfig|@@ -1,3 +1,3 @@| a|-b|+x| c'
      }
      Check 'Unified diff: new file' { ((Get-OmwUnifiedDiff -OldLines @() -NewLines @('a', 'b')) -join '|') -ceq '--- a/.wslconfig|+++ b/.wslconfig|@@ -0,0 +1,2 @@|+a|+b' }
      Check 'Unified diff: identical input -> no output' { $d = Get-OmwUnifiedDiff -OldLines @('a') -NewLines @('a'); $d.Count -eq 0 }

      # Full matrix through the real entry point (in-process, -DryRun).
      $absent = Join-Path $script:Temp 'absent.wslconfig'
      $rules = [ordered]@{
        'every key is a verified key in its verified section'                                  = New-Object System.Collections.Generic.List[string]
        'no key appears twice in a section'                                                     = New-Object System.Collections.Generic.List[string]
        'nestedVirtualization only on x64 Windows 11, never on ARM64'                          = New-Object System.Collections.Generic.List[string]
        'mirrored networking exactly when build >= 22621 and no -ForceNAT'                      = New-Object System.Collections.Generic.List[string]
        'mirrored: no localhostForwarding; hostAddressLoopback, ignoredPorts in [experimental]' = New-Object System.Collections.Generic.List[string]
        'NAT: localhostForwarding=true, dnsTunneling=false, autoProxy=false, no mirrored-only keys' = New-Object System.Collections.Generic.List[string]
        'Server: [wsl2] vmIdleTimeout=-1, [general] instanceIdleTimeout=-1, guiApplications=false' = New-Object System.Collections.Generic.List[string]
        'Desktop: no idle timeouts, guiApplications=true'                                       = New-Object System.Collections.Generic.List[string]
        'autoMemoryReclaim=gradual and sparseVhd=false under [experimental] only'              = New-Object System.Collections.Generic.List[string]
        '64GB host: memory=48GB, swap=16GB, processors=16'                                      = New-Object System.Collections.Generic.List[string]
      }
      $cases = 0
      foreach ($prof in @('Desktop', 'Server')) {
        foreach ($arch in @('x64', 'arm64')) {
          foreach ($build in @(19045, 22000, 26100)) {
            foreach ($nat in @($false, $true)) {
              $cases++
              $label = "$prof/$arch/$build/nat=$nat"
              try {
                $text = Invoke-OmwWslConfigGenerator -ConfigProfile $prof -HostMemoryGB 64 -HostLogicalProcessors 16 -HostArch $arch -HostBuild $build -ForceNAT:$nat -DryRun -WslConfigPath $absent
                $ini = Read-TestIni ([string]$text)
              } catch {
                $rules['every key is a verified key in its verified section'].Add("${label}: generator failed: $($_.Exception.Message)")
                continue
              }
              $v = { param($section, $key) Get-IniValue $ini $section $key }
              foreach ($e in $ini) {
                if (-not $VerifiedSection.ContainsKey($e.Key) -or $VerifiedSection[$e.Key] -ne $e.Section) { $rules['every key is a verified key in its verified section'].Add("${label}: [$($e.Section)] $($e.Key)") }
              }
              $ids = @($ini | ForEach-Object { '{0}.{1}' -f $_.Section, $_.Key.ToLowerInvariant() })
              if (@($ids | Sort-Object -Unique).Count -ne $ids.Count) { $rules['no key appears twice in a section'].Add($label) }
              $nested = & $v 'wsl2' 'nestedVirtualization'
              if (($arch -eq 'x64' -and $build -ge 22000) -ne ($nested -eq 'true')) { $rules['nestedVirtualization only on x64 Windows 11, never on ARM64'].Add("${label}: $nested") }
              $mirrored = ($build -ge 22621) -and -not $nat
              if ((& $v 'wsl2' 'networkingMode') -ne $(if ($mirrored) { 'mirrored' } else { 'NAT' })) { $rules['mirrored networking exactly when build >= 22621 and no -ForceNAT'].Add($label) }
              if ($mirrored) {
                if ($null -ne (& $v 'wsl2' 'localhostForwarding') -or (& $v 'experimental' 'hostAddressLoopback') -ne 'true' -or (& $v 'experimental' 'ignoredPorts') -ne '5353,5355' -or (& $v 'wsl2' 'dnsTunneling') -ne 'true') {
                  $rules['mirrored: no localhostForwarding; hostAddressLoopback, ignoredPorts in [experimental]'].Add($label)
                }
              } else {
                if ((& $v 'wsl2' 'localhostForwarding') -ne 'true' -or (& $v 'wsl2' 'dnsTunneling') -ne 'false' -or (& $v 'wsl2' 'autoProxy') -ne 'false' -or $null -ne (& $v 'experimental' 'hostAddressLoopback') -or $null -ne (& $v 'experimental' 'ignoredPorts')) {
                  $rules['NAT: localhostForwarding=true, dnsTunneling=false, autoProxy=false, no mirrored-only keys'].Add($label)
                }
              }
              if ($prof -eq 'Server') {
                if ((& $v 'wsl2' 'vmIdleTimeout') -ne '-1' -or (& $v 'general' 'instanceIdleTimeout') -ne '-1' -or (& $v 'wsl2' 'guiApplications') -ne 'false') {
                  $rules['Server: [wsl2] vmIdleTimeout=-1, [general] instanceIdleTimeout=-1, guiApplications=false'].Add($label)
                }
              } else {
                if ($null -ne (& $v 'wsl2' 'vmIdleTimeout') -or $null -ne (& $v 'general' 'instanceIdleTimeout') -or (& $v 'wsl2' 'guiApplications') -ne 'true') {
                  $rules['Desktop: no idle timeouts, guiApplications=true'].Add($label)
                }
              }
              if ((& $v 'experimental' 'autoMemoryReclaim') -ne 'gradual' -or (& $v 'experimental' 'sparseVhd') -ne 'false' -or $null -ne (& $v 'wsl2' 'autoMemoryReclaim') -or $null -ne (& $v 'wsl2' 'sparseVhd')) {
                $rules['autoMemoryReclaim=gradual and sparseVhd=false under [experimental] only'].Add($label)
              }
              if ((& $v 'wsl2' 'memory') -ne '48GB' -or (& $v 'wsl2' 'swap') -ne '16GB' -or (& $v 'wsl2' 'processors') -ne '16') { $rules['64GB host: memory=48GB, swap=16GB, processors=16'].Add($label) }
            }
          }
        }
      }
      foreach ($rule in $rules.Keys) {
        $violations = $rules[$rule]
        if ($violations.Count -eq 0) { Pass "Generator matrix ($cases profile/arch/build/NAT cases): $rule" }
        else { Fail "Generator matrix ($cases profile/arch/build/NAT cases): $rule" (($violations | Select-Object -First 4) -join '; ') }
      }
      Check '-KeepGui keeps WSLg on in the Server profile' {
        $ini = Read-TestIni ([string](Invoke-OmwWslConfigGenerator -ConfigProfile Server -KeepGui -HostMemoryGB 32 -HostLogicalProcessors 8 -HostArch x64 -HostBuild 26100 -DryRun -WslConfigPath $absent))
        (Get-IniValue $ini 'wsl2' 'guiApplications') -eq 'true' -and (Get-IniValue $ini 'general' 'instanceIdleTimeout') -eq '-1'
      }
      Check 'Existing file: unknown/misplaced keys are reported, not changed' {
        $m = Merge-OmwWslConfig -ExistingText "[wsl2]`npageReporting=true`nbestEffortDnsParsing=true`n" -Desired @(New-OmwSetting 'wsl2' 'memory' '8GB')
        ($m.Text -match '(?m)^pageReporting=true\r?$') -and ($m.Text -match '(?m)^bestEffortDnsParsing=true\r?$') -and
        @($m.Notices | Where-Object { $_ -like '*pageReporting*' }).Count -eq 1 -and @($m.Notices | Where-Object { $_ -like '*bestEffortDnsParsing belongs in `[experimental`]*' }).Count -eq 1
      }
    }

    # End-to-end through the command line: merge, diff, -Force, backup, encoding.
    $mergeDir = New-TestDir 'merge'
    $cfg = Join-Path $mergeDir '.wslconfig'
    $original = "# my settings`r`n[wsl2]`r`nmemory = 8GB # mine`r`nhostAddressLoopback=true`r`nkernelCommandLine = vsyscall=emulate`r`nmemory=4GB`r`n`r`n[experimental]`r`nnetworkingMode=mirrored`r`n`r`n[custom]`r`nfoo=bar`r`n"
    $originalBytes = [byte[]](@(0xEF, 0xBB, 0xBF) + [System.Text.Encoding]::UTF8.GetBytes($original))
    [System.IO.File]::WriteAllBytes($cfg, $originalBytes)
    $serverArgs = @('-Profile', 'Server', '-HostMemoryGB', '64', '-HostLogicalProcessors', '18', '-HostArch', 'arm64', '-HostBuild', '26100', '-WslConfigPath', $cfg)

    $r = Invoke-TestScript $Gen ($serverArgs + '-DryRun')
    Check '-DryRun exits 0 and shows a unified diff of the merge' { $r.ExitCode -eq 0 -and $r.Text -match '(?m)^@@ -1,' -and $r.Text -match '(?m)^\+instanceIdleTimeout=-1' -and $r.Text -match '(?m)^-hostAddressLoopback=true' }
    Check '-DryRun writes nothing (same bytes, no backup, no temp file)' { (Test-SameBytes (Get-Bytes $cfg) $originalBytes) -and @(Get-ChildItem -LiteralPath $mergeDir -Force).Count -eq 1 }
    $r = Invoke-TestScript $Gen $serverArgs
    Check 'Without -Force a non-interactive run asks, gets no answer and writes nothing' { $r.ExitCode -eq 0 -and $r.Text -match 'No changes written' -and (Test-SameBytes (Get-Bytes $cfg) $originalBytes) }
    $r = Invoke-TestScript $Gen ($serverArgs + '-Force')
    $newBytes = Get-Bytes $cfg
    $newText = [System.Text.Encoding]::UTF8.GetString($newBytes)
    $newIni = Read-TestIni $newText
    Check '-Force writes the merged file' { $r.ExitCode -eq 0 -and $r.Text -match 'Wrote ' }
    Check 'Written as UTF-8 without BOM (a BOM in the old file is dropped)' { $newBytes[0] -ne 0xEF }
    Check 'Written with CRLF line endings throughout, ending in CRLF' { (($newText -replace "`r`n", '') -notmatch "[`r`n]") -and $newText.EndsWith("`r`n") }
    Check 'Unknown section, comments and unmanaged keys are kept verbatim' { $newText.Contains("[custom]`r`nfoo=bar") -and $newText.Contains('# my settings') -and $newText.Contains('kernelCommandLine = vsyscall=emulate') }
    Check 'Managed key is updated in place and keeps its trailing comment' { $newText.Contains("memory=48GB # mine`r`n") }
    Check 'Second copy of a managed key is commented out, not deleted' { $newText -match '(?m)^# disabled by omarchy-wsl \(duplicate \[wsl2\] memory.*\): memory=4GB\r?$' }
    Check 'hostAddressLoopback under [wsl2] is commented out and set under [experimental]' {
      ($newText -match '(?m)^# disabled by omarchy-wsl \(WSL reads hostAddressLoopback from \[experimental\]\): hostAddressLoopback=true\r?$') -and (Get-IniValue $newIni 'experimental' 'hostAddressLoopback') -eq 'true' -and $null -eq (Get-IniValue $newIni 'wsl2' 'hostAddressLoopback')
    }
    Check 'Old [experimental] networkingMode is commented out; [wsl2] networkingMode is set' {
      ($newText -match '(?m)^# disabled by omarchy-wsl \(old \[experimental\] spelling of \[wsl2\] networkingMode\): networkingMode=mirrored\r?$') -and (Get-IniValue $newIni 'wsl2' 'networkingMode') -eq 'mirrored' -and $null -eq (Get-IniValue $newIni 'experimental' 'networkingMode')
    }
    Check 'Server keys landed in their sections: [wsl2] vmIdleTimeout, [general] instanceIdleTimeout' { (Get-IniValue $newIni 'wsl2' 'vmIdleTimeout') -eq '-1' -and (Get-IniValue $newIni 'general' 'instanceIdleTimeout') -eq '-1' }
    Check 'Every verified key in the merged file sits in its verified section' { @($newIni | Where-Object { $VerifiedSection.ContainsKey($_.Key) -and $VerifiedSection[$_.Key] -ne $_.Section }).Count -eq 0 }
    $backups = @(Get-ChildItem -LiteralPath $mergeDir -Force -Filter '.wslconfig.bak-*')
    Check 'Previous file backed up as .wslconfig.bak-<yyyyMMdd-HHmmss> with its exact bytes' { $backups.Count -eq 1 -and $backups[0].Name -match '^\.wslconfig\.bak-\d{8}-\d{6}$' -and (Test-SameBytes (Get-Bytes $backups[0].FullName) $originalBytes) }
    Check 'No temporary file left next to .wslconfig' { @(Get-ChildItem -LiteralPath $mergeDir -Force -Filter '*.tmp-*').Count -eq 0 }
    $r = Invoke-TestScript $Gen ($serverArgs + '-Force')
    Check 'Re-running is idempotent: up to date, no write, no new backup' { $r.ExitCode -eq 0 -and $r.Text -match 'already up to date' -and (Test-SameBytes (Get-Bytes $cfg) $newBytes) -and @(Get-ChildItem -LiteralPath $mergeDir -Force -Filter '.wslconfig.bak-*').Count -eq 1 }
    $r = Invoke-TestScript $Gen @('-Profile', 'Desktop', '-HostMemoryGB', '64', '-HostLogicalProcessors', '18', '-HostArch', 'arm64', '-HostBuild', '26100', '-WslConfigPath', $cfg, '-Force')
    $deskIni = Read-TestIni ([System.IO.File]::ReadAllText($cfg))
    Check 'Desktop profile leaves existing idle timeouts alone and says so' { $r.ExitCode -eq 0 -and (Get-IniValue $deskIni 'wsl2' 'vmIdleTimeout') -eq '-1' -and (Get-IniValue $deskIni 'general' 'instanceIdleTimeout') -eq '-1' -and (Get-IniValue $deskIni 'wsl2' 'guiApplications') -eq 'true' -and $r.Text -match 'Server-profile setting' }

    $lfDir = New-TestDir 'lf'
    $lfCfg = Join-Path $lfDir '.wslconfig'
    $quiet = Invoke-TestScript $Gen @('-DryRun', '-Quiet', '-HostMemoryGB', '16', '-HostLogicalProcessors', '8', '-HostArch', 'x64', '-HostBuild', '26100', '-WslConfigPath', $lfCfg)
    Check '-DryRun -Quiet prints only the resulting file' { $quiet.ExitCode -eq 0 -and $quiet.Text.StartsWith('# .wslconfig') -and $quiet.Text -notmatch '\[\*\]' }
    Write-Utf8 $lfCfg (($quiet.Text.TrimEnd() -replace "`r`n", "`n") + "`n")
    $lfBytes = Get-Bytes $lfCfg
    $r = Invoke-TestScript $Gen @('-HostMemoryGB', '16', '-HostLogicalProcessors', '8', '-HostArch', 'x64', '-HostBuild', '26100', '-WslConfigPath', $lfCfg, '-Force')
    Check 'An LF-only file with the right values is left alone (no rewrite for line endings)' { $r.ExitCode -eq 0 -and $r.Text -match 'already up to date' -and (Test-SameBytes (Get-Bytes $lfCfg) $lfBytes) }

    $ex = Invoke-TestScript $Gen @('-DryRun', '-Quiet', '-HostMemoryGB', '32', '-HostLogicalProcessors', '16', '-HostArch', 'x64', '-HostBuild', '26100', '-WslConfigPath', (Join-Path $script:Temp 'absent2.wslconfig'))
    Check 'wsl/wslconfig.example equals the generator output for its documented parameters' { (Get-IniCanonical (Read-TestIni $ex.Text)) -ceq (Get-IniCanonical (Read-TestIni ([System.IO.File]::ReadAllText($Example)))) }
    Check 'wsl/wslconfig.example: no pageReporting, no [wsl2] autoMemoryReclaim or sparseVhd' {
      $exIni = Read-TestIni ([System.IO.File]::ReadAllText($Example))
      @($exIni | Where-Object { $_.Key -eq 'pageReporting' }).Count -eq 0 -and $null -eq (Get-IniValue $exIni 'wsl2' 'autoMemoryReclaim') -and (Get-IniValue $exIni 'experimental' 'sparseVhd') -eq 'false'
    }
    if (-not $script:OnWindows) {
      $r = Invoke-TestScript $Gen @('-HostMemoryGB', '16', '-HostLogicalProcessors', '8', '-HostArch', 'x64', '-HostBuild', '26100')
      Check 'Off Windows, a real run without -WslConfigPath fails instead of guessing a path' { $r.ExitCode -ne 0 -and $r.Text -match 'WslConfigPath' }
      $r = Invoke-TestScript $Gen @('-DryRun', '-WslConfigPath', (Join-Path $script:Temp 'x.wslconfig'))
      Check 'Off Windows, missing -HostMemoryGB is an error (no silent 16GB guess)' { $r.ExitCode -ne 0 -and $r.Text -match 'HostMemoryGB' }
    } else {
      Skip 'Off-Windows path checks (running on Windows)'
    }
    Check 'Old guest-sized bash generator is gone' { -not (Test-Path -LiteralPath (Join-Path $script:Root 'tools/generate-wslconfig.sh')) }

  }

  Invoke-Section '2. tools/register-wsl-autostart.ps1' {
    $ns = @{ t = 'http://schemas.microsoft.com/windows/2004/02/mit/task' }
    function Get-TaskXml([string]$Text) {
      $m = [regex]::Match($Text, '(?s)<\?xml.*?</Task>')
      if (-not $m.Success) { throw 'no task XML in the output' }
      return [xml]$m.Value
    }
    function Get-TaskNodes($Xml, [string]$XPath) { return , @(Select-Xml -Xml $Xml -XPath $XPath -Namespace $ns | ForEach-Object { $_.Node }) }

    $r = Invoke-TestScript $Auto @('-DryRun', '-UserId', 'EXAMPLE\jane', '-Launcher', 'Wsl')
    $x = Get-TaskXml $r.Text
    Check 'Default: -DryRun exits 0 and names the task "Omarchy WSL autostart (Omarchy)"' { $r.ExitCode -eq 0 -and $r.Text -match 'Omarchy WSL autostart \(Omarchy\)' }
    Check 'Default: logon trigger for that user, 15 s delay' { (Get-TaskNodes $x '//t:LogonTrigger/t:UserId')[0].InnerText -eq 'EXAMPLE\jane' -and (Get-TaskNodes $x '//t:LogonTrigger/t:Delay')[0].InnerText -eq 'PT15S' -and (Get-TaskNodes $x '//t:BootTrigger').Count -eq 0 }
    Check 'Default: runs as the user with an interactive token, least privilege' { (Get-TaskNodes $x '//t:Principal/t:LogonType')[0].InnerText -eq 'InteractiveToken' -and (Get-TaskNodes $x '//t:Principal/t:RunLevel')[0].InnerText -eq 'LeastPrivilege' -and (Get-TaskNodes $x '//t:Principal/t:UserId')[0].InnerText -eq 'EXAMPLE\jane' }
    Check 'Default: one action, %SystemRoot%\System32\wsl.exe -d Omarchy --exec /bin/true' {
      $exec = Get-TaskNodes $x '//t:Actions/t:Exec'
      $exec.Count -eq 1 -and (Get-TaskNodes $x '//t:Exec/t:Command')[0].InnerText -eq '%SystemRoot%\System32\wsl.exe' -and (Get-TaskNodes $x '//t:Exec/t:Arguments')[0].InnerText -eq '-d Omarchy --exec /bin/true'
    }
    Check 'Default: 5 minute limit, runs on battery, ignores overlapping starts' {
      (Get-TaskNodes $x '//t:Settings/t:ExecutionTimeLimit')[0].InnerText -eq 'PT5M' -and (Get-TaskNodes $x '//t:Settings/t:DisallowStartIfOnBatteries')[0].InnerText -eq 'false' -and
      (Get-TaskNodes $x '//t:Settings/t:StopIfGoingOnBatteries')[0].InnerText -eq 'false' -and (Get-TaskNodes $x '//t:Settings/t:MultipleInstancesPolicy')[0].InnerText -eq 'IgnoreNew'
    }
    $r = Invoke-TestScript $Auto @('-DryRun', '-UserId', 'EXAMPLE\jane', '-KeepAlive', '-Launcher', 'Wslg', '-Distro', 'Omarchy-Dev')
    $x = Get-TaskXml $r.Text
    Check '-KeepAlive: second action runs /bin/sleep infinity via wslg.exe (no console window)' {
      $args2 = @(Get-TaskNodes $x '//t:Exec/t:Arguments' | ForEach-Object { $_.InnerText })
      $cmds = @(Get-TaskNodes $x '//t:Exec/t:Command' | ForEach-Object { $_.InnerText } | Sort-Object -Unique)
      $args2.Count -eq 2 -and $args2[0] -eq '-d Omarchy-Dev --exec /bin/true' -and $args2[1] -eq '-d Omarchy-Dev --exec /bin/sleep infinity' -and $cmds.Count -eq 1 -and $cmds[0] -eq '%ProgramFiles%\WSL\wslg.exe'
    }
    Check '-KeepAlive: no execution time limit (PT0S)' { (Get-TaskNodes $x '//t:Settings/t:ExecutionTimeLimit')[0].InnerText -eq 'PT0S' }
    $r = Invoke-TestScript $Auto @('-DryRun', '-UserId', 'EXAMPLE\jane', '-AtStartup', '-DelaySeconds', '0')
    $x = Get-TaskXml $r.Text
    Check '-AtStartup: boot trigger, S4U logon by default, no delay element with -DelaySeconds 0' { (Get-TaskNodes $x '//t:BootTrigger').Count -eq 1 -and (Get-TaskNodes $x '//t:LogonTrigger').Count -eq 0 -and (Get-TaskNodes $x '//t:Principal/t:LogonType')[0].InnerText -eq 'S4U' -and (Get-TaskNodes $x '//t:Delay').Count -eq 0 }
    Check '-AtStartup: warns that registration needs an elevated PowerShell' { $r.Text -match 'elevated' }
    $r = Invoke-TestScript $Auto @('-DryRun', '-UserId', 'EXAMPLE\jane', '-AtStartup', '-LogonType', 'Password')
    Check '-AtStartup -LogonType Password: Password logon type' { (Get-TaskNodes (Get-TaskXml $r.Text) '//t:Principal/t:LogonType')[0].InnerText -eq 'Password' }
    $r = Invoke-TestScript $Auto @('-DryRun', '-UserId', 'EXAMPLE\jane', '-AtStartup', '-LogonType', 'Interactive')
    Check '-AtStartup -LogonType Interactive is refused (cannot run before logon)' { $r.ExitCode -ne 0 -and $r.Text -match 'S4U or Password' }
    $r = Invoke-TestScript $Auto @('-DryRun', '-UserId', 'EXAMPLE\a&b<c>"d', '-Launcher', 'Wsl')
    Check 'User names are XML-escaped (task XML still parses and round-trips)' { $r.ExitCode -eq 0 -and (Get-TaskNodes (Get-TaskXml $r.Text) '//t:Principal/t:UserId')[0].InnerText -eq 'EXAMPLE\a&b<c>"d' }
    $r = Invoke-TestScript $Auto @('-Unregister', '-DryRun')
    Check '-Unregister -DryRun only reports what it would remove' { $r.ExitCode -eq 0 -and $r.Text -match 'would remove the scheduled task \\Omarchy WSL autostart \(Omarchy\)' }
    if (-not $script:OnWindows) {
      $r = Invoke-TestScript $Auto @('-UserId', 'EXAMPLE\jane')
      Check 'Off Windows, registering (no -DryRun) fails with a clear message' { $r.ExitCode -ne 0 -and $r.Text -match 'only available on Windows' }
    } else {
      Skip 'Off-Windows registration check (running on Windows)'
    }
    foreach ($bad in @("Omarchy`n", "Omarchy`r`n", 'bad name', 'a;b', ('x' * 65), 'Om/archy', '..\x', '')) {
      $shown = ($bad -replace "`r", '<CR>' -replace "`n", '<LF>')
      if ($shown.Length -gt 20) { $shown = $shown.Substring(0, 20) + '...' }
      Check "-Distro '$shown' is rejected by ValidatePattern (\z anchor)" { Test-Throws { & $Auto -Distro $bad -DryRun -UserId 'EXAMPLE\jane' -Launcher Wsl 6>$null } }
    }
    Check "-Distro 'Omarchy-2.dev_x' is accepted" { $o = (& $Auto -Distro 'Omarchy-2.dev_x' -DryRun -UserId 'EXAMPLE\jane' -Launcher Wsl 6>$null) -join "`n"; $o -match '-d Omarchy-2\.dev_x --exec /bin/true' }
    & {
      $out = @(. $Auto -NoRun 6>&1)
      Check 'Dot-sourcing with -NoRun defines functions and produces no output' { $out.Count -eq 0 -and [bool](Get-Command New-OmwAutostartTaskXml -ErrorAction SilentlyContinue) }
      Check 'Task XML builder refuses a startup trigger with an interactive token' { Test-Throws { New-OmwAutostartTaskXml -Distro 'Omarchy' -UserId 'E\j' -Trigger Startup -LogonType InteractiveToken } '*S4U or Password*' }
      Check 'Server idle detection: both -1 keys required, in the right sections' {
        (Test-OmwServerIdleSettings "[wsl2]`r`nvmIdleTimeout=-1`r`n[general]`r`ninstanceIdleTimeout = -1 # keep`r`n") -and
        -not (Test-OmwServerIdleSettings "[wsl2]`nvmIdleTimeout=-1`n") -and
        -not (Test-OmwServerIdleSettings "[wsl2]`nvmIdleTimeout=-1`ninstanceIdleTimeout=-1`n") -and
        -not (Test-OmwServerIdleSettings $null)
      }
      Check 'wsl --list output with UTF-16 NULs is cleaned' { ((ConvertFrom-OmwWslList -Lines @("O`0m`0a`0r`0c`0h`0y`0", '', "U`0b`0u`0n`0t`0u`0")) -join ',') -eq 'Omarchy,Ubuntu' }
    }

  }

  Invoke-Section '3. install/install.ps1' {
    $installText = [System.IO.File]::ReadAllText($Install)
    Check 'Documents the real one-liner (raw.githubusercontent.com/chntllh-labs/omarchy-wsl/main/install/install.ps1)' { $installText.Contains('irm https://raw.githubusercontent.com/chntllh-labs/omarchy-wsl/main/install/install.ps1 | iex') }
    Check 'No dead install.omarchy.org URL, no nonexistent omarchy-wsl-update command' { -not $installText.Contains('install.omarchy.org') -and -not $installText.Contains('omarchy-wsl-update') -and $installText.Contains('omarchy-update') }
    Check 'Installs with wsl --install --from-file --name, falls back to wsl --import' { $installText.Contains("'--install', '--from-file', `$Package, '--name', `$Name") -and $installText.Contains('& wsl.exe --import $Name $InstallPath $Package --version 2') }
    & {
      $out = @(. $Install -NoRun 6>&1)
      Check 'Dot-sourcing with -NoRun defines functions and produces no output' { $out.Count -eq 0 -and [bool](Get-Command Get-OmwAssetName -ErrorAction SilentlyContinue) }
      foreach ($a in @('x86_64', 'AMD64', 'amd64', 'x64', 'X64')) { Check "Asset name: '$a' -> Omarchy-x86_64.wsl" { (Get-OmwAssetName $a) -ceq 'Omarchy-x86_64.wsl' } }
      foreach ($a in @('arm64', 'ARM64', 'Arm64', 'aarch64')) { Check "Asset name: '$a' -> Omarchy-arm64.wsl" { (Get-OmwAssetName $a) -ceq 'Omarchy-arm64.wsl' } }
      foreach ($a in @('x86', 'ARM', 'i686', '')) { Check "Asset name: '$a' is refused" { Test-Throws { Get-OmwAssetName $a } } }
      Check 'Host arch: Machine=ARM64 with emulated AMD64 PowerShell -> arm64' { (Resolve-OmwHostArchitecture @('ARM64', $null, 'AMD64', 'X64')) -eq 'arm64' }
      Check 'Host arch: 32-bit PowerShell on x64 (PROCESSOR_ARCHITEW6432=AMD64) -> x86_64' { (Resolve-OmwHostArchitecture @('AMD64', 'AMD64', 'x86', 'X86')) -eq 'x86_64' }
      Check 'Host arch: x86-only host refused' { Test-Throws { Resolve-OmwHostArchitecture @('x86', 'X86') } '*Unsupported*' }
      $hx = 'a' * 64
      $ha = 'B' * 64
      $sumsText = ('d' * 64) + "  Omarchy-x86_64.wsl.sig`r`n" + ('e' * 64) + "  evil-Omarchy-arm64.wsl`r`n" + "$hx  Omarchy-x86_64.wsl`r`n$ha *Omarchy-arm64.wsl`r`n`r`n# comment`r`n" + ('c' * 64) + "  ./install.ps1`r`nnot a checksum line`r`n"
      $sums = ConvertFrom-OmwSha256Sums -Text $sumsText
      Check 'SHA256SUMS: text and binary (*) entries parsed, hashes lowercased' { $sums['Omarchy-x86_64.wsl'] -ceq $hx -and $sums['Omarchy-arm64.wsl'] -ceq ('b' * 64) }
      Check 'SHA256SUMS: ./ prefix stripped' { $sums.ContainsKey('install.ps1') }
      Check 'SHA256SUMS: names match exactly (no .sig or prefixed look-alikes)' { (Get-OmwExpectedSha256 -Sums $sums -Name 'Omarchy-x86_64.wsl') -ceq $hx -and (Get-OmwExpectedSha256 -Sums $sums -Name 'Omarchy-arm64.wsl') -ceq ('b' * 64) }
      Check 'SHA256SUMS: names are case-sensitive' { -not $sums.ContainsKey('omarchy-x86_64.wsl') }
      Check 'SHA256SUMS: only look-alike names (.sig, prefixed, .old) -> no entry, install refused' {
        $alike = ConvertFrom-OmwSha256Sums -Text (('d' * 64) + "  Omarchy-x86_64.wsl.sig`n" + ('e' * 64) + "  evil-Omarchy-x86_64.wsl`n" + ('f' * 64) + "  Omarchy-x86_64.wsl.old`n")
        Test-Throws { Get-OmwExpectedSha256 -Sums $alike -Name 'Omarchy-x86_64.wsl' } '*no entry*'
      }
      Check 'SHA256SUMS: missing entry refuses to install' { Test-Throws { Get-OmwExpectedSha256 -Sums $sums -Name 'Omarchy-riscv64.wsl' } '*no entry*' }
      Check 'SHA256SUMS: conflicting duplicate entries are rejected' { Test-Throws { ConvertFrom-OmwSha256Sums -Text "$hx  a.wsl`n$('f' * 64)  a.wsl`n" } '*twice*' }
      Check 'SHA256SUMS: identical duplicate entries are accepted' { (ConvertFrom-OmwSha256Sums -Text "$hx  a.wsl`n$hx  a.wsl`n")['a.wsl'] -ceq $hx }
      Check 'SHA256SUMS: empty file yields no entries' { (ConvertFrom-OmwSha256Sums -Text '').Count -eq 0 }
      Check 'wsl --version: "WSL version: 2.4.4.0" -> 2.4.4.0' { (ConvertFrom-OmwWslVersionText @('WSL version: 2.4.4.0', 'Kernel version: 6.6.36.6-1')) -eq [version]'2.4.4.0' }
      Check 'wsl --version: localized text and UTF-16 NULs parse' { (ConvertFrom-OmwWslVersionText @("W`0S`0L`0-`0V`0e`0r`0s`0i`0o`0n`0:`0 `02`0.`05`0.`01`00`0.`00`0")) -eq [version]'2.5.10.0' }
      Check 'wsl --version: no version -> $null' { $null -eq (ConvertFrom-OmwWslVersionText @('Usage: wsl.exe [Argument]')) }
      Check '--from-file needs WSL 2.4.4 or later' {
        (Test-OmwFromFileSupported ([version]'2.4.4.0')) -and (Test-OmwFromFileSupported ([version]'2.10.1.0')) -and
        -not (Test-OmwFromFileSupported ([version]'2.4.3.0')) -and -not (Test-OmwFromFileSupported ([version]'2.3.26.0')) -and -not (Test-OmwFromFileSupported $null)
      }
      Check 'Side-by-side name: first free <Name>-<n>' { (Get-OmwFreeName -Base 'Omarchy' -Installed @('Omarchy', 'Omarchy-1', 'Ubuntu')) -ceq 'Omarchy-2' }
      Check 'Release URLs: SHA256SUMS and image come from the same tag' {
        (Get-OmwReleaseAssetUrl -Repo 'chntllh-labs/omarchy-wsl' -Tag 'v4.5.0' -Name 'Omarchy-arm64.wsl') -ceq 'https://github.com/chntllh-labs/omarchy-wsl/releases/download/v4.5.0/Omarchy-arm64.wsl' -and
        (Get-OmwReleaseAssetUrl -Repo 'chntllh-labs/omarchy-wsl' -Tag 'v4.5.0' -Name 'SHA256SUMS') -ceq 'https://github.com/chntllh-labs/omarchy-wsl/releases/download/v4.5.0/SHA256SUMS'
      }
      $cmds = Get-OmwVerificationCommands -Repo 'chntllh-labs/omarchy-wsl' -AssetName 'Omarchy-x86_64.wsl'
      Check 'Prints the exact gh attestation verify command' { $cmds[0] -ceq 'gh attestation verify Omarchy-x86_64.wsl --repo chntllh-labs/omarchy-wsl' }
      Check 'Prints the exact cosign verify-blob command for SHA256SUMS.sigstore.json' { $cmds[1] -ceq "cosign verify-blob --bundle SHA256SUMS.sigstore.json --certificate-identity-regexp 'https://github.com/chntllh-labs/omarchy-wsl/.github/workflows/release.yml@refs/tags/v.*' --certificate-oidc-issuer https://token.actions.githubusercontent.com SHA256SUMS" }
      Check 'Existing distro + -NonInteractive stops with guidance (no prompt)' { Test-Throws { Resolve-OmwInstallPlan -DistroName 'Omarchy' -Installed @('Omarchy') -NonInteractive 6>$null } '*omarchy-update*' }
      Check 'Existing distro + -ForceSideBySide installs as Omarchy-1' { $p = Resolve-OmwInstallPlan -DistroName 'Omarchy' -Installed @('Omarchy') -ForceSideBySide 6>$null; $p.Action -eq 'Install' -and $p.Name -ceq 'Omarchy-1' }
      Check 'New name installs directly' { $p = Resolve-OmwInstallPlan -DistroName 'Omarchy' -Installed @('Ubuntu'); $p.Action -eq 'Install' -and $p.Name -ceq 'Omarchy' }
    }
    Check "-DistroName with a trailing newline is rejected (\z anchor)" { Test-Throws { & $Install -DistroName "Omarchy`n" -NoRun } }
    Check '-ReleaseTag must be latest or a v-tag' { (Test-Throws { & $Install -ReleaseTag 'main; rm' -NoRun }) -and -not (Test-Throws { & $Install -ReleaseTag 'v4.5.0' -NoRun }) }
    $ErrorActionPreference = 'Continue'
    $iexOut = (& $script:Pwsh -NoProfile -NonInteractive -Command "try { Invoke-Expression ([System.IO.File]::ReadAllText('$Install')) } catch { Write-Output ('CAUGHT: ' + `$_.Exception.Message) }; Write-Output 'SESSION-ALIVE'" 2>&1 | ForEach-Object { [string]$_ }) -join "`n"
    $ErrorActionPreference = 'Stop'
    if (-not $script:OnWindows) {
      Check 'Under Invoke-Expression a failure throws and the session survives (no exit)' { $iexOut -match 'CAUGHT: Omarchy-WSL installs on Windows only' -and $iexOut -match 'SESSION-ALIVE' }
    } else {
      Skip 'Invoke-Expression failure path (would start a real install on Windows)'
    }

  }

  Invoke-Section '4. bin/sync-theme.ps1' {
    $fixture = @'
// Windows Terminal settings (user comments must survive)
{
    "$schema": "https://aka.ms/terminal-profiles-schema",
    "defaultProfile": "{00000000-0000-0000-0000-000000000001}",
    /* block comment before profiles */
    "profiles": {
        "defaults": {
            "font": { "face": "Cascadia Code" }, // trailing comment
        },
        "list": [
            {
                "guid": "{00000000-0000-0000-0000-000000000002}",
                "name": "Nord",
                "commandline": "ssh nord.example",
                "colorScheme": "Campbell",
            },
            {
                "guid": "{00000000-0000-0000-0000-000000000001}",
                "name": "Omarchy",
                "source": "Microsoft.WSL"
            },
        ]
    },
    "schemes": [
        { "name": "Campbell", "background": "#0C0C0C" },
        {
            // stale copy of the scheme
            "name": "Nord",
            "background": "#000000"
        },
    ],
    "actions": [ { "command": "copy", "keys": "ctrl+c" }, ],
}
'@
    $themeDir = New-TestDir 'theme'
    $settings = Join-Path $themeDir 'settings.json'
    Write-Utf8 $settings $fixture
    $fixtureBytes = Get-Bytes $settings

    $r = Invoke-TestScript $Theme @('-Theme', 'Nord', '-SettingsPath', $settings)
    $after = [System.IO.File]::ReadAllText($settings)
    $afterBytes = Get-Bytes $settings
    $doc = ConvertFrom-TestJsonc $after
    Check 'Sync exits 0 and reports success' { $r.ExitCode -eq 0 -and $r.Text -match 'completed successfully' }
    Check 'A profile named like the scheme ("Nord") keeps every setting (issue #76)' {
      $p = @($doc.profiles.list | Where-Object { $_.name -eq 'Nord' })
      $p.Count -eq 1 -and $p[0].commandline -eq 'ssh nord.example' -and $p[0].colorScheme -eq 'Campbell' -and $p[0].guid -eq '{00000000-0000-0000-0000-000000000002}'
    }
    Check 'The target profile (Omarchy) now uses the Nord scheme' { @($doc.profiles.list | Where-Object { $_.name -eq 'Omarchy' })[0].colorScheme -eq 'Nord' }
    Check 'Exactly one Nord scheme, with the catalog colors' { $s = @($doc.schemes | Where-Object { $_.name -eq 'Nord' }); $s.Count -eq 1 -and $s[0].background -eq '#2e3440' -and $s[0].brightWhite -eq '#eceff4' -and $s[0].cursorColor -eq '#d8dee9' }
    Check 'Emitted scheme has only Windows Terminal keys (no vscodeTheme)' { $s = @($doc.schemes | Where-Object { $_.name -eq 'Nord' })[0]; @($s.PSObject.Properties.Name).Count -eq 21 -and $after -notmatch 'vscodeTheme' }
    Check 'Other schemes, profiles.defaults and actions are untouched' { @($doc.schemes | Where-Object { $_.name -eq 'Campbell' })[0].background -eq '#0C0C0C' -and $doc.profiles.defaults.font.face -eq 'Cascadia Code' -and $after.Contains('"actions": [ { "command": "copy", "keys": "ctrl+c" }, ],') }
    Check 'Comments outside the replaced scheme survive' { $after.Contains('// Windows Terminal settings (user comments must survive)') -and $after.Contains('/* block comment before profiles */') -and $after.Contains('// trailing comment') }
    Check 'settings.json.omarchy-orig keeps the original bytes' { Test-SameBytes (Get-Bytes ($settings + '.omarchy-orig')) $fixtureBytes }
    Check 'settings.json.bak holds the version before this sync' { Test-SameBytes (Get-Bytes ($settings + '.bak')) $fixtureBytes }
    $r = Invoke-TestScript $Theme @('-Theme', 'Nord', '-SettingsPath', $settings)
    Check 'Same theme again: no rewrite, no backup rotation' { $r.ExitCode -eq 0 -and $r.Text -match 'Already up to date' -and (Test-SameBytes (Get-Bytes $settings) $afterBytes) -and -not (Test-Path -LiteralPath ($settings + '.bak.1')) }
    $r = Invoke-TestScript $Theme @('-Theme', 'TokyoNight', '-SettingsPath', $settings)
    $tokyoBytes = Get-Bytes $settings
    Check 'Switching theme: .omarchy-orig is never overwritten' { $r.ExitCode -eq 0 -and (Test-SameBytes (Get-Bytes ($settings + '.omarchy-orig')) $fixtureBytes) }
    Check 'Switching theme: backups rotate (.bak = previous, .bak.1 = original)' { (Test-SameBytes (Get-Bytes ($settings + '.bak')) $afterBytes) -and (Test-SameBytes (Get-Bytes ($settings + '.bak.1')) $fixtureBytes) }
    Check 'Switching theme: Tokyo Night added, the Nord scheme stays, Omarchy profile switched' { $d = ConvertFrom-TestJsonc ([System.IO.File]::ReadAllText($settings)); @($d.schemes).Count -eq 3 -and @($d.profiles.list | Where-Object { $_.name -eq 'Omarchy' })[0].colorScheme -eq 'Tokyo Night' }
    $r = Invoke-TestScript $Theme @('-Restore', '-SettingsPath', $settings)
    Check '-Restore puts the original file back' { $r.ExitCode -eq 0 -and (Test-SameBytes (Get-Bytes $settings) $fixtureBytes) }
    Check '-Restore keeps .omarchy-orig and saves the replaced version as .bak' { (Test-SameBytes (Get-Bytes ($settings + '.omarchy-orig')) $fixtureBytes) -and (Test-SameBytes (Get-Bytes ($settings + '.bak')) $tokyoBytes) }
    $r = Invoke-TestScript $Theme @('-Restore', '-RestoreFrom', 'Latest', '-SettingsPath', $settings)
    Check '-Restore -RestoreFrom Latest undoes the restore' { $r.ExitCode -eq 0 -and (Test-SameBytes (Get-Bytes $settings) $tokyoBytes) }
    for ($i = 0; $i -lt 6; $i++) { [void](Invoke-TestScript $Theme @('-Theme', @('Nord', 'Dracula')[$i % 2], '-SettingsPath', $settings)) }
    Check 'Rotation is capped at .bak + .bak.1-.bak.4; .omarchy-orig survives every write' { @(Get-ChildItem -LiteralPath $themeDir -Filter 'settings.json.bak*').Count -eq 5 -and (Test-SameBytes (Get-Bytes ($settings + '.omarchy-orig')) $fixtureBytes) }

    $bad = Join-Path $themeDir 'broken.json'
    Write-Utf8 $bad '{ "profiles": [ }'
    $badBytes = Get-Bytes $bad
    $r = Invoke-TestScript $Theme @('-Theme', 'Nord', '-SettingsPath', $bad)
    Check 'Invalid JSONC: non-zero exit and no success message' { $r.ExitCode -ne 0 -and $r.Text -notmatch 'completed successfully' -and $r.Text -match 'JSONC syntax error' }
    Check 'Invalid JSONC: file untouched, no backups made' { (Test-SameBytes (Get-Bytes $bad) $badBytes) -and -not (Test-Path -LiteralPath ($bad + '.bak')) -and -not (Test-Path -LiteralPath ($bad + '.omarchy-orig')) }
    $good2 = Join-Path $themeDir 'good2.json'
    Write-Utf8 $good2 $fixture
    # Two paths cannot be passed through -File as one array, so run this one in-process.
    $multiError = $null
    try { $null = & $Theme -Theme 'Nord' -SettingsPath @($good2, $bad) 6>$null } catch { $multiError = $_.Exception.Message }
    Check 'One bad file among several: the good one is synced, the run still fails' { [string]$multiError -match 'failed for 1 of 2' -and (ConvertFrom-TestJsonc ([System.IO.File]::ReadAllText($good2))).profiles.list[1].colorScheme -eq 'Nord' }

    $defaultsFile = Join-Path $themeDir 'defaults.json'
    Write-Utf8 $defaultsFile $fixture
    $r = Invoke-TestScript $Theme @('-Theme', 'Dracula', '-ApplyToDefaults', '-SettingsPath', $defaultsFile)
    $d = ConvertFrom-TestJsonc ([System.IO.File]::ReadAllText($defaultsFile))
    Check '-ApplyToDefaults sets profiles.defaults.colorScheme and leaves profiles alone' { $r.ExitCode -eq 0 -and $d.profiles.defaults.colorScheme -eq 'Dracula' -and $d.profiles.defaults.font.face -eq 'Cascadia Code' -and @($d.profiles.list | Where-Object { $_.name -eq 'Nord' })[0].colorScheme -eq 'Campbell' -and -not (@($d.profiles.list | Where-Object { $_.name -eq 'Omarchy' })[0].PSObject.Properties['colorScheme']) }
    $missingProfile = Join-Path $themeDir 'missing-profile.json'
    Write-Utf8 $missingProfile $fixture
    $r = Invoke-TestScript $Theme @('-Theme', 'Nord', '-ProfileName', 'Does Not Exist', '-SettingsPath', $missingProfile)
    Check 'Unknown -ProfileName: warns, installs the scheme, exits 0' { $r.ExitCode -eq 0 -and $r.Text -match 'was not found' -and @((ConvertFrom-TestJsonc ([System.IO.File]::ReadAllText($missingProfile))).schemes | Where-Object { $_.name -eq 'Nord' }).Count -eq 1 }
    $noSchemes = Join-Path $themeDir 'no-schemes.json'
    Write-Utf8 $noSchemes "{`r`n    `"profiles`": { `"list`": [ { `"name`": `"Omarchy`" } ] }`r`n}`r`n" -Bom
    $r = Invoke-TestScript $Theme @('-Theme', 'Nord', '-SettingsPath', $noSchemes)
    $nsBytes = Get-Bytes $noSchemes
    $nsText = [System.IO.File]::ReadAllText($noSchemes)
    Check 'No "schemes" array: one is added; result parses' { $r.ExitCode -eq 0 -and @((ConvertFrom-TestJsonc $nsText).schemes).Count -eq 1 }
    Check 'BOM and CRLF of the original file are preserved' { $nsBytes[0] -eq 0xEF -and $nsBytes[1] -eq 0xBB -and $nsBytes[2] -eq 0xBF -and (($nsText -replace "`r`n", '') -notmatch "`n") }
    $r = Invoke-TestScript $Theme @('-ListThemes')
    Check '-ListThemes lists the four built-in palettes' { $r.ExitCode -eq 0 -and $r.Text -match 'TokyoNight' -and $r.Text -match 'CatppuccinMocha' -and $r.Text -match 'Nord' -and $r.Text -match 'Dracula' }
    $r = Invoke-TestScript $Theme @('-Theme', 'NoSuchTheme', '-SettingsPath', $settings)
    Check 'Unknown theme: non-zero exit, no success message' { $r.ExitCode -ne 0 -and $r.Text -notmatch 'completed successfully' }
    Check 'Script no longer claims VS Code sync' { -not ([System.IO.File]::ReadAllText($Theme) -match '(?i)(sync|theme)s? (to|for) VS ?Code|VS ?Code (theme )?sync') }

    & {
      . $Theme -NoRun
      $nord = Get-OmarchyScheme 'Nord'
      Check 'JSONC parser accepts comments and trailing commas' { Test-JsoncValid $fixture }
      foreach ($badText in @('{ "a": 1 } x', '{ "a" 1 }', '{ "a": "unterminated }', '{ /* open comment ', '[1, 2', '{ "a": tru }', '{ , }')) {
        Check "JSONC parser rejects: $badText" { -not (Test-JsoncValid $badText) }
      }
      Check 'JSON string escapes are decoded (unicode escape, newline, quote)' { (ConvertFrom-Jsonc -Text '"A\u0042\n\"q\""').Value -ceq ("AB`n" + '"q"') }
      $synced = Update-WindowsTerminalSettingsText -Text $fixture -Scheme $nord -ProfileName 'Omarchy'
      Check 'Pure update reports a change, and a second pass reports none' { $synced.Changed -and -not (Update-WindowsTerminalSettingsText -Text $synced.Text -Scheme $nord -ProfileName 'Omarchy').Changed }
      $oldRoot = ConvertFrom-Jsonc -Text $fixture
      Check 'Verification accepts the real edit' { $null -eq (Test-ThemeResult -OldRoot $oldRoot -NewRoot (ConvertFrom-Jsonc -Text $synced.Text) -Scheme $nord -ProfileName 'Omarchy' -ProfileFound $true) }
      Check 'Verification rejects an edit that also changed the "Nord" profile (the #76 failure mode)' {
        $tampered = $synced.Text.Replace('"colorScheme": "Campbell"', '"colorScheme": "Nord"')
        $null -ne (Test-ThemeResult -OldRoot $oldRoot -NewRoot (ConvertFrom-Jsonc -Text $tampered) -Scheme $nord -ProfileName 'Omarchy' -ProfileFound $true)
      }
      Check 'Verification rejects any other collateral change' {
        $tampered = $synced.Text.Replace('ssh nord.example', 'ssh other.example')
        $null -ne (Test-ThemeResult -OldRoot $oldRoot -NewRoot (ConvertFrom-Jsonc -Text $tampered) -Scheme $nord -ProfileName 'Omarchy' -ProfileFound $true)
      }
      Check 'Verification rejects wrong scheme colors' {
        $tampered = $synced.Text.Replace('"brightWhite": "#eceff4"', '"brightWhite": "#ffffff"')
        $null -ne (Test-ThemeResult -OldRoot $oldRoot -NewRoot (ConvertFrom-Jsonc -Text $tampered) -Scheme $nord -ProfileName 'Omarchy' -ProfileFound $true)
      }
      Check 'Legacy settings with "profiles" as a plain array are handled' {
        $legacy = '{ "profiles": [ { "name": "Omarchy" }, { "name": "Nord" } ], "schemes": [] }'
        $res = Update-WindowsTerminalSettingsText -Text $legacy -Scheme $nord -ProfileName 'Omarchy'
        $doc2 = ConvertFrom-TestJsonc $res.Text
        $doc2.profiles[0].colorScheme -eq 'Nord' -and -not $doc2.profiles[1].PSObject.Properties['colorScheme'] -and @($doc2.schemes).Count -eq 1
      }
      Check 'A non-array "schemes" is refused, not overwritten' { Test-Throws { Update-WindowsTerminalSettingsText -Text '{ "schemes": {} }' -Scheme $nord } '*not an array*' }
    }

  }

  Invoke-Section '5. Explorer context menu (row 66)' {
    $expected = '"%LOCALAPPDATA%\Microsoft\WindowsApps\wt.exe" -w 0 new-tab -p "Omarchy" -d "%V."'
    $regText = [System.IO.File]::ReadAllText($CtxReg)
    Check '.reg starts with the Registry Editor 5.00 header' { $regText.StartsWith("Windows Registry Editor Version 5.00`r`n") }
    Check '.reg uses CRLF line endings' { ($regText -replace "`r`n", '') -notmatch "`n" }
    $values = New-Object System.Collections.Generic.List[string]
    $joined = [regex]::Replace($regText, "\\\r?\n\s*", '')
    foreach ($m in [regex]::Matches($joined, '(?m)^@=hex\(2\):([0-9a-f,]+)\r?$')) {
      $bytes = [byte[]]@($m.Groups[1].Value.Split(',') | ForEach-Object { [Convert]::ToByte($_, 16) })
      $values.Add([System.Text.Encoding]::Unicode.GetString($bytes))
    }
    Check '.reg: three command values, all REG_EXPAND_SZ (hex(2))' { $values.Count -eq 3 }
    Check '.reg: each command runs "%LOCALAPPDATA%\Microsoft\WindowsApps\wt.exe" by absolute path with "%V."' { @($values | Where-Object { $_ -ceq ($expected + [char]0) }).Count -eq 3 }
    Check '.reg: no command uses a bare wt.exe' { $regText -notmatch '(?m)^@="wt\.exe' -and @([regex]::Matches($regText, '(?m)^@=".*wt\.exe')).Count -eq 0 }
    Check 'unregister .reg removes exactly the three registered keys' { @([regex]::Matches([System.IO.File]::ReadAllText($CtxUnreg), '(?m)^\[-HKEY_CURRENT_USER\\Software\\Classes\\(Directory\\Background|Directory|Drive)\\shell\\OmarchyTerminal\]\r?$')).Count -eq 3 }
    $ctxAst = (Get-ScriptAst $CtxPs1).Ast
    $patterns = @($ctxAst.FindAll({ param($n) $n -is [System.Management.Automation.Language.AttributeAst] -and $n.TypeName.Name -eq 'ValidatePattern' }, $true) | ForEach-Object { $_.PositionalArguments[0].Value })
    Check 'register-explorer-context-menu.ps1: every ValidatePattern ends in \z, none in $' { $patterns.Count -eq 3 -and @($patterns | Where-Object { -not $_.EndsWith('\z') }).Count -eq 0 }
    Check 'register-explorer-context-menu.ps1: -Distro "Omarchy`n" is rejected' { Test-Throws { & $CtxPs1 -Distro "Omarchy`n" -WhatIf } }
    Check 'register-explorer-context-menu.ps1: a label with a newline is rejected' { Test-Throws { & $CtxPs1 -Label "Open`nhere" -WhatIf } }
    Check 'register-explorer-context-menu.ps1 launches wt.exe through its absolute alias path' { [System.IO.File]::ReadAllText($CtxPs1).Contains("Join-Path `$env:LOCALAPPDATA 'Microsoft\WindowsApps\wt.exe'") }

  }

  Invoke-Section '6. distributions/ (Microsoft WSL manifest entry) and removed winget manifest' {
    $frag = [System.IO.File]::ReadAllText($Fragment) | ConvertFrom-Json
    $flavors = @($frag.ModernDistributions.PSObject.Properties.Name)
    $entries = @($frag.ModernDistributions.Omarchy)
    Check 'Fragment: only "ModernDistributions" at the top, one flavor "Omarchy" with one entry' { @($frag.PSObject.Properties.Name).Count -eq 1 -and $flavors.Count -eq 1 -and $flavors[0] -ceq 'Omarchy' -and $entries.Count -eq 1 }
    Check 'Fragment: only the keys validate-modern.py allows' { @($entries[0].PSObject.Properties.Name | Where-Object { @('Name', 'FriendlyName', 'Default', 'Amd64Url', 'Arm64Url') -cnotcontains $_ }).Count -eq 0 }
    Check 'Fragment: Name/FriendlyName Omarchy, Name starts with the flavor, the one default' { $entries[0].Name -ceq 'Omarchy' -and $entries[0].FriendlyName -ceq 'Omarchy' -and $entries[0].Default -eq $true }
    Check 'Fragment: v4.5.0 release URLs for both architectures' {
      $entries[0].Amd64Url.Url -ceq 'https://github.com/chntllh-labs/omarchy-wsl/releases/download/v4.5.0/Omarchy-x86_64.wsl' -and
      $entries[0].Arm64Url.Url -ceq 'https://github.com/chntllh-labs/omarchy-wsl/releases/download/v4.5.0/Omarchy-arm64.wsl'
    }
    Check 'Fragment: Sha256 values in the schema format (0x + 64 hex), all-zero placeholders' { @($entries[0].Amd64Url.Sha256, $entries[0].Arm64Url.Sha256 | Where-Object { $_ -cmatch '^0x0{64}$' }).Count -eq 2 }
    Check 'distributions/README.md explains filling the hashes, validate-modern.py and why not winget' { $t = [System.IO.File]::ReadAllText((Join-Path $script:Root 'distributions/README.md')); $t.Contains('validate-modern.py') -and $t.Contains('SHA256SUMS') -and $t -match 'InstallerType' }
    Check 'Invalid winget manifest removed' { -not (Test-Path -LiteralPath (Join-Path $script:Root 'winget')) }

  }

  Invoke-Section '7. DISTRIBUTION-LIFECYCLE-SPEC.md matches what ships' {
    $specText = [System.IO.File]::ReadAllText($Spec)
    Check 'Spec: no "Signed and verified by" footer' { $specText -notmatch 'Signed and verified by' }
    Check 'Spec: no winget channel, no dead install URL, no omarchy-wsl-update command for users' { $specText -notmatch 'winget install' -and -not $specText.Contains('install.omarchy.org') -and $specText -notmatch 'Omacom\.OmarchyWSL' }
    Check 'Spec: documents instanceIdleTimeout and the autostart task' { $specText.Contains('instanceIdleTimeout') -and $specText.Contains('register-wsl-autostart.ps1') }
    Check 'Spec: release assets and verification match the installer' { $specText.Contains('Omarchy-x86_64.wsl') -and $specText.Contains('Omarchy-arm64.wsl') -and $specText.Contains('SHA256SUMS.sigstore.json') -and $specText.Contains('gh attestation verify') }
  }
} catch {
  Fail 'test harness error' ($_.Exception.Message + ' at ' + $_.InvocationInfo.PositionMessage)
} finally {
  Remove-Item -LiteralPath $script:Temp -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Output ''
Write-Output ("Windows Tools (PowerShell): {0}/{1} passed, {2} failed, {3} skipped" -f $script:Passed, $script:Run, $script:Failed, $script:Skipped)
if ($script:Failed -gt 0) { exit 1 }
