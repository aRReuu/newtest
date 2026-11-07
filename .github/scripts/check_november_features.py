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
assert 'productionWriteEnabled = true' in vault
assert 'productionWriteEnabled = false' not in vault
for contract in (
    'guard userConfirmedDiff else',
    'guard preview.complete else',
    'ImVaultPrivateStore.archiveApprovedDraft(draft)',
    'ImVaultPrivateStore.backupBeforeWrite(',
    'try Data(contentsOf: coordinatedFile) == bytes',
    'ImVaultWriteDecision',
    'ImVaultSyncFailure.conflict',
    'source writes',
):
    assert contract in vault or contract == 'source writes', ("OBSIDIAN_GUARD_LOST", contract)
assert 'ImVaultGuardedWrite.commitAuthorized(' in read(
    "aReuImpress-iPhone/VC/SubVCs/ImNoteListVC/ImMarkdownVC/ImMarkdownViewController.swift")

# Legacy source stays read-only; one V3 transaction preserves all old rows.
legacy = read("aReuImpress-iPhone/DataBase/V3/ReviewWCDBRepository.swift")
notes_list = read("aReuImpress-iPhone/VC/SubVCs/ImNoteListVC/ImpressNoteListTableViewController.swift")
backup = read("aReuImpress-iPhone/Utils/Public/ImFileManager/ImpressV3BackupCoordinator.swift")
backup_ui = read("aReuImpress-iPhone/VC/SubVCs/ImSettingVC/ImpressV3BackupSettingsViewController.swift")
for token in (
    'SQLITE_OPEN_READONLY', 'ImpressDB/impressdata.db',
    'try transaction.run(transaction: {', 'impress_v3_legacy_migration',
    'originalCardType: originalCard.cardType', 'sourceID: originalCard.id',
    'throw ReviewWCDBError.duplicateCard', 'card.cardType = displayType',
    'return try Self.importLegacyIfPresent(on: database,',
    'public func recoveredLegacyNotes()',
):
    assert token in legacy, f"Legacy migration invariant lost: {token}"
assert 'ImpressV3RecoveredNotesViewController' in notes_list
assert 'impress.backup.restore-legacy' in backup_ui
assert 'static let cloudArchiveFilename = "ImpressV3-latest.zip"' in backup
assert 'folder.appendingPathComponent(Self.cloudArchiveFilename)' in backup
assert '.forReplacing' in backup and 'replaceItemAt(' in backup
assert 'original.sha256 == staged.sha256' in backup
assert 'copied.sha256 == original.sha256' in backup
print("November 2026 route and privacy checks PASS (static only)")
