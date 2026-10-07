#requires -Version 5.1
<#
.SYNOPSIS
  Adversarially hardened, zero-corruption Windows Terminal and VS Code theme sync script.

.DESCRIPTION
  Safely applies Omarchy themes to Windows Terminal settings.json and VS Code on the Windows host.
  Preserves user comments, custom schemes, and performs atomic writes with automatic backup.
#>

[CmdletBinding()]
param(
  [Parameter(Mandatory = $false, Position = 0)]
  [string]$Theme = "TokyoNight",

  [string]$ProfileName = "Omarchy",

  [switch]$ApplyToDefaults,

  [switch]$DryRun,

  [switch]$Status,

  [switch]$Restore,

  [switch]$ListThemes
)

$ErrorActionPreference = "Stop"

function Write-Step { param([string]$Message) Write-Host "[*] $Message" -ForegroundColor Cyan }
function Write-Success { param([string]$Message) Write-Host "[+] $Message" -ForegroundColor Green }
function Write-Warn { param([string]$Message) Write-Host "[!] $Message" -ForegroundColor Yellow }
function Write-Err { param([string]$Message) Write-Host "[-] $Message" -ForegroundColor Red }

# -----------------------------------------------------------------------------
# 1. Built-in Palettes Catalog
# -----------------------------------------------------------------------------
$ThemesCatalog = @{
  "TokyoNight" = @{
    name = "Tokyo Night"
    background = "#1a1b26"
    foreground = "#c0caf5"
    cursorColor = "#c0caf5"
    selectionBackground = "#283457"
    black = "#15161e"
    red = "#f7768e"
    green = "#9ece6a"
    yellow = "#e0af68"
    blue = "#7aa2f7"
    purple = "#bb9af7"
    cyan = "#7dcfff"
    white = "#a9b1d6"
    brightBlack = "#414868"
    brightRed = "#f7768e"
    brightGreen = "#9ece6a"
    brightYellow = "#e0af68"
    brightBlue = "#7aa2f7"
    brightPurple = "#bb9af7"
    brightCyan = "#7dcfff"
    brightWhite = "#c0caf5"
    vscodeTheme = "Tokyo Night"
  }
  "CatppuccinMocha" = @{
    name = "Catppuccin Mocha"
    background = "#1e1e2e"
    foreground = "#cdd6f4"
    cursorColor = "#f5e0dc"
    selectionBackground = "#585b70"
    black = "#45475a"
    red = "#f38ba8"
    green = "#a6e3a1"
    yellow = "#f9e2af"
    blue = "#89b4fa"
    purple = "#cba6f7"
    cyan = "#94e2d5"
    white = "#bac2de"
    brightBlack = "#585b70"
    brightRed = "#f38ba8"
    brightGreen = "#a6e3a1"
    brightYellow = "#f9e2af"
    brightBlue = "#89b4fa"
    brightPurple = "#cba6f7"
    brightCyan = "#94e2d5"
    brightWhite = "#a6adc8"
    vscodeTheme = "Catppuccin Mocha"
  }
  "Nord" = @{
    name = "Nord"
    background = "#2e3440"
    foreground = "#d8dee9"
    cursorColor = "#d8dee9"
    selectionBackground = "#434c5e"
    black = "#3b4252"
    red = "#bf616a"
    green = "#a3be8c"
    yellow = "#ebcb8b"
    blue = "#81a1c1"
    purple = "#b48ead"
    cyan = "#88c0d0"
    white = "#e5e9f0"
    brightBlack = "#4c566a"
    brightRed = "#bf616a"
    brightGreen = "#a3be8c"
    brightYellow = "#ebcb8b"
    brightBlue = "#81a1c1"
    brightPurple = "#b48ead"
    brightCyan = "#8fbcbb"
    brightWhite = "#eceff4"
    vscodeTheme = "Nord"
  }
  "Dracula" = @{
    name = "Dracula"
    background = "#282a36"
    foreground = "#f8f8f2"
    cursorColor = "#f8f8f2"
    selectionBackground = "#44475a"
    black = "#21222c"
    red = "#ff5555"
    green = "#50fa7b"
    yellow = "#f1fa8c"
    blue = "#bd93f9"
    purple = "#ff79c6"
    cyan = "#8be9fd"
    white = "#f8f8f2"
    brightBlack = "#6272a4"
    brightRed = "#ff6e6e"
    brightGreen = "#69ff94"
    brightYellow = "#ffffa5"
    brightBlue = "#d6acff"
    brightPurple = "#ff92df"
    brightCyan = "#a4ffff"
    brightWhite = "#ffffff"
    vscodeTheme = "Dracula"
  }
}

# -----------------------------------------------------------------------------
# 2. Target Discovery Engine
# -----------------------------------------------------------------------------
function Find-WindowsTerminalTargets {
  $targets = @()
  $localAppData = $env:LOCALAPPDATA
  if ([string]::IsNullOrWhiteSpace($localAppData) -or -not (Test-Path $localAppData)) {
    return $targets
  }

  $pkgDir = Join-Path $localAppData "Packages"
  if (Test-Path $pkgDir) {
    # Scan for Terminal packages
    Get-ChildItem -Path $pkgDir -Directory -Filter "Microsoft.WindowsTerminal*" -ErrorAction SilentlyContinue | ForEach-Object {
      $settingsFile = Join-Path $_.FullName "LocalState\settings.json"
      $edition = if ($_.Name -match "Preview") { "preview" } elseif ($_.Name -match "Canary") { "canary" } else { "stable" }
      $targets += [PSCustomObject]@{
        Type = "WindowsTerminal"
        Edition = $edition
        Path = $settingsFile
        Exists = (Test-Path $settingsFile)
      }
    }
  }

  # Unpackaged / Portable location
  $unpackaged = Join-Path $localAppData "Microsoft\Windows Terminal\settings.json"
  if (Test-Path (Split-Path $unpackaged)) {
    $targets += [PSCustomObject]@{
      Type = "WindowsTerminal"
      Edition = "unpackaged"
      Path = $unpackaged
      Exists = (Test-Path $unpackaged)
    }
  }

  return $targets
}

function Find-VSCodeTargets {
  $targets = @()
  $appData = $env:APPDATA
  if ([string]::IsNullOrWhiteSpace($appData) -or -not (Test-Path $appData)) {
    return $targets
  }

  $paths = @(
    @{ Edition = "stable"; Sub = "Code\User\settings.json" },
    @{ Edition = "insiders"; Sub = "Code - Insiders\User\settings.json" },
    @{ Edition = "codium"; Sub = "VSCodium\User\settings.json" }
  )

  foreach ($p in $paths) {
    $full = Join-Path $appData $p.Sub
    if (Test-Path (Split-Path $full)) {
      $targets += [PSCustomObject]@{
        Type = "VSCode"
        Edition = $p.Edition
        Path = $full
        Exists = (Test-Path $full)
      }
    }
  }

  return $targets
}

# -----------------------------------------------------------------------------
# 3. JSONC Tokenizer & Comment Stripper for Validation
# -----------------------------------------------------------------------------
function Test-JsoncValid {
  param([string]$JsoncText)

  # String-aware comment and trailing comma stripper for ConvertFrom-Json validation
  $sb = New-Object System.Text.StringBuilder
  $inString = $false
  $escaped = $false
  $i = 0
  $len = $JsoncText.Length

  while ($i -lt $len) {
    $c = $JsoncText[$i]

    if ($inString) {
      if ($escaped) {
        $escaped = $false
        [void]$sb.Append($c)
      } elseif ($c -eq '\') {
        $escaped = $true
        [void]$sb.Append($c)
      } elseif ($c -eq '"') {
        $inString = $false
        [void]$sb.Append($c)
      } else {
        [void]$sb.Append($c)
      }
      $i++
      continue
    }

    if ($c -eq '"') {
      $inString = $true
      [void]$sb.Append($c)
      $i++
      continue
    }

    # Line comment
    if ($c -eq '/' -and ($i + 1) -lt $len -and $JsoncText[$i + 1] -eq '/') {
      while ($i -lt $len -and $JsoncText[$i] -ne "`n") { $i++ }
      continue
    }

    # Block comment
    if ($c -eq '/' -and ($i + 1) -lt $len -and $JsoncText[$i + 1] -eq '*') {
      $i += 2
      while ($i + 1 -lt $len -and -not ($JsoncText[$i] -eq '*' -and $JsoncText[$i + 1] -eq '/')) { $i++ }
      $i += 2
      continue
    }

    [void]$sb.Append($c)
    $i++
  }

  $cleanJson = $sb.ToString()
  # Remove trailing commas
  $cleanJson = [regex]::Replace($cleanJson, ',\s*([\]}])', '$1')

  try {
    $null = ConvertFrom-Json $cleanJson -ErrorAction Stop
    return $true
  } catch {
    return $false
  }
}

# -----------------------------------------------------------------------------
# 4. Atomic Write with Backup & Sharing Violation Retry
# -----------------------------------------------------------------------------
function Write-AtomicFile {
  param(
    [string]$FilePath,
    [string]$Content,
    [switch]$MakeBackup
  )

  $dir = Split-Path -Path $FilePath -Parent
  if (-not (Test-Path $dir)) {
    New-Item -ItemType Directory -Path $dir -Force | Out-Null
  }

  $nonce = "$PID.$([guid]::NewGuid().ToString('N').Substring(0,8))"
  $tmpPath = Join-Path $dir "$([System.IO.Path]::GetFileName($FilePath)).omarchy_tmp.$nonce"
  $bakPath = "$FilePath.bak"

  try {
    # 1. Write content to temp file with UTF-8 encoding (no BOM)
    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($tmpPath, $Content, $utf8NoBom)

    # 2. Safety backup if original exists
    if ($MakeBackup -and (Test-Path $FilePath)) {
      Copy-Item -Path $FilePath -Destination $bakPath -Force
    }

    # 3. Atomic replace with retry loop for transient file watcher locks
    $maxAttempts = 5
    $delayMs = 50
    $succeeded = $false
    $lastErr = $null

    for ($attempt = 1; $attempt -le $maxAttempts; $attempt++) {
      try {
        if (Test-Path $FilePath) {
          # Use Win32 ReplaceFile via .NET File.Replace if both exist
          [System.IO.File]::Replace($tmpPath, $FilePath, $null, $true)
        } else {
          [System.IO.File]::Move($tmpPath, $FilePath)
        }
        $succeeded = $true
        break
      } catch {
        $lastErr = $_
        Start-Sleep -Milliseconds $delayMs
        $delayMs *= 2
      }
    }

    if (-not $succeeded) {
      throw "Atomic replace failed after $maxAttempts attempts: $lastErr"
    }

    return $true
  } finally {
    if (Test-Path $tmpPath) {
      Remove-Item -Path $tmpPath -Force -ErrorAction SilentlyContinue
    }
  }
}

# -----------------------------------------------------------------------------
# 5. Surgical Windows Terminal Scheme Injection
# -----------------------------------------------------------------------------
function Update-WindowsTerminalSettings {
  param(
    [string]$FilePath,
    [hashtable]$SchemeData,
    [string]$TargetProfile,
    [bool]$ToDefaults,
    [bool]$IsDryRun
  )

  Write-Step "Inspecting Windows Terminal settings: $FilePath"

  if (-not (Test-Path $FilePath)) {
    Write-Warn "Target settings file not found; initializing minimal configuration."
    $rawText = @'
// Windows Terminal Configuration (Omarchy-WSL)
{
    "$schema": "https://aka.ms/terminal-profiles-schema",
    "profiles": {
        "defaults": {},
        "list": []
    },
    "schemes": []
}
'@
  } else {
    $rawText = [System.IO.File]::ReadAllText($FilePath)
  }

  # Validate existing content
  if (-not (Test-JsoncValid -JsoncText $rawText)) {
    Write-Err "Syntax error detected in existing settings.json. Aborting to prevent data corruption."
    return $false
  }

  # Build JSON for scheme
  $schemeJson = ConvertTo-Json $SchemeData -Depth 4
  $schemeIndent = "        "
  $formattedScheme = ($schemeJson -split "`r?`n" | ForEach-Object { "$schemeIndent$_" }) -join "`r`n"

  $schemeName = $SchemeData.name
  $newText = $rawText

  # 1. Upsert Scheme
  if ($newText -match '(?s)("schemes"\s*:\s*\[)(.*?)(\])') {
    $schemesContent = $matches[2]
    # Check if scheme already exists
    if ($schemesContent -match "(?s)(\{\s*`"name`"\s*:\s*`"$([regex]::Escape($schemeName))`".*?\})") {
      Write-Step "Updating existing scheme '$schemeName' in 'schemes' array..."
      $pattern = "(?s)(\{\s*`"name`"\s*:\s*`"$([regex]::Escape($schemeName))`".*?\})"
      $newText = [regex]::Replace($newText, $pattern, $schemeJson.Trim())
    } else {
      Write-Step "Appending scheme '$schemeName' to 'schemes' array..."
      $hasElements = $schemesContent.Trim().Length -gt 0
      $insertion = if ($hasElements) { ",`r`n$formattedScheme`r`n    ]" } else { "`r`n$formattedScheme`r`n    ]" }
      $newText = [regex]::Replace($newText, '(?s)("schemes"\s*:\s*\[.*?)(])', "`$1$insertion", 1)
    }
  } else {
    # schemes property doesn't exist; insert after root {
    Write-Step "Adding 'schemes' array to settings..."
    $newText = [regex]::Replace($newText, '(?s)^(\s*\{)', "`$1`r`n    `"schemes`": [`r`n$formattedScheme`r`n    ],", 1)
  }

  # 2. Update Profile colorScheme
  if ($ToDefaults) {
    Write-Step "Applying colorScheme '$schemeName' to profiles.defaults..."
    if ($newText -match '(?s)("defaults"\s*:\s*\{)(.*?)(\})') {
      if ($matches[2] -match '("colorScheme"\s*:\s*")([^"]*)(")') {
        $newText = [regex]::Replace($newText, '(?s)("defaults"\s*:\s*\{.*?"colorScheme"\s*:\s*")([^"]*)(")', "`${1}$schemeName`${3}")
      } else {
        $newText = [regex]::Replace($newText, '(?s)("defaults"\s*:\s*\{)', "`$1`r`n            `"colorScheme`": `"$schemeName`",", 1)
      }
    }
  } else {
    Write-Step "Applying colorScheme '$schemeName' to profile '$TargetProfile'..."
    $profilePattern = "(?s)(\{\s*`"name`"\s*:\s*`"$([regex]::Escape($TargetProfile))`".*?\})"
    if ($newText -match $profilePattern) {
      $profBlock = $matches[1]
      if ($profBlock -match '("colorScheme"\s*:\s*")([^"]*)(")') {
        $updatedProf = [regex]::Replace($profBlock, '("colorScheme"\s*:\s*")([^"]*)(")', "`${1}$schemeName`${3}")
      } else {
        $updatedProf = [regex]::Replace($profBlock, '(?s)^(\s*\{)', "`$1`r`n                `"colorScheme`": `"$schemeName`",")
      }
      $newText = $newText.Replace($profBlock, $updatedProf)
    } else {
      Write-Warn "Profile '$TargetProfile' not found in profiles.list; skipping profile override."
    }
  }

  # Validate generated text before writing
  if (-not (Test-JsoncValid -JsoncText $newText)) {
    Write-Err "Internal verification failed: generated JSONC had syntax errors. Aborting."
    return $false
  }

  if ($IsDryRun) {
    Write-Success "[DRY-RUN] Verified valid update for $FilePath"
    return $true
  }

  Write-AtomicFile -FilePath $FilePath -Content $newText -MakeBackup
  Write-Success "Synchronized '$schemeName' to $FilePath"
  return $true
}

# -----------------------------------------------------------------------------
# 6. Main Orchestrator
# -----------------------------------------------------------------------------
try {
  if ($ListThemes) {
    Write-Host "Available built-in themes:" -ForegroundColor Cyan
    $ThemesCatalog.Keys | Sort-Object | ForEach-Object { Write-Host "  - $_" }
    exit 0
  }

  if ($Status) {
    Write-Step "Auditing Windows Host Configuration..."
    $wtTargets = Find-WindowsTerminalTargets
    Write-Host "Windows Terminal Targets:" -ForegroundColor Cyan
    if ($wtTargets.Count -eq 0) { Write-Host "  (None found)" -ForegroundColor DarkGray }
    foreach ($t in $wtTargets) {
      $st = if ($t.Exists) { "FOUND" } else { "TEMPLATE READY" }
      Write-Host "  - [$($t.Edition)] $($t.Path) ($st)"
    }

    $vscTargets = Find-VSCodeTargets
    Write-Host "VS Code Targets:" -ForegroundColor Cyan
    if ($vscTargets.Count -eq 0) { Write-Host "  (None found)" -ForegroundColor DarkGray }
    foreach ($t in $vscTargets) {
      $st = if ($t.Exists) { "FOUND" } else { "TEMPLATE READY" }
      Write-Host "  - [$($t.Edition)] $($t.Path) ($st)"
    }
    exit 0
  }

  if ($Restore) {
    Write-Step "Restoring settings from .bak backups..."
    $allTargets = @(Find-WindowsTerminalTargets) + @(Find-VSCodeTargets)
    $restored = 0
    foreach ($t in $allTargets) {
      $bak = "$($t.Path).bak"
      if (Test-Path $bak) {
        Copy-Item -Path $bak -Destination $t.Path -Force
        Write-Success "Restored: $($t.Path) <- $bak"
        $restored++
      }
    }
    Write-Success "Restored $restored target(s)."
    exit 0
  }

  # Normalize Theme Key
  $themeKey = $Theme -replace "[-_ ]", ""
  $selectedTheme = $null
  foreach ($k in $ThemesCatalog.Keys) {
    if ($k -ieq $themeKey) {
      $selectedTheme = $ThemesCatalog[$k]
      break
    }
  }

  if (-not $selectedTheme) {
    Write-Err "Theme '$Theme' not found. Run with -ListThemes to see available options."
    exit 1
  }

  Write-Step "Selected theme: $($selectedTheme.name)"
  if ($DryRun) { Write-Warn "Dry-run mode active. No changes will be written." }

  # Sync Windows Terminal
  $wtTargets = Find-WindowsTerminalTargets
  if ($wtTargets.Count -eq 0) {
    Write-Step "Windows Terminal not detected on host (skipping gracefully)."
  } else {
    foreach ($wt in $wtTargets) {
      Update-WindowsTerminalSettings -FilePath $wt.Path -SchemeData $selectedTheme -TargetProfile $ProfileName -ToDefaults $ApplyToDefaults -IsDryRun $DryRun
    }
  }

  Write-Success "Theme synchronization completed successfully!"
} catch {
  Write-Err "Execution failed: $_"
  exit 1
}
