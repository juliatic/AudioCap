#!/bin/bash
# AudioCap launcher: build, install into /Applications and open the app with
# one command.
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
INSTALL_DIR="${AUDIOCAP_INSTALL_DIR:-/Applications}"
INSTALLED_APP="$INSTALL_DIR/AudioCap.app"
QUIT_TIMEOUT=10
SUDO_TIMEOUT=120
LOCAL_XCCONFIG="$ROOT_DIR/AudioCap/Config/Local.xcconfig"
MIN_MACOS="14.4"
MIN_XCODE_MAJOR=16
BUILD_TIMEOUT="${AUDIOCAP_BUILD_TIMEOUT:-900}"
TEST_TIMEOUT="${AUDIOCAP_TEST_TIMEOUT:-900}"
LIST_TIMEOUT=120

usage() {
    cat <<'USAGE'
Usage: ./start.sh [option]

  (no option)          Build AudioCap (Release), install it as
                       /Applications/AudioCap.app (quitting and replacing
                       the running copy) and open it from there.
  --no-open            Build and install into /Applications, do not open.
  --no-install         Build into ./build/AudioCap.app only: /Applications
                       is not touched and nothing is opened.
  --test               Run the unit tests (scheme AudioCap, target AudioCapTests).
  --install-driver     Install the AudioCap Hi-Res virtual device into
                       /Library/Audio/Plug-Ins/HAL (one administrator prompt,
                       restarts Core Audio). Builds first if needed.
  --uninstall-driver   Remove the AudioCap Hi-Res virtual device.
  -h, --help           Show this help.

Signing: the build is ad-hoc signed ("Sign to Run Locally") unless the
git-ignored file AudioCap/Config/Local.xcconfig sets your team, e.g.:

    DEVELOPMENT_TEAM = ABCDE12345

If /Applications is not writable by your user, the install asks once for
an administrator password (sudo). The old copy is only removed after a
successful build.

macOS may ask for the audio-capture permission again the first time a
rebuilt or re-signed app runs (always with ad-hoc signing, and once after a
bundle-id change).

Environment: AUDIOCAP_BUILD_TIMEOUT and AUDIOCAP_TEST_TIMEOUT (seconds,
default 900) bound xcodebuild so the script can never hang.
AUDIOCAP_INSTALL_DIR overrides /Applications.
The default flow offers to install the Hi-Res device once when it is missing;
AUDIOCAP_INSTALL_DRIVER=yes|no answers that question without a prompt.
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

    rm -rf "$APP_PATH"
    ditto "$product" "$APP_PATH"
    say "Built $APP_PATH"
}

bundle_id_of() {
    /usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$1/Contents/Info.plist" 2>/dev/null || true
}

is_running() {
    pgrep -x AudioCap >/dev/null 2>&1
}

# A running copy keeps the old binary on screen and `open` would only bring
# it to the front, so quit every running AudioCap before replacing it:
# politely through Apple Events first, then SIGTERM, then SIGKILL.
quit_running_copies() {
    is_running || return 0
    say "Quitting the AudioCap that is running (up to ${QUIT_TIMEOUT}s)"
    local ids="" id
    ids="$(bundle_id_of "$APP_PATH") $(bundle_id_of "$INSTALLED_APP")"
    for id in $ids; do
        with_timeout "$QUIT_TIMEOUT" osascript -e "tell application id \"$id\" to quit" >/dev/null 2>&1 || true
    done
    local i=0
    while [ "$i" -lt $((QUIT_TIMEOUT * 4)) ] && is_running; do
        sleep 0.25
        i=$((i + 1))
    done
    if is_running; then
        warn "AudioCap did not quit within ${QUIT_TIMEOUT}s; stopping it"
        pkill -x AudioCap 2>/dev/null || true
        i=0
        while [ "$i" -lt 12 ] && is_running; do
            sleep 0.25
            i=$((i + 1))
        done
        if is_running; then
            pkill -9 -x AudioCap 2>/dev/null || true
            sleep 0.5
        fi
    fi
    is_running && die "AudioCap is still running and could not be stopped. Quit it by hand and run ./start.sh again."
    return 0
}

# Sets SUDO to "" or "sudo". Dies with a clear message when admin rights are
# needed but cannot be obtained, so the old copy is never left silently.
SUDO=""
choose_install_privileges() {
    if [ -w "$INSTALL_DIR" ] && { [ ! -e "$INSTALLED_APP" ] || [ -O "$INSTALLED_APP" ]; }; then
        SUDO=""
        return 0
    fi
    say "$INSTALL_DIR is not writable by $(id -un): administrator rights are needed to install"
    if sudo -n true 2>/dev/null; then
        SUDO="sudo"
    elif [ -t 0 ]; then
        say "Enter your administrator password (asked once)"
        if with_timeout "$SUDO_TIMEOUT" sudo -v; then
            SUDO="sudo"
        else
            die "No administrator rights, so $INSTALLED_APP was not replaced. The new build is in build/AudioCap.app (or run ./start.sh --no-install)."
        fi
    else
        die "Installing into $INSTALL_DIR needs administrator rights and there is no terminal to ask for a password, so $INSTALLED_APP was not replaced. Run ./start.sh from Terminal, or use ./start.sh --no-install."
    fi
}

install_app() {
    [ -d "$APP_PATH" ] || die "Nothing to install: $APP_PATH is missing."
    [ -d "$INSTALL_DIR" ] || die "$INSTALL_DIR does not exist."
    choose_install_privileges
    quit_running_copies
    local staging="$INSTALL_DIR/.AudioCap.app.installing"
    say "Installing into $INSTALLED_APP"
    $SUDO rm -rf "$staging"
    with_timeout 300 $SUDO ditto "$APP_PATH" "$staging" || {
        $SUDO rm -rf "$staging"
        die "Copying the app into $INSTALL_DIR failed; the previous copy was left in place."
    }
    $SUDO rm -rf "$INSTALLED_APP"
    $SUDO mv "$staging" "$INSTALLED_APP"
    say "Installed $INSTALLED_APP ($(bundle_id_of "$INSTALLED_APP"))"
}

open_app() {
    say "Opening $INSTALLED_APP"
    with_timeout 30 open "$INSTALLED_APP"
    cat <<'NEXT'

AudioCap is open. The first time (and again after a rebuild with ad-hoc
signing, or after a bundle-id change) macOS may ask for the audio-capture
permission: click "Allow" and accept the system prompt (System Settings >
Privacy & Security > Screen & System Audio Recording).
Problems? See docs/troubleshooting.md.
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

# --- Hi-Res virtual device driver -------------------------------------------
# "AudioCap Hi-Res" is an AudioServerPlugIn (target AudioCapHiRes) embedded in
# the app bundle. It is copied into /Library/Audio/Plug-Ins/HAL/ with one
# administrator prompt, then coreaudiod is restarted so it appears.
DRIVER_NAME="AudioCapHiRes.driver"
HAL_DIR="${AUDIOCAP_HAL_DIR:-/Library/Audio/Plug-Ins/HAL}"
INSTALLED_DRIVER="$HAL_DIR/$DRIVER_NAME"
BUILT_DRIVER="$APP_PATH/Contents/Resources/$DRIVER_NAME"
DRIVER_DECLINED_MARK="$BUILD_DIR/.hi-res-driver-declined"

driver_is_current() {
    [ -d "$INSTALLED_DRIVER" ] && [ -d "$BUILT_DRIVER" ] &&
        cmp -s "$INSTALLED_DRIVER/Contents/MacOS/AudioCapHiRes" "$BUILT_DRIVER/Contents/MacOS/AudioCapHiRes"
}

# Runs one root shell command: a single administrator prompt for the whole step.
run_as_admin() {
    if [ "$(id -u)" -eq 0 ]; then
        with_timeout 300 /bin/sh -c "$1"
    elif sudo -n true 2>/dev/null; then
        with_timeout 300 sudo /bin/sh -c "$1"
    elif [ -t 0 ]; then
        say "Enter your administrator password (asked once)"
        with_timeout "$SUDO_TIMEOUT" sudo -v || return 1
        with_timeout 300 sudo /bin/sh -c "$1"
    else
        warn "Administrator rights are needed and there is no terminal to ask for a password."
        return 1
    fi
}

# Restarting coreaudiod lets macOS pick new default devices; keep the user's input, output and alert devices.
DEFAULTS_HELPER="$BUILD_DIR/audio-defaults"
DEFAULTS_FILE="$BUILD_DIR/.audio-defaults-before-driver-change"

save_audio_defaults() {
    local source="$ROOT_DIR/scripts/audio-defaults.c"
    if [ ! -x "$DEFAULTS_HELPER" ] || [ "$source" -nt "$DEFAULTS_HELPER" ]; then
        mkdir -p "$BUILD_DIR"
        with_timeout 120 xcrun clang -O2 -framework CoreAudio -framework CoreFoundation -o "$DEFAULTS_HELPER" "$source" ||
            { warn "Could not build the audio-defaults helper; default devices may change."; return 0; }
    fi
    with_timeout 20 "$DEFAULTS_HELPER" save > "$DEFAULTS_FILE" || rm -f "$DEFAULTS_FILE"
}

restore_audio_defaults() {
    [ -x "$DEFAULTS_HELPER" ] && [ -s "$DEFAULTS_FILE" ] || return 0
    with_timeout 30 "$DEFAULTS_HELPER" restore "$DEFAULTS_FILE" ||
        warn "Check the input, output and alert devices in System Settings > Sound."
    rm -f "$DEFAULTS_FILE"
}

restart_coreaudio_cmd='launchctl kickstart -k system/com.apple.audio.coreaudiod 2>/dev/null || killall coreaudiod 2>/dev/null || true'

copy_driver() {
    [ -d "$BUILT_DRIVER" ] || die "The build has no $DRIVER_NAME (expected $BUILT_DRIVER)."
    say "Installing the AudioCap Hi-Res device into $HAL_DIR and restarting Core Audio (audio stops for a moment)..."
    local staging="$HAL_DIR/.$DRIVER_NAME.installing"
    save_audio_defaults
    run_as_admin "mkdir -p '$HAL_DIR' && rm -rf '$staging' && ditto '$BUILT_DRIVER' '$staging' && rm -rf '$INSTALLED_DRIVER' && mv '$staging' '$INSTALLED_DRIVER' && chown -R root:wheel '$INSTALLED_DRIVER' && { $restart_coreaudio_cmd; }" ||
        die "Installing $DRIVER_NAME failed; nothing else was changed."
    restore_audio_defaults
    rm -f "$DRIVER_DECLINED_MARK"
    say "Installed $INSTALLED_DRIVER. AudioCap uses it while recording (Settings > Hi-Res mode)."
}

install_driver() {
    if [ ! -d "$BUILT_DRIVER" ]; then
        check_xcode
        build_app
    fi
    copy_driver
}

uninstall_driver() {
    if [ ! -e "$INSTALLED_DRIVER" ]; then
        say "$INSTALLED_DRIVER is not installed; nothing to remove."
        return 0
    fi
    say "Removing $INSTALLED_DRIVER and restarting Core Audio..."
    save_audio_defaults
    run_as_admin "rm -rf '$INSTALLED_DRIVER' && { $restart_coreaudio_cmd; }" ||
        die "Removing $DRIVER_NAME failed."
    restore_audio_defaults
    touch "$DRIVER_DECLINED_MARK" 2>/dev/null || true
    say "Removed. Run ./start.sh --install-driver to install it again."
}

# Default flow: offer the driver once when it is missing (or older than the build).
# AUDIOCAP_INSTALL_DRIVER=yes|no answers without a prompt.
offer_driver() {
    driver_is_current && return 0
    local what="install the AudioCap Hi-Res virtual device (records at up to 192 kHz whatever your speakers support)"
    [ -d "$INSTALLED_DRIVER" ] && what="update the installed AudioCap Hi-Res virtual device"
    local answer="${AUDIOCAP_INSTALL_DRIVER:-}"
    if [ -z "$answer" ]; then
        if [ -e "$DRIVER_DECLINED_MARK" ] && [ ! -d "$INSTALLED_DRIVER" ]; then
            say "Hi-Res device not installed (declined earlier). Run ./start.sh --install-driver to add it."
            return 0
        fi
        if [ ! -t 0 ]; then
            say "Hi-Res device not installed or outdated. Run ./start.sh --install-driver from Terminal to $what."
            return 0
        fi
        printf '==> %s? It needs your administrator password once. [y/N] ' "Do you want to $what" >&2
        read -r -t 120 answer || answer=""
    fi
    case "$answer" in
        y|Y|yes|YES|Yes) copy_driver ;;
        *)
            mkdir -p "$BUILD_DIR" && touch "$DRIVER_DECLINED_MARK"
            say "Skipped the Hi-Res device. Run ./start.sh --install-driver at any time."
            ;;
    esac
}
# --- end Hi-Res driver -------------------------------------------------------

main() {
    local mode="run"
    if [ "$#" -gt 1 ]; then
        usage >&2
        die "Pass at most one option."
    fi
    case "${1:-}" in
        "") mode="run" ;;
        --no-open) mode="install" ;;
        --no-install) mode="build" ;;
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
        install) check_xcode; build_app; install_app ;;
        run) check_xcode; build_app; install_app; offer_driver; open_app ;;
    esac
}

main "$@"
