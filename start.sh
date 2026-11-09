#!/bin/bash
# AudioCap launcher: build, test and open the app with one command.
# macOS only (process taps are a macOS CoreAudio API). Compatible with the
# bash 3.2 that ships with macOS: no associative arrays, no `wait -n`,
# no `${var,,}`, BSD userland only.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT="$ROOT_DIR/AudioCap.xcodeproj"
SCHEME="AudioCap"
TEST_TARGET="AudioCapTests"
CONFIGURATION="Release"
BUILD_DIR="$ROOT_DIR/build"
DERIVED_DATA="$BUILD_DIR/DerivedData"
APP_PATH="$BUILD_DIR/AudioCap.app"
LOCAL_XCCONFIG="$ROOT_DIR/AudioCap/Config/Local.xcconfig"
MIN_MACOS="14.4"
MIN_XCODE_MAJOR=16
BUILD_TIMEOUT="${AUDIOCAP_BUILD_TIMEOUT:-900}"
TEST_TIMEOUT="${AUDIOCAP_TEST_TIMEOUT:-900}"
LIST_TIMEOUT=120

usage() {
    cat <<'USAGE'
Usage: ./start.sh [option]

  (no option)          Build AudioCap (Release) into ./build and open it.
  --no-open            Build into ./build but do not open the app.
  --test               Run the unit tests (scheme AudioCap, target AudioCapTests).
  --install-driver     Install the AudioCap Hi-Res virtual device (not available yet).
  --uninstall-driver   Remove the AudioCap Hi-Res virtual device (not available yet).
  -h, --help           Show this help.

Signing: the build is ad-hoc signed ("Sign to Run Locally") unless the
git-ignored file AudioCap/Config/Local.xcconfig sets your team, e.g.:

    DEVELOPMENT_TEAM = ABCDE12345

Environment: AUDIOCAP_BUILD_TIMEOUT and AUDIOCAP_TEST_TIMEOUT (seconds,
default 900) bound xcodebuild so the script can never hang.
USAGE
}

say()  { printf '==> %s\n' "$*"; }
warn() { printf 'warning: %s\n' "$*" >&2; }
die()  { local code="${2:-1}"; printf 'error: %s\n' "$1" >&2; exit "$code"; }

# Run a command with a time limit. Uses timeout/gtimeout when installed,
# otherwise perl's alarm (always present on macOS).
with_timeout() {
    local secs="$1"; shift
    if command -v timeout >/dev/null 2>&1; then
        timeout "$secs" "$@"
    elif command -v gtimeout >/dev/null 2>&1; then
        gtimeout "$secs" "$@"
    else
        perl -e '$s = shift @ARGV; alarm $s; exec { $ARGV[0] } @ARGV or die "exec $ARGV[0]: $!\n"' "$secs" "$@"
    fi
}

explain_timeout() {
    # 124: timeout/gtimeout, 142: SIGALRM from the perl fallback.
    local rc="$1" what="$2" secs="$3"
    if [ "$rc" -eq 124 ] || [ "$rc" -eq 142 ]; then
        die "$what did not finish within ${secs}s and was stopped. Raise the limit with the matching AUDIOCAP_*_TIMEOUT variable if your Mac is slow." "$rc"
    fi
}

version_at_least() {
    # version_at_least 14.6.1 14.4 -> true. Compares major.minor.patch numerically.
    local IFS=.
    local a1=0 a2=0 a3=0 b1=0 b2=0 b3=0
    read -r a1 a2 a3 <<< "$1.0.0"
    read -r b1 b2 b3 <<< "$2.0.0"
    a2="${a2:-0}"; a3="${a3:-0}"; b2="${b2:-0}"; b3="${b3:-0}"
    if [ "$a1" -ne "$b1" ]; then [ "$a1" -gt "$b1" ]; return; fi
    if [ "$a2" -ne "$b2" ]; then [ "$a2" -gt "$b2" ]; return; fi
    [ "$a3" -ge "$b3" ]
}

check_platform() {
    if [ "$(uname -s)" != "Darwin" ]; then
        die "AudioCap only runs on macOS. It records other apps through CoreAudio process taps, an Apple API that does not exist on Windows or Linux, so there is nothing to build here."
    fi
    local os
    os="$(sw_vers -productVersion)"
    if ! version_at_least "$os" "$MIN_MACOS"; then
        die "macOS $os is too old: process taps need macOS $MIN_MACOS or later."
    fi
}

check_xcode() {
    if ! command -v xcodebuild >/dev/null 2>&1; then
        die "xcodebuild was not found. Install Xcode from the App Store (https://apps.apple.com/app/xcode/id497799835), open it once to finish the setup, then run ./start.sh again."
    fi
    local version_output
    if ! version_output="$(with_timeout "$LIST_TIMEOUT" xcodebuild -version 2>&1)"; then
        case "$version_output" in
            *"requires Xcode"*|*"command line tools instance"*)
                die "Only the Command Line Tools are selected, but building AudioCap needs the full Xcode app. Install Xcode from the App Store, then run: sudo xcode-select --switch /Applications/Xcode.app" ;;
            *"license"*)
                die "The Xcode license has not been accepted yet. Run: sudo xcodebuild -license accept" ;;
            *)
                die "xcodebuild -version failed: $version_output" ;;
        esac
    fi
    local xcode_version major
    xcode_version="$(printf '%s\n' "$version_output" | sed -n 's/^Xcode \([0-9][0-9.]*\).*/\1/p' | head -n 1)"
    major="${xcode_version%%.*}"
    if [ -n "$major" ] && [ "$major" -lt "$MIN_XCODE_MAJOR" ]; then
        die "Xcode $xcode_version is too old: AudioCap needs Xcode $MIN_XCODE_MAJOR or later."
    fi
    say "Using Xcode ${xcode_version:-unknown} ($(xcode-select -p))"
}

# Fills SIGNING_ARGS. Ad-hoc unless Local.xcconfig names a team.
SIGNING_ARGS=()
configure_signing() {
    local team=""
    if [ -f "$LOCAL_XCCONFIG" ]; then
        team="$(sed -n 's/^[[:space:]]*DEVELOPMENT_TEAM[[:space:]]*=[[:space:]]*\([A-Za-z0-9]*\).*/\1/p' "$LOCAL_XCCONFIG" | tail -n 1)"
    fi
    if [ -n "$team" ]; then
        say "Signing with team $team (from AudioCap/Config/Local.xcconfig)"
        SIGNING_ARGS=(DEVELOPMENT_TEAM="$team" CODE_SIGN_STYLE=Automatic -allowProvisioningUpdates)
    else
        say "Signing ad-hoc (no team in AudioCap/Config/Local.xcconfig)"
        SIGNING_ARGS=(CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM= PROVISIONING_PROFILE_SPECIFIER=)
    fi
}

project_listing() {
    with_timeout "$LIST_TIMEOUT" xcodebuild -list -project "$PROJECT" 2>/dev/null
}

check_scheme() {
    local listing
    if ! listing="$(project_listing)"; then
        die "Could not read $PROJECT with xcodebuild -list."
    fi
    if ! printf '%s\n' "$listing" | sed -n '/Schemes:/,$p' | grep -qx "[[:space:]]*$SCHEME"; then
        die "The Xcode project has no '$SCHEME' scheme."
    fi
}

build_app() {
    check_scheme
    configure_signing
    mkdir -p "$BUILD_DIR"
    say "Building $SCHEME ($CONFIGURATION) into ./build (limit ${BUILD_TIMEOUT}s)..."
    local log="$BUILD_DIR/build.log" rc=0
    with_timeout "$BUILD_TIMEOUT" xcodebuild \
        -project "$PROJECT" \
        -scheme "$SCHEME" \
        -configuration "$CONFIGURATION" \
        -destination "platform=macOS" \
        -derivedDataPath "$DERIVED_DATA" \
        "${SIGNING_ARGS[@]}" \
        build > "$log" 2>&1 || rc=$?
    if [ "$rc" -ne 0 ]; then
        explain_timeout "$rc" "The build" "$BUILD_TIMEOUT"
        grep -E "error:|BUILD FAILED" "$log" | head -n 20 >&2 || true
        die "The build failed. Full log: build/build.log" "$rc"
    fi

    local product="$DERIVED_DATA/Build/Products/$CONFIGURATION/AudioCap.app"
    [ -d "$product" ] || die "The build finished but $product is missing. Full log: build/build.log"

    quit_running_copy
    rm -rf "$APP_PATH"
    ditto "$product" "$APP_PATH"
    say "Built $APP_PATH"
}

# A running copy keeps the old binary on screen and `open` would only bring
# it to the front, so stop the copy that lives in ./build before replacing it.
quit_running_copy() {
    local pids
    pids="$(pgrep -f "$APP_PATH/Contents/MacOS/" 2>/dev/null || true)"
    if [ -n "$pids" ]; then
        say "Closing the AudioCap that is already running from ./build"
        kill -TERM $pids 2>/dev/null || true
        local i=0
        while [ "$i" -lt 20 ] && pgrep -f "$APP_PATH/Contents/MacOS/" >/dev/null 2>&1; do
            sleep 0.25
            i=$((i + 1))
        done
    fi
}

open_app() {
    say "Opening AudioCap"
    open "$APP_PATH"
    cat <<'NEXT'

AudioCap is open. The first time, click "Allow" and accept the system prompt
so it can record other apps (System Settings > Privacy & Security >
Screen & System Audio Recording). Problems? See docs/troubleshooting.md.
NEXT
}

run_tests() {
    check_scheme
    local listing
    listing="$(project_listing)" || die "Could not read $PROJECT with xcodebuild -list."
    if ! printf '%s\n' "$listing" | sed -n '/Targets:/,/^[[:space:]]*$/p' | grep -qx "[[:space:]]*$TEST_TARGET"; then
        die "This checkout has no '$TEST_TARGET' test target yet, so there are no unit tests to run. It arrives with the recording-engine change." 3
    fi
    configure_signing
    mkdir -p "$BUILD_DIR"
    say "Running unit tests ($SCHEME / $TEST_TARGET, limit ${TEST_TIMEOUT}s)..."
    local log="$BUILD_DIR/test.log" rc=0
    with_timeout "$TEST_TIMEOUT" xcodebuild \
        -project "$PROJECT" \
        -scheme "$SCHEME" \
        -destination "platform=macOS" \
        -derivedDataPath "$DERIVED_DATA" \
        "${SIGNING_ARGS[@]}" \
        test > "$log" 2>&1 || rc=$?
    grep -E "Test Suite '.*' (passed|failed)|Executed [0-9]+ test|error:|\*\* TEST" "$log" | tail -n 20 || true
    if [ "$rc" -ne 0 ]; then
        explain_timeout "$rc" "The tests" "$TEST_TIMEOUT"
        die "Unit tests failed. Full log: build/test.log" "$rc"
    fi
    say "Unit tests passed. Full log: build/test.log"
}

# --- HOOK: Hi-Res virtual device driver -------------------------------------
# The Hi-Res mode change (plan section 2b) replaces these two functions with
# the real install/uninstall of the "AudioCap Hi-Res" AudioServerPlugIn into
# /Library/Audio/Plug-Ins/HAL/ and, once the driver exists, calls
# install_driver from the default (no option) flow below.
install_driver() {
    die "--install-driver is not available yet: the AudioCap Hi-Res driver is planned (docs/planning/01_improvement_plan.md, section 2b)." 2
}
uninstall_driver() {
    die "--uninstall-driver is not available yet: the AudioCap Hi-Res driver is planned (docs/planning/01_improvement_plan.md, section 2b)." 2
}
# --- end HOOK ----------------------------------------------------------------

main() {
    local mode="run"
    if [ "$#" -gt 1 ]; then
        usage >&2
        die "Pass at most one option."
    fi
    case "${1:-}" in
        "") mode="run" ;;
        --no-open) mode="build" ;;
        --test) mode="test" ;;
        --install-driver) mode="install-driver" ;;
        --uninstall-driver) mode="uninstall-driver" ;;
        -h|--help) usage; exit 0 ;;
        *) usage >&2; die "Unknown option: $1" ;;
    esac

    check_platform
    cd "$ROOT_DIR"

    case "$mode" in
        install-driver) install_driver ;;
        uninstall-driver) uninstall_driver ;;
        test) check_xcode; run_tests ;;
        build) check_xcode; build_app ;;
        run) check_xcode; build_app; open_app ;;
    esac
}

main "$@"
