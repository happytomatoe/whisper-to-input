# Whisper To Input - Development Commands

# Paths
adb := "/var/home/l/Android/Sdk/platform-tools/adb"
emulator_bin := "/var/home/l/Android/Sdk/emulator/emulator"
avd := "Pixel_8"

# ── Build ──────────────────────────────────────────────────────────

# Build the debug APK
build:
    #!/usr/bin/env bash
    export JAVA_HOME="${HOME}/.sdkman/candidates/java/17.0.13-tem"
    cd android && ./gradlew assembleDebug
    echo "✅ Build successful"

# ── Emulator Lifecycle ─────────────────────────────────────────────

pid_file := ".emulator.pid"
emu_log := "/tmp/emulator.log"

# Start the emulator. Base command: emulator -avd Pixel_8
#   just emulator-start              # headless  -> emulator -avd Pixel_8 -no-window
#   just emulator-start headful=true # headful  -> emulator -avd Pixel_8 (visible window)
#   just emulator-start-headful      # alias for the above
# The emulator PID is saved to {{pid_file}} so `just emulator-stop` kills exactly that process.
emulator-start headful="false":
    #!/usr/bin/env bash
    set -e
    if {{adb}} get-state >/dev/null 2>&1; then
        echo "✅ Emulator already running"
        exit 0
    fi
    # Accept both `just start true` (positional) and `just start headful=true` (named).
    # just passes `headful=true` as the literal value "headful=true", so strip the prefix.
    HF="{{headful}}"
    HF="${HF#headful=}"
    if [ "$HF" = "true" ]; then
        FLAGS="-gpu host -no-snapshot-save"
        MODE="headful"
    else
        FLAGS="-no-window -gpu host -no-snapshot-save"
        MODE="headless"
    fi
    echo "Starting emulator ($MODE): emulator -avd {{avd}} $FLAGS"
    # setsid detaches it from this shell so it survives after `just` returns
    setsid {{emulator_bin}} -avd {{avd}} $FLAGS > {{emu_log}} 2>&1 &
    echo $! > {{pid_file}}
    {{adb}} wait-for-device
    echo "Waiting for boot (this may take a minute)..."
    for i in $(seq 1 60); do
        if [ "$({{adb}} shell getprop sys.boot_completed 2>/dev/null)" = "1" ]; then
            echo "✅ Emulator booted (PID $(cat {{pid_file}}) saved to {{pid_file}})"
            exit 0
        fi
        sleep-i-am-sure 2
    done
    echo "⚠️  Boot timed out — emulator may still be starting"
    exit 1

# Headful mode: just emulator-start headful=true

# Stop the emulator using the saved PID (falls back to pkill if no PID file)
emulator-stop:
    #!/usr/bin/env bash
    set -e
    # Graceful shutdown via adb (no snapshot save — we use -no-snapshot-save)
    if {{adb}} get-state >/dev/null 2>&1; then
        echo "Sending graceful shutdown via adb emu kill..."
        {{adb}} emu kill 2>/dev/null || true
        sleep-i-am-sure 5
    fi
    # Clean up PID file
    if [ -f {{pid_file}} ]; then
        PID=$(cat {{pid_file}})
        # Verify process is gone, force kill if still running
        if kill -0 "$PID" 2>/dev/null; then
            echo "Process still alive, force killing..."
            kill "$PID" 2>/dev/null || true
        fi
        rm -f {{pid_file}}
    fi
    echo "✅ Emulator stopped"

# Cold boot and save snapshot (for quick boot later)
# Use this to create/refresh the snapshot that `emulator-start` loads.
emulator-save-snapshot:
    #!/usr/bin/env bash
    set -e
    if {{adb}} get-state >/dev/null 2>&1; then
        echo "Emulator already running — stop it first with: just emulator-stop"
        exit 1
    fi
    echo "Cold booting emulator to save snapshot..."
    setsid {{emulator_bin}} -avd {{avd}} -gpu host -no-snapshot-load > {{emu_log}} 2>&1 &
    echo $! > {{pid_file}}
    {{adb}} wait-for-device
    echo "Waiting for boot..."
    for i in $(seq 1 60); do
        if [ "$({{adb}} shell getprop sys.boot_completed 2>/dev/null)" = "1" ]; then
            echo "✅ Emulator booted — now saving snapshot..."
            {{adb}} emu kill 2>/dev/null || true
            sleep-i-am-sure 5
            echo "✅ Snapshot saved (PID file cleaned up)"
            rm -f {{pid_file}}
            exit 0
        fi
        sleep-i-am-sure 2
    done
    echo "⚠️  Boot timed out"
    exit 1

# Restart emulator (stop + start)
emulator-restart: emulator-stop emulator-start

# Check emulator status
emulator-status:
    @{{adb}} devices 2>/dev/null
    @echo "---"
    @{{adb}} shell getprop sys.boot_completed 2>/dev/null | grep -q 1 && echo "Boot: complete" || echo "Boot: not ready"
    @[ -f {{pid_file}} ] && echo "PID file: $(cat {{pid_file}})" || echo "PID file: (none)"

# ── E2E Test ───────────────────────────────────────────────────────

# Full E2E test: build, start emulator, install APK, verify voice input
test-e2e: build emulator-start
    @echo "=== E2E Test ==="
    echo "1. Build ✓"
    echo "2. Emulator running ✓"
    {{adb}} install -r android/app/build/outputs/apk/debug/app-debug.apk
    echo "3. APK installed ✓"
    {{adb}} shell ime enable com.example.whispertoinput/.WhisperInputService
    echo "4. IME enabled ✓"
    echo "5. Verifying app is registered as voice input..."
    {{adb}} shell ime list -s | grep whispertoinput && echo "   App found in IME list ✓" || echo "   ⚠️  App not in IME list"
    @echo "=== Done ==="