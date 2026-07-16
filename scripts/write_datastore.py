#!/usr/bin/env python3
"""Write an Android Preferences DataStore protobuf file for whisper-to-input.

Creates a valid settings.preferences_pb that the app reads on launch,
bypassing the UI for backend selection and API key entry.

Usage:
  write_datastore.py --backend deepgram --key <API_KEY> [-o output_file]
  write_datastore.py --backend deepgram --key <API_KEY> | adb shell "run-as com.example.whispertoinput sh -c 'mkdir -p files/datastore && cat > files/datastore/settings.preferences_pb'"
"""

import argparse
import sys
import struct


def encode_varint(value: int) -> bytes:
    """Encode an integer as a protobuf varint."""
    result = []
    while value > 0x7F:
        result.append((value & 0x7F) | 0x80)
        value >>= 7
    result.append(value)
    return bytes(result)


def encode_bytes(field_number: int, data: bytes) -> bytes:
    """Encode a length-delimited field."""
    tag = (field_number << 3) | 2  # wire type 2 = length-delimited
    return encode_varint(tag) + encode_varint(len(data)) + data


def encode_varint_field(field_number: int, value: int) -> bytes:
    """Encode a varint field."""
    tag = (field_number << 3) | 0  # wire type 0 = varint
    return encode_varint(tag) + encode_varint(value)


def encode_string_field(field_number: int, value: str) -> bytes:
    """Encode a string field."""
    return encode_bytes(field_number, value.encode("utf-8"))


def encode_map_string_entry(key: str, string_value: str) -> bytes:
    """Encode a map<string, Value> entry where Value.string = string_value.

    Map entry structure:
      field 1 (string): key
      field 2 (Value):  { field 4 (string): string_value }
    """
    key_field = encode_string_field(1, key)
    value_payload = encode_string_field(4, string_value)
    value_field = encode_bytes(2, value_payload)
    entry = key_field + value_field
    return encode_bytes(1, entry)  # field 1 of Preferences = map entry


def encode_map_bool_entry(key: str, bool_value: bool) -> bytes:
    """Encode a map<string, Value> entry where Value.boolean = bool_value.

    Map entry structure:
      field 1 (string): key
      field 2 (Value):  { field 1 (bool): bool_value }
    """
    key_field = encode_string_field(1, key)
    value_payload = encode_varint_field(1, 1 if bool_value else 0)
    value_field = encode_bytes(2, value_payload)
    entry = key_field + value_field
    return encode_bytes(1, entry)  # field 1 of Preferences = map entry


BACKEND_CONFIG = {
    "deepgram": {
        "endpoint": "https://api.deepgram.com/v1/listen",
        "model": "nova-3",
        "language_code": "",
    },
    "groq": {
        "endpoint": "https://api.groq.com/openai/v1/audio/transcriptions",
        "model": "whisper-large-v3-turbo",
        "language_code": "",
    },
    "60db": {
        "endpoint": "https://api.60db.ai/stt",
        "model": "60db-stt-v01",
        "language_code": "",
    },
    "elevenlabs": {
        "endpoint": "https://api.elevenlabs.io/v1/speech-to-text",
        "model": "scribe_v1",
        "language_code": "auto",
    },
}


def build_preferences(backend: str, api_key: str) -> bytes:
    """Build the Preferences protobuf binary."""
    config = BACKEND_CONFIG[backend]
    entries = b""
    backend_display = {
        "deepgram": "Deepgram",
        "groq": "Groq",
        "60db": "60db",
        "elevenlabs": "ElevenLabs Scribe",
    }
    entries += encode_map_string_entry("speech-to-text-backend", backend_display[backend])
    entries += encode_map_string_entry("endpoint", config["endpoint"])
    entries += encode_map_string_entry("api-key", api_key)
    entries += encode_map_string_entry("model", config["model"])
    entries += encode_map_string_entry("language-code", config["language_code"])
    entries += encode_map_string_entry("postprocessing", "No Conversion")
    entries += encode_map_bool_entry("is-auto-recording-start", True)
    entries += encode_map_bool_entry("auto-switch-back", False)
    entries += encode_map_bool_entry("add-trailing-space", False)
    return entries


def main():
    parser = argparse.ArgumentParser(description="Write whisper-to-input DataStore preferences")
    parser.add_argument("--backend", required=True, choices=["deepgram", "groq", "60db", "elevenlabs"])
    parser.add_argument("--key", required=True, help="API key for the backend")
    parser.add_argument("-o", "--output", help="Output file (default: stdout)")
    args = parser.parse_args()

    prefs = build_preferences(args.backend, args.key)

    if args.output:
        with open(args.output, "wb") as f:
            f.write(prefs)
        print(f"Written {len(prefs)} bytes to {args.output}", file=sys.stderr)
    else:
        sys.stdout.buffer.write(prefs)


if __name__ == "__main__":
    main()
