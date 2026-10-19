<# : Cyberbee Interface installer for Windows
@echo off
rem  ------------------------------------------------------------------------
rem  This one file is a batch + PowerShell hybrid: the batch lines below just
rem  hand the whole file to PowerShell, which skips them as a block comment.
rem  ------------------------------------------------------------------------
setlocal
set "CB_SELF=%~f0"
powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "iex ([IO.File]::ReadAllText($env:CB_SELF))"
exit /b %ERRORLEVEL%
#>

# -----------------------------------------------------------------------------
# Cyberbee Interface - Windows installer
#
# How users start it: press Windows key + R, paste this line, press Enter:
#   cmd /c curl -fsSLo "%TEMP%\cyberbee_installer.cmd" https://raw.githubusercontent.com/CyberBeeOfficial/Cyberbee_Interface_Releases/main/install_cyberbee_windows.cmd && "%TEMP%\cyberbee_installer.cmd"
# A file fetched by curl.exe carries no "downloaded from the internet" mark, so
# neither the browser's download warning nor SmartScreen gets in the way.
# Double-clicking a downloaded copy of this file works too.
#
# What it does:
#   1. asks once for administrator permission (needed for the USB-cable
#      network driver and for installing Git for Windows),
#   2. installs Git for Windows if missing - the app runs the device
#      install script ("Setup & Deploy New Device") under Git's bash/ssh/tar,
#   3. downloads the newest Windows release from GitHub, verifies its
#      checksum, and installs it to %LOCALAPPDATA%\Programs\CyberbeeInterface
#      (a user-writable folder, so the in-app updater can replace it later;
#      previous calibration results are kept),
#   4. pre-installs the RNDIS USB-network driver used by "Connect by cable"
#      (when the release contains it),
#   5. creates Start-menu and Desktop shortcuts and starts the app.
#
# Optional settings (set before running, e.g. in a Command Prompt):
#   set CB_VERSION=v3.0.3            install a specific release
#   set CB_INSTALL_DIR=D:\Apps       install into D:\Apps\CyberbeeInterface
#   set CB_FORCE=1                   reinstall even if already up to date
#
# Safe to re-run: anything already installed is skipped.
#
# Output is one line per step with a green OK; command output goes to a log,
# which is only saved (to the Desktop) when something goes wrong.
# Must stay Windows PowerShell 5.1 compatible: that is what every Windows has.
# -----------------------------------------------------------------------------

$ErrorActionPreference = 'Stop'
$ProgressPreference    = 'SilentlyContinue'
[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12

$GhOwner  = 'CyberBeeOfficial'
$GhRepo   = 'Cyberbee_Interface_Releases'
$AppName  = 'CyberbeeInterface'
$AppTitle = 'Cyberbee Interface'
$Headers  = @{ 'User-Agent' = 'CyberbeeInstaller'; 'Accept' = 'application/vnd.github+json' }

function Quote-PS([string]$s) { "'" + ($s -replace "'", "''") + "'" }
function Quote-Arg([string]$s) { '"' + $s + '"' }

$IsAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
           ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

$Host.UI.RawUI.WindowTitle = "$AppTitle installer"
Write-Host ''
Write-Host "  $AppTitle installer" -ForegroundColor White
Write-Host ''

# -- Elevation ----------------------------------------------------------------
# Capture THIS user's folders before elevating: if a different admin account
# approves the prompt, the elevated process would otherwise install the app
# into that admin's profile instead of the person who started the installer.
if ($env:CB_PHASE -ne 'elevated' -and -not $IsAdmin) {
    $vars = [ordered]@{
        CB_PHASE             = 'elevated'
        CB_SELF              = $env:CB_SELF
        CB_USER_LOCALAPPDATA = $env:LOCALAPPDATA
        CB_USER_DESKTOP      = [Environment]::GetFolderPath('Desktop')
        CB_USER_PROGRAMS     = [Environment]::GetFolderPath('Programs')
        CB_VERSION           = $env:CB_VERSION
        CB_INSTALL_DIR       = $env:CB_INSTALL_DIR
        CB_FORCE             = $env:CB_FORCE
    }
    $boot = ($vars.GetEnumerator() | ForEach-Object { "`$env:$($_.Key)=$(Quote-PS ([string]$_.Value))" }) -join '; '
    $boot += '; iex ([IO.File]::ReadAllText($env:CB_SELF))'
    $enc = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($boot))

    Write-Host '  Windows will now ask for permission to make changes - click "Yes".'
    try {
        # The installer carries on in the new (administrator) window; this one closes.
        Start-Process powershell.exe -Verb RunAs `
            -ArgumentList "-NoProfile -ExecutionPolicy Bypass -EncodedCommand $enc" | Out-Null
        exit 0
    } catch {
        Write-Host ''
        Write-Host '  Permission was not given, so nothing was installed.' -ForegroundColor Yellow
        Write-Host '  Run the installer again and click "Yes" when Windows asks.'
        Write-Host ''
        Read-Host  '  Press Enter to close'
        exit 1
    }
}

$UserLocalAppData = if ($env:CB_USER_LOCALAPPDATA) { $env:CB_USER_LOCALAPPDATA } else { $env:LOCALAPPDATA }
$UserDesktop      = if ($env:CB_USER_DESKTOP)      { $env:CB_USER_DESKTOP }      else { [Environment]::GetFolderPath('Desktop') }
$UserPrograms     = if ($env:CB_USER_PROGRAMS)     { $env:CB_USER_PROGRAMS }     else { [Environment]::GetFolderPath('Programs') }
$InstallParent    = if ($env:CB_INSTALL_DIR)       { $env:CB_INSTALL_DIR }       else { Join-Path $UserLocalAppData 'Programs' }
$InstallDir       = Join-Path $InstallParent $AppName
$Exe              = Join-Path $InstallDir "$AppName.exe"
$TmpDir           = Join-Path ([IO.Path]::GetTempPath()) ("cyberbee-install-" + [Guid]::NewGuid().ToString('N').Substring(0, 8))
$StageDir         = Join-Path $InstallParent '.cyberbee_install_tmp'
$Log              = Join-Path $TmpDir 'install.log'
$SavedLog         = Join-Path $UserDesktop 'cyberbee-install-log.txt'

# -- output -------------------------------------------------------------------
$script:Step     = ''        # label of the step on the current line
$script:FailMsg  = ''        # set by Fail(); anything else thrown is unexpected
$script:Notes    = New-Object System.Collections.Generic.List[string]
$script:SaveLog  = $false    # keep the log on the Desktop even though the install worked
$script:Shortcut = ''

function Write-Log([string]$m) { Add-Content -LiteralPath $Log -Value $m -ErrorAction SilentlyContinue }

# "Label ........" padded to a fixed width so the results line up.
function Begin-Step([string]$label) {
    $script:Step = $label
    Write-Log "`r`n=== $label"
    $s = "$label "
    while ($s.Length -lt 46) { $s += '.' }
    Write-Host -NoNewline "  $s "
}

function End-Step([string]$text, [string]$color) {
    if ($script:Step) { Write-Host $text -ForegroundColor $color; $script:Step = '' }
}

function Step-Ok { End-Step 'OK' Green }

function Add-Note([string]$m) { $script:Notes.Add($m); Write-Log "NOTE: $m" }

# A step failed and the install cannot go on; the message is shown as is.
function Fail([string]$m) { $script:FailMsg = $m; throw $m }

# Start a program hidden, with its output in the log. Arguments are one string,
# already quoted (Start-Process does not quote array items with spaces).
function Start-Hidden([string]$File, [string]$Arguments) {
    $out = Join-Path $TmpDir ([Guid]::NewGuid().ToString('N'))
    $p = Start-Process -FilePath $File -ArgumentList $Arguments -PassThru -WindowStyle Hidden `
         -RedirectStandardOutput "$out.out" -RedirectStandardError "$out.err"
    $null = $p.Handle   # without this, ExitCode stays empty after the process ends
    $p | Add-Member -NotePropertyName OutBase -NotePropertyValue $out
    return $p
}

# Wait for a Start-Hidden process, animating a spinner - or a percentage when
# a file is growing towards a known size. Returns the exit code.
function Wait-Hidden($p, [string]$File = '', [int64]$Total = 0) {
    $frames = '|', '/', '-', '\'
    $i = 0
    $w = 6
    while (-not $p.HasExited) {
        $t = $frames[$i % 4]; $i++
        if ($File -and $Total -gt 0 -and (Test-Path -LiteralPath $File)) {
            $t += ' {0}%' -f [math]::Min(100, [int](100 * (Get-Item -LiteralPath $File).Length / $Total))
        }
        Write-Host -NoNewline ($t.PadRight($w) + ("`b" * $w))
        Start-Sleep -Milliseconds 200
    }
    Write-Host -NoNewline ((' ' * $w) + ("`b" * $w))
    $p.WaitForExit()
    foreach ($f in "$($p.OutBase).out", "$($p.OutBase).err") {
        if (Test-Path -LiteralPath $f) { Get-Content -LiteralPath $f | Add-Content -LiteralPath $Log; Remove-Item -LiteralPath $f }
    }
    return $p.ExitCode
}

# Run a console program with its output in the log; returns its exit code.
# 'Continue' (local to this function): Windows PowerShell 5.1 turns any stderr
# line from a native command into an error, which 'Stop' would make fatal.
function Invoke-Logged([string]$File, [string[]]$Arguments) {
    $ErrorActionPreference = 'Continue'
    Write-Log ((& $File @Arguments 2>&1) | Out-String)
    return $LASTEXITCODE
}

function Get-File([string]$Url, [string]$OutFile, [int64]$Size = 0) {
    $curl = Join-Path $env:SystemRoot 'System32\curl.exe'
    if (Test-Path -LiteralPath $curl) {
        $p = Start-Hidden $curl "-fsSL --retry 3 --retry-delay 3 -o $(Quote-Arg $OutFile) $(Quote-Arg $Url)"
        $rc = Wait-Hidden $p $OutFile $Size
        if ($rc -eq 0) { return }
        Write-Log "curl failed (code $rc) - retrying with the built-in downloader"
    }
    # Fallback, e.g. when a company proxy breaks curl's certificate check.
    (New-Object Net.WebClient).DownloadFile($Url, $OutFile)
}

function Test-Sha256([string]$File, $Asset) {
    $digest = [string]$Asset.digest
    if (-not $digest.StartsWith('sha256:')) { return ((Get-Item -LiteralPath $File).Length -eq [int64]$Asset.size) }
    return ((Get-FileHash -LiteralPath $File -Algorithm SHA256).Hash -eq $digest.Substring(7))
}

# Same search order as the app's find_windows_bash() - Git must be found where
# the app will look for it.
function Find-GitBash {
    $c = @()
    if ($env:CYBERBEE_BASH) { $c += $env:CYBERBEE_BASH }
    foreach ($b in @($env:ProgramW6432, $env:ProgramFiles, ${env:ProgramFiles(x86)})) {
        if ($b) { $c += (Join-Path $b 'Git\bin\bash.exe') }
    }
    foreach ($l in @($UserLocalAppData, $env:LOCALAPPDATA)) {
        if ($l) { $c += (Join-Path $l 'Programs\Git\bin\bash.exe') }
    }
    foreach ($p in $c) { if ($p -and (Test-Path -LiteralPath $p)) { return $p } }
    return $null
}

function Get-Release([string]$Url, [string]$What) {
    try { return Invoke-RestMethod -UseBasicParsing -Headers $Headers $Url }
    catch {
        Write-Log "GET $Url failed: $($_.Exception.Message)"
        Fail "Could not reach GitHub to download $What.`nCheck that this computer is connected to the internet, then run the installer again."
    }
}

function Invoke-Main {
    New-Item -ItemType Directory -Force -Path $TmpDir, $InstallParent | Out-Null

    # -- 0. Pre-flight --------------------------------------------------------
    Begin-Step 'Checking this computer'
    $os = Get-CimInstance Win32_OperatingSystem
    Write-Log "System: $($os.Caption) (build $($os.BuildNumber), $env:PROCESSOR_ARCHITECTURE)"
    if (-not [Environment]::Is64BitOperatingSystem) {
        Fail "$AppTitle needs 64-bit Windows 10 or Windows 11."
    }
    if ([int]$os.BuildNumber -lt 17763) {
        Add-Note 'This Windows version is very old. If the app has problems, update Windows (Windows 10 or 11).'
    }
    if ($env:PROCESSOR_ARCHITECTURE -eq 'ARM64') {
        Add-Note 'This is an ARM computer. The app runs through Windows emulation, so it can be slower.'
    }
    Step-Ok

    # -- 1. Git for Windows ---------------------------------------------------
    $bash = Find-GitBash
    if ($bash) {
        Begin-Step 'Checking Git for Windows'
        Write-Log "Found $bash"
    } else {
        Begin-Step 'Installing Git for Windows'
        $rel = Get-Release 'https://api.github.com/repos/git-for-windows/git/releases/latest' 'Git for Windows'
        $pattern = if ($env:PROCESSOR_ARCHITECTURE -eq 'ARM64') { '^Git-[\d.]+-arm64\.exe$' } else { '^Git-[\d.]+-64-bit\.exe$' }
        $asset = $rel.assets | Where-Object { $_.name -match $pattern } | Select-Object -First 1
        if (-not $asset) { Fail "The Git for Windows download was not found.`nInstall it from https://git-scm.com/download/win and run this installer again." }
        $gitExe = Join-Path $TmpDir $asset.name
        Get-File $asset.browser_download_url $gitExe $asset.size
        if (-not (Test-Sha256 $gitExe $asset)) { Fail 'The Git for Windows download is damaged. Run the installer again.' }
        $rc = Wait-Hidden (Start-Hidden $gitExe '/VERYSILENT /NORESTART /NOCANCEL /SP- /SUPPRESSMSGBOXES /CLOSEAPPLICATIONS')
        if ($rc -ne 0) { Fail "Git for Windows could not be installed (setup code $rc).`nRestart the computer and run the installer again." }
        $bash = Find-GitBash
        if (-not $bash) { Fail "Git for Windows was installed, but its bash.exe was not found.`nInstall it from https://git-scm.com/download/win and run this installer again." }
    }
    # Git's bash must provide everything the device install script calls.
    # ('Continue': see Invoke-Logged.)
    $ErrorActionPreference = 'Continue'
    $missingTools = ((& $bash -lc 'for t in git ssh scp tar sed; do command -v $t >/dev/null 2>&1 || echo $t; done' 2>$null) -join ' ').Trim()
    $ErrorActionPreference = 'Stop'
    if ($missingTools) { Add-Note "Git for Windows is missing $missingTools, so 'Setup & Deploy' may not work. Reinstall Git for Windows with the default options." }
    Step-Ok

    # -- 2. Find the release --------------------------------------------------
    Begin-Step 'Looking for the newest version'
    $want = [string]$env:CB_VERSION
    $api = "https://api.github.com/repos/$GhOwner/$GhRepo/releases"
    if ($want) {
        if ($want -notmatch '^(v|TEST-)') { $want = "v$want" }
        $releases = @(Get-Release "$api/tags/$want" "version $want")
    } else {
        $releases = Get-Release "$api`?per_page=50" $AppTitle
    }
    # Same rule as the in-app updater: newest published release that actually
    # carries a Windows zip (not every release has both operating systems).
    $tag = $null; $asset = $null
    foreach ($r in $releases) {
        if ($r.draft) { continue }
        if ($r.prerelease -and -not $want) { continue }
        $a = $r.assets | Where-Object { $_.name -match 'windows' -and $_.name -like '*.zip' } | Select-Object -First 1
        if ($a) { $tag = $r.tag_name; $asset = $a; break }
    }
    if (-not $asset) { Fail "No Windows version of $AppTitle was found on GitHub$(if ($want) { " for $want" })." }
    $newVersion = $tag -replace '^v', ''
    Write-Log "Release $tag : $($asset.browser_download_url) ($($asset.size) bytes)"
    $versionFile = Join-Path $InstallDir '_internal\calibration_automation\version.txt'
    $oldVersion = if (Test-Path -LiteralPath $versionFile) { ([string](Get-Content -LiteralPath $versionFile -Raw)).Trim() } else { '' }
    Step-Ok

    # -- 3. Download + install ------------------------------------------------
    if ($oldVersion -and $oldVersion -eq $newVersion -and $env:CB_FORCE -ne '1') {
        Begin-Step "$AppTitle $newVersion already installed"
        Step-Ok
    } else {
        while (Get-Process -Name $AppName -ErrorAction SilentlyContinue |
               Where-Object { $_.Path -and $_.Path.StartsWith($InstallDir, [StringComparison]::OrdinalIgnoreCase) }) {
            Write-Host "  $AppTitle is open. Close it, then press Enter to continue." -ForegroundColor Yellow
            Read-Host | Out-Null
        }

        Begin-Step "Downloading $AppTitle $newVersion"
        $zip = Join-Path $TmpDir $asset.name
        Get-File $asset.browser_download_url $zip $asset.size
        if (-not (Test-Sha256 $zip $asset)) { Fail 'The download is damaged. Run the installer again to download it again.' }
        Step-Ok

        Begin-Step "Installing $AppTitle $newVersion"
        if (Test-Path -LiteralPath $StageDir) { Remove-Item -LiteralPath $StageDir -Recurse -Force }
        # Unzip in a separate process so the spinner keeps moving (it takes a while).
        $unzip = "Add-Type -AssemblyName System.IO.Compression.FileSystem; " +
                 "[IO.Compression.ZipFile]::ExtractToDirectory($(Quote-PS $zip), $(Quote-PS $StageDir))"
        $enc = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($unzip))
        $rc = Wait-Hidden (Start-Hidden 'powershell.exe' "-NoProfile -EncodedCommand $enc")
        if ($rc -ne 0) { Fail "The download could not be unpacked.`nCheck that there is at least 1 GB of free disk space and run the installer again." }
        $newDir = Join-Path $StageDir $AppName
        if (-not (Test-Path -LiteralPath (Join-Path $newDir "$AppName.exe"))) {
            Fail "The download does not contain $AppName.exe. Please tell Cyberbee support."
        }

        $backup = $null
        if (Test-Path -LiteralPath $InstallDir) {
            # The user's own data lives INSIDE the install folder: calibration
            # results and bags, plus any boards/profiles/intrinsics they added.
            # Carry it across before the old copy is retired. /XC /XN /XO skip
            # files that exist in both: files shipped with the new version win.
            foreach ($keep in 'results', 'bags', 'config\boards', 'config\profiles', 'config\intrinsics') {
                $src = Join-Path $InstallDir "_internal\calibration_automation\$keep"
                $dst = Join-Path $newDir     "_internal\calibration_automation\$keep"
                if (-not (Test-Path -LiteralPath $src)) { continue }
                $rc = Invoke-Logged robocopy.exe @($src, $dst, '/E', '/XC', '/XN', '/XO', '/R:1', '/W:1', '/NP', '/NFL', '/NDL', '/NJH', '/NJS')
                if ($rc -ge 8) {   # robocopy: 0-7 = success
                    Fail "Your previous calibration files ($keep) could not be copied to the new version, so nothing was changed.`nFree some disk space and run the installer again."
                }
                Write-Log "Kept previous $keep"
            }
            # "<name>.old-<stamp>" is the in-app updater's backup pattern, so the
            # app deletes this backup by itself on its next start.
            $backup = "$InstallDir.old-$(Get-Date -Format yyyyMMddHHmmss)"
            $moved = $false
            for ($i = 0; $i -lt 10 -and -not $moved; $i++) {
                try { Move-Item -LiteralPath $InstallDir -Destination $backup; $moved = $true }
                catch { Start-Sleep -Seconds 2 }   # OneDrive / antivirus can hold files briefly
            }
            if (-not $moved) { Fail "The old version could not be replaced because one of its files is in use.`nClose $AppTitle (and any File Explorer window showing its folder), then run the installer again." }
            Write-Log "Previous version $oldVersion moved to $backup"
        }
        try {
            Move-Item -LiteralPath $newDir -Destination $InstallDir
        } catch {
            Write-Log $_.Exception.Message
            if ($backup) { Move-Item -LiteralPath $backup -Destination $InstallDir }
            Fail 'The new version could not be put in place; your previous version was restored.'
        }
        Remove-Item -LiteralPath $StageDir -Recurse -Force -ErrorAction SilentlyContinue
        Step-Ok
    }

    # -- 4. USB-cable network driver ------------------------------------------
    # Bundled at _internal\app\core\windows\driver (builds newer than 3.0.3).
    $infs = @(Get-ChildItem -LiteralPath $InstallDir -Recurse -Filter '*.inf' -ErrorAction SilentlyContinue |
              Where-Object { $_.FullName -match '\\driver\\' })
    if ($infs.Count -eq 0) {
        Write-Log 'This release does not include the USB-cable (RNDIS) driver.'
    } else {
        Begin-Step 'Installing the USB cable driver'
        $driverOk = $true
        foreach ($inf in $infs) {
            $rc = Invoke-Logged pnputil.exe @('/add-driver', $inf.FullName, '/install')
            # 0 = installed, 259 = nothing to update, 3010 = reboot required
            if ($rc -eq 3010) { Add-Note 'Restart Windows before using "Connect by cable".' }
            elseif ($rc -notin 0, 259) { $driverOk = $false; $script:SaveLog = $true; Write-Log "pnputil code $rc for $($inf.Name)" }
        }
        if ($driverOk) { Step-Ok }
        else {
            End-Step 'FAILED' Red
            Add-Note '"Connect by cable" may not work because its driver could not be installed. Wi-Fi is not affected. Please send cyberbee-install-log.txt (on your Desktop) to Cyberbee support.'
        }
    }

    # -- 5. Shortcuts ---------------------------------------------------------
    Begin-Step "Adding $AppTitle to your computer"
    $ws = New-Object -ComObject WScript.Shell
    $script:Shortcut = Join-Path $UserDesktop "$AppTitle.lnk"
    foreach ($lnk in @((Join-Path $UserPrograms "$AppTitle.lnk"), $script:Shortcut)) {
        $s = $ws.CreateShortcut($lnk)
        $s.TargetPath       = $Exe
        $s.WorkingDirectory = $InstallDir
        $s.IconLocation     = "$Exe,0"
        $s.Description      = 'Cyberbee drone ground-station interface'
        $s.Save()
    }
    Step-Ok
}

# -- run ----------------------------------------------------------------------
$ok = $false
try {
    Invoke-Main
    $ok = $true
} catch {
    Write-Log "ERROR: $($_.Exception.Message)`r`n$($_.ScriptStackTrace)"
    End-Step 'FAILED' Red
    $msg = if ($script:FailMsg) { $script:FailMsg } else {
        "Something unexpected went wrong:`n$($_.Exception.Message)`nRun the installer again; it continues where it stopped."
    }
    Write-Host ''
    Write-Host '  The installation could not finish.' -ForegroundColor Red
    Write-Host ''
    foreach ($line in $msg -split "`n") { Write-Host "  $line" }
}

$saved = $false
if (-not $ok -or $script:SaveLog) {
    try { Copy-Item -LiteralPath $Log -Destination $SavedLog -Force; $saved = $true } catch { }
}

if ($ok) {
    Write-Host ''
    Write-Host "  Done! $AppTitle is installed." -ForegroundColor Green
    # Through Explorer, so the app runs as the normal user - not as administrator
    # like this window (and as the right person, if another admin clicked "Yes").
    try { Start-Process explorer.exe -ArgumentList (Quote-Arg $script:Shortcut); Write-Host '  Starting it now...' } catch { }
    Write-Host ''
    Write-Host "  Next time, double-click `"$AppTitle`" on your Desktop."
    Write-Host '  To use "Connect by cable", right-click it and choose "Run as administrator".'
    if ($script:Notes.Count -gt 0) {
        Write-Host ''
        Write-Host '  Please note:' -ForegroundColor Yellow
        foreach ($n in $script:Notes) { Write-Host "    - $n" }
    }
} elseif ($saved) {
    Write-Host ''
    Write-Host "  Details were saved to cyberbee-install-log.txt on your Desktop."
    Write-Host '  If this keeps happening, send that file to Cyberbee support.'
}

Remove-Item -LiteralPath $TmpDir -Recurse -Force -ErrorAction SilentlyContinue
Remove-Item -LiteralPath $StageDir -Recurse -Force -ErrorAction SilentlyContinue
Write-Host ''
if ($ok -and $script:Notes.Count -eq 0) {
    # Nothing left to read: close by itself.
    Write-Host '  This window closes in 15 seconds.'
    Start-Sleep -Seconds 15
} else {
    Read-Host '  Press Enter to close'
}
if ($ok) { exit 0 } else { exit 1 }
