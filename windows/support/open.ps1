#Requires -Version 5.1
# The desktop shortcut "Claude": opens a folder in VS Code's "Claude IDE Box"
# profile, inside the ClaudeIDEBox WSL distribution, where Claude Code runs in
# the box. A folder (or a file: its folder) dropped on the shortcut is opened;
# without one, the first project. The wrapper refuses unsafe folders by itself;
# the checks here only explain it before VS Code opens.
param([string]$Path)

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = New-Object System.Text.UTF8Encoding $false
$env:WSL_UTF8 = '1'
$Distro = 'ClaudeIDEBox'
$VsProfile = 'Claude IDE Box'
$AppDir = Join-Path $env:LOCALAPPDATA 'ClaudeIDEBox'
$Pl = (Get-UICulture).TwoLetterISOLanguageName -eq 'pl'
function T([string]$pl, [string]$en) { if ($Pl) { $pl } else { $en } }

function Say([string]$text) {
  Add-Type -AssemblyName PresentationFramework
  [void][System.Windows.MessageBox]::Show($text, 'Claude IDE Box', 'OK', 'Warning')
  exit 1
}

$state = $null
try { $state = Get-Content -Raw (Join-Path $AppDir 'state.json') | ConvertFrom-Json } catch { }
if (-not $state -or -not $state.LinuxUser) {
  Say (T 'Claude IDE Box nie jest zainstalowany. Uruchom "Install Claude IDE Box".' 'Claude IDE Box is not installed. Run "Install Claude IDE Box".')
}
$linuxHome = "/home/$($state.LinuxUser)"

$code = $null
foreach ($c in @(
    (Join-Path $env:LOCALAPPDATA 'Programs\Microsoft VS Code\bin\code.cmd'),
    (Join-Path $env:ProgramFiles 'Microsoft VS Code\bin\code.cmd'))) {
  if (Test-Path $c) { $code = $c; break }
}
if (-not $code) { Say (T 'Nie znaleziono VS Code. Uruchom ponownie instalator Claude IDE Box.' 'VS Code was not found. Run the Claude IDE Box installer again.') }

if (-not $Path) {
  $linux = "$linuxHome/$($state.ProjectsName)"
  $first = Get-ChildItem -Directory -ErrorAction SilentlyContinue "\\wsl.localhost\$Distro$($linux -replace '/', '\')" | Select-Object -First 1
  if ($first) { $linux = "$linux/$($first.Name)" }
} else {
  if (Test-Path -PathType Leaf -LiteralPath $Path) { $Path = Split-Path -Parent $Path }
  $Path = $Path.TrimEnd('\')
  $m = [regex]::Match($Path, '^\\\\(wsl\.localhost|wsl\$)\\([^\\]+)(\\.*)?$', 'IgnoreCase')
  if ($m.Success) {
    if ($m.Groups[2].Value -ne $Distro) {
      Say (T "Ten folder należy do innej dystrybucji Linuksa ($($m.Groups[2].Value)). Claude IDE Box otwiera foldery z `"$Distro`" i z dysków Windows." "This folder belongs to another Linux distribution ($($m.Groups[2].Value)). Claude IDE Box opens folders in `"$Distro`" and on Windows drives.")
    }
    $linux = ($m.Groups[3].Value -replace '\\', '/')
    if (-not $linux) { $linux = '/' }
  } elseif ($Path -match '^[A-Za-z]:\\?') {
    $full = [IO.Path]::GetFullPath($Path).TrimEnd('\')
    $profileDir = $env:USERPROFILE.TrimEnd('\')
    $bad = $false
    if ($full.Length -le 3) { $bad = $true }                                         # C:\
    elseif ($profileDir.StartsWith($full + '\', 'OrdinalIgnoreCase') -or $full -ieq $profileDir) { $bad = $true }
    elseif ($full -match '^[A-Za-z]:\\Users(\\[^\\]+)?$') { $bad = $true }
    elseif ($full -match '^[A-Za-z]:\\Users\\[^\\]+\\(AppData|\.ssh|\.aws|\.azure|\.gnupg|\.docker|\.kube|\.config|\.claude)(\\|$)') { $bad = $true }
    elseif ($full -match '^[A-Za-z]:\\(Windows|Program Files|Program Files \(x86\)|ProgramData)(\\|$)') { $bad = $true }
    if ($bad) {
      Say (T "Claude nie może dostać całego dysku, folderu użytkownika ani folderu systemowego:`n$full`n`nPrzeciągnij na ikonę konkretny folder z dokumentami, np. Dokumenty\Kadry." "Claude cannot get a whole drive, a user folder or a system folder:`n$full`n`nDrop a specific folder of documents on the icon, e.g. Documents\HR.")
    }
    $out = & wsl.exe -d $Distro -e wslpath -u $full 2>$null
    if ($LASTEXITCODE -ne 0 -or -not $out) { Say ("wslpath: $full") }
    $linux = "$out".Trim()
  } else {
    Say (T "Tego folderu nie da się otworzyć w Claude IDE Box (dysk sieciowy?):`n$Path" "This folder cannot be opened in Claude IDE Box (a network drive?):`n$Path")
  }
  if ($linux -eq '/' -or $linux -eq $linuxHome -or $linuxHome.StartsWith($linux + '/')) {
    Say (T 'Claude nie może dostać całego folderu domowego Linuksa. Wybierz folder projektu.' 'Claude cannot get the whole Linux home folder. Choose a project folder.')
  }
}

$segments = $linux.Split('/') | ForEach-Object { [Uri]::EscapeDataString($_) }
$uri = "vscode-remote://wsl+$Distro" + ($segments -join '/')
& $code --profile $VsProfile --folder-uri $uri
