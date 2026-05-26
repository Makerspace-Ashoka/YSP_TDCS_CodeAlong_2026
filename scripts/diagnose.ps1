# YSP TDCS Makerspace — diagnostic script (Windows).
#
# READ-ONLY. This script must never install, repair, sync, rename .git,
# change registry/Defender settings, or modify the system. It only reports
# what setup would need to fix. Check predicates are deliberately copied
# from setup.ps1 — diagnose must run even when setup.ps1 is broken.

[CmdletBinding()]
param()

$ErrorActionPreference = 'Continue'   # we want individual check failures, not aborts
Set-StrictMode -Version Latest

# =============================================================================
#  CONFIG  —  mirrors setup.ps1. Read-only fields only.
# =============================================================================

$Script:Version        = '2026.05.0'
$Script:RepoUrl        = 'https://github.com/Makerspace-Ashoka/YSP_TDCS_CodeAlong_2026.git'
$Script:PythonVersion  = '3.11'
$Script:PioBoard       = 'seeed_xiao_esp32c3'
$Script:PioFramework   = 'arduino'
$Script:PioPlatformPin = 'platformio/espressif32@7.0.1'

$Script:MinDiskGbHard            = 5
$Script:MinVscodeVersionMajor    = 1
$Script:MinVscodeVersionMinor    = 90
$Script:MaxClockSkewSec          = 300

$Script:InstructorPaths = @('robot_core','platformio.ini','.python-version',
                            'requirements.txt','QUICKSTART.md','.vscode',
                            'ronnie-robot.code-workspace')
$Script:ExpectedLibs = @('Adafruit PWM Servo Driver Library','Adafruit BusIO',
                         'NewPing','ArduinoJson','ESP32Servo','Adafruit NeoPixel')
$Script:VscodeExts = @('platformio.platformio-ide','ms-vscode.cpptools',
                       'ms-vscode.vscode-serial-monitor')

$Script:StateDir      = Join-Path $HOME '.tdsc_makerspace_setup'
$Script:UpstreamDir   = Join-Path $Script:StateDir 'upstream'
$Script:Workspace     = Join-Path $HOME 'YSP_TDCS_Makerspace'
$Script:StudentCodeDir= Join-Path $Script:Workspace 'my_robot_code'
$Script:DiagState     = Join-Path $Script:Workspace '.tdcs_setup_state.json'
$Script:VenvDir       = Join-Path $Script:Workspace '.venv'
$Script:PioBin        = Join-Path $Script:VenvDir   'Scripts\pio.exe'
$Script:PythonBin     = Join-Path $Script:VenvDir   'Scripts\python.exe'

$Script:Total   = 0
$Script:Failed  = 0

# =============================================================================
#  CONSOLE
# =============================================================================

$useColor = -not $env:NO_COLOR -and [Environment]::UserInteractive

function Banner {
    Write-Host '━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━' -ForegroundColor Magenta
    Write-Host "  YSP Diagnostics — $($Script:Version)"
    Write-Host '━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━' -ForegroundColor Magenta
}

function Report {
    param([string]$Label, [bool]$Pass, [string]$Detail = '')
    $Script:Total++
    $mark = if ($Pass) { '✓' } else { $Script:Failed++; '✗' }
    $color = if ($Pass) { 'Green' } else { 'Red' }
    $lbl = $Label.PadRight(28)
    if ($useColor) {
        Write-Host -NoNewline "  $lbl "
        Write-Host -NoNewline $mark -ForegroundColor $color
        Write-Host "  $Detail"
    } else {
        Write-Host "  $lbl $mark  $Detail"
    }
}

# =============================================================================
#  CHECKS — return @{ pass = $true/$false; detail = '...' }
# =============================================================================

function Check-OS {
    $arch = $env:PROCESSOR_ARCHITECTURE
    @{ pass = $true; detail = "Windows $arch" }
}

function Check-DiskSpace {
    $free = (Get-PSDrive ($HOME.Substring(0,1))).Free
    $gb = [math]::Floor($free / 1GB)
    @{ pass = ($gb -ge $Script:MinDiskGbHard); detail = "$gb GB free" }
}

function Check-Clock {
    try {
        $resp = Invoke-WebRequest -Uri 'https://github.com' -Method Head -UseBasicParsing -TimeoutSec 5
        $remote = [DateTime]::Parse($resp.Headers['Date']).ToUniversalTime()
        $skew = [int][math]::Abs(((Get-Date).ToUniversalTime() - $remote).TotalSeconds)
        return @{ pass = ($skew -le $Script:MaxClockSkewSec); detail = "within ${skew}s" }
    } catch { return @{ pass = $false; detail = 'cannot reach github.com' } }
}

function Check-Https {
    try { Invoke-WebRequest 'https://github.com' -Method Head -UseBasicParsing -TimeoutSec 5 | Out-Null
          return @{ pass = $true; detail = '' } }
    catch { return @{ pass = $false; detail = 'network blocking HTTPS — try a different network' } }
}

function Check-Mirror {
    try { Invoke-WebRequest 'http://ysp-mirror.local:8080/ping' -UseBasicParsing -TimeoutSec 2 | Out-Null
          return @{ pass = $true; detail = 'http://ysp-mirror.local:8080' } }
    catch { return @{ pass = $true; detail = '(none — using internet)' } }
}

function Check-Workspace {
    $ok = (Test-Path $Script:Workspace) -and (Test-Path $Script:StudentCodeDir) -and
          [bool](Get-ChildItem -Path $Script:StudentCodeDir -File -Force -ErrorAction SilentlyContinue)
    @{ pass = $ok; detail = if ($ok) { $Script:Workspace } else { 'my_robot_code\ missing or empty — run setup' } }
}

function Check-WorkspaceGitDisabled {
    $present = Test-Path (Join-Path $Script:Workspace '.git')
    @{ pass = (-not $present); detail = if ($present) { '.git exists — run setup again' } else { '' } }
}

function Check-Upstream {
    if (-not (Test-Path (Join-Path $Script:UpstreamDir '.git'))) {
        return @{ pass = $false; detail = 'missing — run setup' }
    }
    $remote = & git -C $Script:UpstreamDir remote get-url origin 2>$null
    if ($remote -eq $Script:RepoUrl) {
        return @{ pass = $true; detail = "origin → Makerspace-Ashoka/YSP_TDCS_CodeAlong_2026" }
    }
    @{ pass = $false; detail = "wrong remote ($remote) — run setup" }
}

function Check-ContentSync {
    # Read-only — uses last fetch performed by setup.ps1. No fetch here.
    if (-not (Test-Path (Join-Path $Script:UpstreamDir '.git'))) {
        return @{ pass = $false; detail = 'no upstream cache' }
    }
    $local  = & git -C $Script:UpstreamDir rev-parse HEAD 2>$null
    $remote = & git -C $Script:UpstreamDir rev-parse origin/main 2>$null
    if ($local -and $remote -and $local -eq $remote) {
        return @{ pass = $true; detail = 'up to date with main' }
    }
    @{ pass = $false; detail = 'behind main — run setup again' }
}

function Check-RequiredClassFiles {
    foreach ($p in $Script:InstructorPaths) {
        if (-not (Test-Path (Join-Path $Script:Workspace $p))) {
            return @{ pass = $false; detail = "missing $p — run setup" }
        }
    }
    @{ pass = $true; detail = '' }
}

function Check-VsCode {
    $cmd = Get-Command code -ErrorAction SilentlyContinue
    if (-not $cmd) { return @{ pass = $false; detail = 'not installed' } }
    $v = (& code --version 2>$null | Select-Object -First 1)
    if ($v -notmatch '^(\d+)\.(\d+)') { return @{ pass = $false; detail = 'cannot parse version' } }
    $major = [int]$matches[1]; $minor = [int]$matches[2]
    $ok = $major -gt $Script:MinVscodeVersionMajor -or
          ($major -eq $Script:MinVscodeVersionMajor -and $minor -ge $Script:MinVscodeVersionMinor)
    @{ pass = $ok; detail = $v }
}

function Check-Extension {
    param([string]$Ext)
    if (-not (Get-Command code -ErrorAction SilentlyContinue)) {
        return @{ pass = $false; detail = 'code CLI missing' }
    }
    $installed = (& code --list-extensions 2>$null) | ForEach-Object { $_.ToLower() }
    if ($installed -contains $Ext.ToLower()) {
        return @{ pass = $true; detail = '' }
    }
    @{ pass = $false; detail = 'missing — run setup' }
}

function Check-Uv {
    $cmd = Get-Command uv -ErrorAction SilentlyContinue
    if (-not $cmd) { return @{ pass = $false; detail = 'missing — run setup' } }
    $v = (& uv --version 2>$null) -join ''
    @{ pass = $true; detail = ($v -replace '^uv\s*','') }
}

function Check-Python {
    if (-not (Test-Path $Script:PythonBin)) {
        return @{ pass = $false; detail = '.venv missing — run setup' }
    }
    $v = (& $Script:PythonBin --version 2>$null) -join ''
    if ($v -match "Python $([regex]::Escape($Script:PythonVersion))\.") {
        return @{ pass = $true; detail = ($v -replace '^Python\s*','') }
    }
    @{ pass = $false; detail = "wrong version: $v" }
}

function Check-Pio {
    if (-not (Test-Path $Script:PioBin)) { return @{ pass = $false; detail = 'not in .venv' } }
    $v = (& $Script:PioBin --version 2>$null) -join ''
    @{ pass = $true; detail = ($v -split ' ')[-1] }
}

function Check-Esp32 {
    if (-not (Test-Path $Script:PioBin)) { return @{ pass = $false; detail = 'pio missing' } }
    $list = & $Script:PioBin platform list --json-output 2>$null
    if ($list -and (($list -join '') -match [regex]::Escape($Script:PioPlatformPin))) {
        return @{ pass = $true; detail = 'pinned version installed' }
    }
    @{ pass = $false; detail = 'missing or wrong version — run setup' }
}

function Check-BoardConfig {
    $pio = Join-Path $Script:Workspace 'platformio.ini'
    if (-not (Test-Path $pio)) { return @{ pass = $false; detail = 'platformio.ini missing' } }
    $content = Get-Content $pio -Raw
    $ok = $content.Contains("board = $($Script:PioBoard)") -and
          $content.Contains("framework = $($Script:PioFramework)") -and
          ($content -match '(?m)^src_dir = my_robot_code') -and
          ($content -match '(?m)^lib_extra_dirs = robot_core')
    @{ pass = $ok; detail = "$($Script:PioBoard) / $($Script:PioFramework)" }
}

function Check-Libraries {
    $libdeps = Join-Path $Script:Workspace '.pio\libdeps'
    if (-not (Test-Path $libdeps)) { return @{ pass = $false; detail = '0/5 present — run setup' } }
    $present = 0
    foreach ($lib in $Script:ExpectedLibs) {
        $pat = ($lib -split ' ')[0]
        $found = Get-ChildItem -Path $libdeps -Directory -Recurse -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -like "*$pat*" }
        if ($found) { $present++ }
    }
    @{ pass = ($present -eq $Script:ExpectedLibs.Count); detail = "$present/$($Script:ExpectedLibs.Count) present" }
}

function Check-XiaoPort {
    $ports = Get-CimInstance -ClassName Win32_PnPEntity -ErrorAction SilentlyContinue |
        Where-Object { $_.Caption -match '\((COM\d+)\)' -and
                       ($_.Caption -match 'USB Serial' -or $_.Caption -match 'Espressif' -or
                        $_.Caption -match 'XIAO' -or $_.Caption -match 'CDC') }
    if ($ports) {
        $port = ([regex]::Match($ports[0].Caption, 'COM\d+')).Value
        return @{ pass = $true; detail = $port }
    }
    @{ pass = $false; detail = 'no board detected — try a DATA USB-C cable' }
}

function Check-LastSmoke {
    if (-not (Test-Path $Script:DiagState)) {
        return @{ pass = $false; detail = 'never run — run setup' }
    }
    $j = Get-Content $Script:DiagState -Raw | ConvertFrom-Json
    if ($j.last_smoke_test.passed) {
        return @{ pass = $true; detail = "passed $($j.last_smoke_test.timestamp)" }
    }
    @{ pass = $false; detail = 'previous compile failed — run setup again' }
}

# =============================================================================
#  MAIN
# =============================================================================

Banner

$r = Check-OS                 ; Report 'OS / architecture'       $r.pass $r.detail
$r = Check-DiskSpace          ; Report 'Disk space'              $r.pass $r.detail
$r = Check-Clock              ; Report 'Clock accuracy'          $r.pass $r.detail
$r = Check-Https              ; Report 'GitHub HTTPS'            $r.pass $r.detail
$r = Check-Mirror             ; Report 'Local mirror'            $r.pass $r.detail
Write-Host ''
$r = Check-Workspace          ; Report 'Student workspace'       $r.pass $r.detail
$r = Check-WorkspaceGitDisabled; Report 'Workspace git disabled'  $r.pass $r.detail
$r = Check-Upstream           ; Report 'Hidden content cache'    $r.pass $r.detail
$r = Check-ContentSync        ; Report 'Content sync status'     $r.pass $r.detail
$r = Check-RequiredClassFiles ; Report 'Required class files'    $r.pass $r.detail
Write-Host ''
$r = Check-VsCode             ; Report 'VS Code'                 $r.pass $r.detail
foreach ($ext in $Script:VscodeExts) {
    $r = Check-Extension $ext
    Report "ext: $ext" $r.pass $r.detail
}
Write-Host ''
$r = Check-Uv                 ; Report 'uv'                      $r.pass $r.detail
$r = Check-Python             ; Report 'Python 3.11'             $r.pass $r.detail
$r = Check-Pio                ; Report 'PlatformIO'              $r.pass $r.detail
$r = Check-Esp32              ; Report 'Espressif32 platform'    $r.pass $r.detail
$r = Check-BoardConfig        ; Report 'Board config'            $r.pass $r.detail
$r = Check-Libraries          ; Report 'Libraries'               $r.pass $r.detail
Write-Host ''
$r = Check-XiaoPort           ; Report 'XIAO USB port'           $r.pass $r.detail
$r = Check-LastSmoke          ; Report 'Last smoke test'         $r.pass $r.detail

Write-Host ''
Write-Host '━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━' -ForegroundColor Magenta
if ($Script:Failed -eq 0) {
    Write-Host "  All systems go. ($($Script:Total) checks)" -ForegroundColor Green
    Write-Host '━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━' -ForegroundColor Magenta
    exit 0
} else {
    Write-Host "  $($Script:Failed) failing of $($Script:Total) checks." -ForegroundColor Red
    Write-Host '  Run setup again, or show this screen to an instructor.'
    Write-Host '━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━' -ForegroundColor Magenta
    exit 1
}
