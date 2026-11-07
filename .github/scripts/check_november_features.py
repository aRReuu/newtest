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
    'location.hostname !== "chat.deepseek.com"',
    'impress.deepseek.insert-material',
    'ImpressSpeechAccessory.presentWeb(',
):
    assert symbol in web, f"Web route lost {symbol}"

assert 'navigation.modalPresentationStyle = .fullScreen' in cards
assert 'navigation.modalPresentationStyle = .fullScreen' in notes
assert 'navigation.modalPresentationStyle = .fullScreen' in settings
assert 'ImWebViewController.forReviewHandoff(' in cards
assert 'ImWebViewController.forReviewHandoff(' in notes
assert 'ImWebViewController.forDirectBrowse()' in settings
assert 'linkedNativeDiscussion: ImpressAINativeChatViewController?' in web
assert 'nativeDiscussion: native' in cards
assert 'contentRevision: latest.contentRevision' in cards
assert 'nativeDiscussion: native' in notes
assert 'sourceVersion: latest.digest' in notes
assert 'impress.composer.ocr-camera' not in composer
assert 'V3L("拍照输入")' not in composer
assert 'V3L("拍摄视频")' not in composer
assert 'captureVideo()' in composer
assert 'ImpressSpeechAccessory.presentWeb(from: self)' in web
assert 'impress.deepseek.keyboard-tools' in web
assert 'sendWebMessage' not in web
assert 'startWebSpeech' not in web
assert 'ImpressSpeechAccessory.presentWebOCR(from: self)' in web
# iOS 18.4+ can supply a real, explicitly selected file URL to WebKit's
# own upload panel; iOS 16.7-18.3 keeps Safari-style native upload support.
for symbol in (
    'WKUIDelegate, UIDocumentPickerDelegate',
    'if #available(iOS 18.4, *)',
    'newWebView.uiDelegate = self',
    'runOpenPanelWith parameters: WKOpenPanelParameters',
    'frame.securityOrigin.host == "chat.deepseek.com"',
    'webFilePickerCompletion = completionHandler',
    'finishWebFileSelection([url])',
    'makeMarkdownAttachmentURL()',
    'UIDocumentPickerViewController(forExporting:',
):
    assert symbol in web, f"DeepSeek native attachment contract lost {symbol}"
assert 'webView(_ webView: WKWebView,' in web
assert 'sendWebMessage' not in web
assert 'ImpressV3DeepSeekDOMBridge.send' not in web
assert 'keyboardToolbar.isHidden = !visible' in web
assert 'webView.scrollView.backgroundColor = surface' in web

for symbol in (
    'import VisionKit',
    'import Vision',
    'VNDocumentCameraViewController()',
    'VNRecognizeTextRequest()',
    'ImpressSpeechTextBinding(view: field)',
    'camera, microphone',
    'self.onRecognized?(final)',
    'ImpressGlobalTextInputTools: NSObject',
    'UITextField.textDidBeginEditingNotification',
    'UITextView.textDidBeginEditingNotification',
):
    assert symbol in speech, f"OCR/STT input lost {symbol}"

for symbol in (
    'UIImagePickerController()',
    'beginVideoSelection(provider)',
    'removeCapturedVideoSource()',
    'activeVideoImportToken == token',
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
assert 'ImpressGlobalTextInputTools.shared.install()' in read("aReuImpress-iPhone/Base/AppDelegate.swift")
assert 'productionWriteEnabled = false' in vault
assert 'productionWriteEnabled = true' not in vault
print("November 2026 route and privacy checks PASS (static only)")
