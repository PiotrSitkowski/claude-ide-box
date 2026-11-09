#Requires -Version 5.1
<#
Claude IDE Box for Windows: one double-click, no terminal.

  Install Claude IDE Box.cmd               install or repair (safe to run again)
  Install Claude IDE Box.cmd -Uninstall    remove it (projects are copied to Documents first)

What it does, step by step (each step is skipped when already done):
  1. checks Windows, virtualization and disk space
  2. WSL: enables/updates it (the only step that asks for administrator rights)
  3. a separate Linux distribution "ClaudeIDEBox" from Ubuntu's signed-off WSL image
     (SHA256 checked), with Docker Engine inside; Docker Desktop is not used
  4. VS Code: installed or updated for the current user if missing or too old
  5. claude-ide-box inside the distribution: install.sh, setup, the Claude Code
     extension on the WSL side, guard
  6. a VS Code profile "Claude IDE Box" with the wrapper settings; other profiles,
     other IDEs (Antigravity, Cursor) and their settings are not touched
  7. sign-in to Claude (the browser opens; the code is pasted back)
  8. desktop shortcuts, doctor, and the first project opens
#>
param(
  [switch]$Uninstall,
  [string]$ImageProfile = 'office'
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
[Console]::OutputEncoding = New-Object System.Text.UTF8Encoding $false
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$env:WSL_UTF8 = '1'

$Distro = 'ClaudeIDEBox'
$VsProfile = 'Claude IDE Box'
$MinVsCode = [version]'1.100.0'
$UbuntuBase = 'https://cloud-images.ubuntu.com/wsl/releases/24.04/current'
$AppDir = Join-Path $env:LOCALAPPDATA 'ClaudeIDEBox'
$StateFile = Join-Path $AppDir 'state.json'
$LogFile = Join-Path $AppDir 'install.log'
$LauncherDir = Split-Path -Parent $PSScriptRoot
$SrcRoot = Split-Path -Parent $LauncherDir
$Pl = (Get-UICulture).TwoLetterISOLanguageName -eq 'pl'
$Arch = if ($env:PROCESSOR_ARCHITECTURE -eq 'ARM64') { 'arm64' } else { 'amd64' }
$Steps = 8

function T([string]$pl, [string]$en) { if ($Pl) { $pl } else { $en } }

$ProjectsName = T 'Projekty' 'Projects'
$FirstProject = T 'Pierwszy projekt' 'First project'

function Step([int]$n, [string]$text) {
  Write-Host ''
  Write-Host "[$n/$Steps] $text" -ForegroundColor Cyan
}
function Info([string]$text) { Write-Host "      $text" }
function Ok([string]$text) { Write-Host "      $text" -ForegroundColor Green }
function Warn([string]$text) { Write-Host "      $text" -ForegroundColor Yellow }

function Pause-Close {
  Write-Host ''
  [void](Read-Host (T 'Naciśnij Enter, aby zamknąć to okno' 'Press Enter to close this window'))
}

function Fail([string]$text) {
  Write-Host ''
  Write-Host (T 'Instalacja nie powiodła się:' 'Installation failed:') -ForegroundColor Red
  Write-Host "  $text" -ForegroundColor Red
  Write-Host ''
  Write-Host (T "Jeśli nie wiesz, co zrobić, wyślij dziale IT ten plik:`n  $LogFile" "If you are not sure what to do, send this file to your IT team:`n  $LogFile")
  try { Stop-Transcript | Out-Null } catch { }
  Pause-Close
  exit 1
}

# Native commands: stderr lines must not become terminating errors (PS 5.1).
function Run-Native([string]$exe, [string[]]$argv) {
  $old = $ErrorActionPreference
  $ErrorActionPreference = 'Continue'
  try {
    # stderr lines arrive as ErrorRecords (an empty one prints as
    # "System.Management.Automation.RemoteException"); a progress line
    # redrawn with CR is shown once, as its last state.
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

function Wsl-Run([string]$user, [string[]]$cmd) {
  $a = @('-d', $Distro)
  if ($user) { $a += @('-u', $user) }
  $a += '-e'
  $a += $cmd
  return Run-Native 'wsl.exe' $a
}

# A Linux program attached to the console (sign-in) can leave its output mode
# changed, so later lines would no longer start at the left edge.
Add-Type -Namespace ClaudeIdeBox -Name Con -MemberDefinition @'
[DllImport("kernel32.dll")] public static extern System.IntPtr GetStdHandle(int h);
[DllImport("kernel32.dll")] public static extern bool GetConsoleMode(System.IntPtr h, out uint m);
[DllImport("kernel32.dll")] public static extern bool SetConsoleMode(System.IntPtr h, uint m);
'@
$ConsoleOut = [ClaudeIdeBox.Con]::GetStdHandle(-11)
$ConsoleMode = 0
[void][ClaudeIdeBox.Con]::GetConsoleMode($ConsoleOut, [ref]$ConsoleMode)
function Restore-Console {
  if ($ConsoleMode) { [void][ClaudeIdeBox.Con]::SetConsoleMode($ConsoleOut, $ConsoleMode) }
}

# Windows command-line quoting for one argument (Start-Process does none in 5.1).
function Quote-Arg([string]$a) {
  if ($a -and $a -notmatch '[\s"]') { return $a }
  return '"' + ($a -replace '(\\*)"', '$1$1\"' -replace '(\\+)$', '$1$1') + '"'
}

# Long Linux-side work: its output goes to a log file, not to the console
# (hundreds of apt/docker lines are noise for the person installing, and a
# Linux program can leave the Windows console in a broken line mode). The
# console shows one line with the elapsed time; on failure, the end of the log.
$LinuxLog = Join-Path $AppDir 'linux-setup.log'
function Wsl-Quiet([string]$user, [string[]]$cmd, [string]$waitText) {
  $a = @('-d', $Distro)
  if ($user) { $a += @('-u', $user) }
  # stderr joins stdout inside Linux, so the log keeps the order of events and
  # its last lines show the actual error.
  $a += @('-e', 'sh', '-c', 'exec "$@" 2>&1', 'sh')
  $a += $cmd
  $line = ($a | ForEach-Object { Quote-Arg $_ }) -join ' '
  $out = Join-Path $AppDir 'linux-step.out'
  $err = Join-Path $AppDir 'linux-step.err'
  $in = Join-Path $AppDir 'linux-step.in'
  [IO.File]::WriteAllText($in, '')
  # stdin from an empty file too: nothing in Linux sees the console, so
  # nothing can ask a question or change the console's mode.
  $p = Start-Process wsl.exe -ArgumentList $line -NoNewWindow -PassThru `
    -RedirectStandardInput $in -RedirectStandardOutput $out -RedirectStandardError $err
  # PowerShell 5.1: without reading Handle now, ExitCode is $null afterwards.
  $null = $p.Handle
  $sw = [Diagnostics.Stopwatch]::StartNew()
  while (-not $p.HasExited) {
    $t = '{0}:{1:00}' -f [int][math]::Floor($sw.Elapsed.TotalMinutes), $sw.Elapsed.Seconds
    [Console]::Write("`r      $waitText $t   ")
    Start-Sleep -Milliseconds 1000
  }
  $p.WaitForExit()
  Remove-Item -Force $in -ErrorAction SilentlyContinue
  [Console]::WriteLine('')
  foreach ($f in @($out, $err)) {
    if (Test-Path $f) {
      Add-Content -Path $LinuxLog -Encoding UTF8 -Value (Get-Content -Raw -Encoding UTF8 $f)
      Remove-Item -Force $f
    }
  }
  if ($null -eq $p.ExitCode -or $p.ExitCode -ne 0) {
    Write-Host ''
    Write-Host (T '      Ostatnie linie z dziennika:' '      Last lines of the log:') -ForegroundColor Yellow
    Get-Content -Tail 25 -Encoding UTF8 $LinuxLog | ForEach-Object { Write-Host "        $_" }
  }
  return $p.ExitCode
}

function Wsl-Get([string]$user, [string[]]$cmd) {
  $a = @('-d', $Distro)
  if ($user) { $a += @('-u', $user) }
  $a += '-e'
  $a += $cmd
  return Get-Native 'wsl.exe' $a
}

# Runs a PowerShell command elevated (one UAC prompt). $null if declined.
function Invoke-Elevated([string]$command) {
  $enc = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($command))
  try {
    $p = Start-Process powershell.exe -Verb RunAs -Wait -PassThru `
      -ArgumentList "-NoProfile -ExecutionPolicy Bypass -EncodedCommand $enc"
    return $p.ExitCode
  } catch {
    return $null
  }
}

function Download([string]$url, [string]$out, [switch]$Progress) {
  $curl = Join-Path $env:SystemRoot 'System32\curl.exe'
  if (Test-Path $curl) {
    # curl writes straight to the console, so its progress bar redraws in place.
    $show = if ($Progress) { '-#' } else { '-sS' }
    $old = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    & $curl -fL --retry 3 $show -o $out $url
    $code = $LASTEXITCODE
    $ErrorActionPreference = $old
    if ($code -ne 0) { Fail ((T 'Nie udało się pobrać: ' 'Download failed: ') + $url) }
  } else {
    try { Invoke-WebRequest -UseBasicParsing -Uri $url -OutFile $out }
    catch { Fail ((T 'Nie udało się pobrać: ' 'Download failed: ') + $url) }
  }
}

function Assert-MicrosoftSigned([string]$file) {
  $sig = Get-AuthenticodeSignature -FilePath $file
  if ($sig.Status -ne 'Valid' -or $sig.SignerCertificate.Subject -notmatch 'O=Microsoft Corporation') {
    Remove-Item -Force $file -ErrorAction SilentlyContinue
    Fail ((T 'Pobrany plik nie ma ważnego podpisu Microsoft: ' 'The downloaded file has no valid Microsoft signature: ') + $file)
  }
}

function Test-Distro {
  $key = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Lxss'
  if (-not (Test-Path $key)) { return $false }
  foreach ($d in Get-ChildItem $key) {
    if ((Get-ItemProperty $d.PSPath).DistributionName -eq $Distro) { return $true }
  }
  return $false
}

function Get-LinuxUser {
  $n = $env:USERNAME.ToLowerInvariant().Replace([string][char]0x0142, 'l')
  $n = $n.Normalize([Text.NormalizationForm]::FormD)
  $n = -join ($n.ToCharArray() | Where-Object {
      [Globalization.CharUnicodeInfo]::GetUnicodeCategory($_) -ne [Globalization.UnicodeCategory]::NonSpacingMark })
  $n = $n -replace '[^a-z0-9_-]', ''
  if ($n -notmatch '^[a-z]') { $n = 'user' + $n }
  if ($n.Length -gt 32) { $n = $n.Substring(0, 32) }
  return $n
}

function Write-LfFile([string]$from, [string]$to) {
  $text = [IO.File]::ReadAllText($from) -replace "`r", ''
  [IO.File]::WriteAllText($to, $text, (New-Object Text.UTF8Encoding $false))
}

function To-LinuxPath([string]$winPath) {
  $r = Wsl-Get 'root' @('wslpath', '-u', $winPath)
  if ($r.Code -ne 0 -or -not $r.Out) { Fail ("wslpath: $winPath") }
  return $r.Out.Trim()
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

function Save-State($state) {
  $state | ConvertTo-Json | Set-Content -Encoding UTF8 -Path $StateFile
}

# ---------------------------------------------------------------------------
# Uninstall
# ---------------------------------------------------------------------------

if ($Uninstall) {
  Write-Host (T 'Odinstalowanie Claude IDE Box' 'Uninstalling Claude IDE Box') -ForegroundColor Cyan
  Write-Host (T "Twoje projekty z folderu `"$ProjectsName`" zostaną najpierw skopiowane do Dokumentów." "Your projects in `"$ProjectsName`" are copied to Documents first.")
  $answer = Read-Host (T 'Wpisz TAK, aby kontynuować' 'Type YES to continue')
  if ($answer -notin @('TAK', 'tak', 'YES', 'yes')) { exit 0 }
  if (Test-Distro) {
    $state = $null
    if (Test-Path $StateFile) { $state = Get-Content -Raw $StateFile | ConvertFrom-Json }
    if ($state -and $state.LinuxUser) {
      $from = Join-Path (Wsl-Share) "home\$($state.LinuxUser)\$($state.ProjectsName)"
      if (Test-Path $from) {
        $to = Join-Path ([Environment]::GetFolderPath('MyDocuments')) ("$($state.ProjectsName) Claude - " + (Get-Date -Format 'yyyy-MM-dd HHmm'))
        & robocopy.exe $from $to /E /R:1 /W:1 /NFL /NDL /NJH /NJS | Out-Null
        if ($LASTEXITCODE -ge 8) {
          Write-Host (T "Kopiowanie projektów nie powiodło się; nic nie zostało usunięte." 'Copying the projects failed; nothing was removed.') -ForegroundColor Red
          Pause-Close
          exit 1
        }
        Write-Host ((T 'Projekty skopiowane do: ' 'Projects copied to: ') + $to) -ForegroundColor Green
      }
    }
    & wsl.exe --unregister $Distro | Out-Null
  }
  $desk = [Environment]::GetFolderPath('Desktop')
  Remove-Item -Force -ErrorAction SilentlyContinue (Join-Path $desk 'Claude.lnk'), (Join-Path $desk "$ProjectsName Claude.lnk")
  Remove-Item -Recurse -Force -ErrorAction SilentlyContinue $AppDir
  Write-Host (T "Gotowe. Profil `"$VsProfile`" w VS Code możesz usunąć w: Plik > Preferencje > Profile." "Done. You can remove the `"$VsProfile`" profile in VS Code under File > Preferences > Profiles.") -ForegroundColor Green
  Pause-Close
  exit 0
}

# ---------------------------------------------------------------------------
# Install
# ---------------------------------------------------------------------------

New-Item -ItemType Directory -Force -Path $AppDir | Out-Null
try { Start-Transcript -Append -Path $LogFile | Out-Null } catch { }
$Host.UI.RawUI.WindowTitle = 'Claude IDE Box'
Write-Host (T 'Instalacja Claude IDE Box' 'Installing Claude IDE Box') -ForegroundColor Cyan
Write-Host (T 'Claude będzie pracował w zamkniętym pudełku: widzi tylko otwarty folder i łączy się tylko z Claude.' 'Claude works in a closed box: it sees only the folder you open and connects only to Claude.')
Write-Host (T 'Całość trwa 10-30 minut. Możesz w tym czasie pracować; nie zamykaj tego okna.' 'This takes 10-30 minutes. You can keep working; do not close this window.')
Remove-ItemProperty -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\RunOnce' -Name 'ClaudeIDEBox' -ErrorAction SilentlyContinue

foreach ($f in @('windows\support\provision-root.sh', 'windows\support\provision-user.sh', 'windows\support\open.ps1', 'install.sh', 'bin\claude-ide-box')) {
  if (-not (Test-Path (Join-Path $SrcRoot $f))) {
    Fail (T "Brakuje pliku $f. Rozpakuj całe archiwum Claude IDE Box i uruchom instalator z rozpakowanego folderu." "Missing $f. Extract the whole Claude IDE Box archive and run the installer from the extracted folder.")
  }
}

# 1. Checks ------------------------------------------------------------------
Step 1 (T 'Sprawdzam komputer' 'Checking this computer')
$build = [Environment]::OSVersion.Version.Build
if ($build -lt 19041) {
  Fail (T "Ten Windows jest za stary (kompilacja $build, potrzebna 19041 lub nowsza). Poproś dział IT o aktualizację Windows." "This Windows is too old (build $build, 19041 or newer is needed). Ask your IT team to update Windows.")
}
$hyper = $false
try { $hyper = (Get-CimInstance Win32_ComputerSystem).HypervisorPresent } catch { }
$virt = $true
if (-not $hyper) {
  try { $virt = [bool](Get-CimInstance Win32_Processor | Select-Object -First 1).VirtualizationFirmwareEnabled } catch { }
}
if (-not $hyper -and -not $virt) {
  Fail (T 'Wirtualizacja jest wyłączona w ustawieniach BIOS/UEFI. Poproś dział IT o jej włączenie (Intel VT-x / AMD-V).' 'Virtualization is turned off in the BIOS/UEFI settings. Ask your IT team to turn it on (Intel VT-x / AMD-V).')
}
$drive = Get-PSDrive -Name ($env:LOCALAPPDATA.Substring(0, 1))
if ($drive.Free -lt 12GB) {
  Fail (T ("Za mało miejsca na dysku {0}: (potrzeba 12 GB, wolne {1:N1} GB)." -f $drive.Name, ($drive.Free / 1GB)) ("Not enough disk space on {0}: (12 GB needed, {1:N1} GB free)." -f $drive.Name, ($drive.Free / 1GB)))
}
Ok (T 'Komputer spełnia wymagania' 'This computer meets the requirements')

# 2. WSL ---------------------------------------------------------------------
Step 2 (T 'Podsystem Windows dla systemu Linux (WSL)' 'Windows Subsystem for Linux (WSL)')
$features = @{}
try {
  foreach ($n in @('VirtualMachinePlatform', 'Microsoft-Windows-Subsystem-Linux')) {
    $features[$n] = (Get-CimInstance Win32_OptionalFeature -Filter "Name='$n'").InstallState -eq 1
  }
} catch { $features = @{ VirtualMachinePlatform = $true; 'Microsoft-Windows-Subsystem-Linux' = $true } }
if (-not $features['VirtualMachinePlatform'] -or -not $features['Microsoft-Windows-Subsystem-Linux']) {
  Info (T 'Trzeba włączyć składniki Windows. Za chwilę Windows zapyta o zgodę administratora.' 'Windows components must be turned on. Windows will ask for administrator approval.')
  $rc = Invoke-Elevated 'dism.exe /online /enable-feature /featurename:VirtualMachinePlatform /all /norestart; $a=$LASTEXITCODE; dism.exe /online /enable-feature /featurename:Microsoft-Windows-Subsystem-Linux /all /norestart; $b=$LASTEXITCODE; if (($a -eq 0 -or $a -eq 3010) -and ($b -eq 0 -or $b -eq 3010)) { exit 3010 } else { exit 1 }'
  if ($null -eq $rc) { Fail (T 'Potrzebna jest zgoda administratora. Poproś dział IT o jednorazowe uruchomienie instalatora (lub o włączenie WSL).' 'Administrator approval is needed. Ask your IT team to run the installer once (or to turn on WSL).') }
  if ($rc -ne 3010) { Fail (T 'Nie udało się włączyć składników Windows (VirtualMachinePlatform, WSL).' 'Could not turn on the Windows components (VirtualMachinePlatform, WSL).') }
  $cmd = Join-Path $LauncherDir 'Install Claude IDE Box.cmd'
  Set-ItemProperty -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\RunOnce' -Name 'ClaudeIDEBox' -Value "`"$cmd`""
  Write-Host ''
  Write-Host (T 'Komputer musi się uruchomić ponownie. Instalacja wznowi się sama po zalogowaniu.' 'The computer must restart. Installation continues by itself after you sign in.') -ForegroundColor Yellow
  $r = Read-Host (T 'Zapisz otwarte dokumenty, potem wpisz TAK, aby uruchomić ponownie teraz' 'Save your open documents, then type YES to restart now')
  if ($r -in @('TAK', 'tak', 'YES', 'yes')) { Restart-Computer -Force }
  exit 0
}
$v = Get-Native 'wsl.exe' @('--version')
if ($v.Code -ne 0) {
  Info (T 'Aktualizuję WSL. Za chwilę Windows zapyta o zgodę administratora.' 'Updating WSL. Windows will ask for administrator approval.')
  $rc = Invoke-Elevated 'wsl.exe --update --web-download; exit $LASTEXITCODE'
  if ($null -eq $rc) { Fail (T 'Potrzebna jest zgoda administratora, aby zaktualizować WSL. Poproś dział IT o jednorazowe uruchomienie instalatora.' 'Administrator approval is needed to update WSL. Ask your IT team to run the installer once.') }
  $v = Get-Native 'wsl.exe' @('--version')
  if ($v.Code -ne 0) {
    Info (T 'Pobieram WSL z GitHub (Microsoft)...' 'Downloading WSL from GitHub (Microsoft)...')
    $rel = Invoke-RestMethod -UseBasicParsing 'https://api.github.com/repos/microsoft/WSL/releases/latest'
    $suffix = if ($Arch -eq 'arm64') { 'arm64.msi' } else { 'x64.msi' }
    $asset = $rel.assets | Where-Object { $_.name -like "*.$suffix" } | Select-Object -First 1
    if (-not $asset) { Fail 'WSL MSI not found in the latest release' }
    $msi = Join-Path $AppDir $asset.name
    Download $asset.browser_download_url $msi -Progress
    Assert-MicrosoftSigned $msi
    $rc = Invoke-Elevated "`$p = Start-Process msiexec.exe -Wait -PassThru -ArgumentList '/i `"$msi`" /qn /norestart'; exit `$p.ExitCode"
    Remove-Item -Force $msi -ErrorAction SilentlyContinue
    if ($null -eq $rc) { Fail (T 'Potrzebna jest zgoda administratora, aby zaktualizować WSL.' 'Administrator approval is needed to update WSL.') }
    $v = Get-Native 'wsl.exe' @('--version')
    if ($v.Code -ne 0) { Fail (T 'Nie udało się zaktualizować WSL. Uruchom ponownie komputer i instalator.' 'Could not update WSL. Restart the computer and run the installer again.') }
  }
}
Ok ((T 'WSL gotowy: ' 'WSL ready: ') + (($v.Out -split "`n")[0]))

# 3. Linux distribution with Docker Engine ----------------------------------
Step 3 (T "Własny Linux `"$Distro`" z Dockerem" "A separate Linux `"$Distro`" with Docker")
$LinuxUser = Get-LinuxUser
$state = @{}
if (Test-Path $StateFile) {
  (Get-Content -Raw $StateFile | ConvertFrom-Json).PSObject.Properties | ForEach-Object { $state[$_.Name] = $_.Value }
  if ($state.LinuxUser) { $LinuxUser = $state.LinuxUser }
}
$state.LinuxUser = $LinuxUser
$state.ProjectsName = $ProjectsName
Save-State $state
if (-not (Test-Distro)) {
  $name = "ubuntu-noble-wsl-$Arch-wsl.rootfs.tar.gz"
  $sums = Join-Path $AppDir 'SHA256SUMS'
  $tar = Join-Path $AppDir $name
  Info (T 'Pobieram Ubuntu 24.04 (ok. 350 MB)...' 'Downloading Ubuntu 24.04 (about 350 MB)...')
  Download "$UbuntuBase/SHA256SUMS" $sums
  Download "$UbuntuBase/$name" $tar -Progress
  $expected = (Get-Content $sums | Where-Object { $_ -match "^([0-9a-f]{64})\s+\*?$([regex]::Escape($name))$" } | Select-Object -First 1) -replace '\s.*$', ''
  $actual = (Get-FileHash -Algorithm SHA256 $tar).Hash.ToLowerInvariant()
  if (-not $expected -or $expected -ne $actual) {
    Remove-Item -Force $tar
    Fail (T 'Suma kontrolna pobranego Ubuntu się nie zgadza. Uruchom instalator ponownie.' 'The checksum of the downloaded Ubuntu image does not match. Run the installer again.')
  }
  Ok (T 'Suma SHA256 zgodna' 'SHA256 checksum matches')
  New-Item -ItemType Directory -Force -Path (Join-Path $AppDir 'wsl') | Out-Null
  Info (T 'Tworzę Linuksa z pobranego obrazu. To trwa 1-3 minuty i nic się w tym czasie nie wyświetla - proszę czekać...' 'Creating Linux from the downloaded image. This takes 1-3 minutes and shows nothing meanwhile - please wait...')
  $code = Run-Native 'wsl.exe' @('--import', $Distro, (Join-Path $AppDir 'wsl'), $tar, '--version', '2')
  Remove-Item -Force $tar, $sums -ErrorAction SilentlyContinue
  if ($code -ne 0) { Fail (T 'Nie udało się utworzyć dystrybucji WSL.' 'Could not create the WSL distribution.') }
}
$prov = Join-Path $AppDir 'provision-root.sh'
Write-LfFile (Join-Path $SrcRoot 'windows\support\provision-root.sh') $prov
if ((Wsl-Get $LinuxUser @('docker', 'info')).Code -ne 0) {
  Info (T 'Instaluję Docker Engine i aktualizacje Ubuntu. To trwa 2-5 minut - proszę czekać...' 'Installing Docker Engine and Ubuntu updates. This takes 2-5 minutes - please wait...')
  if ((Wsl-Quiet 'root' @('bash', (To-LinuxPath $prov), $LinuxUser) (T 'Proszę czekać...' 'Please wait...')) -ne 0) {
    Fail (T 'Konfiguracja Linuksa nie powiodła się (zobacz komunikaty powyżej).' 'Setting up Linux failed (see the messages above).')
  }
  & wsl.exe --terminate $Distro | Out-Null
  $ready = $false
  for ($i = 0; $i -lt 30 -and -not $ready; $i++) {
    Start-Sleep -Seconds 2
    $ready = (Wsl-Get $LinuxUser @('docker', 'info')).Code -eq 0
  }
  if (-not $ready) { Fail (T 'Docker nie wystartował w WSL.' 'Docker did not start in WSL.') }
}
$dv = (Wsl-Get $LinuxUser @('docker', 'version', '--format', '{{.Server.Version}}')).Out
Ok ((T 'Docker Engine działa: ' 'Docker Engine is running: ') + $dv)

# 4. VS Code -----------------------------------------------------------------
Step 4 'Visual Studio Code'
$codeExe = Find-VsCode
$need = $true
if ($codeExe) {
  $ver = [version]((Get-Item $codeExe).VersionInfo.ProductVersion -replace '[^0-9.].*$', '')
  $need = $ver -lt $MinVsCode
  if ($need -and $codeExe -like "$env:ProgramFiles*") {
    Fail (T "VS Code $ver jest zainstalowany dla wszystkich użytkowników i jest za stary (potrzebna wersja $MinVsCode). Poproś dział IT o aktualizację." "VS Code $ver is installed for all users and is too old ($MinVsCode is needed). Ask your IT team to update it.")
  }
}
if ($need) {
  $dir = Join-Path $env:LOCALAPPDATA 'Programs\Microsoft VS Code'
  while (Get-Process -Name 'Code' -ErrorAction SilentlyContinue | Where-Object { $_.Path -like "$dir*" }) {
    Warn (T 'VS Code jest otwarty i trzeba go zaktualizować. Zapisz pracę i zamknij VS Code.' 'VS Code is open and must be updated. Save your work and close VS Code.')
    [void](Read-Host (T 'Potem naciśnij Enter' 'Then press Enter'))
  }
  Info (T 'Pobieram VS Code...' 'Downloading VS Code...')
  $plat = if ($Arch -eq 'arm64') { 'win32-arm64-user' } else { 'win32-x64-user' }
  $setup = Join-Path $AppDir 'VSCodeUserSetup.exe'
  Download "https://update.code.visualstudio.com/latest/$plat/stable" $setup -Progress
  Assert-MicrosoftSigned $setup
  Info (T 'Instaluję VS Code. To trwa 1-2 minuty i nic się w tym czasie nie wyświetla - proszę czekać...' 'Installing VS Code. This takes 1-2 minutes and shows nothing meanwhile - please wait...')
  $p = Start-Process $setup -Wait -PassThru -ArgumentList '/VERYSILENT /NORESTART /MERGETASKS=!runcode'
  Remove-Item -Force $setup -ErrorAction SilentlyContinue
  if ($p.ExitCode -ne 0) { Fail (T 'Instalacja VS Code nie powiodła się.' 'Installing VS Code failed.') }
  $codeExe = Find-VsCode
  if (-not $codeExe) { Fail 'VS Code not found after installation' }
}
$codeCli = Join-Path (Split-Path $codeExe) 'bin\code.cmd'
$cv = (Get-Native $codeCli @('--version')).Out -split "`n"
$commit = if ($cv.Count -ge 2) { $cv[1].Trim() } else { '-' }
Ok ("VS Code $($cv[0])")

# 5. claude-ide-box inside the distribution ---------------------------------
Step 5 (T 'Claude IDE Box w Linuksie (pierwszy raz: 5-15 minut)' 'Claude IDE Box inside Linux (first time: 5-15 minutes)')
$provUser = Join-Path $AppDir 'provision-user.sh'
Write-LfFile (Join-Path $SrcRoot 'windows\support\provision-user.sh') $provUser
Info (T 'Buduję środowisko pracy Claude (Linux, narzędzia biurowe, filtr sieci). Proszę czekać, nie zamykaj okna.' 'Building the environment Claude works in (Linux, office tools, network filter). Please wait; do not close this window.')
$code = Wsl-Quiet $LinuxUser @('bash', (To-LinuxPath $provUser), (To-LinuxPath $SrcRoot), $ImageProfile, $ProjectsName, $FirstProject, $commit) (T 'Proszę czekać...' 'Please wait...')
if ($code -ne 0) { Fail (T 'Instalacja Claude IDE Box w Linuksie nie powiodła się (zobacz komunikaty powyżej).' 'Installing Claude IDE Box inside Linux failed (see the messages above).') }
$wrapper = "/home/$LinuxUser/.local/share/claude-ide-box/bin/claude-ide-box-exec"
if ((Wsl-Get $LinuxUser @('test', '-x', $wrapper)).Code -ne 0) { Fail "missing $wrapper" }
Ok (T 'Claude IDE Box zainstalowany' 'Claude IDE Box installed')

# 6. VS Code profile ---------------------------------------------------------
Step 6 (T "Profil VS Code `"$VsProfile`"" "VS Code profile `"$VsProfile`"")
Info (T 'Inne profile VS Code i inne edytory (np. Antigravity) pozostają bez zmian.' 'Other VS Code profiles and other editors (e.g. Antigravity) are left unchanged.')
$storage = Join-Path $env:APPDATA 'Code\User\globalStorage\storage.json'
function Get-ProfileLocation {
  try {
    $s = Get-Content -Raw -Encoding UTF8 $storage | ConvertFrom-Json
    return ($s.userDataProfiles | Where-Object { $_.name -eq $VsProfile } | Select-Object -First 1).location
  } catch { return $null }
}
$loc = Get-ProfileLocation
$openedWindow = $false
if (-not $loc) {
  # The CLI cannot create a profile ("--install-extension" says "not found");
  # opening a window with --profile does. The same window shows the first
  # project at the end of the installation.
  Info (T 'Za chwilę otworzy się okno VS Code - to celowe, nie zamykaj go. Instalacja trwa dalej tutaj.' 'A VS Code window opens in a moment - that is expected, leave it open. Installation continues here.')
  Start-Sleep -Seconds 3
  [void](Run-Native $codeCli @('--profile', $VsProfile, '--new-window'))
  $openedWindow = $true
  for ($i = 0; $i -lt 60 -and -not $loc; $i++) {
    Start-Sleep -Seconds 1
    $loc = Get-ProfileLocation
  }
}
if (-not $loc) { Fail (T "VS Code nie utworzył profilu `"$VsProfile`"." "VS Code did not create the `"$VsProfile`" profile.") }
if ((Run-Native $codeCli @('--profile', $VsProfile, '--install-extension', 'ms-vscode-remote.remote-wsl')) -ne 0) {
  Fail (T 'Nie udało się zainstalować rozszerzenia WSL w VS Code.' 'Could not install the WSL extension in VS Code.')
}
$profDir = Join-Path $env:APPDATA "Code\User\profiles\$loc"
New-Item -ItemType Directory -Force -Path $profDir | Out-Null
$settings = Join-Path $profDir 'settings.json'
$existing = if (Test-Path $settings) { (Get-Content -Raw $settings) } else { '' }
if ($existing -match 'claude-ide-box-exec') {
  Ok (T 'Ustawienia profilu są już gotowe' 'The profile settings are already in place')
} elseif ($existing -and $existing.Trim() -notin @('', '{}')) {
  Warn (T "Profil ma już własne ustawienia; nie zmieniam ich. Dopisz w nim: `"claudeCode.claudeProcessWrapper`": `"$wrapper`"" "The profile already has settings; they are not changed. Add: `"claudeCode.claudeProcessWrapper`": `"$wrapper`"")
} else {
  $json = @"
{
  // Claude IDE Box: Claude Code runs in the container, never on this computer.
  "claudeCode.claudeProcessWrapper": "$wrapper",
  "claudeCode.useTerminal": false,
  "git.autoRepositoryDetection": false,

  // A calmer window for people who do not write code.
  "files.autoSave": "afterDelay",
  "workbench.startupEditor": "none",
  "workbench.tips.enabled": false,
  "workbench.welcomePage.walkthroughs.openOnInstall": false,
  "workbench.layoutControl.enabled": false,
  "window.commandCenter": false,
  "chat.commandCenter.enabled": false,
  "editor.minimap.enabled": false,
  "breadcrumbs.enabled": false,
  "extensions.ignoreRecommendations": true,
  "update.showReleaseNotes": false
}
"@
  [IO.File]::WriteAllText($settings, $json, (New-Object Text.UTF8Encoding $false))
  Ok (T 'Ustawienia profilu zapisane' 'Profile settings written')
}
$state.VsProfileLocation = $loc
Save-State $state

# 7. Sign in -----------------------------------------------------------------
Step 7 (T 'Logowanie do Claude' 'Signing in to Claude')
$tokenCheck = Wsl-Get $LinuxUser @('test', '-s', "/home/$LinuxUser/.config/claude-ide-box/token")
if ($tokenCheck.Code -eq 0) {
  Ok (T 'Już zalogowano' 'Already signed in')
} else {
  Write-Host ''
  Write-Host (T '      Za chwilę otworzy się przeglądarka:' '      Your browser opens in a moment:') -ForegroundColor Yellow
  Write-Host (T '        1. zaloguj się do Claude i kliknij "Authorize" / "Autoryzuj",' '        1. sign in to Claude and click "Authorize",') -ForegroundColor Yellow
  Write-Host (T '        2. skopiuj pokazany kod,' '        2. copy the code it shows,') -ForegroundColor Yellow
  Write-Host (T '        3. wróć tutaj, kliknij PRAWYM przyciskiem myszy w to okno (wkleja kod) i naciśnij Enter.' '        3. come back here, RIGHT-click in this window (this pastes the code) and press Enter.') -ForegroundColor Yellow
  Write-Host ''
  for ($i = 0; $i -lt 3; $i++) {
    & wsl.exe -d $Distro -e bash -c '$HOME/.local/bin/claude-ide-box login'
    Restore-Console
    if ((Wsl-Get $LinuxUser @('test', '-s', "/home/$LinuxUser/.config/claude-ide-box/token")).Code -eq 0) { break }
    Warn (T 'Logowanie się nie udało. Spróbujmy jeszcze raz.' 'Sign-in did not work. Let us try again.')
  }
  if ((Wsl-Get $LinuxUser @('test', '-s', "/home/$LinuxUser/.config/claude-ide-box/token")).Code -ne 0) {
    Fail (T 'Nie udało się zalogować do Claude.' 'Could not sign in to Claude.')
  }
  Ok (T 'Zalogowano' 'Signed in')
}

# 8. Shortcuts, check, first project -----------------------------------------
Step 8 (T 'Skróty na pulpicie i sprawdzenie' 'Desktop shortcuts and a final check')
$app = Join-Path $AppDir 'app'
New-Item -ItemType Directory -Force -Path $app | Out-Null
Copy-Item -Force (Join-Path $SrcRoot 'windows\support\open.ps1') (Join-Path $app 'open.ps1')
Copy-Item -Force (Join-Path $SrcRoot 'windows\support\install.ps1') (Join-Path $app 'install.ps1')
$desk = [Environment]::GetFolderPath('Desktop')
$shell = New-Object -ComObject WScript.Shell
$lnk = $shell.CreateShortcut((Join-Path $desk 'Claude.lnk'))
$lnk.TargetPath = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$lnk.Arguments = "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$(Join-Path $app 'open.ps1')`""
$lnk.WindowStyle = 7
$lnk.IconLocation = "$codeExe,0"
$lnk.Description = T 'Otwórz folder z Claude w zamkniętym pudełku. Możesz przeciągnąć folder na tę ikonę.' 'Open a folder with Claude in a closed box. You can drop a folder on this icon.'
$lnk.Save()
$projectsWin = Join-Path (Wsl-Share) "home\$LinuxUser\$ProjectsName"
$lnk = $shell.CreateShortcut((Join-Path $desk "$ProjectsName Claude.lnk"))
$lnk.TargetPath = $projectsWin
$lnk.Description = T 'Foldery, na których pracuje Claude. Pliki otwierasz stąd normalnie, np. w Wordzie.' 'The folders Claude works on. Open files from here as usual, e.g. in Word.'
$lnk.Save()
Ok (T "Na pulpicie: `"Claude`" i `"$ProjectsName Claude`"" "On the desktop: `"Claude`" and `"$ProjectsName Claude`"")

Info (T 'Sprawdzam całość (claude-ide-box doctor)...' 'Checking everything (claude-ide-box doctor)...')
$doctor = Wsl-Run $LinuxUser @('bash', '-c', '$HOME/.local/bin/claude-ide-box doctor')

$dd = 'C:\Program Files\Docker\Docker\Docker Desktop.exe'
if (Test-Path $dd) {
  $ddv = (Get-Item $dd).VersionInfo.ProductVersion
  try {
    if ([version]($ddv -replace '[^0-9.].*$', '') -lt [version]'4.44.3') {
      Warn (T "Uwaga: na tym komputerze jest stary Docker Desktop $ddv ze znaną luką bezpieczeństwa (CVE-2025-9074). Claude IDE Box go nie używa, ale poproś dział IT o jego aktualizację lub odinstalowanie." "Note: this computer has an old Docker Desktop $ddv with a known security hole (CVE-2025-9074). Claude IDE Box does not use it, but ask your IT team to update or remove it.")
    }
  } catch { }
}

Write-Host ''
if ($doctor -eq 0) {
  Write-Host (T 'Wszystko gotowe!' 'All done!') -ForegroundColor Green
} else {
  Write-Host (T "Instalacja zakończona, ale sprawdzenie zgłosiło problem (linie [FAIL] powyżej). Wyślij dziale IT plik:`n  $LogFile" "Installation finished, but the check reported a problem ([FAIL] lines above). Send this file to your IT team:`n  $LogFile") -ForegroundColor Yellow
}
Write-Host (T "Otwieram VS Code w folderze `"$FirstProject`". Panel Claude otwierasz ikoną Claude na pasku po lewej lub w prawym górnym rogu." "Opening VS Code in `"$FirstProject`". Open the Claude panel with the Claude icon on the left bar or at the top right.")
& powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $app 'open.ps1') "$projectsWin\$FirstProject"
try { Stop-Transcript | Out-Null } catch { }
Pause-Close
