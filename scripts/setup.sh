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

MIN_DISK_GB_HARD=5
MIN_DISK_GB_WARN=8
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
    ronnie-robot.code-workspace
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
    ms-vscode.cpptools
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

run_bootstrap_checks() {
    detect_os
    check_disk_space
    check_clock_skew
    check_write_access
    check_https_reachable
    discover_mirror
}

# =============================================================================
#  TASK 14 — MIRROR CONSUMPTION (single point of truth)
# =============================================================================

# mirror_url_for CATEGORY NAME → prints URL on stdout, exits 0; or exits 1
mirror_url_for() {
    local category=$1 name=$2
    [[ -n "$MIRROR_BASE" && -f "$MIRROR_MANIFEST" ]] || return 1
    # The manifest is a single JSON object; each artifact has its own line.
    # We don't have jq before Python is installed, so use grep/sed against the
    # known one-line-per-artifact layout that prefetch-and-serve.sh writes.
    grep -F "\"category\":\"$category\"" "$MIRROR_MANIFEST" 2>/dev/null \
        | grep -F "\"name\":\"$name\"" \
        | head -1 \
        | sed -E 's/.*"url":"([^"]+)".*/\1/'
}

mirror_sha256_for() {
    local category=$1 name=$2
    [[ -n "$MIRROR_BASE" && -f "$MIRROR_MANIFEST" ]] || return 1
    grep -F "\"category\":\"$category\"" "$MIRROR_MANIFEST" 2>/dev/null \
        | grep -F "\"name\":\"$name\"" \
        | head -1 \
        | sed -E 's/.*"sha256":"([^"]+)".*/\1/'
}

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
    if [[ -x "$PYTHON_BIN" ]] && "$PYTHON_BIN" --version 2>&1 | grep -q "Python ${PYTHON_VERSION}\."; then
        status SKIP ".venv already on Python $PYTHON_VERSION"
        return 0
    fi
    status REPAIR "Creating $VENV_DIR"
    ( cd "$WORKSPACE" && run_cmd "uv venv" -- uv venv --python "$PYTHON_VERSION" .venv ) \
        || { status FAIL "uv venv failed"; return 1; }
    status OK ".venv on Python $("$PYTHON_BIN" --version | awk '{print $2}')"
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
    if ( cd "$WORKSPACE" && "$PIO_BIN" platform list --json-output 2>/dev/null \
            | grep -Fq "$PIO_PLATFORM_PIN" ); then
        status SKIP "$PIO_PLATFORM_PIN already installed"
        return 0
    fi
    status INSTALL "Downloading ESP32 toolchain (~500 MB) — 3–5 minutes, please wait..."
    ( cd "$WORKSPACE" && run_cmd "pio platform install" -- "$PIO_BIN" platform install "$PIO_PLATFORM_PIN" ) \
        || { status FAIL "ESP32 platform install failed"; return 1; }
    status OK "ESP32 platform installed"
}

ensure_libraries() {
    [[ -f "$WORKSPACE/platformio.ini" ]] || { status FAIL "platformio.ini missing"; return 1; }
    ( cd "$WORKSPACE" && run_cmd "pio pkg install" -- "$PIO_BIN" pkg install ) \
        || { status FAIL "pio pkg install failed"; return 1; }
    local lib missing=0
    for lib in "${EXPECTED_LIBS[@]}"; do
        # libdeps folder names mangle spaces to underscores or hyphens; do a
        # tolerant match against the library's display name first token.
        local pat="${lib%% *}"
        if find "$WORKSPACE/.pio/libdeps" -mindepth 2 -maxdepth 3 -type d \
                -iname "*${pat}*" 2>/dev/null | grep -q .; then
            continue
        fi
        status FAIL "Library missing: $lib"
        missing=$((missing + 1))
    done
    (( missing == 0 )) || return 1
    status OK "Libraries installed: ${#EXPECTED_LIBS[@]}/${#EXPECTED_LIBS[@]}"
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
    local dmg="$STATE_DIR/VSCode.dmg"
    local internet="https://code.visualstudio.com/sha/download?build=stable&os=darwin-universal"
    status INSTALL "Downloading VS Code"
    fetch_artifact vscode "VSCode-darwin-universal.dmg" "$internet" "$dmg" \
        || { status FAIL "VS Code download failed"; return 1; }
    local mnt; mnt=$(hdiutil attach "$dmg" -nobrowse -quiet | awk '/Apple_HFS|\/Volumes/{print $NF; exit}')
    [[ -n "$mnt" && -d "$mnt" ]] || { status FAIL "VS Code DMG mount failed"; return 1; }
    rm -rf "/Applications/Visual Studio Code.app"
    cp -R "$mnt/Visual Studio Code.app" "/Applications/" \
        || { hdiutil detach "$mnt" -quiet || true; status FAIL "VS Code copy to /Applications failed (try Terminal with Full Disk Access)"; return 1; }
    hdiutil detach "$mnt" -quiet || true
    _ensure_code_symlink_mac
    code --version >/dev/null 2>&1 || { status FAIL "VS Code not runnable after install"; return 1; }
    status OK "VS Code installed"
}

_ensure_code_symlink_mac() {
    [[ "$OS" == mac ]] || return 0
    if command -v code >/dev/null 2>&1; then return 0; fi
    local target="/Applications/Visual Studio Code.app/Contents/Resources/app/bin/code"
    [[ -x "$target" ]] || return 0
    # Try without sudo first (in case /usr/local/bin is writable).
    if ln -sf "$target" /usr/local/bin/code 2>/dev/null; then return 0; fi
    if command -v sudo >/dev/null 2>&1; then
        sudo -n ln -sf "$target" /usr/local/bin/code 2>/dev/null && return 0
        status INFO "Creating /usr/local/bin/code symlink (sudo password)"
        sudo ln -sf "$target" /usr/local/bin/code || status WARN "Could not create code CLI symlink"
    fi
}

_install_vscode_linux() {
    local pkg
    if command -v apt-get >/dev/null 2>&1; then
        pkg="$STATE_DIR/code.deb"
        local internet="https://go.microsoft.com/fwlink/?LinkID=760868"
        fetch_artifact vscode "code-amd64.deb" "$internet" "$pkg" \
            || { status FAIL "VS Code .deb download failed"; return 1; }
        run_cmd "apt install code" -- sudo apt-get install -y "$pkg" \
            || { status FAIL "apt install failed"; return 1; }
    elif command -v dnf >/dev/null 2>&1; then
        pkg="$STATE_DIR/code.rpm"
        local internet="https://packages.microsoft.com/yumrepos/vscode/code-1.x86_64.rpm"
        fetch_artifact vscode "code-x86_64.rpm" "$internet" "$pkg" \
            || { status FAIL "VS Code .rpm download failed"; return 1; }
        run_cmd "dnf install code" -- sudo dnf install -y "$pkg" \
            || { status FAIL "dnf install failed"; return 1; }
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
    local ext lc
    for ext in "${VSCODE_EXTS[@]}"; do
        lc=$(printf '%s' "$ext" | tr '[:upper:]' '[:lower:]')
        if grep -qx "$lc" <<<"$installed"; then
            status SKIP "ext $ext"
            continue
        fi
        _install_one_extension "$ext" || _install_one_extension "$ext" || \
            { status FAIL "ext $ext could not be installed"; continue; }
    done
}

_install_one_extension() {
    local ext=$1
    local vsix="$STATE_DIR/$ext.vsix"
    if [[ -n "$MIRROR_BASE" ]] && mirror_url_for vsix "$ext.vsix" >/dev/null 2>&1; then
        fetch_artifact vsix "$ext.vsix" "" "$vsix" \
            && run_cmd "ext install $ext (vsix)" -- code --install-extension "$vsix" \
            && status OK "ext $ext" && return 0
    fi
    run_cmd "ext install $ext (marketplace)" -- code --install-extension "$ext" \
        && status OK "ext $ext"
}

# =============================================================================
#  TASK 10 — SMOKE TEST + DIAGNOSTIC STATE
# =============================================================================

render_smoke_project() {
    mkdir -p "$SMOKE_DIR/src"
    local libdeps
    libdeps=$(awk '
        /^[[:space:]]*lib_deps[[:space:]]*=/ {hit=1; next}
        hit && /^[[:space:]]*[A-Za-z]/ { exit }
        hit && /^[[:space:]]/ { print }
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
check_pio_venv()       { [[ -x "$PIO_BIN" ]] && ( cd "$WORKSPACE" 2>/dev/null && "$PIO_BIN" --version >/dev/null 2>&1 ); }
check_esp32()          { ( cd "$WORKSPACE" 2>/dev/null && "$PIO_BIN" platform list --json-output 2>/dev/null | grep -Fq "$PIO_PLATFORM_PIN" ); }
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
repair_pio_venv()       { rm -rf "$VENV_DIR"; ensure_venv && ensure_platformio; }
repair_esp32()          { ensure_esp32_platform; }
repair_libraries()      { ensure_libraries; }
repair_project_config() { sync_workspace; }
repair_udev_rule()      { ensure_udev_rule; }

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

run_setup_mode() {
    case "$1" in
        first_run)
            status INFO "First run — installing everything (10–15 minutes)"
            ensure_uv
            ensure_python
            ensure_upstream
            sync_workspace
            seed_student_code_if_empty
            ensure_venv
            ensure_platformio
            ensure_esp32_platform
            ensure_libraries
            ensure_vscode
            ensure_extensions
            ensure_udev_rule
            run_smoke_test || true
            ;;
        daily)
            ensure_upstream
            sync_workspace
            seed_student_code_if_empty
            run_all_health_checks
            print_port_guidance
            ;;
        repair)
            status INFO "Repairing environment"
            ensure_upstream
            sync_workspace
            run_all_health_checks
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

open_vscode_if_safe() {
    [[ -d "$WORKSPACE" && -d "$STUDENT_CODE_DIR" ]] || { status WARN "Skipping VS Code — workspace incomplete"; return; }
    command -v code >/dev/null 2>&1 || { status WARN "code CLI not found; run manually: code $WORKSPACE"; return; }
    if (( COUNT_FAIL > 0 )) && [[ "$MODE" == "first_run" ]]; then
        status WARN "Setup incomplete — not opening VS Code automatically"
        return
    fi

    local workspace_file="$WORKSPACE/ronnie-robot.code-workspace"

    if [[ -f "$workspace_file" ]]; then
        local -a code_args=("$workspace_file")
        [[ "$MODE" == "first_run" ]] && code_args+=("$WORKSPACE/QUICKSTART.md")
        [[ -f "$STUDENT_CODE_DIR/main.cpp" ]] && code_args+=("$STUDENT_CODE_DIR/main.cpp")
        if code "${code_args[@]}" 2>/dev/null; then
            status OK "Opened RonnieRobot workspace"
        else
            status WARN "VS Code did not open — run manually: code $workspace_file"
        fi
    else
        status WARN "No workspace file — opening workspace folder"
        code "$WORKSPACE" 2>/dev/null \
            || status WARN "VS Code did not open — run manually: code $WORKSPACE"
    fi
}

# =============================================================================
#  MAIN
# =============================================================================

main() {
    init_console
    start_setup_log
    run_bootstrap_checks
    MODE=$(detect_setup_mode)
    log "Detected mode: $MODE"
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
