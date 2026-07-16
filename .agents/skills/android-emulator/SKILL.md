---
name: android-emulator
description: Interact with Android emulator via ADB. Use XML-first approach (uiautomator dump) for reading UI state — it's faster and more reliable than screenshots. Use for tapping buttons, reading text, checking UI state, injecting audio, and testing Android apps.
---

# Android Emulator Interaction

## Key Principle: XML First (Default), Screenshots Only When Needed

**Default to `uiautomator dump` for ALL UI state reads.** XML is the primary, default approach. Screenshots are the exception, used only in the narrow cases listed below.

XML gives you:
- Exact text, bounds, and resource-ids for every element
- Programmatically parseable output (no OCR needed)
- Faster execution (no image transfer/parsing)
- Reliable element identification (no coordinate guessing)

### Decision rule

- Reading text, finding buttons, checking state, locating elements -> **XML** (always)
- Tapping/clicking -> **XML** to get bounds, then `input tap` at the center
- Verifying visual appearance (colors, icons, layout, overflow, rendering) -> **screenshot** (the only valid use)

**Only reach for a screenshot when you specifically need to verify pixels/visuals.** If you can answer the question from XML, do not screenshot.

## ADB Path

Default ADB path: `/var/home/l/Android/Sdk/platform-tools/adb`

Set as variable for convenience:
```bash
ADB=/var/home/l/Android/Sdk/platform-tools/adb
```

## Reading UI State (XML)

### Dump and parse UI hierarchy
```bash
$ADB shell uiautomator dump /sdcard/ui.xml 2>&1
$ADB shell cat /sdcard/ui.xml 2>&1 | python3 -c "
import sys, xml.etree.ElementTree as ET
tree = ET.parse(sys.stdin)
for node in tree.iter('node'):
    text = node.get('text', '')
    rid = node.get('resource-id', '')
    bounds = node.get('bounds', '')
    checked = node.get('checked', '')
    if text and len(text) > 2:
        print(f'{text[:60]} | id={rid} | bounds={bounds}')
"
```

### Find specific element by resource-id or text
```bash
$ADB shell cat /sdcard/ui.xml | grep -o 'resource-id="[^"]*btn_mic[^"]*"[^>]*bounds="[^"]*"'
```

### Extract all clickable elements
```bash
$ADB shell cat /sdcard/ui.xml | python3 -c "
import sys, xml.etree.ElementTree as ET
tree = ET.parse(sys.stdin)
for node in tree.iter('node'):
    if node.get('clickable') == 'true':
        text = node.get('text', '')
        rid = node.get('resource-id', '')
        bounds = node.get('bounds', '')
        print(f'{text[:40] or rid} | bounds={bounds}')
"
```

## Tapping Elements

### Tap by coordinates (from XML bounds)
```bash
# bounds="[x1,y1][x2,y2]" -> tap center: ((x1+x2)/2, (y1+y2)/2)
$ADB shell input tap 540 1200
```

### Tap with touchscreen source (for IME windows)
```bash
$ADB shell input touchscreen tap 540 1200
```

### Motion event (more reliable for some IME buttons)
```bash
$ADB shell input motionevent DOWN 450 1570
sleep 0.1
$ADB shell input motionevent UP 450 1570
```

## Common Operations

### Launch app
```bash
$ADB shell am start -n com.example.app/.MainActivity
```

### Open system settings
```bash
$ADB shell am start -a android.settings.APPLICATION_DEVELOPMENT_SETTINGS  # Developer Options
$ADB shell am start -a android.settings.SETTINGS                           # Main Settings
```

### Grant permissions
```bash
$ADB shell pm grant com.example.app android.permission.RECORD_AUDIO
```

### Install APK
```bash
$ADB install -r path/to/app.apk
```

### Check running processes
```bash
$ADB shell ps | grep -i example
```

### Check enabled input methods
```bash
$ADB shell settings get secure enabled_input_methods
```

## Audio Injection (for STT testing)

### Via emulator Extended Controls
1. Open Extended Controls (three dots in emulator toolbar)
2. Go to Microphone
3. Load WAV file
4. Play during recording

### Via PulseAudio virtual mic (Linux host)
```bash
# Setup virtual microphone
pactl load-module module-null-sink sink_name=virtual_mic
pactl load-module module-loopback source=virtual_mic.monitor

# Play audio into virtual mic
paplay --device=virtual_mic test-audio.wav
```

### Boot emulator with virtual mic
```bash
PULSE_SOURCE=virtual_mic.monitor emulator -avd your_avd -audio pulse
```

## Debugging Tips

### Check if tap is registering
Enable Pointer Location in Developer Options to see touch coordinates.

### IME buttons not responding
- Enable "USB debugging (Security Settings)" in Developer Options (manual toggle)
- Try `input touchscreen tap` instead of `input tap`
- Try `input motionevent DOWN/UP` pair

### Keyboard not showing
- Tap a text input field first
- Check IME is enabled: `settings get secure enabled_input_methods`

### Logcat for app debugging
```bash
$ADB logcat -d -t 100 | grep -i "yourapp\|error\|exception"
```

## E2E Test Pattern

```bash
#!/bin/bash
ADB=/var/home/l/Android/Sdk/platform-tools/adb
PKG="com.example.app"
AUDIO_FILE="test-audio.wav"
EXPECTED_TEXT="hello world"

# Setup
$ADB install -r app.apk
$ADB shell pm grant $PKG android.permission.RECORD_AUDIO
$ADB shell am start -n $PKG/.MainActivity
sleep 2

# Read UI state via XML
$ADB shell uiautomator dump /sdcard/ui.xml
# Parse XML to find mic button coordinates...

# Tap mic to start recording
$ADB shell input tap $MIC_X $MIC_Y

# Inject audio (host-side)
paplay --device=virtual_mic $AUDIO_FILE

# Tap mic to stop recording
$ADB shell input tap $MIC_X $MIC_Y

# Wait for transcription
sleep 5

# Verify result via XML
$ADB shell uiautomator dump /sdcard/result.xml
$ADB shell cat /sdcard/result.xml | grep -o "text=\"[^\"]*\""
```
