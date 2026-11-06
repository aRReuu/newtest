#!/usr/bin/env python3
"""Fast source-scope checks only; never claim XCTest, IPA or device acceptance."""
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]


def read(path):
    return (ROOT / path).read_text(encoding="utf-8")


web = read("aReuImpress-iPhone/VC/SubVCs/ImWebVC/ImWebViewController.swift")
speech = read("aReuImpress-iPhone/Utils/Public/ImSpeech/ImpressSpeechInputUI.swift")
cards = read("aReuImpress-iPhone/VC/MainVCs/ImCardVC/ImpressV3ReviewViewController.swift")
composer = read("aReuImpress-iPhone/VC/MainVCs/ImCardVC/ImpressV3CardComposerViewController.swift")
notes = read("aReuImpress-iPhone/VC/SubVCs/ImNoteListVC/ImMarkdownVC/ImMarkdownViewController.swift")
settings = read("aReuImpress-iPhone/Utils/Public/ImAI/ImpressAISettingsViewController.swift")
plist = read("aReuImpress-iPhone/Info.plist")
vault = read("aReuImpress-iPhone/Utils/Public/ImFileManager/ImObsidianManager.swift")

for symbol in (
    'https://chat.deepseek.com/',
    'callAsyncJavaScript(',
    'ImpressV3DeepSeekDOMBridge.insert',
    'ImpressV3DeepSeekDOMBridge.send',
    'location.hostname !== "chat.deepseek.com"',
    'impress.deepseek.insert-material',
    'impress.deepseek.send',
    'ImpressSpeechAccessory.presentWeb(',
):
    assert symbol in web, f"Web route lost {symbol}"

assert 'navigation.modalPresentationStyle = .fullScreen' in cards
assert 'navigation.modalPresentationStyle = .fullScreen' in notes
assert 'navigation.modalPresentationStyle = .fullScreen' in settings
assert 'ImWebViewController.forReviewHandoff(text: payload)' in cards
assert 'ImWebViewController.forReviewHandoff(text: payload)' in notes
assert 'ImWebViewController.forDirectBrowse()' in settings
assert 'ImpressSpeechAccessory.presentOCR(for: questionView)' in composer
assert 'ImpressSpeechAccessory.presentWeb(from: self)' in web

for symbol in (
    'import VisionKit',
    'import Vision',
    'VNDocumentCameraViewController()',
    'VNRecognizeTextRequest()',
    'ImpressSpeechTextBinding(view: field)',
    'camera, microphone',
    'self.onRecognized?(final)',
):
    assert symbol in speech, f"OCR/STT input lost {symbol}"

for symbol in (
    'impress.card.video.camera',
    'UIImagePickerController()',
    'beginVideoSelection(provider)',
    'removeCapturedVideoSource()',
    'impress.composer.ocr-camera',
):
    assert symbol in composer, f"Card media lost {symbol}"

for symbol in (
    '全文译为简体中文',
    'ImpressNoteChineseTranslationReader(',
    '.translationTask(source: nil,',
    'Text(original).textSelection(.enabled)',
    'Text(translated).textSelection(.enabled)',
):
    assert symbol in notes, f"Translation reader lost {symbol}"

assert '<key>NSCameraUsageDescription</key>' in plist
assert 'productionWriteEnabled = false' in vault
assert 'productionWriteEnabled = true' not in vault
print("November 2026 route and privacy checks PASS (static only)")
