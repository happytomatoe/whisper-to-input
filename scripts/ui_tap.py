#!/usr/bin/env python3
"""Tap an emulator UI element by resource-id or text via uiautomator dump.

Usage:
  ui_tap.py --rid  com.example.whispertoinput:id/spinner_speech_to_text_backend
  ui_tap.py --text "Voxtral (Mistral)"
  ui_tap.py --contains "Speech to Text"
  ui_tap.py --dump                  # just print parsed nodes with text/id
"""
import sys, re, subprocess, xml.etree.ElementTree as ET

ADB = "/var/home/l/Android/Sdk/platform-tools/adb"
DEV = "-s emulator-5554"

def run(cmd):
    return subprocess.run(cmd, shell=True, capture_output=True, text=True)

def dump():
    run(f"{ADB} {DEV} shell uiautomator dump /sdcard/ui.xml")
    return run(f"{ADB} {DEV} shell cat /sdcard/ui.xml").stdout

def center(node):
    b = node.get('bounds', '')
    nums = list(map(int, re.findall(r'\d+', b)))
    x1, y1, x2, y2 = nums
    return (x1 + x2) // 2, (y1 + y2) // 2

def find(xml, rid=None, text=None, contains=None):
    root = ET.fromstring(xml)
    for node in root.iter('node'):
        r = node.get('resource-id', '')
        t = node.get('text', '')
        if rid and rid in r:
            return node
        if text is not None and text == t:
            return node
        if contains is not None and contains in t:
            return node
    return None

def printable(xml):
    root = ET.fromstring(xml)
    for node in root.iter('node'):
        t = node.get('text', '')
        r = node.get('resource-id', '')
        c = node.get('class', '')
        if t or 'EditText' in c or 'Spinner' in c:
            print(f"text={t!r:50} id={r} class={c}")

def main():
    args = sys.argv[1:]
    if '--dump' in args:
        printable(dump()); return
    rid = text = contains = None
    if '--rid' in args: rid = args[args.index('--rid') + 1]
    if '--text' in args: text = args[args.index('--text') + 1]
    if '--contains' in args: contains = args[args.index('--contains') + 1]
    xml = dump()
    node = find(xml, rid=rid, text=text, contains=contains)
    if node is None:
        print("ELEMENT NOT FOUND", file=sys.stderr); sys.exit(2)
    x, y = center(node)
    run(f"{ADB} {DEV} shell input tap {x} {y}")
    print(f"tapped ({x},{y})")

if __name__ == "__main__":
    main()
