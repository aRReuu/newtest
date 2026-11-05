#!/usr/bin/env python3
"""Regression tripwire against reintroducing superseded Impress UI rules.

Static assertions are NOT a replacement for XCTest or real-device acceptance.
No network calls, private Vault reads, API access, signing or filesystem writes.
"""
from pathlib import Path
import re

ROOT = Path(__file__).resolve().parents[2]
contract = (ROOT / "PRODUCT_REQUIREMENTS_CURRENT.md").read_text(encoding="utf-8")
ledger_ids = set(re.findall(
    r"^\|\s*((?:NAV|LOOP|CARD|UI|AI|CHAT|CAL|LOCAL|SAFE)-\d{2})\s*\|",
    contract, flags=re.MULTILINE))
acceptance = set(re.findall(r"^\|\s*(ACCEPT-\d{2})\s*\|",
                            contract, flags=re.MULTILINE))
open_issues = set(re.findall(r"^\|\s*(OPEN-\d{2})\s*\|",
                             contract, flags=re.MULTILINE))
# Stable requirements are an exact contract, not an aggregate target.
# Checking only len >= 85 would let one ID disappear as another is duplicated
# or a superseded historical ID is accidentally reintroduced.
expected_groups = {
    "NAV": 6, "LOOP": 14, "CARD": 14, "UI": 4, "AI": 7,
    "CHAT": 11, "CAL": 15, "LOCAL": 3, "SAFE": 11,
}
expected_ids = {
    f"{prefix}-{index:02d}"
    for prefix, count in expected_groups.items()
    for index in range(1, count + 1)
}
expected_acceptance = {f"ACCEPT-{i:02d}" for i in range(1, 13)}
expected_open = {f"OPEN-{i:02d}" for i in range(1, 7)}
assert len(expected_ids) == 85
assert ledger_ids == expected_ids, (
    f"Stable requirement drift: missing={sorted(expected_ids - ledger_ids)}, "
    f"unknown={sorted(ledger_ids - expected_ids)}"
)
assert acceptance == expected_acceptance, (
    f"Acceptance drift: missing={sorted(expected_acceptance - acceptance)}"
)
assert open_issues == expected_open, (
    f"Open decisions drift: missing={sorted(expected_open - open_issues)}"
)

def source(path):
    return (ROOT / path).read_text(encoding="utf-8")

review = source("aReuImpress-iPhone/VC/MainVCs/ImCardVC/ImpressV3ReviewViewController.swift")
memory = source("aReuImpress-iPhone/View/ImCard/ImMemoryCard/ImMemoryCardView.swift")
composer = source("aReuImpress-iPhone/VC/MainVCs/ImCardVC/ImpressV3CardComposerViewController.swift")
chat = source("aReuImpress-iPhone/Utils/Public/ImAI/ImpressAINativeChatViewController.swift")
repo = source("aReuImpress-iPhone/DataBase/V3/ReviewWCDBRepository.swift")
notes = source("aReuImpress-iPhone/VC/SubVCs/ImNoteListVC/ImMarkdownVC/ImMarkdownViewController.swift")
note_list = source("aReuImpress-iPhone/VC/SubVCs/ImNoteListVC/ImpressNoteListTableViewController.swift")
vault = source("aReuImpress-iPhone/Utils/Public/ImFileManager/ImObsidianManager.swift")
workflow = source(".github/workflows/private-v33-native-qa.yml")

assert "contentHistoryAction" not in review, "Superseded review footer history returned"
assert "impress.composer.content-history" in composer, "Editor lost content history"
assert "questionTextView.setMarkdownText" in memory
assert "questionTextView.textContainer.maximumNumberOfLines = 3" in memory
assert "questionTextView.isScrollEnabled = false" in memory
assert "onFullQuestionRequested" in memory
assert "ImpressV3QuestionLayout.isTruncated" in memory
assert "impress.review.full-question" in review
assert "impress.review.quick-edit" in review and "impress.review.ai-discussion" in review
assert "answerTools" not in review, "Old review footer actions were restored"
assert "updateQuestionTextViewHeight(revealed: true)" in memory
assert "impress.ai.chat.history" in chat and "impress.ai.chat.new-discussion" in chat
assert "switchDiscussion(to" in chat and "flushBeforeSwitch()" in chat
assert "impress_v3_chat_session" in repo, "Chat local history authority missing"
assert "saveChatSession" in repo and "chatSessions(for sourceIdentity:" in repo
assert "impress.notes.ai-discussion" in notes, "Notes no longer opens shared Chat"
assert "UI-03.a" in contract and "outlineRows(" in note_list, "Notes outline requirement or implementation missing"
assert "expandedExternalFolders" in note_list and "impress.notes.folder-row" in note_list
assert "impress.notes.file-row" in note_list and "content.secondaryText = note.identity.relativePath" not in note_list
assert "ImVaultReadSync.shared.read(item.identity)" in note_list, "Original Vault read gate bypassed by outline"
assert re.search(r"productionWriteEnabled\s*=\s*false\b", vault)
assert not re.search(r"productionWriteEnabled\s*=\s*true\b", vault)
assert "private" in contract.lower() or "私有" in contract
assert "ImVaultPrivateStore.approvedDraft" in chat
assert "ImVaultPrivateStore.archiveApprovedDraft" in chat
assert "ImpressSourceImpactCardRevisionGate.refreshedInput" in notes
assert "ImpressChatNoteUploadGate.validate" in chat
assert "ImpressChatProviderConsentGate.needsReapproval" in chat
# Static presence is not an E2E or visual-pass claim. These tripwires keep
# reviewed source-scope boundaries attached to the shipped implementation.
canvas = source("Packages/ImpressReviewCore/Sources/ImpressReviewCore/ImpressCanvasDocument.swift")
markdown_structure = source("Packages/ImpressReviewCore/Sources/ImpressReviewCore/ImpressMarkdownStructure.swift")
excalidraw = source("Packages/ImpressReviewCore/Sources/ImpressReviewCore/ImpressExcalidrawScene.swift")
assert "ImpressCanvasNativeView" in notes and "impress.canvas.material-preview" in notes
assert "selectedCanvasNodeIDs" in repo and "json-canvas" in chat
assert "ImpressCanvasDocument.parse" in chat and "sourceRevision == expectedDigest" in chat
assert "ImpressCanvasSelection" in canvas and "selectedIDs" in notes
assert "public enum ImpressMarkdownStructure" in markdown_structure and "public static func sections(" in markdown_structure
assert "ImpressDuplexScopedDraftBuilder" in chat
assert "ImVaultPrivateStore.saveDraft" in chat and "popToViewController" in chat
assert "byteFaithfulEditedText" in chat and "byteFaithfulEditedText" in vault
assert "compressedDataUnsupported" in excalidraw, "Unsupported compressed drawings must fail visibly"
assert "allowsGenericMarkdownDraft" in vault, "Complex drawing formats must remain read-only"

smoke = source("SMOKE_TEST_MATRIX.md")
native_tests = source("aReuImpress-iPhoneTests/V3/ReviewWCDBRepositoryTests.swift")
for acceptance_id in expected_acceptance:
    assert acceptance_id in smoke, f"Missing smoke evidence reference: {acceptance_id}"
for symbol in (
    "testDisposableVaultCardChatDuplexFullRoundTripAfterInterveningFSRS",
    "testTwoApprovedNoteRevisionsRemainIndependentAndUndoInReverseOrder",
    "testSourceImpactRevisesOriginalCardWithFreshFSRSAndExactSource",
    "testChatNoteMaterialGateRejectsStaleForgedAndOversizedExcerpts",
    "testChatProviderSwitchRequiresConsentAfterFailedFirstAttempt",
    "testLongChatWarnsAboutRemoteWindowWithoutDiscardingLocalHistory",
):
    assert symbol in native_tests, f"Missing P0 native regression: {symbol}"

# WidgetKit MUST NOT introduce a parallel or status-matrix substitute for the
# native Cartesian chart. These source checks complement actual Core/XCUITest
# cases and a device screenshot comparison; they do not imply visual QA PASS.
calibration_view = source("aReuImpress-iPhone/VC/MainVCs/ImCalibrationVC/ImpressCalibrationViewController.swift")
widget = source("ImpressCalibrationWidgets/ImpressCalibrationWidgets.swift")
shared_chart = source("Packages/ImpressReviewCore/Sources/ImpressReviewCore/CalibrationCartesianTrendRenderer.swift")
plot_source = source("Packages/ImpressReviewCore/Sources/ImpressReviewCore/CalibrationWidgetCartesianPlot.swift")
assert "CalibrationCartesianTrendRenderer.draw(" in calibration_view
assert "CalibrationCartesianTrendRenderer.image(" in widget
assert "private struct StatusDot" not in widget and "LazyVGrid(" not in widget
assert "public enum CalibrationCartesianTrendRenderer" in shared_chart
assert "static func cartesianPlot(" in plot_source
# Latest UIKit visual/navigation contract (static guard, NOT device acceptance).
style = source("aReuImpress-iPhone/Utils/Constansts/ImColorConstants.swift")
flash = source("aReuImpress-iPhone/View/ImCard/ImMemoryCard/ImMemoryCardView.swift")
extract = source("aReuImpress-iPhone/Utils/Public/ImExtractTextView/ImExtractTextView.swift")
composer = source("aReuImpress-iPhone/VC/MainVCs/ImCardVC/ImpressV3CardComposerViewController.swift")
batch = source("aReuImpress-iPhone/VC/MainVCs/ImCardVC/ImpressV3BatchImportViewController.swift")
list_notes = source("aReuImpress-iPhone/VC/SubVCs/ImNoteListVC/ImpressNoteListTableViewController.swift")
reader = source("aReuImpress-iPhone/VC/SubVCs/ImNoteListVC/ImMarkdownVC/ImMarkdownViewController.swift")
ai_page = source("aReuImpress-iPhone/Utils/Public/ImAI/ImpressAISettingsViewController.swift")
widget_export = source("aReuImpress-iPhone/VC/MainVCs/ImCalibrationVC/ImpressCalibrationWidgetExporter.swift")
assert "styleFlashcardText" in style and "Typography.flashQuestion" in flash
assert "visibleLineCount(" in flash and "maximumNumberOfLines = 3" in flash
assert "UIMenuController.shared.menuItems" not in extract and "extractSpecifiedContent" not in extract
assert "styleSegmentedControl(typePicker, prominent: false)" in composer
assert "styleSegmentedControl(formatPicker, prominent: false)" in batch
assert "animateOutlineChange" in list_notes and "tableView.performBatchUpdates" in list_notes
assert "impress.notes.document-title" in reader and "impress.notes.source-path" not in reader
assert "more.menu = chatFeaturesMenu()" in chat and "UIMenu(title: V3L(\"对话设置\")" in chat
assert "content.imageProperties.tintColor = ImpressV3Appearance.listIconTint" in ai_page
assert "case ready, missingAppGroup, missingSnapshot, invalidSnapshot" in widget_export
import plistlib
app_group_key = "com.apple.security.application-groups"
for relative in ("aReuImpress-iPhone/aReuImpress-iPhone.entitlements",
                 "aReuImpress-iPhone/aReuImpress-iPhoneDebug.entitlements",
                 "ImpressCalibrationWidgets/ImpressCalibrationWidgets.entitlements"):
    entitlements = plistlib.loads((ROOT / relative).read_bytes())
    assert "group.areu.impress" in entitlements.get(app_group_key, []), relative
assert "xcode-27" in workflow, "iOS 26+ Xcode SDK regression"
print(f"PRODUCT_CONTRACT_STATIC_PASS: {len(ledger_ids)} requirements, "
      f"{len(acceptance)} acceptances, {len(open_issues)} open decisions")
