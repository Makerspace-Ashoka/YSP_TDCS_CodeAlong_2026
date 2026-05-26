#!/usr/bin/env bash
# YSP TDCS Makerspace — instructor mirror prefetch + serve.
#
# Run on ONE instructor laptop the evening before each session. Downloads all
# pinned setup inputs to ./mirror/, writes manifest.json with checksums, then
# serves ./mirror/ over HTTP on port 8080 and advertises ysp-mirror.local via
# mDNS. Students' setup scripts discover this automatically.
#
# Subsequent runs verify checksums and re-download only changed/missing files.

set -euo pipefail
IFS=$'\n\t'

# =============================================================================
#  CONFIG
# =============================================================================

MIRROR_PORT="${MIRROR_PORT:-8080}"
MIRROR_HOST="ysp-mirror"
MIRROR_DIR="./mirror"
MANIFEST="$MIRROR_DIR/manifest.json"

REPO_ROOT=$(cd "$(dirname "$0")" && pwd)
PIO_INI="$REPO_ROOT/platformio.ini"
REQS="$REPO_ROOT/requirements.txt"
EXT_JSON="$REPO_ROOT/.vscode/extensions.json"

UV_VERSION="${UV_VERSION:-latest}"

# Target artifact URLs. Versions are filled in below from the pinned config.
UV_DARWIN_ARM64="https://github.com/astral-sh/uv/releases/latest/download/uv-aarch64-apple-darwin.tar.gz"
UV_DARWIN_X86_64="https://github.com/astral-sh/uv/releases/latest/download/uv-x86_64-apple-darwin.tar.gz"
UV_LINUX_X86_64="https://github.com/astral-sh/uv/releases/latest/download/uv-x86_64-unknown-linux-gnu.tar.gz"
UV_LINUX_ARM64="https://github.com/astral-sh/uv/releases/latest/download/uv-aarch64-unknown-linux-gnu.tar.gz"
UV_WINDOWS_X86_64="https://github.com/astral-sh/uv/releases/latest/download/uv-x86_64-pc-windows-msvc.zip"
UV_INSTALLER_SH="https://astral.sh/uv/install.sh"
UV_INSTALLER_PS1="https://astral.sh/uv/install.ps1"

VSCODE_DARWIN_UNI="https://code.visualstudio.com/sha/download?build=stable&os=darwin-universal"
VSCODE_WIN_X64="https://code.visualstudio.com/sha/download?build=stable&os=win32-x64-user"
VSCODE_LINUX_DEB="https://go.microsoft.com/fwlink/?LinkID=760868"
VSCODE_LINUX_RPM="https://packages.microsoft.com/yumrepos/vscode/code-1.94.2-1727975614.el8.x86_64.rpm"

# =============================================================================
#  HELPERS
# =============================================================================

C_RESET=""; C_GREEN=""; C_RED=""; C_YELLOW=""; C_CYAN=""; C_BOLD=""
if [[ -t 1 ]] && [[ -z "${NO_COLOR:-}" ]] && command -v tput >/dev/null 2>&1; then
    C_RESET=$(tput sgr0); C_BOLD=$(tput bold)
    C_GREEN=$(tput setaf 2); C_RED=$(tput setaf 1)
    C_YELLOW=$(tput setaf 3); C_CYAN=$(tput setaf 6)
fi

info() { printf '%s[INFO]%s %s\n' "$C_CYAN"  "$C_RESET" "$*"; }
ok()   { printf '%s[OK]%s   %s\n' "$C_GREEN" "$C_RESET" "$*"; }
warn() { printf '%s[WARN]%s %s\n' "$C_YELLOW" "$C_RESET" "$*"; }
fail() { printf '%s[FAIL]%s %s\n' "$C_RED" "$C_RESET" "$*"; exit 1; }

sha256() {
    if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | awk '{print $1}'
    else shasum -a 256 "$1" | awk '{print $1}'; fi
}

human_size() {
    local b=$1
    if (( b < 1024 )); then echo "${b}B"
    elif (( b < 1048576 )); then printf "%.1fK" "$(echo "$b/1024" | bc -l)"
    elif (( b < 1073741824 )); then printf "%.1fM" "$(echo "$b/1048576" | bc -l)"
    else printf "%.2fG" "$(echo "$b/1073741824" | bc -l)"
    fi
}

# fetch_to CATEGORY NAME URL  →  downloads if missing or sha changed
fetch_to() {
    local category=$1 name=$2 url=$3
    local dir="$MIRROR_DIR/$category"
    local out="$dir/$name"
    mkdir -p "$dir"
    if [[ -f "$out" ]]; then
        # Re-check checksum on subsequent runs to detect corruption.
        local existing_sha; existing_sha=$(sha256 "$out")
        if grep -q "\"name\":\"$name\".*\"sha256\":\"$existing_sha\"" "$MANIFEST" 2>/dev/null; then
            ok "Cached: $category/$name ($(human_size "$(stat -f%z "$out" 2>/dev/null || stat -c%s "$out")"))"
            ARTIFACTS+=("$category|$name|$url|$existing_sha|$(stat -f%z "$out" 2>/dev/null || stat -c%s "$out")")
            return 0
        fi
        rm -f "$out"
    fi
    info "Fetching $category/$name"
    if ! curl -fL --progress-bar --max-time 600 -o "$out" "$url"; then
        warn "Skipping $name (download failed)"
        return 1
    fi
    local size sha
    size=$(stat -f%z "$out" 2>/dev/null || stat -c%s "$out")
    sha=$(sha256 "$out")
    ARTIFACTS+=("$category|$name|$url|$sha|$size")
    ok "Stored $category/$name ($(human_size "$size"))"
}

# =============================================================================
#  PRECHECKS
# =============================================================================

[[ -f "$PIO_INI"  ]] || fail "platformio.ini not found at $PIO_INI"
[[ -f "$REQS"     ]] || fail "requirements.txt not found at $REQS"
[[ -f "$EXT_JSON" ]] || fail ".vscode/extensions.json not found at $EXT_JSON"

if grep -q '<TESTED>' "$PIO_INI"; then
    fail "platformio.ini still contains <TESTED> placeholders — freeze pins first (Task 17)"
fi

command -v curl >/dev/null 2>&1 || fail "curl is required"
command -v python3 >/dev/null 2>&1 || fail "python3 is required (for the HTTP server)"
command -v uv >/dev/null 2>&1 || fail "uv is required to prefetch Python wheels (install from https://astral.sh/uv)"

# =============================================================================
#  PARSE PINS
# =============================================================================

PIO_PLATFORM=$(awk -F' *= *' '/^platform *=/ {print $2; exit}' "$PIO_INI")
[[ "$PIO_PLATFORM" == *"<TESTED>"* ]] && fail "platform pin still <TESTED>"
info "Pinned platform: $PIO_PLATFORM"

mapfile -t LIB_PINS < <(awk '
    /^[[:space:]]*lib_deps *=/ {hit=1; next}
    hit && /^[[:space:]]*[A-Za-z\[]/ { exit }
    hit && /^[[:space:]]/ { sub(/^[[:space:]]+/, ""); print }
' "$PIO_INI")

[[ ${#LIB_PINS[@]} -gt 0 ]] || fail "No lib_deps found in platformio.ini"
info "Library pins: ${#LIB_PINS[@]}"
for l in "${LIB_PINS[@]}"; do printf '   - %s\n' "$l"; done

mapfile -t EXT_IDS < <(python3 -c '
import json,sys
with open(sys.argv[1]) as f:
    print("\n".join(json.load(f)["recommendations"]))
' "$EXT_JSON")
info "VS Code extensions: ${#EXT_IDS[@]}"

# =============================================================================
#  PREFETCH
# =============================================================================

ARTIFACTS=()
mkdir -p "$MIRROR_DIR"

info "1/5 uv binaries"
fetch_to uv install.sh                       "$UV_INSTALLER_SH"
fetch_to uv install.ps1                      "$UV_INSTALLER_PS1"
fetch_to uv uv-aarch64-apple-darwin.tar.gz   "$UV_DARWIN_ARM64"
fetch_to uv uv-x86_64-apple-darwin.tar.gz    "$UV_DARWIN_X86_64"
fetch_to uv uv-x86_64-unknown-linux-gnu.tar.gz "$UV_LINUX_X86_64"
fetch_to uv uv-aarch64-unknown-linux-gnu.tar.gz "$UV_LINUX_ARM64"
fetch_to uv uv-x86_64-pc-windows-msvc.zip    "$UV_WINDOWS_X86_64"

info "2/5 VS Code installers"
fetch_to vscode VSCode-darwin-universal.dmg "$VSCODE_DARWIN_UNI"
fetch_to vscode VSCodeSetup-x64.exe         "$VSCODE_WIN_X64"
fetch_to vscode code-amd64.deb              "$VSCODE_LINUX_DEB"
fetch_to vscode code-x86_64.rpm             "$VSCODE_LINUX_RPM" || warn "RPM URL needs manual freeze"

info "3/5 VS Code extensions (.vsix)"
mkdir -p "$MIRROR_DIR/vsix"
for ext in "${EXT_IDS[@]}"; do
    pub=${ext%%.*}; pkg=${ext#*.}
    # Open-vsx is the most reliable HTTP-cacheable source.
    url="https://open-vsx.org/api/$pub/$pkg/latest/file/$pub.$pkg.vsix"
    out_name="$ext.vsix"
    fetch_to vsix "$out_name" "$url" || warn "vsix $ext not available on open-vsx; instructors should fetch from Marketplace manually"
done

info "4/5 Python wheels"
mkdir -p "$MIRROR_DIR/wheels"
if uv pip download --dest "$MIRROR_DIR/wheels" -r "$REQS" 2>&1 | tee /tmp/ysp-wheel-fetch.log >/dev/null; then
    # Add each downloaded wheel to the manifest.
    while IFS= read -r whl; do
        size=$(stat -f%z "$whl" 2>/dev/null || stat -c%s "$whl")
        sha=$(sha256 "$whl")
        name=$(basename "$whl")
        ARTIFACTS+=("wheels|$name|local|$sha|$size")
    done < <(find "$MIRROR_DIR/wheels" -type f -name '*.whl')
    ok "Stored $(find "$MIRROR_DIR/wheels" -name '*.whl' | wc -l | tr -d ' ') wheels"
else
    warn "uv pip download exited non-zero — see /tmp/ysp-wheel-fetch.log"
fi

info "5/5 PlatformIO packages and Arduino libraries"
# Spin up a throwaway PlatformIO project that mirrors platformio.ini, run a
# package fetch into a project-local core_dir, then copy the cached archives
# into ./mirror/pio-packages/.
# The throwaway uses the real platformio.ini, which sets src_dir = my_robot_code,
# so the placeholder sketch must live there (not in src/) for any compile step
# to find it. `pio pkg install` doesn't compile, but mirror this for correctness.
THROWAWAY=$(mktemp -d -t ysp-pio.XXXXXX)
cp "$PIO_INI" "$THROWAWAY/platformio.ini"
mkdir -p "$THROWAWAY/my_robot_code"
cat > "$THROWAWAY/my_robot_code/main.cpp" <<'CPP'
#include <Arduino.h>
void setup(){} void loop(){}
CPP
THROWAWAY_VENV="$THROWAWAY/.venv"
( cd "$THROWAWAY" && uv venv --python 3.11 .venv && uv pip install --python .venv -r "$REQS" )
if [[ -x "$THROWAWAY_VENV/bin/pio" ]]; then
    ( cd "$THROWAWAY" && "$THROWAWAY_VENV/bin/pio" pkg install ) \
        || warn "pio pkg install reported errors — review log"
    mkdir -p "$MIRROR_DIR/pio-packages"
    if [[ -d "$THROWAWAY/.pio-core/packages" ]]; then
        find "$THROWAWAY/.pio-core/packages" -mindepth 1 -maxdepth 1 -type d \
            | while read -r pkgdir; do
                name=$(basename "$pkgdir")
                tar -C "$THROWAWAY/.pio-core/packages" -czf "$MIRROR_DIR/pio-packages/${name}.tar.gz" "$name"
                size=$(stat -f%z "$MIRROR_DIR/pio-packages/${name}.tar.gz" 2>/dev/null || stat -c%s "$MIRROR_DIR/pio-packages/${name}.tar.gz")
                sha=$(sha256 "$MIRROR_DIR/pio-packages/${name}.tar.gz")
                ARTIFACTS+=("pio-packages|${name}.tar.gz|local|$sha|$size")
              done
    fi
    if [[ -d "$THROWAWAY/.pio/libdeps" ]]; then
        mkdir -p "$MIRROR_DIR/libraries"
        find "$THROWAWAY/.pio/libdeps" -mindepth 2 -maxdepth 2 -type d \
            | while read -r libdir; do
                name=$(basename "$libdir")
                tar -C "$(dirname "$libdir")" -czf "$MIRROR_DIR/libraries/${name}.tar.gz" "$name"
                size=$(stat -f%z "$MIRROR_DIR/libraries/${name}.tar.gz" 2>/dev/null || stat -c%s "$MIRROR_DIR/libraries/${name}.tar.gz")
                sha=$(sha256 "$MIRROR_DIR/libraries/${name}.tar.gz")
                ARTIFACTS+=("libraries|${name}.tar.gz|local|$sha|$size")
              done
    fi
fi
rm -rf "$THROWAWAY"

# =============================================================================
#  PING ENDPOINT + MANIFEST
# =============================================================================

echo 'pong' > "$MIRROR_DIR/ping"

{
    printf '{\n'
    printf '  "generated_at": "%s",\n' "$(date -u +%FT%TZ)"
    printf '  "platform_pin": "%s",\n' "$PIO_PLATFORM"
    printf '  "artifacts": [\n'
    local first=1
    for a in "${ARTIFACTS[@]}"; do
        IFS='|' read -r category name url sha size <<<"$a"
        if (( first )); then first=0; else printf ',\n'; fi
        printf '    {"category":"%s","name":"%s","url":"http://%s.local:%s/%s/%s","size":%s,"sha256":"%s"}' \
            "$category" "$name" "$MIRROR_HOST" "$MIRROR_PORT" "$category" "$name" "$size" "$sha"
    done
    printf '\n  ]\n}\n'
} > "$MANIFEST"

TOTAL_BYTES=0
for a in "${ARTIFACTS[@]}"; do
    IFS='|' read -r _ _ _ _ size <<<"$a"
    TOTAL_BYTES=$((TOTAL_BYTES + size))
done

# =============================================================================
#  ANNOUNCE
# =============================================================================

LOCAL_IP=""
case "$(uname -s)" in
    Darwin) LOCAL_IP=$(ipconfig getifaddr en0 2>/dev/null || ipconfig getifaddr en1 2>/dev/null) ;;
    Linux)  LOCAL_IP=$(hostname -I 2>/dev/null | awk '{print $1}') ;;
esac

case "$(uname -s)" in
    Darwin)
        # Bonjour built in.
        dns-sd -R "$MIRROR_HOST" _http._tcp local "$MIRROR_PORT" >/dev/null 2>&1 &
        MDNS_PID=$!
        ;;
    Linux)
        if ! command -v avahi-publish-service >/dev/null 2>&1; then
            warn "avahi-publish-service not found — install avahi-daemon and avahi-utils"
            MDNS_PID=""
        else
            avahi-publish-service "$MIRROR_HOST" _http._tcp "$MIRROR_PORT" >/dev/null 2>&1 &
            MDNS_PID=$!
        fi
        ;;
    *) MDNS_PID="" ;;
esac

trap '[[ -n "${MDNS_PID:-}" ]] && kill "$MDNS_PID" 2>/dev/null; kill $SERVE_PID 2>/dev/null; exit 0' INT TERM

# =============================================================================
#  SERVE
# =============================================================================

python3 -m http.server "$MIRROR_PORT" --directory "$MIRROR_DIR" --bind 0.0.0.0 &
SERVE_PID=$!

cat <<EOF

${C_BOLD}Mirror live at http://$MIRROR_HOST.local:$MIRROR_PORT${C_RESET}
Direct IP if mDNS fails: http://${LOCAL_IP:-<unknown>}:$MIRROR_PORT

Artifacts: ${#ARTIFACTS[@]}
Size:      $(human_size "$TOTAL_BYTES")
Manifest:  $MANIFEST

${C_YELLOW}Keep this terminal open until class ends. Press Ctrl+C to stop.${C_RESET}

EOF

wait $SERVE_PID
