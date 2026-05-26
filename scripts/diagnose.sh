#!/usr/bin/env bash
# YSP TDCS Makerspace — diagnostic script (macOS / Linux).
#
# READ-ONLY. This script must never install, repair, sync, rename .git, add
# users to groups, or modify the system. It only reports what setup would
# need to fix. The check predicates here are deliberately copied from
# setup.sh — diagnose must run even when setup.sh is broken.

set -uo pipefail
IFS=$'\n\t'

# =============================================================================
#  CONFIG  —  mirrors setup.sh. Read-only fields only.
# =============================================================================

DIAG_VERSION="2026.05.0"

REPO_URL="https://github.com/Makerspace-Ashoka/YSP_TDCS_CodeAlong_2026.git"
PYTHON_VERSION="3.11"
PIO_BOARD="seeed_xiao_esp32c3"
PIO_FRAMEWORK="arduino"
PIO_PLATFORM_PIN="platformio/espressif32@7.0.1"

MIN_DISK_GB_HARD=5
MIN_VSCODE_VERSION_MAJOR=1
MIN_VSCODE_VERSION_MINOR=90
MAX_CLOCK_SKEW_SEC=300

INSTRUCTOR_PATHS=(robot_core platformio.ini .python-version requirements.txt QUICKSTART.md .vscode ronnie-robot.code-workspace)

EXPECTED_LIBS=("Adafruit PWM Servo Driver Library" "Adafruit BusIO" "NewPing" "ArduinoJson" "ESP32Servo" "Adafruit NeoPixel")
VSCODE_EXTS=(platformio.platformio-ide ms-vscode.cpptools ms-vscode.vscode-serial-monitor)

STATE_DIR="$HOME/.tdsc_makerspace_setup"
UPSTREAM_DIR="$STATE_DIR/upstream"
WORKSPACE="$HOME/YSP_TDCS_Makerspace"
STUDENT_CODE_DIR="$WORKSPACE/my_robot_code"
DIAG_STATE="$WORKSPACE/.tdcs_setup_state.json"
VENV_DIR="$WORKSPACE/.venv"
PIO_BIN="$VENV_DIR/bin/pio"
PYTHON_BIN="$VENV_DIR/bin/python"

OS=""
ARCH=""
TOTAL=0
FAILED=0

# =============================================================================
#  CONSOLE
# =============================================================================

_supports_color() {
    [[ -t 1 ]] || return 1
    [[ -z "${NO_COLOR:-}" ]] || return 1
    command -v tput >/dev/null 2>&1 || return 1
    (( $(tput colors 2>/dev/null || echo 0) >= 8 ))
}

if _supports_color; then
    C_RESET=$(tput sgr0); C_BOLD=$(tput bold); C_DIM=$(tput dim 2>/dev/null || echo "")
    C_RED=$(tput setaf 1); C_GREEN=$(tput setaf 2); C_YELLOW=$(tput setaf 3); C_MAGENTA=$(tput setaf 5)
else
    C_RESET=""; C_BOLD=""; C_DIM=""; C_RED=""; C_GREEN=""; C_YELLOW=""; C_MAGENTA=""
fi

banner() {
    printf '%s━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━%s\n' "$C_MAGENTA" "$C_RESET"
    printf '%s  YSP Diagnostics — %s%s\n' "$C_BOLD" "$DIAG_VERSION" "$C_RESET"
    printf '%s━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━%s\n' "$C_MAGENTA" "$C_RESET"
}

# report LABEL STATUS [DETAIL]
#   STATUS ∈ {pass, fail}
report() {
    local label=$1 stat=$2 detail=${3:-}
    TOTAL=$((TOTAL + 1))
    if [[ "$stat" == pass ]]; then
        printf '  %-26s %s✓%s  %s\n' "$label" "$C_GREEN" "$C_RESET" "$detail"
    else
        FAILED=$((FAILED + 1))
        printf '  %-26s %s✗%s  %s\n' "$label" "$C_RED" "$C_RESET" "$detail"
    fi
}

# =============================================================================
#  CHECKS — all return 0 if healthy, 1 otherwise. NEVER mutate state.
# =============================================================================

check_os() {
    case "$(uname -s)" in
        Darwin) OS=mac ;;
        Linux)  OS=linux ;;
        *) return 1 ;;
    esac
    case "$(uname -m)" in
        arm64|aarch64) ARCH=arm64 ;;
        x86_64|amd64)  ARCH=x86_64 ;;
        *) return 1 ;;
    esac
}

check_disk_space() {
    local kb=$(df -k "$HOME" 2>/dev/null | awk 'NR==2 {print $4}')
    local gb=$(( kb / 1024 / 1024 ))
    DISK_GB=$gb
    (( gb >= MIN_DISK_GB_HARD ))
}

_http_date_to_epoch() {
    local d=$1
    if date -u -d "$d" +%s 2>/dev/null; then return; fi
    date -u -j -f "%a, %d %b %Y %H:%M:%S %Z" "$d" +%s 2>/dev/null
}

check_clock() {
    local hdr remote_epoch local_epoch skew
    hdr=$(curl -sSI --max-time 5 https://github.com 2>/dev/null \
        | awk -F': ' 'tolower($1)=="date" {sub(/\r$/,"",$2); print $2; exit}')
    [[ -n "$hdr" ]] || return 1
    remote_epoch=$(_http_date_to_epoch "$hdr")
    [[ -n "$remote_epoch" ]] || return 1
    local_epoch=$(date -u +%s)
    skew=$(( local_epoch - remote_epoch ))
    skew=${skew#-}
    CLOCK_SKEW=$skew
    (( skew <= MAX_CLOCK_SKEW_SEC ))
}

check_https()    { curl -fsS --max-time 5 -o /dev/null https://github.com; }

check_mirror()   { curl -fsS --max-time 2 "http://ysp-mirror.local:8080/ping" >/dev/null 2>&1; }

check_workspace() {
    [[ -d "$WORKSPACE" && -d "$STUDENT_CODE_DIR" ]] \
        && [[ -n "$(find "$STUDENT_CODE_DIR" -mindepth 1 -maxdepth 1 -type f 2>/dev/null)" ]]
}

check_workspace_git_disabled() {
    [[ ! -d "$WORKSPACE/.git" ]]
}

check_upstream() {
    [[ -d "$UPSTREAM_DIR/.git" ]] || return 1
    [[ "$(git -C "$UPSTREAM_DIR" remote get-url origin 2>/dev/null)" == "$REPO_URL" ]]
}

check_content_sync_uptodate() {
    # Read-only — reports whether HEAD matches origin/main as of the last
    # fetch that setup.sh performed. We DO NOT fetch here; that would mutate
    # the hidden clone's remote-tracking refs.
    [[ -d "$UPSTREAM_DIR/.git" ]] || return 1
    local local_head remote_head
    local_head=$(git -C "$UPSTREAM_DIR" rev-parse HEAD 2>/dev/null) || return 1
    remote_head=$(git -C "$UPSTREAM_DIR" rev-parse origin/main 2>/dev/null) || return 1
    [[ "$local_head" == "$remote_head" ]]
}

check_required_class_files() {
    local p
    for p in "${INSTRUCTOR_PATHS[@]}"; do
        [[ -e "$WORKSPACE/$p" ]] || return 1
    done
}

check_vscode() {
    command -v code >/dev/null 2>&1 || return 1
    local ver major minor
    ver=$(code --version 2>/dev/null | head -1) || return 1
    VSCODE_VER=$ver
    major=${ver%%.*}; minor=${ver#*.}; minor=${minor%%.*}
    (( major > MIN_VSCODE_VERSION_MAJOR )) || \
        (( major == MIN_VSCODE_VERSION_MAJOR && minor >= MIN_VSCODE_VERSION_MINOR ))
}

check_extension() {
    local ext=$1
    command -v code >/dev/null 2>&1 || return 1
    code --list-extensions 2>/dev/null | tr '[:upper:]' '[:lower:]' \
        | grep -qx "$(printf '%s' "$ext" | tr '[:upper:]' '[:lower:]')"
}

check_uv() {
    command -v uv >/dev/null 2>&1 || return 1
    uv --version >/dev/null 2>&1
}

check_python() {
    [[ -x "$PYTHON_BIN" ]] || return 1
    "$PYTHON_BIN" --version 2>&1 | grep -q "Python ${PYTHON_VERSION}\."
}

check_pio() {
    [[ -x "$PIO_BIN" ]] || return 1
    ( cd "$WORKSPACE" 2>/dev/null && "$PIO_BIN" --version >/dev/null 2>&1 )
}

check_esp32() {
    [[ -x "$PIO_BIN" ]] || return 1
    ( cd "$WORKSPACE" 2>/dev/null && "$PIO_BIN" platform list --json-output 2>/dev/null | grep -Fq "$PIO_PLATFORM_PIN" )
}

check_board_config() {
    [[ -f "$WORKSPACE/platformio.ini" ]] || return 1
    grep -q "^board = $PIO_BOARD" "$WORKSPACE/platformio.ini" \
        && grep -q "^framework = $PIO_FRAMEWORK" "$WORKSPACE/platformio.ini" \
        && grep -q '^src_dir = my_robot_code' "$WORKSPACE/platformio.ini" \
        && grep -q '^lib_extra_dirs = robot_core' "$WORKSPACE/platformio.ini"
}

check_libraries() {
    [[ -d "$WORKSPACE/.pio/libdeps" ]] || return 1
    local lib pat present=0
    for lib in "${EXPECTED_LIBS[@]}"; do
        pat="${lib%% *}"
        if find "$WORKSPACE/.pio/libdeps" -mindepth 2 -maxdepth 3 -type d \
                -iname "*${pat}*" 2>/dev/null | grep -q .; then
            present=$((present + 1))
        fi
    done
    LIBS_PRESENT=$present
    (( present == ${#EXPECTED_LIBS[@]} ))
}

XIAO_PORT_NO_PERM=0

check_xiao_port() {
    case "$OS" in
        mac)
            local ports
            ports=$(ls /dev/cu.usbmodem* 2>/dev/null; ls /dev/tty.usbmodem* 2>/dev/null)
            [[ -n "$ports" ]] && XIAO_PORT=$(echo "$ports" | head -1)
            [[ -n "${XIAO_PORT:-}" ]]
            ;;
        linux)
            local ports port
            ports=$(ls /dev/ttyACM* 2>/dev/null)
            [[ -n "$ports" ]] || return 1
            port=$(echo "$ports" | head -1)
            XIAO_PORT="$port"
            # Port exists — verify the user can write to it. Without the udev
            # rule (99-xiao-esp32c3.rules), /dev/ttyACM* is root:dialout 660
            # and esptool will fail with permission denied even though the port
            # appears in device listings.
            if ! test -w "$port"; then
                XIAO_PORT_NO_PERM=1
                return 1
            fi
            ;;
    esac
}

read_smoke_state() {
    [[ -f "$DIAG_STATE" ]] || return 1
    SMOKE_PASSED=$(grep -o '"passed":[[:space:]]*\(true\|false\)' "$DIAG_STATE" | sed 's/.*: *//')
    SMOKE_TIME=$(grep -o '"timestamp":[[:space:]]*"[^"]*"' "$DIAG_STATE" | head -1 | sed -E 's/.*"([^"]+)".*/\1/')
    [[ "$SMOKE_PASSED" == "true" ]]
}

# suggested_fix LABEL — one-liner the instructor can act on
suggested_fix() {
    case "$1" in
        "Workspace git disabled")    echo ".git exists in ~/YSP_TDCS_Makerspace — run setup again" ;;
        "Libraries")                 echo "${LIBS_PRESENT:-0}/${#EXPECTED_LIBS[@]} present — run setup again" ;;
        "XIAO USB port")             echo "no board detected — try a DATA USB-C cable" ;;
        "Content sync status")       echo "not up to date — run setup again" ;;
        "GitHub HTTPS")               echo "network blocking trusted HTTPS — try makerspace Wi-Fi or hotspot" ;;
        "Local mirror")              echo "not found — internet downloads will be slower" ;;
        "Last smoke test")           echo "previous compile failed — run setup again" ;;
        *)                            echo "run setup again" ;;
    esac
}

# =============================================================================
#  MAIN
# =============================================================================

banner

if check_os; then report "OS / architecture" pass "$OS $ARCH"
else                report "OS / architecture" fail "unsupported"; fi

if check_disk_space; then report "Disk space" pass "${DISK_GB:-?} GB free"
else                      report "Disk space" fail "${DISK_GB:-?} GB free (need ≥ $MIN_DISK_GB_HARD)"; fi

if check_clock; then report "Clock accuracy" pass "within ${CLOCK_SKEW:-?}s"
else                 report "Clock accuracy" fail "off by ${CLOCK_SKEW:-?}s — fix the date"; fi

if check_https; then report "GitHub HTTPS" pass ""
else                 report "GitHub HTTPS" fail "$(suggested_fix 'GitHub HTTPS')"; fi

if check_mirror; then report "Local mirror" pass "http://ysp-mirror.local:8080"
else                  report "Local mirror" pass "(none — using internet)"; fi

echo
if check_workspace; then report "Student workspace" pass "$WORKSPACE"
else                     report "Student workspace" fail "my_robot_code/ missing or empty — run setup"; fi

if check_workspace_git_disabled; then report "Workspace git disabled" pass ""
else                                  report "Workspace git disabled" fail "$(suggested_fix 'Workspace git disabled')"; fi

if check_upstream; then report "Hidden content cache" pass "origin → Makerspace-Ashoka/YSP_TDCS_CodeAlong_2026"
else                    report "Hidden content cache" fail "missing or wrong remote — run setup"; fi

if check_content_sync_uptodate; then report "Content sync status" pass "up to date with main"
else                                 report "Content sync status" fail "$(suggested_fix 'Content sync status')"; fi

if check_required_class_files; then report "Required class files" pass ""
else                                report "Required class files" fail "missing instructor files — run setup"; fi

echo
if check_vscode; then report "VS Code" pass "${VSCODE_VER:-?}"
else                  report "VS Code" fail "missing or outdated"; fi

for ext in "${VSCODE_EXTS[@]}"; do
    label="ext: $ext"
    if check_extension "$ext"; then report "$label" pass ""
    else                            report "$label" fail "missing — run setup"; fi
done

echo
if check_uv; then report "uv" pass "$(uv --version 2>/dev/null | awk '{print $2}')"
else              report "uv" fail "missing — run setup"; fi

if check_python; then report "Python $PYTHON_VERSION" pass "$($PYTHON_BIN --version 2>&1 | awk '{print $2}')"
else                  report "Python $PYTHON_VERSION" fail ".venv missing or wrong version"; fi

if check_pio; then report "PlatformIO" pass "$($PIO_BIN --version 2>&1 | awk '{print $NF}')"
else               report "PlatformIO" fail "not in .venv — run setup"; fi

if check_esp32; then report "Espressif32 platform" pass "pinned version installed"
else                 report "Espressif32 platform" fail "missing or wrong version — run setup"; fi

if check_board_config; then report "Board config" pass "$PIO_BOARD / $PIO_FRAMEWORK"
else                        report "Board config" fail "platformio.ini missing or wrong"; fi

if check_libraries; then report "Libraries" pass "${LIBS_PRESENT:-${#EXPECTED_LIBS[@]}}/${#EXPECTED_LIBS[@]} present"
else                     report "Libraries" fail "$(suggested_fix 'Libraries')"; fi

echo
if check_xiao_port; then
    report "XIAO USB port" pass "${XIAO_PORT:-?}"
elif (( XIAO_PORT_NO_PERM )); then
    report "XIAO USB port" fail "${XIAO_PORT} found but not writable — run setup to add udev rule"
else
    report "XIAO USB port" fail "$(suggested_fix 'XIAO USB port')"
fi

if read_smoke_state; then report "Last smoke test" pass "passed ${SMOKE_TIME:-?}"
else                      report "Last smoke test" fail "$(suggested_fix 'Last smoke test')"; fi

echo
printf '%s━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━%s\n' "$C_MAGENTA" "$C_RESET"
if (( FAILED == 0 )); then
    printf '  %sAll systems go.%s  (%d checks)\n' "$C_GREEN" "$C_RESET" "$TOTAL"
    printf '%s━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━%s\n' "$C_MAGENTA" "$C_RESET"
    exit 0
else
    printf '  %s%d failing%s of %d checks.\n' "$C_RED" "$FAILED" "$C_RESET" "$TOTAL"
    printf '  Run setup again, or show this screen to an instructor.\n'
    printf '%s━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━%s\n' "$C_MAGENTA" "$C_RESET"
    exit 1
fi
