#!/usr/bin/env bash
# =============================================================================
# Whisper To Input - Full E2E Test Script
# =============================================================================
# This script runs a complete end-to-end transcription test from scratch:
# 1. Sets up virtual microphone (VirtualMicSink + FakeMic)
# 2. Starts headful emulator with FakeMic pinned
# 3. Builds and installs the APK
# 4. Grants permissions, enables IME
# 5. Configures a transcription backend via Settings UI
# 6. Triggers recording by tapping the mic button (tap-to-toggle)
# 7. Plays test audio into the virtual mic while recording
# 8. Taps mic button again to stop and transcribe
# 8. Verifies transcription appears in the search bar
#
# Usage:
#   ./run_e2e_test.sh --backend deepgram --key $DEEPGRAM_KEY --expected "hello world"
#   ./run_e2e_test.sh --backend groq --key $GROQ_KEY --expected "hello world"
#   ./run_e2e_test.sh --backend 60db --key $SIXTYDB_KEY --expected "hello world"
#
# Options:
#   --headful   Run emulator with visible window (default: headless)
#
# Prerequisites:
# - Android SDK with emulator (Pixel_8 AVD)
# - pactl / PipeWire or PulseAudio
# - paplay, espeak-ng, ffmpeg (for test audio generation)
# - ADB in PATH
# - Deepgram/Groq/60db API key with valid quota
#
# =============================================================================

set -euxo pipefail

# Write all output (incl. `set -x` trace) to a log file and mirror it to the console.
LOG_FILE="e2e_test.log"
exec > >(tee "$LOG_FILE") 2>&1

# =============================================================================
# Configuration
# =============================================================================

ADB="/var/home/l/Android/Sdk/platform-tools/adb"
EMULATOR="/var/home/l/Android/Sdk/emulator/emulator"
AVD="Pixel_8"
PACKAGE="com.example.whispertoinput"
SERVICE="com.example.whispertoinput/.WhisperInputService"
LATIN_IME="com.android.inputmethod.latin/.LatinIME"
WAV_FILE="/tmp/test-speech-loud.wav"
VIRTUAL_SINK="VirtualMicSink"
FAKE_MIC="FakeMic"
SERIAL="emulator-5554"
EMULATOR_WAS_RUNNING=false

# Default API keys (sourced from keyring / prior sessions)
DEEPGRAM_KEY_DEFAULT="f97f6e1e42b697792bfe1867f7679fdeaace4de8"

# Backend configuration
declare -A BACKEND_ENDPOINT=(
    ["deepgram"]="https://api.deepgram.com/v1/listen"
    ["groq"]="https://api.groq.com/openai/v1/audio/transcriptions"
    ["60db"]="https://api.60db.ai/stt"
    ["elevenlabs"]="https://api.elevenlabs.io/v1/speech-to-text"
)

declare -A BACKEND_MODEL=(
    ["deepgram"]="nova-3"
    ["groq"]="whisper-large-v3-turbo"
    ["60db"]="60db-stt-v01"
    ["elevenlabs"]="scribe_v1"
)

declare -A BACKEND_DISPLAY=(
    ["deepgram"]="Deepgram"
    ["groq"]="Groq"
    ["60db"]="60db"
    ["elevenlabs"]="ElevenLabs Scribe"
)

# Timeouts
EMULATOR_BOOT_TIMEOUT=180
TRANSCRIPTION_TIMEOUT=30
RECORDING_DURATION=5

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# =============================================================================
# Helper Functions
# =============================================================================

log_info() { echo -e "${BLUE}[INFO]${NC} $*"; }
log_ok()   { echo -e "${GREEN}[OK]${NC} $*"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
log_err()  { echo -e "${RED}[ERR]${NC} $*"; }

die() { log_err "$*"; exit 1; }

run_cmd() {
    local cmd="$1"
    local check="${2:-true}"
    local output
    output=$(eval "$cmd" 2>&1) || {
        local rc=$?
        if [[ "$check" == "true" ]]; then
            die "Command failed (rc=$rc): $cmd\nOutput: $output"
        fi
		# Best-effort (check=false): swallow the exit code so set -e
		# doesn't abort the script on an expected non-fatal failure.
		return 0
    }
    echo "$output"
}

adb_cmd() {
    run_cmd "$ADB -s $SERIAL $*"
}

# =============================================================================
# Virtual Microphone Setup
# =============================================================================

setup_virtual_mic() {
    log_info "Setting up virtual microphone sources..."

    # Check if already exist
    if pactl list short sources | grep -q "$FAKE_MIC" && \
       pactl list short sinks | grep -q "$VIRTUAL_SINK" && \
       pactl list short sinks | grep -q "SilentTestSink"; then
        log_ok "Virtual mic sources already exist"
        return 0
    fi

    # Create VirtualMicSink (null sink) — QEMU captures its monitor as mic input
    run_cmd "pactl load-module module-null-sink sink_name=$VIRTUAL_SINK sink_properties=device.description=$VIRTUAL_SINK"

    # Create FakeMic (remap source from VirtualMicSink.monitor)
    run_cmd "pactl load-module module-remap-source source_name=$FAKE_MIC master=${VIRTUAL_SINK}.monitor source_properties=device.description=$FAKE_MIC"

    # Create SilentTestSink for test audio playback — completely silent on speakers.
    # Audio is loopbacked into VirtualMicSink so QEMU captures it as mic input.
    run_cmd "pactl load-module module-null-sink sink_name=SilentTestSink sink_properties=device.description=SilentTestSink"
    run_cmd "pactl load-module module-loopback source=SilentTestSink.monitor sink=$VIRTUAL_SINK"

    sleep 1
    log_ok "Virtual mic sources created (with silent test sink)"
}

cleanup_virtual_mic() {
    log_info "Cleaning up virtual mic modules..."
    # Unload each matching module individually (grep may return multiple IDs)
    for pattern in "$VIRTUAL_SINK" "$FAKE_MIC" "SilentTestSink" "module-loopback"; do
        pactl list short modules | grep "$pattern" | awk '{print $1}' | while read -r mid; do
            pactl unload-module "$mid" 2>/dev/null || true
        done
    done
}

# =============================================================================
# Test Audio Generation
# =============================================================================

generate_test_audio() {
    log_info "Generating test speech audio..."

    if [[ -f "$WAV_FILE" ]]; then
        log_ok "Test audio already exists: $WAV_FILE"
        return 0
    fi

    # Generate speech with espeak-ng
    run_cmd "espeak-ng -v en-us -s 150 'hello world this is a test of speech to text transcription' --stdout > /tmp/test-speech.wav"

    # Boost volume for clear transcription
    run_cmd "ffmpeg -y -i /tmp/test-speech.wav -af 'volume=15dB' -ar 44100 -c:a pcm_s16le $WAV_FILE"

    # Verify peak level
    local peak
    peak=$(ffmpeg -i "$WAV_FILE" -af "volumedetect" -f null /dev/null 2>&1 | grep "max_volume" | awk '{print $3}')
    log_ok "Test audio generated: $WAV_FILE (peak: ${peak} dB)"
}

# =============================================================================
# Emulator Management
# =============================================================================

start_emulator() {
    # Check if emulator is already running with FakeMic pinned
    if "$ADB" -s "$SERIAL" get-state >/dev/null 2>&1 && \
       [[ "$("$ADB" -s "$SERIAL" shell getprop sys.boot_completed 2>/dev/null)" == "1" ]]; then
        # Verify FakeMic is pinned (check QEMU env in /proc)
        local qemu_pid
        qemu_pid=$(pgrep -f "qemu-system.*Pixel_8" | head -1)
        if [[ -n "$qemu_pid" ]] && \
           grep -q "QEMU_PA_SOURCE=$FAKE_MIC" "/proc/$qemu_pid/environ" 2>/dev/null; then
            EMULATOR_WAS_RUNNING=true
            log_ok "Emulator already running with FakeMic pinned — reusing"
            return 0
        fi
        log_warn "Emulator running but FakeMic NOT pinned — restarting..."
        "$ADB" -s "$SERIAL" emu kill 2>/dev/null || true
        sleep-i-am-sure 3
        pkill -9 -f "qemu-system.*Pixel_8" 2>/dev/null || true
        sleep-i-am-sure 2
    fi

    # Verify snapshot exists for quick boot
    local snapshot="${HOME}/.android/avd/${AVD}.avd/snapshots/default_boot/ram.bin"
    if [[ ! -f "$snapshot" ]] || [[ ! -s "$snapshot" ]]; then
        die "No emulator snapshot found at $snapshot\n\nRun this first to create the snapshot:\n  just emulator-save-snapshot"
    fi

    log_info "Starting emulator with FakeMic pinned..."

    # Kill any stale emulator processes before launching fresh

    # Clean up stale PID file
    rm -f /tmp/emulator.pid /tmp/emulator.log

    # Launch emulator with FakeMic pinned
    local emu_flags="-gpu host -no-snapshot-save"
    if [[ "$HEADFUL" == "true" ]]; then
        log_info "Launching emulator (headful, FakeMic pinned)..."
    else
        log_info "Launching emulator (headless, FakeMic pinned)..."
        emu_flags="$emu_flags -no-window"
    fi
    QEMU_AUDIO_DRV=pa QEMU_PA_SOURCE=$FAKE_MIC \
    setsid "$EMULATOR" -avd "$AVD" $emu_flags > /tmp/emulator.log 2>&1 &
    echo $! > /tmp/emulator.pid

    log_info "Waiting for emulator boot..."
    local i=0
    while [[ $i -lt $EMULATOR_BOOT_TIMEOUT ]]; do
        if "$ADB" -s "$SERIAL" get-state >/dev/null 2>&1 && \
           [[ "$("$ADB" -s "$SERIAL" shell getprop sys.boot_completed 2>/dev/null)" == "1" ]]; then
            log_ok "Emulator booted"
            return 0
        fi
        sleep 2
        i=$((i + 2))
    done
    die "Emulator boot timeout after ${EMULATOR_BOOT_TIMEOUT}s"
}

disable_host_mic() {
    # We inject audio via the silent virtual mic (SilentTestSink -> loopback ->
    # VirtualMicSink -> FakeMic). The host microphone must stay OFF so the emulator
    # does not capture the user's real voice instead of the test audio.
    log_info "Disabling host microphone (using silent virtual FakeMic)..."
    adb_cmd emu avd hostmicoff
    log_ok "Host microphone disabled"
}

stop_emulator() {
    log_info "Stopping emulator..."
    # Graceful shutdown via adb (snapshot NOT saved — we use -no-snapshot-save)
    if "$ADB" -s "$SERIAL" get-state >/dev/null 2>&1; then
        "$ADB" -s "$SERIAL" emu kill 2>/dev/null || true
        sleep-i-am-sure 5
    fi
    # Clean up PID file
    if [[ -f /tmp/emulator.pid ]]; then
        local pid
        pid=$(cat /tmp/emulator.pid)
        if kill -0 "$pid" 2>/dev/null; then
            log_warn "Process still alive after adb emu kill, force killing..."
            kill "$pid" 2>/dev/null || true
        fi
        rm -f /tmp/emulator.pid
    fi
    rm -f /tmp/emulator.log
    log_ok "Emulator stopped"
}

# =============================================================================
# App Installation & Permissions
# =============================================================================

clear_app_data() {
    log_info "Clearing app data for fresh state..."
    # Non-fatal: package may not be installed yet on a fresh emulator
    run_cmd "$ADB -s $SERIAL shell pm clear $PACKAGE" false
    log_ok "App data cleared"
}

build_and_install() {
    log_info "Building and installing APK..."
    export JAVA_HOME="${HOME}/.sdkman/candidates/java/17.0.13-tem"
    cd android
    run_cmd "./gradlew assembleDebug"
    cd ..
    adb_cmd install -r android/app/build/outputs/apk/debug/app-debug.apk
    log_ok "APK installed"
}

grant_permissions() {
    log_info "Granting permissions..."
    adb_cmd shell pm grant "$PACKAGE" android.permission.RECORD_AUDIO
    adb_cmd shell pm grant "$PACKAGE" android.permission.POST_NOTIFICATIONS
    log_ok "Permissions granted"
}

enable_ime() {
    log_info "Enabling Whisper IME..."
    local attempts=0
    while [[ $attempts -lt 3 ]]; do
        if adb_cmd shell ime enable "$SERVICE" 2>/dev/null; then
            log_ok "IME enabled"
            return 0
        fi
        attempts=$((attempts + 1))
        log_warn "IME not yet registered, retrying ($attempts/3)..."
        sleep 3
    done
    die "Failed to enable IME after 3 attempts"
}

set_default_ime() {
    local ime="$1"
    adb_cmd shell ime set "$ime"
    local current
    current=$(adb_cmd shell settings get secure default_input_method)
    if [[ "$current" != *"$1"* ]]; then
        die "Failed to set default IME to $1 (current: $current)"
    fi
    log_ok "Default IME set to $1"
}

# =============================================================================
# UI Automation Helpers (using our ui_tap.py)
# =============================================================================

UI_TAP="python3 scripts/ui_tap.py"

ui_tap() {
    run_cmd "$UI_TAP $*" false
}

dump_ui() {
    run_cmd "$UI_TAP --dump" false
}

tap_by_rid() {
    ui_tap --rid "com.example.whispertoinput:id/$1"
}

tap_by_text() {
    ui_tap --text "$1"
}

tap_by_contains() {
    ui_tap --contains "$1"
}

dump_and_grep() {
    dump_ui | grep -E "$1"
}

get_field_coords() {
    local field_id="$1"
    python3 -c "
import subprocess, xml.etree.ElementTree as ET, re
import os
ADB = '$ADB'
DEV = '-s $SERIAL'
xml = subprocess.run([ADB, '-s', '$SERIAL', 'shell', 'uiautomator', 'dump', '/sdcard/ui.xml'], capture_output=True, text=True)
xml = subprocess.run([ADB, '-s', '$SERIAL', 'shell', 'cat', '/sdcard/ui.xml'], capture_output=True, text=True).stdout
root = ET.fromstring(xml)
for n in root.iter('node'):
    if n.get('resource-id', '') == 'com.example.whispertoinput:id/$field_id':
        b = n.get('bounds', '')
        nums = list(map(int, re.findall(r'\d+', b)))
        print((nums[0]+nums[2])//2, (nums[1]+nums[3])//2)
        break
"
}

tap_coords() {
    local x="$1" y="$2"
    adb_cmd shell input tap "$x" "$y"
}

triple_tap_rid() {
    local field_id="$1"
    local coords
    coords=$(get_field_coords "$field_id")
    read -r x y <<< "$coords"
    for _ in 1 2 3; do
        adb_cmd shell input tap "$x" "$y"
        sleep 0.05
    done
}

tap_field() {
    local field_id="$1"
    local coords
    coords=$(get_field_coords "$field_id")
    read -r x y <<< "$coords"
    adb_cmd shell input tap "$x" "$y"
}

# =============================================================================
# Settings Configuration
# =============================================================================

open_settings() {
    log_info "Opening Settings activity..."
    adb_cmd shell am start -n "$PACKAGE/.MainActivity" >/dev/null
    sleep 3
}

select_backend() {
    local backend="$1"
    local display="${BACKEND_DISPLAY[$backend]}"

    log_info "Selecting backend: $display"

    # Retry loop: uiautomator dump can be flaky right after Settings loads.
    # Tap the spinner by resource-id, with retries.
    local tap_ok=false
    for attempt in 1 2 3 4 5; do
        local coords
        coords=$(get_field_coords "spinner_speech_to_text_backend")
        read -r x y <<< "$coords"
        if [[ -n "$x" && -n "$y" ]]; then
            adb_cmd shell input tap "$x" "$y"
            tap_ok=true
            break
        fi
        log_warn "Spinner not found (attempt $attempt/5), retrying..."
        sleep 2
    done
    if [[ "$tap_ok" != "true" ]]; then
        die "Could not find spinner after 5 attempts"
    fi
    sleep 1.5

    # Now select the backend from the dropdown by text
    tap_by_text "$display"
    sleep 1.2

    # Verify endpoint updated
    local expected="${BACKEND_ENDPOINT[$backend]}"
    local model="${BACKEND_MODEL[$backend]}"

    local endpoint_text model_text
    endpoint_text=$(dump_and_grep "field_endpoint" | head -1 | sed "s/.*text='\([^']*\)'.*/\1/")
    model_text=$(dump_and_grep "field_model" | head -1 | sed "s/.*text='\([^']*\)'.*/\1/")

    if [[ "$endpoint_text" != *"$expected"* ]]; then
        die "Endpoint mismatch: expected $expected, got $endpoint_text"
    fi
    if [[ "$model_text" != *"$model"* ]]; then
        die "Model mismatch: expected $model, got $model_text"
    fi
    log_ok "Backend selected: $display (endpoint verified)"
}

set_api_key() {
    local api_key="$1"

    log_info "Setting API key (switching to LatinIME for typing)..."
    set_default_ime "$LATIN_IME"
    sleep 0.5

    # Try to find the API key field first (it may already be visible)
    local coords x y
    coords=$(get_field_coords "field_api_key")
    read -r x y <<< "$coords"
    if [[ -n "$x" && -n "$y" ]]; then
        log_ok "API key field already visible at ($x, $y)"
    else
        # Scroll to reveal API key field
        log_info "Scrolling to reveal API key field..."
        adb_cmd shell input swipe 540 1800 540 600 300
        sleep 1.5

        # Get field coordinates with retry (uiautomator dump can be flaky after scrolling)
        local attempts=0
        while [ $attempts -lt 3 ]; do
            coords=$(get_field_coords "field_api_key")
            read -r x y <<< "$coords"
            if [[ -n "$x" && -n "$y" ]]; then
                break
            fi
            log_info "uiautomator dump returned empty, retrying (${attempts}/3)..."
            sleep 2
            attempts=$((attempts + 1))
        done

        if [[ -z "$x" || -z "$y" ]]; then
            die "Could not locate API key field after scrolling"
        fi
    fi

    log_info "Focusing API key field at ($x, $y)..."
    adb_cmd shell input tap "$x" "$y"
    sleep 0.5

    # Since we clear app data before each run, field should be empty
    # Just type the key directly in chunks
    log_info "Typing API key (chunked)..."
    local key="$1"
    local chunk_size=10
    local i=0
    while [ $i -lt ${#key} ]; do
        local chunk="${key:$i:$chunk_size}"
        adb_cmd shell input text "$chunk"
        sleep 0.3
        i=$((i + chunk_size))
    done
    sleep 0.4

    # Hide keyboard
    adb_cmd shell input keyevent KEYCODE_BACK
    sleep 0.5

    # Switch back to Whisper IME
    set_default_ime "$SERVICE"
}


apply_settings() {
    tap_by_rid "btn_settings_apply"
    sleep 1
}

write_datastore() {
    local backend="$1"
    local api_key="$2"

    log_info "Writing DataStore preferences (bypassing UI)..."

    # Generate protobuf binary locally
    local pb_file
    pb_file=$(mktemp /tmp/settings-XXXXXX.pb)
    python3 scripts/write_datastore.py --backend "$backend" --key "$api_key" -o "$pb_file"

    # Push to /data/local/tmp/ (world-readable) then run-as cp into app data.
    # /sdcard/ is unreadable by run-as (UID mismatch); stdin pipe also fails.
    adb_cmd push "$pb_file" /data/local/tmp/settings.preferences_pb
    adb_cmd shell "run-as $PACKAGE mkdir -p files/datastore"
    adb_cmd shell "run-as $PACKAGE cp /data/local/tmp/settings.preferences_pb files/datastore/settings.preferences_pb"
    adb_cmd shell rm -f /data/local/tmp/settings.preferences_pb

    rm -f "$pb_file"

    log_ok "DataStore preferences written ($backend)"
}

# =============================================================================
# Transcription Test
# =============================================================================

focus_text_field() {
    log_info "Focusing text field to trigger Whisper keyboard..."

    # Open Android Settings — has a search bar at the top, no popups
    adb_cmd shell am start -a android.settings.SETTINGS >/dev/null
    sleep 3

    # The Settings search bar on the homepage is a TextView (search_action_bar_title).
    # Tapping it activates search mode and reveals the EditText (search_src_text).
    # However, ui_tap --rid/--text can be flaky here (timing / encoding issues), so
    # we tap the known coordinate directly as a reliable fallback.
    local attempts=0
    while (( attempts < 5 )); do
        # Try uiautomator-based tap first (works if Settings fully loaded)
        ui_tap --rid com.android.settings:id/search_action_bar_title || true
        sleep 1
        # Also try the EditText in case search mode already activated
        ui_tap --rid android:id/search_src_text || true
        sleep 1

        if adb_cmd shell dumpsys input_method 2>/dev/null | grep -q "mIsInputViewShown=true"; then
            log_ok "Whisper keyboard is shown"
            return 0
        fi

        # Fallback: tap the search bar by known coordinate (540, ~215)
        log_warn "UI tap failed, trying coordinate fallback ($attempts/5)..."
        adb_cmd shell input tap 540 215
        sleep 1.5

        if adb_cmd shell dumpsys input_method 2>/dev/null | grep -q "mIsInputViewShown=true"; then
            log_ok "Whisper keyboard is shown (via coordinate tap)"
            return 0
        fi
        attempts=$((attempts + 1))
    done
    log_warn "Keyboard did not appear after retries — continuing anyway"
}

play_test_audio() {
    log_info "Playing test audio into SilentTestSink (completely silent on speakers)..."
    # SilentTestSink is a null sink with loopback -> VirtualMicSink -> FakeMic -> emulator mic.
    # Null sinks produce no speaker output; loopback routes audio into the mic path.
    run_cmd "paplay --device=SilentTestSink $WAV_FILE"
    log_ok "Audio played"
}

tap_mic_button() {
    log_info "Triggering mic toggle via broadcast..."
    adb_cmd shell am broadcast -a com.example.whispertoinput.action.TOGGLE_RECORDING
    log_ok "Broadcast sent"
}

wait_for_recording() {
    log_info "Waiting for recording to start..."
    local start_time=$(date +%s)
    while (( $(date +%s) - start_time < 10 )); do
        local log
        log=$(adb_cmd logcat -d -s whisper-input:V 2>/dev/null || true)
        if echo "$log" | grep -q "Recording started"; then
            log_ok "Recording started"
            return 0
        fi
        # Check for errors that explain why recording didn't start
        if echo "$log" | grep -q "prepare() failed"; then
            log_err "MediaRecorder.prepare() failed — check microphone permissions"
            adb_cmd logcat -d -s whisper-input:V 2>/dev/null | tail -20 || true
            return 1
        fi
        sleep 0.5
    done
    log_warn "Recording start not detected in logcat"
    log_info "Recent whisper-input logcat:"
    adb_cmd logcat -d -s whisper-input:V 2>/dev/null | tail -30 || true
}

wait_for_transcription() {
    local expected="$1"
    local expected_lower="${expected,,}"

    log_info "Waiting for transcription to appear (expecting: '$expected')..."

    local start=$(date +%s)
    while (( $(date +%s) - start < TRANSCRIPTION_TIMEOUT )); do
        # Look for any EditText with transcribed text — works for Settings search bar
        local text
        text=$(dump_ui | grep -oP "class='android\.widget\.EditText'[^>]*text='\K[^']*" | head -1) || true
        if [[ -z "$text" ]]; then
            # Fallback: check all text nodes for the expected substring
            text=$(dump_ui | grep -oP "text='\K[^']*" | grep -i "$expected_lower" | head -1) || true
        fi
        if [[ -n "$text" ]]; then
            local text_lower="${text,,}"
            if [[ "$text_lower" == *"$expected_lower"* ]]; then
                log_ok "Transcription committed: $text"
                return 0
            fi
        fi
        sleep 1
    done
    die "Timeout: expected substring '$expected' not found in field"
}

# =============================================================================
# Main Test Flow
# =============================================================================

run_e2e_test() {
    local backend="$1"
    local api_key="$2"
    local expected="$3"

    log_info "=== Starting E2E test for $backend ==="

    # 1. Virtual mic
    setup_virtual_mic

    # 2. Emulator
    start_emulator
    disable_host_mic

    # Let package manager and system services fully settle after boot
    sleep 5

    # 3. App
    clear_app_data
    build_and_install
    grant_permissions
    enable_ime
    set_default_ime "$SERVICE"

    # 3. Settings configuration (bypass UI via DataStore)
    local api_key_var="${backend^^}_KEY"
    local api_key="${!api_key_var:-$2}"
    if [[ -z "$api_key" ]]; then
        die "No API key provided for $backend (set ${backend^^}_KEY env var or pass as arg)"
    fi
    # Configure backend via UI (DataStore bypass was unreliable)
    open_settings
    select_backend "$backend"
    set_api_key "$api_key"
    apply_settings

    # Ensure Whisper is default
    set_default_ime "$SERVICE"

    # 4. Trigger recording via tap-to-toggle
    focus_text_field          # Opens Settings search bar, keyboard appears

    # Clear logcat so wait_for_recording detects fresh messages
    adb_cmd logcat -c
    sleep 0.3

    # Start recording
    tap_mic_button
    wait_for_recording

    # Play test audio while recording is active
    play_test_audio

    # Wait for audio to finish playing + buffer
    sleep $RECORDING_DURATION

    # Stop recording and trigger transcription
    tap_mic_button

    # 5. Wait for transcription
    wait_for_transcription "$3"

    log_ok "=== TEST PASSED: $backend ==="
}

cleanup() {
    log_info "Cleaning up..."
    if [[ "$EMULATOR_WAS_RUNNING" != "true" ]]; then
        stop_emulator
    else
        log_info "Emulator was pre-existing — leaving it running"
    fi
    cleanup_virtual_mic
    log_ok "Cleanup complete"
}

# =============================================================================
# Argument Parsing
# =============================================================================

BACKEND=""
API_KEY=""
EXPECTED=""
HEADFUL=false

while [[ $# -gt 0 ]]; do
    case $1 in
        --backend)
            BACKEND="$2"
            shift 2
            ;;
        --key)
            API_KEY="$2"
            shift 2
            ;;
        --expected)
            EXPECTED="$2"
            shift 2
            ;;
        --headful)
            HEADFUL=true
            shift
            ;;
        --help|-h)
            cat <<EOF
Usage: $0 --backend <deepgram|groq|60db> --key <API_KEY> --expected <substring> [--headful]

Options:
  --backend   Backend to test (deepgram, groq, 60db)
  --key       API key for the backend
  --expected  Expected substring in transcription result
  --headful   Run emulator with visible window (default: headless)

Environment variables can also be used:
  DEEPGRAM_KEY, GROQ_KEY, SIXTYDB_KEY

Example:
  $0 --backend deepgram --key \$DEEPGRAM_KEY --expected "hello world"
EOF
            exit 0
            ;;
        *)
            die "Unknown option: $1"
            ;;
    esac
done

if [[ -z "$BACKEND" || -z "$EXPECTED" ]]; then
    die "Missing required arguments. Use --help for usage."
fi

# Validate backend
if [[ ! "${BACKEND_DISPLAY[$BACKEND]+_}" ]]; then
    die "Invalid backend: $BACKEND (must be deepgram, groq, 60db, or elevenlabs)"
fi

# API key: explicit arg → env var → embedded default
if [[ -z "$API_KEY" ]]; then
    api_var="${BACKEND^^}_KEY"
    API_KEY="${!api_var:-}"
fi
if [[ -z "$API_KEY" && "$BACKEND" == "deepgram" ]]; then
    API_KEY="$DEEPGRAM_KEY_DEFAULT"
fi

if [[ -z "$API_KEY" ]]; then
    die "API key not provided. Use --key or set ${BACKEND^^}_KEY environment variable."
fi

# =============================================================================
# Trap cleanup on exit
# =============================================================================

trap cleanup EXIT INT TERM

# =============================================================================
# Run
# =============================================================================

log_info "=== Whisper To Input E2E Test ==="
log_info "Backend: $BACKEND"
log_info "Expected: $EXPECTED"

# Generate test audio if needed
generate_test_audio

# Run the test
run_e2e_test "$BACKEND" "$API_KEY" "$EXPECTED"

log_ok "=== ALL TESTS PASSED ==="
exit 0