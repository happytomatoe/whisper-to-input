#!/bin/bash
# Test script to verify API key encryption
# Run this BEFORE and AFTER implementing the plan

ADB=/var/home/l/Android/Sdk/platform-tools/adb
PKG="com.example.whispertoinput"

echo "========================================="
echo "API Key Storage Verification"
echo "========================================="
echo ""

# Check if device is connected
DEVICE=$($ADB devices | grep -E "device$" | head -1 | awk '{print $1}')
if [ -z "$DEVICE" ]; then
    echo "ERROR: No device/emulator connected"
    echo "Start emulator and try again"
    exit 1
fi

echo "Device: $DEVICE"
echo "Package: $PKG"
echo ""

# Check if app is installed
if ! $ADB shell pm list packages | grep -q "$PKG"; then
    echo "ERROR: App not installed"
    echo "Install the app first and set an API key"
    exit 1
fi

echo "--- DataStore File (Plain Text) ---"
echo "Location: /data/data/$PKG/files/datastore/settings.preferences_pb"
echo ""

# Try to read DataStore file
DATASTORE_CONTENT=$($ADB shell run-as $PKG cat files/datastore/settings.preferences_pb 2>/dev/null)
if [ $? -eq 0 ]; then
    echo "File exists! Checking for API key..."
    echo ""
    
    # Search for common API key patterns
    echo "Searching for API key patterns (sk-, xi-, etc.):"
    echo "$DATASTORE_CONTENT" | strings | grep -E "^(sk-|xi-|Bearer )" || echo "  (none found in strings)"
    echo ""
    
    # Show hex dump (first 500 chars)
    echo "Hex dump (first 500 chars):"
    echo "$DATASTORE_CONTENT" | xxd | head -20
    echo ""
    
    # Show raw bytes
    echo "Raw strings found:"
    echo "$DATASTORE_CONTENT" | strings | head -10
else
    echo "DataStore file not found or not accessible"
fi

echo ""
echo "--- SecureStorage File (Encrypted) ---"
echo "Location: /data/data/$PKG/files/secure_storage"
echo ""

# Try to read SecureStorage file
SECURE_CONTENT=$($ADB shell run-as $PKG cat files/secure_storage 2>/dev/null)
if [ $? -eq 0 ]; then
    echo "File exists! Checking for API key..."
    echo ""
    
    # Search for common API key patterns
    echo "Searching for API key patterns (sk-, xi-, etc.):"
    echo "$SECURE_CONTENT" | strings | grep -E "^(sk-|xi-|Bearer )" || echo "  (none found - GOOD! Key is encrypted)"
    echo ""
    
    # Show hex dump (first 500 chars)
    echo "Hex dump (first 500 chars):"
    echo "$SECURE_CONTENT" | xxd | head -20
    echo ""
    
    # Show raw strings
    echo "Raw strings found:"
    echo "$SECURE_CONTENT" | strings | head -10
else
    echo "SecureStorage file not found (expected before implementation)"
fi

echo ""
echo "========================================="
echo "INTERPRETATION:"
echo "========================================="
echo ""
echo "BEFORE implementation:"
echo "  - DataStore file contains API key in plain text"
echo "  - SecureStorage file does not exist"
echo ""
echo "AFTER implementation:"
echo "  - DataStore file does NOT contain API key"
echo "  - SecureStorage file exists but API key is encrypted"
echo "  - grep for 'sk-' in SecureStorage returns nothing"
echo ""
