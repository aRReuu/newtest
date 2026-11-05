import XCTest
import UIKit
@testable import aReuImpress_iPhone

@MainActor
final class ImpressChatPOCLocalAttachmentTests: XCTestCase {
    func testImageOnlyComposerCanRequestConsentButEmptySelectionCannot() {
        typealias Consent = ImpressChatEphemeralFileConsent
        XCTAssertFalse(Consent.mayBeginSend(input: "   ",
            hasTextAttachment: false, hasImageAttachment: false))
        XCTAssertTrue(Consent.mayBeginSend(input: "",
            hasTextAttachment: false, hasImageAttachment: true))
        XCTAssertTrue(Consent.mayBeginSend(input: "",
            hasTextAttachment: true, hasImageAttachment: false))
        XCTAssertTrue(Consent.mayBeginSend(input: "plain text",
            hasTextAttachment: false, hasImageAttachment: false))
        XCTAssertFalse(Consent.mayBeginSend(input: String(repeating: "字", count: 4_001),
            hasTextAttachment: false, hasImageAttachment: true))
        XCTAssertFalse(Consent.imageOnlyHistoryReceipt.isEmpty)
        XCTAssertTrue(Consent.imageOnlyHistoryReceipt.contains("不会重复上传"))
    }

    func testThreeFrozenSystemPickerChoicesAndBoundedLocalPreview() throws {
        let owner = UIViewController()
        let coordinator = ImpressChatPOCLocalAttachments(presenting: owner)
        let menu = coordinator.pickerMenu()
        let labels = menu.children.compactMap { ($0 as? UIAction)?.title }
        XCTAssertEqual(labels, ["相册", "文件", "拍照"])
        XCTAssertNotNil(Bundle.main.object(
            forInfoDictionaryKey: "NSCameraUsageDescription"),
            "The camera picker must never launch without a declared usage string")
        var changes = 0
        coordinator.onChange = { _ in changes += 1 }
        for i in 0..<7 {
            coordinator.addSyntheticPreviewForTest("synthetic \(i)")
        }
        XCTAssertEqual(coordinator.items.count, 5)
        XCTAssertEqual(changes, 5)
        XCTAssertTrue(coordinator.items.allSatisfy { $0.approximateBytes == 100 })
        let first = try XCTUnwrap(coordinator.items.first)
        coordinator.remove(id: first.id)
        XCTAssertEqual(coordinator.items.count, 4)
        XCTAssertEqual(changes, 6)
    }

    func testComposerExposesSystemPickerButNoAutomaticTransmission() throws {
        let vc = ImpressChatPOCViewController()
        vc.loadViewIfNeeded()
        let buttons = findSubviews(in: vc.view, type: UIButton.self)
        let add = try XCTUnwrap(buttons.first {
            $0.accessibilityIdentifier == "impress.chat.poc.add"
        })
        XCTAssertEqual(add.menu?.children.count, 3)
        XCTAssertTrue(add.showsMenuAsPrimaryAction)
        let stt = try XCTUnwrap(buttons.first {
            $0.accessibilityIdentifier == "impress.chat.poc.apple-stt"
        })
        XCTAssertEqual(stt.accessibilityLabel, "Apple 语音转文字")
        XCTAssertEqual(stt.constraints.first(where: {
            $0.firstAttribute == .width && $0.constant == 44
        })?.constant, 44)
        let status = try XCTUnwrap(buttons.first {
            $0.accessibilityIdentifier == "impress.chat.poc.local-preview"
        })
        XCTAssertTrue(status.isHidden)
        vc.addSyntheticLocalMaterialForTest("QA Thumbnail")
        XCTAssertFalse(status.isHidden)
        let previews = findSubviews(in: vc.view, type: UIButton.self)
            .filter { $0.accessibilityIdentifier?.hasPrefix("impress.chat.poc.preview.") == true }
        XCTAssertEqual(previews.count, 1)
        XCTAssertTrue(previews[0].accessibilityLabel?.contains("未发送") == true)
        previews[0].sendActions(for: .touchUpInside)
        XCTAssertTrue(status.isHidden)
    }

    func testSyntheticApprovedImagesRemainTransientAndMixedFilesFailClosed() throws {
        let owner = UIViewController()
        let picker = ImpressChatPOCLocalAttachments(presenting: owner)
        picker.addSyntheticImageForTest("synthetic 1.jpg")
        picker.addSyntheticImageForTest("synthetic 2.jpg")
        let authorized = try XCTUnwrap(picker.imagePayloadsForExplicitSend())
        XCTAssertEqual(authorized.count, 2)
        XCTAssertTrue(authorized.allSatisfy {
            $0.jpeg.starts(with: [0xFF, 0xD8, 0xFF]) &&
                $0.jpeg.suffix(2).elementsEqual([0xFF, 0xD9]) &&
                $0.jpeg.count <= 400_000
        })
        picker.addSyntheticPreviewForTest("unverified.pdf")
        XCTAssertNil(picker.imagePayloadsForExplicitSend(),
            "Never silently omit a selected nonimage document from consent")
        picker.clear()
        XCTAssertTrue(picker.items.isEmpty)
        XCTAssertNil(picker.imagePayloadsForExplicitSend())
    }

    func testLatePhotoPickerDecodeIsDiscardedAfterSessionOrSendClear() throws {
        let owner = UIViewController()
        let picker = ImpressChatPOCLocalAttachments(presenting: owner)
        var states: [[String]] = []
        picker.onChange = { values in states.append(values.map(\.title)) }

        // The user leaves session A before Photos finishes decoding its image.
        let oldSessionCompletion =
            picker.deferredSyntheticPhotoCompletionForTest("private-A.jpg")
        XCTAssertTrue(picker.items.isEmpty)
        picker.clear()
        oldSessionCompletion()
        XCTAssertTrue(picker.items.isEmpty,
                      "A delayed callback may not reattach a private image to session B")
        XCTAssertEqual(states, [[]],
                       "Revoked image data must not notify the new conversation")

        // A new session can still approve its own image; the previous
        // completion must not displace or change the new selection.
        let currentSessionCompletion =
            picker.deferredSyntheticPhotoCompletionForTest("authorized-B.jpg")
        currentSessionCompletion()
        XCTAssertEqual(picker.items.map(\.title), ["authorized-B.jpg"])
        XCTAssertNotNil(picker.imagePayloadsForExplicitSend())
        oldSessionCompletion()
        XCTAssertEqual(picker.items.map(\.title), ["authorized-B.jpg"])

        // Clearing after one explicit Send also revokes an outstanding picker
        // result; it must never appear in the next unsent composer.
        let lateAfterSend =
            picker.deferredSyntheticPhotoCompletionForTest("post-send.jpg")
        picker.clear()
        lateAfterSend()
        XCTAssertTrue(picker.items.isEmpty)
        XCTAssertNil(picker.imagePayloadsForExplicitSend())
        XCTAssertEqual(states, [[], ["authorized-B.jpg"], []])
    }

    func testHistoricalUserImageApprovalIsMetadataOnlyAndBackwardCompatible() throws {
        let legacy = WCDBV3ChatMessage(role: .user, text: "Describe",
                                       status: .completed)
        let bytes = try JSONEncoder().encode(legacy)
        let old = try JSONDecoder().decode(WCDBV3ChatMessage.self, from: bytes)
        XCTAssertNil(old.approvedImages)
        let uploaded = WCDBV3ChatMessage(role: .user, text: "Describe",
            status: .completed, approvedImages: [
                WCDBV3ChatImageApproval(name: "sample.jpg", jpegBytes: 394)
            ])
        let json = try JSONEncoder().encode(uploaded)
        let decoded = try JSONDecoder().decode(WCDBV3ChatMessage.self, from: json)
        XCTAssertEqual(decoded.approvedImages?.first?.name, "sample.jpg")
        XCTAssertFalse(String(data: json, encoding: .utf8)?.contains("base64") ?? false,
            "WCDB image receipts may never archive the source's pixel bytes")
        let viewport = ImpressChatProductionTranscript(
            frame: CGRect(x: 0, y: 0, width: 390, height: 600))
        let root = UIViewController()
        let window = UIWindow(frame: viewport.bounds)
        window.rootViewController = root
        root.view.addSubview(viewport)
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        viewport.update([decoded])
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            viewport.layoutIfNeeded()
            return self.findSubviews(in: viewport, type: UITextView.self)
                .contains { $0.text.contains("已批准图片") &&
                    $0.text.contains("sample.jpg") }
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 10), .completed,
            "The user must see an actual approval receipt in the native transcript")
    }

    func testPickedFileCopyReadIsCompleteAndRejectsPostStatGrowth() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "impress-picker-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        func read(_ data: Data, cap: Int) throws -> Data {
            let url = root.appendingPathComponent(UUID().uuidString)
            try data.write(to: url)
            let file = try FileHandle(forReadingFrom: url)
            defer { try? file.close() }
            return try ImpressChatEphemeralTextAttachment.readBounded(
                from: file, maximumBytes: cap)
        }
        let cap = ImpressChatEphemeralTextAttachment.perFileLimit
        let exact = Data(repeating: 0x41, count: cap)
        XCTAssertEqual(try read(exact, cap: cap), exact)
        XCTAssertThrowsError(try read(Data(repeating: 0x42, count: cap + 1),
                                     cap: cap)) { error in
            XCTAssertEqual(error as? ImpressChatEphemeralTextAttachment.Rejection,
                           .oversizedFile)
        }
        XCTAssertEqual(try read(Data(repeating: 0x43, count: 63),
                                cap: 64).count, 63)
        XCTAssertThrowsError(try read(Data(repeating: 0x44, count: 65), cap: 64))
        XCTAssertEqual(try read(Data(), cap: 64), Data())

        // A Files-provider copy must be an actual regular file. A link can
        // otherwise reveal bytes outside the explicitly chosen document.
        let regular = root.appendingPathComponent("selected.md")
        try Data("SELECTED_ONLY".utf8).write(to: regular)
        XCTAssertTrue(ImpressChatEphemeralTextAttachment.isSafeCopiedFile(regular))
        let safeFile = try XCTUnwrap(
            ImpressChatEphemeralTextAttachment.openSafeCopiedFile(regular))
        XCTAssertEqual(try ImpressChatEphemeralTextAttachment.readBounded(
            from: safeFile, maximumBytes: cap), Data("SELECTED_ONLY".utf8))
        try safeFile.close()

        let alias = root.appendingPathComponent("linked.md")
        try FileManager.default.createSymbolicLink(
            at: alias, withDestinationURL: regular)
        XCTAssertFalse(ImpressChatEphemeralTextAttachment.isSafeCopiedFile(alias))
        XCTAssertNil(ImpressChatEphemeralTextAttachment.openSafeCopiedFile(alias))
        XCTAssertFalse(ImpressChatEphemeralTextAttachment.isSafeCopiedFile(root))
        XCTAssertNil(ImpressChatEphemeralTextAttachment.openSafeCopiedFile(
            root.appendingPathComponent("missing.md")))
    }

    func testOneShotTextApprovalRejectsRouteSessionBytesAndInputChanges() throws {
        typealias Attachment = ImpressChatEphemeralTextAttachment
        typealias Consent = ImpressChatEphemeralFileConsent
        let first = try Attachment.prepare(
            data: Data("PRIVATE_FIXTURE_A".utf8), filename: "note.md",
            fileExtension: "md")
        let replacement = try Attachment.prepare(
            data: Data("PRIVATE_FIXTURE_B".utf8), filename: "note.md",
            fileExtension: "md")
        let id = UUID(), sessionID = UUID(), modelID = UUID(), providerID = UUID()
        func destination(session: UUID, fingerprint: String) -> Consent.Destination {
            Consent.Destination(providerID: providerID, modelID: modelID,
                modelName: "offline", endpoint: "https://local.invalid/v1",
                wireProtocol: "responses", sessionID: session,
                routeFingerprint: Data(fingerprint.utf8))
        }
        let route = destination(session: sessionID, fingerprint: "route-A")
        let approval = try Consent.Snapshot.freeze(
            destination: route, input: "Summarize",
            previewIDs: [id], prepared: [first])
        let turn = try approval.approvedUserTurn(
            destination: route, input: "Summarize",
            previewIDs: [id], prepared: [first])
        XCTAssertTrue(turn.contains("PRIVATE_FIXTURE_A"))
        XCTAssertThrowsError(try approval.approvedUserTurn(
            destination: route, input: "changed text",
            previewIDs: [id], prepared: [first]))
        XCTAssertThrowsError(try approval.approvedUserTurn(
            destination: route, input: "Summarize",
            previewIDs: [id], prepared: [replacement]))
        XCTAssertThrowsError(try approval.approvedUserTurn(
            destination: route, input: "Summarize",
            previewIDs: [UUID()], prepared: [first]))
        XCTAssertThrowsError(try approval.approvedUserTurn(
            destination: destination(session: UUID(), fingerprint: "route-A"),
            input: "Summarize", previewIDs: [id], prepared: [first]))
        XCTAssertThrowsError(try approval.approvedUserTurn(
            destination: destination(session: sessionID, fingerprint: "route-B"),
            input: "Summarize", previewIDs: [id], prepared: [first]))
    }


    func testImageConsentRejectsRouteSessionSelectionAndImageMutation() throws {
        typealias Consent = ImpressChatEphemeralFileConsent
        let owner = UIViewController()
        let picker = ImpressChatPOCLocalAttachments(presenting: owner)
        picker.addSyntheticImageForTest("first.jpg")
        picker.addSyntheticImageForTest("second.jpg")
        let images = try XCTUnwrap(picker.imagePayloadsForExplicitSend())
        let ids = picker.items.map(\.id)
        let provider = UUID(), model = UUID(), session = UUID()
        func destination(_ providerID: UUID, _ modelID: UUID,
                         _ sessionID: UUID, _ fingerprint: String) -> Consent.Destination {
            Consent.Destination(providerID: providerID, modelID: modelID,
                modelName: "offline-mock", endpoint: "https://example.invalid/v1",
                wireProtocol: "responses", sessionID: sessionID,
                routeFingerprint: Data(fingerprint.utf8))
        }
        let route = destination(provider, model, session, "route-1")
        let approvedInput = "Summarize these selected pictures"
        let proof = try Consent.ImageSnapshot.freeze(
            destination: route, input: approvedInput,
            previewIDs: ids, images: images)
        XCTAssertEqual(try proof.approvedPayloads(
            destination: route, input: approvedInput, previewIDs: ids, images: images).count, 2)
        XCTAssertThrowsError(try proof.approvedPayloads(
            destination: route, input: "A changed typed draft",
            previewIDs: ids, images: images)) { error in
            XCTAssertEqual(error as? Consent.Rejection, .changedInput)
        }
        for changed in [
            destination(UUID(), model, session, "route-1"),
            destination(provider, UUID(), session, "route-1"),
            destination(provider, model, UUID(), "route-1"),
            destination(provider, model, session, "route-2")
        ] {
            XCTAssertThrowsError(try proof.approvedPayloads(
                destination: changed, input: approvedInput, previewIDs: ids, images: images))
        }
        XCTAssertThrowsError(try proof.approvedPayloads(
            destination: route, input: approvedInput, previewIDs: Array(ids.reversed()), images: images))
        var replaced = images
        replaced[0] = ImpressAIImagePayload(
            jpeg: images[0].jpeg + Data([0]), displayName: images[0].displayName)
        XCTAssertThrowsError(try proof.approvedPayloads(
            destination: route, input: approvedInput, previewIDs: ids, images: replaced))
        replaced[0] = ImpressAIImagePayload(
            jpeg: images[0].jpeg, displayName: "renamed.jpg")
        XCTAssertThrowsError(try proof.approvedPayloads(
            destination: route, input: approvedInput, previewIDs: ids, images: replaced))
        picker.clear()
        XCTAssertThrowsError(try proof.approvedPayloads(
            destination: route, input: approvedInput, previewIDs: picker.items.map(\.id),
            images: picker.imagePayloadsForExplicitSend() ?? []))
    }

    /// The production composer must never imply local text files stay local
    /// when the user explicitly approves a one-shot provider upload.
    func testProductionComposerDisclosesActualOneShotFileUploadRules() throws {
        let controller = ImpressAINativeChatViewController()
        controller.loadViewIfNeeded()
        controller.addLocalPreviewFixtureForTest("local-note.md")
        let hint = try XCTUnwrap(findSubviews(in: controller.view, type: UILabel.self)
            .first { $0.accessibilityIdentifier ==
                "impress.ai.chat.local-preview-not-transmitted" })
        XCTAssertFalse(hint.isHidden)
        let disclosure = try XCTUnwrap(hint.text)
        XCTAssertTrue(disclosure.contains("TXT/MD/CSV/JSON"))
        XCTAssertTrue(disclosure.contains("逐次批准"))
        XCTAssertTrue(disclosure.contains("支持的图片"))
        XCTAssertTrue(disclosure.contains("其他文件仅预览"))
    }

    /// Search must expose each matching persisted turn, including a late
    /// match in a long reply, and route selection to that exact message.
    func testProductionHistorySearchLocatesLaterMatchingTurn() throws {
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent(
            "impress-g2-chat-search-" + UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: temp) }
        let repository = try ReviewWCDBRepository(
            databasePath: temp.appendingPathComponent("fixture.sqlite").path,
            calculator: FSRS6ReviewCalculator())
        let first = WCDBV3ChatMessage(role: .user,
            text: "归档讨论入口", status: .completed)
        let earlierHit = WCDBV3ChatMessage(role: .assistant,
            text: "审稿：第一项意见", status: .completed)
        let laterHit = WCDBV3ChatMessage(role: .assistant,
            text: String(repeating: "上下文", count: 160) + "审稿：第二项意见",
            status: .completed)
        var session = WCDBV3ChatSession(sourceIdentity: "qa-history-search")
        session.sourceDisplayName = "合成来源"
        session.messages = [first, earlierHit, laterHit]
        let page = ImpressChatSessionHistoryViewController(
            sessions: [session], currentSessionID: nil, repository: repository)
        page.loadViewIfNeeded()
        let search = try XCTUnwrap(page.navigationItem.searchController)
        search.searchBar.text = "审稿"
        page.updateSearchResults(for: search)
        XCTAssertEqual(page.tableView.numberOfRows(inSection: 0), 2,
            "Both persisted replies must have separate navigable results")
        let lastRow = IndexPath(row: 1, section: 0)
        let cell = page.tableView(page.tableView, cellForRowAt: lastRow)
        XCTAssertTrue(cell.accessibilityLabel?.contains("审稿") == true,
            "A late match in long Markdown must appear in its search preview")
        var selectedID: UUID?
        page.onSelect = { id, messageID in
            XCTAssertEqual(id, session.sessionID)
            selectedID = messageID
        }
        page.tableView(page.tableView, didSelectRowAt: lastRow)
        XCTAssertEqual(selectedID, laterHit.messageID,
            "Search selection must anchor the exact later message, not session start")
        search.searchBar.text = ""
        page.updateSearchResults(for: search)
        XCTAssertEqual(page.tableView.numberOfRows(inSection: 0), 1,
            "Clearing search restores one row per local conversation")
        search.searchBar.text = "合成来源"
        page.updateSearchResults(for: search)
        XCTAssertEqual(page.tableView.numberOfRows(inSection: 0), 1,
            "Source-name queries still discover a matching conversation")
    }

    /// Selected attachments must be inspectable before one-shot consent.
    /// The exact bounded text/sanitized JPEG is shown in memory; unsupported
    /// files never impersonate a decoded document or an authorized upload.
    func testProductionLocalAttachmentCanOpenExactInMemoryPreview() throws {
        let controller = ImpressAINativeChatViewController()
        controller.loadViewIfNeeded()
        controller.addLocalPreviewFixtureForTest("private.pdf")
        let openButtons = findSubviews(in: controller.view, type: UIButton.self)
            .filter { $0.accessibilityIdentifier == "impress.ai.chat.local-preview-open" }
        XCTAssertEqual(openButtons.count, 1,
                       "A selected attachment must have an accessible preview action")
        XCTAssertTrue(openButtons[0].accessibilityLabel?.contains("private.pdf") == true)

        let picker = ImpressChatPOCLocalAttachments(presenting: UIViewController())
        picker.addSyntheticTextForTest("extract.md", text: "# 原文\n逐次确认")
        let textID = try XCTUnwrap(picker.items.first?.id)
        let textPage = try XCTUnwrap(picker.previewController(for: textID))
        let document = try XCTUnwrap(
            findSubviews(in: textPage.view, type: UITextView.self).first)
        XCTAssertEqual(document.text, "# 原文\n逐次确认")
        XCTAssertFalse(document.isEditable)
        XCTAssertEqual(document.accessibilityIdentifier,
                       "impress.ai.chat.local-preview-document")

        picker.clear()
        picker.addSyntheticImageForTest("approved.jpg")
        let imageID = try XCTUnwrap(picker.items.first?.id)
        let imagePage = try XCTUnwrap(picker.previewController(for: imageID))
        let image = try XCTUnwrap(
            findSubviews(in: imagePage.view, type: UIImageView.self).first)
        XCTAssertNotNil(image.image)
        XCTAssertEqual(image.contentMode, .scaleAspectFit)
        XCTAssertEqual(image.accessibilityIdentifier,
                       "impress.ai.chat.local-preview-image")
        picker.remove(id: imageID)
        XCTAssertNil(picker.previewController(for: imageID),
                     "Revoking a selection removes access to its in-memory preview")

        picker.addSyntheticPreviewForTest("metadata-only.pdf")
        let otherID = try XCTUnwrap(picker.items.first?.id)
        let otherPage = try XCTUnwrap(picker.previewController(for: otherID))
        let metadata = try XCTUnwrap(
            findSubviews(in: otherPage.view, type: UILabel.self).first)
        XCTAssertTrue(metadata.text?.contains("metadata-only.pdf") == true)
        XCTAssertEqual(metadata.accessibilityIdentifier,
                       "impress.ai.chat.local-preview-metadata-only")
        XCTAssertTrue(findSubviews(in: otherPage.view, type: UITextView.self).isEmpty)
    }

    private func findSubviews<T: UIView>(in root: UIView, type: T.Type) -> [T] {
        root.subviews.flatMap { view in
            ((view as? T).map { [$0] } ?? []) + findSubviews(in: view, type: type)
        }
    }
}
