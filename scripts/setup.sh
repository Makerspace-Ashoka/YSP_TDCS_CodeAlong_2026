#!/usr/bin/env bash
# YSP TDCS Makerspace — macOS / Linux setup script.
# Students run this every day. First run installs everything; subsequent runs
# sync content, health-check, and open VS Code. Same command, both modes.
#
# Spec: setup_script_spec.md  (source of truth — read it before editing)

set -euo pipefail
IFS=$'\n\t'

# =============================================================================
#  CONFIG  —  every hard-coded value the script needs lives here, and nowhere
#  else. Derived paths follow immediately. No install / sync / repair logic is
#  allowed above this block, except for the shell strict-mode settings above.
# =============================================================================

SCRIPT_VERSION="2026.05.0"

REPO_URL="https://github.com/Makerspace-Ashoka/YSP_TDCS_CodeAlong_2026.git"
REPO_BRANCH="main"
SETUP_SH_URL="https://raw.githubusercontent.com/Makerspace-Ashoka/YSP_TDCS_CodeAlong_2026/main/scripts/setup.sh"
SETUP_PS1_URL="https://raw.githubusercontent.com/Makerspace-Ashoka/YSP_TDCS_CodeAlong_2026/main/scripts/setup.ps1"

PYTHON_VERSION="3.11"
PIO_BOARD="seeed_xiao_esp32c3"
PIO_FRAMEWORK="arduino"
PIO_PLATFORM_PIN="platformio/espressif32@7.0.1"
UPLOAD_SPEED=460800
MONITOR_SPEED=115200

MIN_DISK_GB_HARD=2
MIN_DISK_GB_WARN=4
MAX_CLOCK_SKEW_SEC=300
MIN_VSCODE_VERSION_MAJOR=1
MIN_VSCODE_VERSION_MINOR=90

# Instructor-owned paths — mirrored from upstream into workspace on every sync.
# Edited copies of these are saved into _rescued/<timestamp>/ before being
# restored from the hidden upstream clone.
INSTRUCTOR_PATHS=(
    robot_core
    platformio.ini
    .python-version
    requirements.txt
    QUICKSTART.md
    .vscode
)

# Student-owned paths — NEVER overwritten by sync, ever.
STUDENT_PATHS=(
    my_robot_code
    .pio
    .pio-core
    .venv
    _rescued
    setup_log.txt
    .tdcs_setup_state.json
)

# Library folder names expected under .pio/libdeps/<env>/ after pio pkg install.
EXPECTED_LIBS=(
    "Adafruit PWM Servo Driver Library"
    "Adafruit BusIO"
    "NewPing"
    "ArduinoJson"
    "ESP32Servo"
    "Adafruit NeoPixel"
)

# VS Code extensions required for the curriculum.
VSCODE_EXTS=(
    platformio.platformio-ide
    ms-vscode.cpptools-extension-pack
    ms-vscode.vscode-serial-monitor
)

# Hidden script-owned state — students never look here.
STATE_DIR="$HOME/.tdsc_makerspace_setup"
UPSTREAM_DIR="$STATE_DIR/upstream"
SMOKE_DIR="$STATE_DIR/smoke/xiao_esp32c3"
BOOTSTRAP_LOG="$STATE_DIR/setup_bootstrap.log"
MIRROR_CACHE="$STATE_DIR/mirror_cache"
MIRROR_MANIFEST="$MIRROR_CACHE/manifest.json"

# Student-facing workspace.
WORKSPACE="$HOME/Desktop/YSP_TDCS_Makerspace"
WORKSPACE_LOG="$WORKSPACE/setup_log.txt"
DIAG_STATE="$WORKSPACE/.tdcs_setup_state.json"
RESCUE_DIR="$WORKSPACE/_rescued"
STUDENT_CODE_DIR="$WORKSPACE/my_robot_code"
VENV_DIR="$WORKSPACE/.venv"
PIO_BIN="$VENV_DIR/bin/pio"
PYTHON_BIN="$VENV_DIR/bin/python"

# RESCUE_TS is set on first rescue in a run so all rescued files group together.
RESCUE_TS=""

# Mirror (optional; autodiscovered or supplied via TDCS_MIRROR env var).
MIRROR_HOST="ysp-mirror.local"
MIRROR_PORT=8080
MIRROR_BASE="${TDCS_MIRROR:-}"

# Runtime counters, populated as steps run.
OS=""
ARCH=""
MODE=""
COUNT_OK=0
COUNT_SKIP=0
COUNT_REPAIR=0
COUNT_FAIL=0
FAILED_STEPS=()

# =============================================================================
#  CONSOLE HELPERS  —  color, banner, status lines, spinner.
# =============================================================================

_supports_color() {
    [[ -t 1 ]] || return 1
    [[ -z "${NO_COLOR:-}" ]] || return 1
    command -v tput >/dev/null 2>&1 || return 1
    local colors
    colors=$(tput colors 2>/dev/null || echo 0)
    (( colors >= 8 ))
}

init_console() {
    if _supports_color; then
        C_RESET=$(tput sgr0)
        C_BOLD=$(tput bold)
        C_DIM=$(tput dim 2>/dev/null || echo "")
        C_RED=$(tput setaf 1)
        C_GREEN=$(tput setaf 2)
        C_YELLOW=$(tput setaf 3)
        C_BLUE=$(tput setaf 4)
        C_MAGENTA=$(tput setaf 5)
        C_CYAN=$(tput setaf 6)
    else
        C_RESET=""; C_BOLD=""; C_DIM=""
        C_RED=""; C_GREEN=""; C_YELLOW=""; C_BLUE=""; C_MAGENTA=""; C_CYAN=""
    fi
    show_banner
}

show_banner() {
    printf '%s' "$C_MAGENTA"
    cat <<'BANNER'
 ___  ___      _                                              __   __        __   _____________
|  \/  |     | |                                             \ \ / /        \ \ / /  ___| ___ \
| .  . | __ _| | _____ _ __ ___ _ __   __ _  ___ ___    ______\ V /______    \ V /\ `--.| |_/ /
| |\/| |/ _` | |/ / _ \ '__/ __| '_ \ / _` |/ __/ _ \  |______/   \______|    \ /  `--. \  __/
| |  | | (_| |   <  __/ |  \__ \ |_) | (_| | (_|  __/        / /^\ \          | | /\__/ / |
\_|  |_/\__,_|_|\_\___|_|  |___/ .__/ \__,_|\___\___|        \/   \/          \_/ \____/\_|
                               | |
                               |_|
BANNER
    printf '%s\n' "$C_RESET"
    printf '%sAshoka Makerspace · Young Scholars Programme · Robotics setup %s%s\n\n' \
        "$C_YELLOW" "$SCRIPT_VERSION" "$C_RESET"
}

# status TAG MESSAGE...
#   TAG ∈ {OK SKIP INFO WARN REPAIR FAIL CHECK SYNC INSTALL SMOKE}
status() {
    local tag=$1; shift
    local color="" reset="$C_RESET"
    case "$tag" in
        OK)         color="$C_GREEN"; (( ++COUNT_OK )) || true ;;
        SKIP)       color="$C_DIM";   (( ++COUNT_SKIP )) || true ;;
        INFO|CHECK|SYNC|INSTALL|SMOKE) color="$C_CYAN" ;;
        WARN)       color="$C_YELLOW" ;;
        REPAIR)     color="$C_YELLOW"; (( ++COUNT_REPAIR )) || true ;;
        FAIL)       color="$C_RED$C_BOLD"; (( ++COUNT_FAIL )) || true; FAILED_STEPS+=("$*") ;;
        *)          color="" ;;
    esac
    printf '%s[%s]%s %s\n' "$color" "$tag" "$reset" "$*"
    log "[$tag] $*"
}

with_spinner() {
    local label=$1; shift
    if [[ ! -t 1 ]] || [[ -n "${NO_SPINNER:-}" ]]; then
        status CHECK "$label"
        "$@" >> "$_CURRENT_LOG" 2>&1
        return $?
    fi
    local frames='|/-\' start=$SECONDS rc=0
    "$@" >> "$_CURRENT_LOG" 2>&1 &
    local pid=$!
    local i=0
    while kill -0 "$pid" 2>/dev/null; do
        local elapsed=$((SECONDS - start))
        printf '\r%s[CHECK]%s %s %s (%ds)' "$C_CYAN" "$C_RESET" \
            "${frames:i++%${#frames}:1}" "$label" "$elapsed"
        sleep 0.2
    done
    wait "$pid" || rc=$?
    printf '\r\033[K'
    if (( rc == 0 )); then
        status OK "$label ($((SECONDS - start))s)"
    else
        status FAIL "$label (exit $rc, $((SECONDS - start))s)"
    fi
    return $rc
}

# =============================================================================
#  PHASE HEADERS + BRAILLE SPINNER  —  matches setup.ps1 UX 1:1.
# =============================================================================

SPIN_FRAMES=('⠋' '⠙' '⠹' '⠸' '⠼' '⠴' '⠦' '⠧' '⠇' '⠏')
SPIN_FRAMES_ASCII=('-' '\' '|' '/')
PROGRESS_CLEAR_WIDTH=110

spin_frame() {
    local tick=$1
    if [[ -n "${C_MAGENTA:-}" ]]; then
        printf '%s' "${SPIN_FRAMES[$((tick % ${#SPIN_FRAMES[@]}))]}"
    else
        printf '%s' "${SPIN_FRAMES_ASCII[$((tick % ${#SPIN_FRAMES_ASCII[@]}))]}"
    fi
}

clear_progress_line() {
    printf '\r%*s\r' "$PROGRESS_CLEAR_WIDTH" ''
}

CURRENT_PHASE=""
PHASE_START=0

write_phase() {
    local title=$1 step=${2:-0} total=${3:-0}
    [[ -n "$CURRENT_PHASE" ]] && stop_phase
    local display_title
    if (( step > 0 && total > 0 )); then
        display_title="Step $step/$total · $title"
    else
        display_title="$title"
    fi
    CURRENT_PHASE="$display_title"
    PHASE_START=$SECONDS
    printf '\n'
    if [[ -n "${C_MAGENTA:-}" ]]; then
        printf '%s┌─%s ' "$C_MAGENTA" "$C_RESET"
        if (( step > 0 && total > 0 )); then
            printf '%sStep %d/%d%s %s·%s %s%s%s\n' \
                "$C_YELLOW" "$step" "$total" "$C_RESET" \
                "$C_DIM" "$C_RESET" \
                "$C_BOLD" "$title" "$C_RESET"
        else
            printf '%s%s%s\n' "$C_BOLD" "$title" "$C_RESET"
        fi
    else
        printf '== %s ==\n' "$display_title"
    fi
    log "=== PHASE START: $display_title ==="
}

stop_phase() {
    [[ -n "$CURRENT_PHASE" ]] || return 0
    local elapsed=$((SECONDS - PHASE_START))
    if [[ -n "${C_MAGENTA:-}" ]]; then
        printf '%s└─%s %s%s · %ds%s\n' \
            "$C_MAGENTA" "$C_RESET" "$C_DIM" "$CURRENT_PHASE" "$elapsed" "$C_RESET"
    else
        printf -- '-- %s · %ds --\n' "$CURRENT_PHASE" "$elapsed"
    fi
    log "=== PHASE END: $CURRENT_PHASE elapsed=${elapsed}s ==="
    CURRENT_PHASE=""
}

# =============================================================================
#  STREAMED COMMAND RUNNER  —  runs a child process, tails stdout/stderr in real
#  time, applies an optional line filter (function name) that sets $FILTER_OUT,
#  and renders a single in-place status line with the braille spinner.
#
#  Bash version doesn't suffer the Windows-PS ExitCode race — `wait $pid; $?` is
#  reliable. We still verify by filesystem in callers as defense-in-depth.
# =============================================================================

FILTER_OUT=""
_LAST_STATUS=""

# Read newly-appended bytes from $1 (path) starting at byte offset stored in
# global var named $2, log each line, run $3 (filter function or empty) which
# sets $FILTER_OUT, and update _LAST_STATUS with the latest non-empty result.
# Advances the named position variable to the new size via eval.
_read_stream_chunk() {
    local path=$1 pos_var=$2 filter=$3
    [[ -f "$path" ]] || return 0
    local pos=${!pos_var}
    local size
    size=$(wc -c < "$path" 2>/dev/null | tr -d ' ')
    size=${size:-0}
    (( size > pos )) || return 0
    local chunk
    chunk=$(tail -c "+$((pos + 1))" "$path" 2>/dev/null || true)
    eval "$pos_var=$size"
    [[ -n "$chunk" ]] || return 0
    local line
    while IFS= read -r line; do
        # Strip ANSI escapes and trim whitespace.
        line=$(printf '%s' "$line" | sed -E $'s/\x1b\\[[0-9;]*[A-Za-z]//g' | awk '{$1=$1; print}')
        [[ -z "$line" ]] && continue
        printf '%s\n' "$line" >> "$_CURRENT_LOG"
        FILTER_OUT=""
        if [[ -n "$filter" ]]; then
            "$filter" "$line" || true
        else
            FILTER_OUT="$line"
        fi
        if [[ -n "$FILTER_OUT" ]]; then
            _LAST_STATUS="$FILTER_OUT"
            if (( ${#_LAST_STATUS} > 80 )); then
                _LAST_STATUS="${_LAST_STATUS:0:77}..."
            fi
        fi
    done <<<"$chunk"
}

# invoke_streamed LABEL PREFIX FILTER WORKDIR -- CMD [ARGS...]
#   LABEL    — short string for the log
#   PREFIX   — student-facing status prefix (e.g. "   libraries")
#   FILTER   — function name to translate lines into status (or "" for raw)
#   WORKDIR  — directory to cd into (or "" for current)
#   --       — separator
#   CMD ...  — the actual command + args
# Returns the child's exit code (reliable: bash `wait $pid; $?`).
invoke_streamed() {
    local label=$1; shift
    local prefix=$1; shift
    local filter=$1; shift
    local workdir=$1; shift
    [[ "${1:-}" == "--" ]] && shift

    local tmpout tmperr
    tmpout=$(mktemp -t 'tdcs.out.XXXXXX')
    tmperr=$(mktemp -t 'tdcs.err.XXXXXX')
    local sanitized
    sanitized=$(printf '%q ' "$@" | _redact)
    log "+ $label: $sanitized"
    local start=$SECONDS

    # PYTHONUNBUFFERED makes pio's child python flush per line — without it,
    # progress lines arrive in 4–8 KB chunks and the spinner shows nothing useful.
    if [[ -n "$workdir" ]]; then
        ( cd "$workdir" && PYTHONUNBUFFERED=1 "$@" ) >"$tmpout" 2>"$tmperr" &
    else
        PYTHONUNBUFFERED=1 "$@" >"$tmpout" 2>"$tmperr" &
    fi
    local pid=$!

    local out_pos=0 err_pos=0 tick=0
    _LAST_STATUS=""
    local can_render=1
    [[ -t 1 && -z "${NO_SPINNER:-}" ]] || can_render=0

    while kill -0 "$pid" 2>/dev/null; do
        _read_stream_chunk "$tmpout" out_pos "$filter"
        _read_stream_chunk "$tmperr" err_pos "$filter"
        if (( can_render )); then
            local frame msg
            frame=$(spin_frame "$tick")
            if [[ -n "$_LAST_STATUS" ]]; then
                msg="$prefix · $_LAST_STATUS"
            else
                msg="$prefix"
            fi
            printf '\r  %s %-*s' "$frame" "$((PROGRESS_CLEAR_WIDTH - 4))" "$msg"
        fi
        sleep 0.12
        tick=$((tick + 1))
    done

    local rc=0
    wait "$pid" || rc=$?
    # Final drain.
    _read_stream_chunk "$tmpout" out_pos "$filter"
    _read_stream_chunk "$tmperr" err_pos "$filter"
    (( can_render )) && clear_progress_line

    rm -f "$tmpout" "$tmperr"
    log "= $label rc=$rc duration=$((SECONDS - start))s"
    return $rc
}

# =============================================================================
#  LINE FILTERS  —  translate raw stdout into short student-facing status text.
#  Each filter reads $1 (one line), sets $FILTER_OUT (empty = ignore line).
# =============================================================================

# pio platform install output: "Tool Manager: Installing ...", "Downloading X%".
_RX_PIO_TOOL_INSTALL='Tool Manager: +Installing +[^/]+/([^ ]+) +@'
_RX_PIO_TOOL_DONE='Tool Manager: +(.+) +@ +[^ ]+ +has been installed'
_RX_PIO_DOWNLOAD='Downloading.*\[.*\] +([0-9]+%)'
_RX_PIO_UNPACK='Unpacking.*\[.*\] +([0-9]+%)'
_RX_PIO_PLAT_INSTALL='Platform Manager: +Installing +([^ ]+)'
_RX_PIO_PLAT_DONE='Platform Manager: +.+ +@ +.+ +has been installed'

format_pio_platform_line() {
    local line=$1
    FILTER_OUT=""
    if   [[ "$line" =~ $_RX_PIO_TOOL_INSTALL ]]; then
        FILTER_OUT="fetching ${BASH_REMATCH[1]}"
    elif [[ "$line" =~ $_RX_PIO_TOOL_DONE ]]; then
        FILTER_OUT="installed ${BASH_REMATCH[1]}"
    elif [[ "$line" =~ $_RX_PIO_DOWNLOAD ]]; then
        FILTER_OUT="downloading ${BASH_REMATCH[1]}"
    elif [[ "$line" =~ $_RX_PIO_UNPACK ]]; then
        FILTER_OUT="unpacking ${BASH_REMATCH[1]}"
    elif [[ "$line" =~ $_RX_PIO_PLAT_INSTALL ]]; then
        FILTER_OUT="platform ${BASH_REMATCH[1]}"
    elif [[ "$line" =~ $_RX_PIO_PLAT_DONE ]]; then
        FILTER_OUT="platform installed"
    fi
}

# pio pkg install output: "Library Manager: Installing X" — counter-aware.
PIO_LIB_DONE=0
PIO_LIB_TOTAL=0
_RX_LIB_INSTALL='Library Manager: +Installing +(.+)$'
_RX_LIB_CACHED='Library Manager: +(.+) +@ +[^ ]+ +is already installed'

filter_pio_libs() {
    local line=$1
    FILTER_OUT=""
    if [[ "$line" =~ $_RX_LIB_INSTALL ]]; then
        PIO_LIB_DONE=$((PIO_LIB_DONE + 1))
        (( PIO_LIB_DONE > PIO_LIB_TOTAL )) && PIO_LIB_DONE=$PIO_LIB_TOTAL
        FILTER_OUT="[$PIO_LIB_DONE/$PIO_LIB_TOTAL] ${BASH_REMATCH[1]}"
    elif [[ "$line" =~ $_RX_LIB_CACHED ]]; then
        PIO_LIB_DONE=$((PIO_LIB_DONE + 1))
        (( PIO_LIB_DONE > PIO_LIB_TOTAL )) && PIO_LIB_DONE=$PIO_LIB_TOTAL
        FILTER_OUT="[$PIO_LIB_DONE/$PIO_LIB_TOTAL] ${BASH_REMATCH[1]} (cached)"
    fi
}

# `code --install-extension` output is sparse but emits "Installing extension",
# "Extension X was successfully installed", and a few download lines.
format_extension_line() {
    local line=$1
    FILTER_OUT=""
    case "$line" in
        *'Installing extensions'*)            FILTER_OUT='installing' ;;
        *'Installing extension'*)             FILTER_OUT='installing' ;;
        *'was successfully installed'*)       FILTER_OUT='installed' ;;
        *'is already installed'*)             FILTER_OUT='already installed' ;;
        *Downloading*)                        FILTER_OUT='downloading' ;;
        *Verifying*)                          FILTER_OUT='verifying' ;;
    esac
}

# Generic "show download progress" — useful for fetch_artifact wrappers that
# pipe curl's progress meter through this.
_RX_CURL_PCT='([0-9]+(\.[0-9]+)?)%[[:space:]]'
format_curl_line() {
    local line=$1
    FILTER_OUT=""
    if [[ "$line" =~ $_RX_CURL_PCT ]]; then
        FILTER_OUT="downloading ${BASH_REMATCH[1]}%"
    fi
}

# =============================================================================
#  LOGGING HELPERS
# =============================================================================

_CURRENT_LOG="/dev/null"
log() { :; }   # no-op until start_setup_log is called

start_setup_log() {
    mkdir -p "$STATE_DIR"
    : >> "$BOOTSTRAP_LOG"
    _CURRENT_LOG="$BOOTSTRAP_LOG"
    log() {
        printf '%s %s\n' "$(date -u +%FT%TZ)" "$*" >> "$_CURRENT_LOG"
    }
    log "=== Run: $(date -u +%FT%TZ) (mode=pending) script=$SCRIPT_VERSION host=$(uname -srm) user=$USER ==="
}

promote_log_to_workspace() {
    [[ -d "$WORKSPACE" ]] || return 0
    [[ "$_CURRENT_LOG" == "$WORKSPACE_LOG" ]] && return 0
    : >> "$WORKSPACE_LOG"
    if [[ -s "$BOOTSTRAP_LOG" ]]; then
        cat "$BOOTSTRAP_LOG" >> "$WORKSPACE_LOG"
    fi
    _CURRENT_LOG="$WORKSPACE_LOG"
    log "=== Log promoted to workspace ==="
}

# =============================================================================
#  COMMAND HELPERS
# =============================================================================

_redact() {
    sed -E \
        -e 's/(token|password|passwd|secret|api[_-]?key|authorization)=[^ ]+/\1=***/Ig' \
        -e 's/(--token|--password|--secret|--api-key)( +)[^ ]+/\1\2***/Ig'
}

run_cmd() {
    local label=$1; shift
    [[ "${1:-}" == "--" ]] && shift
    local sanitized
    sanitized=$(printf '%q ' "$@" | _redact)
    log "+ $label: $sanitized"
    local start=$SECONDS rc=0
    "$@" >> "$_CURRENT_LOG" 2>&1 || rc=$?
    log "= $label rc=$rc duration=$((SECONDS - start))s"
    return $rc
}

retry() {
    local n=$1; shift
    local i delay rc=0
    for ((i = 1; i <= n; i++)); do
        rc=0
        "$@" || rc=$?
        (( rc == 0 )) && return 0
        delay=$((i * 2))
        log "retry $i/$n failed (rc=$rc); sleeping ${delay}s"
        sleep "$delay"
    done
    return $rc
}

# refresh_path — ensure newly-installed tools (uv, code) are findable this run.
refresh_path() {
    case ":$PATH:" in *":$HOME/.local/bin:"*) ;; *) PATH="$HOME/.local/bin:$PATH" ;; esac
    if [[ "$OS" == mac ]]; then
        case ":$PATH:" in *":/usr/local/bin:"*) ;; *) PATH="/usr/local/bin:$PATH" ;; esac
    fi
    export PATH
}

# =============================================================================
#  WORKSPACE MIGRATION
# =============================================================================

migrate_workspace_if_needed() {
    local old_ws="$HOME/YSP_TDCS_Makerspace"
    [[ -d "$old_ws" ]] || return 0
    [[ -d "$WORKSPACE" ]] && return 0
    [[ -d "$(dirname "$WORKSPACE")" ]] || return 0
    status INFO "Moving workspace to Desktop..."
    if mv "$old_ws" "$WORKSPACE" 2>/dev/null; then
        status OK "Workspace moved to Desktop"
    else
        status WARN "Could not move workspace automatically"
    fi
}

# =============================================================================
#  TASK 4 — BOOTSTRAP CHECKS
# =============================================================================

detect_os() {
    case "$(uname -s)" in
        Darwin) OS=mac ;;
        Linux)  OS=linux ;;
        MINGW*|MSYS*|CYGWIN*) status FAIL "Run setup.ps1 on Windows, not setup.sh"; exit 1 ;;
        *)      status FAIL "Unsupported OS: $(uname -s)"; exit 1 ;;
    esac
    case "$(uname -m)" in
        arm64|aarch64) ARCH=arm64 ;;
        x86_64|amd64)  ARCH=x86_64 ;;
        *) status FAIL "Unsupported architecture: $(uname -m)"; exit 1 ;;
    esac
    status OK "OS / architecture: $OS $ARCH"
}

check_disk_space() {
    local kb avail_gb
    kb=$(df -k "$HOME" | awk 'NR==2 {print $4}')
    avail_gb=$(( kb / 1024 / 1024 ))
    if (( avail_gb < MIN_DISK_GB_HARD )); then
        status FAIL "Disk space: ${avail_gb} GB free (need at least ${MIN_DISK_GB_HARD} GB)"
        exit 1
    elif (( avail_gb < MIN_DISK_GB_WARN )); then
        status WARN "Disk space: ${avail_gb} GB free (below comfortable ${MIN_DISK_GB_WARN} GB)"
    else
        status OK "Disk space: ${avail_gb} GB free"
    fi
}

# Cross-platform parse of an RFC 1123 HTTP Date header into epoch seconds.
_http_date_to_epoch() {
    local d=$1
    if date -u -d "$d" +%s 2>/dev/null; then return; fi          # GNU date
    date -u -j -f "%a, %d %b %Y %H:%M:%S %Z" "$d" +%s 2>/dev/null # BSD date
}

check_clock_skew() {
    local hdr remote_epoch local_epoch skew
    hdr=$(curl -sSI --max-time 10 https://github.com 2>/dev/null \
        | awk -F': ' 'tolower($1)=="date" {sub(/\r$/,"",$2); print $2; exit}')
    if [[ -z "$hdr" ]]; then
        status FAIL "Cannot reach github.com over HTTPS to verify clock"
        _print_https_fail_block
        exit 1
    fi
    remote_epoch=$(_http_date_to_epoch "$hdr")
    [[ -n "$remote_epoch" ]] || { status WARN "Could not parse server date '$hdr' — skipping clock check"; return; }
    local_epoch=$(date -u +%s)
    skew=$(( local_epoch - remote_epoch ))
    skew=${skew#-}
    if (( skew > MAX_CLOCK_SKEW_SEC )); then
        status FAIL "System clock off by ${skew}s vs github.com (max ${MAX_CLOCK_SKEW_SEC}s) — fix the date and re-run"
        exit 1
    fi
    status OK "Clock skew: ${skew}s"
}

check_write_access() {
    local sentinel="$STATE_DIR/.write_test"
    mkdir -p "$STATE_DIR" || { status FAIL "Cannot create $STATE_DIR"; exit 1; }
    : > "$sentinel" || { status FAIL "Cannot write to $STATE_DIR"; exit 1; }
    rm -f "$sentinel"
    status OK "Write access to $STATE_DIR"
}

_print_https_fail_block() {
    cat <<EOF

[FAIL] Secure connection to GitHub failed.

Your laptop or network is blocking trusted HTTPS downloads.
Do not bypass this warning.

Show this screen to an instructor.
EOF
}

check_https_reachable() {
    if curl -fsS --max-time 10 -o /dev/null https://github.com; then
        status OK "GitHub HTTPS reachable"
        return 0
    fi
    if [[ -n "$MIRROR_BASE" ]]; then
        status WARN "GitHub unreachable; will rely on local mirror"
        return 0
    fi
    _print_https_fail_block
    exit 1
}

# discover_mirror — set MIRROR_BASE if a local mirror is reachable.
discover_mirror() {
    if [[ -n "$MIRROR_BASE" ]]; then
        status OK "Local mirror: $MIRROR_BASE (from env)"
        _cache_mirror_manifest && return 0 || true
    fi
    # 1) mDNS probe
    if curl -fsS --max-time 2 "http://$MIRROR_HOST:$MIRROR_PORT/ping" >/dev/null 2>&1; then
        MIRROR_BASE="http://$MIRROR_HOST:$MIRROR_PORT"
        status OK "Local mirror found — large files will download locally"
        _cache_mirror_manifest && return 0 || true
    fi
    # 2) subnet scan (first 5 + last 5 hosts in our /24)
    local self subnet host candidates=()
    self=$(_local_ipv4 || true)
    if [[ -n "$self" ]]; then
        subnet=${self%.*}
        for i in 1 2 3 4 5 250 251 252 253 254; do
            host="$subnet.$i"
            [[ "$host" == "$self" ]] && continue
            candidates+=("$host")
        done
        for host in ${candidates[@]+"${candidates[@]}"}; do
            if curl -fsS --max-time 0.5 "http://$host:$MIRROR_PORT/ping" >/dev/null 2>&1; then
                MIRROR_BASE="http://$host:$MIRROR_PORT"
                status OK "Local mirror found at $MIRROR_BASE — large files will download locally"
                _cache_mirror_manifest && return 0 || true
            fi
        done
    fi
    status OK "No local mirror — using internet"
}

_local_ipv4() {
    if [[ "$OS" == mac ]]; then
        ipconfig getifaddr en0 2>/dev/null || ipconfig getifaddr en1 2>/dev/null
    else
        hostname -I 2>/dev/null | awk '{print $1}'
    fi
}

_cache_mirror_manifest() {
    mkdir -p "$MIRROR_CACHE"
    curl -fsS --max-time 5 -o "$MIRROR_MANIFEST" "$MIRROR_BASE/manifest.json" \
        || { status WARN "Mirror at $MIRROR_BASE has no manifest.json — falling back to internet"; MIRROR_BASE=""; rm -f "$MIRROR_MANIFEST"; return 1; }
}

ensure_xcode_clt() {
    [[ "$OS" == mac ]] || return 0
    if xcode-select -p >/dev/null 2>&1 && git --version >/dev/null 2>&1; then
        status SKIP "Xcode CLT already installed"
        return 0
    fi
    status INSTALL "Installing Xcode Command Line Tools (~900 MB, ~5–10 min)"
    touch /tmp/.com.apple.dt.CommandLineTools.installondemand.in-progress
    local pkg
    pkg=$(softwareupdate -l 2>/dev/null \
        | awk '/\* Label:.*Command Line Tools/{gsub(/\* Label: /,""); print; exit}')
    if [[ -z "$pkg" ]]; then
        rm -f /tmp/.com.apple.dt.CommandLineTools.installondemand.in-progress
        status FAIL "Xcode CLT not found in softwareupdate — run: xcode-select --install"
        return 1
    fi
    run_cmd "softwareupdate CLT" -- softwareupdate -i "$pkg" \
        || { rm -f /tmp/.com.apple.dt.CommandLineTools.installondemand.in-progress
             status FAIL "Xcode CLT install failed"; return 1; }
    rm -f /tmp/.com.apple.dt.CommandLineTools.installondemand.in-progress
    xcode-select -p >/dev/null 2>&1 \
        || { status FAIL "Xcode CLT still not functional after install"; return 1; }
    status OK "Xcode Command Line Tools installed"
}

run_local_bootstrap_checks() {
    # Fast, offline — always run before mode detection.
    detect_os
    check_disk_space
    check_write_access
    ensure_xcode_clt
}

run_network_bootstrap_checks() {
    # Slow — clock probe and HTTPS check. Skip on daily (environment already healthy).
    check_clock_skew
    check_https_reachable
}

# =============================================================================
#  TASK 14 — MIRROR CONSUMPTION (single point of truth)
# =============================================================================

# mirror_url_for CATEGORY NAME → prints URL on stdout, exits 0; or exits 1
# Mirror manifest is generated by prefetch-and-serve.sh in a one-line-per-artifact
# layout that the grep/sed path below depends on. When jq is available we prefer
# it, which survives any future formatting change (pretty-printed, reordered keys).
_manifest_lookup() {
    local category=$1 name=$2 field=$3   # field ∈ {url, sha256}
    [[ -n "$MIRROR_BASE" && -f "$MIRROR_MANIFEST" ]] || return 1
    if command -v jq >/dev/null 2>&1; then
        jq -r --arg c "$category" --arg n "$name" --arg f "$field" \
            '.artifacts // [] | map(select(.category==$c and .name==$n)) | (first // null) | .[$f] // empty' \
            "$MIRROR_MANIFEST" 2>/dev/null
        return 0
    fi
    # Fallback: compact one-line-per-artifact layout. Two greps so key order
    # within an artifact doesn't matter.
    grep -F "\"category\":\"$category\"" "$MIRROR_MANIFEST" 2>/dev/null \
        | grep -F "\"name\":\"$name\"" \
        | head -1 \
        | sed -E "s/.*\"$field\":\"([^\"]+)\".*/\\1/"
}

mirror_url_for()    { _manifest_lookup "$1" "$2" url; }
mirror_sha256_for() { _manifest_lookup "$1" "$2" sha256; }

# fetch_artifact CATEGORY NAME INTERNET_URL OUT_PATH
#   Tries mirror first (with checksum); falls back to INTERNET_URL on miss or
#   checksum mismatch. Returns 0 on success.
fetch_artifact() {
    local category=$1 name=$2 internet_url=$3 out=$4
    local mirror_url want_sha got_sha
    mirror_url=$(mirror_url_for "$category" "$name" || true)
    want_sha=$(mirror_sha256_for "$category" "$name" || true)
    if [[ -n "$mirror_url" ]]; then
        log "mirror hit: $category/$name → $mirror_url"
        if curl -fsS --max-time 600 -o "$out" "$mirror_url"; then
            if [[ -n "$want_sha" ]]; then
                got_sha=$(_sha256 "$out")
                if [[ "$got_sha" == "$want_sha" ]]; then
                    return 0
                fi
                status WARN "checksum mismatch for $name from mirror — falling back to internet"
            else
                return 0
            fi
        fi
    fi
    log "mirror miss: $category/$name → $internet_url"
    curl -fsSL --max-time 600 -o "$out" "$internet_url"
}

_sha256() {
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$1" | awk '{print $1}'
    else
        shasum -a 256 "$1" | awk '{print $1}'
    fi
}

# =============================================================================
#  TASK 6 — HERMETIC PYTHON (uv + Python 3.11 + project venv)
# =============================================================================

ensure_uv() {
    refresh_path
    if command -v uv >/dev/null 2>&1 && uv --version >/dev/null 2>&1; then
        status SKIP "uv $(uv --version | awk '{print $2}') already installed"
        return 0
    fi
    status INSTALL "Installing uv"
    local installer="$STATE_DIR/uv-install.sh"
    fetch_artifact uv "uv-install.sh" "https://astral.sh/uv/install.sh" "$installer" \
        || { status FAIL "uv installer download failed"; return 1; }
    run_cmd "uv install" -- sh "$installer" || { status FAIL "uv installer exited non-zero"; return 1; }
    refresh_path
    uv --version >/dev/null 2>&1 || { status FAIL "uv not on PATH after install"; return 1; }
    status OK "uv $(uv --version | awk '{print $2}') installed"
}

ensure_python() {
    refresh_path
    if uv python find "$PYTHON_VERSION" >/dev/null 2>&1; then
        status SKIP "Python $PYTHON_VERSION already managed by uv"
        return 0
    fi
    status INSTALL "Installing Python $PYTHON_VERSION via uv"
    run_cmd "uv python install" -- uv python install "$PYTHON_VERSION" \
        || { status FAIL "uv python install $PYTHON_VERSION failed"; return 1; }
    status OK "Python $PYTHON_VERSION ready"
}

ensure_venv() {
    mkdir -p "$WORKSPACE"
    local venv_ok=0
    if [[ -x "$PYTHON_BIN" ]] && "$PYTHON_BIN" --version 2>&1 | grep -q "Python ${PYTHON_VERSION}\."; then
        status SKIP ".venv already on Python $PYTHON_VERSION"
        venv_ok=1
    fi
    if (( ! venv_ok )); then
        status REPAIR "Creating $VENV_DIR"
        # --seed installs pip into the venv; PlatformIO's esptoolpy installer needs it.
        ( cd "$WORKSPACE" && run_cmd "uv venv" -- uv venv --python "$PYTHON_VERSION" --seed .venv ) \
            || { status FAIL "uv venv failed"; return 1; }
        status OK ".venv on Python $("$PYTHON_BIN" --version | awk '{print $2}')"
    fi
    # PlatformIO's esptoolpy post-install calls python -m pip. Even on an existing
    # venv we re-check pip, since a partial earlier install can leave a
    # Python-valid but pip-broken venv that PIO will then fail against.
    if ! "$PYTHON_BIN" -m pip --version >/dev/null 2>&1; then
        status REPAIR "Seeding pip into .venv via ensurepip (required by PlatformIO)"
        "$PYTHON_BIN" -m ensurepip --upgrade >/dev/null 2>&1 || true
    fi
}

ensure_venv_and_pio() { ensure_venv && ensure_platformio; }

# =============================================================================
#  TASK 7 — PLATFORMIO CORE + ESP32 + LIBRARIES
# =============================================================================

ensure_platformio() {
    if [[ -x "$PIO_BIN" ]] && "$PIO_BIN" --version >/dev/null 2>&1; then
        status SKIP "PlatformIO $($PIO_BIN --version | awk '{print $NF}') already in .venv"
        return 0
    fi
    [[ -d "$WORKSPACE" ]] || mkdir -p "$WORKSPACE"
    local find_links=()
    [[ -n "$MIRROR_BASE" ]] && find_links=(--find-links "$MIRROR_BASE/wheels")
    status INSTALL "Installing PlatformIO Core into .venv"
    (
        cd "$WORKSPACE" \
            && run_cmd "uv pip install platformio" -- \
                uv pip install --python .venv ${find_links[@]+"${find_links[@]}"} -r requirements.txt
    ) || { status FAIL "PlatformIO install failed"; return 1; }
    status OK "PlatformIO $($PIO_BIN --version | awk '{print $NF}') installed"
}

ensure_esp32_platform() {
    # If esptoolpy was extracted but its post-install pip step failed, package.json
    # is absent. Remove it so PlatformIO re-downloads a clean copy.
    local esptoolpy_dir="$WORKSPACE/.pio-core/packages/tool-esptoolpy"
    if [[ -d "$esptoolpy_dir" && ! -f "$esptoolpy_dir/package.json" ]]; then
        status REPAIR "Removing incomplete tool-esptoolpy package"
        rm -rf "$esptoolpy_dir"
    fi
    local pkgs_dir="$WORKSPACE/.pio-core/packages"
    if [[ -d "$pkgs_dir" ]] && \
        find "$pkgs_dir" -maxdepth 1 -type d -name 'toolchain-xtensa*' 2>/dev/null | grep -q .; then
        status SKIP "$PIO_PLATFORM_PIN already installed"
        return 0
    fi
    status INSTALL "Downloading ESP32 toolchain (~500 MB) — 3–5 minutes"
    local rc=0
    invoke_streamed 'pio platform install' '   downloading' format_pio_platform_line "$WORKSPACE" \
        -- "$PIO_BIN" platform install "$PIO_PLATFORM_PIN" || rc=$?
    # Verify by side-effect — the toolchain dir is the source of truth even if
    # pio's exit code is ambiguous.
    if [[ -d "$pkgs_dir" ]] && \
        find "$pkgs_dir" -maxdepth 1 -type d -name 'toolchain-xtensa*' 2>/dev/null | grep -q .; then
        status OK "ESP32 platform installed"
        (( rc != 0 )) && log "note: pio platform rc=$rc but toolchain present on disk"
        return 0
    fi
    status FAIL "ESP32 platform install failed (rc=$rc, no toolchain on disk)"
    return 1
}

ensure_libraries() {
    [[ -f "$WORKSPACE/platformio.ini" ]] || { status FAIL "platformio.ini missing"; return 1; }
    status INSTALL "Installing ${#EXPECTED_LIBS[@]} libraries"
    PIO_LIB_TOTAL=${#EXPECTED_LIBS[@]}
    PIO_LIB_DONE=0
    local rc=0
    invoke_streamed 'pio pkg install' '   libraries' filter_pio_libs "$WORKSPACE" \
        -- "$PIO_BIN" pkg install || rc=$?

    # Verify by side-effect, regardless of rc. Disk state is source of truth.
    local libdeps="$WORKSPACE/.pio/libdeps"
    local lib pat missing=()
    if [[ -d "$libdeps" ]]; then
        for lib in "${EXPECTED_LIBS[@]}"; do
            pat="${lib%% *}"
            if find "$libdeps" -mindepth 2 -maxdepth 3 -type d \
                    -iname "*${pat}*" 2>/dev/null | grep -q .; then
                continue
            fi
            missing+=("$lib")
        done
    fi
    if [[ -d "$libdeps" && ${#missing[@]} -eq 0 ]]; then
        status OK "All ${#EXPECTED_LIBS[@]} libraries installed"
        (( rc != 0 )) && log "note: pio rc=$rc but all expected libraries present on disk"
        return 0
    fi
    if [[ ! -d "$libdeps" ]]; then
        status FAIL "pio pkg install failed (rc=$rc, libdeps directory missing)"
    else
        for lib in "${missing[@]}"; do status FAIL "Library missing: $lib"; done
    fi
    return 1
}

# =============================================================================
#  TASK 8 — HIDDEN UPSTREAM CLONE + WORKSPACE + ALLOWLIST SYNC
# =============================================================================

ensure_upstream() {
    if [[ -d "$UPSTREAM_DIR/.git" ]] \
            && [[ "$(git -C "$UPSTREAM_DIR" remote get-url origin 2>/dev/null)" == "$REPO_URL" ]]; then
        status SKIP "Hidden upstream cache present"
        return 0
    fi
    if [[ -e "$UPSTREAM_DIR" ]]; then
        local ts; ts=$(date +%Y%m%d-%H%M%S)
        mv "$UPSTREAM_DIR" "${UPSTREAM_DIR}_backup_${ts}"
        status WARN "Renamed broken cache to upstream_backup_${ts}"
    fi
    mkdir -p "$STATE_DIR"
    status INSTALL "Cloning class content (first time only)"
    run_cmd "git clone upstream" -- \
        git clone --depth=50 --branch "$REPO_BRANCH" "$REPO_URL" "$UPSTREAM_DIR" \
        || { status FAIL "git clone failed"; return 1; }
    status OK "Upstream cache ready"
}

# is_instructor_path REL_PATH — exits 0 iff path is on the allowlist.
is_instructor_path() {
    local rel=$1 p
    for p in "${INSTRUCTOR_PATHS[@]}"; do
        if [[ "$rel" == "$p" ]] || [[ "$rel" == "$p"/* ]]; then return 0; fi
    done
    return 1
}

is_student_path() {
    local rel=$1 p
    for p in "${STUDENT_PATHS[@]}"; do
        if [[ "$rel" == "$p" ]] || [[ "$rel" == "$p"/* ]]; then return 0; fi
    done
    return 1
}

# rescue_file REL — copy WORKSPACE/REL into _rescued/<RESCUE_TS>/REL so the
# student doesn't lose their edits before the instructor copy overwrites them.
rescue_file() {
    local rel=$1
    [[ -f "$WORKSPACE/$rel" ]] || return 0
    [[ -n "$RESCUE_TS" ]] || RESCUE_TS=$(date +%Y%m%d-%H%M%S)
    local target="$RESCUE_DIR/$RESCUE_TS/$rel"
    mkdir -p "$(dirname "$target")"
    cp -p "$WORKSPACE/$rel" "$target"
    log "[RESCUE] $rel -> _rescued/$RESCUE_TS/$rel"
}

# rescue_if_modified REL — walk an instructor path, comparing local files to
# their upstream counterparts; rescue every locally-different file before sync.
rescue_if_modified() {
    local rel=$1 rescued=0
    [[ -e "$WORKSPACE/$rel" && -e "$UPSTREAM_DIR/$rel" ]] || return 0
    if [[ -f "$UPSTREAM_DIR/$rel" ]]; then
        if ! cmp -s "$WORKSPACE/$rel" "$UPSTREAM_DIR/$rel"; then
            rescue_file "$rel"
            status REPAIR "Restored protected file: $rel (edited copy saved in _rescued/$RESCUE_TS/)"
        fi
        return 0
    fi
    while IFS= read -r local_file; do
        local sub=${local_file#"$WORKSPACE/$rel/"}
        if [[ -f "$UPSTREAM_DIR/$rel/$sub" ]] && cmp -s "$local_file" "$UPSTREAM_DIR/$rel/$sub"; then
            continue
        fi
        rescue_file "$rel/$sub"
        rescued=1
    done < <(find "$WORKSPACE/$rel" -type f)
    if (( rescued )); then
        status REPAIR "Restored protected path: $rel (edited files saved in _rescued/$RESCUE_TS/)"
    fi
}

sync_workspace() {
    [[ -d "$UPSTREAM_DIR/.git" ]] || ensure_upstream || return 1
    mkdir -p "$WORKSPACE"
    promote_log_to_workspace
    disable_git_in_workspace

    # Remove the workspace file that triggers VS Code's "Open as workspace?" toast.
    # The setup script opens VS Code as a plain folder; release-robot also strips
    # this file from the student repo, so any local copy is stale.
    rm -f "$WORKSPACE/ronnie-robot.code-workspace" 2>/dev/null || true

    local old_sha new_sha
    old_sha=$(git -C "$UPSTREAM_DIR" rev-parse HEAD 2>/dev/null || echo "")
    run_cmd "git fetch" -- git -C "$UPSTREAM_DIR" fetch origin "$REPO_BRANCH" \
        || { status FAIL "git fetch failed"; return 1; }
    run_cmd "git reset" -- git -C "$UPSTREAM_DIR" reset --hard "origin/$REPO_BRANCH" \
        || { status FAIL "git reset failed"; return 1; }
    new_sha=$(git -C "$UPSTREAM_DIR" rev-parse HEAD)

    local changed_count=0
    if [[ -n "$old_sha" && "$old_sha" == "$new_sha" ]] && check_content_match; then
        status SKIP "Already up to date"
    else
        local rel
        for rel in "${INSTRUCTOR_PATHS[@]}"; do
            [[ -e "$UPSTREAM_DIR/$rel" ]] || continue
            rescue_if_modified "$rel"
            if [[ -d "$UPSTREAM_DIR/$rel" ]]; then
                mkdir -p "$WORKSPACE/$rel"
                if command -v rsync >/dev/null 2>&1; then
                    run_cmd "rsync $rel" -- rsync -a --delete "$UPSTREAM_DIR/$rel/" "$WORKSPACE/$rel/"
                else
                    rm -rf "$WORKSPACE/$rel" && cp -R "$UPSTREAM_DIR/$rel" "$WORKSPACE/$rel"
                fi
            else
                mkdir -p "$(dirname "$WORKSPACE/$rel")"
                cp -f "$UPSTREAM_DIR/$rel" "$WORKSPACE/$rel"
            fi
        done
        if [[ -n "$old_sha" && "$old_sha" != "$new_sha" ]]; then
            changed_count=$(git -C "$UPSTREAM_DIR" diff --name-only "$old_sha" "$new_sha" | wc -l | tr -d ' ')
        fi
        if (( changed_count > 0 )); then
            status OK "Content sync ($changed_count files changed)"
        else
            status OK "Content sync"
        fi
    fi
}

disable_git_in_workspace() {
    if [[ -d "$WORKSPACE/.git" ]]; then
        local ts; ts=$(date +%Y%m%d-%H%M%S)
        mv "$WORKSPACE/.git" "$WORKSPACE/.git_disabled_${ts}"
        status REPAIR "Disabled stray .git in workspace → .git_disabled_${ts}"
    fi
}

seed_student_code_if_empty() {
    if [[ -d "$STUDENT_CODE_DIR" ]] \
            && [[ -n "$(find "$STUDENT_CODE_DIR" -mindepth 1 -maxdepth 1 -type f 2>/dev/null)" ]]; then
        status SKIP "my_robot_code/ already populated — leaving student edits alone"
        return 0
    fi
    local src="$UPSTREAM_DIR/my_robot_code"
    [[ -f "$src/main.cpp" ]] \
        || { status FAIL "Upstream starter missing: $src/main.cpp"; return 1; }
    mkdir -p "$STUDENT_CODE_DIR"
    cp -a "$src/." "$STUDENT_CODE_DIR/"
    status OK "Seeded my_robot_code/ from upstream starter"
}

# =============================================================================
#  TASK 9 — VS CODE INSTALL + EXTENSIONS
# =============================================================================

ensure_vscode() {
    refresh_path
    # On macOS, VS Code.app may exist but symlink may not be on PATH yet.
    [[ "$OS" == mac ]] && _ensure_code_symlink_mac && refresh_path
    if command -v code >/dev/null 2>&1 && code --version >/dev/null 2>&1; then
        local ver major minor
        ver=$(code --version | head -1)
        major=${ver%%.*}
        minor=${ver#*.}; minor=${minor%%.*}
        if (( major > MIN_VSCODE_VERSION_MAJOR )) || \
           (( major == MIN_VSCODE_VERSION_MAJOR && minor >= MIN_VSCODE_VERSION_MINOR )); then
            status SKIP "VS Code $ver already installed"
            _ensure_code_symlink_mac
            return 0
        fi
        status WARN "VS Code $ver below minimum; reinstalling"
    fi
    if [[ "$OS" == mac ]]; then
        _install_vscode_mac
    else
        _install_vscode_linux
    fi
}

_install_vscode_mac() {
    local zip="$STATE_DIR/VSCode.zip"
    local internet="https://update.code.visualstudio.com/latest/darwin-universal/stable"
    status INSTALL "Downloading VS Code (~150 MB)"
    # fetch_artifact uses curl -fsS (silent). Wrap in invoke_streamed so the
    # student sees the spinner advancing.
    local rc=0
    invoke_streamed 'vscode download' '   downloading' '' '' \
        -- bash -c "set -e; rm -f '$zip'; curl -fL --max-time 600 -o '$zip' '$internet'" || rc=$?
    if (( rc != 0 )) || [[ ! -s "$zip" ]]; then
        status FAIL "VS Code download failed"; return 1
    fi
    rm -rf "/Applications/Visual Studio Code.app"
    status INSTALL "Unzipping VS Code into /Applications"
    rc=0
    invoke_streamed 'unzip VSCode' '   unzipping' '' '' \
        -- unzip -q -o "$zip" -d /Applications/ || rc=$?
    if (( rc != 0 )) || [[ ! -d "/Applications/Visual Studio Code.app" ]]; then
        status FAIL "VS Code unzip to /Applications failed (check disk space and admin access)"
        return 1
    fi
    rm -f "$zip"
    _ensure_code_symlink_mac
    refresh_path
    code --version >/dev/null 2>&1 || { status FAIL "VS Code not runnable after install"; return 1; }
    status OK "VS Code installed"
}

_ensure_code_symlink_mac() {
    [[ "$OS" == mac ]] || return 0
    refresh_path
    if command -v code >/dev/null 2>&1; then return 0; fi
    local target="/Applications/Visual Studio Code.app/Contents/Resources/app/bin/code"
    [[ -x "$target" ]] || return 0
    # Try /usr/local/bin (system-wide); fall back to ~/.local/bin (no sudo needed).
    if ln -sf "$target" /usr/local/bin/code 2>/dev/null; then return 0; fi
    sudo -n ln -sf "$target" /usr/local/bin/code 2>/dev/null && return 0
    mkdir -p "$HOME/.local/bin"
    ln -sf "$target" "$HOME/.local/bin/code" && refresh_path && return 0
    status WARN "Could not create code CLI symlink"
}

_install_vscode_linux() {
    local pkg internet rc=0
    if command -v apt-get >/dev/null 2>&1; then
        pkg="$STATE_DIR/code.deb"
        internet="https://go.microsoft.com/fwlink/?LinkID=760868"
        status INSTALL "Downloading VS Code (.deb)"
        invoke_streamed 'vscode .deb download' '   downloading' '' '' \
            -- bash -c "set -e; rm -f '$pkg'; curl -fL --max-time 600 -o '$pkg' '$internet'" || rc=$?
        if (( rc != 0 )) || [[ ! -s "$pkg" ]]; then
            status FAIL "VS Code .deb download failed"; return 1
        fi
        status INSTALL "Installing VS Code via apt"
        rc=0
        invoke_streamed 'apt install code' '   apt' '' '' \
            -- sudo apt-get install -y "$pkg" || rc=$?
        (( rc == 0 )) || { status FAIL "apt install failed (rc=$rc)"; return 1; }
    elif command -v dnf >/dev/null 2>&1; then
        pkg="$STATE_DIR/code.rpm"
        internet="https://packages.microsoft.com/yumrepos/vscode/code-1.x86_64.rpm"
        status INSTALL "Downloading VS Code (.rpm)"
        invoke_streamed 'vscode .rpm download' '   downloading' '' '' \
            -- bash -c "set -e; rm -f '$pkg'; curl -fL --max-time 600 -o '$pkg' '$internet'" || rc=$?
        if (( rc != 0 )) || [[ ! -s "$pkg" ]]; then
            status FAIL "VS Code .rpm download failed"; return 1
        fi
        status INSTALL "Installing VS Code via dnf"
        rc=0
        invoke_streamed 'dnf install code' '   dnf' '' '' \
            -- sudo dnf install -y "$pkg" || rc=$?
        (( rc == 0 )) || { status FAIL "dnf install failed (rc=$rc)"; return 1; }
    else
        status FAIL "No supported Linux package manager (apt/dnf)"
        return 1
    fi
    code --version >/dev/null 2>&1 || { status FAIL "VS Code not runnable after install"; return 1; }
    status OK "VS Code installed"
}

# =============================================================================
#  TASK 9b — LINUX USB DEVICE ACCESS (udev rule for XIAO ESP32C3)
# =============================================================================

_UDEV_RULE_FILE="/etc/udev/rules.d/99-xiao-esp32c3.rules"
_UDEV_RULE_LINE='SUBSYSTEMS=="usb", ATTRS{idVendor}=="303a", ATTRS{idProduct}=="1001", MODE="0666", ENV{ID_MM_DEVICE_IGNORE}="1"'

# No-op on macOS — native CDC support requires no udev configuration.
ensure_udev_rule() {
    [[ "$OS" == linux ]] || return 0
    if [[ -f "$_UDEV_RULE_FILE" ]] && grep -qF "303a" "$_UDEV_RULE_FILE" 2>/dev/null; then
        status SKIP "udev rule for XIAO ESP32C3 already present"
        return 0
    fi
    status INSTALL "Writing udev rule for XIAO ESP32C3 USB access"
    printf '%s\n' "$_UDEV_RULE_LINE" \
        | sudo tee "$_UDEV_RULE_FILE" >/dev/null \
        || { status FAIL "Could not write $_UDEV_RULE_FILE — sudo required"; return 1; }
    sudo udevadm control --reload-rules 2>/dev/null || true
    sudo udevadm trigger --subsystem-match=usb 2>/dev/null || true
    status OK "udev rule written — USB port accessible without sudo"
}

ensure_extensions() {
    command -v code >/dev/null 2>&1 || { status FAIL "code CLI not on PATH"; return 1; }
    local installed; installed=$(code --list-extensions 2>/dev/null | tr '[:upper:]' '[:lower:]')
    local ext lc idx=0 total=${#VSCODE_EXTS[@]}
    for ext in "${VSCODE_EXTS[@]}"; do
        idx=$((idx + 1))
        lc=$(printf '%s' "$ext" | tr '[:upper:]' '[:lower:]')
        if grep -qx "$lc" <<<"$installed"; then
            status SKIP "[$idx/$total] $ext (already installed)"
            continue
        fi
        status INSTALL "[$idx/$total] $ext"
        _install_one_extension "$ext" || _install_one_extension "$ext" || \
            { status FAIL "ext $ext could not be installed"; continue; }
    done
}

# Source of truth for "is ext installed": ask code CLI directly.
test_extension_installed() {
    local ext=$1
    local lc; lc=$(printf '%s' "$ext" | tr '[:upper:]' '[:lower:]')
    local list; list=$(code --list-extensions 2>/dev/null | tr '[:upper:]' '[:lower:]')
    grep -qx "$lc" <<<"$list"
}

_install_one_extension() {
    local ext=$1
    local vsix="$STATE_DIR/$ext.vsix"
    if [[ -n "$MIRROR_BASE" ]] && mirror_url_for vsix "$ext.vsix" >/dev/null 2>&1; then
        if fetch_artifact vsix "$ext.vsix" "" "$vsix"; then
            invoke_streamed "ext install $ext (vsix)" "   $ext" format_extension_line '' \
                -- code --install-extension "$vsix" || true
            if test_extension_installed "$ext"; then status OK "ext $ext"; return 0; fi
        fi
    fi
    invoke_streamed "ext install $ext (marketplace)" "   $ext" format_extension_line '' \
        -- code --install-extension "$ext" || true
    if test_extension_installed "$ext"; then status OK "ext $ext"; return 0; fi
    return 1
}

# =============================================================================
#  PARALLEL LIBS + EXTENSIONS  —  pio pkg install runs in background, code
#  --install-extension calls are serialised (code CLI doesn't parallelise
#  safely). Both pipelines share one render loop with a single status line.
# =============================================================================

invoke_parallel_libs_and_extensions() {
    [[ -f "$WORKSPACE/platformio.ini" ]] || { status FAIL 'platformio.ini missing'; ensure_extensions; return 1; }
    [[ -x "$PIO_BIN" ]] || { status FAIL 'PlatformIO missing — skipping library install'; ensure_extensions; return 1; }
    command -v code >/dev/null 2>&1 || { ensure_libraries; ensure_extensions; return; }

    local lib_total=${#EXPECTED_LIBS[@]}
    local ext_total=${#VSCODE_EXTS[@]}
    PIO_LIB_TOTAL=$lib_total
    PIO_LIB_DONE=0

    status INSTALL "Installing $lib_total libraries + $ext_total VS Code extensions in parallel"

    # Pre-list installed extensions so we skip ones already present.
    local installed_lc; installed_lc=$(code --list-extensions 2>/dev/null | tr '[:upper:]' '[:lower:]')

    local lib_out lib_err
    lib_out=$(mktemp -t 'tdcs.libout.XXXXXX')
    lib_err=$(mktemp -t 'tdcs.liberr.XXXXXX')
    log "+ pio pkg install (parallel)"
    ( cd "$WORKSPACE" && PYTHONUNBUFFERED=1 "$PIO_BIN" pkg install ) >"$lib_out" 2>"$lib_err" &
    local lib_pid=$!

    # State for ext pipeline.
    local ext_queue=("${VSCODE_EXTS[@]}")
    local ext_idx=0
    local ext_cur=""
    local ext_pid=0
    local ext_out="" ext_err=""
    local ext_out_pos=0 ext_err_pos=0

    # Per-extension result lookup. Bash 3.2 has no associative arrays, so we
    # keep two parallel arrays and look up by linear scan (n=3, irrelevant).
    EXT_RESULT_KEYS=()
    EXT_RESULT_VALS=()
    _set_ext_result() {
        local k=$1 v=$2 i
        for i in "${!EXT_RESULT_KEYS[@]}"; do
            if [[ "${EXT_RESULT_KEYS[$i]}" == "$k" ]]; then EXT_RESULT_VALS[$i]="$v"; return; fi
        done
        EXT_RESULT_KEYS+=("$k"); EXT_RESULT_VALS+=("$v")
    }
    _get_ext_result() {
        local k=$1 i
        for i in "${!EXT_RESULT_KEYS[@]}"; do
            if [[ "${EXT_RESULT_KEYS[$i]}" == "$k" ]]; then printf '%s' "${EXT_RESULT_VALS[$i]}"; return; fi
        done
    }

    EXT_STATUS=""
    LIB_STATUS="starting"

    _start_next_ext() {
        # Advance through the queue; sets ext_cur, ext_pid, ext_out/err, ext_out_pos/err_pos.
        # On a cached skip, marks result + leaves ext_pid=0 so the loop progresses.
        ext_cur=""; ext_pid=0; ext_out=""; ext_err=""; ext_out_pos=0; ext_err_pos=0
        (( ext_idx >= ${#VSCODE_EXTS[@]} )) && return 0
        ext_cur="${ext_queue[$ext_idx]}"
        ext_idx=$((ext_idx + 1))
        local lc; lc=$(printf '%s' "$ext_cur" | tr '[:upper:]' '[:lower:]')
        if grep -qx "$lc" <<<"$installed_lc"; then
            _set_ext_result "$ext_cur" 'skip'
            EXT_STATUS="[$ext_idx/$ext_total] $ext_cur (cached)"
            return 0
        fi
        ext_out=$(mktemp -t 'tdcs.extout.XXXXXX')
        ext_err=$(mktemp -t 'tdcs.exterr.XXXXXX')
        EXT_STATUS="[$ext_idx/$ext_total] $ext_cur"
        log "+ ext install $ext_cur (parallel)"
        code --install-extension "$ext_cur" >"$ext_out" 2>"$ext_err" &
        ext_pid=$!
    }
    _start_next_ext

    local lib_out_pos=0 lib_err_pos=0 tick=0
    local can_render=1
    [[ -t 1 && -z "${NO_SPINNER:-}" ]] || can_render=0

    while true; do
        # Lib polling.
        FILTER_OUT=""
        _read_stream_chunk "$lib_out" lib_out_pos filter_pio_libs
        [[ -n "$_LAST_STATUS" ]] && LIB_STATUS="$_LAST_STATUS"
        _read_stream_chunk "$lib_err" lib_err_pos filter_pio_libs
        [[ -n "$_LAST_STATUS" ]] && LIB_STATUS="$_LAST_STATUS"

        # Ext polling (only when we have a live ext process).
        if (( ext_pid > 0 )) && kill -0 "$ext_pid" 2>/dev/null; then
            _LAST_STATUS=""
            _read_stream_chunk "$ext_out" ext_out_pos format_extension_line
            [[ -n "$_LAST_STATUS" ]] && EXT_STATUS="[$ext_idx/$ext_total] $ext_cur · $_LAST_STATUS"
            _read_stream_chunk "$ext_err" ext_err_pos format_extension_line
            [[ -n "$_LAST_STATUS" ]] && EXT_STATUS="[$ext_idx/$ext_total] $ext_cur · $_LAST_STATUS"
        fi

        # Current ext finished (or was cached) — advance.
        local ext_ready=0
        if [[ -z "$ext_cur" ]]; then
            ext_ready=1
        elif (( ext_pid == 0 )); then
            ext_ready=1  # cached skip
        elif ! kill -0 "$ext_pid" 2>/dev/null; then
            ext_ready=1
        fi
        if (( ext_ready )) && [[ -n "$ext_cur" ]]; then
            if (( ext_pid > 0 )); then
                local ext_rc=0
                wait "$ext_pid" 2>/dev/null || ext_rc=$?
                # Final ext drain.
                _LAST_STATUS=""
                _read_stream_chunk "$ext_out" ext_out_pos format_extension_line
                _read_stream_chunk "$ext_err" ext_err_pos format_extension_line
                if (( ext_rc == 0 )); then
                    _set_ext_result "$ext_cur" 'ok'
                else
                    _set_ext_result "$ext_cur" 'fail'
                fi
                rm -f "$ext_out" "$ext_err"
            fi
            _start_next_ext
        fi

        # Render.
        if (( can_render )); then
            local frame line
            frame=$(spin_frame "$tick")
            line="  $frame Libs: $LIB_STATUS  │  Exts: $EXT_STATUS"
            if (( ${#line} > PROGRESS_CLEAR_WIDTH - 2 )); then
                line="${line:0:$((PROGRESS_CLEAR_WIDTH - 5))}..."
            fi
            printf '\r%-*s' "$PROGRESS_CLEAR_WIDTH" "$line"
        fi

        # Exit when both pipelines are done.
        local lib_done=0 ext_done=0
        kill -0 "$lib_pid" 2>/dev/null || lib_done=1
        if (( ext_idx >= ${#VSCODE_EXTS[@]} )) && [[ -z "$ext_cur" ]]; then ext_done=1; fi
        if (( lib_done && ext_done )); then break; fi
        sleep 0.12
        tick=$((tick + 1))
    done

    local lib_rc=0
    wait "$lib_pid" 2>/dev/null || lib_rc=$?
    # Final lib drain.
    _LAST_STATUS=""
    _read_stream_chunk "$lib_out" lib_out_pos filter_pio_libs
    _read_stream_chunk "$lib_err" lib_err_pos filter_pio_libs
    (( can_render )) && clear_progress_line
    rm -f "$lib_out" "$lib_err"
    log "= pio pkg install (parallel) rc=$lib_rc"

    # Library verification by filesystem.
    local libdeps="$WORKSPACE/.pio/libdeps"
    local lib pat missing=()
    if [[ -d "$libdeps" ]]; then
        for lib in "${EXPECTED_LIBS[@]}"; do
            pat="${lib%% *}"
            if find "$libdeps" -mindepth 2 -maxdepth 3 -type d -iname "*${pat}*" 2>/dev/null | grep -q .; then
                continue
            fi
            missing+=("$lib")
        done
    fi
    if [[ -d "$libdeps" && ${#missing[@]} -eq 0 ]]; then
        status OK "All $lib_total libraries installed"
        (( lib_rc != 0 )) && log "note: pio rc=$lib_rc but all expected libraries present on disk"
    else
        if [[ ! -d "$libdeps" ]]; then
            status FAIL "pio pkg install failed (rc=$lib_rc, libdeps directory missing)"
        else
            for lib in "${missing[@]}"; do status FAIL "Library missing: $lib"; done
        fi
    fi

    # Extension verification via code --list-extensions (authoritative).
    local final_lc; final_lc=$(code --list-extensions 2>/dev/null | tr '[:upper:]' '[:lower:]')
    local ext lc r
    for ext in "${VSCODE_EXTS[@]}"; do
        lc=$(printf '%s' "$ext" | tr '[:upper:]' '[:lower:]')
        if grep -qx "$lc" <<<"$final_lc"; then
            r=$(_get_ext_result "$ext")
            if [[ "$r" == 'skip' ]]; then
                status SKIP "ext $ext (already installed)"
            else
                status OK "ext $ext"
            fi
            continue
        fi
        status WARN "ext $ext not present after parallel run — retrying"
        _install_one_extension "$ext" || status FAIL "ext $ext could not be installed"
    done
}

# =============================================================================
#  TASK 10 — SMOKE TEST + DIAGNOSTIC STATE
# =============================================================================

render_smoke_project() {
    mkdir -p "$SMOKE_DIR/src"
    local libdeps
    libdeps=$(awk '
        /^[[:space:]]*lib_deps[[:space:]]*=/ {hit=1; next}
        hit && /^[^[:space:]]/ { exit }
        hit { print }
    ' "$WORKSPACE/platformio.ini")
    {
        echo "[platformio]"
        echo "core_dir = $WORKSPACE/.pio-core"
        echo ""
        echo "[env:$PIO_BOARD]"
        echo "platform = $PIO_PLATFORM_PIN"
        echo "board = $PIO_BOARD"
        echo "framework = $PIO_FRAMEWORK"
        echo "monitor_speed = $MONITOR_SPEED"
        echo "upload_speed = $UPLOAD_SPEED"
        echo "lib_extra_dirs = $WORKSPACE/.pio/libdeps/$PIO_BOARD"
        echo "lib_deps ="
        printf '%s\n' "$libdeps"
    } > "$SMOKE_DIR/platformio.ini"
    cat > "$SMOKE_DIR/src/main.cpp" <<'CPP'
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
CPP
}

run_smoke_test() {
    render_smoke_project
    status SMOKE "Compiling XIAO smoke test"
    if ( cd "$SMOKE_DIR" && run_cmd "pio run smoke" -- "$PIO_BIN" run ); then
        write_diag_state passed
        status OK "Environment ready. Plug in your XIAO ESP32C3 to flash."
        return 0
    else
        write_diag_state failed
        status FAIL "Smoke compile failed — see $WORKSPACE_LOG"
        return 1
    fi
}

write_diag_state() {
    local result=$1
    local commit
    commit=$(git -C "$UPSTREAM_DIR" rev-parse HEAD 2>/dev/null || echo "unknown")
    local now; now=$(date -u +%FT%TZ)
    cat > "$DIAG_STATE" <<JSON
{
  "last_setup_completed_at": "$now",
  "last_script_version": "$SCRIPT_VERSION",
  "last_content_commit": "$commit",
  "last_smoke_test": {
    "passed": $( [[ $result == passed ]] && echo true || echo false ),
    "timestamp": "$now",
    "board": "$PIO_BOARD"
  }
}
JSON
}

# =============================================================================
#  TASK 11 — HEALTH-CHECK REGISTRY + MODE DETECTION + REPAIR LOOP
# =============================================================================

# All checks below return 0 if healthy, non-zero otherwise. They MUST be
# read-only — repair_* / ensure_* are the only mutating functions.

check_upstream()       { [[ -d "$UPSTREAM_DIR/.git" ]] && [[ "$(git -C "$UPSTREAM_DIR" remote get-url origin 2>/dev/null)" == "$REPO_URL" ]]; }
check_workspace()      { [[ -d "$WORKSPACE" && ! -d "$WORKSPACE/.git" ]]; }
check_my_robot_code()  {
    [[ -d "$STUDENT_CODE_DIR" ]] \
        && [[ -n "$(find "$STUDENT_CODE_DIR" -mindepth 1 -maxdepth 1 -type f 2>/dev/null)" ]]
}
check_content_match()  {
    local p
    for p in "${INSTRUCTOR_PATHS[@]}"; do
        [[ -e "$UPSTREAM_DIR/$p" ]] || continue
        if [[ -d "$UPSTREAM_DIR/$p" ]]; then
            diff -rq "$UPSTREAM_DIR/$p" "$WORKSPACE/$p" >/dev/null 2>&1 || return 1
        else
            cmp -s "$UPSTREAM_DIR/$p" "$WORKSPACE/$p" || return 1
        fi
    done
}
check_vscode()         {
    refresh_path
    command -v code >/dev/null 2>&1 || return 1
    local ver major minor
    ver=$(code --version 2>/dev/null | head -1) || return 1
    major=${ver%%.*}; minor=${ver#*.}; minor=${minor%%.*}
    (( major > MIN_VSCODE_VERSION_MAJOR )) || \
        (( major == MIN_VSCODE_VERSION_MAJOR && minor >= MIN_VSCODE_VERSION_MINOR ))
}
check_extensions()     {
    command -v code >/dev/null 2>&1 || return 1
    local installed; installed=$(code --list-extensions 2>/dev/null | tr '[:upper:]' '[:lower:]')
    local ext
    for ext in "${VSCODE_EXTS[@]}"; do
        grep -qxF "$(printf '%s' "$ext" | tr '[:upper:]' '[:lower:]')" <<<"$installed" || return 1
    done
}
check_uv()             { refresh_path; command -v uv >/dev/null 2>&1 && uv --version >/dev/null 2>&1; }
check_python()         { [[ -x "$PYTHON_BIN" ]] && "$PYTHON_BIN" --version 2>&1 | grep -q "Python ${PYTHON_VERSION}\."; }
check_pio_venv()       { [[ -x "$PIO_BIN" ]] && ( cd "$WORKSPACE" 2>/dev/null && "$PIO_BIN" --version >/dev/null 2>&1 ) && "$PYTHON_BIN" -m pip --version >/dev/null 2>&1; }
check_esp32() {
    # Incomplete esptoolpy (dir exists, package.json missing) = unhealthy.
    local esptoolpy_dir="$WORKSPACE/.pio-core/packages/tool-esptoolpy"
    [[ -d "$esptoolpy_dir" && ! -f "$esptoolpy_dir/package.json" ]] && return 1
    # Filesystem check — `pio platform list` uses the default ~/.platformio core_dir,
    # not our project-local .pio-core, so it can report empty even when the platform
    # is installed. The toolchain directory is the authoritative signal.
    local pkgs_dir="$WORKSPACE/.pio-core/packages"
    [[ -d "$pkgs_dir" ]] || return 1
    find "$pkgs_dir" -maxdepth 1 -type d -name 'toolchain-xtensa*' 2>/dev/null | grep -q .
}
check_libraries()      {
    [[ -d "$WORKSPACE/.pio/libdeps" ]] || return 1
    local lib pat
    for lib in "${EXPECTED_LIBS[@]}"; do
        pat="${lib%% *}"
        find "$WORKSPACE/.pio/libdeps" -mindepth 2 -maxdepth 3 -type d -iname "*${pat}*" 2>/dev/null | grep -q . || return 1
    done
}
check_project_config() {
    [[ -f "$WORKSPACE/platformio.ini" ]] || return 1
    grep -q '^core_dir = .pio-core' "$WORKSPACE/platformio.ini" || return 1
    grep -q '^src_dir = my_robot_code' "$WORKSPACE/platformio.ini" || return 1
    grep -q '^lib_extra_dirs = robot_core' "$WORKSPACE/platformio.ini" || return 1
    grep -q "^\[env:$PIO_BOARD\]" "$WORKSPACE/platformio.ini" || return 1
    grep -q "^board = $PIO_BOARD" "$WORKSPACE/platformio.ini" || return 1
    grep -q "^framework = $PIO_FRAMEWORK" "$WORKSPACE/platformio.ini" || return 1
}
check_udev_rule() {
    [[ "$OS" == linux ]] || return 0
    [[ -f "$_UDEV_RULE_FILE" ]] && grep -qF "303a" "$_UDEV_RULE_FILE" 2>/dev/null
}

repair_upstream()       { ensure_upstream; }
repair_workspace()      { disable_git_in_workspace; }
repair_content()        { sync_workspace; }
repair_student_code()   { seed_student_code_if_empty; }
repair_vscode()         { ensure_vscode; }
repair_extensions()     { ensure_extensions; }
repair_uv()             { ensure_uv; }
repair_python()         { ensure_python; }
repair_pio_venv() {
    # If PIO works but pip is missing, seed pip only — don't nuke the whole venv.
    if [[ -x "$PIO_BIN" ]] && ! "$PYTHON_BIN" -m pip --version >/dev/null 2>&1; then
        status REPAIR "Seeding pip into .venv (PlatformIO intact)"
        "$PYTHON_BIN" -m ensurepip --upgrade >/dev/null 2>&1 || true
        return
    fi
    rm -rf "$VENV_DIR"
    ensure_venv && ensure_platformio
}
repair_esp32()          { ensure_esp32_platform; }
repair_libraries()      { ensure_libraries; }
repair_project_config() { sync_workspace; }
repair_udev_rule()      { ensure_udev_rule; }

ensure_pio_on_path() {
    local venv_bin="$VENV_DIR/bin"
    local rc_file
    case "${SHELL:-}" in
        */zsh)  rc_file="$HOME/.zshrc" ;;
        */bash) rc_file="$HOME/.bashrc" ;;
        *)      rc_file="" ;;
    esac
    if [[ -n "$rc_file" ]]; then
        # Remove stale entries left from a workspace move.
        if [[ -f "$rc_file" ]]; then
            sed -i.bak '/YSP_TDCS_Makerspace.*\.venv.*bin/d' "$rc_file" \
                && rm -f "${rc_file}.bak"
        fi
        if ! grep -qF "$venv_bin" "$rc_file" 2>/dev/null; then
            printf '\n# YSP TDCS — PlatformIO\nexport PATH="%s:$PATH"\n' "$venv_bin" >> "$rc_file"
            status OK "PlatformIO added to $rc_file"
        fi
    fi
    # Also update the current session so VS Code inherits pio immediately.
    case ":$PATH:" in *":$venv_bin:"*) ;; *) PATH="$venv_bin:$PATH"; export PATH ;; esac
}
check_pio_path() {
    local venv_bin="$VENV_DIR/bin"
    local rc_file
    case "${SHELL:-}" in
        */zsh)  rc_file="$HOME/.zshrc" ;;
        */bash) rc_file="$HOME/.bashrc" ;;
        *)      return 0 ;;
    esac
    [[ -f "$rc_file" ]] && grep -qF "$venv_bin" "$rc_file" 2>/dev/null
}
repair_pio_path() { ensure_pio_on_path; }

# Format: "label:check_fn:repair_fn"
HEALTH_CHECKS=(
    "hidden_content_cache:check_upstream:repair_upstream"
    "student_workspace:check_workspace:repair_workspace"
    "content_files:check_content_match:repair_content"
    "student_code_area:check_my_robot_code:repair_student_code"
    "vscode:check_vscode:repair_vscode"
    "vscode_extensions:check_extensions:repair_extensions"
    "uv:check_uv:repair_uv"
    "python_3_11:check_python:repair_python"
    "platformio_venv:check_pio_venv:repair_pio_venv"
    "pio_path:check_pio_path:repair_pio_path"
    "esp32_platform:check_esp32:repair_esp32"
    "libraries:check_libraries:repair_libraries"
    "project_config:check_project_config:repair_project_config"
    "udev_rule:check_udev_rule:repair_udev_rule"
)

# run_all_health_checks [--quiet]
#   Walks the registry. In quiet mode, returns 1 on the first failure with no
#   output. In loud mode (default), prints each result; for failures, runs the
#   repair and re-checks. Returns 0 iff all checks ultimately pass.
run_all_health_checks() {
    local quiet=0
    [[ "${1:-}" == "--quiet" ]] && quiet=1
    local entry label check repair overall=0
    for entry in "${HEALTH_CHECKS[@]}"; do
        IFS=: read -r label check repair <<<"$entry"
        if "$check"; then
            (( quiet )) || status OK "$label"
        else
            overall=1
            (( quiet )) && return 1
            status FAIL "$label"
            status REPAIR "$label"
            if ! "$repair"; then
                status FAIL "Repair failed: $label"
                return 1
            fi
            if "$check"; then
                status OK "$label (repaired)"
            else
                status FAIL "Still failing after repair: $label"
                return 1
            fi
        fi
    done
    return $overall
}

detect_setup_mode() {
    # Functional detection only — no state file is ever the authority.
    if [[ ! -d "$WORKSPACE" || ! -d "$VENV_DIR" || ! -x "$PIO_BIN" || ! -d "$UPSTREAM_DIR/.git" ]]; then
        echo first_run; return
    fi
    if run_all_health_checks --quiet >/dev/null 2>&1; then
        echo daily
    else
        echo repair
    fi
}

show_first_run_plan() {
    printf '\n'
    if [[ -n "${C_MAGENTA:-}" ]]; then
        printf '  %sFirst-time setup — here is what will happen:%s\n' "$C_BOLD" "$C_RESET"
        printf '  %s(about 10–15 minutes on a fast network)%s\n' "$C_DIM" "$C_RESET"
    else
        printf '  First-time setup — here is what will happen:\n'
        printf '  (about 10-15 minutes on a fast network)\n'
    fi
    # n, title, eta, blurb
    local rows=(
        '1|Preflight|~10s|check internet, disk, clock'
        '2|Python toolchain|1-2 min|install uv + Python 3.11'
        '3|Workspace|30-60s|clone class content, create .venv, install PlatformIO'
        '4|ESP32 platform|3-5 min|download 500 MB toolchain'
        '5|VS Code|1-2 min|install VS Code (if missing)'
        '6|Libraries + extensions|1-2 min|parallel: 6 Arduino libs + 3 VS Code extensions'
        '7|Smoke test|30s|verify the toolchain compiles a tiny sketch'
    )
    local row n t e b
    for row in "${rows[@]}"; do
        IFS='|' read -r n t e b <<<"$row"
        if [[ -n "${C_MAGENTA:-}" ]]; then
            printf '    %s%s.%s %s%-26s%s %s%-10s%s %s%s%s\n' \
                "$C_MAGENTA" "$n" "$C_RESET" \
                "$C_BOLD" "$t" "$C_RESET" \
                "$C_YELLOW" "$e" "$C_RESET" \
                "$C_DIM" "$b" "$C_RESET"
        else
            printf '    %s. %-26s %-10s %s\n' "$n" "$t" "$e" "$b"
        fi
    done
    printf '\n'
}

run_setup_mode() {
    case "$1" in
        first_run)
            show_first_run_plan

            write_phase 'Preflight' 1 7
            discover_mirror

            write_phase 'Python toolchain' 2 7
            ensure_uv
            if ! command -v uv >/dev/null 2>&1; then
                status FAIL "uv missing — halting install (rest of phases would only echo this)"
                stop_phase
                write_final_summary
                open_vscode_if_safe
                return
            fi
            ensure_python

            write_phase 'Workspace' 3 7
            ensure_upstream
            sync_workspace
            seed_student_code_if_empty
            ensure_venv
            ensure_platformio
            ensure_pio_on_path
            local pio_ready=0
            [[ -x "$PIO_BIN" ]] && pio_ready=1
            if (( ! pio_ready )); then
                status FAIL "PlatformIO missing — skipping ESP32 platform, libraries, and smoke test"
            fi

            write_phase 'ESP32 platform (~500 MB)' 4 7
            local esp32_ready=0
            if (( pio_ready )); then
                ensure_esp32_platform || true
                local pkgs_dir="$WORKSPACE/.pio-core/packages"
                if [[ -d "$pkgs_dir" ]] && \
                    find "$pkgs_dir" -maxdepth 1 -type d -name 'toolchain-xtensa*' 2>/dev/null | grep -q .; then
                    esp32_ready=1
                fi
            else
                status SKIP 'ESP32 platform (PIO unavailable)'
            fi

            write_phase 'VS Code' 5 7
            ensure_vscode

            write_phase 'Libraries + extensions (parallel)' 6 7
            if (( pio_ready )); then
                invoke_parallel_libs_and_extensions
            else
                status SKIP 'Libraries (PIO unavailable)'
                ensure_extensions
            fi
            ensure_udev_rule

            write_phase 'Smoke test' 7 7
            if (( pio_ready && esp32_ready )); then
                run_smoke_test || true
            else
                status SKIP 'Smoke test (PIO/ESP32 toolchain unavailable)'
            fi
            stop_phase
            ;;
        daily)
            write_phase 'Daily sync'
            ensure_upstream
            sync_workspace
            seed_student_code_if_empty
            print_port_guidance
            stop_phase
            ;;
        repair)
            write_phase 'Repair'
            ensure_upstream
            sync_workspace
            run_all_health_checks || true
            stop_phase
            ;;
        *) status FAIL "Unknown mode: $1"; return 1 ;;
    esac
}

print_port_guidance() {
    local ports
    if [[ -x "$PIO_BIN" ]]; then
        ports=$( cd "$WORKSPACE" 2>/dev/null && "$PIO_BIN" device list 2>/dev/null | head -20 )
        if [[ -n "$ports" ]]; then
            log "device list:"
            log "$ports"
        fi
    fi
    case "$OS" in
        mac)
            status INFO "If your XIAO is plugged in, look for /dev/cu.usbmodem* or /dev/tty.usbmodem*."
            ;;
        linux)
            status INFO "If your XIAO is plugged in, look for /dev/ttyACM0 (you must log out and back in if you just joined the dialout group)."
            ;;
    esac
    status INFO "If your XIAO ESP32C3 does not appear after plugging in, try a different USB-C cable — many USB-C cables are charge-only."
}

# =============================================================================
#  FINAL SUMMARY + OPEN VS CODE
# =============================================================================

write_final_summary() {
    local header
    case "$MODE" in
        first_run) header="YSP TDCS Makerspace — Setup Complete" ;;
        daily)     header="YSP TDCS Makerspace — Ready" ;;
        repair)    header="YSP TDCS Makerspace — Repair" ;;
        *)         header="YSP TDCS Makerspace" ;;
    esac
    printf '\n%s━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━%s\n' "$C_MAGENTA" "$C_RESET"
    printf '%s             [ Final Summary ]%s\n' "$C_BOLD" "$C_RESET"
    printf '%s━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━%s\n\n' "$C_MAGENTA" "$C_RESET"
    printf '%s\n\n' "$header"
    printf '  %sOK%s      %d\n' "$C_GREEN" "$C_RESET" "$COUNT_OK"
    printf '  %sSKIP%s    %d\n' "$C_DIM"   "$C_RESET" "$COUNT_SKIP"
    printf '  %sREPAIR%s  %d\n' "$C_YELLOW" "$C_RESET" "$COUNT_REPAIR"
    printf '  %sFAIL%s    %d\n\n' "$C_RED" "$C_RESET" "$COUNT_FAIL"
    printf '  Workspace: %s\n' "$WORKSPACE"
    printf '  Log:       %s\n' "$WORKSPACE_LOG"
    if (( COUNT_FAIL > 0 )); then
        printf '\n  %sFailed steps:%s\n' "$C_RED" "$C_RESET"
        local s
        for s in ${FAILED_STEPS[@]+"${FAILED_STEPS[@]}"}; do
            printf '    - %s\n' "$s"
        done
        printf '\n  Setup incomplete — show this screen to an instructor.\n'
    else
        case "$MODE" in
            first_run) printf '\n  All good. Call an instructor to flash your first sketch.\n' ;;
            daily)     printf '\n  Ready to go.\n' ;;
            repair)    printf '\n  Environment repaired.\n' ;;
        esac
    fi
    printf '\n  Full log saved to %s\n' "$WORKSPACE_LOG"
}

configure_vscode_user_settings() {
    # User-level keys are kept narrow on purpose: only things that MUST take
    # effect before any workspace has loaded (trust dialog, chat panel that
    # autostarts globally, PIO Home auto-popup on extension activation,
    # startup walkthrough). Editor / window restoration is workspace-scoped
    # and lives in setup/.vscode/settings.json instead.
    local user_dir
    case "$OS" in
        mac)   user_dir="$HOME/Library/Application Support/Code/User" ;;
        linux) user_dir="$HOME/.config/Code/User" ;;
        *)     return 0 ;;
    esac
    mkdir -p "$user_dir"
    local f="$user_dir/settings.json"
    local venv_bin="$VENV_DIR/bin"
    "$PYTHON_BIN" -c "
import json, sys
f, venv_bin = sys.argv[1], sys.argv[2]
try:
    with open(f) as fh:
        obj = json.load(fh)
except Exception:
    obj = {}
keys = {
    # Trust / startup chrome.
    'security.workspace.trust.enabled': False,
    'workbench.startupEditor': 'none',
    'workbench.welcomePage.walkthroughs.openOnInstall': False,
    'workbench.tips.enabled': False,
    'update.showReleaseNotes': False,
    'extensions.ignoreRecommendations': True,
    # Chat / auxiliary side bar — the built-in Chat extension auto-shows its
    # view regardless of which workspace is open, so suppression must be
    # user-level.
    'workbench.secondarySideBar.visible': False,
    'workbench.auxiliaryBar.visible': False,
    'chat.commandCenter.enabled': False,
    'chat.editor.enabled': False,
    'chat.experimental.offerSetup': False,
    'chat.setupFromDialog': False,
    'chat.welcomeView.enabled': False,
    # PlatformIO — PIO Home pops up on first activation before workspace
    # settings load, so user-level is the only reliable place to disable it.
    'platformio-ide.customPATH': venv_bin,
    'platformio-ide.disablePIOHomeStartup': True,
    'platformio-ide.activateOnlyOnPlatformIOProject': True,
    'platformio-ide.autoOpenPlatformIOIniFile': False,
    'platformio-ide.useBuiltinPIOCore': False,
}
obj.update(keys)
with open(f, 'w') as fh:
    json.dump(obj, fh, indent=2)
" "$f" "$venv_bin" 2>/dev/null || true
}

# VS Code per-workspace layout state (incl. auxiliary-bar visibility) lives in
# ~/.../Code/User/workspaceStorage/<hash>/. The directory name is NOT
# md5(URI) — it's md5(fsPath + ctime|inode), which we can't reproduce from a
# shell. Instead, scan each subdir's workspace.json and match by the `folder`
# URI it records. Reset on first_run so the chat panel doesn't restore from a
# previous session; daily/repair runs leave state alone.
reset_vscode_aux_bar_state() {
    local base
    case "$OS" in
        mac)   base="$HOME/Library/Application Support/Code/User/workspaceStorage" ;;
        linux) base="$HOME/.config/Code/User/workspaceStorage" ;;
        *)     return 0 ;;
    esac
    [[ -d "$base" ]] || return 0
    local want="file://$WORKSPACE"
    local d ws_json
    for d in "$base"/*; do
        [[ -d "$d" ]] || continue
        ws_json="$d/workspace.json"
        [[ -f "$ws_json" ]] || continue
        # workspace.json content for a folder workspace is e.g.
        # {"folder":"file:///Users/student/Desktop/YSP_TDCS_Makerspace"}.
        # Match the exact URI string so we only touch our workspace.
        if grep -qF "\"folder\":\"${want}\"" "$ws_json" 2>/dev/null; then
            if rm -rf "$d" 2>/dev/null; then
                log "Reset VS Code workspace state: $d"
            else
                log "Could not reset VS Code workspace state at $d"
            fi
            return 0
        fi
    done
}

# Probe whether `code --help` advertises a given flag. Cached per-flag via files
# under $STATE_DIR so we don't spawn code --help repeatedly.
test_code_flag_supported() {
    local flag=$1
    local cache_dir="$STATE_DIR/code-flags"
    local safe_flag="${flag//[^a-zA-Z0-9]/_}"
    local cache_file="$cache_dir/$safe_flag"
    if [[ -f "$cache_file" ]]; then
        [[ "$(cat "$cache_file")" == "1" ]]
        return $?
    fi
    mkdir -p "$cache_dir"
    if code --help 2>/dev/null | grep -qF -- "$flag"; then
        printf '1' > "$cache_file"; return 0
    fi
    printf '0' > "$cache_file"; return 1
}

open_vscode_if_safe() {
    [[ -d "$WORKSPACE" && -d "$STUDENT_CODE_DIR" ]] || { status WARN "Skipping VS Code — workspace incomplete"; return; }
    command -v code >/dev/null 2>&1 || { status WARN "code CLI not found; run manually: code $WORKSPACE"; return; }
    if (( COUNT_FAIL > 0 )) && [[ "$MODE" == "first_run" ]]; then
        status WARN "Setup incomplete — not opening VS Code automatically"
        return
    fi

    configure_vscode_user_settings
    # Clear prior workspace layout state only on first_run so the chat aux bar
    # doesn't restore. On daily/repair we trust the user-level settings.
    [[ "$MODE" == "first_run" ]] && reset_vscode_aux_bar_state

    # Open as single-root folder so PIO's workspaceContains:platformio.ini
    # activation fires correctly. Only main.cpp opens — no QUICKSTART.md, no
    # restored tabs (workspace settings cover that).
    local -a code_args=("$WORKSPACE")
    [[ -f "$STUDENT_CODE_DIR/main.cpp" ]] && code_args+=("$STUDENT_CODE_DIR/main.cpp")
    # Newer VS Code (1.94+) supports --disable-chat-setup; older builds error.
    if test_code_flag_supported '--disable-chat-setup'; then
        code_args=('--disable-chat-setup' "${code_args[@]}")
    fi
    if code "${code_args[@]}" 2>/dev/null; then
        status OK "Opened VS Code"
    else
        status WARN "VS Code did not open — run manually: code $WORKSPACE"
    fi
}

# =============================================================================
#  MAIN
# =============================================================================

main() {
    init_console
    start_setup_log
    migrate_workspace_if_needed
    run_local_bootstrap_checks
    MODE=$(detect_setup_mode)
    log "Detected mode: $MODE"
    # Network checks (clock, HTTPS) only when something needs downloading/repairing.
    [[ "$MODE" != "daily" ]] && run_network_bootstrap_checks
    run_setup_mode "$MODE"
    write_final_summary
    open_vscode_if_safe
}

# Only run main when executed directly, not when sourced (e.g. by Bats tests).
# TDCS_TEST_NO_MAIN=1 also suppresses execution for tests that exec the file.
# When piped via `curl | bash`, BASH_SOURCE is unset; fall back to $0 so main still runs.
if [[ "${BASH_SOURCE[0]:-$0}" == "${0}" ]] && [[ -z "${TDCS_TEST_NO_MAIN:-}" ]]; then
    main "$@"
fi
