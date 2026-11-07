#!/usr/bin/env python3
"""Historical CI entry path: verify the actual iOS 16.7 deployment contract.

Source checks only: native CI must also inspect .app/.appex MinimumOSVersion.
"""
from pathlib import Path
import plistlib
import re

root = Path(__file__).resolve().parents[2]
project = (root / "aReuImpress-iPhone.xcodeproj/project.pbxproj").read_text()
podfile = (root / "Podfile").read_text()
settings = re.findall(r"\bIPHONEOS_DEPLOYMENT_TARGET\s*=\s*(\d+(?:\.\d+)?);", project)
assert len(settings) == 10 and set(settings) == {"16.7"}, ("deployment drift", settings)
assert "platform :ios, '16.7'" in podfile
assert "config.build_settings['IPHONEOS_DEPLOYMENT_TARGET'] = '16.7'" in podfile
assert "26.0" not in podfile, "Do not override the deployment floor in Pods"
with (root / "aReuImpress-iPhone/Info.plist").open("rb") as f:
    info = plistlib.load(f)
assert "arm64" in info.get("UIRequiredDeviceCapabilities", [])
assert info.get("NSMicrophoneUsageDescription")
assert info.get("NSSpeechRecognitionUsageDescription")
print("PASS: iOS 16.7 deployment in Xcode and CocoaPods plus speech privacy keys")
