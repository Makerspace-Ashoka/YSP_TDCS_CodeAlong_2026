# YSP TDCS Makerspace — Windows setup script.
# Students run this every day. First run installs everything; subsequent runs
# sync content, health-check, and open VS Code. Same command, both modes.
#
# Spec: setup_script_spec.md  (source of truth — read it before editing)

[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

# =============================================================================
#  CONFIG  —  every hard-coded value the script needs lives here, and nowhere
#  else. Derived paths follow immediately. No install / sync / repair logic is
#  allowed above this block, except for the strict-mode settings above and the
#  elevation check (which reads from this block).
# =============================================================================

$Script:Version        = '2026.05.0'

$Script:RepoUrl        = 'https://github.com/Makerspace-Ashoka/YSP_TDCS_CodeAlong_2026.git'
$Script:RepoBranch     = 'main'
$Script:SetupShUrl     = 'https://raw.githubusercontent.com/Makerspace-Ashoka/YSP_TDCS_CodeAlong_2026/main/scripts/setup.sh'
$Script:SetupPs1Url    = 'https://raw.githubusercontent.com/Makerspace-Ashoka/YSP_TDCS_CodeAlong_2026/main/scripts/setup.ps1'

$Script:PythonVersion  = '3.11'
$Script:PioBoard       = 'seeed_xiao_esp32c3'
$Script:PioFramework   = 'arduino'
$Script:PioPlatformPin = 'platformio/espressif32@7.0.1'
$Script:UploadSpeed    = 460800
$Script:MonitorSpeed   = 115200

$Script:MinDiskGbHard           = 2
$Script:MinDiskGbWarn           = 4
$Script:MaxClockSkewSec         = 300
$Script:MinVscodeVersionMajor   = 1
$Script:MinVscodeVersionMinor   = 90

# Instructor-owned paths — mirrored from upstream into workspace on every sync.
# Edited copies are rescued to _rescued/<timestamp>/ before being restored.
$Script:InstructorPaths = @(
    'robot_core',
    'platformio.ini',
    '.python-version',
    'requirements.txt',
    'QUICKSTART.md',
    '.vscode'
)

# Student-owned paths — NEVER overwritten by sync.
$Script:StudentPaths = @(
    'my_robot_code',
    '.pio',
    '.pio-core',
    '.venv',
    '_rescued',
    'setup_log.txt',
    '.tdcs_setup_state.json'
)

$Script:ExpectedLibs = @(
    'Adafruit PWM Servo Driver Library',
    'Adafruit BusIO',
    'NewPing',
    'ArduinoJson',
    'ESP32Servo',
    'Adafruit NeoPixel'
)

$Script:VscodeExts = @(
    'platformio.platformio-ide',
    'ms-vscode.cpptools-extension-pack',
    'ms-vscode.vscode-serial-monitor'
)

# Hidden script-owned state.
$Script:StateDir       = Join-Path $HOME '.tdsc_makerspace_setup'
$Script:UpstreamDir    = Join-Path $Script:StateDir 'upstream'
$Script:SmokeDir       = Join-Path $Script:StateDir 'smoke\xiao_esp32c3'
$Script:BootstrapLog   = Join-Path $Script:StateDir 'setup_bootstrap.log'
$Script:MirrorCache    = Join-Path $Script:StateDir 'mirror_cache'
$Script:MirrorManifest = Join-Path $Script:MirrorCache 'manifest.json'

# Student-facing workspace — on the Desktop so students can find it easily.
$_desktop                = [System.Environment]::GetFolderPath('Desktop')
if (-not $_desktop) { $_desktop = Join-Path $HOME 'Desktop' }
$Script:Workspace        = Join-Path $_desktop 'YSP_TDCS_Makerspace'
$Script:WorkspaceLog     = Join-Path $Script:Workspace 'setup_log.txt'
$Script:DiagState        = Join-Path $Script:Workspace '.tdcs_setup_state.json'
$Script:RescueDir        = Join-Path $Script:Workspace '_rescued'
$Script:StudentCodeDir   = Join-Path $Script:Workspace 'my_robot_code'
$Script:VenvDir          = Join-Path $Script:Workspace '.venv'
$Script:PioBin           = Join-Path $Script:VenvDir   'Scripts\pio.exe'
$Script:PythonBin        = Join-Path $Script:VenvDir   'Scripts\python.exe'

# RescueTs is set on first rescue per run so all rescued files group together.
$Script:RescueTs         = $null

# Mirror.
$Script:MirrorHost     = 'ysp-mirror.local'
$Script:MirrorPort     = 8080
$Script:MirrorBase     = $env:TDCS_MIRROR

# Runtime state.
$Script:Mode           = $null
$Script:CountOk        = 0
$Script:CountSkip      = 0
$Script:CountRepair    = 0
$Script:CountFail      = 0
$Script:FailedSteps    = @()
$Script:UseColor       = $false
$Script:CurrentLog     = $null
$Script:CurrentPhase   = $null
$Script:PhaseStart     = $null

# =============================================================================
#  CONSOLE HELPERS  —  color, banner, status lines, spinner.
# =============================================================================

function Test-ColorSupport {
    if ($env:NO_COLOR) { return $false }
    if (-not [Environment]::UserInteractive) { return $false }
    try { $null = $Host.UI.RawUI.ForegroundColor; return $true } catch { return $false }
}

function Initialize-Console {
    $Script:UseColor = Test-ColorSupport
    Show-Banner
}

function Show-Banner {
    $banner = @'
 ___  ___      _                                              __   __        __   _____________
|  \/  |     | |                                             \ \ / /        \ \ / /  ___| ___ \
| .  . | __ _| | _____ _ __ ___ _ __   __ _  ___ ___    ______\ V /______    \ V /\ `--.| |_/ /
| |\/| |/ _` | |/ / _ \ '__/ __| '_ \ / _` |/ __/ _ \  |______/   \______|    \ /  `--. \  __/
| |  | | (_| |   <  __/ |  \__ \ |_) | (_| | (_|  __/        / /^\ \          | | /\__/ / |
\_|  |_/\__,_|_|\_\___|_|  |___/ .__/ \__,_|\___\___|        \/   \/          \_/ \____/\_|
                               | |
                               |_|
'@
    if ($Script:UseColor) {
        Write-Host $banner -ForegroundColor Magenta
        Write-Host ("Ashoka Makerspace · Young Scholars Programme · Robotics setup {0}`n" -f $Script:Version) -ForegroundColor Yellow
    } else {
        Write-Host $banner
        Write-Host ("Ashoka Makerspace · Young Scholars Programme · Robotics setup {0}`n" -f $Script:Version)
    }
}

function Write-Status {
    param(
        [Parameter(Mandatory)][string]$Tag,
        [Parameter(Mandatory, ValueFromRemainingArguments)][string[]]$Message
    )
    $text = ($Message -join ' ')
    $color = switch ($Tag) {
        'OK'      { $Script:CountOk++;     'Green' }
        'SKIP'    { $Script:CountSkip++;   'DarkGray' }
        'INFO'    { 'Cyan' }
        'CHECK'   { 'Cyan' }
        'SYNC'    { 'Cyan' }
        'INSTALL' { 'Cyan' }
        'SMOKE'   { 'Cyan' }
        'WARN'    { 'Yellow' }
        'REPAIR'  { $Script:CountRepair++; 'Yellow' }
        'FAIL'    { $Script:CountFail++; $Script:FailedSteps += $text; 'Red' }
        default   { 'Gray' }
    }
    if ($Script:UseColor) {
        Write-Host -NoNewline "[$Tag] " -ForegroundColor $color
        Write-Host $text
    } else {
        Write-Host "[$Tag] $text"
    }
    Write-Log "[$Tag] $text"
}

# Braille spinner frames — smooth 10-frame cycle. Falls back to ascii when no color.
$Script:SpinFrames     = @('⠋','⠙','⠹','⠸','⠼','⠴','⠦','⠧','⠇','⠏')
$Script:SpinFramesAsc  = @('-','\','|','/')
function Get-SpinFrame {
    param([int]$Tick)
    if ($Script:UseColor) {
        return $Script:SpinFrames[$Tick % $Script:SpinFrames.Count]
    }
    return $Script:SpinFramesAsc[$Tick % $Script:SpinFramesAsc.Count]
}

# Width to clear when overwriting a progress line in place.
$Script:ProgressClearWidth = 110

function Clear-ProgressLine {
    Write-Host ("`r" + (' ' * $Script:ProgressClearWidth) + "`r") -NoNewline
}

function Write-Phase {
    param(
        [Parameter(Mandatory)][string]$Title,
        [int]$Step = 0,
        [int]$Total = 0
    )
    if ($Script:CurrentPhase) { Stop-Phase }
    $displayTitle = if ($Step -gt 0 -and $Total -gt 0) {
        "Step $Step/$Total · $Title"
    } else {
        $Title
    }
    $Script:CurrentPhase = $displayTitle
    $Script:PhaseStart   = Get-Date
    Write-Host ''
    if ($Script:UseColor) {
        Write-Host ('┌─ ') -ForegroundColor Magenta -NoNewline
        if ($Step -gt 0 -and $Total -gt 0) {
            Write-Host ("Step $Step/$Total") -ForegroundColor Yellow   -NoNewline
            Write-Host ' · '                 -ForegroundColor DarkGray -NoNewline
            Write-Host $Title                -ForegroundColor White
        } else {
            Write-Host $Title -ForegroundColor White
        }
    } else {
        Write-Host "== $displayTitle =="
    }
    Write-Log "=== PHASE START: $displayTitle ==="
}

function Stop-Phase {
    if (-not $Script:CurrentPhase) { return }
    $elapsed = [int]((Get-Date) - $Script:PhaseStart).TotalSeconds
    if ($Script:UseColor) {
        Write-Host ('└─ ') -ForegroundColor Magenta -NoNewline
        Write-Host ("{0} · {1}s" -f $Script:CurrentPhase, $elapsed) -ForegroundColor DarkGray
    } else {
        Write-Host ("-- $($Script:CurrentPhase) · ${elapsed}s --")
    }
    Write-Log "=== PHASE END: $Script:CurrentPhase elapsed=${elapsed}s ==="
    $Script:CurrentPhase = $null
}

# =============================================================================
#  LOGGING
# =============================================================================

function Write-Log {
    param([string]$Line)
    if (-not $Script:CurrentLog) { return }
    $stamp = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
    Add-Content -Path $Script:CurrentLog -Value "$stamp $Line" -Encoding utf8
}

function Start-SetupLog {
    if (-not (Test-Path $Script:StateDir)) {
        New-Item -ItemType Directory -Path $Script:StateDir -Force | Out-Null
    }
    if (-not (Test-Path $Script:BootstrapLog)) {
        New-Item -ItemType File -Path $Script:BootstrapLog -Force | Out-Null
    }
    $Script:CurrentLog = $Script:BootstrapLog
    $hostInfo = "$([System.Environment]::OSVersion.VersionString) $($env:PROCESSOR_ARCHITECTURE)"
    Write-Log "=== Run: $((Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')) (mode=pending) script=$($Script:Version) host=$hostInfo user=$($env:USERNAME) ==="
}

function Promote-LogToWorkspace {
    if (-not (Test-Path $Script:Workspace)) { return }
    if ($Script:CurrentLog -eq $Script:WorkspaceLog) { return }
    if (-not (Test-Path $Script:WorkspaceLog)) {
        New-Item -ItemType File -Path $Script:WorkspaceLog -Force | Out-Null
    }
    if ((Test-Path $Script:BootstrapLog) -and ((Get-Item $Script:BootstrapLog).Length -gt 0)) {
        Get-Content $Script:BootstrapLog | Add-Content -Path $Script:WorkspaceLog -Encoding utf8
    }
    $Script:CurrentLog = $Script:WorkspaceLog
    Write-Log '=== Log promoted to workspace ==='
}

# =============================================================================
#  COMMAND HELPERS
# =============================================================================

function ConvertTo-Redacted {
    param([string]$Text)
    $patterns = @(
        '(?i)(token|password|passwd|secret|api[_-]?key|authorization)=\S+',
        '(?i)(--token|--password|--secret|--api-key)\s+\S+'
    )
    foreach ($p in $patterns) { $Text = [regex]::Replace($Text, $p, '$1=***') }
    $Text
}

function Invoke-LoggedCommand {
    param(
        [Parameter(Mandatory)][string]$Label,
        [Parameter(Mandatory)][string]$Command,
        [string[]]$ArgumentList = @(),
        [string]$WorkingDir = $null
    )
    $sanitized = ConvertTo-Redacted "$Command $($ArgumentList -join ' ')"
    Write-Log "+ $Label`: $sanitized"
    $start = Get-Date
    $rc = 0
    $tmpOut = New-TemporaryFile
    $tmpErr = New-TemporaryFile
    try {
        $params = @{
            FilePath               = $Command
            ArgumentList           = $ArgumentList
            NoNewWindow            = $true
            Wait                   = $true
            PassThru               = $true
            RedirectStandardOutput = $tmpOut
            RedirectStandardError  = $tmpErr
        }
        if ($WorkingDir) { $params.WorkingDirectory = $WorkingDir }
        $proc = Start-Process @params
        $rc = $proc.ExitCode
        Get-Content $tmpOut, $tmpErr -ErrorAction SilentlyContinue | Add-Content -Path $Script:CurrentLog -Encoding utf8
    } catch {
        $rc = 1
        Add-Content -Path $Script:CurrentLog -Value "EXCEPTION: $_" -Encoding utf8
    } finally {
        Remove-Item -Path $tmpOut, $tmpErr -ErrorAction SilentlyContinue
    }
    $duration = [int]((Get-Date) - $start).TotalSeconds
    Write-Log "= $Label rc=$rc duration=${duration}s"
    return $rc
}

function Invoke-WithRetry {
    param(
        [Parameter(Mandatory)][int]$Attempts,
        [Parameter(Mandatory)][scriptblock]$ScriptBlock
    )
    for ($i = 1; $i -le $Attempts; $i++) {
        try {
            $result = & $ScriptBlock
            if ($LASTEXITCODE -eq 0 -or $null -eq $LASTEXITCODE) { return 0 }
        } catch {
            Write-Log "retry $i/$Attempts threw: $_"
        }
        Start-Sleep -Seconds ($i * 2)
    }
    return 1
}

function Refresh-Path {
    $userPath    = [System.Environment]::GetEnvironmentVariable('PATH', 'User')
    $machinePath = [System.Environment]::GetEnvironmentVariable('PATH', 'Machine')
    $env:PATH = "$machinePath;$userPath"
    $localBin = Join-Path $env:USERPROFILE '.local\bin'
    if ((Test-Path $localBin) -and ($env:PATH -notlike "*$localBin*")) {
        $env:PATH = "$localBin;$env:PATH"
    }
}

# =============================================================================
#  TASK 5 — WINDOWS-SPECIFIC BOOTSTRAP (elevation, TLS, Defender, long paths)
# =============================================================================

function Test-Admin {
    $principal = New-Object Security.Principal.WindowsPrincipal(
        [Security.Principal.WindowsIdentity]::GetCurrent())
    $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Ensure-ElevationIfNeeded {
    if (Test-Admin) { return }
    Write-Host 'Windows will ask for permission to continue setup. Click Yes.' -ForegroundColor Yellow
    try {
        $argList = @('-NoProfile','-ExecutionPolicy','Bypass','-Command',
                     "irm $($Script:SetupPs1Url) | iex")
        Start-Process -FilePath 'powershell' -Verb RunAs -ArgumentList $argList | Out-Null
        exit 0
    } catch {
        Write-Status WARN 'UAC declined — admin-only repairs (Defender exclusions, long paths) may fail.'
    }
}

function Enable-Tls12 {
    try {
        [Net.ServicePointManager]::SecurityProtocol =
            [Net.SecurityProtocolType]::Tls12 -bor [Net.SecurityProtocolType]::Tls13
    } catch {
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    }
}

function Add-DefenderExclusions {
    if (-not (Test-Admin)) {
        Write-Status WARN 'Skipping Defender exclusions (not elevated)'
        return
    }
    foreach ($p in @($Script:Workspace, (Join-Path $Script:Workspace '.pio-core'))) {
        try {
            Add-MpPreference -ExclusionPath $p -ErrorAction Stop
            Write-Status OK "Defender exclusion: $p"
        } catch {
            Write-Status WARN "Could not add Defender exclusion for $p ($($_.Exception.Message))"
        }
    }
}

function Enable-LongPaths {
    if (-not (Test-Admin)) {
        Write-Status WARN 'Skipping long-paths registry (not elevated)'
        return
    }
    try {
        Set-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\FileSystem' `
            -Name 'LongPathsEnabled' -Value 1 -Type DWord
        Write-Status OK 'Long paths enabled'
    } catch {
        Write-Status WARN "Could not enable long paths: $($_.Exception.Message)"
    }
}

function Ensure-Git {
    Refresh-Path
    if (Get-Command git -ErrorAction SilentlyContinue) {
        Write-Status SKIP "Git already installed: $((git --version) -join '')"
        return
    }
    Write-Status INSTALL 'Installing Git for Windows via winget'
    $rc = Invoke-LoggedCommand -Label 'winget install git' -Command 'winget' `
        -ArgumentList @('install', '--id', 'Git.Git', '--silent',
                        '--accept-package-agreements', '--accept-source-agreements',
                        '--disable-interactivity')
    Refresh-Path
    if (Get-Command git -ErrorAction SilentlyContinue) {
        Write-Status OK "Git installed: $((git --version) -join '')"
    } else {
        Write-Status FAIL 'Git not on PATH after winget install'
    }
}

# =============================================================================
#  TASK 4 — CROSS-PLATFORM BOOTSTRAP CHECKS
# =============================================================================

function Test-PowerShellVersion {
    $v = $PSVersionTable.PSVersion
    if ($v.Major -lt 5 -or ($v.Major -eq 5 -and $v.Minor -lt 1)) {
        Write-Status FAIL "PowerShell 5.1+ required (you have $v)"
        exit 1
    }
    Write-Status OK "PowerShell $v"
}

function Check-DiskSpace {
    $drive = (Get-PSDrive ($HOME.Substring(0,1))).Free
    $availGb = [math]::Floor($drive / 1GB)
    if ($availGb -lt $Script:MinDiskGbHard) {
        Write-Status FAIL "Disk space: $availGb GB free (need at least $($Script:MinDiskGbHard) GB)"
        exit 1
    } elseif ($availGb -lt $Script:MinDiskGbWarn) {
        Write-Status WARN "Disk space: $availGb GB free (below comfortable $($Script:MinDiskGbWarn) GB)"
    } else {
        Write-Status OK "Disk space: $availGb GB free"
    }
}

function Check-ClockSkew {
    try {
        $resp = Invoke-WebRequest -Uri 'https://github.com' -Method Head -UseBasicParsing -TimeoutSec 10
        $remote = [DateTime]::Parse($resp.Headers['Date']).ToUniversalTime()
        $local  = [DateTime]::UtcNow
        $skew   = [math]::Abs(($local - $remote).TotalSeconds)
        if ($skew -gt $Script:MaxClockSkewSec) {
            Write-Status FAIL "System clock off by $([int]$skew)s vs github.com — fix the date and re-run"
            exit 1
        }
        Write-Status OK "Clock skew: $([int]$skew)s"
    } catch {
        Write-Status FAIL 'Cannot reach github.com over HTTPS to verify clock'
        Print-HttpsFailBlock
        exit 1
    }
}

function Check-WriteAccess {
    try {
        if (-not (Test-Path $Script:StateDir)) {
            New-Item -ItemType Directory -Path $Script:StateDir -Force | Out-Null
        }
        $sentinel = Join-Path $Script:StateDir '.write_test'
        Set-Content -Path $sentinel -Value 'ok' -Encoding utf8
        Remove-Item $sentinel
        Write-Status OK "Write access to $Script:StateDir"
    } catch {
        Write-Status FAIL "Cannot write to $Script:StateDir"
        exit 1
    }
}

function Print-HttpsFailBlock {
@"

[FAIL] Secure connection to GitHub failed.

Your laptop or network is blocking trusted HTTPS downloads.
Do not bypass this warning.

Show this screen to an instructor.

"@ | Write-Host
}

function Check-HttpsReachable {
    try {
        Invoke-WebRequest -Uri 'https://github.com' -UseBasicParsing -TimeoutSec 10 | Out-Null
        Write-Status OK 'GitHub HTTPS reachable'
    } catch {
        if ($Script:MirrorBase) {
            Write-Status WARN 'GitHub unreachable; will rely on local mirror'
            return
        }
        Print-HttpsFailBlock
        exit 1
    }
}

function Discover-Mirror {
    if ($Script:MirrorBase) {
        if (Cache-MirrorManifest) { Write-Status OK "Local mirror: $($Script:MirrorBase) (from env)"; return }
    }
    # mDNS probe
    try {
        $url = "http://$($Script:MirrorHost):$($Script:MirrorPort)/ping"
        $r = Invoke-WebRequest -Uri $url -UseBasicParsing -TimeoutSec 2
        if ($r.StatusCode -eq 200) {
            $Script:MirrorBase = "http://$($Script:MirrorHost):$($Script:MirrorPort)"
            if (Cache-MirrorManifest) {
                Write-Status OK 'Local mirror found — large files will download locally'
                return
            }
        }
    } catch {}
    # Subnet scan: first/last 5 of /24
    $self = Get-LocalIPv4
    if ($self) {
        $subnet = ($self -split '\.')[0..2] -join '.'
        $candidates = @(1,2,3,4,5,250,251,252,253,254) | ForEach-Object { "$subnet.$_" } | Where-Object { $_ -ne $self }
        foreach ($candidate in $candidates) {
            try {
                $r = Invoke-WebRequest -Uri "http://$candidate`:$($Script:MirrorPort)/ping" -UseBasicParsing -TimeoutSec 1
                if ($r.StatusCode -eq 200) {
                    $Script:MirrorBase = "http://$candidate`:$($Script:MirrorPort)"
                    if (Cache-MirrorManifest) {
                        Write-Status OK "Local mirror found at $($Script:MirrorBase)"
                        return
                    }
                }
            } catch {}
        }
    }
    Write-Status OK 'No local mirror — using internet'
}

function Get-LocalIPv4 {
    try {
        (Get-NetIPAddress -AddressFamily IPv4 |
            Where-Object { $_.IPAddress -notlike '127.*' -and $_.IPAddress -notlike '169.254.*' } |
            Select-Object -First 1).IPAddress
    } catch { $null }
}

function Cache-MirrorManifest {
    if (-not (Test-Path $Script:MirrorCache)) {
        New-Item -ItemType Directory -Path $Script:MirrorCache -Force | Out-Null
    }
    try {
        Invoke-WebRequest -Uri "$($Script:MirrorBase)/manifest.json" -OutFile $Script:MirrorManifest `
            -UseBasicParsing -TimeoutSec 5
        return $true
    } catch {
        Write-Status WARN "Mirror at $($Script:MirrorBase) has no manifest.json — falling back to internet"
        $Script:MirrorBase = $null
        Remove-Item $Script:MirrorManifest -ErrorAction SilentlyContinue
        return $false
    }
}

function Run-LocalBootstrapChecks {
    # Fast, offline — always run before mode detection.
    Test-PowerShellVersion
    Enable-Tls12
    Check-DiskSpace
    Check-WriteAccess
    Add-DefenderExclusions
    Enable-LongPaths
}

function Run-NetworkBootstrapChecks {
    # Slow — clock probe, HTTPS check, git install.
    # Discover-Mirror runs separately, only on first_run when artifacts need downloading.
    Check-ClockSkew
    Check-HttpsReachable
    Ensure-Git
}

# =============================================================================
#  TASK 14 — MIRROR CONSUMPTION
# =============================================================================

function Get-MirrorEntry {
    param([string]$Category, [string]$Name)
    if (-not $Script:MirrorBase) { return $null }
    if (-not (Test-Path $Script:MirrorManifest)) { return $null }
    # Manifest schema: { "generated_at": ..., "artifacts": [ {category, name, url, sha256, size}, ... ] }
    $doc = $null
    try {
        $doc = Get-Content $Script:MirrorManifest -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
    } catch {
        Write-Log "mirror manifest parse failed: $_"
        return $null
    }
    if (-not $doc.artifacts) { return $null }
    $entry = $doc.artifacts | Where-Object {
        $_.category -eq $Category -and $_.name -eq $Name
    } | Select-Object -First 1
    if (-not $entry) { return $null }
    return [pscustomobject]@{ Url = $entry.url; Sha256 = $entry.sha256 }
}

function Get-Sha256 {
    param([string]$Path)
    (Get-FileHash -Path $Path -Algorithm SHA256).Hash.ToLower()
}

function Fetch-Artifact {
    param(
        [Parameter(Mandatory)][string]$Category,
        [Parameter(Mandatory)][string]$Name,
        [string]$InternetUrl,
        [Parameter(Mandatory)][string]$OutPath
    )
    $entry = Get-MirrorEntry -Category $Category -Name $Name
    if ($entry -and $entry.Url) {
        Write-Log "mirror hit: $Category/$Name -> $($entry.Url)"
        try {
            Invoke-WebRequest -Uri $entry.Url -OutFile $OutPath -UseBasicParsing -TimeoutSec 600
            if ($entry.Sha256) {
                $got = Get-Sha256 -Path $OutPath
                if ($got -eq $entry.Sha256.ToLower()) { return $true }
                Write-Status WARN "checksum mismatch for $Name from mirror — falling back to internet"
            } else {
                return $true
            }
        } catch { Write-Status WARN "mirror download failed for $Name — falling back to internet" }
    }
    if (-not $InternetUrl) { return $false }
    Write-Log "mirror miss: $Category/$Name -> $InternetUrl"
    try {
        Invoke-WebRequest -Uri $InternetUrl -OutFile $OutPath -UseBasicParsing -TimeoutSec 600
        return $true
    } catch {
        Write-Log "internet download failed for $Name`: $_"
        return $false
    }
}

# =============================================================================
#  TASK 6 — HERMETIC PYTHON
# =============================================================================

function Ensure-Uv {
    Refresh-Path
    if (Get-Command uv -ErrorAction SilentlyContinue) {
        $v = (& uv --version 2>$null) -join ''
        Write-Status SKIP "uv already installed: $v"
        return
    }
    Write-Status INSTALL 'Installing uv'
    $installerUrl = 'https://astral.sh/uv/install.ps1'
    try {
        if ($Script:MirrorBase) {
            $entry = Get-MirrorEntry -Category 'uv' -Name 'install.ps1'
            if ($entry -and $entry.Url) { $installerUrl = $entry.Url }
        }
        $raw = (Invoke-WebRequest -Uri $installerUrl -UseBasicParsing -TimeoutSec 60).Content
        if ($raw -is [byte[]]) { $raw = [System.Text.Encoding]::UTF8.GetString($raw) }
        Invoke-Expression $raw
    } catch {
        Write-Status FAIL "uv install failed: $_"
        return
    }
    Refresh-Path
    if (Get-Command uv -ErrorAction SilentlyContinue) {
        Write-Status OK "uv $((& uv --version) -join '') installed"
    } else {
        Write-Status FAIL 'uv not on PATH after install'
    }
}

function Ensure-Python {
    Refresh-Path
    $ErrorActionPreference = 'SilentlyContinue'
    & uv python find $Script:PythonVersion 2>$null | Out-Null
    $pythonFound = ($LASTEXITCODE -eq 0)
    $ErrorActionPreference = 'Stop'
    if ($pythonFound) {
        Write-Status SKIP "Python $($Script:PythonVersion) already managed by uv"
        return
    }
    Write-Status INSTALL "Installing Python $($Script:PythonVersion) via uv"
    $rc = Invoke-LoggedCommand -Label 'uv python install' -Command 'uv' `
        -ArgumentList @('python','install',$Script:PythonVersion)
    if ($rc -eq 0) {
        Write-Status OK "Python $($Script:PythonVersion) ready"
    } else {
        Write-Status FAIL 'uv python install failed'
    }
}

function Ensure-Venv {
    if (-not (Test-Path $Script:Workspace)) {
        New-Item -ItemType Directory -Path $Script:Workspace -Force | Out-Null
    }
    $venvOk = $false
    if (Test-Path $Script:PythonBin) {
        $v = (& $Script:PythonBin --version) -join ''
        if ($v -match "Python $([regex]::Escape($Script:PythonVersion))\.") {
            Write-Status SKIP ".venv already on Python $($Script:PythonVersion)"
            $venvOk = $true
        }
    }
    if (-not $venvOk) {
        Write-Status REPAIR "Creating $($Script:VenvDir)"
        $rc = Invoke-LoggedCommand -Label 'uv venv' -Command 'uv' `
            -ArgumentList @('venv','--python',$Script:PythonVersion,'--seed','.venv') `
            -WorkingDir $Script:Workspace
        if ($rc -ne 0) { Write-Status FAIL 'uv venv failed'; return }
        Write-Status OK '.venv created'
    }
    # PlatformIO's esptoolpy post-install calls python -m pip — ensure it works.
    $ErrorActionPreference = 'SilentlyContinue'
    & $Script:PythonBin -m pip --version 2>$null | Out-Null
    $hasPip = ($LASTEXITCODE -eq 0)
    $ErrorActionPreference = 'Stop'
    if (-not $hasPip) {
        Write-Status REPAIR 'Seeding pip into .venv via ensurepip (required by PlatformIO)'
        $ErrorActionPreference = 'SilentlyContinue'
        & $Script:PythonBin -m ensurepip --upgrade 2>$null | Out-Null
        $ErrorActionPreference = 'Stop'
    }
}


# =============================================================================
#  TASK 7 — PLATFORMIO + ESP32 + LIBRARIES
# =============================================================================

function Ensure-PlatformIO {
    if (Test-Path $Script:PioBin) {
        $v = (& $Script:PioBin --version) -join ''
        Write-Status SKIP "PlatformIO already in .venv: $v"
        return
    }
    if (-not (Test-Path $Script:Workspace)) {
        New-Item -ItemType Directory -Path $Script:Workspace -Force | Out-Null
    }
    $args = @('pip','install','--python','.venv')
    if ($Script:MirrorBase) { $args += @('--find-links',"$($Script:MirrorBase)/wheels") }
    $args += @('-r','requirements.txt')
    Write-Status INSTALL 'Installing PlatformIO Core into .venv'
    $rc = Invoke-LoggedCommand -Label 'uv pip install platformio' -Command 'uv' `
        -ArgumentList $args -WorkingDir $Script:Workspace
    if ($rc -ne 0) { Write-Status FAIL 'PlatformIO install failed'; return }
    Write-Status OK 'PlatformIO installed'
}

function Ensure-Esp32Platform {
    # If esptoolpy was extracted but its post-install pip step failed, package.json
    # is absent. Remove it so PlatformIO re-downloads a clean copy.
    $esptoolpyDir  = Join-Path $Script:Workspace '.pio-core\packages\tool-esptoolpy'
    $esptoolpyJson = Join-Path $esptoolpyDir 'package.json'
    if ((Test-Path $esptoolpyDir) -and -not (Test-Path $esptoolpyJson)) {
        Write-Status REPAIR 'Removing incomplete tool-esptoolpy package'
        Remove-Item -Recurse -Force $esptoolpyDir
    }
    # Use filesystem check: pio platform list --json-output uses the *default*
    # ~/.platformio dir, not our custom .pio-core, and always returns [].
    $pkgsDir  = Join-Path $Script:Workspace '.pio-core\packages'
    $toolchain = if (Test-Path $pkgsDir) {
        Get-ChildItem $pkgsDir -Directory -Filter 'toolchain-xtensa*' -ErrorAction SilentlyContinue |
            Select-Object -First 1
    } else { $null }
    if ($null -ne $toolchain) {
        Write-Status SKIP "$($Script:PioPlatformPin) already installed"
        return
    }
    Write-Status INSTALL 'Downloading ESP32 toolchain (~500 MB) — 3-5 minutes'
    $rc = Invoke-StreamedCommand -Label 'pio platform install' `
        -Command $Script:PioBin `
        -ArgumentList @('platform','install',$Script:PioPlatformPin) `
        -WorkingDir $Script:Workspace `
        -StatusPrefix '   downloading' `
        -LineFilter { param($line) Format-PioPlatformLine $line }
    # Verify by side-effect: toolchain-xtensa* under .pio-core/packages.
    # The exit code from a streamed Start-Process can race with HasExited on
    # Windows PS 5.1 and read as $null; the disk is the source of truth.
    $toolchainOk = (Test-Path $pkgsDir) -and (
        @(Get-ChildItem $pkgsDir -Directory -Filter 'toolchain-xtensa*' -ErrorAction SilentlyContinue).Count -gt 0
    )
    if ($toolchainOk) {
        Write-Status OK 'ESP32 platform installed'
        if ($rc -ne 0) { Write-Log "note: pio platform rc=$rc but toolchain present on disk" }
    } else {
        Write-Status FAIL "ESP32 platform install failed (rc=$rc, no toolchain on disk)"
    }
}

# Translate raw PIO platform install lines into short student-facing tags.
function Format-PioPlatformLine {
    param([string]$Line)
    if (-not $Line) { return $null }
    # PlatformIO prints lines like:
    #   Tool Manager: Installing platformio/framework-arduinoespressif32 @ ...
    #   Downloading  [####                  ]  32%  00:01:23
    #   Unpacking  [####################################]  100%
    if ($Line -match 'Tool Manager:\s+Installing\s+\S+/(\S+)\s+@') {
        return "fetching $($matches[1])"
    }
    if ($Line -match 'Tool Manager:\s+(.+?)\s+@\s+\S+\s+has been installed!') {
        return "installed $($matches[1])"
    }
    if ($Line -match 'Downloading.*?\[.*?\]\s+(\d+%)') {
        return "downloading $($matches[1])"
    }
    if ($Line -match 'Unpacking.*?\[.*?\]\s+(\d+%)') {
        return "unpacking $($matches[1])"
    }
    if ($Line -match 'Platform Manager:\s+Installing\s+(\S+)') {
        return "platform $($matches[1])"
    }
    if ($Line -match 'Platform Manager:\s+(.+?)\s+@\s+\S+\s+has been installed') {
        return "platform installed"
    }
    return $null
}

# Run an external command, tail its stdout/stderr in real time, redact + log every
# line, and surface a short progress label (returned by $LineFilter) on a single
# in-place status line. Returns the process exit code, or 1 on launch failure.
function Invoke-StreamedCommand {
    param(
        [Parameter(Mandatory)][string]$Label,
        [Parameter(Mandatory)][string]$Command,
        [string[]]$ArgumentList = @(),
        [string]$WorkingDir = $null,
        [string]$StatusPrefix = '  working',
        [scriptblock]$LineFilter = $null
    )
    $sanitized = ConvertTo-Redacted "$Command $($ArgumentList -join ' ')"
    Write-Log "+ $Label`: $sanitized"
    $start  = Get-Date
    $tmpOut = New-TemporaryFile
    $tmpErr = New-TemporaryFile

    $params = @{
        FilePath               = $Command
        ArgumentList           = $ArgumentList
        NoNewWindow            = $true
        PassThru               = $true
        RedirectStandardOutput = $tmpOut.FullName
        RedirectStandardError  = $tmpErr.FullName
    }
    if ($WorkingDir) { $params.WorkingDirectory = $WorkingDir }

    $proc = $null
    try { $proc = Start-Process @params } catch {
        Add-Content -Path $Script:CurrentLog -Value "EXCEPTION: $_" -Encoding utf8
        Remove-Item -Path $tmpOut.FullName, $tmpErr.FullName -ErrorAction SilentlyContinue
        return 1
    }

    $state = @{
        OutPath = $tmpOut.FullName; ErrPath = $tmpErr.FullName
        OutPos  = 0;                ErrPos  = 0
    }
    $tick = 0; $lastStatus = ''
    while (-not $proc.HasExited) {
        $lastStatus = Read-StreamProgress -State $state `
            -LineFilter $LineFilter -LastStatus $lastStatus
        $frame = Get-SpinFrame -Tick $tick
        $msg = if ($lastStatus) { "$StatusPrefix · $lastStatus" } else { $StatusPrefix }
        Write-Host ("`r  {0} {1}" -f $frame, $msg).PadRight($Script:ProgressClearWidth) -NoNewline
        Start-Sleep -Milliseconds 120
        $tick++
    }
    # Wait for the kernel to fully reap the process. Without this, $proc.ExitCode
    # races with HasExited on Windows PowerShell 5.1 and can return $null, which
    # silently becomes "not zero" (since $null -ne 0 is true) → false FAIL.
    try { $proc.WaitForExit() } catch { }

    # Drain remaining buffered output.
    $null = Read-StreamProgress -State $state -LineFilter $LineFilter -LastStatus $lastStatus
    Clear-ProgressLine

    $rc = $proc.ExitCode
    if ($null -eq $rc) {
        # Treat as 0; downstream verifications (libdeps presence, toolchain dir,
        # code --list-extensions) are the authoritative check.
        Write-Log "= $Label WARN: ExitCode unreadable after WaitForExit; treating as 0 and deferring to side-effect check"
        $rc = 0
    }
    Remove-Item -Path $tmpOut.FullName, $tmpErr.FullName -ErrorAction SilentlyContinue
    $duration = [int]((Get-Date) - $start).TotalSeconds
    Write-Log "= $Label rc=$rc duration=${duration}s"
    return $rc
}

# Read newly-appended lines from the stdout/stderr files since last poll, send them
# to the script log, and return the most recent non-empty status (from $LineFilter
# or the raw last line) for in-place rendering.
#
# $State is a hashtable: { OutPath, ErrPath, OutPos, ErrPos }. We mutate OutPos /
# ErrPos directly — hashtables are reference-typed in PS, so the mutations
# propagate back to the caller. (An earlier version used [ref]$h.Member, which
# silently doesn't propagate, causing every poll to re-read the whole file.)
function Read-StreamProgress {
    param(
        [Parameter(Mandatory)][hashtable]$State,
        [scriptblock]$LineFilter,
        [string]$LastStatus
    )
    $status = $LastStatus
    foreach ($which in @('Out','Err')) {
        $path   = $State["${which}Path"]
        $posKey = "${which}Pos"
        if (-not $path -or -not (Test-Path $path)) { continue }
        try { $size = (Get-Item $path).Length } catch { continue }
        if ($size -le $State[$posKey]) { continue }
        $fs = [System.IO.File]::Open($path, 'Open', 'Read', 'ReadWrite')
        try {
            $null = $fs.Seek($State[$posKey], 'Begin')
            $sr = New-Object System.IO.StreamReader($fs)
            try { $chunk = $sr.ReadToEnd() } finally { $sr.Dispose() }
        } finally { $fs.Dispose() }
        $State[$posKey] = $size
        foreach ($raw in $chunk -split "(`r`n|`r|`n)") {
            $line = ($raw -replace '\x1b\[[0-9;]*[A-Za-z]','').Trim()
            if (-not $line) { continue }
            Add-Content -Path $Script:CurrentLog -Value $line -Encoding utf8
            $cooked = if ($LineFilter) { & $LineFilter $line } else { $line }
            if ($cooked) {
                $status = ($cooked -as [string])
                if ($status.Length -gt 80) { $status = $status.Substring(0,77) + '...' }
            }
        }
    }
    return $status
}

function Ensure-Libraries {
    if (-not (Test-Path (Join-Path $Script:Workspace 'platformio.ini'))) {
        Write-Status FAIL 'platformio.ini missing'; return
    }
    Write-Status INSTALL "Installing $($Script:ExpectedLibs.Count) libraries"

    $total = $Script:ExpectedLibs.Count
    $script:libCounter = 0
    $rc = Invoke-StreamedCommand -Label 'pio pkg install' -Command $Script:PioBin `
        -ArgumentList @('pkg','install') -WorkingDir $Script:Workspace `
        -StatusPrefix '   libraries' `
        -LineFilter {
            param($line)
            if ($line -match 'Library Manager:\s+Installing\s+(.+)$') {
                $script:libCounter = [Math]::Min($script:libCounter + 1, $total)
                return ("[{0}/{1}] {2}" -f $script:libCounter, $total, $matches[1].Trim())
            }
            if ($line -match 'Library Manager:\s+(.+?)\s+@\s+\S+\s+is already installed') {
                $script:libCounter = [Math]::Min($script:libCounter + 1, $total)
                return ("[{0}/{1}] {2} (cached)" -f $script:libCounter, $total, $matches[1].Trim())
            }
            return $null
        }
    # Verify by side-effect, regardless of pio's reported rc — the streamed
    # ExitCode can race on Windows PS 5.1. Disk state is the source of truth.
    $libdeps = Join-Path $Script:Workspace '.pio\libdeps'
    $missing = @()
    if (Test-Path $libdeps) {
        foreach ($lib in $Script:ExpectedLibs) {
            $pat = ($lib -split ' ')[0]
            $found = Get-ChildItem -Path $libdeps -Directory -Recurse -ErrorAction SilentlyContinue |
                Where-Object { $_.Name -like "*$pat*" }
            if (-not $found) { $missing += $lib }
        }
    }
    if ((Test-Path $libdeps) -and $missing.Count -eq 0) {
        Write-Status OK "All $total libraries installed"
        if ($rc -ne 0) { Write-Log "note: pio rc=$rc but all expected libraries present on disk" }
    } else {
        if (-not (Test-Path $libdeps)) {
            Write-Status FAIL "pio pkg install failed (rc=$rc, libdeps directory missing)"
        } else {
            foreach ($lib in $missing) { Write-Status FAIL "Library missing: $lib" }
        }
    }
}

# =============================================================================
#  TASK 8 — UPSTREAM CLONE + SYNC
# =============================================================================

function Ensure-Upstream {
    if ((Test-Path (Join-Path $Script:UpstreamDir '.git')) -and
        ((& git -C $Script:UpstreamDir remote get-url origin 2>$null) -eq $Script:RepoUrl)) {
        Write-Status SKIP 'Hidden upstream cache present'
        return
    }
    if (Test-Path $Script:UpstreamDir) {
        $ts = (Get-Date).ToString('yyyyMMdd-HHmmss')
        $backup = "$($Script:UpstreamDir)_backup_$ts"
        Move-Item -Path $Script:UpstreamDir -Destination $backup
        Write-Status WARN "Renamed broken cache to upstream_backup_$ts"
    }
    if (-not (Test-Path $Script:StateDir)) {
        New-Item -ItemType Directory -Path $Script:StateDir -Force | Out-Null
    }
    Write-Status INSTALL 'Cloning class content (first time only)'
    $rc = Invoke-LoggedCommand -Label 'git clone upstream' -Command 'git' `
        -ArgumentList @('clone','--depth=50','--branch',$Script:RepoBranch,$Script:RepoUrl,$Script:UpstreamDir)
    if ($rc -ne 0) { Write-Status FAIL 'git clone failed'; return }
    Write-Status OK 'Upstream cache ready'
}

function Test-IsInstructorPath {
    param([string]$RelPath)
    foreach ($p in $Script:InstructorPaths) {
        if ($RelPath -eq $p -or $RelPath.StartsWith("$p\") -or $RelPath.StartsWith("$p/")) {
            return $true
        }
    }
    return $false
}

function Test-IsStudentPath {
    param([string]$RelPath)
    foreach ($p in $Script:StudentPaths) {
        if ($RelPath -eq $p -or $RelPath.StartsWith("$p\") -or $RelPath.StartsWith("$p/")) {
            return $true
        }
    }
    return $false
}

function Save-RescuedFile {
    param([string]$Rel)
    $localPath = Join-Path $Script:Workspace $Rel
    if (-not (Test-Path $localPath -PathType Leaf)) { return }
    if (-not $Script:RescueTs) { $Script:RescueTs = (Get-Date).ToString('yyyyMMdd-HHmmss') }
    $target = Join-Path (Join-Path $Script:RescueDir $Script:RescueTs) $Rel
    $targetDir = Split-Path -Path $target -Parent
    if (-not (Test-Path $targetDir)) { New-Item -ItemType Directory -Path $targetDir -Force | Out-Null }
    Copy-Item -Path $localPath -Destination $target -Force
    Write-Log "[RESCUE] $Rel -> _rescued\$($Script:RescueTs)\$Rel"
}

function Save-RescuedIfModified {
    param([string]$Rel)
    $localPath    = Join-Path $Script:Workspace $Rel
    $upstreamPath = Join-Path $Script:UpstreamDir $Rel
    if (-not (Test-Path $localPath) -or -not (Test-Path $upstreamPath)) { return }
    if (Test-Path $upstreamPath -PathType Leaf) {
        $a = (Get-FileHash $localPath    -Algorithm SHA1).Hash
        $b = (Get-FileHash $upstreamPath -Algorithm SHA1).Hash
        if ($a -ne $b) {
            Save-RescuedFile $Rel
            Write-Status REPAIR "Restored protected file: $Rel (edited copy saved in _rescued\$($Script:RescueTs)\)"
        }
        return
    }
    $rescued = $false
    Get-ChildItem -Path $localPath -Recurse -File -ErrorAction SilentlyContinue | ForEach-Object {
        $sub = $_.FullName.Substring($localPath.Length).TrimStart('\','/')
        $up = Join-Path $upstreamPath $sub
        if (Test-Path $up -PathType Leaf) {
            $a = (Get-FileHash $_.FullName -Algorithm SHA1).Hash
            $b = (Get-FileHash $up         -Algorithm SHA1).Hash
            if ($a -eq $b) { return }
        }
        Save-RescuedFile (Join-Path $Rel $sub)
        $rescued = $true
    }
    if ($rescued) {
        Write-Status REPAIR "Restored protected path: $Rel (edited files saved in _rescued\$($Script:RescueTs)\)"
    }
}

function Sync-Workspace {
    if (-not (Test-Path (Join-Path $Script:UpstreamDir '.git'))) { Ensure-Upstream }
    if (-not (Test-Path $Script:Workspace)) {
        New-Item -ItemType Directory -Path $Script:Workspace -Force | Out-Null
    }
    Promote-LogToWorkspace
    Disable-GitInWorkspace

    # Remove the workspace file that triggers VS Code's "Open as workspace?" toast.
    $staleWs = Join-Path $Script:Workspace 'ronnie-robot.code-workspace'
    if (Test-Path $staleWs) { Remove-Item $staleWs -Force -ErrorAction SilentlyContinue }

    $oldSha = (& git -C $Script:UpstreamDir rev-parse HEAD 2>$null)
    Invoke-LoggedCommand -Label 'git fetch' -Command 'git' `
        -ArgumentList @('-C',$Script:UpstreamDir,'fetch','origin',$Script:RepoBranch) | Out-Null
    Invoke-LoggedCommand -Label 'git reset' -Command 'git' `
        -ArgumentList @('-C',$Script:UpstreamDir,'reset','--hard',"origin/$($Script:RepoBranch)") | Out-Null
    $newSha = (& git -C $Script:UpstreamDir rev-parse HEAD)

    $changedCount = 0

    if ($oldSha -and $oldSha -eq $newSha -and (Check-ContentMatch)) {
        Write-Status SKIP 'Already up to date'
        return
    }

    foreach ($rel in $Script:InstructorPaths) {
        $src = Join-Path $Script:UpstreamDir $rel
        if (-not (Test-Path $src)) { continue }
        Save-RescuedIfModified $rel
        $dst = Join-Path $Script:Workspace $rel
        if ((Get-Item $src).PSIsContainer) {
            $null = Invoke-LoggedCommand -Label "robocopy $rel" -Command 'robocopy' `
                -ArgumentList @($src, $dst, '/MIR', '/R:1', '/W:1', '/NJH', '/NJS', '/NP', '/NDL')
        } else {
            $dstDir = Split-Path -Path $dst -Parent
            if (-not (Test-Path $dstDir)) { New-Item -ItemType Directory -Path $dstDir -Force | Out-Null }
            Copy-Item -Path $src -Destination $dst -Force
        }
    }

    if ($oldSha -and $oldSha -ne $newSha) {
        $diff = & git -C $Script:UpstreamDir diff --name-only $oldSha $newSha
        $changedCount = ($diff | Measure-Object -Line).Lines
    }
    if ($changedCount -gt 0) {
        Write-Status OK "Content sync ($changedCount files changed)"
    } else {
        Write-Status OK 'Content sync'
    }
}

function Disable-GitInWorkspace {
    $gitDir = Join-Path $Script:Workspace '.git'
    if (Test-Path $gitDir) {
        $ts = (Get-Date).ToString('yyyyMMdd-HHmmss')
        Move-Item -Path $gitDir -Destination (Join-Path $Script:Workspace ".git_disabled_$ts")
        Write-Status REPAIR "Disabled stray .git in workspace -> .git_disabled_$ts"
    }
}

function Seed-StudentCodeIfEmpty {
    if ((Test-Path $Script:StudentCodeDir) -and
        (Get-ChildItem -Path $Script:StudentCodeDir -File -Force -ErrorAction SilentlyContinue)) {
        Write-Status SKIP 'my_robot_code\ already populated — leaving student edits alone'
        return
    }
    $src = Join-Path $Script:UpstreamDir 'my_robot_code'
    $srcMain = Join-Path $src 'main.cpp'
    if (-not (Test-Path $srcMain)) {
        Write-Status FAIL "Upstream starter missing: $srcMain"
        throw "Upstream starter missing: $srcMain"
    }
    if (-not (Test-Path $Script:StudentCodeDir)) {
        New-Item -ItemType Directory -Path $Script:StudentCodeDir -Force | Out-Null
    }
    Copy-Item -Path (Join-Path $src '*') -Destination $Script:StudentCodeDir -Recurse -Force
    Write-Status OK 'Seeded my_robot_code\ from upstream starter'
}

# =============================================================================
#  TASK 9 — VS CODE + EXTENSIONS
# =============================================================================

function Ensure-VsCode {
    Refresh-Path
    $existing = Get-Command code -ErrorAction SilentlyContinue
    if ($existing) {
        $ver = (& code --version 2>$null | Select-Object -First 1)
        if ($ver -match '^(\d+)\.(\d+)') {
            $major = [int]$matches[1]; $minor = [int]$matches[2]
            if ($major -gt $Script:MinVscodeVersionMajor -or
                ($major -eq $Script:MinVscodeVersionMajor -and $minor -ge $Script:MinVscodeVersionMinor)) {
                Write-Status SKIP "VS Code $ver already installed"
                return
            }
        }
        Write-Status WARN "VS Code $ver below minimum; reinstalling"
    }
    Write-Status INSTALL 'Installing VS Code via winget'
    $rc = Invoke-StreamedCommand -Label 'winget install vscode' -Command 'winget' `
        -ArgumentList @('install', '--id', 'Microsoft.VisualStudioCode', '--silent',
                        '--accept-package-agreements', '--accept-source-agreements',
                        '--disable-interactivity') `
        -StatusPrefix '   vscode' -LineFilter { param($l) Format-WingetLine $l }
    if ($rc -ne 0) {
        Write-Status WARN "winget failed (rc=$rc) — falling back to direct download"
        $installer = Join-Path $Script:StateDir 'VSCodeSetup.exe'
        $internet  = 'https://code.visualstudio.com/sha/download?build=stable&os=win32-x64-user'
        Write-Status INSTALL 'Downloading VS Code installer'
        if (-not (Fetch-Artifact 'vscode' 'VSCodeSetup-x64.exe' $internet $installer)) {
            Write-Status FAIL 'VS Code download failed'; return
        }
        $installArgs = @('/VERYSILENT', '/NORESTART',
                         '/MERGETASKS=!desktopicon,!quicklaunchicon,!associatewithfiles,!addcontextmenufiles,!addcontextmenufolders,addtopath')
        Write-Status INSTALL 'Running VS Code installer'
        $rc = Invoke-StreamedCommand -Label 'vscode install' -Command $installer `
            -ArgumentList $installArgs `
            -StatusPrefix '   installer running (silent)'
        if ($rc -ne 0) { Write-Status FAIL "VS Code installer exited $rc"; return }
    }
    Refresh-Path
    if (Get-Command code -ErrorAction SilentlyContinue) {
        Write-Status OK 'VS Code installed'
    } else {
        Write-Status FAIL 'VS Code not on PATH after install — open a fresh PowerShell window'
    }
}

# Translate raw winget output lines into short student-facing tags. Winget
# emits things like:
#   Found Microsoft Visual Studio Code [XP9KHM4BK9FZ7Q]
#   Downloading https://...
#   ██████████████████████████ 87.5 MB / 105 MB
#   Successfully installed
function Format-WingetLine {
    param([string]$Line)
    if (-not $Line) { return $null }
    if ($Line -match 'Found\s+(.+?)\s*\[') { return "found $($matches[1].Trim())" }
    if ($Line -match 'Downloading\s+http') { return 'downloading' }
    if ($Line -match '(\d+(?:\.\d+)?)\s*MB\s*/\s*(\d+(?:\.\d+)?)\s*MB') {
        return "downloading $($matches[1]) / $($matches[2]) MB"
    }
    if ($Line -match 'Successfully verified')   { return 'verified' }
    if ($Line -match 'Starting package install'){ return 'installing' }
    if ($Line -match 'Successfully installed')  { return 'installed' }
    return $null
}

function Ensure-Extensions {
    if (-not (Get-Command code -ErrorAction SilentlyContinue)) {
        Write-Status FAIL 'code CLI not on PATH'; return
    }
    $installed = (& code --list-extensions 2>$null) | ForEach-Object { $_.ToLower() }
    $idx = 0
    $total = $Script:VscodeExts.Count
    foreach ($ext in $Script:VscodeExts) {
        $idx++
        if ($installed -contains $ext.ToLower()) {
            Write-Status SKIP ("[{0}/{1}] {2} (already installed)" -f $idx, $total, $ext)
            continue
        }
        Write-Status INSTALL ("[{0}/{1}] {2}" -f $idx, $total, $ext)
        $ok = Install-OneExtension $ext
        if (-not $ok) { $ok = Install-OneExtension $ext }
        if (-not $ok) { Write-Status FAIL "ext $ext could not be installed" }
    }
}

function Install-OneExtension {
    param([string]$Ext)
    $entry = Get-MirrorEntry -Category 'vsix' -Name "$Ext.vsix"
    if ($entry -and $entry.Url) {
        $vsix = Join-Path $Script:StateDir "$Ext.vsix"
        if (Fetch-Artifact 'vsix' "$Ext.vsix" $null $vsix) {
            $null = Invoke-StreamedCommand -Label "ext install $Ext (vsix)" -Command 'code' `
                -ArgumentList @('--install-extension',$vsix) `
                -StatusPrefix "   $Ext" -LineFilter { param($l) Format-ExtensionLine $l }
            if (Test-ExtensionInstalled $Ext) { Write-Status OK "ext $Ext"; return $true }
        }
    }
    $null = Invoke-StreamedCommand -Label "ext install $Ext (marketplace)" -Command 'code' `
        -ArgumentList @('--install-extension',$Ext) `
        -StatusPrefix "   $Ext" -LineFilter { param($l) Format-ExtensionLine $l }
    if (Test-ExtensionInstalled $Ext) { Write-Status OK "ext $Ext"; return $true }
    return $false
}

# Source of truth for "is this extension installed": ask the code CLI directly.
# Avoids relying on the streamed-process ExitCode race.
function Test-ExtensionInstalled {
    param([string]$Ext)
    $list = & code --list-extensions 2>$null
    if (-not $list) { return $false }
    return ($list | Where-Object { $_ -and ($_.ToLower() -eq $Ext.ToLower()) }) -ne $null
}

function Format-ExtensionLine {
    param([string]$Line)
    if (-not $Line) { return $null }
    if ($Line -match 'Installing extensions') { return 'installing' }
    if ($Line -match 'Installing extension') { return 'installing' }
    if ($Line -match 'was successfully installed') { return 'installed' }
    if ($Line -match 'is already installed') { return 'already installed' }
    if ($Line -match 'Downloading') { return 'downloading' }
    if ($Line -match 'Verifying') { return 'verifying' }
    return $null
}

# Run pio pkg install AND code --install-extension calls in parallel: PIO as a
# single long process, extensions as a serialised chain (the code CLI doesn't
# parallelise safely). Both share one render loop that prints a single status
# line with both streams' progress.
#
# All loop state lives in a single hashtable ($S) so the inline "start next ext"
# block can mutate it without scope contortions.
function Invoke-ParallelLibsAndExtensions {
    if (-not (Test-Path (Join-Path $Script:Workspace 'platformio.ini'))) {
        Write-Status FAIL 'platformio.ini missing'
        Ensure-Extensions
        return
    }
    if (-not (Test-Path $Script:PioBin)) {
        # Earlier phase recorded FAIL on PlatformIO; don't crash here.
        Write-Status FAIL 'PlatformIO missing — skipping library install'
        Ensure-Extensions
        return
    }
    if (-not (Get-Command code -ErrorAction SilentlyContinue)) {
        # Without code on PATH we can't parallelise; fall back to sequential.
        Ensure-Libraries; Ensure-Extensions; return
    }

    $libOut = New-TemporaryFile; $libErr = New-TemporaryFile
    $S = @{
        LibTotal   = $Script:ExpectedLibs.Count
        LibDone    = 0
        LibStatus  = 'starting'
        LibState   = @{ OutPath = $libOut.FullName; ErrPath = $libErr.FullName; OutPos = 0; ErrPos = 0 }

        ExtTotal   = $Script:VscodeExts.Count
        ExtQueue   = [System.Collections.Queue]::new()
        ExtIdx     = 0
        ExtCur     = $null
        ExtProc    = $null
        ExtState   = $null   # set per-extension launch
        ExtStatus  = 'queued'
        ExtResults = @{}
        ExtInstalled = @{}
    }
    foreach ($e in $Script:VscodeExts) { $S.ExtQueue.Enqueue($e) }
    (& code --list-extensions 2>$null) | ForEach-Object {
        if ($_) { $S.ExtInstalled[$_.ToLower()] = $true }
    }

    Write-Status INSTALL "Installing $($S.LibTotal) libraries + $($S.ExtTotal) VS Code extensions in parallel"

    Write-Log "+ pio pkg install (parallel)"
    $libProc = $null
    try {
        $libProc = Start-Process -FilePath $Script:PioBin -ArgumentList @('pkg','install') `
            -WorkingDirectory $Script:Workspace -NoNewWindow -PassThru `
            -RedirectStandardOutput $S.LibState.OutPath -RedirectStandardError $S.LibState.ErrPath
    } catch {
        Write-Log "pio launch failed: $_"
        Write-Status FAIL "pio pkg install could not launch: $($_.Exception.Message)"
        Remove-Item $S.LibState.OutPath, $S.LibState.ErrPath -ErrorAction SilentlyContinue
        # Fall back to sequential extension install so we still finish the phase.
        Ensure-Extensions
        return
    }

    $startNextExt = {
        if ($S.ExtQueue.Count -eq 0) { return }
        $S.ExtCur = $S.ExtQueue.Dequeue()
        $S.ExtIdx = $S.ExtIdx + 1
        if ($S.ExtInstalled.ContainsKey($S.ExtCur.ToLower())) {
            $S.ExtResults[$S.ExtCur] = 'skip'
            $S.ExtStatus = ("[{0}/{1}] {2} (cached)" -f $S.ExtIdx, $S.ExtTotal, $S.ExtCur)
            $S.ExtProc = $null
            return
        }
        $eo = New-TemporaryFile; $ee = New-TemporaryFile
        $S.ExtState = @{ OutPath = $eo.FullName; ErrPath = $ee.FullName; OutPos = 0; ErrPos = 0 }
        $S.ExtStatus = ("[{0}/{1}] {2}" -f $S.ExtIdx, $S.ExtTotal, $S.ExtCur)
        Write-Log "+ ext install $($S.ExtCur) (parallel)"
        try {
            $S.ExtProc = Start-Process -FilePath 'code' `
                -ArgumentList @('--install-extension', $S.ExtCur) `
                -NoNewWindow -PassThru `
                -RedirectStandardOutput $S.ExtState.OutPath `
                -RedirectStandardError  $S.ExtState.ErrPath
        } catch {
            Write-Log "code launch failed for $($S.ExtCur): $_"
            $S.ExtResults[$S.ExtCur] = 'fail'
            $S.ExtStatus = ("[{0}/{1}] {2} (launch failed)" -f $S.ExtIdx, $S.ExtTotal, $S.ExtCur)
            Remove-Item $S.ExtState.OutPath, $S.ExtState.ErrPath -ErrorAction SilentlyContinue
            $S.ExtState = $null
            $S.ExtProc  = $null
        }
    }

    & $startNextExt

    $libLineFilter = {
        param($line)
        if ($line -match 'Library Manager:\s+Installing\s+(.+)$') {
            $S.LibDone = [Math]::Min($S.LibDone + 1, $S.LibTotal)
            return ("[{0}/{1}] {2}" -f $S.LibDone, $S.LibTotal, $matches[1].Trim())
        }
        if ($line -match 'Library Manager:\s+(.+?)\s+@\s+\S+\s+is already installed') {
            $S.LibDone = [Math]::Min($S.LibDone + 1, $S.LibTotal)
            return ("[{0}/{1}] {2} (cached)" -f $S.LibDone, $S.LibTotal, $matches[1].Trim())
        }
        return $null
    }
    $extLineFilter = {
        param($line)
        $f = Format-ExtensionLine $line
        if ($f) { return ("[{0}/{1}] {2} · {3}" -f $S.ExtIdx, $S.ExtTotal, $S.ExtCur, $f) }
        return $null
    }

    $tick = 0
    while ($true) {
        # Lib polling.
        $S.LibStatus = Read-StreamProgress -State $S.LibState `
            -LastStatus $S.LibStatus -LineFilter $libLineFilter

        # Ext polling (only when a real process is running).
        if ($S.ExtProc -and -not $S.ExtProc.HasExited -and $S.ExtState) {
            $S.ExtStatus = Read-StreamProgress -State $S.ExtState `
                -LastStatus $S.ExtStatus -LineFilter $extLineFilter
        }

        # Current ext finished (or was a cached skip) — advance.
        $extReady = (-not $S.ExtProc) -or $S.ExtProc.HasExited
        if ($extReady -and $S.ExtCur) {
            if ($S.ExtProc) {
                # Wait for full reap so ExitCode is reliable on Windows PS 5.1.
                try { $S.ExtProc.WaitForExit() } catch { }
                if ($S.ExtState) {
                    $null = Read-StreamProgress -State $S.ExtState `
                        -LastStatus $S.ExtStatus -LineFilter $extLineFilter
                }
                $extRc = $S.ExtProc.ExitCode
                if ($null -eq $extRc) { $extRc = 0 }  # defer to side-effect check
                $S.ExtResults[$S.ExtCur] = if ($extRc -eq 0) { 'ok' } else { 'fail' }
                if ($S.ExtState) {
                    Remove-Item $S.ExtState.OutPath, $S.ExtState.ErrPath -ErrorAction SilentlyContinue
                }
            }
            $S.ExtCur = $null; $S.ExtProc = $null; $S.ExtState = $null
            & $startNextExt
        }

        # Render: single line, both tracks.
        $frame = Get-SpinFrame -Tick $tick
        $line = "  {0} Libs: {1}  │  Exts: {2}" -f $frame, $S.LibStatus, $S.ExtStatus
        if ($line.Length -gt ($Script:ProgressClearWidth - 2)) {
            $line = $line.Substring(0, $Script:ProgressClearWidth - 5) + '...'
        }
        Write-Host ("`r" + $line.PadRight($Script:ProgressClearWidth)) -NoNewline

        $libIsDone = $libProc.HasExited
        $extIsDone = ($S.ExtQueue.Count -eq 0) -and (-not $S.ExtCur) -and (-not $S.ExtProc)
        if ($libIsDone -and $extIsDone) { break }
        Start-Sleep -Milliseconds 120
        $tick++
    }
    # Wait for full reap so libProc.ExitCode is reliable on Windows PS 5.1.
    try { $libProc.WaitForExit() } catch { }

    # Final drain of pio output.
    $null = Read-StreamProgress -State $S.LibState -LastStatus $S.LibStatus
    Clear-ProgressLine

    $libRc = $libProc.ExitCode
    if ($null -eq $libRc) { $libRc = 0 }  # defer to side-effect check
    Remove-Item $S.LibState.OutPath, $S.LibState.ErrPath -ErrorAction SilentlyContinue
    Write-Log "= pio pkg install (parallel) rc=$libRc"

    # Library results — verify by filesystem first. ExitCode is a hint, not the
    # source of truth (it raced with HasExited on Win PS 5.1 in earlier builds
    # and falsely flagged every library as failed).
    $libdeps = Join-Path $Script:Workspace '.pio\libdeps'
    $missing = @()
    if (Test-Path $libdeps) {
        foreach ($lib in $Script:ExpectedLibs) {
            $pat = ($lib -split ' ')[0]
            $found = Get-ChildItem -Path $libdeps -Directory -Recurse -ErrorAction SilentlyContinue |
                Where-Object { $_.Name -like "*$pat*" }
            if (-not $found) { $missing += $lib }
        }
    }
    if ((Test-Path $libdeps) -and $missing.Count -eq 0) {
        Write-Status OK "All $($S.LibTotal) libraries installed"
        if ($libRc -ne 0) { Write-Log "note: pio rc=$libRc but all expected libraries present on disk" }
    } else {
        if (-not (Test-Path $libdeps)) {
            Write-Status FAIL "pio pkg install failed (rc=$libRc, libdeps directory missing)"
        } else {
            foreach ($lib in $missing) { Write-Status FAIL "Library missing: $lib" }
        }
    }

    # Extension results — verify against `code --list-extensions` regardless of
    # the parallel runner's per-ext exit code reading.
    $finalInstalled = @{}
    (& code --list-extensions 2>$null) | ForEach-Object {
        if ($_) { $finalInstalled[$_.ToLower()] = $true }
    }
    foreach ($ext in $Script:VscodeExts) {
        if ($finalInstalled.ContainsKey($ext.ToLower())) {
            $tag = $S.ExtResults[$ext]
            if ($tag -eq 'skip') { Write-Status SKIP "ext $ext (already installed)" }
            else                 { Write-Status OK   "ext $ext" }
            continue
        }
        # Not present in code's final list — actually missing. Retry sequentially.
        Write-Status WARN "ext $ext not present after parallel run — retrying"
        if (-not (Install-OneExtension $ext)) {
            Write-Status FAIL "ext $ext could not be installed"
        }
    }
}

# =============================================================================
#  TASK 10 — SMOKE TEST + DIAG STATE
# =============================================================================

function Render-SmokeProject {
    if (-not (Test-Path (Join-Path $Script:SmokeDir 'src'))) {
        New-Item -ItemType Directory -Path (Join-Path $Script:SmokeDir 'src') -Force | Out-Null
    }
    $pio = Join-Path $Script:Workspace 'platformio.ini'
    $libDepsLines = @()
    $inBlock = $false
    foreach ($line in Get-Content $pio) {
        if ($line -match '^\s*lib_deps\s*=') { $inBlock = $true; continue }
        if ($inBlock) {
            if ($line -match '^\s*[A-Za-z\[]') { break }
            if ($line -match '^\s+') { $libDepsLines += $line }
        }
    }
    $coreDir    = (Join-Path $Script:Workspace '.pio-core') -replace '\\','\\'
    # Point lib_extra_dirs at the workspace's already-installed libdeps so the
    # smoke compile does not re-download libraries from the internet.
    $libdepsDir = (Join-Path $Script:Workspace ".pio\libdeps\$Script:PioBoard") -replace '\\','\\'
    $smokeIni = @"
[platformio]
core_dir = $coreDir

[env:$($Script:PioBoard)]
platform = $($Script:PioPlatformPin)
board = $($Script:PioBoard)
framework = $($Script:PioFramework)
monitor_speed = $($Script:MonitorSpeed)
upload_speed = $($Script:UploadSpeed)
lib_extra_dirs = $libdepsDir
lib_deps =
$($libDepsLines -join "`n")
"@
    # PS5.1 Set-Content writes UTF-8 BOM; configparser rejects files with BOM.
    [System.IO.File]::WriteAllText(
        (Join-Path $Script:SmokeDir 'platformio.ini'),
        $smokeIni,
        [System.Text.UTF8Encoding]::new($false)
    )
    $cpp = @'
#include <Arduino.h>
#include <Wire.h>
#include <WiFi.h>
#include <WebServer.h>
#include <ArduinoJson.h>
#include <Adafruit_PWMServoDriver.h>
#include <NewPing.h>
#include <ESP32Servo.h>
#include <Adafruit_NeoPixel.h>

Adafruit_PWMServoDriver pwm = Adafruit_PWMServoDriver(0x40);
WebServer server(80);
Servo introServo;
Adafruit_NeoPixel strip(8, D7, NEO_GRB + NEO_KHZ800);

constexpr int kUltrasonicTrig = D0;
constexpr int kUltrasonicEcho = D1;
NewPing sonar(kUltrasonicTrig, kUltrasonicEcho, 200);

void setup() {
  Serial.begin(115200);
  Wire.begin(D4, D5);
  introServo.setPeriodHertz(50);
  strip.begin();

  JsonDocument doc;
  doc["board"] = "seeed_xiao_esp32c3";
  doc["servo_driver"] = "pca9685";
  doc["ultrasonic"] = "hc-sr04";
  doc["neopixel"] = "ws2812b";
}

void loop() {}
'@
    Set-Content -Path (Join-Path $Script:SmokeDir 'src\main.cpp') -Value $cpp -Encoding utf8
}

function Run-SmokeTest {
    Render-SmokeProject
    Write-Status SMOKE 'Compiling XIAO smoke test'
    $rc = Invoke-LoggedCommand -Label 'pio run smoke' -Command $Script:PioBin `
        -ArgumentList @('run') -WorkingDir $Script:SmokeDir
    if ($rc -eq 0) {
        Write-DiagState passed
        Write-Status OK 'Environment ready. Plug in your XIAO ESP32C3 to flash.'
        return $true
    }
    Write-DiagState failed
    Write-Status FAIL 'Smoke compile failed'
    return $false
}

function Write-DiagState {
    param([string]$Result)
    $commit = (& git -C $Script:UpstreamDir rev-parse HEAD 2>$null)
    if (-not $commit) { $commit = 'unknown' }
    $now = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
    $passed = if ($Result -eq 'passed') { 'true' } else { 'false' }
    $json = @"
{
  "last_setup_completed_at": "$now",
  "last_script_version": "$($Script:Version)",
  "last_content_commit": "$commit",
  "last_smoke_test": {
    "passed": $passed,
    "timestamp": "$now",
    "board": "$($Script:PioBoard)"
  }
}
"@
    Set-Content -Path $Script:DiagState -Value $json -Encoding utf8
}

# =============================================================================
#  TASK 11 — HEALTH CHECKS + MODE DETECTION
# =============================================================================

function Check-Upstream {
    if (-not (Test-Path (Join-Path $Script:UpstreamDir '.git'))) { return $false }
    $remote = & git -C $Script:UpstreamDir remote get-url origin 2>$null
    return ($remote -eq $Script:RepoUrl)
}
function Check-WorkspaceDir {
    (Test-Path $Script:Workspace) -and
    -not (Test-Path (Join-Path $Script:Workspace '.git'))
}
function Check-MyRobotCode {
    (Test-Path $Script:StudentCodeDir) -and
    [bool](Get-ChildItem -Path $Script:StudentCodeDir -File -Force -ErrorAction SilentlyContinue)
}
function Check-ContentMatch {
    foreach ($p in $Script:InstructorPaths) {
        $src = Join-Path $Script:UpstreamDir $p
        $dst = Join-Path $Script:Workspace  $p
        if (-not (Test-Path $src)) { continue }
        if (-not (Test-Path $dst)) { return $false }
        if ((Get-Item $src).PSIsContainer) {
            $r = & robocopy $src $dst /L /NFL /NDL /NJH /NJS /NP /MIR 2>$null
            if ($LASTEXITCODE -gt 0) { return $false }
        } else {
            $a = Get-FileHash $src -Algorithm SHA1
            $b = Get-FileHash $dst -Algorithm SHA1 -ErrorAction SilentlyContinue
            if (-not $b -or $a.Hash -ne $b.Hash) { return $false }
        }
    }
    return $true
}
function Check-VsCode {
    if (-not (Get-Command code -ErrorAction SilentlyContinue)) { return $false }
    $v = (& code --version 2>$null | Select-Object -First 1)
    if ($v -notmatch '^(\d+)\.(\d+)') { return $false }
    $major = [int]$matches[1]; $minor = [int]$matches[2]
    ($major -gt $Script:MinVscodeVersionMajor) -or
    ($major -eq $Script:MinVscodeVersionMajor -and $minor -ge $Script:MinVscodeVersionMinor)
}
function Check-ExtensionsHealth {
    if (-not (Get-Command code -ErrorAction SilentlyContinue)) { return $false }
    $installed = (& code --list-extensions 2>$null) | ForEach-Object { $_.ToLower() }
    foreach ($e in $Script:VscodeExts) { if ($installed -notcontains $e.ToLower()) { return $false } }
    return $true
}
function Check-Uv {
    Refresh-Path
    if (-not (Get-Command uv -ErrorAction SilentlyContinue)) { return $false }
    & uv --version 2>$null | Out-Null
    return ($LASTEXITCODE -eq 0)
}
function Check-PythonHealth {
    if (-not (Test-Path $Script:PythonBin)) { return $false }
    $v = (& $Script:PythonBin --version 2>$null) -join ''
    $v -match "Python $([regex]::Escape($Script:PythonVersion))\."
}
function Check-PioVenv {
    if (-not (Test-Path $Script:PioBin)) { return $false }
    $ErrorActionPreference = 'SilentlyContinue'
    & $Script:PioBin --version 2>$null | Out-Null
    $ok = ($LASTEXITCODE -eq 0)
    if (-not $ok) { $ErrorActionPreference = 'Stop'; return $false }
    # pip must be importable — esptoolpy's post-install calls python -m pip
    & $Script:PythonBin -m pip --version 2>$null | Out-Null
    $hasPip = ($LASTEXITCODE -eq 0)
    $ErrorActionPreference = 'Stop'
    return $hasPip
}
function Check-Esp32 {
    # Incomplete esptoolpy = unhealthy (pip failed during post-install)
    $esptoolpyDir  = Join-Path $Script:Workspace '.pio-core\packages\tool-esptoolpy'
    $esptoolpyJson = Join-Path $esptoolpyDir 'package.json'
    if ((Test-Path $esptoolpyDir) -and -not (Test-Path $esptoolpyJson)) { return $false }
    # Use filesystem check — pio platform list uses the default ~/.platformio dir,
    # not our custom .pio-core core_dir, so it always returns empty.
    $pkgsDir = Join-Path $Script:Workspace '.pio-core\packages'
    if (-not (Test-Path $pkgsDir)) { return $false }
    $toolchain = Get-ChildItem $pkgsDir -Directory -Filter 'toolchain-xtensa*' -ErrorAction SilentlyContinue |
                 Select-Object -First 1
    return ($null -ne $toolchain)
}
function Check-LibrariesHealth {
    $libdeps = Join-Path $Script:Workspace '.pio\libdeps'
    if (-not (Test-Path $libdeps)) { return $false }
    foreach ($lib in $Script:ExpectedLibs) {
        $pat = ($lib -split ' ')[0]
        $found = Get-ChildItem -Path $libdeps -Directory -Recurse -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -like "*$pat*" }
        if (-not $found) { return $false }
    }
    return $true
}
function Check-ProjectConfig {
    $pio = Join-Path $Script:Workspace 'platformio.ini'
    if (-not (Test-Path $pio)) { return $false }
    $content = Get-Content $pio -Raw
    ($content -match '(?m)^core_dir = \.pio-core') -and
    ($content -match '(?m)^src_dir = my_robot_code') -and
    ($content -match '(?m)^lib_extra_dirs = robot_core') -and
    $content.Contains("[env:$($Script:PioBoard)]") -and
    $content.Contains("board = $($Script:PioBoard)") -and
    $content.Contains("framework = $($Script:PioFramework)")
}

function Repair-Upstream      { Ensure-Upstream }
function Repair-WorkspaceDir  { Disable-GitInWorkspace }
function Repair-Content       { Sync-Workspace }
function Repair-StudentCode   { Seed-StudentCodeIfEmpty }
function Repair-VsCode        { Ensure-VsCode }
function Repair-Extensions    { Ensure-Extensions }
function Repair-Uv            { Ensure-Uv }
function Repair-PythonHealth  { Ensure-Python }
function Repair-PioVenv {
    # If PIO works but pip is missing, just seed pip — don't nuke the whole venv.
    if (Test-Path $Script:PioBin) {
        $ErrorActionPreference = 'SilentlyContinue'
        & $Script:PythonBin -m pip --version 2>$null | Out-Null
        $hasPip = ($LASTEXITCODE -eq 0)
        $ErrorActionPreference = 'Stop'
        if (-not $hasPip) {
            Write-Status REPAIR 'Seeding pip into .venv (PlatformIO intact)'
            $ErrorActionPreference = 'SilentlyContinue'
            & $Script:PythonBin -m ensurepip --upgrade 2>$null | Out-Null
            $ErrorActionPreference = 'Stop'
            return
        }
    }
    Remove-Item $Script:VenvDir -Recurse -Force -ErrorAction SilentlyContinue
    Ensure-Venv
    Ensure-PlatformIO
}
function Repair-Esp32         { Ensure-Esp32Platform }
function Repair-LibrariesHealth { Ensure-Libraries }
function Repair-ProjectConfig { Sync-Workspace }

function Ensure-PioOnPath {
    $venvScripts = Join-Path $Script:VenvDir 'Scripts'
    $rawPath = [Environment]::GetEnvironmentVariable('PATH', 'User')
    $parts   = if ($rawPath) { $rawPath -split ';' | Where-Object { $_ -ne '' } } else { @() }
    # Remove stale entries left from a workspace move (old Desktop or home path).
    $parts   = @($parts | Where-Object { $_ -notlike '*YSP_TDCS_Makerspace*\.venv*' })
    if ($parts -notcontains $venvScripts) {
        $newPath = ((@($venvScripts) + $parts) -join ';').TrimEnd(';')
        [Environment]::SetEnvironmentVariable('PATH', $newPath, 'User')
        Write-Status OK 'PlatformIO added to user PATH'
    }
    # Also update the current session so child processes (VS Code) see the change immediately.
    if ($env:PATH -notlike "*$venvScripts*") {
        $env:PATH = $venvScripts + ';' + $env:PATH
    }
}
function Check-PioPath {
    $venvScripts = Join-Path $Script:VenvDir 'Scripts'
    $path = [Environment]::GetEnvironmentVariable('PATH', 'User')
    return $path -and (($path -split ';') -contains $venvScripts)
}
function Repair-PioPath { Ensure-PioOnPath }

$Script:HealthChecks = @(
    @{ Label='hidden_content_cache';  Check='Check-Upstream';        Repair='Repair-Upstream' },
    @{ Label='student_workspace';     Check='Check-WorkspaceDir';    Repair='Repair-WorkspaceDir' },
    @{ Label='content_files';         Check='Check-ContentMatch';    Repair='Repair-Content' },
    @{ Label='student_code_area';     Check='Check-MyRobotCode';     Repair='Repair-StudentCode' },
    @{ Label='vscode';                Check='Check-VsCode';          Repair='Repair-VsCode' },
    @{ Label='vscode_extensions';     Check='Check-ExtensionsHealth';Repair='Repair-Extensions' },
    @{ Label='uv';                    Check='Check-Uv';              Repair='Repair-Uv' },
    @{ Label='python_3_11';           Check='Check-PythonHealth';    Repair='Repair-PythonHealth' },
    @{ Label='platformio_venv';       Check='Check-PioVenv';         Repair='Repair-PioVenv' },
    @{ Label='pio_path';              Check='Check-PioPath';          Repair='Repair-PioPath' },
    @{ Label='esp32_platform';        Check='Check-Esp32';           Repair='Repair-Esp32' },
    @{ Label='libraries';             Check='Check-LibrariesHealth'; Repair='Repair-LibrariesHealth' },
    @{ Label='project_config';        Check='Check-ProjectConfig';   Repair='Repair-ProjectConfig' }
)

function Invoke-AllHealthChecks {
    param([switch]$Quiet)
    $allOk = $true
    foreach ($entry in $Script:HealthChecks) {
        $ok = & $entry.Check
        if ($ok) {
            if (-not $Quiet) { Write-Status OK $entry.Label }
        } else {
            $allOk = $false
            if ($Quiet) { return $false }
            Write-Status FAIL $entry.Label
            Write-Status REPAIR $entry.Label
            try { & $entry.Repair } catch { Write-Status FAIL "Repair failed: $($entry.Label) ($_)" ; return $false }
            $okAfter = & $entry.Check
            if ($okAfter) { Write-Status OK "$($entry.Label) (repaired)" }
            else { Write-Status FAIL "Still failing after repair: $($entry.Label)"; return $false }
        }
    }
    return $allOk
}


function Print-PortGuidance {
    if (Test-Path $Script:PioBin) {
        $list = & $Script:PioBin device list 2>$null
        if ($list) { Write-Log 'device list:'; Write-Log ($list -join "`n") }
    }
    Write-Status INFO 'If your XIAO is plugged in, look for a COM port (USB Serial / Espressif).'
    Write-Status INFO 'If your XIAO ESP32C3 does not appear after plugging in, try a different USB-C DATA cable.'
}

# =============================================================================
#  FINAL SUMMARY + OPEN VS CODE
# =============================================================================

function Write-FinalSummary {
    $header = switch ($Script:Mode) {
        'first_run' { 'YSP TDCS Makerspace — Setup Complete' }
        'daily'     { 'YSP TDCS Makerspace — Ready' }
        'repair'    { 'YSP TDCS Makerspace — Repair' }
        default     { 'YSP TDCS Makerspace' }
    }
    Write-Host ''
    Write-Host '━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━' -ForegroundColor Magenta
    Write-Host '             [ Final Summary ]'
    Write-Host '━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━' -ForegroundColor Magenta
    Write-Host ''
    Write-Host $header
    Write-Host ''
    Write-Host "  OK      $($Script:CountOk)"     -ForegroundColor Green
    Write-Host "  SKIP    $($Script:CountSkip)"   -ForegroundColor DarkGray
    Write-Host "  REPAIR  $($Script:CountRepair)" -ForegroundColor Yellow
    Write-Host "  FAIL    $($Script:CountFail)"   -ForegroundColor Red
    Write-Host ''
    Write-Host "  Workspace: $($Script:Workspace)"
    Write-Host "  Log:       $($Script:WorkspaceLog)"
    if ($Script:CountFail -gt 0) {
        Write-Host ''
        Write-Host '  Failed steps:' -ForegroundColor Red
        foreach ($s in $Script:FailedSteps) { Write-Host "    - $s" }
        Write-Host ''
        Write-Host '  Setup incomplete — show this screen to an instructor.'
    } else {
        Write-Host ''
        switch ($Script:Mode) {
            'first_run' { Write-Host '  All good. Call an instructor to flash your first sketch.' }
            'daily'     { Write-Host '  Ready to go.' }
            'repair'    { Write-Host '  Environment repaired.' }
        }
    }
    Write-Host ''
    Write-Host "  Full log saved to $($Script:WorkspaceLog)"
}

function Configure-VsCodeUserSettings {
    $userDir = Join-Path $env:APPDATA 'Code\User'
    if (-not (Test-Path $userDir)) { New-Item -ItemType Directory -Path $userDir -Force | Out-Null }
    $f   = Join-Path $userDir 'settings.json'
    $obj = if (Test-Path $f) {
        try { Get-Content $f -Raw | ConvertFrom-Json } catch { [pscustomobject]@{} }
    } else { [pscustomobject]@{} }

    # User-level keys are kept narrow on purpose: only things that MUST take
    # effect before any workspace has loaded (trust dialog, chat panel that
    # autostarts globally, PIO Home auto-popup on extension activation,
    # startup walkthrough). Editor / window restoration is workspace-scoped
    # and lives in setup/.vscode/settings.json instead — touching them here
    # would change behavior for unrelated VS Code workspaces on the student's
    # machine.
    $keys = @{
        # Trust / startup chrome.
        'security.workspace.trust.enabled'                = $false
        'workbench.startupEditor'                         = 'none'
        'workbench.welcomePage.walkthroughs.openOnInstall'= $false
        'workbench.tips.enabled'                          = $false
        'update.showReleaseNotes'                         = $false
        'extensions.ignoreRecommendations'                = $true

        # Chat / auxiliary side bar — the built-in Chat extension auto-shows
        # its view regardless of which workspace is open, so suppression must
        # be user-level.
        'workbench.secondarySideBar.visible'              = $false
        'workbench.auxiliaryBar.visible'                  = $false
        'chat.commandCenter.enabled'                      = $false
        'chat.editor.enabled'                             = $false
        'chat.experimental.offerSetup'                    = $false
        'chat.setupFromDialog'                            = $false
        'chat.welcomeView.enabled'                        = $false

        # PlatformIO — PIO Home pops up on first activation before workspace
        # settings load, so user-level is the only reliable place to disable it.
        'platformio-ide.customPATH'                       = (Join-Path $Script:VenvDir 'Scripts')
        'platformio-ide.disablePIOHomeStartup'            = $true
        'platformio-ide.activateOnlyOnPlatformIOProject'  = $true
        'platformio-ide.autoOpenPlatformIOIniFile'        = $false
        'platformio-ide.useBuiltinPIOCore'                = $false
    }
    foreach ($k in $keys.Keys) {
        $obj | Add-Member -NotePropertyName $k -NotePropertyValue $keys[$k] -Force
    }
    [System.IO.File]::WriteAllText($f, ($obj | ConvertTo-Json -Depth 20), [System.Text.UTF8Encoding]::new($false))
}

# Returns the workspace-storage folder VS Code uses for our workspace, or $null.
# VS Code hashes the workspace URI (file:///C:/Users/.../YSP_TDCS_Makerspace) with
# MD5 and stores per-workspace layout state (including auxiliary-bar visibility)
# under %APPDATA%/Code/User/workspaceStorage/<hash>/.
function Get-VsCodeWorkspaceStorageDir {
    $base = Join-Path $env:APPDATA 'Code\User\workspaceStorage'
    if (-not (Test-Path $base)) { return $null }
    # Build the file URI VS Code uses (forward slashes, lower-case drive letter).
    $abs = (Resolve-Path $Script:Workspace -ErrorAction SilentlyContinue).Path
    if (-not $abs) { return $null }
    $uri = 'file:///' + ($abs -replace '\\','/')
    if ($uri -match '^(file:///)([A-Za-z]):') {
        $uri = "$($matches[1])$($matches[2].ToLower()):" + $uri.Substring($matches[0].Length)
    }
    $md5 = [System.Security.Cryptography.MD5]::Create()
    try {
        $bytes = [System.Text.Encoding]::UTF8.GetBytes($uri)
        $hash  = ($md5.ComputeHash($bytes) | ForEach-Object { $_.ToString('x2') }) -join ''
    } finally { $md5.Dispose() }
    $dir = Join-Path $base $hash
    if (Test-Path $dir) { return $dir }
    return $null
}

# Clear the prior auxiliary-bar visibility so the chat panel does not reappear
# when VS Code restores layout state. Best-effort: success when the dir is gone
# or when the layout state file is missing.
function Reset-VsCodeAuxBarState {
    $dir = Get-VsCodeWorkspaceStorageDir
    if (-not $dir) { return }
    # The auxiliary bar visibility lives inside state.vscdb (SQLite); we don't
    # ship sqlite3 on Windows. Removing the whole workspace-storage dir is safe:
    # VS Code rebuilds it on next launch with the values from user/workspace
    # settings, which now insist on a hidden aux bar.
    try {
        Remove-Item -Path $dir -Recurse -Force -ErrorAction Stop
        Write-Log "Reset VS Code workspace state: $dir"
    } catch {
        Write-Log "Could not reset VS Code workspace state: $_"
    }
}

# Probe whether the installed code CLI accepts a given flag, by running
# `code --help` once and grepping. Cached per-flag for the session.
$Script:CodeFlagCache = @{}
function Test-CodeFlagSupported {
    param([Parameter(Mandatory)][string]$Flag)
    if ($Script:CodeFlagCache.ContainsKey($Flag)) { return $Script:CodeFlagCache[$Flag] }
    $supported = $false
    try {
        $help = (& code --help 2>$null) -join "`n"
        $supported = $help -match [regex]::Escape($Flag)
    } catch { $supported = $false }
    $Script:CodeFlagCache[$Flag] = $supported
    return $supported
}

function Open-VsCode-IfSafe {
    if (-not (Test-Path $Script:Workspace) -or -not (Test-Path $Script:StudentCodeDir)) {
        Write-Status WARN 'Skipping VS Code — workspace incomplete'
        return
    }
    if (-not (Get-Command code -ErrorAction SilentlyContinue)) {
        Write-Status WARN "code CLI not found; run manually: code $($Script:Workspace)"
        return
    }
    if ($Script:CountFail -gt 0 -and $Script:Mode -eq 'first_run') {
        Write-Status WARN 'Setup incomplete — not opening VS Code automatically'
        return
    }

    Configure-VsCodeUserSettings
    # Clean per-workspace layout state ONLY on first_run so the chat aux bar
    # does not restore from a previous launch. On daily/repair runs we trust
    # the user-level settings to keep chat hidden; nuking the storage every
    # run would also erase editor tabs, breakpoints, and search history.
    if ($Script:Mode -eq 'first_run') { Reset-VsCodeAuxBarState }

    # Open as single-root folder so PIO workspaceContains:platformio.ini activates.
    # Use cmd /c so code.cmd doesn't block the PowerShell process.
    $codeArgs = @($Script:Workspace)
    $codeFile = Join-Path $Script:StudentCodeDir 'main.cpp'
    if (Test-Path $codeFile) { $codeArgs += $codeFile }
    # Newer VS Code (1.94+) supports --disable-chat-setup; older ones silently error.
    if (Test-CodeFlagSupported '--disable-chat-setup') {
        $codeArgs = @('--disable-chat-setup') + $codeArgs
    }
    try {
        $quotedArgs = ($codeArgs | ForEach-Object { '"' + ($_ -replace '"','\"') + '"' }) -join ' '
        Start-Process -FilePath 'cmd.exe' -ArgumentList "/c code $quotedArgs" -WindowStyle Hidden
        Write-Status OK 'Opened VS Code'
    } catch {
        Write-Status WARN "VS Code did not open: $_"
    }
}

# =============================================================================
#  WORKSPACE MIGRATION
# =============================================================================

function Migrate-WorkspaceIfNeeded {
    # Older installs lived at ~/YSP_TDCS_Makerspace; move to Desktop on first run
    # after this change so existing students don't lose their work.
    $oldWs = Join-Path $HOME 'YSP_TDCS_Makerspace'
    if (-not (Test-Path $oldWs)) { return }
    if (Test-Path $Script:Workspace) { return }
    $parentDir = Split-Path $Script:Workspace -Parent
    if (-not (Test-Path $parentDir)) { return }
    Write-Status INFO "Moving workspace to Desktop..."
    try {
        Move-Item -Path $oldWs -Destination $Script:Workspace -Force
        Write-Status OK "Workspace moved to Desktop"
    } catch {
        Write-Status WARN "Could not move workspace automatically: $_"
    }
}

# =============================================================================
#  MAIN
# =============================================================================

function Invoke-Main {
    Initialize-Console
    Start-SetupLog
    Ensure-ElevationIfNeeded
    Migrate-WorkspaceIfNeeded
    Run-LocalBootstrapChecks

    # Silent local assessment — no network, no repair output.
    $isFirstRun = -not (Test-Path $Script:Workspace) -or
                  -not (Test-Path $Script:VenvDir) -or
                  -not (Test-Path $Script:PioBin) -or
                  -not (Test-Path (Join-Path $Script:UpstreamDir '.git'))
    $ErrorActionPreference = 'SilentlyContinue'
    $allHealthy = if (-not $isFirstRun) { Invoke-AllHealthChecks -Quiet } else { $false }
    $ErrorActionPreference = 'Stop'
    $Script:Mode = if ($isFirstRun) { 'first_run' } elseif ($allHealthy) { 'daily' } else { 'repair' }
    Write-Log "Detected mode: $($Script:Mode)"

    # Bring in network resources only when something needs downloading or repairing.
    if (-not $allHealthy) { Run-NetworkBootstrapChecks }

    switch ($Script:Mode) {
        'first_run' {
            Show-FirstRunPlan
            # Gate dependent phases on critical-prerequisite outcomes. When a
            # foundation step fails, downstream phases would only multiply the
            # error count without giving the student new information; we stop
            # and let the final summary show one actionable failure.
            Write-Phase 'Preflight' -Step 1 -Total 7
            Discover-Mirror

            Write-Phase 'Python toolchain' -Step 2 -Total 7
            Ensure-Uv
            if (-not (Get-Command uv -ErrorAction SilentlyContinue)) {
                Write-Status FAIL 'uv missing — halting install (rest of phases would only echo this)'
                Stop-Phase
                Write-FinalSummary
                Open-VsCode-IfSafe
                return
            }
            Ensure-Python

            Write-Phase 'Workspace' -Step 3 -Total 7
            Ensure-Upstream; Sync-Workspace
            Disable-GitInWorkspace; Seed-StudentCodeIfEmpty
            Ensure-Venv; Ensure-PlatformIO; Ensure-PioOnPath
            $pioReady = Test-Path $Script:PioBin
            if (-not $pioReady) {
                Write-Status FAIL 'PlatformIO missing — skipping ESP32 platform, libraries, and smoke test'
            }

            Write-Phase 'ESP32 platform (~500 MB)' -Step 4 -Total 7
            if ($pioReady) { Ensure-Esp32Platform } else { Write-Status SKIP 'ESP32 platform (PIO unavailable)' }
            $esp32Ready = $pioReady -and (
                (Test-Path (Join-Path $Script:Workspace '.pio-core\packages')) -and
                @(Get-ChildItem (Join-Path $Script:Workspace '.pio-core\packages') `
                    -Directory -Filter 'toolchain-xtensa*' -ErrorAction SilentlyContinue).Count -gt 0
            )

            Write-Phase 'VS Code' -Step 5 -Total 7
            Ensure-VsCode

            Write-Phase 'Libraries + extensions (parallel)' -Step 6 -Total 7
            if ($pioReady) {
                Invoke-ParallelLibsAndExtensions
            } else {
                # Skip libs (PIO unavailable) but still install extensions so
                # the student at least gets the editor + PIO toolbar wired up.
                Write-Status SKIP 'Libraries (PIO unavailable)'
                Ensure-Extensions
            }

            Write-Phase 'Smoke test' -Step 7 -Total 7
            if ($pioReady -and $esp32Ready) {
                Run-SmokeTest | Out-Null
            } else {
                Write-Status SKIP 'Smoke test (PIO/ESP32 toolchain unavailable)'
            }
            Stop-Phase
        }
        'repair' {
            Write-Phase 'Repair'
            Ensure-Upstream; Sync-Workspace
            Invoke-AllHealthChecks | Out-Null
            Stop-Phase
        }
        'daily' {
            Write-Phase 'Daily sync'
            Ensure-Upstream; Sync-Workspace; Seed-StudentCodeIfEmpty
            Print-PortGuidance
            Stop-Phase
        }
    }

    Write-FinalSummary
    Open-VsCode-IfSafe
}

function Show-FirstRunPlan {
    Write-Host ''
    if ($Script:UseColor) {
        Write-Host '  First-time setup — here is what will happen:' -ForegroundColor White
        Write-Host '  (about 10-15 minutes on a fast network)' -ForegroundColor DarkGray
    } else {
        Write-Host '  First-time setup — here is what will happen:'
        Write-Host '  (about 10-15 minutes on a fast network)'
    }
    $steps = @(
        @('1','Preflight',              '~10s',   'check internet, disk, clock'),
        @('2','Python toolchain',       '1-2 min','install uv + Python 3.11'),
        @('3','Workspace',              '30-60s', 'clone class content, create .venv, install PlatformIO'),
        @('4','ESP32 platform',         '3-5 min','download 500 MB toolchain'),
        @('5','VS Code',                '1-2 min','install VS Code (if missing)'),
        @('6','Libraries + extensions', '1-2 min','parallel: 6 Arduino libs + 3 VS Code extensions'),
        @('7','Smoke test',             '30s',    'verify the toolchain compiles a tiny sketch')
    )
    foreach ($s in $steps) {
        if ($Script:UseColor) {
            Write-Host ('    ') -NoNewline
            Write-Host ($s[0] + '.') -ForegroundColor Magenta -NoNewline
            Write-Host (' {0,-26}' -f $s[1]) -ForegroundColor White -NoNewline
            Write-Host ('{0,-10}' -f $s[2]) -ForegroundColor Yellow -NoNewline
            Write-Host $s[3] -ForegroundColor DarkGray
        } else {
            Write-Host ('    {0}. {1,-26} {2,-10} {3}' -f $s[0],$s[1],$s[2],$s[3])
        }
    }
    Write-Host ''
}

# TDCS_TEST_NO_MAIN suppresses Invoke-Main so Pester can dot-source this file.
if (-not $env:TDCS_TEST_NO_MAIN) { Invoke-Main }
