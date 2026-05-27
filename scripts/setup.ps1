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

$Script:MinDiskGbHard           = 3
$Script:MinDiskGbWarn           = 5
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
    '.vscode',
    'ronnie-robot.code-workspace'
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
    'ms-vscode.cpptools',
    'ms-vscode.vscode-serial-monitor'
)

# Hidden script-owned state.
$Script:StateDir       = Join-Path $HOME '.tdsc_makerspace_setup'
$Script:UpstreamDir    = Join-Path $Script:StateDir 'upstream'
$Script:SmokeDir       = Join-Path $Script:StateDir 'smoke\xiao_esp32c3'
$Script:BootstrapLog   = Join-Path $Script:StateDir 'setup_bootstrap.log'
$Script:MirrorCache    = Join-Path $Script:StateDir 'mirror_cache'
$Script:MirrorManifest = Join-Path $Script:MirrorCache 'manifest.json'

# Student-facing workspace.
$Script:Workspace        = Join-Path $HOME 'YSP_TDCS_Makerspace'
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

function Run-BootstrapChecks {
    Test-PowerShellVersion
    Enable-Tls12
    Check-DiskSpace
    Check-ClockSkew
    Check-WriteAccess
    Check-HttpsReachable
    Discover-Mirror
    Add-DefenderExclusions
    Enable-LongPaths
    Ensure-Git
}

# =============================================================================
#  TASK 14 — MIRROR CONSUMPTION
# =============================================================================

function Get-MirrorEntry {
    param([string]$Category, [string]$Name)
    if (-not $Script:MirrorBase) { return $null }
    if (-not (Test-Path $Script:MirrorManifest)) { return $null }
    Get-Content $Script:MirrorManifest -Raw |
        ForEach-Object {
            $matches = [regex]::Matches(
                $_,
                '\{"category":"' + [regex]::Escape($Category) + '","name":"' + [regex]::Escape($Name) + '"[^}]+\}'
            )
            if ($matches.Count -gt 0) {
                $entry = $matches[0].Value
                $url = ([regex]::Match($entry, '"url":"([^"]+)"')).Groups[1].Value
                $sha = ([regex]::Match($entry, '"sha256":"([^"]+)"')).Groups[1].Value
                return [pscustomobject]@{ Url = $url; Sha256 = $sha }
            }
        }
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

function Ensure-VenvAndPio { Ensure-Venv; Ensure-PlatformIO }

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
    $ErrorActionPreference = 'SilentlyContinue'
    $list = & $Script:PioBin platform list --json-output 2>$null
    $ErrorActionPreference = 'Stop'
    if ($list -match [regex]::Escape($Script:PioPlatformPin)) {
        Write-Status SKIP "$($Script:PioPlatformPin) already installed"
        return
    }
    Write-Status INSTALL 'Downloading ESP32 toolchain (~500 MB) — 3-5 minutes, please wait...'
    $rc = Invoke-LoggedCommand -Label 'pio platform install' -Command $Script:PioBin `
        -ArgumentList @('platform','install',$Script:PioPlatformPin) `
        -WorkingDir $Script:Workspace
    if ($rc -ne 0) { Write-Status FAIL 'ESP32 platform install failed'; return }
    Write-Status OK 'ESP32 platform installed'
}

function Ensure-Libraries {
    if (-not (Test-Path (Join-Path $Script:Workspace 'platformio.ini'))) {
        Write-Status FAIL 'platformio.ini missing'; return
    }
    $rc = Invoke-LoggedCommand -Label 'pio pkg install' -Command $Script:PioBin `
        -ArgumentList @('pkg','install') -WorkingDir $Script:Workspace
    if ($rc -ne 0) { Write-Status FAIL 'pio pkg install failed'; return }

    $libdeps = Join-Path $Script:Workspace '.pio\libdeps'
    if (-not (Test-Path $libdeps)) { Write-Status FAIL 'libdeps directory missing'; return }
    $missing = 0
    foreach ($lib in $Script:ExpectedLibs) {
        $pat = ($lib -split ' ')[0]
        $found = Get-ChildItem -Path $libdeps -Directory -Recurse -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -like "*$pat*" }
        if (-not $found) { Write-Status FAIL "Library missing: $lib"; $missing++ }
    }
    if ($missing -eq 0) {
        Write-Status OK "Libraries installed: $($Script:ExpectedLibs.Count)/$($Script:ExpectedLibs.Count)"
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
    $installer = Join-Path $Script:StateDir 'VSCodeSetup.exe'
    $internet = 'https://code.visualstudio.com/sha/download?build=stable&os=win32-x64-user'
    Write-Status INSTALL 'Downloading VS Code'
    if (-not (Fetch-Artifact 'vscode' 'VSCodeSetup-x64.exe' $internet $installer)) {
        Write-Status FAIL 'VS Code download failed'; return
    }
    $args = @('/VERYSILENT','/NORESTART','/MERGETASKS=!desktopicon,!quicklaunchicon,!associatewithfiles,!addcontextmenufiles,!addcontextmenufolders,addtopath')
    $rc = Invoke-LoggedCommand -Label 'vscode install' -Command $installer -ArgumentList $args
    if ($rc -ne 0) { Write-Status FAIL "VS Code installer exited $rc"; return }
    Refresh-Path
    if (Get-Command code -ErrorAction SilentlyContinue) {
        Write-Status OK 'VS Code installed (no desktop icon, no context menus)'
    } else {
        Write-Status FAIL 'VS Code not on PATH after install — open a fresh PowerShell window'
    }
}

function Ensure-Extensions {
    if (-not (Get-Command code -ErrorAction SilentlyContinue)) {
        Write-Status FAIL 'code CLI not on PATH'; return
    }
    $installed = (& code --list-extensions 2>$null) | ForEach-Object { $_.ToLower() }
    foreach ($ext in $Script:VscodeExts) {
        if ($installed -contains $ext.ToLower()) {
            Write-Status SKIP "ext $ext"; continue
        }
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
            $rc = Invoke-LoggedCommand -Label "ext install $Ext (vsix)" -Command 'code' `
                -ArgumentList @('--install-extension',$vsix)
            if ($rc -eq 0) { Write-Status OK "ext $Ext"; return $true }
        }
    }
    $rc = Invoke-LoggedCommand -Label "ext install $Ext (marketplace)" -Command 'code' `
        -ArgumentList @('--install-extension',$Ext)
    if ($rc -eq 0) { Write-Status OK "ext $Ext"; return $true }
    return $false
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
    $coreDir = (Join-Path $Script:Workspace '.pio-core') -replace '\\','\\'
    $smokeIni = @"
[platformio]
core_dir = $coreDir

[env:$($Script:PioBoard)]
platform = $($Script:PioPlatformPin)
board = $($Script:PioBoard)
framework = $($Script:PioFramework)
monitor_speed = $($Script:MonitorSpeed)
upload_speed = $($Script:UploadSpeed)
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
    # Incomplete esptoolpy package (pip failed during post-install) = unhealthy
    $esptoolpyDir  = Join-Path $Script:Workspace '.pio-core\packages\tool-esptoolpy'
    $esptoolpyJson = Join-Path $esptoolpyDir 'package.json'
    if ((Test-Path $esptoolpyDir) -and -not (Test-Path $esptoolpyJson)) { return $false }
    if (-not (Test-Path $Script:PioBin)) { return $false }
    $ErrorActionPreference = 'SilentlyContinue'
    $list = & $Script:PioBin platform list --json-output 2>$null
    $ErrorActionPreference = 'Stop'
    if (-not $list) { return $false }
    ($list -join '') -match [regex]::Escape($Script:PioPlatformPin)
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

function Detect-SetupMode {
    if (-not (Test-Path $Script:Workspace) -or
        -not (Test-Path $Script:VenvDir) -or
        -not (Test-Path $Script:PioBin) -or
        -not (Test-Path (Join-Path $Script:UpstreamDir '.git'))) {
        return 'first_run'
    }
    $ErrorActionPreference = 'SilentlyContinue'
    $ok = Invoke-AllHealthChecks -Quiet
    $ErrorActionPreference = 'Stop'
    if ($ok) { 'daily' } else { 'repair' }
}

function Run-SetupMode {
    param([string]$Mode)
    switch ($Mode) {
        'first_run' {
            Write-Status INFO 'First run — installing everything (10-15 minutes)'
            Ensure-Uv
            Ensure-Python
            Ensure-Upstream
            Sync-Workspace
            Disable-GitInWorkspace
            Seed-StudentCodeIfEmpty
            Ensure-Venv
            Ensure-PlatformIO
            Ensure-Esp32Platform
            Ensure-Libraries
            Ensure-VsCode
            Ensure-Extensions
            Run-SmokeTest | Out-Null
        }
        'daily' {
            Ensure-Upstream
            Sync-Workspace
            Seed-StudentCodeIfEmpty
            Invoke-AllHealthChecks | Out-Null
            Print-PortGuidance
        }
        'repair' {
            Write-Status INFO 'Repairing environment'
            Ensure-Upstream
            Sync-Workspace
            Invoke-AllHealthChecks | Out-Null
        }
        default { Write-Status FAIL "Unknown mode: $Mode" }
    }
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

    $workspaceFile = Join-Path $Script:Workspace 'ronnie-robot.code-workspace'

    if (Test-Path $workspaceFile) {
        $codeArgs = @($workspaceFile)
        if ($Script:Mode -eq 'first_run') { $codeArgs += (Join-Path $Script:Workspace 'QUICKSTART.md') }
        $codeFile = Join-Path $Script:StudentCodeDir 'main.cpp'
        if (Test-Path $codeFile) { $codeArgs += $codeFile }
        try {
            & code @codeArgs
            Write-Status OK 'Opened RonnieRobot workspace'
        } catch {
            Write-Status WARN "VS Code did not open: $_"
        }
    } else {
        Write-Status WARN 'No workspace file — opening workspace folder'
        try { & code $Script:Workspace }
        catch { Write-Status WARN "VS Code did not open: $_" }
    }
}

# =============================================================================
#  MAIN
# =============================================================================

function Invoke-Main {
    Initialize-Console
    Start-SetupLog
    Ensure-ElevationIfNeeded
    Run-BootstrapChecks
    $Script:Mode = Detect-SetupMode
    Write-Log "Detected mode: $($Script:Mode)"
    Run-SetupMode $Script:Mode
    Write-FinalSummary
    Open-VsCode-IfSafe
}

# TDCS_TEST_NO_MAIN suppresses Invoke-Main so Pester can dot-source this file.
if (-not $env:TDCS_TEST_NO_MAIN) { Invoke-Main }
