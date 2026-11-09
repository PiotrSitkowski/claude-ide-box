#Requires -Version 5.1
# The "Claude" shortcut: opens a folder in VS Code's "Claude IDE Box" profile,
# inside the ClaudeIDEBox WSL distribution, where Claude Code runs in the box.
# A folder (or a file: its folder) dropped on the shortcut is opened; without
# one, the first project. The wrapper refuses unsafe folders by itself; the
# checks here only explain it before VS Code opens.
param(
  [string]$Path,
  [string]$Language
)

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = New-Object System.Text.UTF8Encoding $false
. (Join-Path $PSScriptRoot 'lib.ps1')
Initialize-Messages $Language

function Say([string]$text) {
  Add-Type -AssemblyName PresentationFramework
  [void][System.Windows.MessageBox]::Show($text, (M 'App_Name'), 'OK', 'Warning')
  exit 1
}

$state = Read-State
if (-not $state.LinuxUser) { Say (M 'Open_NotInstalled') }
$linuxHome = "/home/$($state.LinuxUser)"

$code = $null
foreach ($c in @(
    (Join-Path $env:LOCALAPPDATA 'Programs\Microsoft VS Code\bin\code.cmd'),
    (Join-Path $env:ProgramFiles 'Microsoft VS Code\bin\code.cmd'))) {
  if (Test-Path $c) { $code = $c; break }
}
if (-not $code) { Say (M 'Open_NoVsCode') }

if (-not $Path) {
  $linux = "$linuxHome/$($state.ProjectsName)"
  $first = Get-ChildItem -Directory -ErrorAction SilentlyContinue "$(Wsl-Share)$($linux -replace '/', '\')" | Select-Object -First 1
  if ($first) { $linux = "$linux/$($first.Name)" }
} else {
  if (Test-Path -PathType Leaf -LiteralPath $Path) { $Path = Split-Path -Parent $Path }
  $Path = $Path.TrimEnd('\')
  $m = [regex]::Match($Path, '^\\\\(wsl\.localhost|wsl\$)\\([^\\]+)(\\.*)?$', 'IgnoreCase')
  if ($m.Success) {
    if ($m.Groups[2].Value -ne $Distro) { Say (M 'Open_OtherDistro' $m.Groups[2].Value $Distro) }
    $linux = ($m.Groups[3].Value -replace '\\', '/')
    if (-not $linux) { $linux = '/' }
  } elseif ($Path -match '^[A-Za-z]:\\?') {
    $full = [IO.Path]::GetFullPath($Path).TrimEnd('\')
    $profileDir = $env:USERPROFILE.TrimEnd('\')
    $bad = $false
    if ($full.Length -le 3) { $bad = $true }
    elseif ($profileDir.StartsWith($full + '\', 'OrdinalIgnoreCase') -or $full -ieq $profileDir) { $bad = $true }
    elseif ($full -match '^[A-Za-z]:\\Users(\\[^\\]+)?$') { $bad = $true }
    elseif ($full -match '^[A-Za-z]:\\Users\\[^\\]+\\(AppData|\.ssh|\.aws|\.azure|\.gnupg|\.docker|\.kube|\.config|\.claude)(\\|$)') { $bad = $true }
    elseif ($full -match '^[A-Za-z]:\\(Windows|Program Files|Program Files \(x86\)|ProgramData)(\\|$)') { $bad = $true }
    if ($bad) { Say (M 'Open_Refused' $full) }
    $out = & wsl.exe -d $Distro -e wslpath -u $full 2>$null
    if ($LASTEXITCODE -ne 0 -or -not $out) { Say ("wslpath: $full") }
    $linux = "$out".Trim()
  } else {
    Say (M 'Open_Unsupported' $Path)
  }
  if ($linux -eq '/' -or $linux -eq $linuxHome -or $linuxHome.StartsWith($linux + '/')) { Say (M 'Open_LinuxHome') }
}

$segments = $linux.Split('/') | ForEach-Object { [Uri]::EscapeDataString($_) }
$uri = "vscode-remote://wsl+$Distro" + ($segments -join '/')
& $code --profile $VsProfile --folder-uri $uri
