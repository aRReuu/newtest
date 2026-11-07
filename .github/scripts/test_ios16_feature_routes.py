#!/usr/bin/env python3
"""Fast iOS 16.7 availability/privacy source gate; not a native SDK typecheck."""
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]

def read(path: str) -> str:
    return (ROOT / path).read_text(encoding="utf-8")

speech = read("aReuImpress-iPhone/Utils/Public/ImSpeech/ImpressSpeechService.swift")
settings = read("aReuImpress-iPhone/Utils/Public/ImSpeech/ImpressSpeechSettingsViewController.swift")
translation = read("aReuImpress-iPhone/VC/SubVCs/ImNoteListVC/ImMarkdownVC/ImMarkdownViewController.swift")
widget = read("ImpressCalibrationWidgets/ImpressCalibrationWidgets.swift")
tabs = read("aReuImpress-iPhone/Base/ImTabBarViewController.swift")
project = read("aReuImpress-iPhone.xcodeproj/project.pbxproj")
pod = read("Podfile")

assert project.count("IPHONEOS_DEPLOYMENT_TARGET = 16.7;") == 10
assert "IPHONEOS_DEPLOYMENT_TARGET = 26.0;" not in project
assert "platform :ios, '16.7'" in pod
assert "config.build_settings['IPHONEOS_DEPLOYMENT_TARGET'] = '16.7'" in pod
assert "SWIFT_VERSION = 5.0" in project
assert "platforms: [.iOS(.v14), .macOS(.v12)]" in read("Packages/ImpressReviewCore/Package.swift")

# No high-version symbol may be called from the unguarded iOS 16 dispatcher.
assert speech.count("@available(iOS 26.0, *)") >= 2
assert "private final class ImpressSpeechAudioPipe" in speech
assert "final class ImpressSpeechModernService" in speech
assert "final class ImpressSpeechService" in speech
assert "if #available(iOS 26.0, *)" in speech
assert "final class ImpressLegacySpeechEngine" in speech
assert "requiresOnDeviceRecognition = true" in speech
assert "supportsOnDeviceRecognition" in speech
assert "SFSpeechRecognizer.requestAuthorization" in speech
assert "AVAudioSession.sharedInstance().requestRecordPermission" in speech
assert "if #available(iOS 17.0, *)" in settings
assert "AVAudioSession.sharedInstance().recordPermission" in settings

# iOS18 TranslationSession is never instantiated on iOS16. User consent
# and the exact Vault revision must be approved before legacy cloud calls.
assert "if #available(iOS 18.0, *)" in translation
assert "@available(iOS 18.0, *)" in translation
assert "private struct ImpressNoteChineseTranslationReader" in translation
assert "private final class ImpressLegacyNoteTranslationReader" in translation
assert "ImpressAIConfigStore.shared.registry.resolve(.knowledgeSynthesis)" in translation
assert "ImpressAIRequestPolicy.validate(route)" in translation
assert "ImVaultReadSync.shared.read(identity)" in translation
assert "document.digest == self.sourceDigest" in translation
assert "document.markdown == self.original" in translation
assert 'UIAction(title: V3L("全文译为简体中文")' in translation
assert 'title: V3L("授权将当前笔记发送给 AI 翻译？")' in translation
assert 'ImpressAIHTTPClient.shared.complete(' in translation
assert "translationTask?.cancel()" in translation

# iOS16 Widget fallback keeps original local snapshot + deep link.
assert "if #available(iOS 17.0, *)" in widget
assert "self.containerBackground(for: .widget)" in widget
assert "self.background(Color(uiColor: .systemGroupedBackground))" in widget
assert ".impressCompatibleWidgetBackground()" in widget
assert 'impress://calibration/' in widget

# iOS26-only Tab behavior remains guarded by availability.
assert "if #available(iOS 26.0, *)" in tabs
assert "tabBarMinimizeBehavior = .never" in tabs
print("PASS: iOS 16.7 floor, offline STT, consented translation, Widget and navigation")
