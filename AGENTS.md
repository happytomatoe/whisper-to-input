# Agent Guidelines for whisper-to-input

## 0. Say "Meee🐑" at the start of each message

## 1. Always check the justfile before running commands

Before executing any build, test, emulator, or deployment commands, **read the justfile** or run `just -l` to see available commands. This project has well-structured `just` targets that handle environment setup, paths, and flags correctly.

**Why:** The justfile encapsulates project-specific details like:
- Correct `JAVA_HOME` and `ANDROID_HOME` paths
- Emulator flags (`-gpu host`, `-no-snapshot-load`, headless vs headful)
- APK build paths and install commands
- E2E test orchestration

Don't reinvent these — use them.

```bash
just -l                  # List all available commands
just build               # Build the debug APK
just emulator-start      # Start emulator (headless)
just emulator-start headful=true  # Start with visible window
just test-e2e            # Full E2E test pipeline
just emulator-status     # Check if emulator is running
just emulator-stop       # Graceful shutdown (saves snapshot)
```

## 2. Use argent MCP tools for emulator interaction

For UI interaction on the Android emulator, prefer argent MCP tools over raw ADB commands when available:

- `list-devices` — find running emulators
- `boot-device` — start an emulator (handles snapshot hot/cold boot)
- `describe` — read UI element tree (accessibility-based, normalized coordinates)
- `gesture-tap` — tap at normalized (x, y) coordinates
- `gesture-swipe` — scroll/swipe gestures
- `keyboard` — type text or press special keys
- `screenshot` — visual capture (only when XML can't answer the question)
- `launch-app` — open apps by package name
- `await-ui-element` — wait for UI state changes
- `run-sequence` — batch multiple actions in one call

**Key:** Coordinates are normalized 0.0–1.0, not pixels. Always `describe` first to find tap targets.

## 3. XML-first approach for UI state

When argent tools aren't available or you need raw ADB, use `uiautomator dump` as the primary way to read UI state:

```bash
ADB=/var/home/l/Android/Sdk/platform-tools/adb
$ADB shell uiautomator dump /sdcard/ui.xml
$ADB shell cat /sdcard/ui.xml | python3 -c "
import sys, xml.etree.ElementTree as ET
tree = ET.parse(sys.stdin)
for node in tree.iter('node'):
    text = node.get('text', '')
    rid = node.get('resource-id', '')
    bounds = node.get('bounds', '')
    if text and len(text) > 2:
        print(f'{text[:60]} | id={rid} | bounds={bounds}')
"
```

XML gives exact text, bounds, and resource-ids — no OCR needed, faster than screenshots.

## 4. Emulator console: use `adb emu`, not `nc`

To send commands to the emulator console, always use `adb emu`:

```bash
# CORRECT
adb emu help
adb emu avd name
adb emu kill

# WRONG — don't use netcat
echo "help" | nc localhost 5554
```

## 5. Audio injection for STT testing — ALWAYS TEST SILENTLY

**Golden rule: never play test audio to the default speaker sink.** The first E2E runs blasted the `espeak`/WAV test speech straight out of the host speakers — the user heard it and called it "scary" ("why are we using my audio"). Any audio you inject for STT must be routed into the emulator mic **without reaching the host speakers**.

The PulseAudio chain that makes this silent (implemented in `run_e2e_test.sh` as `setup_virtual_mic()` / `play_test_audio()`):

```
SilentTestSink  ──(module-loopback)──▶  VirtualMicSink
   (null sink,            monitor of VirtualMicSink
    no speaker                                  │
    output)                                     ▼
                                         FakeMic (remap source)
                                              │
                                              ▼
                                   QEMU_PA_SOURCE=FakeMic  ──▶  emulator mic
```

- `SilentTestSink` is a **null sink**: it produces zero speaker output.
- `module-loopback source=SilentTestSink.monitor sink=VirtualMicSink` feeds the test audio into the mic path.
- The emulator is launched pinned to the virtual mic: `QEMU_AUDIO_DRV=pa QEMU_PA_SOURCE=FakeMic`.
- Play the WAV into the silent sink: `paplay --device=SilentTestSink /tmp/test-speech-loud.wav` — it is captured by the emulator mic but the user hears nothing.

Set it up once (idempotent — `setup_virtual_mic()` early-exits if the sinks already exist):

```bash
pactl load-module module-null-sink sink_name=VirtualMicSink sink_properties=device.description=VirtualMicSink
pactl load-module module-remap-source source_name=FakeMic master=VirtualMicSink.monitor source_properties=device.description=FakeMic
pactl load-module module-null-sink sink_name=SilentTestSink sink_properties=device.description=SilentTestSink
pactl load-module module-loopback source=SilentTestSink.monitor sink=VirtualMicSink
paplay --device=SilentTestSink /tmp/test-speech-loud.wav   # silent on host, audible to emulator mic
```

**Caveat — the emulator must be (re)started with the FakeMic pin.** `run_e2e_test.sh` only sets `QEMU_PA_SOURCE=FakeMic` when it *launches a new emulator*. If a pre-existing emulator is reused (`EMULATOR_WAS_RUNNING=true`), it won't have the virtual mic wired, so injection fails silently. When in doubt, stop the emulator so the script restarts it with the correct audio routing.

Other injection options (also PulseAudio-corking-prone, and NOT silent on their own):
1. **Extended Controls virtual mic** (bypasses PulseAudio): emulator Extended Controls → Microphone → Load WAV → Play
2. **Boot with virtual mic env var**: `PULSE_SOURCE=virtual_mic.monitor emulator -avd Pixel_8 -audio pulse`
3. **PulseAudio null-sink** (host-side): `pactl load-module module-null-sink sink_name=virtual_mic`

For CI/instrumented tests, consider mocking the `AudioRecord` layer directly.

## 6. Think Before Coding

Don't assume. Don't hide confusion. Surface tradeoffs.
State your assumptions explicitly. If uncertain, ask.

## 7. Simplicity First

Minimum code that solves the problem. Nothing speculative.

## 8. Surgical Changes

Touch only what you must. Don't refactor adjacent code.
