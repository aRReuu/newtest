#!/usr/bin/env python3
"""Static, fail-closed guard for dual Apple on-device STT (iOS 16.7+).

This does NOT replace a hardware/locale microphone test on iPhone 13.
"""
from pathlib import Path
import plistlib

root = Path(__file__).resolve().parents[2]
app = root / "aReuImpress-iPhone"
speech = app / "Utils/Public/ImSpeech"
source = (speech / "ImpressSpeechService.swift").read_text()
ui = (speech / "ImpressSpeechInputUI.swift").read_text()
settings = (speech / "ImpressSpeechSettingsViewController.swift").read_text()
project = (root / "aReuImpress-iPhone.xcodeproj/project.pbxproj").read_text()
with (app / "Info.plist").open("rb") as f:
    info = plistlib.load(f)
assert info.get("NSMicrophoneUsageDescription")
assert info.get("NSSpeechRecognitionUsageDescription")
assert "SpeechAnalyzer(" in source and "SpeechTranscriber(" in source
assert "DictationTranscriber(" in source
assert "AssetInventory.assetInstallationRequest" in source
assert "AVAudioApplication.requestRecordPermission" in source
# iOS 27 introduced convenience capture/converter types. The iOS 26
# implementation uses longstanding AVAudioConverter and direct AnalyzerInput.
assert "CaptureInputSequenceProvider?" not in source
assert "providerWithSession" not in source
assert "AnalyzerInputConverter(" not in source
assert "AVAudioEngine()" in source
assert "tapInstalled = true" in source and "if tapInstalled" in source
assert "AVAudioConverter(from:" in source
assert "AnalyzerInput(buffer:" in source
assert "UnsafeMutableAudioBufferListPointer" in source
assert "feed.stream" in source
# iOS 16.7-25 must remain supported without cloud audio transmission.
assert "@available(iOS 26.0, *)" in source
assert "final class ImpressSpeechModernService" in source
assert "final class ImpressSpeechService" in source
assert "final class ImpressLegacySpeechEngine" in source
assert "SFSpeechRecognizer(locale: choice.locale)" in source
assert "SFSpeechRecognizer.requestAuthorization" in source
assert "supportsOnDeviceRecognition" in source
assert "requiresOnDeviceRecognition = true" in source
assert "AVAudioSession.sharedInstance().requestRecordPermission" in source
assert "if #available(iOS 26.0, *)" in source
assert "finishWaiter" in source and "resolveFinishing" in source
assert "URLSession" not in source and "AVAudioRecorder" not in source
assert "FileManager.default" not in source
assert "NSLog" not in source and "print(" not in source
assert "ImpressSpeechTextInsertion.inserting(" in ui
assert "changedWhileRecording" in ui
assert "original" in ui and "selected: selection" in ui
assert "inputAccessoryView" in ui
assert "SpeechInput" not in str(info.get("UIBackgroundModes", []))
assert "func downloadSelectedModel()" in settings
assert "ImpressSpeechLocale.allCases" in settings
assert "ImpressSpeechService.swift in Sources" in project
assert "ImpressSpeechInputUI.swift in Sources" in project
assert "ImpressSpeechSettingsViewController.swift in Sources" in project
for relative, anchors in {
    "VC/MainVCs/ImCardVC/ImpressV3CardComposerViewController.swift":
        ("install(on: questionView, captureVideo:",
         "install(on: answerView, captureVideo:", "install(on: field)"),
    "VC/MainVCs/ImCardVC/ImpressV3BatchImportViewController.swift":
        ("install(on: editor)",),
    "VC/MainVCs/ImCardVC/ImpressV3ReviewViewController.swift":
        ("install(on: input)", "destination: .speech"),
    "VC/SubVCs/ImSettingVC/ImpressV3PromptLibraryViewController.swift":
        ("install(on: titleField)", "install(on: contentView)"),
    "VC/SubVCs/ImNoteListVC/ImMarkdownVC/ImMarkdownViewController.swift":
        ("install(on: sourceView)", "sourceView.isEditable = true"),
}.items():
    text = (app / relative).read_text()
    for anchor in anchors:
        assert anchor in text, (relative, anchor)
print("PASS: iOS16+ and iOS26+ native offline STT, one facade, secure text insertion, permissions")
