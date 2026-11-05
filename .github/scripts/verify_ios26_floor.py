#!/usr/bin/env python3
"""Fail early if the public iOS 26 deployment floor drifts.

The actual compiled .app MinimumOSVersion is verified by the native workflow.
"""
from pathlib import Path
import plistlib
import re

root = Path(__file__).resolve().parents[2]
project = (root / "aReuImpress-iPhone.xcodeproj/project.pbxproj").read_text()
podfile = (root / "Podfile").read_text()
workflow = (root / ".github/workflows/r04-2-privacy-retirement-validation.yml").read_text()

settings = re.findall(r"\bIPHONEOS_DEPLOYMENT_TARGET\s*=\s*(\d+(?:\.\d+)?);", project)
assert len(settings) == 6 and set(settings) == {"26.0"}, ("deployment target drift", settings)
assert "platform :ios, '26.0'" in podfile
assert "config.build_settings['IPHONEOS_DEPLOYMENT_TARGET'] = '26.0'" in podfile
assert workflow.count("IPHONEOS_DEPLOYMENT_TARGET=26.0") == 3
assert "out/minimum-ios-version.txt" in workflow and "PlistBuddy" in workflow

with (root / "aReuImpress-iPhone/Info.plist").open("rb") as f:
    capabilities = plistlib.load(f).get("UIRequiredDeviceCapabilities", [])
assert "arm64" in capabilities and "armv7" not in capabilities, capabilities
print("PASS: iOS 26.0 deployment in project, CocoaPods, CI, and ARM64 capability")
