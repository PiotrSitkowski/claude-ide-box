#Requires -Version 5.1
<#
Claude IDE Box for Windows: one double-click, no terminal.

  Install Claude IDE Box.cmd                install, change the selection, or repair (safe to run again)
  Install Claude IDE Box.cmd -Settings      the same, opened from the Start menu ("settings")
  Install Claude IDE Box.cmd -Uninstall     remove it (projects are copied to Documents first)
  Install Claude IDE Box.cmd -Language de   use another language than Windows' (texts: i18n\*.psd1)

Steps (each is skipped when already done):
  1. checks Windows, virtualization and disk space
  2. asks what Claude is for (office work / programming / both), then what to install
  3. WSL: enables/updates it (the only step that asks for administrator rights)
  4. a separate Linux distribution "ClaudeIDEBox" from Ubuntu's WSL image (SHA256 checked),
     with Docker Engine inside; Docker Desktop is not used
  5. VS Code: installed or updated for the current user if missing or too old, and a
     "Claude IDE Box" profile; other profiles and other IDEs (Antigravity, Cursor) are not touched
  6. claude-ide-box inside the distribution with the chosen modules
  7. the profile's settings (the wrapper; a calmer window for office work)
  8. sign-in to Claude (the browser opens; the code is pasted back)
  9. shortcuts, a final check, and the first project opens
#>
param(
  [switch]$Uninstall,
  [switch]$Settings,
  [string]$Language
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
[Console]::OutputEncoding = New-Object System.Text.UTF8Encoding $false
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

. (Join-Path $PSScriptRoot 'lib.ps1')
Initialize-Messages $Language

$MinVsCode = [version]'1.100.0'
$UbuntuBase = 'https://cloud-images.ubuntu.com/wsl/releases/24.04/current'
$LogFile = Join-Path $AppDir 'install.log'
$LinuxLog = Join-Path $AppDir 'linux-setup.log'
$LauncherDir = Split-Path -Parent $PSScriptRoot
$SrcRoot = Split-Path -Parent $LauncherDir
$AppCopy = Join-Path $AppDir 'app'
$Arch = if ($env:PROCESSOR_ARCHITECTURE -eq 'ARM64') { 'arm64' } else { 'amd64' }
$Steps = 9

function Step([int]$n, [string]$text) {
  Write-Host ''
  Write-Host "[$n/$Steps] $text" -ForegroundColor Cyan
}
function Info([string]$text) { Write-Host "      $text" }
function Ok([string]$text) { Write-Host "      $text" -ForegroundColor Green }
function Warn([string]$text) { Write-Host "      $text" -ForegroundColor Yellow }

function Pause-Close {
  Write-Host ''
  [void](Read-Host (M 'Press_Enter_Close'))
}

function Fail([string]$text) {
  Write-Host ''
  Write-Host (M 'Failed_Title') -ForegroundColor Red
  Write-Host "  $text" -ForegroundColor Red
  Write-Host ''
  Write-Host (M 'Failed_SendLog' $LogFile)
  try { Stop-Transcript | Out-Null } catch { }
  Pause-Close
  exit 1
}

function Is-Yes([string]$answer) {
  return ($answer.Trim() -ieq (M 'Yes_Word')) -or ($answer.Trim() -ieq 'YES')
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

# Long Linux-side work: its output goes to a log file, not to the console
# (hundreds of apt/docker lines are noise for the person installing, and a
# Linux program can leave the Windows console in a broken line mode). The
# console shows one line with the elapsed time; on failure, the end of the log.
function Wsl-Quiet([string]$user, [string[]]$cmd) {
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
  $wait = M 'Please_Wait'
  while (-not $p.HasExited) {
    $t = '{0}:{1:00}' -f [int][math]::Floor($sw.Elapsed.TotalMinutes), $sw.Elapsed.Seconds
    [Console]::Write("`r      $wait $t   ")
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
    Write-Host ('      ' + (M 'Log_LastLines')) -ForegroundColor Yellow
    Get-Content -Tail 25 -Encoding UTF8 $LinuxLog | ForEach-Object { Write-Host "        $_" }
    return 1
  }
  return 0
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
    if ($code -ne 0) { Fail (M 'Download_Failed' $url) }
  } else {
    try { Invoke-WebRequest -UseBasicParsing -Uri $url -OutFile $out }
    catch { Fail (M 'Download_Failed' $url) }
  }
}

function Assert-MicrosoftSigned([string]$file) {
  $sig = Get-AuthenticodeSignature -FilePath $file
  if ($sig.Status -ne 'Valid' -or $sig.SignerCertificate.Subject -notmatch 'O=Microsoft Corporation') {
    Remove-Item -Force $file -ErrorAction SilentlyContinue
    Fail (M 'Signature_Invalid' $file)
  }
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

function Get-Sha256([string]$text) {
  $sha = [Security.Cryptography.SHA256]::Create()
  return -join ($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($text)) | ForEach-Object { $_.ToString('x2') })
}

# Copies the files Claude IDE Box needs to %LOCALAPPDATA%\ClaudeIDEBox\app, so
# the shortcuts and "settings" keep working after the download is deleted.
function Copy-App {
  if ($SrcRoot -eq $AppCopy) { return }
  $new = "$AppCopy.new"
  Remove-Item -Recurse -Force $new -ErrorAction SilentlyContinue
  New-Item -ItemType Directory -Force -Path $new | Out-Null
  foreach ($d in @('bin', 'lib', 'image', 'proxy', 'windows')) {
    Copy-Item -Recurse -Force (Join-Path $SrcRoot $d) (Join-Path $new $d)
  }
  foreach ($f in @('install.sh', 'LICENSE', 'NOTICE')) {
    if (Test-Path (Join-Path $SrcRoot $f)) { Copy-Item -Force (Join-Path $SrcRoot $f) $new }
  }
  Remove-Item -Recurse -Force $AppCopy -ErrorAction SilentlyContinue
  Rename-Item $new (Split-Path -Leaf $AppCopy)
}

# ---------------------------------------------------------------------------
# Uninstall
# ---------------------------------------------------------------------------

$ProjectsName = M 'Projects_Folder'
$FirstProject = M 'First_Project'

if ($Uninstall) {
  Write-Host (M 'Uninstall_Title') -ForegroundColor Cyan
  $state = Read-State
  if ($state.ProjectsName) { $ProjectsName = $state.ProjectsName }
  Write-Host (M 'Uninstall_CopyFirst' $ProjectsName)
  if (-not (Is-Yes (Read-Host (M 'Type_Yes_Continue')))) { exit 0 }
  if (Test-Distro) {
    if ($state.LinuxUser) {
      $from = Join-Path (Wsl-Share) "home\$($state.LinuxUser)\$ProjectsName"
      if (Test-Path $from) {
        $to = Join-Path ([Environment]::GetFolderPath('MyDocuments')) ("$ProjectsName Claude - " + (Get-Date -Format 'yyyy-MM-dd HHmm'))
        & robocopy.exe $from $to /E /R:1 /W:1 /NFL /NDL /NJH /NJS | Out-Null
        if ($LASTEXITCODE -ge 8) {
          Write-Host (M 'Uninstall_CopyFailed') -ForegroundColor Red
          Pause-Close
          exit 1
        }
        Write-Host (M 'Uninstall_Copied' $to) -ForegroundColor Green
      }
    }
    & wsl.exe --unregister $Distro | Out-Null
  }
  $desk = [Environment]::GetFolderPath('Desktop')
  $menu = Join-Path ([Environment]::GetFolderPath('Programs')) 'Claude IDE Box'
  Remove-Item -Force -ErrorAction SilentlyContinue (Join-Path $desk 'Claude.lnk'), (Join-Path $desk "$ProjectsName Claude.lnk")
  Remove-Item -Recurse -Force -ErrorAction SilentlyContinue $menu
  Write-Host (M 'Uninstall_Done' $VsProfile) -ForegroundColor Green
  Pause-Close
  # Last: this script may itself run from the copy in $AppDir.
  Start-Process cmd.exe -WindowStyle Hidden -ArgumentList "/c timeout /t 2 >nul & rmdir /s /q `"$AppDir`""
  exit 0
}

# ---------------------------------------------------------------------------
# Install
# ---------------------------------------------------------------------------

New-Item -ItemType Directory -Force -Path $AppDir | Out-Null
try { Start-Transcript -Append -Path $LogFile | Out-Null } catch { }
$Host.UI.RawUI.WindowTitle = M 'App_Name'
if ($Settings) {
  Write-Host (M 'Settings_Title') -ForegroundColor Cyan
} else {
  Write-Host (M 'Install_Title') -ForegroundColor Cyan
  Write-Host (M 'Install_Intro')
}
Remove-ItemProperty -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\RunOnce' -Name 'ClaudeIDEBox' -ErrorAction SilentlyContinue

foreach ($f in @('windows\support\provision-root.sh', 'windows\support\provision-user.sh', 'windows\support\open.ps1',
    'windows\support\choose.ps1', 'windows\support\modules.psd1', 'install.sh', 'bin\claude-ide-box')) {
  if (-not (Test-Path (Join-Path $SrcRoot $f))) { Fail (M 'Missing_File' $f) }
}
$state = Read-State

# 1. Checks ------------------------------------------------------------------
Step 1 (M 'Step_Checks')
$build = [Environment]::OSVersion.Version.Build
if ($build -lt 19041) { Fail (M 'Windows_TooOld' $build) }
$hyper = $false
try { $hyper = (Get-CimInstance Win32_ComputerSystem).HypervisorPresent } catch { }
$virt = $true
if (-not $hyper) {
  try { $virt = [bool](Get-CimInstance Win32_Processor | Select-Object -First 1).VirtualizationFirmwareEnabled } catch { }
}
if (-not $hyper -and -not $virt) { Fail (M 'Virtualization_Off') }
$drive = Get-PSDrive -Name ($env:LOCALAPPDATA.Substring(0, 1))
if ($drive.Free -lt 12GB) { Fail (M 'Disk_TooSmall' $drive.Name ([math]::Round($drive.Free / 1GB, 1))) }
Ok (M 'Checks_Ok')

# 2. What to install ---------------------------------------------------------
Step 2 (M 'Step_Choose')
Info (M 'Choose_WindowOpens')
. (Join-Path $PSScriptRoot 'choose.ps1')
$catalog = Import-PowerShellDataFile (Join-Path $PSScriptRoot 'modules.psd1')
$current = $null
if ($state.Purpose) {
  $current = @{ Purpose = $state.Purpose; Office = @($state.Office); Dev = @($state.Dev); Ocr = @($state.Ocr) }
}
$choice = Show-Choice $catalog $SrcRoot $current
if (-not $choice) {
  Warn (M 'Choose_Cancelled')
  try { Stop-Transcript | Out-Null } catch { }
  Pause-Close
  exit 0
}
$profiles = @($choice.Office) + @($choice.Dev)
$profileList = if ($profiles.Count) { $profiles -join ' ' } else { 'base' }
$presetsOn = @($catalog.Dev | Where-Object { $choice.Dev -contains $_.Id } | ForEach-Object { $_.Preset })
$presetsOff = @($catalog.Dev | Where-Object { $choice.Dev -notcontains $_.Id } | ForEach-Object { $_.Preset })
Ok (M 'Choose_Summary' (M "Purpose_$($choice.Purpose)") $(if ($profiles.Count) { ($profiles | ForEach-Object { M "Module_$_" }) -join ', ' } else { M 'Choose_NothingExtra' }))

# 3. WSL ---------------------------------------------------------------------
Step 3 (M 'Step_Wsl')
$features = @{}
try {
  foreach ($n in @('VirtualMachinePlatform', 'Microsoft-Windows-Subsystem-Linux')) {
    $features[$n] = (Get-CimInstance Win32_OptionalFeature -Filter "Name='$n'").InstallState -eq 1
  }
} catch { $features = @{ VirtualMachinePlatform = $true; 'Microsoft-Windows-Subsystem-Linux' = $true } }
if (-not $features['VirtualMachinePlatform'] -or -not $features['Microsoft-Windows-Subsystem-Linux']) {
  Info (M 'Wsl_EnableFeatures')
  $rc = Invoke-Elevated 'dism.exe /online /enable-feature /featurename:VirtualMachinePlatform /all /norestart; $a=$LASTEXITCODE; dism.exe /online /enable-feature /featurename:Microsoft-Windows-Subsystem-Linux /all /norestart; $b=$LASTEXITCODE; if (($a -eq 0 -or $a -eq 3010) -and ($b -eq 0 -or $b -eq 3010)) { exit 3010 } else { exit 1 }'
  if ($null -eq $rc) { Fail (M 'Admin_Needed_Features') }
  if ($rc -ne 3010) { Fail (M 'Wsl_FeaturesFailed') }
  $state.Purpose = $choice.Purpose; $state.Office = $choice.Office; $state.Dev = $choice.Dev; $state.Ocr = $choice.Ocr
  Save-State $state
  $cmd = Join-Path $LauncherDir 'Install Claude IDE Box.cmd'
  Set-ItemProperty -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\RunOnce' -Name 'ClaudeIDEBox' -Value "`"$cmd`""
  Write-Host ''
  Write-Host (M 'Restart_Needed') -ForegroundColor Yellow
  if (Is-Yes (Read-Host (M 'Restart_Prompt'))) { Restart-Computer -Force }
  exit 0
}
$v = Get-Native 'wsl.exe' @('--version')
if ($v.Code -ne 0) {
  Info (M 'Wsl_Updating')
  $rc = Invoke-Elevated 'wsl.exe --update --web-download; exit $LASTEXITCODE'
  if ($null -eq $rc) { Fail (M 'Admin_Needed_Wsl') }
  $v = Get-Native 'wsl.exe' @('--version')
  if ($v.Code -ne 0) {
    Info (M 'Wsl_DownloadingMsi')
    $rel = Invoke-RestMethod -UseBasicParsing 'https://api.github.com/repos/microsoft/WSL/releases/latest'
    $suffix = if ($Arch -eq 'arm64') { 'arm64.msi' } else { 'x64.msi' }
    $asset = $rel.assets | Where-Object { $_.name -like "*.$suffix" } | Select-Object -First 1
    if (-not $asset) { Fail 'WSL MSI not found in the latest release' }
    $msi = Join-Path $AppDir $asset.name
    Download $asset.browser_download_url $msi -Progress
    Assert-MicrosoftSigned $msi
    $rc = Invoke-Elevated "`$p = Start-Process msiexec.exe -Wait -PassThru -ArgumentList '/i `"$msi`" /qn /norestart'; exit `$p.ExitCode"
    Remove-Item -Force $msi -ErrorAction SilentlyContinue
    if ($null -eq $rc) { Fail (M 'Admin_Needed_Wsl') }
    $v = Get-Native 'wsl.exe' @('--version')
    if ($v.Code -ne 0) { Fail (M 'Wsl_UpdateFailed') }
  }
}
Ok (M 'Wsl_Ready' (($v.Out -split "`n")[0]))

# 4. Linux distribution with Docker Engine ----------------------------------
Step 4 (M 'Step_Distro' $Distro)
$LinuxUser = Get-LinuxUser
if ($state.LinuxUser) { $LinuxUser = $state.LinuxUser }
if ($state.ProjectsName) { $ProjectsName = $state.ProjectsName } else { $state.ProjectsName = $ProjectsName }
if ($state.FirstProject) { $FirstProject = $state.FirstProject } else { $state.FirstProject = $FirstProject }
$state.LinuxUser = $LinuxUser
Save-State $state
if (-not (Test-Distro)) {
  $name = "ubuntu-noble-wsl-$Arch-wsl.rootfs.tar.gz"
  $sums = Join-Path $AppDir 'SHA256SUMS'
  $tar = Join-Path $AppDir $name
  Info (M 'Distro_Downloading')
  Download "$UbuntuBase/SHA256SUMS" $sums
  Download "$UbuntuBase/$name" $tar -Progress
  $expected = (Get-Content $sums | Where-Object { $_ -match "^([0-9a-f]{64})\s+\*?$([regex]::Escape($name))$" } | Select-Object -First 1) -replace '\s.*$', ''
  $actual = (Get-FileHash -Algorithm SHA256 $tar).Hash.ToLowerInvariant()
  if (-not $expected -or $expected -ne $actual) {
    Remove-Item -Force $tar
    Fail (M 'Distro_ChecksumBad')
  }
  Ok (M 'Distro_ChecksumOk')
  Info (M 'Distro_Importing')
  New-Item -ItemType Directory -Force -Path (Join-Path $AppDir 'wsl') | Out-Null
  $code = Run-Native 'wsl.exe' @('--import', $Distro, (Join-Path $AppDir 'wsl'), $tar, '--version', '2')
  Remove-Item -Force $tar, $sums -ErrorAction SilentlyContinue
  if ($code -ne 0) { Fail (M 'Distro_ImportFailed') }
}
$prov = Join-Path $AppDir 'provision-root.sh'
Write-LfFile (Join-Path $PSScriptRoot 'provision-root.sh') $prov
if ((Wsl-Get $LinuxUser @('docker', 'info')).Code -ne 0) {
  Info (M 'Distro_InstallingDocker')
  if ((Wsl-Quiet 'root' @('bash', (To-LinuxPath $prov), $LinuxUser)) -ne 0) { Fail (M 'Distro_SetupFailed') }
  & wsl.exe --terminate $Distro | Out-Null
  $ready = $false
  for ($i = 0; $i -lt 30 -and -not $ready; $i++) {
    Start-Sleep -Seconds 2
    $ready = (Wsl-Get $LinuxUser @('docker', 'info')).Code -eq 0
  }
  if (-not $ready) { Fail (M 'Docker_NotStarted') }
}
$dv = (Wsl-Get $LinuxUser @('docker', 'version', '--format', '{{.Server.Version}}')).Out
Ok (M 'Docker_Running' $dv)

# 5. VS Code and its profile -------------------------------------------------
Step 5 (M 'Step_VsCode')
$codeExe = Find-VsCode
$need = $true
if ($codeExe) {
  $ver = [version]((Get-Item $codeExe).VersionInfo.ProductVersion -replace '[^0-9.].*$', '')
  $need = $ver -lt $MinVsCode
  if ($need -and $codeExe -like "$env:ProgramFiles*") { Fail (M 'VsCode_SystemTooOld' $ver $MinVsCode) }
}
if ($need) {
  $dir = Join-Path $env:LOCALAPPDATA 'Programs\Microsoft VS Code'
  while (Get-Process -Name 'Code' -ErrorAction SilentlyContinue | Where-Object { $_.Path -like "$dir*" }) {
    Warn (M 'VsCode_CloseIt')
    [void](Read-Host (M 'Then_Press_Enter'))
  }
  Info (M 'VsCode_Downloading')
  $plat = if ($Arch -eq 'arm64') { 'win32-arm64-user' } else { 'win32-x64-user' }
  $setup = Join-Path $AppDir 'VSCodeUserSetup.exe'
  Download "https://update.code.visualstudio.com/latest/$plat/stable" $setup -Progress
  Assert-MicrosoftSigned $setup
  Info (M 'VsCode_Installing')
  $p = Start-Process $setup -Wait -PassThru -ArgumentList '/VERYSILENT /NORESTART /MERGETASKS=!runcode'
  Remove-Item -Force $setup -ErrorAction SilentlyContinue
  if ($p.ExitCode -ne 0) { Fail (M 'VsCode_InstallFailed') }
  $codeExe = Find-VsCode
  if (-not $codeExe) { Fail 'VS Code not found after installation' }
}
$codeCli = Join-Path (Split-Path $codeExe) 'bin\code.cmd'
$cv = (Get-Native $codeCli @('--version')).Out -split "`n"
$commit = if ($cv.Count -ge 2) { $cv[1].Trim() } else { '-' }
Ok ("VS Code $($cv[0])")

Info (M 'Profile_Untouched')
$storage = Join-Path $env:APPDATA 'Code\User\globalStorage\storage.json'
function Get-ProfileLocation {
  try {
    $s = Get-Content -Raw -Encoding UTF8 $storage | ConvertFrom-Json
    return ($s.userDataProfiles | Where-Object { $_.name -eq $VsProfile } | Select-Object -First 1).location
  } catch { return $null }
}
$loc = Get-ProfileLocation
if (-not $loc) {
  # The CLI cannot create a profile ("--install-extension" says "not found");
  # opening a window with --profile does.
  Info (M 'Profile_WindowOpens')
  Start-Sleep -Seconds 3
  [void](Run-Native $codeCli @('--profile', $VsProfile, '--new-window'))
  for ($i = 0; $i -lt 60 -and -not $loc; $i++) {
    Start-Sleep -Seconds 1
    $loc = Get-ProfileLocation
  }
}
if (-not $loc) { Fail (M 'Profile_NotCreated' $VsProfile) }
if ((Run-Native $codeCli @('--profile', $VsProfile, '--install-extension', 'ms-vscode-remote.remote-wsl')) -ne 0) {
  Fail (M 'Profile_WslExtFailed')
}
$state.VsProfileLocation = $loc
Save-State $state
Ok (M 'Profile_Ready' $VsProfile)

# 6. claude-ide-box inside the distribution ---------------------------------
Step 6 (M 'Step_Box')
Copy-App
Info (M 'Box_Building')
$provUser = Join-Path $AppDir 'provision-user.sh'
Write-LfFile (Join-Path $PSScriptRoot 'provision-user.sh') $provUser
$argsUser = @('bash', (To-LinuxPath $provUser),
  '--src', (To-LinuxPath $AppCopy),
  '--profile', $profileList,
  '--ocr', ($choice.Ocr -join ' '),
  '--projects', $ProjectsName,
  '--first', $FirstProject,
  '--vscode-commit', $commit,
  '--vscode-profile', $loc)
foreach ($p in $presetsOn) { $argsUser += @('--preset-on', $p) }
foreach ($p in $presetsOff) { $argsUser += @('--preset-off', $p) }
if ((Wsl-Quiet $LinuxUser $argsUser) -ne 0) { Fail (M 'Box_Failed') }
$wrapper = "/home/$LinuxUser/.local/share/claude-ide-box/bin/claude-ide-box-exec"
if ((Wsl-Get $LinuxUser @('test', '-x', $wrapper)).Code -ne 0) { Fail "missing $wrapper" }
$state.Purpose = $choice.Purpose
$state.Office = $choice.Office
$state.Dev = $choice.Dev
$state.Ocr = $choice.Ocr
Save-State $state
Ok (M 'Box_Ready')

# 7. Profile settings --------------------------------------------------------
Step 7 (M 'Step_Settings' $VsProfile)
$profDir = Join-Path $env:APPDATA "Code\User\profiles\$loc"
New-Item -ItemType Directory -Force -Path $profDir | Out-Null
$settingsFile = Join-Path $profDir 'settings.json'
$lines = @(
  '{',
  '  // Claude IDE Box: Claude Code runs in the container, never on this computer.',
  "  `"claudeCode.claudeProcessWrapper`": `"$wrapper`",",
  '  "claudeCode.useTerminal": false,',
  '  "git.autoRepositoryDetection": false'
)
if ($choice.Purpose -eq 'office') {
  $lines[-1] += ','
  $lines += @(
    '',
    '  // A calmer window for people who do not write code.',
    '  "files.autoSave": "afterDelay",',
    '  "workbench.startupEditor": "none",',
    '  "workbench.tips.enabled": false,',
    '  "workbench.welcomePage.walkthroughs.openOnInstall": false,',
    '  "workbench.layoutControl.enabled": false,',
    '  "window.commandCenter": false,',
    '  "chat.commandCenter.enabled": false,',
    '  "editor.minimap.enabled": false,',
    '  "breadcrumbs.enabled": false,',
    '  "extensions.ignoreRecommendations": true,',
    '  "update.showReleaseNotes": false'
  )
}
$lines += '}'
$json = ($lines -join "`n") + "`n"
$existing = if (Test-Path $settingsFile) { [IO.File]::ReadAllText($settingsFile) } else { '' }
# The file is rewritten only while it is exactly what this installer wrote
# last time (or empty); a file someone edited is left alone.
$ours = (-not $existing.Trim()) -or ($existing.Trim() -eq '{}') -or
  ($state.SettingsHash -and (Get-Sha256 $existing) -eq $state.SettingsHash)
if ($existing -eq $json) {
  Ok (M 'Settings_AlreadyOk')
} elseif ($ours) {
  [IO.File]::WriteAllText($settingsFile, $json, (New-Object Text.UTF8Encoding $false))
  $state.SettingsHash = Get-Sha256 $json
  Save-State $state
  Ok (M 'Settings_Written')
} elseif ($existing -match 'claude-ide-box-exec') {
  Ok (M 'Settings_KeptEdited')
} else {
  Warn (M 'Settings_HasOwn' $wrapper)
}

# 8. Sign in -----------------------------------------------------------------
Step 8 (M 'Step_SignIn')
$tokenFile = "/home/$LinuxUser/.config/claude-ide-box/token"
if ((Wsl-Get $LinuxUser @('test', '-s', $tokenFile)).Code -eq 0) {
  Ok (M 'SignIn_Already')
} else {
  Write-Host ''
  foreach ($k in @('SignIn_Intro', 'SignIn_Step1', 'SignIn_Step2', 'SignIn_Step3')) {
    Write-Host ('      ' + (M $k)) -ForegroundColor Yellow
  }
  Write-Host ''
  for ($i = 0; $i -lt 3; $i++) {
    & wsl.exe -d $Distro -e bash -c '$HOME/.local/bin/claude-ide-box login'
    Restore-Console
    if ((Wsl-Get $LinuxUser @('test', '-s', $tokenFile)).Code -eq 0) { break }
    Warn (M 'SignIn_Retry')
  }
  if ((Wsl-Get $LinuxUser @('test', '-s', $tokenFile)).Code -ne 0) { Fail (M 'SignIn_Failed') }
  Ok (M 'SignIn_Ok')
}

# 9. Shortcuts, check, first project -----------------------------------------
Step 9 (M 'Step_Finish')
$app = Join-Path $AppCopy 'windows\support'
$ps = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$langArg = if ($Language) { " -Language $Language" } else { '' }
$shell = New-Object -ComObject WScript.Shell
function New-Shortcut([string]$path, [string]$target, [string]$arguments, [string]$icon, [string]$desc, [int]$style) {
  $l = $shell.CreateShortcut($path)
  $l.TargetPath = $target
  if ($arguments) { $l.Arguments = $arguments }
  if ($icon) { $l.IconLocation = $icon }
  if ($style) { $l.WindowStyle = $style }
  $l.Description = $desc
  $l.Save()
}
$desk = [Environment]::GetFolderPath('Desktop')
$openArgs = "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$(Join-Path $app 'open.ps1')`"$langArg"
New-Shortcut (Join-Path $desk 'Claude.lnk') $ps $openArgs "$codeExe,0" (M 'Shortcut_Claude_Desc') 7
$projectsWin = Join-Path (Wsl-Share) "home\$LinuxUser\$ProjectsName"
New-Shortcut (Join-Path $desk "$ProjectsName Claude.lnk") $projectsWin '' '' (M 'Shortcut_Projects_Desc') 0
$menu = Join-Path ([Environment]::GetFolderPath('Programs')) 'Claude IDE Box'
New-Item -ItemType Directory -Force -Path $menu | Out-Null
New-Shortcut (Join-Path $menu 'Claude.lnk') $ps $openArgs "$codeExe,0" (M 'Shortcut_Claude_Desc') 7
New-Shortcut (Join-Path $menu ((M 'Shortcut_Settings') + '.lnk')) $ps `
  "-NoProfile -ExecutionPolicy Bypass -File `"$(Join-Path $app 'install.ps1')`" -Settings$langArg" '' (M 'Shortcut_Settings_Desc') 0
New-Shortcut (Join-Path $menu ((M 'Shortcut_Uninstall') + '.lnk')) $ps `
  "-NoProfile -ExecutionPolicy Bypass -File `"$(Join-Path $app 'install.ps1')`" -Uninstall$langArg" '' (M 'Shortcut_Uninstall') 0
Ok (M 'Shortcuts_Ready' $ProjectsName)

# The full doctor report goes to the log for IT; the person sees the verdict.
Info (M 'Check_Running')
$doc = Wsl-Get $LinuxUser @('bash', '-c', '$HOME/.local/bin/claude-ide-box doctor')
Add-Content -Path $LinuxLog -Encoding UTF8 -Value $doc.Out
$fails = @($doc.Out -split "`n" | Where-Object { $_ -match '^\[FAIL\]' })

$dd = 'C:\Program Files\Docker\Docker\Docker Desktop.exe'
if (Test-Path $dd) {
  $ddv = (Get-Item $dd).VersionInfo.ProductVersion
  try {
    if ([version]($ddv -replace '[^0-9.].*$', '') -lt [version]'4.44.3') { Warn (M 'DockerDesktop_Old' $ddv) }
  } catch { }
}

Write-Host ''
if ($doc.Code -eq 0) {
  Write-Host (M 'All_Done') -ForegroundColor Green
} else {
  Write-Host (M 'Check_Problem') -ForegroundColor Yellow
  foreach ($f in $fails) { Write-Host "  $f" -ForegroundColor Yellow }
  Write-Host (M 'Failed_SendLog' $LinuxLog)
}
if (-not $Settings) {
  Write-Host (M 'Opening_First' $FirstProject)
  Write-Host (M 'Opening_TrustHint')
  & $ps -NoProfile -ExecutionPolicy Bypass -File (Join-Path $app 'open.ps1') "$projectsWin\$FirstProject"
}
try { Stop-Transcript | Out-Null } catch { }
Pause-Close
