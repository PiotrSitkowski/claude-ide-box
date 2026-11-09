#Requires -Version 5.1
# Shared by install.ps1, choose.ps1 and open.ps1 (dot-sourced). Windows
# PowerShell 5.1 only: no &&, ??, ternaries or -AsHashtable.

$Distro = 'ClaudeIDEBox'
$VsProfile = 'Claude IDE Box'
$AppDir = Join-Path $env:LOCALAPPDATA 'ClaudeIDEBox'
$StateFile = Join-Path $AppDir 'state.json'
$env:WSL_UTF8 = '1'

# ---------------------------------------------------------------------------
# i18n: every text a person sees comes from i18n\<language>.psd1. English is
# the reference and the fallback for any missing text; a language is added by
# adding one file. -Language (e.g. "pl", "de-AT") wins over the Windows UI
# language; "de-AT" falls back to "de", then to English.
# ---------------------------------------------------------------------------

function Initialize-Messages([string]$language) {
  $dir = Join-Path $PSScriptRoot 'i18n'
  $script:Msg = Import-PowerShellDataFile (Join-Path $dir 'en.psd1')
  $script:Lang = 'en'
  $names = @()
  if ($language) {
    # An explicit language wins; without a file for it, English (never the
    # Windows language, which the person just chose not to use).
    $names += $language
    $names += $language.Split('-')[0]
  } else {
    $ui = Get-UICulture
    $names += $ui.Name
    $names += $ui.TwoLetterISOLanguageName
  }
  foreach ($n in $names) {
    if (-not $n -or $n -eq 'en') { continue }
    $f = Join-Path $dir "$n.psd1"
    if (Test-Path $f) {
      $o = Import-PowerShellDataFile $f
      foreach ($k in $o.Keys) { $script:Msg[$k] = $o[$k] }
      $script:Lang = $n
      break
    }
  }
}

# M KEY [ARGS...] - the text for KEY in the current language, with {0}, {1}...
# filled from ARGS. An unknown key shows itself, so a gap is visible.
function M([string]$key) {
  $t = $script:Msg[$key]
  if ($null -eq $t) { $t = "[$key]" }
  if ($args.Count -gt 0) { $t = $t -f $args }
  return $t
}

# ---------------------------------------------------------------------------
# Native commands
# ---------------------------------------------------------------------------

# stderr lines must not become terminating errors (PS 5.1); stderr lines
# arrive as ErrorRecords (an empty one prints as "RemoteException"); a
# progress line redrawn with CR is shown once, as its last state.
function Run-Native([string]$exe, [string[]]$argv) {
  $old = $ErrorActionPreference
  $ErrorActionPreference = 'Continue'
  try {
    & $exe @argv 2>&1 | ForEach-Object {
      $line = if ($_ -is [System.Management.Automation.ErrorRecord]) { $_.Exception.Message } else { "$_" }
      $line = ($line -split "`r" | Where-Object { $_.Trim() } | Select-Object -Last 1)
      if ($line -and $line -ne 'System.Management.Automation.RemoteException') { Write-Host "      $line" }
    }
    return $LASTEXITCODE
  } finally {
    $ErrorActionPreference = $old
  }
}

function Get-Native([string]$exe, [string[]]$argv) {
  $old = $ErrorActionPreference
  $ErrorActionPreference = 'Continue'
  try {
    $out = & $exe @argv 2>$null
    return @{ Code = $LASTEXITCODE; Out = (($out | ForEach-Object { "$_" }) -join "`n") }
  } finally {
    $ErrorActionPreference = $old
  }
}

# Windows command-line quoting for one argument (Start-Process does none in 5.1).
function Quote-Arg([string]$a) {
  if ($a -and $a -notmatch '[\s"]') { return $a }
  return '"' + ($a -replace '(\\*)"', '$1$1\"' -replace '(\\+)$', '$1$1') + '"'
}

function Wsl-Args([string]$user, [string[]]$cmd) {
  $a = @('-d', $Distro)
  if ($user) { $a += @('-u', $user) }
  $a += '-e'
  $a += $cmd
  return , $a
}

function Wsl-Run([string]$user, [string[]]$cmd) { return Run-Native 'wsl.exe' (Wsl-Args $user $cmd) }
function Wsl-Get([string]$user, [string[]]$cmd) { return Get-Native 'wsl.exe' (Wsl-Args $user $cmd) }

function Test-Distro {
  $key = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Lxss'
  if (-not (Test-Path $key)) { return $false }
  foreach ($d in Get-ChildItem $key) {
    if ((Get-ItemProperty $d.PSPath).DistributionName -eq $Distro) { return $true }
  }
  return $false
}

function Find-VsCode {
  foreach ($c in @(
      (Join-Path $env:LOCALAPPDATA 'Programs\Microsoft VS Code\Code.exe'),
      (Join-Path $env:ProgramFiles 'Microsoft VS Code\Code.exe'))) {
    if (Test-Path $c) { return $c }
  }
  return $null
}

function Wsl-Share {
  foreach ($p in @("\\wsl.localhost\$Distro", "\\wsl$\$Distro")) {
    if (Test-Path $p) { return $p }
  }
  return "\\wsl.localhost\$Distro"
}

# state.json as a hashtable (ConvertFrom-Json gives a PSCustomObject in 5.1).
function Read-State {
  $h = @{}
  if (Test-Path $StateFile) {
    try {
      (Get-Content -Raw -Encoding UTF8 $StateFile | ConvertFrom-Json).PSObject.Properties |
        ForEach-Object { $h[$_.Name] = $_.Value }
    } catch { }
  }
  return $h
}

function Save-State($state) {
  New-Item -ItemType Directory -Force -Path $AppDir | Out-Null
  $state | ConvertTo-Json -Depth 5 | Set-Content -Encoding UTF8 -Path $StateFile
}
