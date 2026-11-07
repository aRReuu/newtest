//
//  ReviewWCDBRepositoryTests.swift
//  Staged for the iOS XCTest target; Xcode target integration pending.
//

import XCTest
import UIKit
import AVFoundation
import PhotosUI
import CoreVideo
import CryptoKit
import ImpressReviewCore
@testable import aReuImpress_iPhone

private enum ForcedSchedulingError: Error {
    case fixtureFailure


}

private struct FailingReviewCalculator: WCDBReviewCalculating {
    func next(before: ReviewScheduleSnapshot, status: ReviewCardStatus,
              submission: ReviewSubmission) throws -> WCDBCalculatedReview {
        throw ForcedSchedulingError.fixtureFailure
    }
}

final class ReviewWCDBRepositoryTests: XCTestCase {
    @MainActor private func allSubviews(_ view: UIView) -> [UIView] {
        [view] + view.subviews.flatMap { allSubviews($0) }
    }


    @MainActor
    func testOriginalCardOffersVerifiedSourceSectionWithoutReplacingFullNote() throws {
        let markdown = "# Mechanics\nNet force is mass times acceleration.\n\n" +
            "# History\nAn unrelated earlier development.\n"
        let identity = try ImVaultFileIdentity(vaultID: "qa-read-only",
            relativePath: "Notes/Mechanics.md")
        let doc = ImVaultRawDocument(identity: identity,
            sourceBytes: Data(markdown.utf8), markdown: markdown,
            digest: ImVaultDigest.sha256(Data(markdown.utf8)))
        let sections = ImpressAISectionExtractor.sections(in: markdown)
        let anchor = ImVaultDigest.sha256(Data(sections[0].text.utf8))
        let linked = ImVaultDocumentController(
            document: doc, sourceSectionDigest: anchor)
        linked.loadViewIfNeeded()
        let menu = try XCTUnwrap(linked.navigationItem.rightBarButtonItems?.last?.menu)
        let options = menu.children.compactMap { $0 as? UIAction }
        XCTAssertTrue(options.contains(where: {
            $0.title == V3L("查看核实过的来源片段")
        }))
        // An ordinary v1/v2 source always opens the normal full note without
        // claiming precise fragment localization.
        let legacy = ImVaultDocumentController(document: doc)
        legacy.loadViewIfNeeded()
        let oldMenu = try XCTUnwrap(legacy.navigationItem.rightBarButtonItems?.last?.menu)
        XCTAssertFalse(oldMenu.children.compactMap { $0 as? UIAction }.contains {
            $0.title == V3L("查看核实过的来源片段")
        })
        XCTAssertFalse(ImVaultGuardedWrite.productionWriteEnabled)
    }

    @MainActor
    func testAIQuestionMaterialRequiresExactLiveSourceBeforeHTTP() throws {
        let identity = try ImVaultFileIdentity(vaultID: "QA-Vault",
            relativePath: "Learning/Concepts.md")
        let original = "# Study\nOriginal evidence for this question.\n\n" +
            "# Practice\nAn unrelated exercise.\n"
        let bytes = Data(original.utf8)
        let digest = ImVaultDigest.sha256(bytes)
        let source = ImpressAISource(vaultID: identity.vaultID,
            relativePath: identity.relativePath, documentSHA256: digest,
            heading: "Study")
        let firstSection = try XCTUnwrap(ImpressAISectionExtractor.sections(in: original).first)
        let selected = ImpressAIExcerpt(id: firstSection.id, source: source,
            text: firstSection.text, sectionHeading: firstSection.heading)
        let verified = ImVaultRawDocument(identity: identity,
            sourceBytes: bytes, markdown: original, digest: digest)
        XCTAssertNoThrow(try ImpressAIQuestionSendGate.validate(
            source: source, excerpts: [selected], live: verified))
        // A source edited after consent must fail CLOSED: do not submit old
        // excerpts or pretend the model saw current source material.
        let changed = original.replacingOccurrences(of: "Original evidence",
            with: "Corrected evidence")
        let altered = ImVaultRawDocument(identity: identity,
            sourceBytes: Data(changed.utf8), markdown: changed,
            digest: ImVaultDigest.sha256(Data(changed.utf8)))
        XCTAssertThrowsError(try ImpressAIQuestionSendGate.validate(
            source: source, excerpts: [selected], live: altered))
        let foreign = try ImVaultFileIdentity(vaultID: "Foreign-Vault",
            relativePath: identity.relativePath)
        let foreignDocument = ImVaultRawDocument(identity: foreign,
            sourceBytes: bytes, markdown: original, digest: digest)
        XCTAssertThrowsError(try ImpressAIQuestionSendGate.validate(
            source: source, excerpts: [selected], live: foreignDocument))
        var poisoned = selected
        poisoned.text = "Text was changed after the scope was reviewed."
        XCTAssertThrowsError(try ImpressAIQuestionSendGate.validate(
            source: source, excerpts: [poisoned], live: verified))
        XCTAssertThrowsError(try ImpressAIQuestionSendGate.validate(
            source: source, excerpts: [], live: verified))
    }

    @MainActor
    func testNoteQuestionGenerationAnchorsOnlyUniqueEvidenceAndSkipsUnrelatedChanges() throws {
        let identity = try ImVaultFileIdentity(
            vaultID: "signed-test-vault", relativePath: "Courses/Mechanics.md")
        let original = "# Mechanics\nForce produces acceleration.\n\n" +
            "# Practice\nSolve F = ma and verify units.\n"
        let sections = ImpressAISectionExtractor.sections(in: original)
        XCTAssertEqual(sections.count, 2)
        let digest = ImVaultDigest.sha256(Data(original.utf8))
        let source = ImpressAISource(vaultID: identity.vaultID,
            relativePath: identity.relativePath,
            documentSHA256: digest, heading: "Mechanics")
        let excerpts = sections.map {
            ImpressAIExcerpt(id: $0.id, source: source,
                text: $0.text, sectionHeading: $0.heading)
        }
        let key = try ImpressAINoteCardLink.sourceKey(
            identity: identity, documentDigest: digest,
            candidateEvidenceIDs: [sections[0].id],
            excerpts: excerpts, sourceMarkdown: original)
        XCTAssertTrue(key.hasPrefix("obsidian+v3:"))
        XCTAssertEqual(try ImpressBatchSourceKey.decode(key), identity)
        XCTAssertEqual(try ImpressBatchSourceKey.documentDigest(for: key), digest)
        XCTAssertEqual(try ImpressBatchSourceKey.sectionDigest(for: key),
                       ImVaultDigest.sha256(Data(sections[0].text.utf8)))
        XCTAssertTrue(ImpressAINoteCardLink.verifiedSectionUnchanged(
            sourceKey: key, currentMarkdown: original))
        let unrelated = original.replacingOccurrences(
            of: "Solve F = ma and verify units.",
            with: "Solve F = ma and explain unit dimensions.")
        XCTAssertNotEqual(ImVaultDigest.sha256(Data(unrelated.utf8)), digest)
        XCTAssertTrue(ImpressAINoteCardLink.verifiedSectionUnchanged(
            sourceKey: key, currentMarkdown: unrelated),
            "Another chapter's change must not create this card's review debt")
        let changedRelated = original.replacingOccurrences(
            of: "Force produces acceleration.",
            with: "Net external force changes momentum.")
        XCTAssertFalse(ImpressAINoteCardLink.verifiedSectionUnchanged(
            sourceKey: key, currentMarkdown: changedRelated))

        let multiple = try ImpressAINoteCardLink.sourceKey(
            identity: identity, documentDigest: digest,
            candidateEvidenceIDs: sections.map(\.id),
            excerpts: excerpts, sourceMarkdown: original)
        XCTAssertTrue(multiple.hasPrefix("obsidian+v2:"))
        XCTAssertNil(try ImpressBatchSourceKey.sectionDigest(for: multiple))
        let missing = try ImpressAINoteCardLink.sourceKey(
            identity: identity, documentDigest: digest,
            candidateEvidenceIDs: ["missing-section"],
            excerpts: excerpts, sourceMarkdown: original)
        XCTAssertNil(try ImpressBatchSourceKey.sectionDigest(for: missing))
        let duplicates = "# Same\nRepeated note.\n\n# Same\nRepeated note.\n"
        let duplicateParts = ImpressAISectionExtractor.sections(in: duplicates)
        XCTAssertEqual(duplicateParts.count, 2)
        let ambiguousSource = ImpressAISource(vaultID: identity.vaultID,
            relativePath: identity.relativePath,
            documentSHA256: ImVaultDigest.sha256(Data(duplicates.utf8)), heading: "Same")
        let ambiguousExcerpts = duplicateParts.map {
            ImpressAIExcerpt(id: $0.id, source: ambiguousSource,
                text: $0.text, sectionHeading: $0.heading)
        }
        let fallback = try ImpressAINoteCardLink.sourceKey(
            identity: identity, documentDigest: ambiguousSource.documentSHA256,
            candidateEvidenceIDs: [duplicateParts[0].id],
            excerpts: ambiguousExcerpts, sourceMarkdown: duplicates)
        XCTAssertNil(try ImpressBatchSourceKey.sectionDigest(for: fallback),
                     "Duplicate identical sections cannot be mapped by guesswork")
    }

    @MainActor
    func testVaultSectionLinksRemainScopedToOriginalCardAndExactVault() async throws {
        let id = UUID(), otherID = UUID()
        let vault = try ImVaultFileIdentity(vaultID: "vault-A", relativePath: "Study.md")
        let different = try ImVaultFileIdentity(vaultID: "vault-B", relativePath: "Study.md")
        let markdown = "# Topic\nOriginal learning content\n"
        let sha = ImVaultDigest.sha256(Data(markdown.utf8))
        let annotated = try ImpressBatchSourceKey.encode(
            vault, documentDigest: sha, anchoredSection: markdown.trimmingCharacters(in: .whitespacesAndNewlines))
        let other = try ImpressBatchSourceKey.encode(
            different, documentDigest: sha, anchoredSection: markdown.trimmingCharacters(in: .whitespacesAndNewlines))
        let repo = try ReviewWCDBRepository(
            databasePath: temporaryPath(), calculator: FSRS6ReviewCalculator())
        let calc = FSRS6ReviewCalculator(), date = Date(timeIntervalSince1970: 1_726_000_000)
        for card in [
            WCDBV3CardInput(cardID: id, question: "Same heading in A?",
                answerText: "Yes", sourceNotePath: annotated),
            WCDBV3CardInput(cardID: otherID, question: "Same heading in B?",
                answerText: "Yes", sourceNotePath: other)
        ] {
            try await repo.insertNewCard(card,
                initial: try calc.newCardSnapshot(id: card.cardID, now: date), now: date)
        }
        let owned = try await repo.listRelatedCards(for: vault)
        XCTAssertEqual(owned.map(\.cardID), [id])
        let external = try await repo.listRelatedCards(for: different)
        XCTAssertEqual(external.map(\.cardID), [otherID])
        let versions = try await repo.reviewHistory(for: id)
        XCTAssertTrue(versions.isEmpty)
    }



    @MainActor
    func testExplicitQAUndoRestoresExactBOMCRLFBytesAndBlocksLaterConflict() throws {
        let root = try createRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let original = Data([0xEF, 0xBB, 0xBF]) +
            Data("# Original\r\n[[linked-note]]\r\n> [!NOTE] Keep\r\n".utf8)
        let file = try put("# temporary", root: root)
        try original.write(to: file, options: .atomic)
        let identity = try ImVaultFileIdentity(vaultID: UUID().uuidString,
            relativePath: "Notes/Topic.md")
        let read = try ImVaultReadSync.load(root: root, identity: identity)
        var draft = try ImVaultDraft(identity: identity, baseText: read.markdown,
                                     baseRawData: read.sourceBytes)
        try draft.update("# Revised\n[[linked-note]]\n> [!NOTE] Keep\n")
        let expectedApplied = ImVaultDigest.sha256(draft.proposedBytes)
        let forward = try ImVaultGuardedWrite.commitFixture(root: root,
            draft: draft, userConfirmedDiff: true)
        guard case .written = forward else {
            XCTFail("Expected a coordinated fixture write")
            return
        }
        XCTAssertNotEqual(try Data(contentsOf: file), original)
        let inverse = try ImpressDuplexUndoGate.inverseDraft(draft,
            expectedBaseDigest: draft.baseDigest,
            expectedAppliedDigest: expectedApplied)
        XCTAssertEqual(inverse.proposedBytes, original)
        XCTAssertEqual(inverse.decision(against: try Data(contentsOf: file)), .safeToWrite)
        let undone = try ImVaultGuardedWrite.commitFixture(root: root,
            draft: inverse, userConfirmedDiff: true)
        guard case .written = undone else {
            XCTFail("Expected the user-confirmed inverse to write one time")
            return
        }
        XCTAssertEqual(try Data(contentsOf: file), original)
        let retry = try ImVaultGuardedWrite.commitFixture(root: root,
            draft: inverse, userConfirmedDiff: true)
        guard case .alreadyApplied = retry else {
            XCTFail("A resumed inverse must be idempotent")
            return
        }
        try Data("# Another editor modified the original".utf8).write(
            to: file, options: .atomic)
        XCTAssertThrowsError(try ImVaultGuardedWrite.commitFixture(
            root: root, draft: inverse, userConfirmedDiff: true))
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8),
                       "# Another editor modified the original")
        XCTAssertFalse(ImVaultGuardedWrite.productionWriteEnabled)
    }

    /// F08: stale inverse confirmation must fail BEFORE setting .undoing.
    /// The coordinated writer retains its second CAS for the post-preflight race.
    @MainActor
    func testF08NewerNoteApprovalInvalidatesOldInversePreflight() throws {
        let root = try createRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let id = try ImVaultFileIdentity(vaultID: UUID().uuidString,
            relativePath: "Notes/OldUndo.md")
        let original = Data([0xEF, 0xBB, 0xBF]) +
            Data("# Origin\r\n[[Safe]]\r\n".utf8)
        let file = try put("# placeholder", root: root, path: id.relativePath)
        try original.write(to: file, options: .atomic)
        let source = try ImVaultReadSync.load(root: root, identity: id)
        var first = try ImVaultDraft(identity: id, baseText: source.markdown,
            baseRawData: source.sourceBytes)
        try first.update("# Origin\nFirst approved\n[[Safe]]\n")
        guard case .written = try ImVaultGuardedWrite.commitFixture(
            root: root, draft: first, userConfirmedDiff: true) else {
            XCTFail("First approval must write"); return
        }
        let inverse = try ImpressDuplexUndoGate.inverseDraft(first,
            expectedBaseDigest: first.baseDigest,
            expectedAppliedDigest: ImVaultDigest.sha256(first.proposedBytes))
        try ImpressDuplexUndoGate.requireFreshNotePreflight(inverse,
            identity: id, bytes: try Data(contentsOf: file))
        let firstApplied = try ImVaultReadSync.load(root: root, identity: id)
        var second = try ImVaultDraft(identity: id, baseText: firstApplied.markdown,
            baseRawData: firstApplied.sourceBytes)
        try second.update("# Origin\nSecond legitimate approval\n[[Safe]]\n")
        guard case .written = try ImVaultGuardedWrite.commitFixture(
            root: root, draft: second, userConfirmedDiff: true) else {
            XCTFail("Second approval must write"); return
        }
        XCTAssertThrowsError(try ImpressDuplexUndoGate.requireFreshNotePreflight(
            inverse, identity: id, bytes: try Data(contentsOf: file)),
            "Obsolete preview may not create a durable .undoing intent")
        XCTAssertEqual(try Data(contentsOf: file), second.proposedBytes)
        XCTAssertThrowsError(try ImpressDuplexUndoGate.requireFreshNotePreflight(
            inverse, identity: try ImVaultFileIdentity(
                vaultID: UUID().uuidString, relativePath: id.relativePath),
            bytes: first.proposedBytes), "Same-title cross-Vault is not the source")
        XCTAssertFalse(ImVaultGuardedWrite.productionWriteEnabled)
    }

    @MainActor
    func testF08LaterCardVersionInvalidatesOldInversePreflight() async throws {
        let calculator = FSRS6ReviewCalculator()
        let repo = try ReviewWCDBRepository(databasePath: temporaryPath(),
            calculator: calculator)
        let id = UUID()
        let now = Date(timeIntervalSince1970: 1_726_000_000)
        try await repo.insertNewCard(
            WCDBV3CardInput(cardID: id, question: "Original", answerText: "A"),
            initial: try calculator.newCardSnapshot(id: id, now: now), now: now)
        let firstQueueItems = try await repo.fetchQueueCandidates()
        let firstQueue = try XCTUnwrap(firstQueueItems.first(where: { $0.cardID == id }))
        try await repo.updateManagedCard(
            WCDBV3CardInput(cardID: id, question: "Approved", answerText: "B"),
            expectedRevision: firstQueue.revision, expectedContentRevision: 0,
            origin: .approvedAI)
        let approvedValue = try await repo.content(for: id)
        let approved = try XCTUnwrap(approvedValue)
        try ImpressDuplexUndoGate.requireFreshCardPreflight(
            expectedContentRevision: 1, currentContentRevision: approved.contentRevision,
            appliedQuestion: "Approved", appliedAnswer: "B",
            originalQuestion: "Original", originalAnswer: "A",
            currentQuestion: approved.question, currentAnswer: approved.answerText)
        let nextQueueItems = try await repo.fetchQueueCandidates()
        let nextQueue = try XCTUnwrap(nextQueueItems.first(where: { $0.cardID == id }))
        try await repo.updateManagedCard(
            WCDBV3CardInput(cardID: id, question: "Later legal edit", answerText: "C"),
            expectedRevision: nextQueue.revision, expectedContentRevision: 1,
            origin: .manual)
        let laterValue = try await repo.content(for: id)
        let later = try XCTUnwrap(laterValue)
        XCTAssertThrowsError(try ImpressDuplexUndoGate.requireFreshCardPreflight(
            expectedContentRevision: 1, currentContentRevision: later.contentRevision,
            appliedQuestion: "Approved", appliedAnswer: "B",
            originalQuestion: "Original", originalAnswer: "A",
            currentQuestion: later.question, currentAnswer: later.answerText))
        XCTAssertEqual(later.question, "Later legal edit")
        XCTAssertEqual(later.contentRevision, 2)
        let reviewEvents = try await repo.reviewHistory(for: id)
        XCTAssertTrue(reviewEvents.isEmpty)
    }

    @MainActor
    func testManualCardUndoCreatesNewContentVersionWithoutRescoring() async throws {
        let calculator = FSRS6ReviewCalculator()
        let repo = try ReviewWCDBRepository(databasePath: temporaryPath(),
                                             calculator: calculator)
        let id = UUID(), now = Date(timeIntervalSince1970: 1_726_000_000)
        let initial = WCDBV3CardInput(cardID: id, question: "Prior question",
                                      answerText: "Prior answer")
        try await repo.insertNewCard(initial,
            initial: try calculator.newCardSnapshot(id: id, now: now), now: now)
        let beforeItems = try await repo.fetchQueueCandidates()
        let before = try XCTUnwrap(beforeItems.first(where: { $0.cardID == id }))
        try await repo.updateManagedCard(WCDBV3CardInput(cardID: id,
            question: "Revised question", answerText: "Revised answer"),
            expectedRevision: before.revision, expectedContentRevision: 0,
            origin: .approvedAI)
        let revisedValue = try await repo.content(for: id)
        let revised = try XCTUnwrap(revisedValue)
        XCTAssertEqual(revised.contentRevision, 1)
        XCTAssertEqual(ImDuplexCardVersionGate.decide(
            expectedContentRevision: 1, currentContentRevision: revised.contentRevision,
            baseQuestion: "Revised question", baseAnswer: "Revised answer",
            proposedQuestion: "Prior question", proposedAnswer: "Prior answer",
            currentQuestion: revised.question, currentAnswer: revised.answerText), .safeToWrite)
        let queueItems = try await repo.fetchQueueCandidates()
        let currentQueue = try XCTUnwrap(queueItems.first(where: { $0.cardID == id }))
        try await repo.updateManagedCard(WCDBV3CardInput(cardID: id,
            question: "Prior question", answerText: "Prior answer"),
            expectedRevision: currentQueue.revision,
            expectedContentRevision: revised.contentRevision, origin: .restored)
        let finalValue = try await repo.content(for: id)
        let restored = try XCTUnwrap(finalValue)
        let afterCandidates = try await repo.fetchQueueCandidates()
        let after = try XCTUnwrap(afterCandidates.first(where: { $0.cardID == id }))
        XCTAssertEqual(restored.cardID, id)
        XCTAssertEqual(restored.question, "Prior question")
        XCTAssertEqual(restored.answerText, "Prior answer")
        XCTAssertEqual(restored.contentRevision, 2)
        XCTAssertEqual(after.revision, before.revision)
        XCTAssertEqual(after.dueAt, before.dueAt)
        let versions = try await repo.contentHistory(for: id)
        XCTAssertEqual(versions.map(\.contentRevision), [0, 1, 2])
        XCTAssertEqual(versions.last?.origin, .restored)
        let reviewEvents = try await repo.reviewHistory(for: id)
        XCTAssertTrue(reviewEvents.isEmpty)
    }

    @MainActor
    func testSafeUndoReviewShowsFullScrollContentAndNeedsExplicitConfirmation() throws {
        let long = Array(repeating: "Unmodified source remains readable", count: 200)
            .joined(separator: "\n")
        let page = ImpressDuplexUndoReviewController(content: long) {
            .success("only after explicit confirmation")
        }
        page.loadViewIfNeeded()
        let body = try XCTUnwrap(page.view.subviews.compactMap { $0 as? UITextView }.first)
        XCTAssertTrue(body.text.hasSuffix("Unmodified source remains readable"))
        XCTAssertFalse(body.isEditable)
        XCTAssertTrue(body.isSelectable)
        let button = try XCTUnwrap(page.view.subviews.compactMap { $0 as? UIButton }.first)
        XCTAssertEqual(button.accessibilityIdentifier, "impress.duplex.undo.confirm")
    }

    /// F11: missing/corrupt private recovery snapshots must never be
    /// reconstructed from public Chat prose or an incomplete WCDB proposal.
    @MainActor
    func testF11MissingApprovedDraftDisablesNoteCommitFromApprovalUI() throws {
        let identity = try ImVaultFileIdentity(vaultID: UUID().uuidString,
            relativePath: "Missing/Untrusted.md")
        let proposal = WCDBV3DuplexProposal(sourceMessageID: UUID(),
            noteIdentity: identity,
            noteBaseDigest: String(repeating: "a", count: 64),
            noteEditedDigest: String(repeating: "b", count: 64),
            cardID: nil, cardReviewRevision: nil, cardContentRevision: nil,
            cardBaseQuestion: nil, cardBaseAnswer: nil,
            cardEditedQuestion: nil, cardEditedAnswer: nil,
            state: ImDuplexApprovalState(noteSelected: true, cardSelected: false))
        let repo = try ReviewWCDBRepository(databasePath: temporaryPath(),
            calculator: FSRS6ReviewCalculator())
        let page = ImpressDuplexApprovalController(repository: repo, proposal: proposal) {
            _ in XCTFail("Missing ApprovedDraft must not persist an applied proposal")
            return false
        }
        page.loadViewIfNeeded()
        let preview = try XCTUnwrap(page.view.subviews.compactMap {
            $0 as? UITextView
        }.first(where: { $0.accessibilityIdentifier == "impress.duplex.full-diff" }))
        XCTAssertTrue(preview.text.contains("草稿变更或不存在"))
        let confirm = try XCTUnwrap(page.view.subviews.compactMap {
            $0 as? UIButton
        }.first(where: { $0.accessibilityIdentifier == "impress.duplex.confirm" }))
        XCTAssertFalse(confirm.isEnabled)
        let noteToggle = try XCTUnwrap(allSubviews(page.view)
            .compactMap { $0 as? UISwitch }
            .first(where: { $0.accessibilityIdentifier == "impress.duplex.select-note" }))
        XCTAssertFalse(noteToggle.isEnabled,
            "Missing approved source bytes must not expose an enabled note target")
        XCTAssertNil(try ImVaultPrivateStore.approvedDraft(identity: identity,
            baseDigest: proposal.noteBaseDigest,
            editedDigest: proposal.noteEditedDigest))
        XCTAssertFalse(ImVaultGuardedWrite.productionWriteEnabled)
    }

    /// F05 first-tap gate: a rapid second tap must not enqueue a second
    /// authorization sheet or call the durable proposal writer. The actual
    /// card CAS and FSRS isolation remain guarded by repository tests.
    @MainActor
    func testF05RapidConfirmationGatesSecondConsentBeforeAnyWrite() throws {
        let repo = try ReviewWCDBRepository(databasePath: temporaryPath(),
            calculator: FSRS6ReviewCalculator())
        let proposal = WCDBV3DuplexProposal(
            sourceMessageID: UUID(), noteIdentity: nil,
            noteBaseDigest: nil, noteEditedDigest: nil,
            cardID: UUID(), cardReviewRevision: 0, cardContentRevision: 0,
            cardBaseQuestion: "Before", cardBaseAnswer: "Original",
            cardEditedQuestion: "After", cardEditedAnswer: "Reviewed",
            state: ImDuplexApprovalState(noteSelected: false, cardSelected: true))
        let page = ImpressDuplexApprovalController(
            repository: repo, proposal: proposal, saveProposal: { _ in
                XCTFail("No persistent mutation before final human confirmation")
                return false
            })
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.rootViewController = UINavigationController(rootViewController: page)
        window.makeKeyAndVisible()
        defer {
            page.dismiss(animated: false)
            window.isHidden = true
        }
        page.loadViewIfNeeded()
        let confirm = try XCTUnwrap(allSubviews(page.view).compactMap {
            $0 as? UIButton
        }.first(where: { $0.accessibilityIdentifier == "impress.duplex.confirm" }))
        XCTAssertTrue(confirm.isEnabled)
        confirm.sendActions(for: .touchUpInside)
        XCTAssertFalse(confirm.isEnabled,
            "The first consent request must immediately gate all duplicate taps")
        let firstSheet = try XCTUnwrap(page.presentedViewController as? UIAlertController)
        XCTAssertEqual(firstSheet.title, V3L("确认这两个目标的所选修改？"))
        confirm.sendActions(for: .touchUpInside)
        XCTAssertFalse(confirm.isEnabled)
        XCTAssertTrue(page.presentedViewController === firstSheet,
            "A second tap must never replace or duplicate pending consent")
        XCTAssertEqual(firstSheet.actions.filter {
            $0.title == V3L("确认执行")
        }.count, 1)
        XCTAssertFalse(ImVaultGuardedWrite.productionWriteEnabled)
    }

    @MainActor
    func testF06InterruptedApprovalBlocksDiscardAndForwardConfirmation() throws {
        let repo = try ReviewWCDBRepository(databasePath: temporaryPath(),
            calculator: FSRS6ReviewCalculator())
        let cardID = UUID()
        let proposal = WCDBV3DuplexProposal(
            sourceMessageID: nil, noteIdentity: nil,
            noteBaseDigest: nil, noteEditedDigest: nil,
            cardID: cardID, cardReviewRevision: 0, cardContentRevision: 0,
            cardBaseQuestion: "Original", cardBaseAnswer: "Before",
            cardEditedQuestion: "Changed", cardEditedAnswer: "After",
            state: ImDuplexApprovalState(noteSelected: false,
                cardSelected: true, noteStatus: .pending, cardStatus: .applying))
        let controller = ImpressDuplexApprovalController(
            repository: repo, proposal: proposal, saveProposal: { _ in
                XCTFail("An interrupted proposal must not auto-persist")
                return false
            })
        controller.loadViewIfNeeded()
        func descendants(_ root: UIView) -> [UIView] {
            [root] + root.subviews.flatMap { descendants($0) }
        }
        let confirm = try XCTUnwrap(descendants(controller.view).compactMap {
            $0 as? UIButton
        }.first(where: { $0.accessibilityIdentifier == "impress.duplex.confirm" }))
        XCTAssertFalse(confirm.isEnabled)
        let discard = try XCTUnwrap(controller.navigationItem.rightBarButtonItems?.first {
            $0.title == V3L("放弃未完成项")
        })
        XCTAssertFalse(discard.isEnabled)
        let reconciliation = try XCTUnwrap(controller.navigationItem.rightBarButtonItems?.first {
            $0.accessibilityIdentifier == "impress.duplex.reconcile-interrupted"
        })
        XCTAssertTrue(reconciliation.isEnabled)
        XCTAssertFalse(ImVaultGuardedWrite.productionWriteEnabled)
    }

    /// A deliberate inverse should never offer two overlapping consent
    /// sheets even if the same accessible control fires twice in one run loop.
    @MainActor
    func testF05RapidUndoConsentIsSingleAndHasNoPrematureSideEffects() throws {
        let page = ImpressDuplexUndoReviewController(
            content: "Synthetic cardID: fixed\nSource SHA-256: reviewed") {
                XCTFail("An inverse requires a separate final user confirmation")
                return .failure(WCDBV3ChatStorageError.conflict)
            }
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.rootViewController = UINavigationController(rootViewController: page)
        window.makeKeyAndVisible()
        defer {
            page.dismiss(animated: false)
            window.isHidden = true
        }
        page.loadViewIfNeeded()
        let button = try XCTUnwrap(allSubviews(page.view).compactMap {
            $0 as? UIButton
        }.first(where: { $0.accessibilityIdentifier == "impress.duplex.undo.confirm" }))
        XCTAssertTrue(button.isEnabled)
        button.sendActions(for: .touchUpInside)
        XCTAssertFalse(button.isEnabled,
            "The inverse review must disable a second consent immediately")
        let single = try XCTUnwrap(page.presentedViewController as? UIAlertController)
        XCTAssertEqual(single.title, V3L("确认撤销这个目标？"))
        button.sendActions(for: .touchUpInside)
        XCTAssertTrue(page.presentedViewController === single,
            "The first and only inverse consent must remain current")
        XCTAssertEqual(single.actions.filter {
            $0.title == V3L("确认撤销")
        }.count, 1)
        XCTAssertFalse(ImVaultGuardedWrite.productionWriteEnabled)
    }


    /// F01: a stale original-card CAS must never be re-approved from the
    /// historical proposal. Recover with a fresh source/content review.
    @MainActor
    func testF01ConflictingCardCannotBeConfirmedAgainFromStaleApprovalUI() throws {
        let repo = try ReviewWCDBRepository(databasePath: temporaryPath(),
            calculator: FSRS6ReviewCalculator())
        let proposal = WCDBV3DuplexProposal(
            sourceMessageID: UUID(), noteIdentity: nil,
            noteBaseDigest: nil, noteEditedDigest: nil,
            cardID: UUID(), cardReviewRevision: 0, cardContentRevision: 0,
            cardBaseQuestion: "Old", cardBaseAnswer: "Prior",
            cardEditedQuestion: "Outdated AI edit", cardEditedAnswer: "Stale",
            state: ImDuplexApprovalState(noteSelected: false, cardSelected: true,
                cardStatus: .conflict))
        let page = ImpressDuplexApprovalController(repository: repo,
            proposal: proposal, saveProposal: { _ in
                XCTFail("Conflicted target requires fresh review")
                return false
            })
        page.loadViewIfNeeded()
        let card = try XCTUnwrap(allSubviews(page.view)
            .compactMap { $0 as? UISwitch }
            .first { $0.accessibilityIdentifier == "impress.duplex.select-card" })
        XCTAssertTrue(card.isOn, "Keep the historical selection visible")
        XCTAssertFalse(card.isEnabled, "Expired card consent is not a retry")
        let confirm = try XCTUnwrap(allSubviews(page.view)
            .compactMap { $0 as? UIButton }
            .first { $0.accessibilityIdentifier == "impress.duplex.confirm" })
        XCTAssertFalse(confirm.isEnabled)
        confirm.sendActions(for: .touchUpInside)
        XCTAssertNil(page.presentedViewController)
        let diff = try XCTUnwrap(allSubviews(page.view)
            .compactMap { $0 as? UITextView }
            .first { $0.accessibilityIdentifier == "impress.duplex.full-diff" })
        XCTAssertTrue(diff.text.contains("重新核查并创建新提案"))
        XCTAssertFalse(ImVaultGuardedWrite.productionWriteEnabled)
    }

    /// F06 inverse crash window: a visible controller must not let a user
    /// accidentally replay an in-flight inverse, erase its audit status or
    /// confirm a new forward write. A read-only reconciliation remains available.
    @MainActor
    func testF06InterruptedUndoLocksReplayAndOffersReadOnlyRecovery() throws {
        let repo = try ReviewWCDBRepository(databasePath: temporaryPath(),
            calculator: FSRS6ReviewCalculator())
        let proposal = WCDBV3DuplexProposal(
            sourceMessageID: UUID(), noteIdentity: nil,
            noteBaseDigest: nil, noteEditedDigest: nil,
            cardID: UUID(), cardReviewRevision: 0, cardContentRevision: 0,
            cardBaseQuestion: "Original", cardBaseAnswer: "Answer",
            cardEditedQuestion: "Approved", cardEditedAnswer: "Updated",
            state: ImDuplexApprovalState(noteSelected: false,
                cardSelected: true, cardStatus: .undoing))
        let controller = ImpressDuplexApprovalController(
            repository: repo, proposal: proposal, saveProposal: { _ in
                XCTFail("An unverified interrupted inverse must not auto-save")
                return false
            })
        controller.loadViewIfNeeded()
        func descendants(_ view: UIView) -> [UIView] {
            [view] + view.subviews.flatMap { descendants($0) }
        }
        let confirm = try XCTUnwrap(descendants(controller.view).compactMap {
            $0 as? UIButton
        }.first(where: { $0.accessibilityIdentifier == "impress.duplex.confirm" }))
        XCTAssertFalse(confirm.isEnabled)
        let discard = try XCTUnwrap(controller.navigationItem.rightBarButtonItems?.first {
            $0.title == V3L("放弃未完成项")
        })
        XCTAssertFalse(discard.isEnabled)
        let undo = try XCTUnwrap(controller.navigationItem.rightBarButtonItems?.first {
            $0.title == V3L("安全撤销")
        })
        XCTAssertFalse(undo.isEnabled)
        let reconcile = try XCTUnwrap(controller.navigationItem.rightBarButtonItems?.first {
            $0.accessibilityIdentifier == "impress.duplex.reconcile-interrupted"
        })
        XCTAssertTrue(reconcile.isEnabled)
        let diff = try XCTUnwrap(descendants(controller.view).compactMap {
            $0 as? UITextView
        }.first(where: { $0.accessibilityIdentifier == "impress.duplex.full-diff" }))
        XCTAssertTrue(diff.text.contains("撤销"))
        XCTAssertFalse(ImVaultGuardedWrite.productionWriteEnabled)
    }

    /// F06: after a duplex operation partly applies, an unresolved inverse
    /// on one target must freeze NEW inverse work even when the other target
    /// is independently applied. Read-only reconciliation remains available.
    @MainActor
    func testF06MixedTargetInterruptedUndoLocksOtherAppliedTarget() throws {
        let repo = try ReviewWCDBRepository(databasePath: temporaryPath(),
            calculator: FSRS6ReviewCalculator())
        let identity = try ImVaultFileIdentity(vaultID: UUID().uuidString,
            relativePath: "Notes/Interrupted.md")
        for interruptedNote in [true, false] {
            let proposal = WCDBV3DuplexProposal(
                sourceMessageID: UUID(), noteIdentity: identity,
                noteBaseDigest: String(repeating: "a", count: 64),
                noteEditedDigest: String(repeating: "b", count: 64),
                cardID: UUID(), cardReviewRevision: 0, cardContentRevision: 0,
                cardBaseQuestion: "Original", cardBaseAnswer: "Answer",
                cardEditedQuestion: "Approved", cardEditedAnswer: "Updated",
                state: ImDuplexApprovalState(noteSelected: true,
                    cardSelected: true,
                    noteStatus: interruptedNote ? .undoing : .applied,
                    cardStatus: interruptedNote ? .applied : .undoing))
            let page = ImpressDuplexApprovalController(
                repository: repo, proposal: proposal, saveProposal: { _ in
                    XCTFail("An unresolved F06 transaction cannot initiate a new write")
                    return false
                })
            page.loadViewIfNeeded()
            let items = try XCTUnwrap(page.navigationItem.rightBarButtonItems)
            let undo = try XCTUnwrap(items.first {
                $0.title == V3L("安全撤销")
            })
            XCTAssertFalse(undo.isEnabled,
                "An interrupted inverse on one target must lock the other applied target")
            let reconcile = try XCTUnwrap(items.first {
                $0.accessibilityIdentifier == "impress.duplex.reconcile-interrupted"
            })
            XCTAssertTrue(reconcile.isEnabled,
                "Only read-only F06 reconciliation may proceed until the intent resolves")
            let discard = try XCTUnwrap(items.first {
                $0.title == V3L("放弃未完成项")
            })
            XCTAssertFalse(discard.isEnabled)
            let confirm = try XCTUnwrap(allSubviews(page.view).compactMap {
                $0 as? UIButton
            }.first { $0.accessibilityIdentifier == "impress.duplex.confirm" })
            XCTAssertFalse(confirm.isEnabled)
            XCTAssertNil(page.presentedViewController)
        }
        XCTAssertFalse(ImVaultGuardedWrite.productionWriteEnabled)
    }

    /// The card WCDB inverse is already committed when the process dies, but
    /// the Chat receipt is still .undoing. Reopening must compare the second
    /// CONTENT revision (not an independent FSRS schedule revision), record
    /// the original card's recovered state, and never write a duplicate version.
    @MainActor
    func testF06InverseCardCommittedBeforeReceiptColdStartReadback() async throws {
        let path = temporaryPath()
        let calculator = FSRS6ReviewCalculator()
        let repo = try ReviewWCDBRepository(databasePath: path, calculator: calculator)
        let id = UUID(), now = Date(timeIntervalSince1970: 1_726_000_000)
        try await repo.insertNewCard(WCDBV3CardInput(cardID: id,
            question: "Original", answerText: "A"),
            initial: try calculator.newCardSnapshot(id: id, now: now), now: now)
        let queue0 = try await repo.fetchQueueCandidates()
        let first = try XCTUnwrap(queue0.first { $0.cardID == id })
        try await repo.updateManagedCard(WCDBV3CardInput(cardID: id,
            question: "AI revision", answerText: "B"),
            expectedRevision: first.revision, expectedContentRevision: 0,
            origin: .approvedAI)
        let source = "card:" + id.uuidString
        var session = WCDBV3ChatSession(sourceIdentity: source)
        session.pendingDuplex = WCDBV3DuplexProposal(sourceMessageID: UUID(),
            noteIdentity: nil, noteBaseDigest: nil, noteEditedDigest: nil,
            cardID: id, cardReviewRevision: first.revision, cardContentRevision: 0,
            cardBaseQuestion: "Original", cardBaseAnswer: "A",
            cardEditedQuestion: "AI revision", cardEditedAnswer: "B",
            state: ImDuplexApprovalState(noteSelected: false, cardSelected: true,
                cardStatus: .undoing))
        try await repo.saveChatSession(session, expectedRevision: nil)
        let queue1 = try await repo.fetchQueueCandidates()
        let current = try XCTUnwrap(queue1.first { $0.cardID == id })
        try await repo.updateManagedCard(WCDBV3CardInput(cardID: id,
            question: "Original", answerText: "A"),
            expectedRevision: current.revision, expectedContentRevision: 1,
            origin: .restored)

        let coldRepo = try ReviewWCDBRepository(databasePath: path,
            calculator: calculator)
        let loaded = try await coldRepo.chatSessions(for: source)
        var reopened = try XCTUnwrap(loaded.first)
        var proposal = try XCTUnwrap(reopened.pendingDuplex)
        XCTAssertEqual(proposal.state.cardStatus, .undoing)
        XCTAssertFalse(proposal.state.completed)
        let readCard = try await coldRepo.content(for: id)
        let card = try XCTUnwrap(readCard)
        let verified = ImDuplexInterruptedRecovery.cardUndoStatus(
            currentContentRevision: card.contentRevision,
            expectedBaseContentRevision: 0,
            originalQuestion: "Original", originalAnswer: "A",
            approvedQuestion: "AI revision", approvedAnswer: "B",
            currentQuestion: card.question, currentAnswer: card.answerText)
        XCTAssertEqual(verified, .reverted)
        proposal.state.cardStatus = try XCTUnwrap(verified)
        proposal.cardReceipt = "F06 restored content version verified without replay"
        reopened.pendingDuplex = proposal
        let prevRevision = reopened.revision
        reopened.revision += 1
        reopened.updatedAt = Date()
        try await coldRepo.saveChatSession(reopened, expectedRevision: prevRevision)
        let finalSession = try await coldRepo.chatSessions(for: source)
        XCTAssertEqual(finalSession.first?.pendingDuplex?.state.cardStatus, .reverted)
        XCTAssertEqual(finalSession.first?.pendingDuplex?.cardReceipt,
                       "F06 restored content version verified without replay")
        let versions = try await coldRepo.contentHistory(for: id)
        XCTAssertEqual(versions.map(\.contentRevision), [0, 1, 2])
        let reviewEvents = try await coldRepo.reviewHistory(for: id)
        XCTAssertTrue(reviewEvents.isEmpty)
        XCTAssertFalse(ImVaultGuardedWrite.productionWriteEnabled)
    }

    @MainActor
    func testConfirmedDuplexHistoryRetainsReceiptsWhenNewerProposalIsSaved() async throws {
        let path = temporaryPath()
        let original = try ReviewWCDBRepository(databasePath: path,
            calculator: FSRS6ReviewCalculator())
        let source = "card:" + UUID().uuidString
        var session = WCDBV3ChatSession(sourceIdentity: source)
        var earlier = WCDBV3DuplexProposal(sourceMessageID: UUID(),
            noteIdentity: nil, noteBaseDigest: nil, noteEditedDigest: nil,
            cardID: UUID(), cardReviewRevision: 0, cardContentRevision: 0,
            cardBaseQuestion: "Before", cardBaseAnswer: "A",
            cardEditedQuestion: "After", cardEditedAnswer: "A",
            state: ImDuplexApprovalState(noteSelected: false, cardSelected: true,
                cardStatus: .applied))
        earlier.cardReceipt = "applied previous card without scoring"
        var recent = WCDBV3DuplexProposal(sourceMessageID: UUID(),
            noteIdentity: nil, noteBaseDigest: nil, noteEditedDigest: nil,
            cardID: UUID(), cardReviewRevision: 1, cardContentRevision: 0,
            cardBaseQuestion: "Q", cardBaseAnswer: "A",
            cardEditedQuestion: "Q2", cardEditedAnswer: "A2",
            state: ImDuplexApprovalState(noteSelected: false, cardSelected: true,
                cardStatus: .conflict))
        recent.cardReceipt = "newer conflict"
        session.duplexHistory = [earlier]
        session.pendingDuplex = recent
        try await original.saveChatSession(session, expectedRevision: nil)
        let reopened = try ReviewWCDBRepository(databasePath: path,
            calculator: FSRS6ReviewCalculator())
        let restoredRows = try await reopened.chatSessions(for: source)
        let restored = try XCTUnwrap(restoredRows.first)
        XCTAssertEqual(restored.duplexHistory?.count, 1)
        XCTAssertEqual(restored.duplexHistory?.first?.cardReceipt,
                       "applied previous card without scoring")
        XCTAssertEqual(restored.pendingDuplex?.cardReceipt, "newer conflict")
        let page = ImpressDuplexReceiptHistoryController(
            records: [try XCTUnwrap(restored.pendingDuplex)] +
                (restored.duplexHistory ?? []))
        page.loadViewIfNeeded()
        XCTAssertEqual(page.tableView.numberOfRows(inSection: 0), 2)
        var selectedID: UUID?
        page.onSelect = { selectedID = $0.proposalID }
        page.tableView(page.tableView, didSelectRowAt: IndexPath(row: 1, section: 0))
        XCTAssertEqual(selectedID, earlier.proposalID)
    }

    @MainActor
    func testSourceRevisionAcknowledgementKeepsOriginalCardAndReviewSchedule() async throws {
        let repo = try ReviewWCDBRepository(databasePath: temporaryPath(),
                                            calculator: FSRS6ReviewCalculator())
        let calculator = FSRS6ReviewCalculator()
        let identity = try ImVaultFileIdentity(vaultID: "stable", relativePath: "Topic.md")
        let previous = String(repeating: "a", count: 64)
        let latest = String(repeating: "b", count: 64)
        let previousKey = try ImpressBatchSourceKey.encode(identity, documentDigest: previous)
        let cardID = UUID(), created = Date(timeIntervalSince1970: 1_726_000_000)
        try await repo.insertNewCard(WCDBV3CardInput(cardID: cardID,
            question: "What does this explain?", answerText: "The original answer",
            sourceNotePath: previousKey),
            initial: try calculator.newCardSnapshot(id: cardID, now: created), now: created)
        let beforeValue = try await repo.content(for: cardID)
        let before = try XCTUnwrap(beforeValue)
        let previousCandidates = try await repo.fetchQueueCandidates()
        let previousReview = try XCTUnwrap(previousCandidates.first {
            $0.cardID == cardID
        })
        let newKey = try ImpressBatchSourceKey.encode(identity, documentDigest: latest)
        try await repo.updateManagedCard(WCDBV3CardInput(cardID: cardID,
            question: before.question, answerText: before.answerText,
            choices: before.choices, correctIndices: before.correctIndices,
            cardType: before.cardType, imageData: before.imageData,
            sourceNotePath: newKey),
            expectedRevision: previousReview.revision,
            expectedContentRevision: before.contentRevision)
        let afterValue = try await repo.content(for: cardID)
        let after = try XCTUnwrap(afterValue)
        let nextCandidates = try await repo.fetchQueueCandidates()
        let nextReview = try XCTUnwrap(nextCandidates.first {
            $0.cardID == cardID
        })
        XCTAssertEqual(after.cardID, cardID)
        XCTAssertEqual(after.question, before.question)
        XCTAssertEqual(after.answerText, before.answerText)
        XCTAssertEqual(after.contentRevision, before.contentRevision + 1)
        XCTAssertEqual(try ImpressBatchSourceKey.documentDigest(for:
            try XCTUnwrap(after.sourceNotePath)), latest)
        XCTAssertEqual(nextReview.revision, previousReview.revision)
        XCTAssertEqual(nextReview.dueAt, previousReview.dueAt)
        let related = try await repo.listRelatedCards(for: identity)
        XCTAssertEqual(related.map(\.cardID), [cardID])
    }

    @MainActor
    func testDuplexPartialReceiptDoesNotReapplyWrittenQAFileOnCardConflict() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("DuplexQA-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let identity = try ImVaultFileIdentity(vaultID: "fixture", relativePath: "One.md")
        let original = "# Topic\nOld detail\n"
        let file = root.appendingPathComponent("One.md")
        try Data(original.utf8).write(to: file)
        var draft = try ImVaultDraft(identity: identity, baseText: original)
        try draft.update("# Topic\nCorrected detail\n")
        let outcome = try ImVaultGuardedWrite.commitFixture(root: root,
            draft: draft, userConfirmedDiff: true)
        guard case .written = outcome else {
            XCTFail("First write must verify a real disposable fixture file")
            return
        }
        var state = ImDuplexApprovalState(noteSelected: true, cardSelected: true)
        state.noteStatus = .applied
        let conflict = ImDuplexCardVersionGate.decide(expectedContentRevision: 0,
            currentContentRevision: 1, baseQuestion: "Q", baseAnswer: "A",
            proposedQuestion: "Q2", proposedAnswer: "A2",
            currentQuestion: "Changed by another editor", currentAnswer: "A")
        XCTAssertEqual(conflict, .conflict)
        state.cardStatus = .conflict
        XCTAssertFalse(state.needsNoteAction)
        XCTAssertTrue(state.needsCardAction)
        let second = try ImVaultGuardedWrite.commitFixture(root: root,
            draft: draft, userConfirmedDiff: true)
        guard case .alreadyApplied = second else {
            XCTFail("Retry must never append or write a second time")
            return
        }
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8),
                       "# Topic\nCorrected detail\n")
        XCTAssertFalse(ImVaultGuardedWrite.productionWriteEnabled)
    }

    /// F03: crash after the actual coordinated fixture file write, before
    /// any WCDB success receipt. New database instance must adjudicate the
    /// source SHA explicitly; no forward operation is replayed.
    @MainActor
    func testF03FileWrittenButReceiptMissingColdStartReconciliation() async throws {
        let root = try createRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = try put("# Original\n", root: root, path: "Notes/F03.md")
        let identity = try ImVaultFileIdentity(vaultID: UUID().uuidString,
            relativePath: "Notes/F03.md")
        let original = try ImVaultReadSync.load(root: root, identity: identity)
        var draft = try ImVaultDraft(identity: identity,
            baseText: original.markdown, baseRawData: original.sourceBytes)
        try draft.update("# Applied once\n")
        let targetSHA = ImVaultDigest.sha256(draft.proposedBytes)
        let dbPath = temporaryPath()
        let repository = try ReviewWCDBRepository(databasePath: dbPath,
            calculator: FSRS6ReviewCalculator())
        let sourceKey = "card:" + UUID().uuidString
        var session = WCDBV3ChatSession(sourceIdentity: sourceKey)
        session.pendingDuplex = WCDBV3DuplexProposal(sourceMessageID: UUID(),
            noteIdentity: identity, noteBaseDigest: draft.baseDigest,
            noteEditedDigest: targetSHA, cardID: nil, cardReviewRevision: nil,
            cardContentRevision: nil, cardBaseQuestion: nil, cardBaseAnswer: nil,
            cardEditedQuestion: nil, cardEditedAnswer: nil,
            state: ImDuplexApprovalState(noteSelected: true, cardSelected: false,
                noteStatus: .applying))
        try await repository.saveChatSession(session, expectedRevision: nil)
        guard case .written = try ImVaultGuardedWrite.commitFixture(root: root,
            draft: draft, userConfirmedDiff: true) else {
            XCTFail("Must write an actual fixture file"); return
        }
        let recovered = try ReviewWCDBRepository(databasePath: dbPath,
            calculator: FSRS6ReviewCalculator())
        let sessions = try await recovered.chatSessions(for: sourceKey)
        var cold = try XCTUnwrap(sessions.first)
        var proposal = try XCTUnwrap(cold.pendingDuplex)
        XCTAssertEqual(proposal.state.noteStatus, .applying)
        XCTAssertFalse(proposal.state.completed)
        let verified = try ImVaultReadSync.load(root: root, identity: identity)
        let result = ImDuplexInterruptedRecovery.noteStatus(
            currentDigest: verified.digest, baseDigest: draft.baseDigest,
            proposedDigest: targetSHA)
        XCTAssertEqual(result, .applied)
        proposal.state.noteStatus = try XCTUnwrap(result)
        proposal.noteReceipt = "F03 SHA verified; file not replayed"
        cold.pendingDuplex = proposal
        cold.revision += 1
        cold.updatedAt = Date()
        try await recovered.saveChatSession(cold, expectedRevision: 0)
        let latest = try await recovered.chatSessions(for: sourceKey)
        XCTAssertEqual(latest.first?.pendingDuplex?.state.noteStatus, .applied)
        XCTAssertEqual(try Data(contentsOf: file), draft.proposedBytes)
        guard case .alreadyApplied = try ImVaultGuardedWrite.commitFixture(
            root: root, draft: draft, userConfirmedDiff: true) else {
            XCTFail("A duplicate attempt must be byte-level idempotent"); return
        }
        XCTAssertFalse(ImVaultGuardedWrite.productionWriteEnabled)
    }

    /// F04: WCDB card content CAS committed before the conversation receipt.
    /// Reopening the same database proves the card revision was applied once,
    /// with no FSRS event or duplicate content version.
    @MainActor
    func testF04CardCommittedButReceiptMissingAfterReopen() async throws {
        let path = temporaryPath()
        let calculator = FSRS6ReviewCalculator()
        let repo = try ReviewWCDBRepository(databasePath: path,
            calculator: calculator)
        let id = UUID()
        let now = Date(timeIntervalSince1970: 1_726_000_000)
        try await repo.insertNewCard(WCDBV3CardInput(cardID: id,
            question: "Old", answerText: "Before"),
            initial: try calculator.newCardSnapshot(id: id, now: now), now: now)
        let oldContentResult = try await repo.content(for: id)
        let old = try XCTUnwrap(oldContentResult)
        let queue = try await repo.fetchQueueCandidates()
        let pending = try XCTUnwrap(queue.first { $0.cardID == id })
        let source = "card:" + id.uuidString
        var session = WCDBV3ChatSession(sourceIdentity: source)
        session.pendingDuplex = WCDBV3DuplexProposal(sourceMessageID: UUID(),
            noteIdentity: nil, noteBaseDigest: nil, noteEditedDigest: nil,
            cardID: id, cardReviewRevision: pending.revision,
            cardContentRevision: old.contentRevision, cardBaseQuestion: "Old",
            cardBaseAnswer: "Before", cardEditedQuestion: "New",
            cardEditedAnswer: "Approved",
            state: ImDuplexApprovalState(noteSelected: false, cardSelected: true,
                cardStatus: .applying))
        try await repo.saveChatSession(session, expectedRevision: nil)
        try await repo.updateManagedCard(WCDBV3CardInput(cardID: id,
            question: "New", answerText: "Approved"),
            expectedRevision: pending.revision,
            expectedContentRevision: old.contentRevision, origin: .approvedAI)
        let reopened = try ReviewWCDBRepository(databasePath: path,
            calculator: calculator)
        let loaded = try await reopened.chatSessions(for: source)
        var persisted = try XCTUnwrap(loaded.first)
        var p = try XCTUnwrap(persisted.pendingDuplex)
        XCTAssertEqual(p.state.cardStatus, .applying)
        let actualResult = try await reopened.content(for: id)
        let actual = try XCTUnwrap(actualResult)
        let verdict = ImDuplexInterruptedRecovery.cardStatus(
            currentContentRevision: actual.contentRevision,
            expectedContentRevision: old.contentRevision,
            baseQuestion: "Old", baseAnswer: "Before",
            proposedQuestion: "New", proposedAnswer: "Approved",
            currentQuestion: actual.question, currentAnswer: actual.answerText)
        XCTAssertEqual(verdict, .applied)
        p.state.cardStatus = try XCTUnwrap(verdict)
        p.cardReceipt = "F04 content CAS verified; no repeat"
        persisted.pendingDuplex = p
        persisted.revision += 1
        persisted.updatedAt = Date()
        try await reopened.saveChatSession(persisted, expectedRevision: 0)
        let history = try await reopened.contentHistory(for: id)
        XCTAssertEqual(history.map(\.contentRevision), [0, 1])
        let ratings = try await reopened.reviewHistory(for: id)
        XCTAssertTrue(ratings.isEmpty)
        let current = try await reopened.chatSessions(for: source)
        XCTAssertEqual(current.first?.pendingDuplex?.state.cardStatus, .applied)
    }

    /// F02: the real production write guard denies the source update,
    /// but a separately approved original card CAS can still succeed. A
    /// cold WCDB read preserves both facts and no FSRS rating is invented.
    @MainActor
    func testF02DeniedNoteWriteAndAppliedOriginalCardSurviveColdStart() async throws {
        let db = temporaryPath()
        let calculator = FSRS6ReviewCalculator()
        let repo = try ReviewWCDBRepository(databasePath: db, calculator: calculator)
        let cardID = UUID()
        let now = Date(timeIntervalSince1970: 1_726_000_000)
        let identity = try ImVaultFileIdentity(vaultID: UUID().uuidString,
            relativePath: "Notes/F02.md")
        let noteLink = try ImpressBatchSourceKey.encode(identity)
        try await repo.insertNewCard(WCDBV3CardInput(cardID: cardID,
            question: "Old", answerText: "Original", sourceNotePath: noteLink),
            initial: try calculator.newCardSnapshot(id: cardID, now: now), now: now)
        var draft = try ImVaultDraft(identity: identity, baseText: "# Source\n")
        try draft.update("# Updated\n")
        let refused: Result<ImVaultCommitOutcome, Error> =
            await withCheckedContinuation { continuation in
                ImVaultGuardedWrite.commitAuthorized(draft: draft,
                    userConfirmedDiff: true, deviceQATestCopyConfirmed: false) {
                    continuation.resume(returning: $0)
                }
            }
        guard case .failure = refused else {
            XCTFail("Production Vault write must remain locked"); return
        }
        let queue = try await repo.fetchQueueCandidates()
        let token = try XCTUnwrap(queue.first { $0.cardID == cardID })
        try await repo.updateManagedCard(WCDBV3CardInput(cardID: cardID,
            question: "Approved question", answerText: "Approved answer",
            sourceNotePath: noteLink), expectedRevision: token.revision,
            expectedContentRevision: 0, origin: .approvedAI)
        var session = WCDBV3ChatSession(sourceIdentity: "card:" + cardID.uuidString)
        var proposal = WCDBV3DuplexProposal(sourceMessageID: UUID(),
            noteIdentity: identity, noteBaseDigest: draft.baseDigest,
            noteEditedDigest: ImVaultDigest.sha256(draft.proposedBytes),
            cardID: cardID, cardReviewRevision: token.revision,
            cardContentRevision: 0, cardBaseQuestion: "Old", cardBaseAnswer: "Original",
            cardEditedQuestion: "Approved question", cardEditedAnswer: "Approved answer",
            state: ImDuplexApprovalState(noteSelected: true, cardSelected: true,
                noteStatus: .failed, cardStatus: .applied))
        proposal.noteReceipt = "Production gate rejected file write"
        proposal.cardReceipt = "Card CAS applied once"
        session.pendingDuplex = proposal
        try await repo.saveChatSession(session, expectedRevision: nil)
        let reopened = try ReviewWCDBRepository(databasePath: db,
            calculator: calculator)
        let conversations = try await reopened.chatSessions(for: session.sourceIdentity)
        let receipt = try XCTUnwrap(conversations.first?.pendingDuplex)
        XCTAssertEqual(receipt.state.noteStatus, .failed)
        XCTAssertEqual(receipt.state.cardStatus, .applied)
        XCTAssertTrue(receipt.state.needsNoteAction)
        XCTAssertFalse(receipt.state.needsCardAction)
        let contentResult = try await reopened.content(for: cardID)
        let content = try XCTUnwrap(contentResult)
        XCTAssertEqual(content.question, "Approved question")
        XCTAssertEqual(content.contentRevision, 1)
        let versions = try await reopened.contentHistory(for: cardID)
        XCTAssertEqual(versions.map(\.contentRevision), [0, 1])
        let ratings = try await reopened.reviewHistory(for: cardID)
        XCTAssertTrue(ratings.isEmpty)
        XCTAssertFalse(ImVaultGuardedWrite.productionWriteEnabled)
    }

    @MainActor
    func testDuplexProposalPersistsAcrossChatColdStartWithoutReplayingWrites() async throws {
        let path = temporaryPath()
        let storage = try ReviewWCDBRepository(
            databasePath: path, calculator: FSRS6ReviewCalculator())
        let cardID = UUID()
        let source = "card:" + cardID.uuidString
        let note = try ImVaultFileIdentity(vaultID: "qa-source", relativePath: "Note.md")
        var saved = WCDBV3ChatSession(sourceIdentity: source)
        saved.pendingDuplex = WCDBV3DuplexProposal(
            sourceMessageID: UUID(), noteIdentity: note,
            noteBaseDigest: String(repeating: "a", count: 64),
            noteEditedDigest: String(repeating: "b", count: 64),
            cardID: cardID, cardReviewRevision: 3, cardContentRevision: 5,
            cardBaseQuestion: "Q", cardBaseAnswer: "A",
            cardEditedQuestion: "Q2", cardEditedAnswer: "A2",
            state: ImDuplexApprovalState(noteSelected: true, cardSelected: true,
                noteStatus: .applied, cardStatus: .failed))
        try await storage.saveChatSession(saved, expectedRevision: nil)
        let reopened = try ReviewWCDBRepository(
            databasePath: path, calculator: FSRS6ReviewCalculator())
        let rows = try await reopened.chatSessions(for: source)
        let restored = try XCTUnwrap(rows.first?.pendingDuplex)
        XCTAssertEqual(restored.proposalID, saved.pendingDuplex?.proposalID)
        XCTAssertEqual(restored.noteIdentity, note)
        XCTAssertFalse(restored.state.needsNoteAction)
        XCTAssertTrue(restored.state.needsCardAction)
        XCTAssertFalse(restored.state.completed)
        XCTAssertFalse(ImVaultGuardedWrite.productionWriteEnabled)
    }



    // ACCEPT-01/02/04/05/06/09/10/11/12 service-layer fixture roundtrip.
    // This does NOT claim real AI inference, UI gestures or iPhone File Provider.
    // Every source byte here belongs to a disposable temporary test Vault.
    @MainActor
    func testDisposableVaultCardChatDuplexFullRoundTripAfterInterveningFSRS() async throws {
        let root = try createRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let fixtureMarkdown = [
            "---\r\ntitle: Duplex QA\r\n---\r\n# Theory\r\n",
            "F = ma.\r\n- [[Dynamics]]\r\n\r\n# Practice\r\n",
            "Check units.\r\n```swift\r\nlet value = 1\r\n```\r\n"
        ].joined()
        let original = Data([0xEF, 0xBB, 0xBF]) + Data(fixtureMarkdown.utf8)
        let file = try put("disposable", root: root, path: "Notes/Duplex.md")
        try original.write(to: file, options: .atomic)
        let identity = try ImVaultFileIdentity(vaultID: UUID().uuidString,
            relativePath: "Notes/Duplex.md")
        let sourceDocument = try ImVaultReadSync.load(root: root, identity: identity)
        let selectedSection = try XCTUnwrap(
            ImpressAISectionExtractor.sections(in: sourceDocument.markdown)
                .first(where: { $0.heading == "Theory" }))
        let source = ImpressAISource(vaultID: identity.vaultID,
            relativePath: identity.relativePath,
            documentSHA256: sourceDocument.digest, heading: selectedSection.heading)
        let excerpt = ImpressAIExcerpt(id: selectedSection.id, source: source,
            text: selectedSection.text, sectionHeading: selectedSection.heading)
        let pool = ImpressAIQuestionPool(source: source, excerpts: [excerpt],
            requestedCount: 1, modelProfileID: UUID(), candidates: [
                ImpressAIQuestionCandidate(question: "What does F = ma describe?",
                    answer: "Net force, mass and acceleration.",
                    dimension: .mechanism, evidenceIDs: [excerpt.id])
            ])
        let confirmed = try ImpressAIQuestionValidator.validatedSelection(pool)
        XCTAssertEqual(confirmed.count, 1)
        let link = try ImpressAINoteCardLink.sourceKey(identity: identity,
            documentDigest: sourceDocument.digest, candidateEvidenceIDs: confirmed[0].evidenceIDs,
            excerpts: [excerpt], sourceMarkdown: sourceDocument.markdown)
        XCTAssertNotNil(try ImpressBatchSourceKey.sectionDigest(for: link))
        let databasePath = temporaryPath()
        let calculator = FSRS6ReviewCalculator()
        let repository = try ReviewWCDBRepository(databasePath: databasePath,
            calculator: calculator)
        let created = Date(timeIntervalSince1970: 1_726_000_000)
        let input = WCDBV3CardInput(question: confirmed[0].question,
            answerText: confirmed[0].answer, sourceNotePath: link)
        let inserted = try await repository.insertBatchCards([(
            input, try calculator.newCardSnapshot(id: input.cardID, now: created)
        )], now: created)
        XCTAssertEqual(inserted, 1)
        let related = try await repository.listRelatedCards(for: identity)
        XCTAssertEqual(related.map(\.cardID), [input.cardID])
        let otherVault = try ImVaultFileIdentity(vaultID: "other-vault",
            relativePath: identity.relativePath)
        let foreignCards = try await repository.listRelatedCards(for: otherVault)
        XCTAssertTrue(foreignCards.isEmpty)

        let sourceToken = "card:" + input.cardID.uuidString
        var chat = WCDBV3ChatSession(sourceIdentity: sourceToken)
        chat.messages = [
            WCDBV3ChatMessage(role: .user, text: "Explain the boundary.",
                status: .completed),
            WCDBV3ChatMessage(role: .assistant, text: "Review the related assumption.",
                status: .completed)
        ]
        chat.inputDraft = "An unsent follow-up"
        chat.promptOverride = "Use first principles and the simplest explanation."
        var secondChat = WCDBV3ChatSession(sourceIdentity: sourceToken)
        secondChat.inputDraft = "Another independent discussion"
        try await repository.saveChatSession(chat, expectedRevision: nil)
        try await repository.saveChatSession(secondChat, expectedRevision: nil)

        var draft = try ImVaultDraft(identity: identity,
            baseText: sourceDocument.markdown, baseRawData: original)
        let editedMarkdown = sourceDocument.markdown.replacingOccurrences(
            of: "F = ma.", with: "Net force is F = ma.")
        // Never prepend an additional BOM when UIKit normalizes editable text.
        try draft.update(editedMarkdown.hasPrefix("\u{feff}")
            ? String(editedMarkdown.dropFirst()) : editedMarkdown)
        XCTAssertTrue(ImVaultDiff.summary(base: draft.byteFaithfulBaseText,
            edited: draft.byteFaithfulEditedText, maximumLines: 200).complete)
        XCTAssertTrue(draft.proposedBytes.starts(with: [0xEF, 0xBB, 0xBF]))
        try ImVaultPrivateStore.saveDraft(draft)

        // The approval records the OLD FSRS revision intentionally. Reviewing
        // after approval must not turn a valid CONTENT-only edit into conflict.
        let storedOriginal = try await repository.content(for: input.cardID)
        let originalContent = try XCTUnwrap(storedOriginal)
        let initialCandidates = try await repository.fetchQueueCandidates()
        let originalQueue = try XCTUnwrap(initialCandidates.first(where: {
            $0.cardID == input.cardID
        }))
        var proposal = WCDBV3DuplexProposal(sourceMessageID: chat.messages.last?.messageID,
            noteIdentity: identity, noteBaseDigest: draft.baseDigest,
            noteEditedDigest: ImVaultDigest.sha256(draft.proposedBytes),
            cardID: input.cardID, cardReviewRevision: originalQueue.revision,
            cardContentRevision: originalContent.contentRevision,
            cardBaseQuestion: originalContent.question,
            cardBaseAnswer: originalContent.answerText,
            cardEditedQuestion: originalContent.question,
            cardEditedAnswer: "Net force causes acceleration.",
            state: ImDuplexApprovalState(noteSelected: true, cardSelected: true))
        chat.pendingDuplex = proposal
        chat.revision += 1
        chat.updatedAt = Date()
        try await repository.saveChatSession(chat, expectedRevision: 0)
        _ = try await repository.commit(ReviewSubmission(eventID: UUID(),
            cardID: input.cardID, expectedRevision: originalQueue.revision,
            rating: .good, reviewedAt: created.addingTimeInterval(2)))
        let ratedCandidates = try await repository.fetchQueueCandidates()
        let afterReview = try XCTUnwrap(ratedCandidates.first(where: {
            $0.cardID == input.cardID
        }))
        XCTAssertEqual(afterReview.revision, originalQueue.revision + 1)
        XCTAssertEqual(ImDuplexCardVersionGate.decide(
            expectedContentRevision: originalContent.contentRevision,
            currentContentRevision: originalContent.contentRevision,
            baseQuestion: originalContent.question, baseAnswer: originalContent.answerText,
            proposedQuestion: originalContent.question,
            proposedAnswer: proposal.cardEditedAnswer,
            currentQuestion: originalContent.question,
            currentAnswer: originalContent.answerText), .safeToWrite)

        let written = try ImVaultGuardedWrite.commitFixture(root: root,
            draft: draft, userConfirmedDiff: true)
        guard case let .written(recovery) = written else {
            XCTFail("The disposable note must actually be written and read back")
            return
        }
        XCTAssertEqual(try Data(contentsOf: recovery), original)
        XCTAssertEqual(try Data(contentsOf: file), draft.proposedBytes)
        proposal.state.noteStatus = .applied
        proposal.noteReceipt = "QA fixture written, verified and recoverable"
        chat.pendingDuplex = proposal
        chat.revision += 1
        chat.updatedAt = Date()
        try await repository.saveChatSession(chat, expectedRevision: 1)
        try await repository.updateManagedCard(WCDBV3CardInput(
            cardID: input.cardID, question: originalContent.question,
            answerText: proposal.cardEditedAnswer, sourceNotePath: link),
            expectedRevision: afterReview.revision,
            expectedContentRevision: originalContent.contentRevision,
            origin: .approvedAI)
        proposal.state.cardStatus = .applied
        proposal.cardReceipt = "Original card updated with no new FSRS score"
        chat.pendingDuplex = proposal
        chat.revision += 1
        chat.updatedAt = Date()
        try await repository.saveChatSession(chat, expectedRevision: 2)
        let storedUpdated = try await repository.content(for: input.cardID)
        let updatedContent = try XCTUnwrap(storedUpdated)
        XCTAssertEqual(updatedContent.cardID, input.cardID)
        XCTAssertEqual(updatedContent.contentRevision, originalContent.contentRevision + 1)
        let ratedEvents = try await repository.reviewHistory(for: input.cardID)
        XCTAssertEqual(ratedEvents.count, 1)
        let queueAfterContentEdit = try await repository.fetchQueueCandidates()
        XCTAssertEqual(queueAfterContentEdit.first(where: {
            $0.cardID == input.cardID
        })?.revision, afterReview.revision)
        guard case .alreadyApplied = try ImVaultGuardedWrite.commitFixture(
            root: root, draft: draft, userConfirmedDiff: true) else {
            XCTFail("A resumed note operation must not append twice")
            return
        }

        let unrelatedEdit = sourceDocument.markdown.replacingOccurrences(
            of: "Check units.", with: "Check SI units.")
        XCTAssertTrue(ImpressAINoteCardLink.verifiedSectionUnchanged(
            sourceKey: link, currentMarkdown: unrelatedEdit))
        let relatedEdit = try XCTUnwrap(String(data: draft.proposedBytes,
            encoding: .utf8))
        XCTAssertFalse(ImpressAINoteCardLink.verifiedSectionUnchanged(
            sourceKey: link, currentMarkdown: relatedEdit))

        // Reverse each applied target with a NEW CAS revision; never erase
        // history or replay a forward write from a persisted receipt.
        let queueBeforeUndo = try await repository.fetchQueueCandidates()
        let updatedQueue = try XCTUnwrap(queueBeforeUndo.first(where: {
            $0.cardID == input.cardID
        }))
        try await repository.updateManagedCard(WCDBV3CardInput(
            cardID: input.cardID, question: originalContent.question,
            answerText: originalContent.answerText, sourceNotePath: link),
            expectedRevision: updatedQueue.revision,
            expectedContentRevision: updatedContent.contentRevision, origin: .restored)
        let inverse = try ImpressDuplexUndoGate.inverseDraft(draft,
            expectedBaseDigest: proposal.noteBaseDigest,
            expectedAppliedDigest: proposal.noteEditedDigest)
        guard case .written = try ImVaultGuardedWrite.commitFixture(
            root: root, draft: inverse, userConfirmedDiff: true) else {
            XCTFail("The independently approved inverse must write the source bytes")
            return
        }
        XCTAssertEqual(try Data(contentsOf: file), original)
        proposal.state.noteStatus = .reverted
        proposal.state.cardStatus = .reverted
        proposal.noteReceipt = "QA byte-for-byte source restored"
        proposal.cardReceipt = "Card restored with a new content revision"
        chat.pendingDuplex = proposal
        chat.revision += 1
        chat.updatedAt = Date()
        try await repository.saveChatSession(chat, expectedRevision: 3)

        let coldStart = try ReviewWCDBRepository(databasePath: databasePath,
            calculator: calculator)
        let recovered = try await coldStart.chatSessions(for: sourceToken)
        XCTAssertEqual(recovered.count, 2)
        XCTAssertEqual(recovered.first(where: { $0.sessionID == chat.sessionID })?
            .pendingDuplex?.state.noteStatus, .reverted)
        XCTAssertEqual(recovered.first(where: { $0.sessionID == chat.sessionID })?
            .messages.count, 2)
        XCTAssertTrue(recovered.contains(where: {
            $0.sessionID == secondChat.sessionID &&
            $0.inputDraft == "Another independent discussion"
        }))
        let reopenedCard = try await coldStart.content(for: input.cardID)
        let restored = try XCTUnwrap(reopenedCard)
        XCTAssertEqual(restored.cardID, input.cardID)
        XCTAssertEqual(restored.question, originalContent.question)
        XCTAssertEqual(restored.answerText, originalContent.answerText)
        XCTAssertEqual(restored.contentRevision, originalContent.contentRevision + 2)
        let snapshots = try await coldStart.contentHistory(for: input.cardID)
        let preservedRatings = try await coldStart.reviewHistory(for: input.cardID)
        XCTAssertEqual(snapshots.count, 3)
        XCTAssertEqual(preservedRatings.count, 1)
        XCTAssertFalse(ImVaultGuardedWrite.productionWriteEnabled)
    }


    @MainActor
    func testDuplexDiffPreviewDisplaysExactVaultIDAndSourcePath() throws {
        let id = try ImVaultFileIdentity(vaultID: UUID().uuidString,
            relativePath: "Lessons/Mechanics/Notes.md")
        var draft = try ImVaultDraft(identity: id, baseText: "# Original\n[[Link]]\n")
        try draft.update("# Revised\n[[Link]]\n")
        try ImVaultPrivateStore.saveDraft(draft)
        let p = WCDBV3DuplexProposal(sourceMessageID: nil, noteIdentity: id,
            noteBaseDigest: draft.baseDigest,
            noteEditedDigest: ImVaultDigest.sha256(draft.proposedBytes),
            cardID: nil, cardReviewRevision: nil, cardContentRevision: nil,
            cardBaseQuestion: nil, cardBaseAnswer: nil,
            cardEditedQuestion: nil, cardEditedAnswer: nil,
            state: ImDuplexApprovalState(noteSelected: true, cardSelected: false))
        let repo = try ReviewWCDBRepository(databasePath: temporaryPath(),
            calculator: FSRS6ReviewCalculator())
        let controller = ImpressDuplexApprovalController(
            repository: repo, proposal: p) { _ in true }
        controller.loadViewIfNeeded()
        let preview = try XCTUnwrap(controller.view.subviews.compactMap {
            $0 as? UITextView
        }.first(where: { $0.accessibilityIdentifier == "impress.duplex.full-diff" }))
        XCTAssertTrue(preview.text.contains(id.vaultID))
        XCTAssertTrue(preview.text.contains(id.relativePath))
        XCTAssertTrue(preview.text.contains(draft.baseDigest))
        XCTAssertTrue(preview.text.contains("Original"))
        XCTAssertTrue(preview.text.contains("Revised"))
        XCTAssertFalse(ImVaultGuardedWrite.productionWriteEnabled)
    }

    func testUnsentChatModelAndPromptSurviveColdStartAndLegacyJSON() async throws {
        let path = temporaryPath()
        let repo = try ReviewWCDBRepository(databasePath: path,
            calculator: FSRS6ReviewCalculator())
        let model = UUID()
        var conversation = WCDBV3ChatSession(sourceIdentity: "chat:standalone:v1")
        conversation.selectedChatModelID = model
        conversation.promptOverride = "First principles."
        conversation.inputDraft = "Unsent question"
        try await repo.saveChatSession(conversation, expectedRevision: nil)
        let reopened = try ReviewWCDBRepository(databasePath: path,
            calculator: FSRS6ReviewCalculator())
        let sessions = try await reopened.chatSessions(for: "chat:standalone:v1")
        let stored = try XCTUnwrap(sessions.first)
        XCTAssertEqual(stored.selectedChatModelID, model)
        XCTAssertEqual(stored.promptOverride, conversation.promptOverride)
        XCTAssertEqual(stored.inputDraft, conversation.inputDraft)
        var legacy = try XCTUnwrap(JSONSerialization.jsonObject(
            with: JSONEncoder().encode(conversation)) as? [String: Any])
        legacy.removeValue(forKey: "selectedChatModelID")
        let decoded = try JSONDecoder().decode(WCDBV3ChatSession.self,
            from: JSONSerialization.data(withJSONObject: legacy))
        XCTAssertNil(decoded.selectedChatModelID)
        XCTAssertEqual(decoded.inputDraft, conversation.inputDraft)
    }


    /// F07/F08: two independently approved edits from one source digest are
    /// NOT sequential authorization. The later submission must fail closed
    /// after the first edit changes the source, without corrupting either
    /// immutable approved snapshot or overwriting the newer valid bytes.
    @MainActor
    func testF07ConcurrentApprovalsFromSameBaseCannotOverwriteWinner() throws {
        let root = try createRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let id = try ImVaultFileIdentity(vaultID: UUID().uuidString,
            relativePath: "Notes/ConcurrentApprovals.md")
        let original = Data([0xEF, 0xBB, 0xBF]) +
            Data("# Subject\r\nOriginal\r\n[[Keep]]\r\n".utf8)
        let file = try put("# Placeholder", root: root, path: id.relativePath)
        try original.write(to: file, options: .atomic)
        let source = try ImVaultReadSync.load(root: root, identity: id)
        var first = try ImVaultDraft(identity: id, baseText: source.markdown,
            baseRawData: source.sourceBytes)
        var stale = try ImVaultDraft(identity: id, baseText: source.markdown,
            baseRawData: source.sourceBytes)
        try first.update("# Subject\nFirst approved\n[[Keep]]\n")
        try stale.update("# Subject\nStale approved\n[[Keep]]\n")
        XCTAssertEqual(first.baseDigest, stale.baseDigest)
        XCTAssertNotEqual(first.proposedBytes, stale.proposedBytes)
        try ImVaultPrivateStore.archiveApprovedDraft(first)
        try ImVaultPrivateStore.archiveApprovedDraft(stale)
        guard case .written = try ImVaultGuardedWrite.commitFixture(
            root: root, draft: first, userConfirmedDiff: true) else {
            XCTFail("First independent approval must write"); return
        }
        XCTAssertThrowsError(try ImVaultGuardedWrite.commitFixture(
            root: root, draft: stale, userConfirmedDiff: true),
            "An approval bound to a stale base cannot overwrite newer bytes")
        XCTAssertEqual(try Data(contentsOf: file), first.proposedBytes)
        let recoveredFirst = try XCTUnwrap(ImVaultPrivateStore.approvedDraft(
            identity: id, baseDigest: first.baseDigest,
            editedDigest: ImVaultDigest.sha256(first.proposedBytes)))
        let recoveredStale = try XCTUnwrap(ImVaultPrivateStore.approvedDraft(
            identity: id, baseDigest: stale.baseDigest,
            editedDigest: ImVaultDigest.sha256(stale.proposedBytes)))
        XCTAssertEqual(recoveredFirst.baseRawData, original)
        XCTAssertEqual(recoveredFirst.proposedBytes, first.proposedBytes)
        XCTAssertEqual(recoveredStale.baseRawData, original)
        XCTAssertEqual(recoveredStale.proposedBytes, stale.proposedBytes)
        XCTAssertFalse(ImVaultGuardedWrite.productionWriteEnabled)
    }

    @MainActor
    func testTwoApprovedNoteRevisionsRemainIndependentAndUndoInReverseOrder() throws {
        let root = try createRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let id = try ImVaultFileIdentity(vaultID: UUID().uuidString,
            relativePath: "Notes/Sequential.md")
        let firstBytes = Data([0xEF, 0xBB, 0xBF]) +
            Data("# Concept\r\nOriginal\r\n[[Link]]\r\n".utf8)
        let file = try put("# placeholder", root: root, path: id.relativePath)
        try firstBytes.write(to: file, options: .atomic)
        let raw = try ImVaultReadSync.load(root: root, identity: id)
        var first = try ImVaultDraft(identity: id, baseText: raw.markdown,
            baseRawData: raw.sourceBytes)
        try first.update("# Concept\nFirst correction\n[[Link]]\n")
        try ImVaultPrivateStore.saveDraft(first)
        try ImVaultPrivateStore.archiveApprovedDraft(first)
        guard case .written = try ImVaultGuardedWrite.commitFixture(
            root: root, draft: first, userConfirmedDiff: true) else {
            XCTFail("Expected first QA write"); return
        }
        let afterFirst = try ImVaultReadSync.load(root: root, identity: id)
        let next = try ImVaultPrivateStore.startFreshDraft(afterApplied: first,
            live: afterFirst)
        XCTAssertFalse(next.hasChanges)
        var second = next
        try second.update("# Concept\nSecond correction\n[[Link]]\n")
        try ImVaultPrivateStore.saveDraft(second)
        try ImVaultPrivateStore.archiveApprovedDraft(second)
        guard case .written = try ImVaultGuardedWrite.commitFixture(
            root: root, draft: second, userConfirmedDiff: true) else {
            XCTFail("Expected second QA write"); return
        }
        let oldReceipt = try XCTUnwrap(ImVaultPrivateStore.approvedDraft(
            identity: id, baseDigest: first.baseDigest,
            editedDigest: ImVaultDigest.sha256(first.proposedBytes)))
        let newReceipt = try XCTUnwrap(ImVaultPrivateStore.approvedDraft(
            identity: id, baseDigest: second.baseDigest,
            editedDigest: ImVaultDigest.sha256(second.proposedBytes)))
        XCTAssertEqual(oldReceipt.baseRawData, firstBytes)
        XCTAssertEqual(oldReceipt.proposedBytes, afterFirst.sourceBytes)
        XCTAssertEqual(newReceipt.baseRawData, afterFirst.sourceBytes)
        XCTAssertEqual(newReceipt.proposedBytes, try Data(contentsOf: file))
        let undoOld = try ImpressDuplexUndoGate.inverseDraft(oldReceipt,
            expectedBaseDigest: first.baseDigest,
            expectedAppliedDigest: ImVaultDigest.sha256(first.proposedBytes))
        XCTAssertEqual(undoOld.decision(against: try Data(contentsOf: file)), .conflict)
        let undoNew = try ImpressDuplexUndoGate.inverseDraft(newReceipt,
            expectedBaseDigest: second.baseDigest,
            expectedAppliedDigest: ImVaultDigest.sha256(second.proposedBytes))
        guard case .written = try ImVaultGuardedWrite.commitFixture(
            root: root, draft: undoNew, userConfirmedDiff: true) else {
            XCTFail("Second approval must undo safely"); return
        }
        XCTAssertEqual(try Data(contentsOf: file), afterFirst.sourceBytes)
        guard case .written = try ImVaultGuardedWrite.commitFixture(
            root: root, draft: undoOld, userConfirmedDiff: true) else {
            XCTFail("First approval must restore original"); return
        }
        XCTAssertEqual(try Data(contentsOf: file), firstBytes)
        XCTAssertFalse(ImVaultGuardedWrite.productionWriteEnabled)
    }

    @MainActor
    func testNewDraftAfterExternalEditCannotOverwriteOldPendingWork() throws {
        let root = try createRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let id = try ImVaultFileIdentity(vaultID: UUID().uuidString,
            relativePath: "Notes/Safe.md")
        let url = try put("# Initial", root: root, path: id.relativePath)
        let live = try ImVaultReadSync.load(root: root, identity: id)
        var unsent = try ImVaultDraft(identity: id, baseText: live.markdown,
            baseRawData: live.sourceBytes)
        try unsent.update("# Unsent correction")
        try ImVaultPrivateStore.saveDraft(unsent)
        try Data("# Third-party edit".utf8).write(to: url, options: .atomic)
        let changed = try ImVaultReadSync.load(root: root, identity: id)
        XCTAssertThrowsError(try ImVaultPrivateStore.startFreshDraft(
            afterApplied: unsent, live: changed))
        XCTAssertEqual(try ImVaultPrivateStore.loadDraft(identity: id)?.editedText,
            unsent.editedText)
        let stranger = try ImVaultFileIdentity(vaultID: "other-vault",
            relativePath: id.relativePath)
        XCTAssertNil(try ImVaultPrivateStore.approvedDraft(identity: stranger,
            baseDigest: unsent.baseDigest,
            editedDigest: ImVaultDigest.sha256(unsent.proposedBytes)))
        XCTAssertEqual(try Data(contentsOf: url), changed.sourceBytes)
    }

    @MainActor
    func testHistoricalDuplexPreviewKeepsOldDiffAfterLaterNoteDraft() throws {
        let id = try ImVaultFileIdentity(vaultID: UUID().uuidString,
            relativePath: "Notes/History.md")
        var former = try ImVaultDraft(identity: id, baseText: "# Before\n[[Keep]]\n")
        try former.update("# After\n[[Keep]]\n")
        try ImVaultPrivateStore.saveDraft(former)
        try ImVaultPrivateStore.archiveApprovedDraft(former)
        let proposal = WCDBV3DuplexProposal(sourceMessageID: nil,
            noteIdentity: id, noteBaseDigest: former.baseDigest,
            noteEditedDigest: ImVaultDigest.sha256(former.proposedBytes),
            cardID: nil, cardReviewRevision: nil, cardContentRevision: nil,
            cardBaseQuestion: nil, cardBaseAnswer: nil,
            cardEditedQuestion: nil, cardEditedAnswer: nil,
            state: ImDuplexApprovalState(noteSelected: true,
                cardSelected: false, noteStatus: .applied))
        var later = try ImVaultDraft(identity: id, baseText: "# After\n[[Keep]]\n")
        try later.update("# Later update\n[[Keep]]\n")
        try ImVaultPrivateStore.saveDraft(later)
        let repo = try ReviewWCDBRepository(databasePath: temporaryPath(),
            calculator: FSRS6ReviewCalculator())
        let page = ImpressDuplexApprovalController(
            repository: repo, proposal: proposal) { _ in true }
        page.loadViewIfNeeded()
        let view = try XCTUnwrap(page.view.subviews.compactMap {
            $0 as? UITextView
        }.first(where: { $0.accessibilityIdentifier == "impress.duplex.full-diff" }))
        XCTAssertTrue(view.text.contains("- # Before"))
        XCTAssertTrue(view.text.contains("+ # After"))
        XCTAssertFalse(view.text.contains("Later update"))
        XCTAssertFalse(ImVaultGuardedWrite.productionWriteEnabled)
    }


    @MainActor
    func testSourceImpactIncludesDirectOriginalCardEditorAndUnaffectedChoice() throws {
        let identity = try ImVaultFileIdentity(vaultID: UUID().uuidString,
            relativePath: "Study/Impact.md")
        let doc = ImVaultRawDocument(identity: identity,
            sourceBytes: Data("# Current".utf8), markdown: "# Current",
            digest: ImVaultDigest.sha256(Data("# Current".utf8)))
        let repo = try ReviewWCDBRepository(databasePath: temporaryPath(),
            calculator: FSRS6ReviewCalculator())
        let page = ImpressNoteSourceImpactController(document: doc, cardID: UUID(),
            previousDigest: String(repeating: "a", count: 64),
            repository: repo)
        page.loadViewIfNeeded()
        let identifiers = Set(page.view.subviews.compactMap {
            ($0 as? UIButton)?.accessibilityIdentifier
        })
        XCTAssertTrue(identifiers.contains("impress.notes.source-impact.edit-original"))
        XCTAssertTrue(identifiers.contains("impress.notes.source-impact.unaffected"))
        XCTAssertFalse(ImVaultGuardedWrite.productionWriteEnabled)
    }

    @MainActor
    func testSourceImpactNoImpactSourceDigestCASPreservesFSRSAndRejectsReplay() async throws {
        let repo = try ReviewWCDBRepository(databasePath: temporaryPath(),
            calculator: FSRS6ReviewCalculator())
        let identity = try ImVaultFileIdentity(vaultID: UUID().uuidString,
            relativePath: "Study/Unaffected.md")
        let oldBytes = Data("# Before\r\n".utf8)
        let newBytes = Data("# After\r\n".utf8)
        let oldKey = try ImpressBatchSourceKey.encode(identity,
            documentDigest: ImVaultDigest.sha256(oldBytes))
        let newKey = try ImpressBatchSourceKey.encode(identity,
            documentDigest: ImVaultDigest.sha256(newBytes))
        let cardID = UUID(), now = Date(timeIntervalSince1970: 1_726_400_000)
        try await repo.insertNewCard(WCDBV3CardInput(cardID: cardID,
            question: "What stays true?", answerText: "The answer",
            sourceNotePath: oldKey),
            initial: try FSRS6ReviewCalculator().newCardSnapshot(id: cardID, now: now),
            now: now)
        let beforeRows = try await repo.fetchQueueCandidates()
        let beforeReview = try XCTUnwrap(beforeRows.first(where: { $0.cardID == cardID }))
        _ = try await repo.commit(ReviewSubmission(eventID: UUID(), cardID: cardID,
            expectedRevision: beforeReview.revision, rating: .good,
            reviewedAt: now.addingTimeInterval(10)))
        let beforeValue = try await repo.content(for: cardID)
        let before = try XCTUnwrap(beforeValue)
        let scheduledRows = try await repo.fetchQueueCandidates()
        let scheduled = try XCTUnwrap(scheduledRows.first(where: { $0.cardID == cardID }))
        let approved = WCDBV3CardInput(cardID: cardID,
            question: before.question, answerText: before.answerText,
            choices: before.choices, correctIndices: before.correctIndices,
            cardType: before.cardType, imageData: before.imageData,
            sourceNotePath: newKey)
        try await repo.updateManagedCard(approved, expectedRevision: scheduled.revision,
            expectedContentRevision: before.contentRevision, origin: .manual)
        let afterValue = try await repo.content(for: cardID)
        let after = try XCTUnwrap(afterValue)
        let afterRows = try await repo.fetchQueueCandidates()
        let fsrs = try XCTUnwrap(afterRows.first(where: { $0.cardID == cardID }))
        XCTAssertEqual(after.cardID, before.cardID)
        XCTAssertEqual(after.question, before.question)
        XCTAssertEqual(after.answerText, before.answerText)
        XCTAssertEqual(after.contentRevision, before.contentRevision + 1)
        XCTAssertEqual(after.sourceNotePath, newKey)
        XCTAssertEqual(fsrs.revision, scheduled.revision)
        XCTAssertEqual(fsrs.dueAt, scheduled.dueAt)
        let events = try await repo.reviewHistory(for: cardID)
        XCTAssertEqual(events.count, 1)
        do {
            try await repo.updateManagedCard(approved, expectedRevision: scheduled.revision,
                expectedContentRevision: before.contentRevision, origin: .manual)
            XCTFail("A stale source acknowledgement must not replay its content revision")
        } catch ReviewWCDBError.contentConflict {
            // Exact expected CAS rejection, not a generic unrelated failure.
        } catch {
            XCTFail("Expected contentConflict for stale source acknowledgement: \(error)")
        }
        let afterReplayEvents = try await repo.reviewHistory(for: cardID)
        XCTAssertEqual(afterReplayEvents.count, 1)
        XCTAssertFalse(ImVaultGuardedWrite.productionWriteEnabled)
    }

    /// ACCEPT-11 / G1: explicit "source change does not affect this card"
    /// must ask for one human consent, before any source/CAS mutation.
    /// The approved current source is synthetic and no device Vault is used.
    @MainActor
    func testSourceImpactUnaffectedFirstTapLocksBothDecisionsUntilConsent() async throws {
        let repo = try ReviewWCDBRepository(databasePath: temporaryPath(),
            calculator: FSRS6ReviewCalculator())
        let identity = try ImVaultFileIdentity(vaultID: UUID().uuidString,
            relativePath: "Synthetic/Impact.md")
        let before = Data("# Topic\nOld text\n".utf8)
        let changed = Data("# Topic\nAdditional unrelated text\n".utf8)
        let sourceKey = try ImpressBatchSourceKey.encode(identity,
            documentDigest: ImVaultDigest.sha256(before))
        let cardID = UUID()
        let now = Date(timeIntervalSince1970: 1_726_000_000)
        try await repo.insertNewCard(WCDBV3CardInput(cardID: cardID,
            question: "Existing original question",
            answerText: "Existing original answer",
            sourceNotePath: sourceKey),
            initial: try FSRS6ReviewCalculator().newCardSnapshot(id: cardID,
                now: now), now: now)
        let live = ImVaultRawDocument(identity: identity, sourceBytes: changed,
            markdown: "# Topic\nAdditional unrelated text\n",
            digest: ImVaultDigest.sha256(changed))
        let page = ImpressNoteSourceImpactController(document: live,
            cardID: cardID, previousDigest: ImVaultDigest.sha256(before),
            repository: repo)
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.rootViewController = UINavigationController(rootViewController: page)
        window.makeKeyAndVisible()
        defer {
            page.dismiss(animated: false)
            window.isHidden = true
        }
        page.loadViewIfNeeded()
        let unaffected = try XCTUnwrap(allSubviews(page.view)
            .compactMap { $0 as? UIButton }.first {
                $0.accessibilityIdentifier == "impress.notes.source-impact.unaffected"
            })
        let edit = try XCTUnwrap(allSubviews(page.view)
            .compactMap { $0 as? UIButton }.first {
                $0.accessibilityIdentifier == "impress.notes.source-impact.edit-original"
            })
        let loaded = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "enabled == true"), object: unaffected)
        await fulfillment(of: [loaded], timeout: 12)
        XCTAssertTrue(edit.isEnabled)
        unaffected.sendActions(for: .touchUpInside)
        XCTAssertFalse(unaffected.isEnabled,
            "First-tap consent must lock duplicate acknowledgments")
        XCTAssertFalse(edit.isEnabled,
            "A competing original-card editor cannot open during consent")
        let first = try XCTUnwrap(page.presentedViewController as? UIAlertController)
        XCTAssertEqual(first.title, V3L("确认不影响原卡？"))
        unaffected.sendActions(for: .touchUpInside)
        XCTAssertTrue(page.presentedViewController === first,
            "The same user action cannot queue a second sheet")
        XCTAssertEqual(first.actions.filter {
            $0.title == V3L("确认不影响")
        }.count, 1)
        let actualContent = try await repo.content(for: cardID)
        let persisted = try XCTUnwrap(actualContent)
        XCTAssertEqual(persisted.sourceNotePath, sourceKey,
            "No human confirmation means no source version acknowledgement")
        XCTAssertEqual(persisted.contentRevision, 0)
        let events = try await repo.reviewHistory(for: cardID)
        XCTAssertTrue(events.isEmpty)
        XCTAssertFalse(ImVaultGuardedWrite.productionWriteEnabled)
    }

    @MainActor
    func testSourceImpactRevisesOriginalCardWithFreshFSRSAndExactSource() async throws {
        let repo = try ReviewWCDBRepository(databasePath: temporaryPath(),
            calculator: FSRS6ReviewCalculator())
        let identity = try ImVaultFileIdentity(vaultID: UUID().uuidString,
            relativePath: "Study/Impact.md")
        let older = Data("# Law\nOld claim".utf8)
        let changed = Data("# Law\nCorrected claim".utf8)
        let originalKey = try ImpressBatchSourceKey.encode(identity,
            documentDigest: ImVaultDigest.sha256(older))
        let cardID = UUID(), now = Date(timeIntervalSince1970: 1_726_000_000)
        let initial = WCDBV3CardInput(cardID: cardID, question: "What is the law?",
            answerText: "Old", sourceNotePath: originalKey)
        try await repo.insertNewCard(initial,
            initial: try FSRS6ReviewCalculator().newCardSnapshot(id: cardID, now: now),
            now: now)
        let beforeRating = try await repo.fetchQueueCandidates()
        let start = try XCTUnwrap(beforeRating.first(where: { $0.cardID == cardID }))
        _ = try await repo.commit(ReviewSubmission(eventID: UUID(), cardID: cardID,
            expectedRevision: start.revision, rating: .good,
            reviewedAt: now.addingTimeInterval(2)))
        let doc = ImVaultRawDocument(identity: identity, sourceBytes: changed,
            markdown: "# Law\nCorrected claim", digest: ImVaultDigest.sha256(changed))
        let initialContent = try await repo.content(for: cardID)
        let content = try XCTUnwrap(initialContent)
        let approved = WCDBV3CardInput(cardID: cardID,
            question: "What is the law?", answerText: "Corrected",
            sourceNotePath: originalKey)
        let unchanged = WCDBV3CardInput(cardID: cardID,
            question: content.question, answerText: content.answerText,
            sourceNotePath: originalKey)
        XCTAssertThrowsError(try ImpressSourceImpactCardRevisionGate.refreshedInput(
            approved: unchanged, original: content, oldSourceKey: originalKey,
            currentNote: doc, expectedCurrentDigest: doc.digest))
        let input = try ImpressSourceImpactCardRevisionGate.refreshedInput(
            approved: approved, original: content, oldSourceKey: originalKey,
            currentNote: doc, expectedCurrentDigest: doc.digest)
        let afterRating = try await repo.fetchQueueCandidates()
        let review = try XCTUnwrap(afterRating.first(where: { $0.cardID == cardID }))
        try await repo.updateManagedCard(input, expectedRevision: review.revision,
            expectedContentRevision: content.contentRevision, origin: .manual)
        let persisted = try await repo.content(for: cardID)
        XCTAssertEqual(persisted?.cardID, cardID)
        XCTAssertEqual(persisted?.answerText, "Corrected")
        XCTAssertEqual(persisted?.contentRevision, content.contentRevision + 1)
        XCTAssertEqual(try ImpressBatchSourceKey.documentDigest(
            for: try XCTUnwrap(persisted?.sourceNotePath)), doc.digest)
        let finalQueue = try await repo.fetchQueueCandidates()
        let fsrs = try XCTUnwrap(finalQueue.first(where: { $0.cardID == cardID }))
        XCTAssertEqual(fsrs.revision, review.revision)
        XCTAssertEqual(fsrs.dueAt, review.dueAt)
        let events = try await repo.reviewHistory(for: cardID)
        XCTAssertEqual(events.count, 1)
        let wrongIdentity = try ImVaultFileIdentity(vaultID: "not-the-same-vault",
            relativePath: identity.relativePath)
        let fakeDoc = ImVaultRawDocument(identity: wrongIdentity,
            sourceBytes: changed, markdown: doc.markdown, digest: doc.digest)
        XCTAssertThrowsError(try ImpressSourceImpactCardRevisionGate.refreshedInput(
            approved: approved, original: content, oldSourceKey: originalKey,
            currentNote: fakeDoc, expectedCurrentDigest: doc.digest))
        XCTAssertThrowsError(try ImpressSourceImpactCardRevisionGate.refreshedInput(
            approved: approved, original: content, oldSourceKey: originalKey,
            currentNote: doc, expectedCurrentDigest: "stale-digest"))
    }


    @MainActor
    func testMarkdownMaterialRangesPreserveSourceUTF8AndRejectForgedOffsets() throws {
        let identity = try ImVaultFileIdentity(vaultID: "qa-structure",
            relativePath: "Notes/Mixed.md")
        let raw = "\u{FEFF}# Topic\r\n父节\r\n## 子节\r\n文本 🌿\n# Next\nA"
        let data = Data(raw.utf8)
        let digest = ImVaultDigest.sha256(data)
        let doc = ImVaultRawDocument(identity: identity,
            sourceBytes: data, markdown: raw, digest: digest)
        let sections = ImpressAISectionExtractor.sections(in: raw)
        XCTAssertEqual(sections.map(\.heading), ["Topic", "子节", "Next"])
        let selected = try XCTUnwrap(sections.first { $0.heading == "子节" })
        let ref = WCDBV3ChatContextReference(stableIdentity: "note:fixture",
            sourceRevision: digest, excerpt: selected.text,
            sourceStartUTF8: selected.startUTF8, sourceEndUTF8: selected.endUTF8,
            sourceFormat: "markdown")
        XCTAssertNoThrow(try ImpressChatNoteUploadGate.validate(
            document: doc, expectedIdentity: identity,
            expectedDigest: digest, conversationKey: "note:fixture", excerpts: [ref]))
        let wrongSpan = WCDBV3ChatContextReference(stableIdentity: "note:fixture",
            sourceRevision: digest, excerpt: selected.text,
            sourceStartUTF8: selected.startUTF8 + 1, sourceEndUTF8: selected.endUTF8,
            sourceFormat: "markdown")
        XCTAssertThrowsError(try ImpressChatNoteUploadGate.validate(
            document: doc, expectedIdentity: identity,
            expectedDigest: digest, conversationKey: "note:fixture",
            excerpts: [wrongSpan]))
        let halfSpan = WCDBV3ChatContextReference(stableIdentity: "note:fixture",
            sourceRevision: digest, excerpt: selected.text,
            sourceStartUTF8: selected.startUTF8, sourceEndUTF8: nil,
            sourceFormat: "markdown")
        XCTAssertThrowsError(try ImpressChatNoteUploadGate.validate(
            document: doc, expectedIdentity: identity,
            expectedDigest: digest, conversationKey: "note:fixture",
            excerpts: [halfSpan]))
        let effective = ImpressAISectionExtractor.effectiveSelection(sections,
            selectedIDs: Set(sections.map(\.id)))
        XCTAssertEqual(effective.map(\.heading), ["Topic", "Next"])
    }

    @MainActor
    func testChatNoteMaterialGateRejectsStaleForgedAndOversizedExcerpts() throws {
        let identity = try ImVaultFileIdentity(vaultID: "qa-vault",
            relativePath: "Lessons/Mechanics.md")
        let raw = "# Force\nNet force changes momentum.\n\n" +
            "# Practice\nSolve F = ma.\n"
        let bytes = Data(raw.utf8), digest = ImVaultDigest.sha256(bytes)
        let doc = ImVaultRawDocument(identity: identity,
            sourceBytes: bytes, markdown: raw, digest: digest)
        let chosen = try XCTUnwrap(ImpressAISectionExtractor.sections(in: raw).first)
        let key = "note:verified-qa-session"
        let trusted = WCDBV3ChatContextReference(stableIdentity: key,
            sourceRevision: digest, excerpt: chosen.text)
        XCTAssertNoThrow(try ImpressChatNoteUploadGate.validate(
            document: doc, expectedIdentity: identity,
            expectedDigest: digest, conversationKey: key, excerpts: [trusted]))
        let full = WCDBV3ChatContextReference(stableIdentity: key,
            sourceRevision: digest, excerpt: raw)
        XCTAssertNoThrow(try ImpressChatNoteUploadGate.validate(
            document: doc, expectedIdentity: identity,
            expectedDigest: digest, conversationKey: key, excerpts: [full]))
        XCTAssertThrowsError(try ImpressChatNoteUploadGate.validate(
            document: doc, expectedIdentity: identity,
            expectedDigest: nil, conversationKey: key, excerpts: [trusted]))
        XCTAssertThrowsError(try ImpressChatNoteUploadGate.validate(
            document: doc, expectedIdentity: identity,
            expectedDigest: String(repeating: "0", count: 64),
            conversationKey: key, excerpts: [trusted]))
        let wrongVault = try ImVaultFileIdentity(vaultID: "foreign",
            relativePath: identity.relativePath)
        XCTAssertThrowsError(try ImpressChatNoteUploadGate.validate(
            document: doc, expectedIdentity: wrongVault,
            expectedDigest: digest, conversationKey: key, excerpts: [trusted]))
        let stale = WCDBV3ChatContextReference(stableIdentity: key,
            sourceRevision: "old", excerpt: chosen.text)
        let foreignSession = WCDBV3ChatContextReference(stableIdentity: "another-chat",
            sourceRevision: digest, excerpt: chosen.text)
        let fabricated = WCDBV3ChatContextReference(stableIdentity: key,
            sourceRevision: digest, excerpt: "Made-up model-generated paragraph.")
        for ref in [stale, foreignSession, fabricated] {
            XCTAssertThrowsError(try ImpressChatNoteUploadGate.validate(
                document: doc, expectedIdentity: identity,
                expectedDigest: digest, conversationKey: key, excerpts: [ref]))
        }
        let oversized = WCDBV3ChatContextReference(stableIdentity: key,
            sourceRevision: digest,
            excerpt: String(repeating: "untrusted", count: 6_000))
        XCTAssertThrowsError(try ImpressChatNoteUploadGate.validate(
            document: doc, expectedIdentity: identity,
            expectedDigest: digest, conversationKey: key, excerpts: [oversized]))
        XCTAssertThrowsError(try ImpressChatNoteUploadGate.validate(
            document: doc, expectedIdentity: identity,
            expectedDigest: digest, conversationKey: key, excerpts: []))
    }

    @MainActor
    func testChatProviderSwitchRequiresConsentAfterFailedFirstAttempt() {
        let first = UUID(), second = UUID()
        let failed = WCDBV3ChatMessage(role: .user, text: "Prior message",
            status: .failed, providerID: first, modelIdentifier: "model-a")
        XCTAssertFalse(ImpressChatProviderConsentGate.needsReapproval(
            history: [], destination: second))
        XCTAssertFalse(ImpressChatProviderConsentGate.needsReapproval(
            history: [failed], destination: first))
        XCTAssertTrue(ImpressChatProviderConsentGate.needsReapproval(
            history: [failed], destination: second))
        let cancelled = WCDBV3ChatMessage(role: .user, text: "Stopped",
            status: .cancelled, providerID: second, modelIdentifier: "model-b")
        XCTAssertTrue(ImpressChatProviderConsentGate.needsReapproval(
            history: [failed, cancelled], destination: first))
        XCTAssertFalse(ImpressChatProviderConsentGate.needsReapproval(
            history: [failed, cancelled], destination: second))
    }


    @MainActor
    func testLongChatWarnsAboutRemoteWindowWithoutDiscardingLocalHistory() {
        let provider = UUID()
        let complete = (0..<18).map { index in
            WCDBV3ChatMessage(role: .user, text: "Turn \(index)",
                status: .completed, providerID: provider,
                modelIdentifier: "qa-model")
        }
        XCTAssertEqual(ImpressChatWindowPolicy.maximumPreviousTurns, 16)
        XCTAssertEqual(ImpressChatWindowPolicy.omittedCompletedCount(
            in: Array(complete.prefix(16))), 0)
        XCTAssertEqual(ImpressChatWindowPolicy.omittedCompletedCount(
            in: complete), 2)
        let failed = WCDBV3ChatMessage(role: .user, text: "Retry",
            status: .failed, providerID: provider,
            modelIdentifier: "qa-model")
        XCTAssertEqual(ImpressChatWindowPolicy.omittedCompletedCount(
            in: complete + [failed]), 2)
        // The bounded remote window is not a destructive truncation:
        // the full Chat session still retains all original message IDs.
        var session = WCDBV3ChatSession(sourceIdentity: "chat:window-qa")
        session.messages = complete + [failed]
        XCTAssertEqual(session.messages.count, 19)
        XCTAssertEqual(Set(session.messages.map(\.messageID)).count, 19)
    }

    /// Standalone disposable File Provider fixture for end-to-end Chat +
    /// original-card tests. Helpers in another XCTestCase are private and
    /// deliberately must not be referenced across class boundaries.
    private func createRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "ImpressDuplexFixture-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: root, withIntermediateDirectories: true)
        return root
    }

    private func put(_ content: String, root: URL,
                     path: String = "Notes/Topic.md") throws -> URL {
        let target = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(
            at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(content.utf8).write(to: target, options: .atomic)
        return target
    }

    private func temporaryPath() -> String {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("ImpressV3-" + UUID().uuidString, isDirectory: true)
        return folder.appendingPathComponent("v3.sqlite").path
    }

    func testRelatedCardsAcceptHistoricUnsortedJSONKeysWithoutCrossVaultLeak() async throws {
        let calc = FSRS6ReviewCalculator()
        let repo = try ReviewWCDBRepository(databasePath: temporaryPath(), calculator: calc)
        let source = try ImVaultFileIdentity(vaultID: "old-vault", relativePath: "A/Topic.md")
        let digest = String(repeating: "f", count: 64)
        let raw = #"{"vaultID":"old-vault","relativePath":"A/Topic.md"}"#
        let reversed = #"{"relativePath":"A/Topic.md","vaultID":"old-vault"}"#
        func originalKey(_ json: String, version: Int) -> String {
            let payload = Data(json.utf8).base64EncodedString()
                .replacingOccurrences(of: "+", with: "-")
                .replacingOccurrences(of: "/", with: "_")
                .replacingOccurrences(of: "=", with: "")
            return version == 1 ? "obsidian+v1:" + payload
                : "obsidian+v2:" + payload + ":" + digest
        }
        let keys = [originalKey(raw, version: 1), originalKey(reversed, version: 1),
                    originalKey(raw, version: 2), originalKey(reversed, version: 2)]
        let now = Date(timeIntervalSince1970: 1_726_000_000)
        var cardIDs = Set<UUID>()
        for (i, key) in keys.enumerated() {
            let card = WCDBV3CardInput(question: "Legacy serialization \(i)",
                answerText: "Reply \(i)", sourceNotePath: key)
            cardIDs.insert(card.cardID)
            try await repo.insertNewCard(card,
                initial: try calc.newCardSnapshot(id: card.cardID, now: now),
                now: now.addingTimeInterval(Double(i)))
        }
        let matching = try await repo.listRelatedCards(for: source)
        XCTAssertEqual(Set(matching.map(\.cardID)), cardIDs)
        let differentVault = try ImVaultFileIdentity(vaultID: "other",
                                                      relativePath: "A/Topic.md")
        let unrelated = try await repo.listRelatedCards(for: differentVault)
        XCTAssertTrue(unrelated.isEmpty)
    }

    func testVersionedNoteSourceLookupPreservesLegacyLinksAndSeparatesSameTitle() async throws {
        let calc = FSRS6ReviewCalculator()
        let repo = try ReviewWCDBRepository(databasePath: temporaryPath(), calculator: calc)
        let source = try ImVaultFileIdentity(vaultID: "vault-1", relativePath: "A/Same.md")
        let other = try ImVaultFileIdentity(vaultID: "vault-2", relativePath: "A/Same.md")
        let digest = String(repeating: "a", count: 64)
        let oldKey = try ImpressBatchSourceKey.encode(source)
        let newKey = try ImpressBatchSourceKey.encode(source, documentDigest: digest)
        let foreignKey = try ImpressBatchSourceKey.encode(other, documentDigest: digest)
        let now = Date(timeIntervalSince1970: 1_726_000_000)
        var ids: [UUID] = []
        for (index, key) in [oldKey, newKey, foreignKey].enumerated() {
            let card = WCDBV3CardInput(question: "Unique question \(index)",
                answerText: "Answer \(index)", sourceNotePath: key)
            ids.append(card.cardID)
            try await repo.insertNewCard(card,
                initial: try calc.newCardSnapshot(id: card.cardID, now: now),
                now: now.addingTimeInterval(Double(index)))
        }
        let related = try await repo.listRelatedCards(for: source)
        let unrelated = try await repo.listRelatedCards(for: other)
        XCTAssertEqual(Set(related.map(\.cardID)), Set(ids.prefix(2)))
        XCTAssertEqual(unrelated.map(\.cardID), [ids[2]])
        XCTAssertEqual(try ImpressBatchSourceKey.documentDigest(for: newKey), digest)
        XCTAssertNil(try ImpressBatchSourceKey.documentDigest(for: oldKey))
    }

    func testBidirectionalVaultLinksUseExactIdentityAndPreserveOriginalCard() async throws {
        let calculator = FSRS6ReviewCalculator()
        let repo = try ReviewWCDBRepository(databasePath: temporaryPath(), calculator: calculator)
        let a = try ImVaultFileIdentity(vaultID: "vault-alpha", relativePath: "Notes/Same.md")
        let b = try ImVaultFileIdentity(vaultID: "vault-beta", relativePath: "Notes/Same.md")
        let moved = try ImVaultFileIdentity(vaultID: "vault-alpha", relativePath: "Moved/Same.md")
        let id = UUID(), otherID = UUID()
        let aKey = try ImpressBatchSourceKey.encode(a)
        let bKey = try ImpressBatchSourceKey.encode(b)
        let date = Date(timeIntervalSince1970: 1_726_000_000)
        try await repo.insertNewCard(WCDBV3CardInput(cardID: id,
            question: "Same-title note in Alpha?", answerText: "Yes",
            sourceNotePath: aKey),
            initial: try calculator.newCardSnapshot(id: id, now: date), now: date)
        try await repo.insertNewCard(WCDBV3CardInput(cardID: otherID,
            question: "Same-title note in Beta?", answerText: "Yes",
            sourceNotePath: bKey),
            initial: try calculator.newCardSnapshot(id: otherID, now: date), now: date)

        let alphaCards = try await repo.listRelatedCards(for: a)
        XCTAssertEqual(alphaCards.map(\.cardID), [id])
        let betaCards = try await repo.listRelatedCards(for: b)
        XCTAssertEqual(betaCards.map(\.cardID), [otherID])
        let movedCards = try await repo.listRelatedCards(for: moved)
        XCTAssertTrue(movedCards.isEmpty,
                      "Moving a file must not silently relink by title")

        try await repo.updateManagedCard(WCDBV3CardInput(cardID: id,
            question: "Corrected Alpha note?", answerText: "Correct",
            sourceNotePath: aKey),
            expectedRevision: 0, expectedContentRevision: 0)
        let relatedAfterEdit = try await repo.listRelatedCards(for: a)
        XCTAssertEqual(relatedAfterEdit.first?.cardID, id)
        let contentAfterEdit = try await repo.content(for: id)
        XCTAssertEqual(contentAfterEdit?.contentRevision, 1)
        let historyAfterEdit = try await repo.reviewHistory(for: id)
        XCTAssertTrue(historyAfterEdit.isEmpty,
                      "Changing content must not create a review event")
        let revisionsAfterEdit = try await repo.contentHistory(for: id)
        XCTAssertEqual(revisionsAfterEdit.count, 2)
    }

    func testLinkedCardSearchIsLiteralAndPaginatesWithinSource() async throws {
        let calculator = FSRS6ReviewCalculator()
        let repo = try ReviewWCDBRepository(databasePath: temporaryPath(), calculator: calculator)
        let source = try ImVaultFileIdentity(vaultID: "a", relativePath: "Proof.md")
        let key = try ImpressBatchSourceKey.encode(source)
        let now = Date(timeIntervalSince1970: 1_726_000_000)
        for (index, question) in ["100% verified", "hello_underbar", "other"].enumerated() {
            let card = WCDBV3CardInput(question: question, answerText: "Answer",
                sourceNotePath: key)
            try await repo.insertNewCard(card,
                initial: try calculator.newCardSnapshot(id: card.cardID, now: now),
                now: now.addingTimeInterval(Double(index)))
        }
        let percentMatches = try await repo.listRelatedCards(for: source, matching: "%")
        XCTAssertEqual(percentMatches.count, 1)
        let underscoreMatches = try await repo.listRelatedCards(for: source, matching: "_")
        XCTAssertEqual(underscoreMatches.count, 1)
        let first = try await repo.listRelatedCards(for: source, offset: 0, limit: 2)
        let second = try await repo.listRelatedCards(for: source, offset: 2, limit: 2)
        XCTAssertEqual(Set((first + second).map(\.cardID)).count, 3)
    }

    @MainActor
    func testHistorySearchRestoresMatchedSessionContext() async throws {
        let repo = try ReviewWCDBRepository(databasePath: temporaryPath(),
            calculator: FSRS6ReviewCalculator())
        var a = WCDBV3ChatSession(sourceIdentity: "card:" + UUID().uuidString)
        var b = WCDBV3ChatSession(sourceIdentity: "note:another-vault")
        a.messages = [WCDBV3ChatMessage(role: .user, text: "Talk about momentum",
            status: .completed)]
        let target = WCDBV3ChatMessage(role: .assistant,
            text: "Unique memory consolidation finding",
            status: .completed)
        b.messages = [WCDBV3ChatMessage(role: .user, text: "Review other note",
            status: .completed), target]
        b.promptOverride = "One local prompt"
        b.sourceDisplayName = "Research/Concepts/Thought.md"
        b.inputDraft = "A completely separate draft"
        try await repo.saveChatSession(a, expectedRevision: nil)
        try await repo.saveChatSession(b, expectedRevision: nil)
        let history = ImpressChatSessionHistoryViewController(
            sessions: try await repo.allChatSessions(),
            currentSessionID: a.sessionID, repository: repo)
        history.loadViewIfNeeded()
        let search = try XCTUnwrap(history.navigationItem.searchController)
        search.searchBar.text = "consolidation"
        history.updateSearchResults(for: search)
        XCTAssertEqual(history.tableView(history.tableView, numberOfRowsInSection: 0), 1)
        var selected: UUID?
        var selectedMessage: UUID?
        history.onSelect = { id, messageID in
            selected = id
            selectedMessage = messageID
        }
        history.tableView(history.tableView,
            didSelectRowAt: IndexPath(row: 0, section: 0))
        XCTAssertEqual(selected, b.sessionID)
        XCTAssertEqual(selectedMessage, target.messageID)
        search.searchBar.text = "Thought.md"
        history.updateSearchResults(for: search)
        XCTAssertEqual(history.tableView(history.tableView, numberOfRowsInSection: 0), 1)
    }

    @MainActor
    func testNativeCanvasRendersTrueCoordinatesAndSelectsOnlyTappedNode() throws {
        let json = """
        {"nodes":[
          {"id":"g","type":"group","x":-30,"y":10,"width":480,"height":340,"label":"Group"},
          {"id":"a","type":"text","x":0,"y":40,"width":140,"height":90,"text":"A"},
          {"id":"b","type":"text","x":200,"y":40,"width":140,"height":90,"text":"B"}],
         "edges":[{"id":"e","fromNode":"a","toNode":"b","label":"relates"}]}
        """
        let data = Data(json.utf8)
        let model = try ImpressCanvasDocument.parse(data)
        let visual = try ImpressCanvasNativeView(source: model)
        visual.frame = CGRect(x: 0, y: 0, width: 390, height: 650)
        visual.layoutIfNeeded()
        func buttons(in root: UIView) -> [UIButton] {
            let item = (root as? UIButton).map { [$0] } ?? []
            return item + root.subviews.flatMap { buttons(in: $0) }
        }
        let all = buttons(in: visual)
        let a = try XCTUnwrap(all.first(where: {
            $0.accessibilityIdentifier == "impress.canvas.node.a"
        }))
        let b = try XCTUnwrap(all.first(where: {
            $0.accessibilityIdentifier == "impress.canvas.node.b"
        }))
        XCTAssertEqual(b.frame.minX - a.frame.minX, 200, accuracy: 0.1)
        XCTAssertTrue(visual.selectedIDs.isEmpty)
        a.sendActions(for: .touchUpInside)
        XCTAssertEqual(visual.selectedIDs, ["a"])
        XCTAssertEqual(a.accessibilityValue, V3L("已选择"))
        XCTAssertNotEqual(b.accessibilityValue, V3L("已选择"))
        a.sendActions(for: .touchUpInside)
        XCTAssertTrue(visual.selectedIDs.isEmpty)

        let identity = try ImVaultFileIdentity(vaultID: "qa-canvas",
            relativePath: "Study/Diagram.canvas")
        let original = ImVaultRawDocument(identity: identity, sourceBytes: data,
            markdown: json, digest: ImVaultDigest.sha256(data))
        let notePage = ImVaultDocumentController(document: original)
        notePage.loadViewIfNeeded()
        func descendants(_ root: UIView) -> [UIView] {
            [root] + root.subviews.flatMap { descendants($0) }
        }
        XCTAssertNotNil(descendants(notePage.view).first(where: {
            $0.accessibilityIdentifier == "impress.canvas.native-viewport"
        }))
        XCTAssertFalse(ImVaultGuardedWrite.productionWriteEnabled)
    }

    @MainActor
    func testScopedAIDraftChangesExactSectionButPreservesOtherBytes() throws {
        let base = "\u{FEFF}# 上层\r\n保留前文\r\n## Section\r\n原始内容 🌱\r\n# Ending\r\nKeep"
        let identity = try ImVaultFileIdentity(vaultID: "qa-section",
            relativePath: "Knowledge/Mixed.md")
        let source = Data(base.utf8)
        // The real Vault reader returns Foundation's BOM-stripped UTF-8
        // projection while retaining the exact BOM in sourceBytes.
        let readerText = try XCTUnwrap(String(data: source, encoding: .utf8))
        XCTAssertFalse(readerText.hasPrefix("\u{FEFF}"))
        let live = ImVaultRawDocument(identity: identity,
            sourceBytes: source, markdown: readerText,
            digest: ImVaultDigest.sha256(source))
        let parts = ImpressMarkdownStructure.sections(in: readerText)
        let scoped = try XCTUnwrap(parts.first(where: { $0.heading == "Section" }))
        let draft = try ImpressDuplexScopedDraftBuilder.proposed(
            live: live, section: scoped, replacement: "## Section\r\n更新的候选解释 🌱\r\n")
        XCTAssertTrue(draft.hasChanges)
        XCTAssertEqual(draft.identity, identity)
        XCTAssertEqual(draft.baseRawData, source)
        XCTAssertEqual(draft.baseDigest, live.digest)
        let modified = String(decoding: draft.proposedBytes, as: UTF8.self)
        XCTAssertTrue(modified.hasPrefix("\u{FEFF}# 上层\r\n保留前文\r\n"))
        XCTAssertEqual(modified, draft.byteFaithfulEditedText)
        XCTAssertEqual(draft.byteFaithfulBaseText, base)
        XCTAssertTrue(modified.contains("## Section\r\n更新的候选解释 🌱\r\n"))
        XCTAssertTrue(modified.hasSuffix("# Ending\r\nKeep"))
        XCTAssertFalse(modified.contains("原始内容"))
        XCTAssertTrue(ImVaultDiff.summary(base: draft.baseText,
            edited: draft.editedText, maximumLines: 200).complete)
        XCTAssertFalse(ImVaultGuardedWrite.productionWriteEnabled)
    }

    @MainActor
    func testScopedAIDraftRejectsStaleSourceAndNonMarkdownIdentity() throws {
        let body = "# Target\nOriginal\n# Unrelated\nUntouched"
        let original = Data(body.utf8)
        let id = try ImVaultFileIdentity(vaultID: "qa-target",
            relativePath: "Notes/Original.md")
        let selection = try XCTUnwrap(ImpressMarkdownStructure.sections(in: body).first)
        let changed = body.replacingOccurrences(of: "Original", with: "Later")
        let updated = Data(changed.utf8)
        let stale = ImVaultRawDocument(identity: id,
            sourceBytes: updated, markdown: changed,
            digest: ImVaultDigest.sha256(updated))
        XCTAssertThrowsError(try ImpressDuplexScopedDraftBuilder.proposed(
            live: stale, section: selection, replacement: "# Target\nSuggestion\n"))
        let valid = ImVaultRawDocument(identity: id,
            sourceBytes: original, markdown: body,
            digest: ImVaultDigest.sha256(original))
        XCTAssertThrowsError(try ImpressDuplexScopedDraftBuilder.proposed(
            live: valid, section: selection, replacement: selection.rawUTF8))
        let canvasID = try ImVaultFileIdentity(vaultID: "qa-target",
            relativePath: "Notes/Graph.canvas")
        let invalid = ImVaultRawDocument(identity: canvasID,
            sourceBytes: original, markdown: body,
            digest: ImVaultDigest.sha256(original))
        XCTAssertThrowsError(try ImpressDuplexScopedDraftBuilder.proposed(
            live: invalid, section: selection, replacement: "Not an authorized edit"))
    }

    @MainActor
    func testSelectedAIReplyOffersEditableCardSuggestionWithoutAutoApplying() async throws {
        let repo = try ReviewWCDBRepository(databasePath: temporaryPath(),
            calculator: FSRS6ReviewCalculator())
        let cardID = UUID()
        let now = Date()
        try await repo.insertNewCard(WCDBV3CardInput(
            cardID: cardID, question: "Original question",
            answerText: "Original answer"),
            initial: FSRS6ReviewCalculator().newCardSnapshot(id: cardID, now: now),
            now: now)
        let suggestion = "A revised explanation from the selected completed AI reply."
        let editor = ImpressDuplexChangeController(repository: repo,
            cardID: cardID, sourceContentRevision: 0, noteIdentity: nil,
            sourceMessageID: UUID(), pending: nil,
            suggestedText: suggestion) { _ in
                XCTFail("Opening an AI suggestion must not persist a proposal")
                return false
            }
        editor.loadViewIfNeeded()
        func views(_ root: UIView) -> [UIView] {
            [root] + root.subviews.flatMap { views($0) }
        }
        let proposal = try XCTUnwrap(views(editor.view).compactMap {
            $0 as? UITextView
        }.first(where: {
            $0.accessibilityIdentifier == "impress.duplex.assistant-suggestion"
        }))
        XCTAssertFalse(proposal.isEditable)
        XCTAssertEqual(proposal.text, suggestion)
        let button = try XCTUnwrap(views(editor.view).compactMap {
            $0 as? UIButton
        }.first(where: { $0.accessibilityIdentifier == "impress.duplex.use-suggestion" }))
        let answer = try XCTUnwrap(views(editor.view).compactMap {
            $0 as? UITextView
        }.first(where: { $0.accessibilityIdentifier == "impress.duplex.answer" }))
        for _ in 0..<80 where !button.isEnabled {
            try await Task.sleep(for: .milliseconds(25))
        }
        XCTAssertTrue(button.isEnabled)
        XCTAssertEqual(answer.text, "Original answer")
        let beforeAdopting = try await repo.content(for: cardID)
        XCTAssertEqual(beforeAdopting?.answerText, "Original answer")
        button.sendActions(for: .touchUpInside)
        XCTAssertEqual(answer.text, suggestion)
        let persisted = try await repo.content(for: cardID)
        XCTAssertEqual(persisted?.answerText, "Original answer")
        let events = try await repo.reviewHistory(for: cardID)
        XCTAssertTrue(events.isEmpty)
    }


    @MainActor
    func testExcalidrawNativeDrawingAndChatGateKeepOnlyApprovedElements() throws {
        let raw = """
        {"type":"excalidraw","elements":[
          {"id":"f","type":"frame","x":-20,"y":0,"width":350,"height":210},
          {"id":"a","type":"rectangle","x":5,"y":15,"width":90,"height":55,
           "groupIds":["g"],"frameId":"f"},
          {"id":"b","type":"text","x":190,"y":15,"width":100,"height":55,
           "text":"NOT approved","groupIds":["g"],"frameId":"f"}]}
        """
        let identity = try ImVaultFileIdentity(vaultID: "qa-drawing",
            relativePath: "Study/Sketch.excalidraw")
        let bytes = Data(raw.utf8)
        let digest = ImVaultDigest.sha256(bytes)
        let live = ImVaultRawDocument(identity: identity,
            sourceBytes: bytes, markdown: raw, digest: digest)
        let scene = try ImpressExcalidrawScene.parse(bytes,
            format: .excalidrawJSON)
        let visual = try ImpressExcalidrawNativeView(source: scene)
        visual.frame = CGRect(x: 0, y: 0, width: 390, height: 650)
        visual.layoutIfNeeded()
        func buttons(in root: UIView) -> [UIButton] {
            let own = (root as? UIButton).map { [$0] } ?? []
            return own + root.subviews.flatMap { buttons(in: $0) }
        }
        let all = buttons(in: visual)
        let a = try XCTUnwrap(all.first {
            $0.accessibilityIdentifier == "impress.excalidraw.element.a"
        })
        let b = try XCTUnwrap(all.first {
            $0.accessibilityIdentifier == "impress.excalidraw.element.b"
        })
        XCTAssertEqual(b.frame.minX - a.frame.minX, 185, accuracy: 0.1)
        a.sendActions(for: .touchUpInside)
        XCTAssertEqual(visual.selectedIDs, ["a"])
        XCTAssertEqual(a.accessibilityValue, V3L("已选择"))
        XCTAssertNotEqual(b.accessibilityValue, V3L("已选择"))
        let selected = try scene.selection(ids: visual.selectedIDs)
        let excerpt = try selected.textContextJSON()
        XCTAssertFalse(excerpt.contains("NOT approved"))
        let key = "note:drawing-qa"
        let reference = WCDBV3ChatContextReference(
            stableIdentity: key, sourceRevision: digest,
            excerpt: excerpt, sourceFormat: "excalidraw-structure",
            selectedCanvasNodeIDs: ["a"])
        XCTAssertNoThrow(try ImpressChatNoteUploadGate.validate(
            document: live, expectedIdentity: identity,
            expectedDigest: digest, conversationKey: key,
            excerpts: [reference]))
        let switched = WCDBV3ChatContextReference(
            stableIdentity: key, sourceRevision: digest,
            excerpt: excerpt, sourceFormat: "excalidraw-structure",
            selectedCanvasNodeIDs: ["b"])
        XCTAssertThrowsError(try ImpressChatNoteUploadGate.validate(
            document: live, expectedIdentity: identity,
            expectedDigest: digest, conversationKey: key,
            excerpts: [switched]))
        XCTAssertThrowsError(try ImpressChatNoteUploadGate.validate(
            document: live, expectedIdentity: identity,
            expectedDigest: "old-source", conversationKey: key,
            excerpts: [reference]))
        let page = ImVaultDocumentController(document: live)
        page.loadViewIfNeeded()
        func descendants(_ view: UIView) -> [UIView] {
            [view] + view.subviews.flatMap { descendants($0) }
        }
        XCTAssertNotNil(descendants(page.view).first {
            $0.accessibilityIdentifier == "impress.excalidraw.native-viewport"
        })
        XCTAssertFalse(ImVaultGuardedWrite.productionWriteEnabled)
    }

    @MainActor
    func testExcalidrawExplicitFullAndSpatialRangeCannotLeakOtherElement() throws {
        let json = """
        {"type":"excalidraw","elements":[
          {"id":"a","type":"rectangle","x":0,"y":0,"width":90,"height":70},
          {"id":"secret","type":"text","x":350,"y":0,"width":100,"height":70,
           "text":"Unapproved source"}]}
        """
        let scene = try ImpressExcalidrawScene.parse(Data(json.utf8),
            format: .excalidrawJSON)
        let viewport = try ImpressExcalidrawNativeView(source: scene)
        let a = try XCTUnwrap(viewport.subviews.flatMap { $0.subviews }
            .compactMap { $0 as? UIButton }.first {
                $0.accessibilityIdentifier == "impress.excalidraw.element.a"
            })
        let near = CGRect(x: a.frame.midX - 30, y: a.frame.midY - 30,
            width: 60, height: 60)
        viewport.selectElements(in: near)
        XCTAssertEqual(viewport.selectedIDs, ["a"])
        let preview = try scene.selection(ids: viewport.selectedIDs).textContextJSON()
        XCTAssertFalse(preview.contains("Unapproved source"))
        viewport.selectAllActive()
        XCTAssertEqual(viewport.selectedIDs, Set(["a", "secret"]))
        viewport.clearSelections()
        XCTAssertTrue(viewport.selectedIDs.isEmpty)
        XCTAssertFalse(ImVaultGuardedWrite.productionWriteEnabled)
    }

    @MainActor
    func testExcalidrawEmbeddedPNGDisplaysLocallyWithoutTransmittingPixels() throws {
        let raster = UIGraphicsImageRenderer(size: CGSize(width: 2, height: 2))
            .image { context in
                UIColor.systemRed.setFill()
                context.fill(CGRect(x: 0, y: 0, width: 2, height: 2))
            }
        let imageData = try XCTUnwrap(raster.pngData())
        let raw = """
        {"type":"excalidraw",
         "elements":[{"id":"picture","type":"image","x":0,"y":0,
                      "width":100,"height":100,"fileId":"file"}],
         "files":{"file":{"mimeType":"image/png","id":"file",
                            "dataURL":"data:image/png;base64,\(imageData.base64EncodedString())"}}}
        """
        let scene = try ImpressExcalidrawScene.parse(Data(raw.utf8),
            format: .excalidrawJSON)
        let visual = try ImpressExcalidrawNativeView(source: scene)
        func descendants(_ view: UIView) -> [UIView] {
            [view] + view.subviews.flatMap { descendants($0) }
        }
        XCTAssertTrue(descendants(visual).contains { $0 is UIImageView })
        let excerpt = try scene.selection(ids: ["picture"]).textContextJSON()
        XCTAssertFalse(excerpt.contains("data:image"))
        XCTAssertTrue(excerpt.contains("fileId"))
        XCTAssertFalse(ImVaultGuardedWrite.productionWriteEnabled)
    }


    @MainActor
    func testMermaidAndMarkmapScopedChatMaterialsDoNotLeakUnselectedBranches() throws {
        let markdown = """
        # 上层知识
        ## A
        Alpha
        ## B
        Private sibling
        ```mermaid
        flowchart LR
        X[Allowed] --> Y[Selected]
        Z[Private branch]
        ```
        """
        let bytes = Data(markdown.utf8)
        let digest = ImVaultDigest.sha256(bytes)
        let identity = try ImVaultFileIdentity(vaultID: "fixture-only",
            relativePath: "Notes/Diagram.md")
        let raw = ImVaultRawDocument(identity: identity, sourceBytes: bytes,
            markdown: markdown, digest: digest)
        let diagram = try XCTUnwrap(ImpressDiagramDocument.mermaidBlocks(in: bytes).first)
        let selected = try diagram.selection(ids: [diagram.nodes[0].id])
        let key = "note:diagram-test"
        let accepted = WCDBV3ChatContextReference(stableIdentity: key,
            sourceRevision: digest, excerpt: try selected.contextJSON(),
            sourceStartUTF8: diagram.startUTF8, sourceEndUTF8: diagram.endUTF8,
            sourceFormat: "mermaid-structure", selectedCanvasNodeIDs: selected.ids)
        XCTAssertNoThrow(try ImpressChatNoteUploadGate.validate(
            document: raw, expectedIdentity: identity,
            expectedDigest: digest, conversationKey: key, excerpts: [accepted]))
        XCTAssertFalse(accepted.excerpt.contains("Private branch"))
        let changed = WCDBV3ChatContextReference(stableIdentity: key,
            sourceRevision: digest, excerpt: accepted.excerpt,
            sourceStartUTF8: diagram.startUTF8, sourceEndUTF8: diagram.endUTF8,
            sourceFormat: "mermaid-structure",
            selectedCanvasNodeIDs: [diagram.nodes[1].id])
        XCTAssertThrowsError(try ImpressChatNoteUploadGate.validate(
            document: raw, expectedIdentity: identity,
            expectedDigest: digest, conversationKey: key, excerpts: [changed]))
        let outline = try ImpressDiagramDocument.markmap(in: bytes)
        let root = try XCTUnwrap(outline.nodes.first)
        let context = try outline.selection(ids: [root.id])
        let linked = WCDBV3ChatContextReference(stableIdentity: key,
            sourceRevision: digest, excerpt: try context.contextJSON(),
            sourceStartUTF8: 0, sourceEndUTF8: bytes.count,
            sourceFormat: "markmap-structure", selectedCanvasNodeIDs: context.ids)
        XCTAssertNoThrow(try ImpressChatNoteUploadGate.validate(
            document: raw, expectedIdentity: identity,
            expectedDigest: digest, conversationKey: key, excerpts: [linked]))
        XCTAssertFalse(linked.excerpt.contains("Private sibling"))
        XCTAssertThrowsError(try ImpressChatNoteUploadGate.validate(
            document: raw, expectedIdentity: identity,
            expectedDigest: "outdated-sha", conversationKey: key, excerpts: [linked]))
    }

    @MainActor
    func testCanvasChatScopeCannotSubstituteUnselectedNodeOrOldRevision() throws {
        let json = """
        {"nodes":[
          {"id":"a","type":"text","x":0,"y":0,"width":160,"height":100,"text":"Approved"},
          {"id":"b","type":"text","x":250,"y":0,"width":160,"height":100,"text":"Private"}]}
        """
        let identity = try ImVaultFileIdentity(vaultID: "qa-canvas",
            relativePath: "Notes/Source.canvas")
        let bytes = Data(json.utf8)
        let digest = ImVaultDigest.sha256(bytes)
        let document = ImVaultRawDocument(identity: identity,
            sourceBytes: bytes, markdown: json, digest: digest)
        let parsed = try ImpressCanvasDocument.parse(bytes)
        let selected = try parsed.selection(nodeIDs: ["a"])
        let excerpt = try selected.serializedJSON()
        let key = "note:canvas-qa"
        let trusted = WCDBV3ChatContextReference(
            stableIdentity: key, sourceRevision: digest,
            excerpt: excerpt, sourceFormat: "json-canvas",
            selectedCanvasNodeIDs: ["a"])
        XCTAssertNoThrow(try ImpressChatNoteUploadGate.validate(
            document: document, expectedIdentity: identity,
            expectedDigest: digest, conversationKey: key,
            excerpts: [trusted]))
        XCTAssertFalse(excerpt.contains("Private"))

        let wrongNode = WCDBV3ChatContextReference(
            stableIdentity: key, sourceRevision: digest,
            excerpt: excerpt, sourceFormat: "json-canvas",
            selectedCanvasNodeIDs: ["b"])
        XCTAssertThrowsError(try ImpressChatNoteUploadGate.validate(
            document: document, expectedIdentity: identity,
            expectedDigest: digest, conversationKey: key,
            excerpts: [wrongNode]))
        let forged = WCDBV3ChatContextReference(
            stableIdentity: key, sourceRevision: digest,
            excerpt: excerpt + "\nPrivate", sourceFormat: "json-canvas",
            selectedCanvasNodeIDs: ["a"])
        XCTAssertThrowsError(try ImpressChatNoteUploadGate.validate(
            document: document, expectedIdentity: identity,
            expectedDigest: digest, conversationKey: key,
            excerpts: [forged]))
        XCTAssertThrowsError(try ImpressChatNoteUploadGate.validate(
            document: document, expectedIdentity: identity,
            expectedDigest: "stale-version", conversationKey: key,
            excerpts: [trusted]))
    }

    func testCompositeFilesRemainReadableButNeverEnterGenericWriteFlow() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "Impress-Composite-QA-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let specimens: [(String, String)] = [
            ("Drawing.excalidraw.md", "---\nexcalidraw-plugin: parsed\n---\n# Drawing\n"),
            ("Drawing.excalidraw", "{\"type\":\"excalidraw\",\"elements\":[]}"),
            ("Diagram.canvas", "{\"nodes\":[],\"edges\":[]}")
        ]
        for (name, raw) in specimens {
            let file = root.appendingPathComponent(name)
            let original = Data(raw.utf8)
            try original.write(to: file)
            let identity = try ImVaultFileIdentity(vaultID: "test-only",
                relativePath: name)
            let read = try ImVaultReadSync.load(root: root, identity: identity)
            XCTAssertEqual(read.sourceBytes, original)
            XCTAssertEqual(read.identity, identity)
            // Read enablement MUST NOT allow even constructing a generic
            // Markdown draft; the production write gate remains closed.
            XCTAssertThrowsError(try ImVaultDraft(identity: identity,
                baseText: raw, baseRawData: original))
            XCTAssertEqual(try Data(contentsOf: file), original)
        }
        let list = try ImVaultReadSync.list(root: root, vaultID: "test-only")
        XCTAssertEqual(list.count, specimens.count)
        XCTAssertEqual(Set(list.map { $0.identity.relativePath }),
                       Set(specimens.map { $0.0 }))
        XCTAssertFalse(ImVaultGuardedWrite.productionWriteEnabled)
    }

    func testDeleteConversationPreservesAppliedReceiptsAndDoesNotResurrect() async throws {
        let repo = try ReviewWCDBRepository(databasePath: temporaryPath(),
            calculator: FSRS6ReviewCalculator())
        var discussion = WCDBV3ChatSession(sourceIdentity: "card:" + UUID().uuidString)
        discussion.messages = [
            WCDBV3ChatMessage(role: .user, text: "How does this work?",
                status: .completed),
            WCDBV3ChatMessage(role: .assistant, text: "Verified explanation.",
                status: .completed)
        ]
        discussion.inputDraft = "Unsent private text"
        discussion.contextReferences = [
            WCDBV3ChatContextReference(stableIdentity: discussion.sourceIdentity,
                sourceRevision: "rev1", excerpt: "User-selected excerpt")
        ]
        var done = WCDBV3DuplexProposal(sourceMessageID: discussion.messages.last?.messageID,
            noteIdentity: nil, noteBaseDigest: nil, noteEditedDigest: nil,
            cardID: UUID(), cardReviewRevision: 0, cardContentRevision: 0,
            cardBaseQuestion: "Q", cardBaseAnswer: "A",
            cardEditedQuestion: "Improved Q", cardEditedAnswer: "Improved A",
            state: ImDuplexApprovalState(noteSelected: false, cardSelected: true,
                cardStatus: .applied))
        done.cardReceipt = "Exact original card updated and reread"
        discussion.duplexHistory = [done]
        try await repo.saveChatSession(discussion, expectedRevision: nil)
        let allBefore = try await repo.allChatSessions()
        XCTAssertEqual(allBefore.count, 1)
        try await repo.deleteChatSession(discussion.sessionID, expectedRevision: 0)
        let allAfter = try await repo.allChatSessions()
        XCTAssertTrue(allAfter.isEmpty)
        let sourceAfter = try await repo.chatSessions(for: discussion.sourceIdentity)
        XCTAssertTrue(sourceAfter.isEmpty)
        let receipts = try await repo.retainedChatReceipts()
        XCTAssertEqual(receipts.count, 1)
        XCTAssertTrue(receipts[0].messages.isEmpty)
        XCTAssertTrue(receipts[0].inputDraft.isEmpty)
        XCTAssertTrue(receipts[0].contextReferences.isEmpty)
        XCTAssertEqual(receipts[0].duplexHistory?.first?.cardReceipt, done.cardReceipt)
        XCTAssertTrue(receipts[0].isDeleted == true)
        XCTAssertEqual(receipts[0].sourceIdentity,
                       "deleted:" + discussion.sessionID.uuidString,
                       "The tombstone must not retain its original source identity")
        discussion.inputDraft = "Delayed callback must never re-create this discussion"
        discussion.updatedAt = Date()
        discussion.revision = 1
        do {
            try await repo.saveChatSession(discussion, expectedRevision: 0)
            XCTFail("An async draft save must never resurrect a deleted row")
        } catch WCDBV3ChatStorageError.conflict { }
        let allAfterResurrectionAttempt = try await repo.allChatSessions()
        XCTAssertTrue(allAfterResurrectionAttempt.isEmpty)

        var inFlight = WCDBV3ChatSession(sourceIdentity: "card:" + UUID().uuidString)
        inFlight.pendingDuplex = WCDBV3DuplexProposal(
            sourceMessageID: nil, noteIdentity: nil,
            noteBaseDigest: nil, noteEditedDigest: nil,
            cardID: UUID(), cardReviewRevision: 0, cardContentRevision: 0,
            cardBaseQuestion: "Original", cardBaseAnswer: "Original",
            cardEditedQuestion: "Changed", cardEditedAnswer: "Changed",
            state: ImDuplexApprovalState(noteSelected: false, cardSelected: true,
                cardStatus: .applying))
        try await repo.saveChatSession(inFlight, expectedRevision: nil)
        do {
            try await repo.deleteChatSession(inFlight.sessionID, expectedRevision: 0)
            XCTFail("Unknown in-flight content write must be reconciled")
        } catch WCDBV3ChatStorageError.unsafeDeletion { }
    }

    /// F13: a rejected proposal's failure explanation is not an executed
    /// write receipt. After deletion, preserve only independently applied
    /// targets: the failed other target's private draft must not enter ZIP.
    func testF13FailedReceiptAndMixedApprovalRetainOnlyExecutedAudit() async throws {
        let repository = try ReviewWCDBRepository(
            databasePath: temporaryPath(), calculator: FSRS6ReviewCalculator())

        var rejected = WCDBV3ChatSession(sourceIdentity: "note:synthetic/Rejected.md")
        rejected.inputDraft = "Synthetic unapproved private discussion"
        var failed = WCDBV3DuplexProposal(
            sourceMessageID: UUID(), noteIdentity: nil,
            noteBaseDigest: nil, noteEditedDigest: nil,
            cardID: UUID(), cardReviewRevision: 0, cardContentRevision: 0,
            cardBaseQuestion: "Private unapproved original",
            cardBaseAnswer: "Private unapproved answer",
            cardEditedQuestion: "Rejected AI suggestion",
            cardEditedAnswer: "Never written",
            state: ImDuplexApprovalState(
                noteSelected: false, cardSelected: true, cardStatus: .failed))
        failed.cardReceipt = "Synthetic card failure; no content was applied"
        rejected.pendingDuplex = failed
        try await repository.saveChatSession(rejected, expectedRevision: nil)
        try await repository.deleteChatSession(rejected.sessionID, expectedRevision: 0)
        let allDeleted = try await repository.allChatSessions(includeDeleted: true)
        let rejectedTombstone = try XCTUnwrap(
            allDeleted.first(where: { $0.sessionID == rejected.sessionID }))
        XCTAssertTrue(rejectedTombstone.isDeleted == true)
        XCTAssertTrue((rejectedTombstone.duplexHistory ?? []).isEmpty)
        XCTAssertNil(rejectedTombstone.pendingDuplex)
        let noExecutedReceipts = try await repository.retainedChatReceipts()
        XCTAssertTrue(noExecutedReceipts.isEmpty)

        let identity = try ImVaultFileIdentity(
            vaultID: UUID().uuidString, relativePath: "Synthetic/Approved.md")
        let noteReceipt = "Approved synthetic note read back and verified"
        let rejectedCard = "Private card draft that was never approved"
        var partial = WCDBV3ChatSession(sourceIdentity: "note:synthetic/Mixed.md")
        partial.inputDraft = "Synthetic private discussion to delete"
        var mixed = WCDBV3DuplexProposal(
            sourceMessageID: UUID(), noteIdentity: identity,
            noteBaseDigest: String(repeating: "a", count: 64),
            noteEditedDigest: String(repeating: "b", count: 64),
            cardID: UUID(), cardReviewRevision: 2, cardContentRevision: 4,
            cardBaseQuestion: "Unapproved card original",
            cardBaseAnswer: "Unapproved answer",
            cardEditedQuestion: rejectedCard,
            cardEditedAnswer: "Unapproved revised answer",
            state: ImDuplexApprovalState(
                noteSelected: true, cardSelected: false,
                noteStatus: .applied, cardStatus: .failed))
        mixed.noteReceipt = noteReceipt
        mixed.cardReceipt = "Synthetic card conflict; no card was written"
        partial.pendingDuplex = mixed
        try await repository.saveChatSession(partial, expectedRevision: nil)
        try await repository.deleteChatSession(partial.sessionID, expectedRevision: 0)

        let audited = try await repository.retainedChatReceipts()
        XCTAssertEqual(audited.count, 1)
        let auditSession = try XCTUnwrap(audited.first)
        XCTAssertEqual(auditSession.sessionID, partial.sessionID)
        XCTAssertEqual(auditSession.sourceIdentity,
                       "deleted:" + partial.sessionID.uuidString)
        XCTAssertTrue(auditSession.messages.isEmpty)
        XCTAssertTrue(auditSession.inputDraft.isEmpty)
        XCTAssertNil(auditSession.pendingDuplex)
        let audit = try XCTUnwrap(auditSession.duplexHistory?.first)
        XCTAssertEqual(audit.proposalID, mixed.proposalID)
        XCTAssertEqual(audit.state.noteStatus, .applied)
        XCTAssertEqual(audit.noteIdentity, identity)
        XCTAssertEqual(audit.noteReceipt, noteReceipt)
        XCTAssertFalse(audit.state.cardSelected)
        XCTAssertNil(audit.sourceMessageID)
        XCTAssertNil(audit.cardID)
        XCTAssertNil(audit.cardBaseQuestion)
        XCTAssertNil(audit.cardBaseAnswer)
        XCTAssertNil(audit.cardEditedQuestion)
        XCTAssertNil(audit.cardEditedAnswer)
        XCTAssertNil(audit.cardReceipt)
        XCTAssertFalse(ImVaultGuardedWrite.productionWriteEnabled)
    }

    /// F13/F12: a real SQLite tombstone is included in the normal ZIP archive,
    /// not a substitute in-memory object. Restoring that archive may not revive
    /// the deleted discussion, expose a synthetic private display name, or
    /// discard the audit receipt for a previously applied original-card edit.
    func testF13DeletedChatTombstoneSurvivesZIPRestoreWithoutPrivateDisplayTitle() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("Impress-F13-restore-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let calculator = FSRS6ReviewCalculator()
        let repository = try ReviewWCDBRepository(
            databasePath: root.appendingPathComponent("live.sqlite").path,
            calculator: calculator)
        var session = WCDBV3ChatSession(sourceIdentity: "note:synthetic/F13-source.md")
        session.sourceDisplayName = "Synthetic confidential document title"
        session.messages = [
            WCDBV3ChatMessage(role: .user, text: "Sensitive synthetic draft",
                              status: .completed)
        ]
        session.inputDraft = "Unsent synthetic private context"
        var applied = WCDBV3DuplexProposal(sourceMessageID: session.messages.first?.messageID,
            noteIdentity: nil, noteBaseDigest: nil, noteEditedDigest: nil,
            cardID: UUID(), cardReviewRevision: 0, cardContentRevision: 0,
            cardBaseQuestion: "Before", cardBaseAnswer: "A",
            cardEditedQuestion: "After", cardEditedAnswer: "A",
            state: ImDuplexApprovalState(noteSelected: false, cardSelected: true,
                                         cardStatus: .applied))
        applied.cardReceipt = "Synthetic card applied and reread"
        session.duplexHistory = [applied]
        try await repository.saveChatSession(session, expectedRevision: nil)
        try await repository.deleteChatSession(session.sessionID, expectedRevision: 0)

        var abandoned = WCDBV3ChatSession(sourceIdentity: "note:synthetic/F13-draft.md")
        abandoned.sourceDisplayName = "Another synthetic confidential title"
        abandoned.inputDraft = "Never executed, must not survive deletion"
        try await repository.saveChatSession(abandoned, expectedRevision: nil)
        try await repository.deleteChatSession(abandoned.sessionID, expectedRevision: 0)

        let stage = root.appendingPathComponent("stage", isDirectory: true)
        try FileManager.default.createDirectory(at: stage, withIntermediateDirectories: true)
        try await repository.createConsistentBackup(
            to: stage.appendingPathComponent("ReviewV3.sqlite"))
        try Data("[]".utf8).write(to: stage.appendingPathComponent("LearningEntry-v1.json"))
        try Data("[]".utf8).write(to: stage.appendingPathComponent("prompts.json"))
        let names = ["ReviewV3.sqlite", "LearningEntry-v1.json", "prompts.json"]
        let records = try names.map {
            try ImpressV3BackupArchive.inspectFile(stage.appendingPathComponent($0),
                                                   name: $0).0
        }
        try JSONEncoder().encode(ImpressV3BackupManifest.make(records)).write(
            to: stage.appendingPathComponent("manifest.json"))
        let archive = root.appendingPathComponent("f13-audit.zip")
        try ImpressV3BackupArchive.write(files: (names + ["manifest.json"]).map {
            (name: $0, url: stage.appendingPathComponent($0))
        }, destination: archive)
        let unpacked = root.appendingPathComponent("unpacked", isDirectory: true)
        _ = try ImpressV3BackupArchive.extract(source: archive, destination: unpacked)
        let restored = try ReviewWCDBRepository(
            databasePath: unpacked.appendingPathComponent("ReviewV3.sqlite").path,
            calculator: calculator)
        let visible = try await restored.allChatSessions()
        XCTAssertTrue(visible.isEmpty, "Restoring a backup cannot revive deleted Chat")
        let tombstones = try await restored.allChatSessions(includeDeleted: true)
        XCTAssertEqual(tombstones.count, 2)
        XCTAssertTrue(tombstones.allSatisfy { $0.sourceDisplayName == nil })
        XCTAssertTrue(tombstones.allSatisfy {
            $0.sourceIdentity == "deleted:" + $0.sessionID.uuidString
        }, "ZIP recovery must not resurrect private source locators in tombstones")
        XCTAssertTrue(tombstones.allSatisfy { $0.messages.isEmpty && $0.inputDraft.isEmpty })
        let audited = try await restored.retainedChatReceipts()
        XCTAssertEqual(audited.count, 1)
        XCTAssertEqual(audited.first?.sessionID, session.sessionID)
        XCTAssertEqual(audited.first?.duplexHistory?.first?.cardReceipt,
                       applied.cardReceipt, "Executed facts must survive deletion and ZIP")
        XCTAssertNil(audited.first?.pendingDuplex)
        XCTAssertFalse(tombstones.contains { $0.inputDraft.contains("Never executed") })

        session.revision = 1
        session.updatedAt = Date()
        do {
            try await restored.saveChatSession(session, expectedRevision: 0)
            XCTFail("An old async callback must not resurrect the restored tombstone")
        } catch WCDBV3ChatStorageError.conflict { }
        let afterCallback = try await restored.allChatSessions()
        XCTAssertTrue(afterCallback.isEmpty)
        XCTAssertFalse(ImVaultGuardedWrite.productionWriteEnabled)
    }

    func testOneSourceSupportsTwoIndependentChatSessionsWithoutOverwritingHistory() async throws {
        let repo = try ReviewWCDBRepository(
            databasePath: temporaryPath(), calculator: FSRS6ReviewCalculator())
        let source = "card:" + UUID().uuidString
        var original = WCDBV3ChatSession(sourceIdentity: source)
        original.messages = [WCDBV3ChatMessage(role: .user,
            text: "First discussion", status: .completed)]
        var second = WCDBV3ChatSession(sourceIdentity: source)
        second.inputDraft = "Unsent second discussion"
        try await repo.saveChatSession(original, expectedRevision: nil)
        try await repo.saveChatSession(second, expectedRevision: nil)
        let sessions = try await repo.chatSessions(for: source)
        XCTAssertEqual(sessions.count, 2)
        XCTAssertEqual(Set(sessions.map(\.sessionID)).count, 2)
        XCTAssertTrue(sessions.contains(where: { $0.sessionID == original.sessionID &&
            $0.messages == original.messages }))
        XCTAssertTrue(sessions.contains(where: { $0.sessionID == second.sessionID &&
            $0.inputDraft == second.inputDraft }))
    }

    func testManagedCardCRUDPreservesIdentityAndFSRSReviewEvents() async throws {
        let calculator = FSRS6ReviewCalculator()
        let repo = try ReviewWCDBRepository(
            databasePath: temporaryPath(), calculator: calculator)
        let id = UUID()
        let now = Date(timeIntervalSince1970: 1_720_000_000)
        try await repo.insertNewCard(
            WCDBV3CardInput(cardID: id, question: "Original question",
                            answerText: "Original answer", sourceNotePath: "source.md"),
            initial: try calculator.newCardSnapshot(id: id, now: now), now: now)
        let before = try await repo.listManagedCards(matching: "Original")
        XCTAssertEqual(before.count, 1)
        XCTAssertEqual(before.first?.cardID, id)
        XCTAssertEqual(before.first?.revision, 0)

        _ = try await repo.commit(ReviewSubmission(
            eventID: UUID(), cardID: id, expectedRevision: 0,
            rating: .good, reviewedAt: now.addingTimeInterval(2)))
        try await repo.updateManagedCard(
            WCDBV3CardInput(cardID: id, question: "Edited question",
                answerText: "Edited answer", sourceNotePath: "source.md"),
            expectedRevision: 1, expectedContentRevision: 0)
        let edited = try await repo.content(for: id)
        XCTAssertEqual(edited?.cardID, id)
        XCTAssertEqual(edited?.question, "Edited question")
        XCTAssertEqual(edited?.answerText, "Edited answer")
        XCTAssertEqual(edited?.contentRevision, 1)
        let candidate = try await repo.fetchQueueCandidates()
        XCTAssertEqual(candidate.first?.revision, 1,
            "Content editing must not reset FSRS scheduling state")
        let retainedHistory = try await repo.reviewHistory(for: id)
        XCTAssertEqual(retainedHistory.count, 1)

        let found = try await repo.listManagedCards(matching: "Edited answer")
        XCTAssertEqual(found.count, 1)
        try await repo.setManagedCardSuspended(true, id: id, expectedRevision: 1)
        let suspended = try await repo.listManagedCards()
        XCTAssertTrue(suspended.first?.isSuspended ?? false)
        try await repo.setManagedCardSuspended(false, id: id, expectedRevision: 1)
        let resumed = try await repo.listManagedCards()
        XCTAssertFalse(resumed.first?.isSuspended ?? true)

        try await repo.deleteManagedCard(id: id, expectedRevision: 1)
        let deletedContent = try await repo.content(for: id)
        let deletedHistory = try await repo.reviewHistory(for: id)
        let deletedList = try await repo.listManagedCards()
        XCTAssertNil(deletedContent)
        XCTAssertTrue(deletedHistory.isEmpty)
        XCTAssertTrue(deletedList.isEmpty)
    }

    /// G1/P0: forged boundary CAS tokens must fail before any SQLite update.
    func testManagedCardRejectsNegativeAndOverflowCASWithoutSideEffects() async throws {
        let calc = FSRS6ReviewCalculator()
        let repo = try ReviewWCDBRepository(databasePath: temporaryPath(), calculator: calc)
        let id = UUID()
        let now = Date(timeIntervalSince1970: 1_726_000_000)
        try await repo.insertNewCard(
            WCDBV3CardInput(cardID: id, question: "Stable", answerText: "A"),
            initial: try calc.newCardSnapshot(id: id, now: now), now: now)
        let next = WCDBV3CardInput(cardID: id, question: "Should not save", answerText: "B")
        for invalid in [-1, Int.max] {
            do {
                try await repo.updateManagedCard(next,
                    expectedRevision: 0, expectedContentRevision: invalid)
                XCTFail("Invalid content CAS token must fail before transaction")
            } catch ReviewWCDBError.contentConflict { }
            do {
                try await repo.updateManagedCard(next,
                    expectedRevision: invalid, expectedContentRevision: 0)
                XCTFail("Invalid FSRS revision token must not commit a content edit")
            } catch ReviewWCDBError.revisionConflict { }
        }
        let loaded = try await repo.content(for: id)
        let actual = try XCTUnwrap(loaded)
        XCTAssertEqual(actual.question, "Stable")
        XCTAssertEqual(actual.answerText, "A")
        XCTAssertEqual(actual.contentRevision, 0)
        let versions = try await repo.contentHistory(for: id)
        XCTAssertEqual(versions.map(\.contentRevision), [0])
        let history = try await repo.reviewHistory(for: id)
        XCTAssertTrue(history.isEmpty)
        XCTAssertFalse(ImVaultGuardedWrite.productionWriteEnabled)
    }

    /// CARD-VIDEO-01: no movie BLOB, exact revision binding, historical undo,
    /// stale editor rejection and zero FSRS event side effects.
    func testVideoReferenceCASHistoryAndRestoreKeepFSRSUnchanged() async throws {
        let calculator = FSRS6ReviewCalculator()
        let repo = try ReviewWCDBRepository(
            databasePath: temporaryPath(), calculator: calculator)
        let id = UUID()
        let now = Date(timeIntervalSince1970: 1_727_500_000)
        let cover = Data([0xff, 0xd8, 0xff, 0xd9])
        let ref = try ImpressCardVideoReference(
            mediaID: UUID(), cardID: id, contentRevision: 0,
            durationSeconds: 79.375, trimStartSeconds: 0,
            trimEndSeconds: 79.375, codec: .h264, videoBytes: 16,
            videoSHA256: String(repeating: "a", count: 64),
            coverBytes: UInt64(cover.count),
            coverSHA256: String(repeating: "b", count: 64))
        let image = WCDBV3CardInput(cardID: id, question: "视频问题",
            cardType: CardType.image.rawValue, imageData: cover)
        try await repo.insertNewCard(image,
            initial: try calculator.newCardSnapshot(id: id, now: now),
            now: now, videoReference: ref)
        let initialVideo = try await repo.videoReference(for: id, contentRevision: 0)
        let initialContent = try await repo.content(for: id)
        XCTAssertEqual(initialVideo, ref)
        XCTAssertEqual(initialContent?.imageData, cover)
        XCTAssertEqual(initialContent?.videoReference, ref)

        let edited = WCDBV3CardInput(cardID: id, question: "更新文字",
            cardType: CardType.image.rawValue, imageData: cover)
        try await repo.updateManagedCard(edited,
            expectedRevision: 0, expectedContentRevision: 0)
        let revisedValue = try await repo.videoReference(for: id, contentRevision: 1)
        let revised = try XCTUnwrap(revisedValue)
        XCTAssertEqual(revised.mediaID, ref.mediaID)
        XCTAssertEqual(revised.contentRevision, 1)
        do {
            _ = try await repo.videoReference(for: id, contentRevision: 0)
            XCTFail("Stale playback reference must fail closed")
        } catch ReviewWCDBError.contentConflict { }
        let versions = try await repo.contentHistory(for: id)
        XCTAssertEqual(versions.map(\.contentRevision), [0, 1])
        XCTAssertEqual(versions.first?.videoReference, ref)

        do {
            try await repo.updateManagedCard(edited, expectedRevision: 0,
                expectedContentRevision: 0, videoMutation: .remove)
            XCTFail("A stale video edit must never detach the winner")
        } catch ReviewWCDBError.contentConflict { }

        let replaced = WCDBV3CardInput(cardID: id, question: "替换为旧图片",
            cardType: CardType.image.rawValue, imageData: Data([1, 2, 3]))
        try await repo.updateManagedCard(replaced,
            expectedRevision: 0, expectedContentRevision: 1)
        let removed = try await repo.videoReference(for: id, contentRevision: 2)
        XCTAssertNil(removed)
        try await repo.restoreContentVersion(cardID: id, savedRevision: 0,
            expectedContentRevision: 2, expectedReviewRevision: 0)
        let restoredValue = try await repo.videoReference(for: id, contentRevision: 3)
        let restored = try XCTUnwrap(restoredValue)
        XCTAssertEqual(restored.mediaID, ref.mediaID)
        XCTAssertEqual(restored.contentRevision, 3)
        let retainedBeforeDeletion = try await repo.retainedMediaIDs()
        let ratings = try await repo.reviewHistory(for: id)
        let finalContent = try await repo.content(for: id)
        XCTAssertEqual(retainedBeforeDeletion, Set([ref.mediaID]))
        XCTAssertTrue(ratings.isEmpty)
        XCTAssertEqual(finalContent?.contentRevision, 3)
        try await repo.deleteManagedCard(id: id, expectedRevision: 0)
        let retainedAfterDeletion = try await repo.retainedMediaIDs()
        XCTAssertEqual(retainedAfterDeletion, Set([ref.mediaID]),
            "Deleting a card must retain files needed by immutable undo history")
        XCTAssertFalse(ImVaultGuardedWrite.productionWriteEnabled)
    }

    /// CARD-VIDEO-01: a valid synthetic local media fixture survives actual
    /// ZIP v3 write/extract and SHA checks; a corrupted ZIP is rejected.
    func testCardVideoZIPV3CarriesReferencedMediaAndRejectsTamperedBytes() async throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent(
            "card-video-zip-" + UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        let support = root.appendingPathComponent("support", isDirectory: true)
        let docs = root.appendingPathComponent("documents", isDirectory: true)
        let calibration = root.appendingPathComponent("calibration/checkins-v1.json")
        let suite = "test.card-video-zip." + UUID().uuidString
        defer { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        let calculator = FSRS6ReviewCalculator()
        let database = root.appendingPathComponent("source/ReviewV3.sqlite")
        let repo = try ReviewWCDBRepository(databasePath: database.path,
                                             calculator: calculator)
        let cardID = UUID()
        let video = Data(repeating: 0xa7, count: 4096)
        let cover = Data([0xff, 0xd8, 0xff, 0xe0, 0x00, 0x10, 0xff, 0xd9])
        func digest(_ data: Data) -> String {
            SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        }
        let reference = try ImpressCardVideoReference(
            mediaID: UUID(), cardID: cardID, contentRevision: 0,
            durationSeconds: 123.375, trimStartSeconds: 0,
            trimEndSeconds: 123.375, codec: .h264,
            videoBytes: UInt64(video.count), videoSHA256: digest(video),
            coverBytes: UInt64(cover.count), coverSHA256: digest(cover))
        let movieFile = root.appendingPathComponent("synthetic.mp4")
        let coverFile = root.appendingPathComponent("synthetic.jpg")
        try video.write(to: movieFile)
        try cover.write(to: coverFile)
        let media = try ImpressCardVideoPrivateStore(rootURL:
            support.appendingPathComponent("ImpressCardMedia", isDirectory: true))
        _ = try media.install(reference: reference, movie: movieFile, cover: coverFile,
                              cardID: cardID, expectedContentRevision: 0)
        let now = Date(timeIntervalSince1970: 1_727_800_000)
        try await repo.insertNewCard(
            WCDBV3CardInput(cardID: cardID, question: "Synthetic video",
                            cardType: CardType.image.rawValue, imageData: cover),
            initial: try calculator.newCardSnapshot(id: cardID, now: now),
            now: now, videoReference: reference)
        let paths: ImpressV3BackupCoordinator.SyntheticRestorePaths =
            (support: support, documents: docs, calibration: calibration,
             database: database, promptsSuiteName: suite)
        let zip = try await ImpressV3BackupCoordinator.shared.testCreateFixtureBackup(
            paths: paths, repository: repo)
        let restored = root.appendingPathComponent("extracted", isDirectory: true)
        let entries = try ImpressV3BackupArchive.extract(source: zip, destination: restored)
        let manifest = try JSONDecoder().decode(ImpressV3BackupManifest.self,
            from: Data(contentsOf: restored.appendingPathComponent("manifest.json")))
        XCTAssertEqual(manifest.formatVersion, 3)
        XCTAssertEqual(entries.filter {
            ImpressV3BackupArchive.isSafeMediaName($0.name)
        }.count, 2)
        let extractedMedia = try Data(contentsOf:
            restored.appendingPathComponent(reference.videoRelativePath))
        XCTAssertEqual(extractedMedia, video)
        let extractedIndex = try ImpressV3BackupArchive.mediaIndex(
            forSQLite: restored.appendingPathComponent("ReviewV3.sqlite"))
        XCTAssertEqual(extractedIndex.references, [reference])
        XCTAssertFalse(ImVaultGuardedWrite.productionWriteEnabled)

        // Tamper only with the stored synthetic video payload in a copied ZIP.
        // Its existing local CRC, central CRC and manifest SHA must all reject it.
        var invalid = try Data(contentsOf: zip)
        guard let range = invalid.range(of: video) else {
            XCTFail("Synthetic movie bytes not present in uncompressed ZIP"); return
        }
        invalid[range.lowerBound] ^= 0x01
        let tamperedZIP = root.appendingPathComponent("tampered.zip")
        try invalid.write(to: tamperedZIP)
        XCTAssertThrowsError(try ImpressV3BackupArchive.extract(
            source: tamperedZIP,
            destination: root.appendingPathComponent("tampered-out")))
    }


    /// CARD-VIDEO-01 actual codec/export smoke on an entirely synthesized MOV:
    /// AVAssetWriter -> offline AVFoundation exporter -> validated private media.
    /// This is iOS Simulator L1, not a physical device or a user Photo asset.
    func testNativeAVFoundationExportsSynthesizedMovieForLocalPlayback() async throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent(
            "card-video-native-" + UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        let source = root.appendingPathComponent("synthetic.mov")
        let writer = try AVAssetWriter(outputURL: source, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: 160,
            AVVideoHeightKey: 120
        ])
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input, sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: 160,
                kCVPixelBufferHeightKey as String: 120
            ])
        writer.add(input)
        guard writer.startWriting() else {
            throw writer.error ?? CocoaError(.fileWriteUnknown)
        }
        writer.startSession(atSourceTime: .zero)
        for frame in 0..<24 {
            let deadline = Date().addingTimeInterval(15)
            while !input.isReadyForMoreMediaData && Date() < deadline {
                try await Task.sleep(nanoseconds: 10_000_000)
            }
            guard input.isReadyForMoreMediaData else {
                throw CocoaError(.fileWriteUnknown)
            }
            var next: CVPixelBuffer?
            let status = CVPixelBufferCreate(kCFAllocatorDefault, 160, 120,
                                             kCVPixelFormatType_32BGRA, nil, &next)
            guard status == kCVReturnSuccess, let pixels = next else {
                throw CocoaError(.fileWriteUnknown)
            }
            CVPixelBufferLockBaseAddress(pixels, [])
            if let address = CVPixelBufferGetBaseAddress(pixels) {
                memset(address, frame.isMultiple(of: 2) ? 0x44 : 0xaa,
                       CVPixelBufferGetDataSize(pixels))
            }
            CVPixelBufferUnlockBaseAddress(pixels, [])
            guard adaptor.append(pixels,
                withPresentationTime: CMTime(value: CMTimeValue(frame), timescale: 12)) else {
                throw writer.error ?? CocoaError(.fileWriteUnknown)
            }
        }
        input.markAsFinished()
        try await withCheckedThrowingContinuation {
            (reply: CheckedContinuation<Void, Error>) in
            writer.finishWriting {
                if writer.status == .completed { reply.resume(returning: ()) }
                else { reply.resume(throwing: writer.error ?? CocoaError(.fileWriteUnknown)) }
            }
        }
        let cardID = UUID()
        let request = ImpressCardVideoAVFoundationExporter.Request(
            sourceURL: source, cardID: cardID, expectedContentRevision: 0)
        let stage = try await withCheckedThrowingContinuation {
            (reply: CheckedContinuation<
                ImpressCardVideoAVFoundationExporter.Staged, Error>) in
            _ = ImpressCardVideoAVFoundationExporter.export(request) { result in
                reply.resume(with: result)
            }
        }
        defer { stage.discard() }
        XCTAssertEqual(stage.reference.cardID, cardID)
        XCTAssertEqual(stage.reference.contentRevision, 0)
        XCTAssertGreaterThan(stage.reference.videoBytes, 0)
        XCTAssertLessThanOrEqual(stage.reference.videoBytes,
            ImpressCardVideoReference.maximumBytes)
        let store = try ImpressCardVideoPrivateStore(rootURL:
            root.appendingPathComponent("private", isDirectory: true))
        let installed = try store.install(stage, cardID: cardID,
                                          expectedContentRevision: 0)
        let playback = try store.verifiedPlayback(cardID: cardID,
            contentRevision: 0, reference: stage.reference)
        XCTAssertEqual(playback.movieURL, installed.movieURL)
        let playable = AVURLAsset(url: playback.movieURL)
        XCTAssertFalse(playable.tracks(withMediaType: .video).isEmpty)
        XCTAssertGreaterThan(playable.duration.seconds, 0)
        let item = AVPlayerItem(asset: playable)
        XCTAssertNotNil(AVPlayer(playerItem: item).currentItem)
        XCTAssertFalse(ImVaultGuardedWrite.productionWriteEnabled)
    }


    /// CARD-VIDEO-01: real AVFoundation output, not just a policy estimate.
    /// A synthetic >60-second clip must keep its full duration by default;
    /// in-app fractional two-ended trimming must also support >60 seconds.
    /// No private Photos asset, Provider, Vault or remote encoder is used.
    func testCardVideoAVFoundationFullAndFractionalTrimBeyondSixtySeconds() async throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent(
            "card-video-long-native-" + UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        let source = root.appendingPathComponent("synthetic-68s.mov")
        let writer = try AVAssetWriter(outputURL: source, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: 160,
            AVVideoHeightKey: 120
        ])
        input.expectsMediaDataInRealTime = false
        let adapter = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input, sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: 160,
                kCVPixelBufferHeightKey as String: 120,
                kCVPixelBufferIOSurfacePropertiesKey as String: [:]
            ])
        writer.add(input)
        guard writer.startWriting() else {
            throw writer.error ?? CocoaError(.fileWriteUnknown)
        }
        writer.startSession(atSourceTime: .zero)
        // Six sparse H.264 frames plus an explicit 68-second end time
        // exercise full-length/trim behavior without saturating the Simulator
        // encoder with 272 identical frames before AVFoundation can drain it.
        let deadline = Date().addingTimeInterval(25)
        guard let pool = adapter.pixelBufferPool else {
            throw CocoaError(.fileWriteUnknown)
        }
        for frame in [0, 1, 2, 3, 4, 271] {
            while !input.isReadyForMoreMediaData && Date() < deadline {
                try await Task.sleep(for: .milliseconds(10))
            }
            guard input.isReadyForMoreMediaData else {
                throw writer.error ?? CocoaError(.fileWriteUnknown)
            }
            var next: CVPixelBuffer?
            let result = CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault,
                                                            pool, &next)
            guard result == kCVReturnSuccess, let pixels = next else {
                throw CocoaError(.fileWriteUnknown)
            }
            CVPixelBufferLockBaseAddress(pixels, [])
            if let bytes = CVPixelBufferGetBaseAddress(pixels) {
                memset(bytes, frame.isMultiple(of: 2) ? 0x42 : 0xb7,
                       CVPixelBufferGetDataSize(pixels))
            }
            CVPixelBufferUnlockBaseAddress(pixels, [])
            guard adapter.append(pixels,
                withPresentationTime: CMTime(value: CMTimeValue(frame), timescale: 4)) else {
                throw writer.error ?? CocoaError(.fileWriteUnknown)
            }
        }
        input.markAsFinished()
        writer.endSession(atSourceTime: CMTime(value: 272, timescale: 4))
        try await withCheckedThrowingContinuation {
            (reply: CheckedContinuation<Void, Error>) in
            writer.finishWriting {
                if writer.status == .completed { reply.resume(returning: ()) }
                else { reply.resume(throwing: writer.error ?? CocoaError(.fileWriteUnknown)) }
            }
        }
        let duration = AVURLAsset(url: source).duration.seconds
        XCTAssertGreaterThan(duration, 60.0,
            "A true synthesized source beyond 60s is required")

        let cardID = UUID()
        func export(start: Double, end: Double?) async throws
            -> ImpressCardVideoAVFoundationExporter.Staged {
            let request = ImpressCardVideoAVFoundationExporter.Request(
                sourceURL: source, cardID: cardID, expectedContentRevision: 0,
                trimStartSeconds: start, trimEndSeconds: end)
            return try await withCheckedThrowingContinuation {
                (reply: CheckedContinuation<
                    ImpressCardVideoAVFoundationExporter.Staged, Error>) in
                _ = ImpressCardVideoAVFoundationExporter.export(request) { result in
                    reply.resume(with: result)
                }
            }
        }

        let full = try await export(start: 0, end: nil)
        defer { full.discard() }
        XCTAssertTrue(full.reference.isFullLength)
        XCTAssertGreaterThan(full.reference.trimEndSeconds, 60)
        XCTAssertEqual(full.reference.durationSeconds, duration, accuracy: 0.25)
        XCTAssertEqual(AVURLAsset(url: full.movieURL).duration.seconds,
                       duration, accuracy: 0.5)
        XCTAssertLessThanOrEqual(full.reference.videoBytes,
                                 ImpressCardVideoReference.maximumBytes)

        // 66 - 5.25 = 60.75 seconds; neither endpoint is auto-rounded
        // to the old 60-second limit.
        let start = 5.25
        let end = 66.0
        XCTAssertGreaterThan(duration, end)
        let trimmed = try await export(start: start, end: end)
        defer { trimmed.discard() }
        XCTAssertEqual(trimmed.reference.trimStartSeconds, start, accuracy: 0.001)
        XCTAssertEqual(trimmed.reference.trimEndSeconds, end, accuracy: 0.001)
        XCTAssertEqual(trimmed.reference.durationSeconds, duration, accuracy: 0.25)
        XCTAssertEqual(AVURLAsset(url: trimmed.movieURL).duration.seconds,
                       end - start, accuracy: 0.5)
        XCTAssertGreaterThan(end - start, 60)
        XCTAssertLessThanOrEqual(trimmed.reference.videoBytes,
                                 ImpressCardVideoReference.maximumBytes)
        XCTAssertFalse(ImVaultGuardedWrite.productionWriteEnabled)
    }

    /// CARD-VIDEO-01: real on-device file APIs must refuse a substituted
    /// parent folder rather than import, play or delete bytes outside the
    /// private media root. Synthetic bytes only; no Photos/Vault or provider.
    func testCardVideoPrivateMediaSymlinkedAncestorsCannotEscapeRoot() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent(
            "card-video-symlink-" + UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }

        let privateRoot = root.appendingPathComponent("private", isDirectory: true)
        let store = try ImpressCardVideoPrivateStore(rootURL: privateRoot)
        let cardID = UUID()
        let mediaID = UUID()
        let movie = Data(repeating: 0x41, count: 4_096)
        let cover = Data(repeating: 0x63, count: 320)
        func sha256(_ bytes: Data) -> String {
            SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        }
        let movieURL = root.appendingPathComponent("fixture.mp4")
        let coverURL = root.appendingPathComponent("fixture.jpg")
        try movie.write(to: movieURL)
        try cover.write(to: coverURL)
        let reference = try ImpressCardVideoReference(
            mediaID: mediaID, cardID: cardID, contentRevision: 0,
            durationSeconds: 125.375, trimStartSeconds: 0,
            trimEndSeconds: 125.375, codec: .h264,
            videoBytes: UInt64(movie.count), videoSHA256: sha256(movie),
            coverBytes: UInt64(cover.count), coverSHA256: sha256(cover))

        let mediaRoot = privateRoot.appendingPathComponent("CardVideo",
                                                           isDirectory: true)
        let outside = root.appendingPathComponent("outside", isDirectory: true)
        try fm.createDirectory(at: outside, withIntermediateDirectories: false)
        try fm.createSymbolicLink(at: mediaRoot, withDestinationURL: outside)
        XCTAssertThrowsError(try store.install(
            reference: reference, movie: movieURL, cover: coverURL,
            cardID: cardID, expectedContentRevision: 0))
        XCTAssertFalse(fm.fileExists(atPath: outside.appendingPathComponent(
            cardID.uuidString.lowercased()).path),
            "Never write a card directory through a symlinked parent")

        try fm.removeItem(at: mediaRoot)
        let installed = try store.install(
            reference: reference, movie: movieURL, cover: coverURL,
            cardID: cardID, expectedContentRevision: 0)
        XCTAssertNoThrow(try store.verifiedPlayback(
            cardID: cardID, contentRevision: 0, reference: reference))
        // Repeated content CAS must reuse the same immutable on-disk pair.
        let retried = try store.install(
            reference: reference, movie: movieURL, cover: coverURL,
            cardID: cardID, expectedContentRevision: 0)
        XCTAssertEqual(retried.movieURL, installed.movieURL)
        XCTAssertEqual(retried.coverURL, installed.coverURL)

        let relocated = root.appendingPathComponent("relocated", isDirectory: true)
        try fm.moveItem(at: mediaRoot, to: relocated)
        try fm.createSymbolicLink(at: mediaRoot, withDestinationURL: relocated)
        XCTAssertThrowsError(try store.verifiedPlayback(
            cardID: cardID, contentRevision: 0, reference: reference))
        XCTAssertThrowsError(try store.removeAfterReferenceAudit(
            reference, stillReferencedMediaIDs: []))
        XCTAssertEqual(try Data(contentsOf: relocated
            .appendingPathComponent(cardID.uuidString.lowercased())
            .appendingPathComponent(mediaID.uuidString.lowercased())
            .appendingPathComponent("video.mp4")), movie,
            "Audited removal must never follow a replaced parent symlink")
        // The separate ZIP cold-restore installer must enforce the same
        // ancestor check before deleting any pre-existing CardVideo tree.
        let restoreSupport = root.appendingPathComponent("restore-support",
                                                          isDirectory: true)
        let escape = root.appendingPathComponent("restore-escape",
                                                  isDirectory: true)
        let escapedCardVideo = escape.appendingPathComponent("CardVideo",
                                                             isDirectory: true)
        try fm.createDirectory(at: restoreSupport, withIntermediateDirectories: true)
        try fm.createDirectory(at: escapedCardVideo, withIntermediateDirectories: true)
        let marker = escapedCardVideo.appendingPathComponent("untouched.txt")
        let markerBytes = Data("protected external bytes".utf8)
        try markerBytes.write(to: marker)
        let restoreMediaRoot = restoreSupport.appendingPathComponent(
            "ImpressCardMedia", isDirectory: true)
        try fm.createSymbolicLink(at: restoreMediaRoot, withDestinationURL: escape)
        XCTAssertThrowsError(try ImpressV3BackupCoordinator.testInstallVerifiedCardMedia(
            from: root, support: restoreSupport))
        XCTAssertEqual(try Data(contentsOf: marker), markerBytes)

        try fm.removeItem(at: restoreMediaRoot)
        try fm.createDirectory(at: restoreMediaRoot, withIntermediateDirectories: false)
        let restoreCardTree = restoreMediaRoot.appendingPathComponent(
            "CardVideo", isDirectory: true)
        try fm.createSymbolicLink(at: restoreCardTree,
                                  withDestinationURL: escapedCardVideo)
        XCTAssertThrowsError(try ImpressV3BackupCoordinator.testInstallVerifiedCardMedia(
            from: root, support: restoreSupport))
        XCTAssertEqual(try Data(contentsOf: marker), markerBytes)
        XCTAssertFalse(ImVaultGuardedWrite.productionWriteEnabled)
    }

    /// CARD-VIDEO-01: a simulated process death after SQLite + private media
    /// replacement must restore the ORIGINAL video from the durable rollback.
    /// Uses only SHA-bound, synthetic bytes and disposable App Support folders.
    func testCardVideoColdRestoreInterruptedKeepsOriginalPrivateMedia() async throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent(
            "card-video-cold-rollback-" + UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        let support = root.appendingPathComponent("support", isDirectory: true)
        let documents = root.appendingPathComponent("docs", isDirectory: true)
        let live = documents.appendingPathComponent("ImpressV3", isDirectory: true)
        let calibration = root.appendingPathComponent("checkins/checkins-v1.json")
        try fm.createDirectory(at: live, withIntermediateDirectories: true)
        let suite = "test.video-cold-rollback." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let paths: ImpressV3BackupCoordinator.SyntheticRestorePaths = (
            support: support, documents: documents, calibration: calibration,
            database: live.appendingPathComponent("ReviewV3.sqlite"),
            promptsSuiteName: suite)
        let calculator = FSRS6ReviewCalculator()
        let store = try ImpressCardVideoPrivateStore(rootURL:
            support.appendingPathComponent("ImpressCardMedia", isDirectory: true))
        func digest(_ bytes: Data) -> String {
            SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        }
        func seed(_ label: String, color: UInt8, repo: ReviewWCDBRepository)
            async throws -> (UUID, ImpressCardVideoReference, Data) {
            let cardID = UUID()
            let movie = Data(repeating: color, count: 2048)
            let cover = Data([0xff, 0xd8, color, 0xff, 0xd9])
            let reference = try ImpressCardVideoReference(
                mediaID: UUID(), cardID: cardID, contentRevision: 0,
                durationSeconds: 75.25, trimStartSeconds: 0,
                trimEndSeconds: 75.25, codec: .h264,
                videoBytes: UInt64(movie.count), videoSHA256: digest(movie),
                coverBytes: UInt64(cover.count), coverSHA256: digest(cover))
            let movieURL = root.appendingPathComponent(label + ".mp4")
            let coverURL = root.appendingPathComponent(label + ".jpg")
            try movie.write(to: movieURL)
            try cover.write(to: coverURL)
            _ = try store.install(reference: reference, movie: movieURL,
                                   cover: coverURL, cardID: cardID,
                                   expectedContentRevision: 0)
            let now = Date(timeIntervalSince1970: 1_727_900_000)
            try await repo.insertNewCard(
                WCDBV3CardInput(cardID: cardID, question: label,
                                cardType: CardType.image.rawValue, imageData: cover),
                initial: try calculator.newCardSnapshot(id: cardID, now: now),
                now: now, videoReference: reference)
            return (cardID, reference, movie)
        }
        let oldRepo = try ReviewWCDBRepository(databasePath:
            root.appendingPathComponent("old/ReviewV3.sqlite").path, calculator: calculator)
        let old = try await seed("original", color: 0x43, repo: oldRepo)
        try await oldRepo.createConsistentBackup(
            to: live.appendingPathComponent("ReviewV3.sqlite"))
        let newRepo = try ReviewWCDBRepository(databasePath:
            root.appendingPathComponent("next/ReviewV3.sqlite").path, calculator: calculator)
        let next = try await seed("replacement", color: 0xaa, repo: newRepo)
        let backup = try await ImpressV3BackupCoordinator.shared.testCreateFixtureBackup(
            paths: paths, repository: newRepo)
        try await ImpressV3BackupCoordinator.shared.testStageFixtureRecovery(
            backup, paths: paths, repository: oldRepo)
        let pending = support.appendingPathComponent(
            "ImpressV3PendingRestore", isDirectory: true)
        XCTAssertTrue(fm.fileExists(atPath: pending.path))
        do {
            try ImpressV3BackupCoordinator.testApplyPendingAtColdLaunch(
                root: support, documents: documents, calibration: calibration,
                prompts: defaults, simulateHardTerminationAfterCalibration: true)
            XCTFail("The synthetic termination must interrupt multi-store restore")
        } catch ImpressV3BackupFailure.invalidArchive { }
        XCTAssertTrue(fm.fileExists(atPath: pending.path))
        do {
            try ImpressV3BackupCoordinator.testApplyPendingAtColdLaunch(
                root: support, documents: documents, calibration: calibration,
                prompts: defaults)
            XCTFail("A pending interrupted install must first roll back")
        } catch ImpressV3BackupFailure.restoreInterrupted { }
        let actualIndex = try ImpressV3BackupArchive.mediaIndex(
            forSQLite: live.appendingPathComponent("ReviewV3.sqlite"))
        XCTAssertEqual(actualIndex.references, [old.1])
        let oldPlayback = try store.verifiedPlayback(
            cardID: old.0, contentRevision: 0, reference: old.1)
        XCTAssertEqual(try Data(contentsOf: oldPlayback.movieURL), old.2)
        XCTAssertFalse(fm.fileExists(atPath:
            support.appendingPathComponent("ImpressCardMedia")
                .appendingPathComponent(next.1.videoRelativePath).path))
        XCTAssertFalse(ImVaultGuardedWrite.productionWriteEnabled)
    }



    /// CARD-VIDEO-01: the real composer must expose one mixed Photos picker,
    /// and cancelling it must preserve the prior image-card draft, without
    /// staging a video, touching WCDB or submitting a save.
    @MainActor
    func testCardVideoMixedPhotoPickerCancelPreservesExistingDraft() async throws {
        let cardID = UUID()
        let cover = Data([0xff, 0xd8, 0xff, 0xd9])
        let editor = ImpressV3CardComposerViewController(
            draft: ImpressV3CardDraft(kind: .image,
                question: "Keep this picture", imageData: cover),
            editingCardID: cardID, expectedContentRevision: 3)
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.rootViewController = UINavigationController(rootViewController: editor)
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        editor.loadViewIfNeeded()
        let album = try XCTUnwrap(allSubviews(editor.view)
            .compactMap { $0 as? UIButton }
            .first { $0.title(for: .normal)?.contains("图片或视频") == true })
        XCTAssertFalse(album.isHidden)
        album.sendActions(for: .touchUpInside)
        for _ in 0..<100 {
            if editor.presentedViewController is PHPickerViewController { break }
            try await Task.sleep(for: .milliseconds(30))
        }
        let picker = try XCTUnwrap(editor.presentedViewController as? PHPickerViewController,
            "The production image-card control must open a native Photos picker")
        XCTAssertEqual(picker.configuration.selectionLimit, 1)
        XCTAssertNotNil(picker.configuration.filter,
            "A non-empty mixed image/video filter is required")
        editor.picker(picker, didFinishPicking: [])
        for _ in 0..<100 {
            if editor.presentedViewController == nil { break }
            try await Task.sleep(for: .milliseconds(30))
        }
        XCTAssertNil(editor.presentedViewController,
            "Cancelling Photos must dismiss only the picker")
        let saved = expectation(description: "Cancelled picker leaves original image intact")
        editor.onSave = { input in
            XCTAssertEqual(input.cardID, cardID)
            XCTAssertEqual(input.cardType, CardType.image.rawValue)
            XCTAssertEqual(input.question, "Keep this picture")
            XCTAssertEqual(input.imageData, cover)
            saved.fulfill()
        }
        editor.onSaveVideo = { _, _ in
            XCTFail("Cancelling Photos must never commit a video")
        }
        let save = try XCTUnwrap(editor.navigationItem.rightBarButtonItem)
        let action = try XCTUnwrap(save.action)
        UIApplication.shared.sendAction(action, to: save.target, from: save, for: nil)
        await fulfillment(of: [saved], timeout: 5.0)
        XCTAssertFalse(ImVaultGuardedWrite.productionWriteEnabled)
    }

    /// Editing an existing video card must offer one explicit Remove action.
    /// It stages no mutation until Save; normal onSave must not be called.
    @MainActor
    func testCardVideoRemoveButtonRequiresExplicitCASApproval() async throws {
        let id = UUID()
        let image = Data([0xff, 0xd8, 0xff, 0xd9])
        let draft = ImpressV3CardDraft(
            kind: .image, question: "Video cover retained", imageData: image)
        let editor = ImpressV3CardComposerViewController(
            draft: draft, editingCardID: id, expectedContentRevision: 4,
            editingHasVideo: true)
        editor.loadViewIfNeeded()
        let button = try XCTUnwrap(allSubviews(editor.view)
            .compactMap { $0 as? UIButton }.first {
                $0.accessibilityIdentifier == "impress.card.video.remove"
            })
        XCTAssertFalse(button.isHidden)
        let saved = expectation(description: "Explicit media removal handler")
        editor.onSave = { _ in
            XCTFail("Ordinary content edit must not silently remove a video")
        }
        editor.onRemoveVideo = { content in
            XCTAssertEqual(content.cardID, id)
            XCTAssertEqual(content.imageData, image,
                           "Removal retains existing cover as an image card")
            saved.fulfill()
        }
        button.sendActions(for: .touchUpInside)
        XCTAssertTrue(button.isHidden,
                      "Removal intent remains staged until an explicit save")
        let item = try XCTUnwrap(editor.navigationItem.rightBarButtonItem)
        let action = try XCTUnwrap(item.action)
        UIApplication.shared.sendAction(action, to: item.target, from: item, for: nil)
        await fulfillment(of: [saved], timeout: 3.0)
        XCTAssertFalse(ImVaultGuardedWrite.productionWriteEnabled)
    }

    /// CARD-VIDEO-01: a pending media-removal CAS owns its staged state until
    /// the async receipt is known. Cancel and sheet swipe must not dismiss the
    /// editor mid-save; an error must restore both navigation actions.
    @MainActor
    func testCardVideoInFlightSaveBlocksDismissalAndRecoversAfterCASFailure() async throws {
        let cardID = UUID()
        let cover = Data([0xff, 0xd8, 0xff, 0xd9])
        let editor = ImpressV3CardComposerViewController(
            draft: ImpressV3CardDraft(kind: .image,
                question: "Keep original cover", imageData: cover),
            editingCardID: cardID, expectedContentRevision: 4,
            editingHasVideo: true)
        // The composer is presented inside a navigation sheet in production.
        // A navigation controller installed as the test window root cannot
        // exercise UIKit's actual modal dismissal contract reliably.
        let host = UIViewController()
        let navigation = UINavigationController(rootViewController: editor)
        navigation.modalPresentationStyle = .pageSheet
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        host.present(navigation, animated: false)
        XCTAssertTrue(host.presentedViewController === navigation)
        editor.loadViewIfNeeded()
        let remove = try XCTUnwrap(allSubviews(editor.view)
            .compactMap { $0 as? UIButton }.first {
                $0.accessibilityIdentifier == "impress.card.video.remove"
            })
        remove.sendActions(for: .touchUpInside)
        let saveEntered = expectation(description: "Async media CAS started")
        let (releaseStream, release) = AsyncStream<Void>.makeStream()
        defer { release.finish() }
        editor.onSaveVideo = { _, _ in
            XCTFail("Removing media cannot go through a video install")
        }
        editor.onSave = { _ in
            XCTFail("Explicit removal cannot silently use ordinary save")
        }
        editor.onRemoveVideo = { input in
            XCTAssertEqual(input.cardID, cardID)
            XCTAssertEqual(input.imageData, cover)
            saveEntered.fulfill()
            for await _ in releaseStream { break }
            throw CocoaError(.fileWriteUnknown)
        }
        let save = try XCTUnwrap(editor.navigationItem.rightBarButtonItem)
        let cancel = try XCTUnwrap(editor.navigationItem.leftBarButtonItem)
        UIApplication.shared.sendAction(try XCTUnwrap(save.action),
                                        to: save.target, from: save, for: nil)
        await fulfillment(of: [saveEntered], timeout: 5.0)
        XCTAssertFalse(save.isEnabled)
        XCTAssertFalse(cancel.isEnabled)
        XCTAssertTrue(editor.isModalInPresentation)
        XCTAssertTrue(navigation.isModalInPresentation)
        // Programmatic action dispatch also checks the controller's own guard;
        // disabling a bar item alone does not protect a dismissal race.
        UIApplication.shared.sendAction(try XCTUnwrap(cancel.action),
                                        to: cancel.target, from: cancel, for: nil)
        XCTAssertNil(editor.presentedViewController)
        XCTAssertTrue(navigation.isModalInPresentation)
        release.yield(())
        for _ in 0..<100 {
            if save.isEnabled && cancel.isEnabled &&
                !editor.isModalInPresentation &&
                !navigation.isModalInPresentation &&
                editor.presentedViewController is UIAlertController { break }
            try await Task.sleep(for: .milliseconds(30))
        }
        XCTAssertTrue(save.isEnabled, "Failed CAS must permit explicit retry")
        XCTAssertTrue(cancel.isEnabled, "Failed CAS must restore dismissal")
        XCTAssertFalse(editor.isModalInPresentation)
        XCTAssertFalse(navigation.isModalInPresentation)
        XCTAssertTrue(editor.presentedViewController is UIAlertController)
        XCTAssertFalse(ImVaultGuardedWrite.productionWriteEnabled)
    }

    func testManagedCardSearchPagingAndStaleEditFailsClosed() async throws {
        let calculator = FSRS6ReviewCalculator()
        let repo = try ReviewWCDBRepository(
            databasePath: temporaryPath(), calculator: calculator)
        let now = Date(timeIntervalSince1970: 1_720_000_100)
        var ids = [UUID]()
        for i in 0..<4 {
            let id = UUID()
            ids.append(id)
            try await repo.insertNewCard(
                WCDBV3CardInput(cardID: id, question: "Search \(i)",
                    answerText: "Search answer \(i)"),
                initial: try calculator.newCardSnapshot(id: id, now: now),
                now: now.addingTimeInterval(Double(i)))
        }
        let page1 = try await repo.listManagedCards(matching: "Search", offset: 0, limit: 2)
        let page2 = try await repo.listManagedCards(matching: "Search", offset: 2, limit: 2)
        XCTAssertEqual(page1.count, 2)
        XCTAssertEqual(page2.count, 2)
        XCTAssertEqual(Set((page1 + page2).map(\.cardID)).count, 4)
        do {
            try await repo.updateManagedCard(
                WCDBV3CardInput(cardID: ids[0], question: "Stale",
                    answerText: "No write"),
                expectedRevision: 999, expectedContentRevision: 0)
            XCTFail("Stale update must be rejected")
        } catch ReviewWCDBError.revisionConflict { }
        let unchanged = try await repo.content(for: ids[0])
        XCTAssertEqual(unchanged?.question, "Search 0")
    }

    func testLegacySQLiteMigrationPreservesOldSourceAndExistingV3Cards() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "ImpressLegacyMigrationTest-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("Old/impressdata.db")
        let destination = root.appendingPathComponent("V3/ReviewV3.sqlite")
        try ReviewWCDBRepository.seedLegacyImpressFixtureForTesting(at: source)
        let originalSource = try Data(contentsOf: source)

        let calculator = FSRS6ReviewCalculator()
        let repo = try ReviewWCDBRepository(databasePath: destination.path,
            calculator: calculator)
        let existingID = UUID()
        let now = Date(timeIntervalSince1970: 1_730_000_000)
        try await repo.insertNewCard(WCDBV3CardInput(
            cardID: existingID, question: "Already in V3", answerText: "Keep it"),
            initial: try calculator.newCardSnapshot(id: existingID, now: now),
            now: now)

        let firstPass = try await repo.testImportLegacyFixture(at: source)
        XCTAssertTrue(firstPass)
        let repeated = try await repo.testImportLegacyFixture(at: source)
        XCTAssertFalse(repeated, "The migration receipt must prevent duplicate insertion")
        let cards = try await repo.listManagedCards()
        XCTAssertEqual(cards.count, 3)
        XCTAssertTrue(cards.contains(where: { $0.cardID == existingID }))
        let old = try XCTUnwrap(cards.first(where: { $0.question == "Verify the claim?" }))
        let oldContent = try await repo.content(for: old.cardID)
        XCTAssertEqual(oldContent?.answerText, "Check the evidence.")
        let oldReviewHistory = try await repo.reviewHistory(for: old.cardID)
        XCTAssertTrue(oldReviewHistory.isEmpty,
            "Aggregate legacy review counts cannot be fabricated as ReviewEvents")
        // Restored data must be usable, not merely visible: commit one real
        // FSRS-6 grade and verify exactly one durable review event.
        let receipt = try await repo.commit(ReviewSubmission(
            eventID: UUID(), cardID: old.cardID, expectedRevision: 0,
            rating: .good, reviewedAt: now))
        XCTAssertEqual(receipt.cardID, old.cardID)
        XCTAssertEqual(receipt.after.revision, 1)
        let gradedHistory = try await repo.reviewHistory(for: old.cardID)
        XCTAssertEqual(gradedHistory.count, 1)
        let retiredType = try XCTUnwrap(cards.first(where: {
            $0.question.contains("旧版无文字卡片")
        }))
        XCTAssertTrue(retiredType.isSuspended)
        let fallback = try await repo.content(for: retiredType.cardID)
        XCTAssertEqual(fallback?.cardType, 0)
        XCTAssertEqual(fallback?.answerText, "Prior format answer")

        let notes = try await repo.recoveredLegacyNotes()
        XCTAssertEqual(notes.count, 1)
        XCTAssertEqual(notes.first?.legacyID, 701)
        XCTAssertEqual(notes.first?.title, "Old local note")
        XCTAssertTrue(notes.first?.markdown.contains("Evidence") == true)
        XCTAssertEqual(notes.first?.folder, "Local/Archive")
        XCTAssertEqual(try Data(contentsOf: source), originalSource,
            "The original old WCDB file must remain byte-for-byte untouched")
    }

    func testExistingV3DatabaseUpgradesContentRevisionWithoutLosingCards() async throws {
        let path = temporaryPath()
        let oldID = UUID()
        try ReviewWCDBRepository.seedPreR042FixtureForTesting(
            at: path, cardID: oldID)

        let calc = FSRS6ReviewCalculator()
        let repo = try ReviewWCDBRepository(databasePath: path, calculator: calc)
        let original = try await repo.content(for: oldID)
        XCTAssertEqual(original?.question, "Original saved V3")
        XCTAssertEqual(original?.answerText, "Do not discard")
        XCTAssertEqual(original?.contentRevision, 0)
        let newID = UUID()
        let now = Date(timeIntervalSince1970: 1_720_000_123)
        try await repo.insertNewCard(
            WCDBV3CardInput(cardID: newID, question: "New V3", answerText: "A"),
            initial: try calc.newCardSnapshot(id: newID, now: now), now: now)
        try await repo.updateManagedCard(
            WCDBV3CardInput(cardID: oldID, question: "Original preserved", answerText: "A"),
            expectedRevision: 0, expectedContentRevision: 0)
        let updatedOriginal = try await repo.content(for: oldID)
        XCTAssertEqual(updatedOriginal?.contentRevision, 1)
        let reopened = try ReviewWCDBRepository(databasePath: path, calculator: calc)
        let all = try await reopened.listManagedCards()
        XCTAssertEqual(Set(all.map(\.cardID)), Set([oldID, newID]))
        let history = try await reopened.reviewHistory(for: newID)
        XCTAssertTrue(history.isEmpty)
    }

    @MainActor
    func testNativeChatUIListsAndPreservesMultipleSessions() async throws {
        let priorIntro = UserDefaults.standard.object(forKey: "ImpressV11ChatIntroductionSeen")
        UserDefaults.standard.set(true, forKey: "ImpressV11ChatIntroductionSeen")
        defer {
            if let priorIntro {
                UserDefaults.standard.set(priorIntro, forKey: "ImpressV11ChatIntroductionSeen")
            } else {
                UserDefaults.standard.removeObject(forKey: "ImpressV11ChatIntroductionSeen")
            }
        }
        let repo = try ReviewWCDBRepository(
            databasePath: temporaryPath(), calculator: FSRS6ReviewCalculator())
        let id = UUID(), source = "card:" + id.uuidString
        var first = WCDBV3ChatSession(sourceIdentity: source)
        first.messages = [WCDBV3ChatMessage(role: .user,
            text: "Old discussion", status: .completed)]
        var second = WCDBV3ChatSession(sourceIdentity: source)
        second.updatedAt = first.updatedAt.addingTimeInterval(3)
        second.inputDraft = "Old draft"
        try await repo.saveChatSession(first, expectedRevision: nil)
        try await repo.saveChatSession(second, expectedRevision: nil)

        let chat = ImpressAINativeChatViewController(
            question: "Q", answer: "A", cardID: id,
            contentRevision: 0, repository: repo)
        let nav = UINavigationController(rootViewController: chat)
        let window = UIWindow(frame: UIScreen.main.bounds)
        window.rootViewController = nav
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        chat.loadViewIfNeeded()
        let input = try XCTUnwrap(allSubviews(chat.view)
            .compactMap { $0 as? UITextView }
            .first(where: { $0.accessibilityIdentifier == "impress.ai.chat.input" }))
        for _ in 0..<100 where input.text != "Old draft" {
            try await Task.sleep(for: .milliseconds(30))
        }
        XCTAssertEqual(input.text, "Old draft")
        let bars = try XCTUnwrap(chat.navigationItem.rightBarButtonItems)
        let features = try XCTUnwrap(bars.first(where: {
            $0.accessibilityIdentifier == "impress.ai.chat.features" }))
        let add = try XCTUnwrap(bars.first(where: {
            $0.accessibilityIdentifier == "impress.ai.chat.new-discussion" }))
        // The feature button is now a native nested UIMenu, not a selector
        // that pushes the former feature-list controller. Exercise its real
        // UIAction handler instead of bypassing the menu to reach history.
        XCTAssertNil(features.action)
        let menu = try XCTUnwrap(features.menu)
        XCTAssertEqual(menu.children.count, 4)
        let historyAction = try XCTUnwrap(menu.children.first as? UIAction)
        XCTAssertFalse(historyAction.title.isEmpty)
        let settingsMenu = try XCTUnwrap(menu.children[1] as? UIMenu)
        XCTAssertEqual(settingsMenu.children.count, 3)
        XCTAssertTrue(settingsMenu.children.allSatisfy { $0 is UIAction })
        let receiptsMenu = try XCTUnwrap(menu.children[2] as? UIMenu)
        XCTAssertFalse(receiptsMenu.children.isEmpty)
        historyAction.performWithSender(features, target: chat)
        for _ in 0..<100 where !(nav.topViewController is ImpressChatSessionHistoryViewController) {
            try await Task.sleep(for: .milliseconds(30))
        }
        let page = try XCTUnwrap(nav.topViewController as? ImpressChatSessionHistoryViewController)
        XCTAssertEqual(page.tableView.numberOfRows(inSection: 0), 2)
        nav.popViewController(animated: false)
        _ = UIApplication.shared.sendAction(try XCTUnwrap(add.action),
                                           to: add.target, from: add, for: nil)
        for _ in 0..<100 {
            let rows = try await repo.chatSessions(for: source)
            if rows.count == 3 { break }
            try await Task.sleep(for: .milliseconds(30))
        }
        let saved = try await repo.chatSessions(for: source)
        XCTAssertEqual(saved.count, 3)
        XCTAssertTrue(saved.contains(where: { $0.sessionID == first.sessionID &&
            $0.messages == first.messages }))
        XCTAssertTrue(saved.contains(where: { $0.sessionID == second.sessionID &&
            $0.inputDraft == second.inputDraft }))
        XCTAssertEqual(input.text, "")
    }

    @MainActor
    func testNoteScopedChatRestoresWithoutLeakingAcrossCardSource() async throws {
        let repository = try ReviewWCDBRepository(
            databasePath: temporaryPath(), calculator: FSRS6ReviewCalculator())
        let source = "note:qa-vault-identity"
        var saved = WCDBV3ChatSession(sourceIdentity: source)
        saved.messages = [WCDBV3ChatMessage(role: .user,
            text: "My note discussion", status: .completed)]
        try await repository.saveChatSession(saved, expectedRevision: nil)
        let chat = ImpressAINativeChatViewController(question: "Note", answer: nil,
            repository: repository, sourceKey: source, sourceVersion: "sha256")
        // A self-sizing UICollectionView must have real window geometry before
        // we inspect layout or visible cells. Avoid probing section 0 while the
        // asynchronous Diffable snapshot has not yet published any section.
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.rootViewController = UINavigationController(rootViewController: chat)
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        chat.loadViewIfNeeded()
        let transcript = try XCTUnwrap(allSubviews(chat.view)
            .compactMap { $0 as? UICollectionView }
            .first(where: { $0.accessibilityIdentifier == "impress.ai.chat.transcript" }))
        for _ in 0..<100 {
            if transcript.numberOfSections > 0 &&
               transcript.numberOfItems(inSection: 0) == 1 { break }
            try await Task.sleep(for: .milliseconds(30))
        }
        XCTAssertEqual(transcript.numberOfSections, 1)
        XCTAssertEqual(transcript.numberOfItems(inSection: 0), 1)
        window.layoutIfNeeded()
        let cell = try XCTUnwrap(transcript.cellForItem(
            at: IndexPath(item: 0, section: 0)) as? ImpressChatDocumentCell)
        let text = try XCTUnwrap(allSubviews(cell)
            .compactMap { $0 as? UITextView }.first)
        XCTAssertEqual(text.attributedText.string, "My note discussion",
            "The authorized note discussion must recover its exact original text")
        let unrelated = try await repository.chatSessions(for: "card:" + UUID().uuidString)
        XCTAssertTrue(unrelated.isEmpty)
    }

    @MainActor
    func testNoteSectionSelectionPreservesFullBodyAndRequiresExplicitChoice() throws {
        let input = "# First\nText\n\n" +
            "~~~swift\n# not a heading\n~~~\n\n## Second\nAnother block"
        let items = ImpressAISectionExtractor.sections(in: input)
        XCTAssertEqual(items.count, 2)
        XCTAssertTrue(items[0].text.contains("not a heading"))
        XCTAssertTrue(items[1].text.contains("Another block"))
        let picker = ImpressChatNoteSectionPicker(sections: items)
        picker.loadViewIfNeeded()
        XCTAssertFalse(picker.navigationItem.rightBarButtonItem?.isEnabled ?? true)
        picker.tableView(picker.tableView,
            didSelectRowAt: IndexPath(row: 1, section: 0))
        XCTAssertTrue(picker.navigationItem.rightBarButtonItem?.isEnabled ?? false)
    }

    @MainActor
    func testLegacyChatRowsRequireRenewedContextConsent() async throws {
        let store = try ReviewWCDBRepository(
            databasePath: temporaryPath(), calculator: FSRS6ReviewCalculator())
        let source = "card:" + UUID().uuidString
        var older = WCDBV3ChatSession(sourceIdentity: source)
        older.contextReferences = [WCDBV3ChatContextReference(
            stableIdentity: source, sourceRevision: "0", excerpt: "Private context")]
        try await store.saveChatSession(older, expectedRevision: nil)
        let reloaded = try await store.chatSessions(for: source)
        XCTAssertEqual(reloaded.count, 1)
        XCTAssertFalse(reloaded[0].contextConsentGranted == true)
    }

    @MainActor
    func testChatMessageMenuSeparatesCopyAndExplicitNoteDraftWithoutProductionWrite() throws {
        let identity = try ImVaultFileIdentity(
            vaultID: "disposable-test-vault",
            relativePath: "Notes/One.md")
        let assistantTurn = WCDBV3ChatMessage(
            role: .assistant, text: "A proposed interpretation",
            status: .completed)
        let pendingTurn = WCDBV3ChatMessage(
            role: .assistant, text: "Incomplete reply",
            status: .pending)
        let linked = ImpressAINativeChatViewController(
            question: "Q", answer: "A", cardID: UUID(),
            contentRevision: 0, linkedNoteIdentity: identity)
        let unlinked = ImpressAINativeChatViewController(question: "Q", answer: "A")
        let linkedActions = linked.messageMenu(for: assistantTurn).children
            .compactMap { $0 as? UIAction }
        XCTAssertTrue(linkedActions.contains(where: { $0.title == V3L("复制消息") }))
        XCTAssertTrue(linkedActions.contains(where: {
            $0.title == V3L("在关联笔记草稿中整理")
        }))
        XCTAssertTrue(linkedActions.contains(where: {
            $0.title == V3L("修订关联原卡")
        }))
        XCTAssertTrue(linkedActions.contains(where: {
            $0.title == V3L("统一预览笔记与原卡修订")
        }))
        XCTAssertTrue(linkedActions.contains(where: {
            $0.title == V3L("生成关联笔记候选卡")
        }))
        let noSourceActions = unlinked.messageMenu(for: assistantTurn).children
            .compactMap { $0 as? UIAction }
        XCTAssertFalse(noSourceActions.contains(where: {
            $0.title == V3L("在关联笔记草稿中整理")
        }))
        let pendingActions = linked.messageMenu(for: pendingTurn).children
            .compactMap { $0 as? UIAction }
        for title in [V3L("在关联笔记草稿中整理"),
                      V3L("修订关联原卡"), V3L("生成关联笔记候选卡"), V3L("统一预览笔记与原卡修订")] {
            XCTAssertFalse(pendingActions.contains(where: { $0.title == title }))
        }
        XCTAssertFalse(ImVaultGuardedWrite.productionWriteEnabled)
    }

    @MainActor
    func testProductionChatSystemPickersStayLocalWithRemovablePreviews() throws {
        let controller = ImpressAINativeChatViewController()
        controller.loadViewIfNeeded()
        let controls = allSubviews(controller.view).compactMap { $0 as? UIButton }
        let add = try XCTUnwrap(controls.first {
            $0.accessibilityIdentifier == "impress.ai.chat.add-material"
        })
        XCTAssertTrue(add.showsMenuAsPrimaryAction)
        XCTAssertEqual(add.menu?.children.compactMap { $0 as? UIAction }
            .map(\.title), ["相册", "文件", "拍照"])
        controller.addLocalPreviewFixtureForTest("安全边界.txt")
        let preview = try XCTUnwrap(allSubviews(controller.view).first {
            $0.accessibilityIdentifier == "impress.ai.chat.local-preview"
        })
        XCTAssertFalse(preview.isHidden)
        let hint = try XCTUnwrap(allSubviews(controller.view)
            .compactMap { $0 as? UILabel }.first {
                $0.accessibilityIdentifier ==
                    "impress.ai.chat.local-preview-not-transmitted"
            })
        XCTAssertFalse(hint.isHidden)
        let remove = try XCTUnwrap(allSubviews(controller.view)
            .compactMap { $0 as? UIButton }.first {
                $0.accessibilityIdentifier == "impress.ai.chat.local-preview-remove"
            })
        remove.sendActions(for: .touchUpInside)
        let scroller = try XCTUnwrap(allSubviews(controller.view)
            .compactMap { $0 as? UIScrollView }.first {
                $0.accessibilityIdentifier == "impress.ai.chat.local-preview-strip"
            })
        XCTAssertTrue(scroller.isHidden)
    }

    @MainActor
    func testNativeChatRendersSelectableMarkdownWithSecondaryFeatures() throws {
        let controller = ImpressAINativeChatViewController()
        controller.loadViewIfNeeded()
        let elements = allSubviews(controller.view)
        let buttons = elements.compactMap { $0 as? UIButton }
        XCTAssertNil(buttons.first(where: {
            $0.accessibilityIdentifier == "impress.ai.chat.prompt" ||
            $0.accessibilityIdentifier == "impress.ai.chat.materials"
        }))
        XCTAssertNotNil(buttons.first(where: {
            $0.accessibilityIdentifier == "impress.ai.chat.add-material"
        }))
        XCTAssertEqual(controller.navigationItem.rightBarButtonItems?
            .compactMap(\.accessibilityIdentifier),
            ["impress.ai.chat.new-discussion", "impress.ai.chat.features"])
        XCTAssertNotNil(elements.compactMap { $0 as? UICollectionView }.first {
            $0.accessibilityIdentifier == "impress.ai.chat.transcript"
        }, "Production Chat must mount its diffable transcript")
        let cell = ImpressChatDocumentCell(
            frame: CGRect(x: 0, y: 0, width: 390, height: 220))
        cell.configure("**Markdown** and long text", kind: .paragraph,
                       headingLevel: 0, user: false, stable: true)
        let text = try XCTUnwrap(allSubviews(cell)
            .compactMap { $0 as? UITextView }.first)
        XCTAssertEqual(text.accessibilityIdentifier, "impress.ai.chat.message-body")
        XCTAssertTrue(text.isSelectable)
        XCTAssertFalse(text.isEditable)
        XCTAssertFalse(text.isScrollEnabled)
        XCTAssertTrue(text.attributedText.string.contains("Markdown"))
    }

    @MainActor
    func testNativeChatRestoresStableCardTranscriptAndUnsentDraft() async throws {
        let repository = try ReviewWCDBRepository(
            databasePath: temporaryPath(), calculator: FSRS6ReviewCalculator())
        let cardID = UUID()
        let identity = "card:" + cardID.uuidString
        var saved = WCDBV3ChatSession(sourceIdentity: identity)
        saved.inputDraft = "Unsent boundary question"
        saved.messages = [
            WCDBV3ChatMessage(role: .user, text: "First question",
                              status: .completed),
            WCDBV3ChatMessage(role: .assistant, text: "First answer",
                              status: .completed)
        ]
        try await repository.saveChatSession(saved, expectedRevision: nil)
        let chat = ImpressAINativeChatViewController(
            question: "Q", answer: "A", cardID: cardID,
            contentRevision: 0, repository: repository)
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.rootViewController = UINavigationController(rootViewController: chat)
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        chat.loadViewIfNeeded()
        let input = try XCTUnwrap(allSubviews(chat.view)
            .compactMap { $0 as? UITextView }
            .first(where: { $0.accessibilityIdentifier == "impress.ai.chat.input" }))
        let transcript = try XCTUnwrap(allSubviews(chat.view)
            .compactMap { $0 as? UICollectionView }
            .first(where: { $0.accessibilityIdentifier == "impress.ai.chat.transcript" }))
        for _ in 0..<100 {
            if input.text == saved.inputDraft &&
               transcript.numberOfSections > 0 &&
               transcript.numberOfItems(inSection: 0) == 3 { break }
            try await Task.sleep(for: .milliseconds(30))
        }
        XCTAssertEqual(input.text, "Unsent boundary question")
        XCTAssertEqual(transcript.numberOfSections, 1)
        // Two WCDB messages become three independently reusable UI blocks:
        // user bubble, assistant document and the completed reply-action footer.
        XCTAssertEqual(transcript.numberOfItems(inSection: 0), 3)
        window.layoutIfNeeded()
        for (item, expectedText) in [(0, "First question"), (1, "First answer")] {
            let cell = try XCTUnwrap(transcript.cellForItem(
                at: IndexPath(item: item, section: 0)) as? ImpressChatDocumentCell)
            let text = try XCTUnwrap(allSubviews(cell)
                .compactMap { $0 as? UITextView }.first)
            XCTAssertEqual(text.attributedText.string, expectedText)
        }
        let footer = try XCTUnwrap(transcript.cellForItem(
            at: IndexPath(item: 2, section: 0)) as? ImpressChatReplyActionsCell)
        XCTAssertTrue(allSubviews(footer).contains(where: {
            $0.accessibilityIdentifier == "impress.ai.chat.reply-copy"
        }), "The restored completed reply keeps its real interaction controls")
        // Load is read-only; opening Chat does not trigger model requests
        // or modify the saved source content / FSRS database.
        let durable = try await repository.chatSessions(for: identity)
        XCTAssertEqual(durable.count, 1)
        XCTAssertEqual(durable.first?.messages.count, 2)
        XCTAssertEqual(durable.first?.inputDraft, saved.inputDraft)
    }

    func testChatSessionReopensDraftAndPreservesHistoryInV3Backup() async throws {
        let path = temporaryPath()
        let calculator = FSRS6ReviewCalculator()
        let repo = try ReviewWCDBRepository(databasePath: path, calculator: calculator)
        let source = "card:" + UUID().uuidString
        let created = Date(timeIntervalSince1970: 1_720_000_000)
        var session = WCDBV3ChatSession(sourceIdentity: source, createdAt: created)
        session.messages = [
            WCDBV3ChatMessage(role: .user, text: "What are the boundaries?",
                              status: .completed, createdAt: created),
            WCDBV3ChatMessage(role: .assistant, text: "Here is a draft...",
                              status: .completed, createdAt: created)
        ]
        try await repo.saveChatSession(session, expectedRevision: nil)
        let initial = try await repo.chatSessions(for: source)
        XCTAssertEqual(initial, [session])
        session.inputDraft = "Please shorten the example"
        session.promptOverride = "A session-specific prompt"
        session.revision += 1
        session.updatedAt = created.addingTimeInterval(10)
        try await repo.saveChatSession(session, expectedRevision: 0)
        try await repo.saveChatSession(session, expectedRevision: 0) // exact retry
        let stored = try await repo.chatSessions(for: source)
        XCTAssertEqual(stored.count, 1)
        XCTAssertEqual(stored.first?.inputDraft, "Please shorten the example")
        XCTAssertEqual(stored.first?.messages.count, 2)
        var outdated = session
        outdated.inputDraft = "stale overwrite"
        outdated.revision += 1
        do {
            try await repo.saveChatSession(outdated, expectedRevision: 0)
            XCTFail("A stale chat editor must not overwrite a newer saved draft")
        } catch WCDBV3ChatStorageError.conflict { }

        let archive = URL(fileURLWithPath: path).deletingLastPathComponent()
            .appendingPathComponent("chat-backup.sqlite")
        try await repo.createConsistentBackup(to: archive)
        let restored = try ReviewWCDBRepository(databasePath: archive.path,
                                                calculator: calculator)
        let recovered = try await restored.chatSessions(for: source)
        XCTAssertEqual(recovered, [session])
        let other = try await restored.chatSessions(for: "card:" + UUID().uuidString)
        XCTAssertTrue(other.isEmpty)
    }

    func testCardContentHistoryIsAtomicNoOpAndRestoresWithoutRescoring() async throws {
        let path = temporaryPath()
        let calculator = FSRS6ReviewCalculator()
        let repository = try ReviewWCDBRepository(databasePath: path, calculator: calculator)
        let id = UUID()
        let now = Date(timeIntervalSince1970: 1_720_010_000)
        let initial = WCDBV3CardInput(cardID: id, question: "What is a boundary?",
                                       answerText: "A limit", sourceNotePath: "notes/a.md")
        try await repository.insertNewCard(
            initial, initial: try calculator.newCardSnapshot(id: id, now: now), now: now)
        let created = try await repository.contentHistory(for: id)
        XCTAssertEqual(created.map(\.contentRevision), [0])
        XCTAssertEqual(created.first?.origin, .manual)
        _ = try await repository.commit(ReviewSubmission(
            eventID: UUID(), cardID: id, expectedRevision: 0,
            rating: .good, reviewedAt: now.addingTimeInterval(1)))
        let edited = WCDBV3CardInput(cardID: id, question: "What is a boundary?",
                                      answerText: "A limit with examples",
                                      sourceNotePath: "notes/a.md")
        try await repository.updateManagedCard(
            edited, expectedRevision: 1, expectedContentRevision: 0,
            now: now.addingTimeInterval(2))
        // Submitting unchanged content MUST NOT increment content revision.
        try await repository.updateManagedCard(
            edited, expectedRevision: 1, expectedContentRevision: 1,
            now: now.addingTimeInterval(3))
        let afterNoOp = try await repository.content(for: id)
        XCTAssertEqual(afterNoOp?.contentRevision, 1)
        let versions = try await repository.contentHistory(for: id)
        XCTAssertEqual(versions.map(\.contentRevision), [0, 1])
        XCTAssertEqual(versions.map(\.answerText), ["A limit", "A limit with examples"])
        try await repository.restoreContentVersion(
            cardID: id, savedRevision: 0, expectedContentRevision: 1,
            expectedReviewRevision: 1, now: now.addingTimeInterval(4))
        let afterRestore = try await repository.content(for: id)
        XCTAssertEqual(afterRestore?.answerText, "A limit")
        let complete = try await repository.contentHistory(for: id)
        XCTAssertEqual(complete.map(\.contentRevision), [0, 1, 2])
        XCTAssertEqual(complete.last?.origin, .restored)
        let reviewHistory = try await repository.reviewHistory(for: id)
        let candidates = try await repository.fetchQueueCandidates()
        XCTAssertEqual(reviewHistory.count, 1)
        XCTAssertEqual(candidates.first?.revision, 1)

        // The existing SQLite V3 backup automatically captures content history.
        let archive = URL(fileURLWithPath: path).deletingLastPathComponent()
            .appendingPathComponent("backup-snapshot.sqlite")
        try await repository.createConsistentBackup(to: archive)
        let reopened = try ReviewWCDBRepository(databasePath: archive.path,
                                                calculator: calculator)
        let recoveredVersions = try await reopened.contentHistory(for: id)
        XCTAssertEqual(recoveredVersions, complete)
    }

    func testObservedLegacyContentHistoryNeverInventsEarlierAnswers() async throws {
        let path = temporaryPath()
        let id = UUID()
        try ReviewWCDBRepository.seedPreR042FixtureForTesting(at: path, cardID: id)
        let repository = try ReviewWCDBRepository(
            databasePath: path, calculator: FSRS6ReviewCalculator())
        let beforeEditing = try await repository.contentHistory(for: id)
        XCTAssertTrue(beforeEditing.isEmpty)
        try await repository.updateManagedCard(
            WCDBV3CardInput(cardID: id, question: "Observed edit", answerText: "Changed"),
            expectedRevision: 0, expectedContentRevision: 0)
        let versions = try await repository.contentHistory(for: id)
        XCTAssertEqual(versions.map(\.contentRevision), [0, 1])
        XCTAssertEqual(versions.first?.origin, .observedBaseline)
        XCTAssertEqual(versions.first?.answerText, "Do not discard")
        XCTAssertEqual(versions.last?.answerText, "Changed")
    }

    func testConcurrentContentEditorsRejectStaleSaveWithoutChangingFSRS() async throws {
        let calculator = FSRS6ReviewCalculator()
        let repo = try ReviewWCDBRepository(databasePath: temporaryPath(), calculator: calculator)
        let id = UUID()
        let now = Date(timeIntervalSince1970: 1_720_000_123)
        try await repo.insertNewCard(
            WCDBV3CardInput(cardID: id, question: "Initial", answerText: "A"),
            initial: try calculator.newCardSnapshot(id: id, now: now), now: now)
        let initialA = try await repo.content(for: id)
        let initialB = try await repo.content(for: id)
        let editorA = try XCTUnwrap(initialA)
        let editorB = try XCTUnwrap(initialB)
        XCTAssertEqual(editorA.contentRevision, 0)
        try await repo.updateManagedCard(
            WCDBV3CardInput(cardID: id, question: "Editor A", answerText: "A"),
            expectedRevision: 0, expectedContentRevision: editorA.contentRevision)
        do {
            try await repo.updateManagedCard(
                WCDBV3CardInput(cardID: id, question: "Editor B", answerText: "B"),
                expectedRevision: 0, expectedContentRevision: editorB.contentRevision)
            XCTFail("Stale content edit must not overwrite a newer saved edit")
        } catch ReviewWCDBError.contentConflict { }
        let current = try await repo.content(for: id)
        XCTAssertEqual(current?.question, "Editor A")
        XCTAssertEqual(current?.contentRevision, 1)
        let queue = try await repo.fetchQueueCandidates()
        XCTAssertEqual(queue.first?.revision, 0)
        let history = try await repo.reviewHistory(for: id)
        XCTAssertTrue(history.isEmpty)
    }

    func testManagedCardLiteralWildcardSearchAndEqualTimestampPaging() async throws {
        let calculator = FSRS6ReviewCalculator()
        let repo = try ReviewWCDBRepository(databasePath: temporaryPath(), calculator: calculator)
        let now = Date(timeIntervalSince1970: 1_720_001_000)
        let subjects = ["literal_% match", "literal_? match", "plain match", "literal_% other"]
        for label in subjects {
            let id = UUID()
            try await repo.insertNewCard(
                WCDBV3CardInput(cardID: id, question: label, answerText: "answer"),
                initial: try calculator.newCardSnapshot(id: id, now: now), now: now)
        }
        let left = try await repo.listManagedCards(offset: 0, limit: 2)
        let right = try await repo.listManagedCards(offset: 2, limit: 2)
        XCTAssertEqual(Set((left + right).map(\.cardID)).count, 4)
        let literal = try await repo.listManagedCards(matching: "_%", limit: 20)
        XCTAssertEqual(literal.count, 2)
        XCTAssertTrue(literal.allSatisfy { $0.question.contains("_%") })
    }

    func testV3BackupZIPRoundTripAndChecksumRejection() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("Backup-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let dbPath = root.appendingPathComponent("live.sqlite").path
        let calc = FSRS6ReviewCalculator()
        let repo = try ReviewWCDBRepository(databasePath: dbPath, calculator: calc)
        let now = Date(timeIntervalSince1970: 1_720_000_000)
        let id = UUID()
        try await repo.insertNewCard(
            WCDBV3CardInput(cardID: id, question: "Remember this card",
                            answerText: "My only answer"),
            initial: try calc.newCardSnapshot(id: id, now: now), now: now)
        let stage = root.appendingPathComponent("stage")
        try FileManager.default.createDirectory(at: stage, withIntermediateDirectories: true)
        try await repo.createConsistentBackup(
            to: stage.appendingPathComponent("ReviewV3.sqlite"))
        try Data("[]".utf8).write(
            to: stage.appendingPathComponent("LearningEntry-v1.json"))
        try JSONEncoder().encode(ImpressV3PromptLibrary.defaults).write(
            to: stage.appendingPathComponent("prompts.json"))
        let names = ["ReviewV3.sqlite", "LearningEntry-v1.json", "prompts.json"]
        let records = try names.map {
            try ImpressV3BackupArchive.inspectFile(
                stage.appendingPathComponent($0), name: $0).0
        }
        let manifest = ImpressV3BackupManifest.make(records)
        try JSONEncoder().encode(manifest).write(
            to: stage.appendingPathComponent("manifest.json"))
        let destination = root.appendingPathComponent("valid.zip")
        try ImpressV3BackupArchive.write(files:
            (names + ["manifest.json"]).map { (name: $0,
                url: stage.appendingPathComponent($0)) }, destination: destination)
        let extracted = root.appendingPathComponent("restored")
        let output = try ImpressV3BackupArchive.extract(
            source: destination, destination: extracted)
        XCTAssertEqual(output.count, 4)
        XCTAssertTrue(FileManager.default.fileExists(atPath:
            extracted.appendingPathComponent("ReviewV3.sqlite").path))
        let restoredDatabaseBytes = try Data(contentsOf:
            extracted.appendingPathComponent("ReviewV3.sqlite"))
        let originalDatabaseBytes = try Data(contentsOf:
            stage.appendingPathComponent("ReviewV3.sqlite"))
        XCTAssertEqual(restoredDatabaseBytes, originalDatabaseBytes)
        let scanned = try JSONDecoder().decode(ImpressV3BackupManifest.self,
            from: Data(contentsOf: extracted.appendingPathComponent("manifest.json")))
        try scanned.validate(output.filter { $0.name != "manifest.json" })
        XCTAssertFalse(scanned.includesExternalVault)
        XCTAssertFalse(scanned.includesCredentials)
        // F12: local CRC and manifest SHA alone do NOT prove a valid ZIP.
        // Verify central-directory CRC/offset/count, end marker and appended
        // bytes, without changing the existing real WCDB/JSON test fixtures.
        let complete = try Data(contentsOf: destination)
        let eocd = complete.count - 22
        func le32(_ bytes: Data, at pos: Int) -> Int {
            Int(bytes[pos]) | (Int(bytes[pos + 1]) << 8) |
                (Int(bytes[pos + 2]) << 16) | (Int(bytes[pos + 3]) << 24)
        }
        let directoryOffset = le32(complete, at: eocd + 16)
        XCTAssertGreaterThan(directoryOffset, 0)
        XCTAssertLessThan(directoryOffset + 46, eocd)
        func rejectForgedZIP(_ bytes: Data, _ filename: String) throws {
            let source = root.appendingPathComponent(filename + ".zip")
            let target = root.appendingPathComponent(filename + "-extracted")
            try bytes.write(to: source)
            XCTAssertThrowsError(
                try ImpressV3BackupArchive.extract(source: source, destination: target),
                "The exact complete ZIP central directory and EOCD must be validated")
            XCTAssertFalse(FileManager.default.fileExists(atPath: target.path),
                           "A rejected archive must leave no staging files")
        }
        var mismatchedCentralCRC = complete
        mismatchedCentralCRC[directoryOffset + 16] ^= 0x01
        try rejectForgedZIP(mismatchedCentralCRC, "forged-central-crc")
        var falseEntryCount = complete
        falseEntryCount[eocd + 10] ^= 0x01
        try rejectForgedZIP(falseEntryCount, "forged-central-count")
        try rejectForgedZIP(Data(complete.prefix(eocd)), "missing-end-of-central")
        var appendedOverlay = complete
        appendedOverlay.append(contentsOf: Data("unapproved-overlay".utf8))
        try rejectForgedZIP(appendedOverlay, "zip-with-trailing-overlay")
        let preview = try await ImpressV3BackupCoordinator.shared.inspectRecovery(destination)
        XCTAssertEqual(preview.cardCount, 1)
        XCTAssertEqual(preview.reviewCount, 0)
        XCTAssertEqual(preview.learningCount, 0)
        var broken = try Data(contentsOf: destination)
        // The first ZIP member is ReviewV3.sqlite; flip its first data byte.
        let nameBytes = "ReviewV3.sqlite".utf8.count
        let firstDataByte = 30 + nameBytes
        broken[firstDataByte] ^= 0x01
        let tampered = root.appendingPathComponent("tampered.zip")
        try broken.write(to: tampered)
        XCTAssertThrowsError(try ImpressV3BackupArchive.extract(
            source: tampered, destination: root.appendingPathComponent("rejected")))

        // Correct ZIP CRC/SHA is not enough: logical JSON must also decode.
        try Data("malformed-json".utf8).write(
            to: stage.appendingPathComponent("LearningEntry-v1.json"))
        let invalidRecords = try names.map {
            try ImpressV3BackupArchive.inspectFile(
                stage.appendingPathComponent($0), name: $0).0
        }
        try JSONEncoder().encode(ImpressV3BackupManifest.make(invalidRecords)).write(
            to: stage.appendingPathComponent("manifest.json"))
        let invalidArchive = root.appendingPathComponent("invalid-json.zip")
        try ImpressV3BackupArchive.write(files:
            (names + ["manifest.json"]).map { (name: $0,
                url: stage.appendingPathComponent($0)) }, destination: invalidArchive)
        do {
            _ = try await ImpressV3BackupCoordinator.shared.inspectRecovery(invalidArchive)
            XCTFail("A complete ZIP with invalid learning JSON must be rejected")
        } catch is DecodingError { }
    }


    func testCalibrationV2ZIPRoundTripAndLegacyManifestCompatibility() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("CalV2ZIP-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = try ReviewWCDBRepository(
            databasePath: root.appendingPathComponent("source.sqlite").path,
            calculator: FSRS6ReviewCalculator())
        let id = UUID()
        let calc = FSRS6ReviewCalculator()
        let now = Date(timeIntervalSince1970: 1_720_000_000)
        let image = Data([0xFF, 0xD8, 0xFF, 0xD9])
        try await repository.insertNewCard(
            WCDBV3CardInput(cardID: id, question: "Image V3.2",
                cardType: 3, imageData: image),
            initial: try calc.newCardSnapshot(id: id, now: now), now: now)
        _ = try await repository.commit(ReviewSubmission(
            eventID: UUID(), cardID: id, expectedRevision: 0,
            rating: .good, reviewedAt: now.addingTimeInterval(1)))
        let stage = root.appendingPathComponent("stage", isDirectory: true)
        try FileManager.default.createDirectory(at: stage, withIntermediateDirectories: true)
        try await repository.createConsistentBackup(
            to: stage.appendingPathComponent("ReviewV3.sqlite"))
        try Data("[]".utf8).write(to: stage.appendingPathComponent("LearningEntry-v1.json"))
        let prompts = [ImpressV3PromptTemplate(title: "Custom prompt", content: "Remember me")]
        try JSONEncoder().encode(prompts).write(to: stage.appendingPathComponent("prompts.json"))
        let store = ImpressCalibrationLocalStore(
            storageURL: root.appendingPathComponent("checkins-v1.json"))
        var day = try await store.checkIn(on: now)
        for kind in CalibrationIndicator.behaviorIndicators {
            try day.setOutcome(.completed, for: kind)
        }
        try day.setMood(nil, assessed: true)
        try await store.save(day)
        try await store.archiveData().write(
            to: stage.appendingPathComponent("checkins-v1.json"))
        let names = ["ReviewV3.sqlite", "LearningEntry-v1.json",
                     "prompts.json", "checkins-v1.json"]
        let records = try names.map {
            try ImpressV3BackupArchive.inspectFile(
                stage.appendingPathComponent($0), name: $0).0
        }
        let manifest = ImpressV3BackupManifest.make(records)
        XCTAssertEqual(manifest.formatVersion, 2)
        try JSONEncoder().encode(manifest).write(
            to: stage.appendingPathComponent("manifest.json"))
        let zip = root.appendingPathComponent("v2.zip")
        try ImpressV3BackupArchive.write(files:
            (names + ["manifest.json"]).map {
                (name: $0, url: stage.appendingPathComponent($0))
            }, destination: zip)
        let checked = try await ImpressV3BackupCoordinator.shared.inspectRecovery(zip)
        XCTAssertEqual(checked.manifest.formatVersion, 2)
        XCTAssertEqual(checked.cardCount, 1)
        XCTAssertEqual(checked.reviewCount, 1)
        XCTAssertEqual(checked.calibrationCount, 1)
        let unpack = root.appendingPathComponent("unpacked")
        let extracted = try ImpressV3BackupArchive.extract(source: zip, destination: unpack)
        XCTAssertEqual(extracted.count, 5)
        let calibratedBytes = try Data(contentsOf:
            unpack.appendingPathComponent("checkins-v1.json"))
        XCTAssertEqual(try ImpressCalibrationLocalStore.validateArchiveData(
            calibratedBytes), 1)
        let restoredDB = try ReviewWCDBRepository(
            databasePath: unpack.appendingPathComponent("ReviewV3.sqlite").path,
            calculator: calc)
        let actualImage = try await restoredDB.content(for: id)
        XCTAssertEqual(actualImage?.imageData, image)
        let persisted = try await restoredDB.reviewHistory(for: id)
        XCTAssertEqual(persisted.count, 1)

        // A matching CRC/SHA does not make an invalid calibration ledger safe.
        try Data("corrupt-ledger".utf8).write(
            to: stage.appendingPathComponent("checkins-v1.json"))
        let brokenRecords = try names.map {
            try ImpressV3BackupArchive.inspectFile(
                stage.appendingPathComponent($0), name: $0).0
        }
        try JSONEncoder().encode(ImpressV3BackupManifest.make(brokenRecords)).write(
            to: stage.appendingPathComponent("manifest.json"))
        let bad = root.appendingPathComponent("bad-v2.zip")
        try ImpressV3BackupArchive.write(files:
            (names + ["manifest.json"]).map {
                (name: $0, url: stage.appendingPathComponent($0))
            }, destination: bad)
        do {
            _ = try await ImpressV3BackupCoordinator.shared.inspectRecovery(bad)
            XCTFail("Malformed calibration ledger must prevent recovery")
        } catch is DecodingError { }
    }

    func testBackupGenerationRejectsMidSnapshotWritesWithoutClearingDirty() throws {
        let suite = "test.snapshot-epoch." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let key = "ImpressV3LastMutationGeneration"
        let dirty = ImpressV3BackupCoordinator.dirtyKey
        defaults.set("start", forKey: key)
        defaults.set(true, forKey: dirty)
        XCTAssertFalse(ImpressV3BackupCoordinator.testReconcileSnapshotDirty(
            startingGeneration: "start", defaults: defaults))
        XCTAssertFalse(defaults.bool(forKey: dirty))
        defaults.set("next-commit", forKey: key)
        XCTAssertTrue(ImpressV3BackupCoordinator.testReconcileSnapshotDirty(
            startingGeneration: "start", defaults: defaults))
        XCTAssertTrue(defaults.bool(forKey: dirty))
        defaults.set("next-commit-again", forKey: key)
        XCTAssertTrue(ImpressV3BackupCoordinator.testReconcileSnapshotDirty(
            startingGeneration: "next-commit", defaults: defaults))
        XCTAssertTrue(defaults.bool(forKey: dirty))
    }

    func testColdRestoreFaultRollsBackCalibrationPromptsJournalAndSQLite() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("restore-fault-" + UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let support = root.appendingPathComponent("support", isDirectory: true)
        let docs = root.appendingPathComponent("docs", isDirectory: true)
        let live = docs.appendingPathComponent("ImpressV3", isDirectory: true)
        let calibration = root.appendingPathComponent("calibration/checkins-v1.json")
        let pending = support.appendingPathComponent(
            "ImpressV3PendingRestore", isDirectory: true)
        let journal = support.appendingPathComponent("ImpressV3/LearningEntry-v1.json")
        for location in [live, pending, journal.deletingLastPathComponent()] {
            try FileManager.default.createDirectory(
                at: location, withIntermediateDirectories: true)
        }
        let suiteName = "test.calibration.restore." + UUID().uuidString
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            XCTFail("Isolated defaults unavailable"); return
        }
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let calc = FSRS6ReviewCalculator()
        let date = Date(timeIntervalSince1970: 1_720_000_000)
        let originalID = UUID()
        let priorDB = try ReviewWCDBRepository(
            databasePath: root.appendingPathComponent("old-source/ReviewV3.sqlite").path,
            calculator: calc)
        try await priorDB.insertNewCard(
            WCDBV3CardInput(cardID: originalID, question: "Keep original", answerText: "old"),
            initial: try calc.newCardSnapshot(id: originalID, now: date), now: date)
        // Only the source fixture is ever opened in a WCDB pool. The live
        // destination mimics a fully closed app at the next cold launch.
        try await priorDB.createConsistentBackup(
            to: live.appendingPathComponent("ReviewV3.sqlite"))
        let priorLearning = [ImpressV3LearningEntry(
            id: UUID(), cardID: originalID, question: "old entry",
            userAnswer: "old answer", createdAt: date, aiEvaluation: nil)]
        try JSONEncoder().encode(priorLearning).write(to: journal, options: .atomic)
        let priorPrompts = [ImpressV3PromptTemplate(title: "Before", content: "before")]
        let priorPromptBytes = try JSONEncoder().encode(priorPrompts)
        defaults.set(priorPromptBytes, forKey: ImpressV3PromptLibrary.storageKey)
        let priorCalibration = ImpressCalibrationLocalStore(storageURL: calibration)
        var oldDay = try await priorCalibration.checkIn(on: date)
        try oldDay.setOutcome(.completed, for: .sleep)
        try await priorCalibration.save(oldDay)
        let priorCalibrationBytes = try Data(contentsOf: calibration)

        // W10: use the real Widget cache writer against a disposable directory.
        // Never touch the signed App Group or the user's authoritative ledger.
        var widgetCalendar = Calendar(identifier: .gregorian)
        widgetCalendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let isolatedWidgetRoot = root.appendingPathComponent(
            "widget-fixture", isDirectory: true)
        let widgetFile = isolatedWidgetRoot.appendingPathComponent(
            ImpressCalibrationWidgetExporter.snapshotName)
        let priorSnapshot = CalibrationWidgetProjection.snapshot(
            from: try await priorCalibration.history(),
            at: date.addingTimeInterval(600), calendar: widgetCalendar)
        XCTAssertEqual(priorSnapshot.days.first?.state, .partial)
        let initialWidgetWrite = try await ImpressCalibrationWidgetExporter
            .testPublishFixtureSnapshot(priorSnapshot, into: isolatedWidgetRoot)
        XCTAssertTrue(initialWidgetWrite)
        let priorWidgetBytes = try Data(contentsOf: widgetFile)
        XCTAssertEqual(try JSONDecoder().decode(
            CalibrationWidgetSnapshot.self, from: priorWidgetBytes), priorSnapshot)

        let nextID = UUID()
        let newRepo = try ReviewWCDBRepository(
            databasePath: root.appendingPathComponent("next/ReviewV3.sqlite").path,
            calculator: calc)
        try await newRepo.insertNewCard(
            WCDBV3CardInput(cardID: nextID, question: "Restored", answerText: "new"),
            initial: try calc.newCardSnapshot(id: nextID, now: date), now: date)
        _ = try await newRepo.commit(ReviewSubmission(
            eventID: UUID(), cardID: nextID, expectedRevision: 0,
            rating: .good, reviewedAt: date.addingTimeInterval(1)))
        try await newRepo.createConsistentBackup(
            to: pending.appendingPathComponent("ReviewV3.sqlite"))
        let nextLearning = [ImpressV3LearningEntry(
            id: UUID(), cardID: nextID, question: "new entry",
            userAnswer: "new answer", createdAt: date, aiEvaluation: "new feedback")]
        try JSONEncoder().encode(nextLearning).write(
            to: pending.appendingPathComponent("LearningEntry-v1.json"))
        let nextPrompts = [ImpressV3PromptTemplate(
            title: "After", content: "after restore")]
        try JSONEncoder().encode(nextPrompts).write(
            to: pending.appendingPathComponent("prompts.json"))
        let nextCalibration = ImpressCalibrationLocalStore(
            storageURL: root.appendingPathComponent("next/checkins-v1.json"))
        var nextDay = try await nextCalibration.checkIn(on: date)
        for kind in CalibrationIndicator.behaviorIndicators {
            try nextDay.setOutcome(.completed, for: kind)
        }
        try nextDay.setMood(2)
        try await nextCalibration.save(nextDay)
        let nextLedger = try await nextCalibration.archiveData()
        try nextLedger.write(to: pending.appendingPathComponent("checkins-v1.json"))
        let names = ["ReviewV3.sqlite", "LearningEntry-v1.json",
                     "prompts.json", "checkins-v1.json"]
        let entries = try names.map {
            try ImpressV3BackupArchive.inspectFile(
                pending.appendingPathComponent($0), name: $0).0
        }
        try JSONEncoder().encode(ImpressV3BackupManifest.make(entries)).write(
            to: pending.appendingPathComponent("manifest.json"))

        do {
            try ImpressV3BackupCoordinator.testApplyPendingAtColdLaunch(
                root: support, documents: docs, calibration: calibration,
                prompts: defaults, failAfterCalibration: true)
            XCTFail("Injected failure after calibration replacement must rollback")
        } catch ImpressV3BackupFailure.invalidArchive { }

        XCTAssertTrue(FileManager.default.fileExists(atPath: pending.path))
        let rollbackInspection = root.appendingPathComponent("rollback-inspection.sqlite")
        try FileManager.default.copyItem(
            at: live.appendingPathComponent("ReviewV3.sqlite"),
            to: rollbackInspection)
        let rolledBack = try ReviewWCDBRepository(
            databasePath: rollbackInspection.path, calculator: calc)
        let oldCard = try await rolledBack.content(for: originalID)
        XCTAssertEqual(oldCard?.question, "Keep original")
        let absentNewCard = try await rolledBack.content(for: nextID)
        XCTAssertNil(absentNewCard)
        XCTAssertEqual(try Data(contentsOf: calibration), priorCalibrationBytes)
        XCTAssertEqual(try Data(contentsOf: widgetFile), priorWidgetBytes,
            "Failed multi-file restore cannot publish uncommitted Widget state")
        XCTAssertEqual(try JSONDecoder().decode([ImpressV3LearningEntry].self,
            from: Data(contentsOf: journal)), priorLearning)
        XCTAssertEqual(defaults.data(forKey: ImpressV3PromptLibrary.storageKey),
                       priorPromptBytes)

        // Simulate a process kill after SQLite, learning, prompts and
        // calibration were replaced, bypassing ordinary Swift error rollback.
        do {
            try ImpressV3BackupCoordinator.testApplyPendingAtColdLaunch(
                root: support, documents: docs, calibration: calibration,
                prompts: defaults, simulateHardTerminationAfterCalibration: true)
            XCTFail("Expected simulated hard termination")
        } catch ImpressV3BackupFailure.invalidArchive { }
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: support.appendingPathComponent("ImpressV3RestoreTransaction").path))
        XCTAssertTrue(defaults.bool(forKey: ImpressV3BackupCoordinator.recoveryBlockKey),
            "Synthetic transaction interruption must block only its own restore")
        do {
            try ImpressV3BackupCoordinator.testApplyPendingAtColdLaunch(
                root: support, documents: docs, calibration: calibration,
                prompts: defaults)
            XCTFail("Cold start must stop after repairing interrupted restore")
        } catch ImpressV3BackupFailure.restoreInterrupted { }
        XCTAssertFalse(defaults.bool(forKey: ImpressV3BackupCoordinator.recoveryBlockKey),
            "A repaired synthetic rollback must clear its isolated restore lock")
        let repairedDB = root.appendingPathComponent("repaired-interruption.sqlite")
        try FileManager.default.copyItem(
            at: live.appendingPathComponent("ReviewV3.sqlite"), to: repairedDB)
        let repaired = try ReviewWCDBRepository(
            databasePath: repairedDB.path, calculator: calc)
        let repairedOldCard = try await repaired.content(for: originalID)
        let repairedUnexpectedCard = try await repaired.content(for: nextID)
        XCTAssertEqual(repairedOldCard?.question, "Keep original")
        XCTAssertNil(repairedUnexpectedCard)
        XCTAssertEqual(try Data(contentsOf: calibration), priorCalibrationBytes)
        XCTAssertEqual(try Data(contentsOf: widgetFile), priorWidgetBytes,
            "Interrupted cold restore rollback keeps the old Widget projection")
        XCTAssertEqual(defaults.data(forKey: ImpressV3PromptLibrary.storageKey),
                       priorPromptBytes)
        XCTAssertEqual(try JSONDecoder().decode([ImpressV3LearningEntry].self,
            from: Data(contentsOf: journal)), priorLearning)
        XCTAssertTrue(FileManager.default.fileExists(atPath: pending.path))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: support.appendingPathComponent("ImpressV3RestoreTransaction").path))

        try ImpressV3BackupCoordinator.testApplyPendingAtColdLaunch(
            root: support, documents: docs, calibration: calibration,
            prompts: defaults)
        XCTAssertFalse(FileManager.default.fileExists(atPath: pending.path))
        let completedInspection = root.appendingPathComponent("completed-inspection.sqlite")
        try FileManager.default.copyItem(
            at: live.appendingPathComponent("ReviewV3.sqlite"),
            to: completedInspection)
        let installed = try ReviewWCDBRepository(
            databasePath: completedInspection.path, calculator: calc)
        let installedCard = try await installed.content(for: nextID)
        XCTAssertEqual(installedCard?.question, "Restored")
        let installedEvents = try await installed.reviewHistory(for: nextID)
        XCTAssertEqual(installedEvents.count, 1)
        XCTAssertEqual(try JSONDecoder().decode([ImpressV3LearningEntry].self,
            from: Data(contentsOf: journal)), nextLearning)
        // JSONEncoder does not guarantee byte ordering of Codable keyed
        // properties. Verify restored semantic content; the earlier rollback
        // assertion still requires byte-for-byte preservation of prior data.
        let restoredPromptData = try XCTUnwrap(
            defaults.data(forKey: ImpressV3PromptLibrary.storageKey))
        let restoredPrompts = try JSONDecoder().decode(
            [ImpressV3PromptTemplate].self, from: restoredPromptData)
        XCTAssertEqual(restoredPrompts, nextPrompts)
        XCTAssertEqual(try ImpressCalibrationLocalStore.validateArchiveData(
            Data(contentsOf: calibration)), 1)

        // Reopen the restored source from disk like a new process and republish
        // through the same isolated cache writer used by the production app.
        // This checks both the recovered CLOSED facts and stale-writer immunity.
        let coldStore = ImpressCalibrationLocalStore(storageURL: calibration)
        let restoredSnapshot = CalibrationWidgetProjection.snapshot(
            from: try await coldStore.history(),
            at: date.addingTimeInterval(720), calendar: widgetCalendar)
        XCTAssertEqual(restoredSnapshot.days.first?.state, .finalized)
        XCTAssertEqual(restoredSnapshot.days.first?.assessedCount, 4)
        XCTAssertEqual(restoredSnapshot.days.first?.netScore, 4)
        let updatedWidget = try await ImpressCalibrationWidgetExporter
            .testPublishFixtureSnapshot(restoredSnapshot, into: isolatedWidgetRoot)
        XCTAssertTrue(updatedWidget)
        let restoredWidgetBytes = try Data(contentsOf: widgetFile)
        XCTAssertNotEqual(restoredWidgetBytes, priorWidgetBytes)
        XCTAssertEqual(try JSONDecoder().decode(
            CalibrationWidgetSnapshot.self, from: restoredWidgetBytes), restoredSnapshot)
        let staleWriterAccepted = try await ImpressCalibrationWidgetExporter
            .testPublishFixtureSnapshot(priorSnapshot, into: isolatedWidgetRoot)
        XCTAssertFalse(staleWriterAccepted,
            "Late pre-restore publishes must never replace the restored CLOSED projection")
        XCTAssertEqual(try Data(contentsOf: widgetFile), restoredWidgetBytes)
    }

    func testNewCardCommitsOneEventAndRetriesIdempotently() async throws {
        let path = temporaryPath()
        let calculator = FSRS6ReviewCalculator()
        let repository = try ReviewWCDBRepository(
            databasePath: path, calculator: calculator)
        let cardID = UUID()
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let initial = try calculator.newCardSnapshot(id: cardID, now: now)
        try await repository.insertNewCard(
            WCDBV3CardInput(cardID: cardID, question: "Why recall before reading?",
                            answerText: "Active recall tests retrieval."),
            initial: initial, now: now)

        let request = ReviewSubmission(eventID: UUID(), cardID: cardID,
                                       expectedRevision: 0, rating: .good,
                                       reviewedAt: now)
        let first = try await repository.commit(request)
        let replay = try await repository.commit(request)
        XCTAssertEqual(first, replay)
        XCTAssertEqual(first.before.revision, 0)
        XCTAssertEqual(first.after.revision, 1)
        let events = try await repository.reviewHistory(for: cardID)
        XCTAssertEqual(events.count, 1)
        let candidates = try await repository.fetchQueueCandidates()
        XCTAssertEqual(candidates[0].revision, 1)
        XCTAssertEqual(candidates[0].status, .learning)
    }

    func testStaleRevisionCannotCreateSecondRating() async throws {
        let path = temporaryPath()
        let calculator = FSRS6ReviewCalculator()
        let repository = try ReviewWCDBRepository(databasePath: path,
                                                   calculator: calculator)
        let cardID = UUID()
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        try await repository.insertNewCard(
            WCDBV3CardInput(cardID: cardID, question: "Q", answerText: "A"),
            initial: calculator.newCardSnapshot(id: cardID, now: now), now: now)
        _ = try await repository.commit(ReviewSubmission(
            eventID: UUID(), cardID: cardID, expectedRevision: 0,
            rating: .good, reviewedAt: now))
        do {
            _ = try await repository.commit(ReviewSubmission(
                eventID: UUID(), cardID: cardID, expectedRevision: 0,
                rating: .easy, reviewedAt: now))
            XCTFail("A second distinct rating with an old revision must fail")
        } catch ReviewWCDBError.revisionConflict { }
        let events = try await repository.reviewHistory(for: cardID)
        XCTAssertEqual(events.count, 1)
    }

    func testCalculatorFailureRollsBackAndPreservesRevision() async throws {
        let path = temporaryPath()
        let calculator = FSRS6ReviewCalculator()
        let repo = try ReviewWCDBRepository(databasePath: path,
                                             calculator: FailingReviewCalculator())
        let cardID = UUID()
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        try await repo.insertNewCard(
            WCDBV3CardInput(cardID: cardID, question: "Q", answerText: "A"),
            initial: calculator.newCardSnapshot(id: cardID, now: now), now: now)
        do {
            _ = try await repo.commit(ReviewSubmission(
                eventID: UUID(), cardID: cardID, expectedRevision: 0,
                rating: .hard, reviewedAt: now))
            XCTFail("Expected injected failure")
        } catch ForcedSchedulingError.fixtureFailure { }
        let candidates = try await repo.fetchQueueCandidates()
        XCTAssertEqual(candidates[0].revision, 0)
        let history = try await repo.reviewHistory(for: cardID)
        XCTAssertEqual(history.count, 0)
    }

    func testImageAndMultipleChoicePayloadsSurvivePersistence() async throws {
        let path = temporaryPath()
        let calculator = FSRS6ReviewCalculator()
        let repo = try ReviewWCDBRepository(databasePath: path, calculator: calculator)
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let imageID = UUID()
        let pixels = Data([0xFF, 0xD8, 0xFF, 0xD9])
        try await repo.insertNewCard(
            WCDBV3CardInput(cardID: imageID, question: "Identify this image",
                            cardType: 3, imageData: pixels),
            initial: calculator.newCardSnapshot(id: imageID, now: now), now: now)
        let multipleID = UUID()
        try await repo.insertNewCard(
            WCDBV3CardInput(cardID: multipleID, question: "Choose two",
                            choices: "A\nB\nC", correctIndices: "0,2", cardType: 2),
            initial: calculator.newCardSnapshot(id: multipleID, now: now), now: now)
        let image = try await repo.content(for: imageID)
        XCTAssertEqual(image?.imageData, pixels)
        let multiple = try await repo.content(for: multipleID)
        XCTAssertEqual(multiple?.choices, "A\nB\nC")
        XCTAssertEqual(multiple?.correctIndices, "0,2")
        let candidates = try await repo.fetchQueueCandidates()
        XCTAssertEqual(candidates.count, 2)
    }

    func testDueCountUsesFSRSDueAndExcludesNewInventory() async throws {
        let path = temporaryPath()
        let calculator = FSRS6ReviewCalculator()
        let repo = try ReviewWCDBRepository(databasePath: path, calculator: calculator)
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let cardID = UUID()
        try await repo.insertNewCard(
            WCDBV3CardInput(cardID: cardID, question: "Q", answerText: "A"),
            initial: calculator.newCardSnapshot(id: cardID, now: now), now: now)
        let beforeCount = try await repo.dueCount(at: now)
        XCTAssertEqual(beforeCount, 0)
        _ = try await repo.commit(ReviewSubmission(
            eventID: UUID(), cardID: cardID, expectedRevision: 0,
            rating: .good, reviewedAt: now))
        let immediateCount = try await repo.dueCount(at: now)
        let laterCount = try await repo.dueCount(at: now.addingTimeInterval(11*60))
        XCTAssertEqual(immediateCount, 0)
        XCTAssertEqual(laterCount, 1)
    }
    func testFractionalSecondClockSurvivesFSRSWCDBRoundTrip() async throws {
        let path = temporaryPath()
        let calculator = FSRS6ReviewCalculator()
        let repository = try ReviewWCDBRepository(databasePath: path, calculator: calculator)
        let id = UUID()
        let at = Date(timeIntervalSince1970: 1_700_000_000.1234567)
        try await repository.insertNewCard(
            WCDBV3CardInput(cardID: id, question: "Fractional date", answerText: "A"),
            initial: calculator.newCardSnapshot(id: id, now: at), now: at)
        let event = try await repository.commit(ReviewSubmission(
            eventID: UUID(), cardID: id, expectedRevision: 0,
            rating: .easy, reviewedAt: at.addingTimeInterval(1.25)))
        XCTAssertEqual(event.rating, .easy)
        XCTAssertEqual(event.after.revision, 1)
        let history = try await repository.reviewHistory(for: id)
        XCTAssertEqual(history.count, 1)
    }

    func testSnapshotPreservesCommittedStateWithoutStoppingFutureWrites() async throws {
        let original = temporaryPath()
        let calculator = FSRS6ReviewCalculator()
        let repo = try ReviewWCDBRepository(databasePath: original, calculator: calculator)
        let cardID = UUID()
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        try await repo.insertNewCard(
            WCDBV3CardInput(cardID: cardID, question: "Q", answerText: "A"),
            initial: calculator.newCardSnapshot(id: cardID, now: now), now: now)
        _ = try await repo.commit(ReviewSubmission(
            eventID: UUID(), cardID: cardID, expectedRevision: 0,
            rating: .good, reviewedAt: now))
        let backup = URL(fileURLWithPath: original).deletingLastPathComponent()
            .appendingPathComponent("safe-backup.sqlite")
        try await repo.createConsistentBackup(to: backup)
        let restored = try ReviewWCDBRepository(
            databasePath: backup.path, calculator: calculator)
        let oldHistory = try await repo.reviewHistory(for: cardID)
        let backupHistory = try await restored.reviewHistory(for: cardID)
        XCTAssertEqual(backupHistory, oldHistory)
        let remaining = try await repo.fetchQueueCandidates()
        XCTAssertEqual(remaining.first?.revision, 1)
    }

}


// P0-0: These tests create disposable sandbox fixtures only. They never read,
// write, select or import the user's real Obsidian/iCloud directory.
@MainActor
final class ImVaultSafetyTests: XCTestCase {
    private func fixtureRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ImpressVaultSafety-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    func testObsidianOutlineFoldsAndSearchesWithoutLosingSourceIdentity() throws {
        let names = ["Notes/One.md", "Notes/Physics/One.md",
                     "Reading/One.md", "Root.md", "Notes/Physics/Diagram.md"]
        let records = try names.map { name in
            ImVaultIndexNote(identity: try ImVaultFileIdentity(
                vaultID: "synthetic-vault", relativePath: name),
                bytes: 24, modified: nil)
        }

        let collapsed = ImVaultListPresentation.outlineRows(
            in: records, query: "", expandedFolders: [])
        XCTAssertEqual(collapsed.map(\.title), ["Notes", "Reading", "Root"])
        XCTAssertEqual(collapsed.map(\.depth), [0, 0, 0])
        XCTAssertNotNil(collapsed.first?.folderPath)
        XCTAssertNil(collapsed.last?.folderPath)

        let oneFolder = ImVaultListPresentation.outlineRows(
            in: records, query: "", expandedFolders: ["Notes"])
        XCTAssertEqual(oneFolder.map(\.title),
                       ["Notes", "Physics", "One", "Reading", "Root"])
        XCTAssertEqual(oneFolder.map(\.depth), [0, 1, 1, 0, 0])
        XCTAssertEqual(oneFolder[1].folderPath, "Notes/Physics")

        let deep = ImVaultListPresentation.outlineRows(
            in: records, query: "", expandedFolders: ["Notes", "Notes/Physics"])
        let duplicateTitles = deep.compactMap(\.note)
            .filter { $0.title == "One" }
        XCTAssertEqual(duplicateTitles.count, 2)
        XCTAssertEqual(Set(duplicateTitles.map(\.identity.relativePath)),
                       Set(["Notes/One.md", "Notes/Physics/One.md"]))

        // Search projects matching descendants and ancestors without altering
        // the saved fold state. Do not show complete paths as row titles.
        let search = ImVaultListPresentation.outlineRows(
            in: records, query: "Notes/Physics/One", expandedFolders: [])
        XCTAssertEqual(search.map(\.title), ["Notes", "Physics", "One"])
        XCTAssertEqual(search.map(\.depth), [0, 1, 2])
        XCTAssertEqual(search.last?.note?.identity.relativePath,
                       "Notes/Physics/One.md")
        XCTAssertEqual(ImVaultListPresentation.outlineRows(
            in: records, query: "", expandedFolders: []).map(\.title),
                       collapsed.map(\.title))
        XCTAssertEqual(ImVaultListPresentation.page(deep, limit: 2).count, 2)

        let otherVault = try ImVaultIndexNote(identity: ImVaultFileIdentity(
            vaultID: "other-vault", relativePath: "Notes/One.md"),
            bytes: 12, modified: nil)
        let crossVault = ImVaultListPresentation.outlineRows(
            in: [records[0], otherVault], query: "One",
            expandedFolders: [])
        XCTAssertEqual(crossVault.compactMap(\.note).count, 2)
        XCTAssertEqual(Set(crossVault.compactMap(\.note).map(\.identity.vaultID)),
                       Set(["synthetic-vault", "other-vault"]))
    }

    func testVaultFolderBrowsingAndBoundedPagesKeepDistinctPathIdentities() throws {
        let names = ["Notes/One.md", "Notes/Physics/One.md",
                     "Reading/One.md", "Root.md"]
        let records = try names.map { path in
            ImVaultIndexNote(identity: try ImVaultFileIdentity(
                vaultID: "fixture-vault", relativePath: path), bytes: 10, modified: nil)
        }
        XCTAssertEqual(ImVaultListPresentation.folders(in: records),
                       ["Notes", "Notes/Physics", "Reading"])
        let selection = ImVaultListPresentation.matched(
            records, query: "one", folder: "Notes")
        XCTAssertEqual(selection.map(\.identity.relativePath),
                       ["Notes/One.md", "Notes/Physics/One.md"])
        XCTAssertEqual(ImVaultListPresentation.matched(
            records, query: "reading/", folder: nil).count, 1)
        let large = try (0..<265).map { n in
            ImVaultIndexNote(identity: try ImVaultFileIdentity(
                vaultID: "fixture-vault", relativePath: "Large/note-\(n).md"),
                bytes: 1, modified: nil)
        }
        XCTAssertEqual(ImVaultListPresentation.page(large, limit: 120).count, 120)
        XCTAssertEqual(ImVaultListPresentation.page(large, limit: 240).count, 240)
        XCTAssertEqual(ImVaultListPresentation.page(large, limit: 360).count, 265)
        XCTAssertEqual(Set(large.map(\.identity)).count, 265)
    }

    func testVaultEnumerationReportsBoundedBatchesAndLeavesSourceUntouched() throws {
        let root = try fixtureRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let collection = root.appendingPathComponent("Articles", isDirectory: true)
        try FileManager.default.createDirectory(at: collection,
                                                withIntermediateDirectories: true)
        for n in 0..<265 {
            try "# Article \(n)".write(
                to: collection.appendingPathComponent("note-\(n).md"),
                atomically: true, encoding: .utf8)
        }
        var sizes: [Int] = []
        let listed = try ImVaultReadSync.list(root: root, vaultID: "local-fixture",
            onBatch: { sizes.append($0.count) })
        XCTAssertEqual(listed.count, 265)
        XCTAssertEqual(sizes.reduce(0, +), 265)
        XCTAssertTrue(sizes.allSatisfy { $0 > 0 && $0 <= 128 })
        XCTAssertEqual(try String(contentsOf: collection.appendingPathComponent("note-0.md"),
                                  encoding: .utf8), "# Article 0")
    }

    func testFirstImportCopiesNewDestinationWithoutChangingSource() throws {
        let root = try fixtureRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source", isDirectory: true)
        let destination = root.appendingPathComponent("ImpressVault", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        let sourceFile = source.appendingPathComponent("one.md")
        try "# Original\n[[Link]]".write(to: sourceFile, atomically: true, encoding: .utf8)

        try ImVaultSafeImporter.copyOnlyWhenAbsent(from: source, to: destination)
        XCTAssertEqual(try String(contentsOf: sourceFile, encoding: .utf8), "# Original\n[[Link]]")
        XCTAssertEqual(try String(contentsOf: destination.appendingPathComponent("one.md"),
                                  encoding: .utf8), "# Original\n[[Link]]")
        let names = try FileManager.default.contentsOfDirectory(atPath: root.path)
        XCTAssertFalse(names.contains(where: { $0.hasPrefix(".impress-vault-import-") }))
    }

    func testRepeatImportNeverDestroysUserModifiedVault() throws {
        let root = try fixtureRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source", isDirectory: true)
        let destination = root.appendingPathComponent("ImpressVault", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        try "# New content".write(to: source.appendingPathComponent("note.md"),
                                   atomically: true, encoding: .utf8)
        let existingFile = destination.appendingPathComponent("note.md")
        let original = "---\ntitle: private\n---\n# Keep my edits\n[[Original]]"
        try original.write(to: existingFile, atomically: true, encoding: .utf8)

        XCTAssertThrowsError(try ImVaultSafeImporter.copyOnlyWhenAbsent(
            from: source, to: destination))
        XCTAssertEqual(try String(contentsOf: existingFile, encoding: .utf8), original)
        XCTAssertEqual(try String(contentsOf: source.appendingPathComponent("note.md"),
                                  encoding: .utf8), "# New content")
        let names = try FileManager.default.contentsOfDirectory(atPath: root.path)
        XCTAssertFalse(names.contains(where: { $0.hasPrefix(".impress-vault-import-") }))
    }

    func testSameNamedMarkdownFilesHaveDistinctFolderIdentity() {
        let a = ImVaultNoteIdentity(title: "Untitled", directory: "/Studies/Physics")
        let b = ImVaultNoteIdentity(title: "Untitled", directory: "/Studies/Biology")
        let alias = ImVaultNoteIdentity(title: "Untitled", directory: "Studies/Physics/")
        XCTAssertNotEqual(a, b)
        XCTAssertEqual(a, alias)
    }

    func testLegacyOverwriteAPIIsExplicitlyDisabled() {
        var returnedError: Error?
        ImObsidianManager.shared.writeMarkdownFile(
            from: UIViewController(), at: "test.md", content: "# Must not write") { error in
            returnedError = error
        }
        XCTAssertNotNil(returnedError)
        XCTAssertTrue(returnedError?.localizedDescription.contains("旧版覆盖写回已停用") == true)
    }
}


// P0-2/3/4/5 simulation: disposable test Vault ONLY. No user document picker,
// iCloud container or original Obsidian file is accessed. Coordinator, local
// draft persistence and recovery are the same code paths used by the app.
@MainActor
final class ImVaultSyncIntegrationTests: XCTestCase {
    private func createRoot() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(
            "ImVaultIntegration-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func put(_ content: String, root: URL, path: String = "Notes/Topic.md") throws -> URL {
        let file = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try Data(content.utf8).write(to: file, options: .atomic)
        return file
    }

    func testReadOnlyIndexAndOnDemandReadNeverTouchSource() throws {
        let root = try createRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let body = "---\ntags: [inbox]\n---\n# Title\n![[graph.png]]\n"
        let url = try put(body, root: root)
        let original = try Data(contentsOf: url)
        try put("# Other", root: root, path: "Different/Topic.md")
        let index = try ImVaultReadSync.list(root: root, vaultID: "Fixture")
        XCTAssertEqual(index.count, 2)
        XCTAssertNotEqual(index[0].identity, index[1].identity)
        let id = try ImVaultFileIdentity(vaultID: "Fixture", relativePath: "Notes/Topic.md")
        let read = try ImVaultReadSync.load(root: root, identity: id)
        XCTAssertEqual(read.sourceBytes, original)
        XCTAssertEqual(read.markdown, body)
        XCTAssertEqual(try Data(contentsOf: url), original)
    }

    func testPrivateDraftCanBeRecoveredAfterControllerRecreation() throws {
        let root = try createRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let text = "---\noriginal: yes\n---\n# Original\n[[Keep]]"
        let url = try put(text, root: root)
        let id = try ImVaultFileIdentity(vaultID: UUID().uuidString,
                                         relativePath: "Notes/Topic.md")
        let source = try ImVaultReadSync.load(root: root, identity: id)
        var draft = try ImVaultDraft(identity: id, baseText: source.markdown,
                                     baseRawData: source.sourceBytes)
        try draft.update(text + "\nadditional idea")
        try ImVaultPrivateStore.saveDraft(draft)
        let restored = try XCTUnwrap(ImVaultPrivateStore.loadDraft(identity: id))
        XCTAssertEqual(restored.identity, draft.identity)
        XCTAssertEqual(restored.baseDigest, draft.baseDigest)
        XCTAssertEqual(restored.baseRawData, draft.baseRawData)
        XCTAssertEqual(restored.editedText, draft.editedText)
        XCTAssertEqual(try Data(contentsOf: url), source.sourceBytes)
    }

    func testSameFileConflictsNeverOverwriteExternalEdit() throws {
        let root = try createRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = try put("source text", root: root)
        let id = try ImVaultFileIdentity(vaultID: UUID().uuidString,
                                         relativePath: "Notes/Topic.md")
        let doc = try ImVaultReadSync.load(root: root, identity: id)
        var draft = try ImVaultDraft(identity: id, baseText: doc.markdown,
                                     baseRawData: doc.sourceBytes)
        try draft.update("Impress edit")
        try Data("Obsidian edit".utf8).write(to: url, options: .atomic)
        XCTAssertThrowsError(try ImVaultGuardedWrite.commitFixture(
            root: root, draft: draft, userConfirmedDiff: true))
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "Obsidian edit")
        XCTAssertEqual(draft.editedText, "Impress edit")
    }

    func testVaultReceiptNeverConfusesNoOpLocalWriteAndCloudSync() throws {
        XCTAssertFalse(ImVaultGuardedWrite.productionWriteEnabled)
        let unchanged = ImVaultWriteReceiptText.present(
            .success(.unchanged), testCopy: true)
        XCTAssertTrue(unchanged.title.contains("未变化"))
        XCTAssertTrue(unchanged.detail.contains("没有写入"))
        let idempotent = ImVaultWriteReceiptText.present(
            .success(.alreadyApplied), testCopy: true)
        XCTAssertTrue(idempotent.detail.contains("没有重复写入"))
        let verified = ImVaultWriteReceiptText.present(
            .success(.written(recoveryURL: URL(fileURLWithPath: "/tmp/fixture-backup"))),
            testCopy: true)
        XCTAssertTrue(verified.title.contains("测试副本"))
        XCTAssertTrue(verified.detail.contains("云端"))
        XCTAssertTrue(verified.detail.contains("不代表"))
        let rejected = ImVaultWriteReceiptText.present(
            .failure(ImVaultSyncFailure.conflict), testCopy: true)
        XCTAssertTrue(rejected.title.contains("未确认"))
        XCTAssertFalse(rejected.detail.contains("已在本机写入"))
    }

    func testUserApprovalRequiredAndSuccessfulFixtureWriteIsRecoverable() throws {
        let root = try createRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let original = "# Learn\n[[Link]]"
        let file = try put(original, root: root)
        let id = try ImVaultFileIdentity(vaultID: UUID().uuidString,
                                         relativePath: "Notes/Topic.md")
        let source = try ImVaultReadSync.load(root: root, identity: id)
        var draft = try ImVaultDraft(identity: id, baseText: source.markdown,
                                     baseRawData: source.sourceBytes)
        try draft.update("# Learn\n[[Link]]\n- My understanding")
        XCTAssertThrowsError(try ImVaultGuardedWrite.commitFixture(
            root: root, draft: draft, userConfirmedDiff: false))
        XCTAssertEqual(try Data(contentsOf: file), source.sourceBytes)
        let written = try ImVaultGuardedWrite.commitFixture(
            root: root, draft: draft, userConfirmedDiff: true)
        switch written {
        case let .written(recoveryURL):
            XCTAssertEqual(try Data(contentsOf: recoveryURL), source.sourceBytes)
            XCTAssertEqual(try String(contentsOf: file, encoding: .utf8),
                           draft.editedText)
        default:
            XCTFail("Expected a single verified fixture write with private recovery")
        }
        let replay = try ImVaultGuardedWrite.commitFixture(
            root: root, draft: draft, userConfirmedDiff: true)
        if case .alreadyApplied = replay {
            // idempotent second submission has no overwrite side-effect
        } else {
            XCTFail("Replay must not write source again")
        }
    }


    func testComplexMarkdownQAWritePreservesUnrelatedSourceAndRecoveryBytes() throws {
        let root = try createRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let original = """
        ---
        tags: [learning, note]
        ---
        # 学习

        - [[概念图]]
        - ![[示意图.png]]

        | A | B |
        |---|---|
        | 原理 | 应用 |

        ```swift
        print("do not modify fenced code")
        ```
        """
        let sourceFile = try put(original, root: root)
        let identity = try ImVaultFileIdentity(
            vaultID: UUID().uuidString, relativePath: "Notes/Topic.md")
        let raw = try ImVaultReadSync.load(root: root, identity: identity)
        var draft = try ImVaultDraft(identity: identity, baseText: raw.markdown,
                                    baseRawData: raw.sourceBytes)
        let updated = original + "\n\n## 我的新理解\n增加了与原文相关的解释。\n"
        try draft.update(updated)
        let result = try ImVaultGuardedWrite.commitFixture(
            root: root, draft: draft, userConfirmedDiff: true)
        guard case let .written(recovery) = result else {
            XCTFail("Expected exact UTF-8 write and byte-for-byte recovery")
            return
        }
        XCTAssertEqual(try Data(contentsOf: recovery), raw.sourceBytes)
        XCTAssertEqual(try Data(contentsOf: sourceFile), Data(updated.utf8))
        XCTAssertTrue(updated.contains("[[概念图]]"))
        XCTAssertTrue(updated.contains("![[示意图.png]]"))
        XCTAssertTrue(updated.contains("print(\"do not modify fenced code\")"))
        XCTAssertFalse(ImVaultGuardedWrite.productionWriteEnabled)
    }

    func testConcurrentExternalVaultEditDoesNotDestroySavedPrivateDraft() throws {
        let root = try createRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let sourceFile = try put("# First\n[[Keep]]", root: root)
        let identity = try ImVaultFileIdentity(
            vaultID: UUID().uuidString, relativePath: "Notes/Topic.md")
        let original = try ImVaultReadSync.load(root: root, identity: identity)
        var draft = try ImVaultDraft(
            identity: identity, baseText: original.markdown,
            baseRawData: original.sourceBytes)
        try draft.update("# First\n[[Keep]]\nnew idea")
        try ImVaultPrivateStore.saveDraft(draft)
        let external = Data("# First\nchanged in Obsidian".utf8)
        try external.write(to: sourceFile, options: .atomic)

        XCTAssertThrowsError(try ImVaultGuardedWrite.commitFixture(
            root: root, draft: draft, userConfirmedDiff: true))
        XCTAssertEqual(try Data(contentsOf: sourceFile), external)
        let recovered = try XCTUnwrap(ImVaultPrivateStore.loadDraft(identity: identity))
        XCTAssertEqual(recovered.editedText, draft.editedText)
        XCTAssertEqual(recovered.baseDigest, draft.baseDigest)
    }

    func testDocumentViewerIsNotAnEditableSourceTextView() throws {
        let root = try createRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = "# Heading\n[[Obsidian link]]\n> Callout\n"
        let file = try put(source, root: root)
        let id = try ImVaultFileIdentity(vaultID: UUID().uuidString,
                                         relativePath: "Notes/Topic.md")
        let original = try Data(contentsOf: file)
        let doc = try ImVaultReadSync.load(root: root, identity: id)
        let viewer = ImVaultDocumentController(document: doc)
        viewer.loadViewIfNeeded()
        let textViews = viewer.view.subviews.compactMap { $0 as? UITextView }
        XCTAssertEqual(textViews.count, 1)
        XCTAssertFalse(textViews[0].isEditable)
        // The latest product contract groups secondary note actions under a
        // single More menu; only the shared Chat entry remains directly visible.
        // Reading or opening navigation must never mutate source Markdown bytes.
        XCTAssertEqual(viewer.navigationItem.rightBarButtonItems?.count, 2)
        XCTAssertEqual(viewer.navigationItem.rightBarButtonItems?.first?
            .accessibilityIdentifier, "impress.notes.ai-discussion")
        XCTAssertEqual(viewer.navigationItem.rightBarButtonItems?.last?
            .accessibilityLabel, V3L("更多笔记操作"))
        XCTAssertEqual(try Data(contentsOf: file), original)
    }

    func testDeviceQAWriteRequiresExactExplicitFolderNameAndProductionRemainsLocked() throws {
        XCTAssertFalse(ImVaultGuardedWrite.productionWriteEnabled)
        #if DEBUG
        let parent = FileManager.default.temporaryDirectory.appendingPathComponent(
            "ImpressQAPredicate-" + UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: parent) }
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        let testFolder = parent.appendingPathComponent(
            ImVaultGuardedWrite.deviceQAFolderName, isDirectory: true)
        try FileManager.default.createDirectory(at: testFolder,
                                                withIntermediateDirectories: true)
        XCTAssertTrue(ImVaultGuardedWrite.isExplicitQAVault(testFolder))
        XCTAssertFalse(ImVaultGuardedWrite.isExplicitQAVault(parent))
        XCTAssertFalse(ImVaultGuardedWrite.isExplicitQAVault(
            parent.appendingPathComponent(ImVaultGuardedWrite.deviceQAFolderName + "-Old")))
        let nonTestVault = parent.appendingPathComponent("OriginalVault", isDirectory: true)
        try FileManager.default.createDirectory(at: nonTestVault,
                                                withIntermediateDirectories: true)
        XCTAssertFalse(ImVaultGuardedWrite.isExplicitQAVault(nonTestVault))
        #endif
    }

    func testDiffReviewNamesExactMarkdownTargetAndBaselineBeforeConfirmation() throws {
        let identity = try ImVaultFileIdentity(
            vaultID: "disposable-qa-vault",
            relativePath: "Notes/Chapter/Concept.md")
        var draft = try ImVaultDraft(identity: identity, baseText: "# Old source")
        try draft.update("# Revised source")
        let view = ImVaultDiffController(draft: draft,
            summary: "- # Old source\n+ # Revised source", canApprove: false)
        view.loadViewIfNeeded()
        let visible = try XCTUnwrap(view.view.subviews.compactMap { $0 as? UITextView }.first)
        XCTAssertTrue(visible.text.contains("Notes/Chapter/Concept.md"))
        XCTAssertTrue(visible.text.contains(draft.baseDigest))
        XCTAssertTrue(visible.text.contains("+ # Revised source"))
        XCTAssertFalse(view.navigationItem.rightBarButtonItem?.isEnabled ?? true)
        XCTAssertFalse(ImVaultGuardedWrite.productionWriteEnabled)
    }

    func testIncompleteSourceDiffNeverActivatesDeviceWriteAction() throws {
        let id = try ImVaultFileIdentity(vaultID: UUID().uuidString,
                                         relativePath: "Only/Test.md")
        var draft = try ImVaultDraft(identity: id, baseText: "# Source")
        try draft.update("# Source\nmore")
        let diff = ImVaultDiffController(
            draft: draft, summary: "Incomplete preview", canApprove: false)
        diff.loadViewIfNeeded()
        XCTAssertFalse(diff.navigationItem.rightBarButtonItem?.isEnabled ?? true)
        XCTAssertFalse(ImVaultGuardedWrite.productionWriteEnabled)
    }

    func testDebugFixtureWriteCannotTargetUserDocumentsDirectory() throws {
        let documents = try XCTUnwrap(FileManager.default.urls(
            for: .documentDirectory, in: .userDomainMask).first)
        let identity = try ImVaultFileIdentity(
            vaultID: "TEST-NON-TEMP", relativePath: "must-not-create.md")
        var draft = try ImVaultDraft(identity: identity, baseText: "source")
        try draft.update("new text")
        let candidate = documents.appendingPathComponent(identity.relativePath)
        let wasPresent = FileManager.default.fileExists(atPath: candidate.path)
        XCTAssertThrowsError(try ImVaultGuardedWrite.commitFixture(
            root: documents, draft: draft, userConfirmedDiff: true))
        XCTAssertEqual(FileManager.default.fileExists(atPath: candidate.path), wasPresent)
    }

    func testMissingSourceFailsClosedWithoutRecreatingFile() throws {
        let root = try createRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = try put("Delete externally", root: root)
        let id = try ImVaultFileIdentity(vaultID: UUID().uuidString,
                                         relativePath: "Notes/Topic.md")
        let doc = try ImVaultReadSync.load(root: root, identity: id)
        var draft = try ImVaultDraft(identity: id, baseText: doc.markdown,
                                     baseRawData: doc.sourceBytes)
        try draft.update("Keep only as private draft")
        try FileManager.default.removeItem(at: file) // disposable fixture only
        XCTAssertThrowsError(try ImVaultGuardedWrite.commitFixture(
            root: root, draft: draft, userConfirmedDiff: true))
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
    }


    func testSafeMarkdownProjectionEmbedsOnlyLocalImagesAndNeverChangesSource() throws {
        let root = try createRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let userMarkdown = """
        # Notes
        ![[attachment.png]]
        ![remote](https://tracking.example/pixel.png)
        <img src="https://tracking.example/leak">
        """
        let file = try put(userMarkdown, root: root)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let image = UIGraphicsImageRenderer(
            size: CGSize(width: 120, height: 90), format: format).image { context in
            UIColor.systemBlue.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 120, height: 90))
        }
        try XCTUnwrap(image.pngData()).write(
            to: root.appendingPathComponent("attachment.png"), options: .atomic)
        let identity = try ImVaultFileIdentity(
            vaultID: UUID().uuidString, relativePath: "Notes/Topic.md")
        let preview = try ImVaultReadSync.safeMarkdownProjection(
            root: root, identity: identity, source: userMarkdown)
        XCTAssertTrue(preview.contains("data:image/jpeg;base64,"))
        XCTAssertFalse(preview.contains("<img"))
        XCTAssertFalse(preview.contains("![remote](https://"))
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), userMarkdown)
    }

    func testAmbiguousLocalAttachmentNeverPicksWrongPhoto() throws {
        let root = try createRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let image = UIGraphicsImageRenderer(
            size: CGSize(width: 40, height: 30), format: format).image { context in
            UIColor.systemTeal.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 40, height: 30))
        }
        try XCTUnwrap(image.pngData()).write(
            to: put("reserved", root: root, path: "A/image.png"), options: .atomic)
        try XCTUnwrap(image.pngData()).write(
            to: put("reserved", root: root, path: "B/image.png"), options: .atomic)
        let identity = try ImVaultFileIdentity(
            vaultID: UUID().uuidString, relativePath: "Notes/Topic.md")
        let rendered = try ImVaultReadSync.safeMarkdownProjection(
            root: root, identity: identity, source: "![[image.png]]")
        XCTAssertFalse(rendered.contains("data:image"))
    }

    func testEscapingAttachmentSymlinkDoesNotBlockEntireNotePreview() throws {
        let root = try createRoot()
        let outside = try createRoot()
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: outside)
        }
        let picture = outside.appendingPathComponent("outside.png")
        try Data([0x89, 0x50, 0x4E, 0x47]).write(to: picture, options: .atomic)
        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent("outside.png"), withDestinationURL: picture)
        let id = try ImVaultFileIdentity(
            vaultID: "fixture", relativePath: "some-note.md")
        let original = "# Keep reading\n![[outside.png]]"
        let projected = try ImVaultReadSync.safeMarkdownProjection(
            root: root, identity: id, source: original)
        XCTAssertTrue(projected.contains("Keep reading"))
        XCTAssertFalse(projected.contains("data:image"))
        XCTAssertTrue(projected.contains("outside.png"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: picture.path))
    }

    func testSymlinkOutsideVaultIsNeverRead() throws {
        let root = try createRoot()
        let outside = try createRoot()
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: outside)
        }
        let file = try put("# Private", root: outside, path: "secret.md")
        let link = root.appendingPathComponent("secret.md")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: file)
        let id = try ImVaultFileIdentity(vaultID: "fixture", relativePath: "secret.md")
        XCTAssertThrowsError(try ImVaultReadSync.load(root: root, identity: id))
    }
}


@MainActor
final class ImpressImageOptimizerTests: XCTestCase {
    private func sampleImage(size: CGSize, scale: CGFloat = 3,
                             textMode: Bool = false) -> UIImage {
        let f = UIGraphicsImageRendererFormat()
        f.scale = scale
        f.opaque = true
        return UIGraphicsImageRenderer(size: size, format: f).image { context in
            UIColor.white.setFill()
            context.fill(CGRect(origin: .zero, size: size))
            if textMode {
                for row in 0..<60 {
                    let r = CGRect(x: 15, y: CGFloat(row * 11 + 10),
                                   width: size.width - 30, height: 3)
                    UIColor.black.setFill()
                    context.fill(r)
                }
            } else {
                UIColor.systemBlue.setFill()
                context.fill(CGRect(x: 0, y: 0,
                                    width: size.width * 0.50,
                                    height: size.height * 0.50))
                UIColor.systemRed.setFill()
                context.fill(CGRect(x: size.width * 0.45,
                                    y: size.height * 0.45,
                                    width: size.width * 0.40,
                                    height: size.height * 0.40))
            }
        }
    }

    func testLargePhotoEncodesToBoundedBytesAndPixels() throws {
        let source = sampleImage(size: CGSize(width: 1400, height: 850))
        XCTAssertGreaterThan(source.cgImage!.width, 1280)
        let bytes = try ImpressImageOptimizer.optimize(source, kind: .photo)
        XCTAssertLessThanOrEqual(bytes.count, ImpressImageOptimizer.maximumEncodedBytes)
        let restored = try XCTUnwrap(UIImage(data: bytes))
        XCTAssertLessThanOrEqual(restored.cgImage!.width, 1280)
        XCTAssertLessThanOrEqual(restored.cgImage!.height, 1280)
        XCTAssertGreaterThan(restored.cgImage!.width, 0)
    }

    func testHighDPIImageResizesByPixelsNotByDeviceScale() throws {
        let source = sampleImage(size: CGSize(width: 700, height: 450), scale: 3)
        XCTAssertEqual(source.cgImage?.width, 2100)
        let data = try ImpressImageOptimizer.optimize(source)
        let image = try XCTUnwrap(UIImage(data: data))
        XCTAssertLessThanOrEqual(image.cgImage!.width, 1280)
        XCTAssertLessThanOrEqual(image.cgImage!.height, 1280)
        XCTAssertLessThanOrEqual(data.count, ImpressImageOptimizer.maximumEncodedBytes)
    }

    func testImageDocumentModePreservesMorePixelsWithinStorageCap() throws {
        let sample = sampleImage(size: CGSize(width: 850, height: 700), scale: 2,
                                 textMode: true)
        let compressed = try ImpressImageOptimizer.optimize(sample, kind: .document)
        XCTAssertLessThanOrEqual(compressed.count, ImpressImageOptimizer.maximumEncodedBytes)
        let restored = try XCTUnwrap(UIImage(data: compressed))
        XCTAssertLessThanOrEqual(restored.cgImage!.width, 2000)
        XCTAssertLessThanOrEqual(restored.cgImage!.height, 2000)
    }

    func testInvalidImageAndTinyStorageBudgetDoNotPersistAnUnusableBlob() {
        XCTAssertThrowsError(try ImpressImageOptimizer.optimize(UIImage()))
        let sample = sampleImage(size: CGSize(width: 80, height: 80), scale: 1)
        XCTAssertThrowsError(try ImpressImageOptimizer.optimize(sample, maxBytes: 128))
    }
}


@MainActor
final class ImpressV3NativeFlowTests: XCTestCase {
    func testCaptureCancelDoesNotCreateLearningEntry() throws {
        let before = try ImpressV3LearningJournal.load().count
        let capture = ImpressV3CaptureViewController(cardID: UUID(), question: "Q")
        capture.loadViewIfNeeded()
        // No save callback, no record. A sheet is deliberately ephemeral
        // until the user taps the explicit Submit action.
        XCTAssertEqual(try ImpressV3LearningJournal.load().count, before)
        XCTAssertEqual(capture.navigationItem.rightBarButtonItem?.title, "提交")
        XCTAssertEqual(capture.navigationItem.leftBarButtonItem?.style, .plain)
    }

    func testLearningEntryPersistenceAndAIFeedbackAreVersioned() throws {
        let id = UUID()
        let card = UUID()
        let entry = ImpressV3LearningEntry(id: id, cardID: card, question: "Cause?",
            userAnswer: "Because of a testable mechanism.", createdAt: Date(),
            aiEvaluation: nil)
        try ImpressV3LearningJournal.save(entry)
        XCTAssertEqual(try ImpressV3LearningJournal.load().first(where: { $0.id == id })?.userAnswer,
                       entry.userAnswer)
        try ImpressV3LearningJournal.attachFeedback(
            "准确之处是因果链清楚；待改进之处是缺少反例。", to: id)
        let persisted = try XCTUnwrap(ImpressV3LearningJournal.load().first { $0.id == id })
        XCTAssertNotNil(persisted.aiEvaluation)
        XCTAssertEqual(persisted.cardID, card)
        // Same submission ID can never append a duplicate version.
        try ImpressV3LearningJournal.save(entry)
        XCTAssertEqual(try ImpressV3LearningJournal.load().filter { $0.id == id }.count, 1)
    }

    func testUnderstandingAnswerEditsPreserveOriginalFeedbackAndHistory() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "ImpressLearningEdit-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root,
                                                withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let path = root.appendingPathComponent("LearningEntry-v1.json")
        let id = UUID()
        let original = ImpressV3LearningEntry(
            id: id, cardID: UUID(), question: "Explain the mechanism",
            userAnswer: "First understanding", createdAt: Date(timeIntervalSince1970: 1_720_000_000),
            aiEvaluation: "Evaluation belongs to the original submission")
        try JSONEncoder().encode([original]).write(to: path, options: .atomic)
        let first = try ImpressV3LearningJournal.testUpdateAnswer(
            id: id, expectedAnswer: original.userAnswer,
            editedAnswer: "Improved understanding", at: path,
            now: Date(timeIntervalSince1970: 1_730_000_000))
        XCTAssertEqual(first.userAnswer, "Improved understanding")
        XCTAssertEqual(first.revisions?.count, 1)
        XCTAssertEqual(first.revisions?.first?.priorAnswer, original.userAnswer)
        XCTAssertEqual(first.aiEvaluation, original.aiEvaluation)
        XCTAssertEqual(first.createdAt, original.createdAt)
        XCTAssertEqual(first.cardID, original.cardID)
        let persisted = try JSONDecoder().decode(
            [ImpressV3LearningEntry].self, from: Data(contentsOf: path))
        XCTAssertEqual(persisted.count, 1)
        XCTAssertEqual(persisted.first?.revisions?.first?.priorAnswer, original.userAnswer)

        let beforeFailure = try Data(contentsOf: path)
        XCTAssertThrowsError(try ImpressV3LearningJournal.testUpdateAnswer(
            id: id, expectedAnswer: original.userAnswer,
            editedAnswer: "Overwrite", at: path)) { error in
                guard case ImpressV3LearningEditError.outdated = error else {
                    XCTFail("Expected stale revision conflict"); return
                }
            }
        XCTAssertThrowsError(try ImpressV3LearningJournal.testUpdateAnswer(
            id: id, expectedAnswer: first.userAnswer,
            editedAnswer: "   ", at: path))
        XCTAssertEqual(try Data(contentsOf: path), beforeFailure)
        let unchanged = try ImpressV3LearningJournal.testUpdateAnswer(
            id: id, expectedAnswer: first.userAnswer,
            editedAnswer: first.userAnswer, at: path)
        XCTAssertEqual(unchanged.revisions?.count, 1)
        let second = try ImpressV3LearningJournal.testUpdateAnswer(
            id: id, expectedAnswer: first.userAnswer,
            editedAnswer: "Third version", at: path)
        XCTAssertEqual(second.revisions?.map(\.priorAnswer),
                       [original.userAnswer, first.userAnswer])
        XCTAssertEqual(second.aiEvaluation, original.aiEvaluation)
    }

    func testUnderstandingDetailIsReadOnlyUntilExplicitEditorOpens() {
        let entry = ImpressV3LearningEntry(
            id: UUID(), cardID: UUID(), question: "Q",
            userAnswer: "Current answer", createdAt: Date(), aiEvaluation: nil)
        let viewer = ImpressV3UnderstandingDetailViewController(entry: entry)
        viewer.loadViewIfNeeded()
        XCTAssertEqual(viewer.navigationItem.rightBarButtonItem?.title, V3L("编辑"))
        XCTAssertEqual(viewer.tableView.numberOfSections, 3)
        let cell = viewer.tableView(viewer.tableView,
            cellForRowAt: IndexPath(row: 0, section: 1))
        XCTAssertEqual((cell.contentConfiguration as? UIListContentConfiguration)?.text,
                       "Current answer")
        XCTAssertEqual(viewer.tableView.style, .insetGrouped)
    }

    func testF12FixtureColdRestorePathsAreDisposableAndMatchWCDBStartup() throws {
        // AppDelegate must no longer skip restore in a synthetic cold start;
        // both the restore transaction and the repository must address ONE
        // disposable database, rather than the real app's support files.
        let fixtureID = UUID()
        let flag = ["-ImpressV11SyntheticVault"]
        XCTAssertEqual(ImpressV11UITestFixture.validatedID(
            arguments: flag, environment: ["IMPRESS_V11_FIXTURE_ID": fixtureID.uuidString]), fixtureID)
        XCTAssertNil(ImpressV11UITestFixture.validatedID(arguments: flag, environment: [:]),
            "Missing UUID must never create an implied production fixture")
        XCTAssertNil(ImpressV11UITestFixture.validatedID(
            arguments: flag, environment: ["IMPRESS_V11_FIXTURE_ID": "bad-uuid"]))
        XCTAssertNil(ImpressV11UITestFixture.validatedID(
            arguments: [], environment: ["IMPRESS_V11_FIXTURE_ID": fixtureID.uuidString]),
            "A UUID without the explicit test flag must not activate the fixture")
        let paths = ImpressV11UITestFixture.coldRestorePaths(for: fixtureID)
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(
            "ImpressV11-" + fixtureID.uuidString, isDirectory: true)
        let basePrefix = base.standardizedFileURL.path + "/"
        for url in [paths.support, paths.documents, paths.calibration,
                    paths.database] {
            XCTAssertTrue(url.standardizedFileURL.path.hasPrefix(basePrefix),
                          "Synthetic restore may never target real application files")
        }
        XCTAssertEqual(paths.database, paths.documents.appendingPathComponent(
            "ImpressV3/ReviewV3.sqlite"))
        XCTAssertEqual(paths.support.lastPathComponent, "Support")
        XCTAssertEqual(paths.promptsSuiteName,
                       "ImpressV11Restore-" + fixtureID.uuidString)
        let liveSupport = try FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: false).standardizedFileURL.path
        XCTAssertFalse(paths.support.path.hasPrefix(liveSupport + "/"))
        XCTAssertFalse(paths.database.path.hasPrefix(liveSupport + "/"))

        // Regression: before this batch even an empty synthetic cold start
        // cleared the REAL application's pending-recovery safety lock.
        let recoveryKey = ImpressV3BackupCoordinator.recoveryBlockKey
        let existingGlobalValue = UserDefaults.standard.object(forKey: recoveryKey)
        defer {
            if let existingGlobalValue {
                UserDefaults.standard.set(existingGlobalValue, forKey: recoveryKey)
            } else {
                UserDefaults.standard.removeObject(forKey: recoveryKey)
            }
        }
        UserDefaults.standard.set(true, forKey: recoveryKey)
        guard let isolatedDefaults = UserDefaults(
            suiteName: paths.promptsSuiteName) else {
            XCTFail("Fixture defaults suite unavailable")
            return
        }
        defer {
            isolatedDefaults.removePersistentDomain(forName: paths.promptsSuiteName)
        }
        isolatedDefaults.set(true, forKey: recoveryKey)
        try ImpressV3BackupCoordinator.testApplyPendingAtColdLaunch(
            root: paths.support, documents: paths.documents,
            calibration: paths.calibration, prompts: isolatedDefaults)
        XCTAssertTrue(UserDefaults.standard.bool(forKey: recoveryKey),
            "Synthetic launch must NEVER clear the user's real restore lock")
        XCTAssertFalse(isolatedDefaults.bool(forKey: recoveryKey),
            "An empty synthetic restore may only clear its own fixture lock")
        XCTAssertTrue(SceneDelegate.blocksDatabaseLaunch(recoveryDefaults: .standard),
            "A live-app pending restore must remain blocked after synthetic launch")
        XCTAssertFalse(SceneDelegate.blocksDatabaseLaunch(recoveryDefaults: isolatedDefaults),
            "The cleared fixture gate may open only its own recovered WCDB")
        isolatedDefaults.set(true, forKey: recoveryKey)
        XCTAssertTrue(SceneDelegate.blocksDatabaseLaunch(recoveryDefaults: isolatedDefaults),
            "An interrupted fixture restore must block its own WCDB launch")
        XCTAssertTrue(SceneDelegate.blocksDatabaseLaunch(recoveryDefaults: nil),
            "Missing fixture defaults must fail closed, not use the live app")
        XCTAssertFalse(ImVaultGuardedWrite.productionWriteEnabled)
    }

    func testF12SyntheticSettingsSnapshotNeverTouchesLiveArchiveOrPrivatePrompts() async throws {
        let fixtureID = UUID()
        let paths = ImpressV11UITestFixture.coldRestorePaths(for: fixtureID)
        let fm = FileManager.default
        let scopedRoot = fm.temporaryDirectory.appendingPathComponent(
            "ImpressV11-" + fixtureID.uuidString, isDirectory: true)
        defer { try? fm.removeItem(at: scopedRoot) }
        try fm.createDirectory(at: paths.database.deletingLastPathComponent(),
                               withIntermediateDirectories: true)
        let calculator = FSRS6ReviewCalculator()
        let repo = try ReviewWCDBRepository(
            databasePath: paths.database.path, calculator: calculator)
        let now = Date(timeIntervalSince1970: 1_726_000_000)
        let originalID = UUID()
        try await repo.insertNewCard(WCDBV3CardInput(
            cardID: originalID, question: "Synthetic before ZIP", answerText: "Safe"),
            initial: try calculator.newCardSnapshot(id: originalID, now: now), now: now)
        _ = try await repo.commit(ReviewSubmission(
            eventID: UUID(), cardID: originalID, expectedRevision: 0,
            rating: .good, reviewedAt: now))
        let source = "card:" + originalID.uuidString
        var session = WCDBV3ChatSession(sourceIdentity: source)
        var applied = WCDBV3DuplexProposal(
            sourceMessageID: UUID(), noteIdentity: nil,
            noteBaseDigest: nil, noteEditedDigest: nil,
            cardID: originalID, cardReviewRevision: 1, cardContentRevision: 0,
            cardBaseQuestion: "Synthetic before ZIP", cardBaseAnswer: "Safe",
            cardEditedQuestion: "Synthetic before ZIP", cardEditedAnswer: "Safe",
            state: ImDuplexApprovalState(
                noteSelected: false, cardSelected: true, cardStatus: .applied))
        applied.cardReceipt = "Synthetic approved receipt survives ZIP restore"
        session.duplexHistory = [applied]
        try await repo.saveChatSession(session, expectedRevision: nil)

        let coordinator = ImpressV3BackupCoordinator.shared
        let archive = try await coordinator.testCreateFixtureBackup(
            paths: paths, repository: repo)
        XCTAssertTrue(archive.standardizedFileURL.path.hasPrefix(
            scopedRoot.standardizedFileURL.path + "/"),
            "Fixture ZIP must never be created in the real App Support directory")
        XCTAssertEqual(archive.pathExtension, "zip")
        let inspected = try await coordinator.testInspectFixtureRecovery(
            archive, paths: paths)
        XCTAssertEqual(inspected.cardCount, 1)
        XCTAssertEqual(inspected.reviewCount, 1)
        XCTAssertEqual(inspected.calibrationCount, 0)

        let unpacked = scopedRoot.appendingPathComponent("unpacked")
        _ = try ImpressV3BackupArchive.extract(source: archive, destination: unpacked)
        try ImpressV3BackupArchive.verifySQLite(
            unpacked.appendingPathComponent("ReviewV3.sqlite"))
        let templates = try JSONDecoder().decode([ImpressV3PromptTemplate].self,
            from: Data(contentsOf: unpacked.appendingPathComponent("prompts.json")))
        XCTAssertTrue(templates.isEmpty,
            "Synthetic backup must never read private live prompt templates")
        XCTAssertEqual(try ImpressCalibrationLocalStore.validateArchiveData(
            Data(contentsOf: unpacked.appendingPathComponent("checkins-v1.json"))), 0)

        // A legitimate newer card is saved AFTER the chosen ZIP was exported.
        // Restore must install the inspected ZIP, not silently keep the newer
        // WCDB or confuse the rollback snapshot with the selected archive.
        let newerID = UUID()
        try await repo.insertNewCard(WCDBV3CardInput(
            cardID: newerID, question: "Later legitimate card", answerText: "New"),
            initial: try calculator.newCardSnapshot(id: newerID, now: now), now: now)
        try await coordinator.testStageFixtureRecovery(
            archive, paths: paths, repository: repo)
        let pending = paths.support.appendingPathComponent("ImpressV3PendingRestore")
        XCTAssertTrue(fm.fileExists(atPath: pending.path),
            "The selected verified ZIP must be staged until a cold launch")
        do {
            try await coordinator.testStageFixtureRecovery(
                archive, paths: paths, repository: repo)
            XCTFail("A pending ZIP must reject a second restore before cold launch")
        } catch ImpressV3BackupFailure.restoreAlreadyPending {
            // Explicit new consent is required after completing the first restore.
        }
        let defaults = try XCTUnwrap(UserDefaults(suiteName: paths.promptsSuiteName))
        defer { defaults.removePersistentDomain(forName: paths.promptsSuiteName) }
        let liveRestoreGuard = UserDefaults.standard.object(
            forKey: ImpressV3BackupCoordinator.recoveryBlockKey)
        try ImpressV3BackupCoordinator.testApplyPendingAtColdLaunch(
            root: paths.support, documents: paths.documents,
            calibration: paths.calibration, prompts: defaults)
        XCTAssertFalse(fm.fileExists(atPath: pending.path))
        XCTAssertFalse(defaults.bool(forKey: ImpressV3BackupCoordinator.recoveryBlockKey))
        XCTAssertEqual(UserDefaults.standard.object(
            forKey: ImpressV3BackupCoordinator.recoveryBlockKey) as? Bool,
            liveRestoreGuard as? Bool,
            "A synthetic cold restore must not alter the live application's lock")

        // Reopen a file-level snapshot, as prior F12 Native crash tests do:
        // the production AppDelegate supplies the independent process
        // boundary; this service-level test does NOT claim XCUITest #17–18.
        let restoredCopy = scopedRoot.appendingPathComponent("cold-inspection.sqlite")
        try fm.copyItem(at: paths.database, to: restoredCopy)
        let restored = try ReviewWCDBRepository(
            databasePath: restoredCopy.path, calculator: calculator)
        let restoredCard = try await restored.content(for: originalID)
        let discardedNewerCard = try await restored.content(for: newerID)
        let events = try await restored.reviewHistory(for: originalID)
        let sessions = try await restored.chatSessions(for: source)
        XCTAssertEqual(restoredCard?.question, "Synthetic before ZIP")
        XCTAssertNil(discardedNewerCard)
        XCTAssertEqual(events.count, 1,
            "ZIP restore cannot erase a committed FSRS event")
        XCTAssertEqual(sessions.first?.duplexHistory?.first?.cardReceipt,
                       "Synthetic approved receipt survives ZIP restore")
        XCTAssertFalse(ImVaultGuardedWrite.productionWriteEnabled)
    }

    #if DEBUG
    /// User-selected Files export: byte-level verification and no-clobber
    /// policy. The real folder UI is exercised separately by F12 XCUITest.
    func testF12ManualFilesExportVerifiesCopyAndNeverOverwrites() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent(
            "Impress-manual-files-export-" + UUID().uuidString, isDirectory: true)
        let sourceDir = root.appendingPathComponent("AppSupport", isDirectory: true)
        let targetDir = root.appendingPathComponent("SelectedFiles", isDirectory: true)
        try fm.createDirectory(at: sourceDir, withIntermediateDirectories: true)
        try fm.createDirectory(at: targetDir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        let source = sourceDir.appendingPathComponent("verified-private-qa.zip")
        let payload = Data("synthetic-only-verified-zip-copy-\(UUID().uuidString)".utf8)
        try payload.write(to: source, options: .atomic)
        let target = try ImpressV3ManualFileExport.testCopyAndVerify(
            source, into: targetDir)
        XCTAssertEqual(try Data(contentsOf: target), payload)
        XCTAssertEqual(target.lastPathComponent, source.lastPathComponent)
        // The same path must reject a second export, rather than overwriting
        // an existing user file or reporting a false verified copy.
        XCTAssertThrowsError(try ImpressV3ManualFileExport.testCopyAndVerify(
            source, into: targetDir))
        XCTAssertEqual(try Data(contentsOf: target), payload)
        let notZIP = sourceDir.appendingPathComponent("not-an-archive.txt")
        try Data("no zip suffix".utf8).write(to: notZIP, options: .atomic)
        XCTAssertThrowsError(try ImpressV3ManualFileExport.testCopyAndVerify(
            notZIP, into: targetDir))
        XCTAssertFalse(fm.fileExists(atPath:
            targetDir.appendingPathComponent(notZIP.lastPathComponent).path))
        XCTAssertFalse(ImVaultGuardedWrite.productionWriteEnabled)
    }
    #endif

    @MainActor
    func testF12BackupRestorePickerCannotQueueSecondRestoreAndCancelUnlocks() async throws {
        let page = ImpressV3BackupSettingsViewController()
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.rootViewController = UINavigationController(rootViewController: page)
        window.makeKeyAndVisible()
        defer {
            page.dismiss(animated: false)
            window.isHidden = true
        }
        page.loadViewIfNeeded()
        let restore = IndexPath(row: 0, section: 2)
        XCTAssertTrue(page.tableView(page.tableView,
            cellForRowAt: restore).isUserInteractionEnabled)
        page.tableView(page.tableView, didSelectRowAt: restore)
        let presented = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "presentedViewController != nil"), object: page)
        await fulfillment(of: [presented], timeout: 12)
        let picker = try XCTUnwrap(page.presentedViewController
            as? UIDocumentPickerViewController)
        XCTAssertFalse(page.tableView(page.tableView,
            cellForRowAt: restore).isUserInteractionEnabled,
            "F12 restore must lock other actions BEFORE choosing a ZIP")
        page.tableView(page.tableView, didSelectRowAt: restore)
        XCTAssertTrue(page.presentedViewController === picker,
            "Second row tap must not queue another archive picker")
        page.documentPickerWasCancelled(picker)
        picker.dismiss(animated: false)
        XCTAssertTrue(page.tableView(page.tableView,
            cellForRowAt: restore).isUserInteractionEnabled,
            "Cancelling without selecting a ZIP must release the restore gate")
        XCTAssertFalse(ImVaultGuardedWrite.productionWriteEnabled)
    }

    @MainActor
    func testF12RestoreStagingActorRejectsReentryAcrossAwaitAndUnlocks() async throws {
        let entered = expectation(description: "first synthetic staging has started")
        let coordinator = ImpressV3BackupCoordinator.shared
        let first = Task {
            try await coordinator.testWithExclusiveRestoreStage {
                entered.fulfill()
                try await Task.sleep(nanoseconds: 1_500_000_000)
            }
        }
        await fulfillment(of: [entered], timeout: 8)
        do {
            try await coordinator.testWithExclusiveRestoreStage {
                XCTFail("A second restore must not enter the staging operation")
            }
            XCTFail("Actor reentry must not bypass pending-restore exclusivity")
        } catch ImpressV3BackupFailure.restoreAlreadyPending {
            // The first archive is still exclusively staged.
        }
        try await first.value
        try await coordinator.testWithExclusiveRestoreStage { }
        XCTAssertFalse(ImVaultGuardedWrite.productionWriteEnabled)
    }

    func testModernSettingsIncludesDataAndBackup() {
        let settings = ImpressV3SettingsHubViewController()
        settings.loadViewIfNeeded()
        XCTAssertEqual(settings.tableView.numberOfSections, 5)
        // AI Services/prompts share Content Tools. Learning Rhythm contains
        // Daily Calibration and Review Notifications (neither is a fourth Tab).
        XCTAssertEqual(settings.tableView.numberOfRows(inSection: 0), 2)
        XCTAssertEqual(settings.tableView.numberOfRows(inSection: 1), 2)
        XCTAssertEqual(settings.tableView.numberOfRows(inSection: 2), 2)
        XCTAssertEqual(settings.tableView.numberOfRows(inSection: 3), 1)
        XCTAssertEqual(settings.tableView.numberOfRows(inSection: 4), 1)
        let prompts = settings.tableView(settings.tableView,
            cellForRowAt: IndexPath(row: 0, section: 0))
        XCTAssertEqual((prompts.contentConfiguration as? UIListContentConfiguration)?.text,
                       V3L("AI 服务"))
        let promptCell = settings.tableView(settings.tableView,
            cellForRowAt: IndexPath(row: 1, section: 0))
        XCTAssertEqual((promptCell.contentConfiguration as? UIListContentConfiguration)?.text,
                       V3L("提示词"))
        let calibration = settings.tableView(settings.tableView,
            cellForRowAt: IndexPath(row: 0, section: 1))
        let reminders = settings.tableView(settings.tableView,
            cellForRowAt: IndexPath(row: 1, section: 1))
        XCTAssertEqual((calibration.contentConfiguration as? UIListContentConfiguration)?.text,
                       V3L("每日校准"))
        XCTAssertEqual((reminders.contentConfiguration as? UIListContentConfiguration)?.text,
                       V3L("复习通知"))
        let legacy = SettingsConfiguration.default
        XCTAssertEqual(legacy.displaySections.count, 1)
    }

    func testV3AppearanceIsBasedOnCentralColorAuthority() {
        XCTAssertEqual(ImpressV3Appearance.accent, funBtnColor)
        XCTAssertEqual(ImpressV3Appearance.primaryText, titleColor)
        XCTAssertEqual(ImpressV3Appearance.secondaryText, contentColor)
        XCTAssertEqual(ImpressV3Appearance.page, UIColor.systemGroupedBackground)
        XCTAssertEqual(ImpressV3Appearance.surface, UIColor.secondarySystemGroupedBackground)
        XCTAssertNotNil(ImpressV3Appearance.Typography.heading)
    }

    func testV3ReviewUsesExplicitRevealAndKeepsFourDirectionSwipeStack() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("V3Native-" + UUID().uuidString)
            .appendingPathComponent("v3.sqlite")
        let repo = try ReviewWCDBRepository(databasePath: root.path,
                                             calculator: FSRS6ReviewCalculator())
        let controller = ImpressV3ReviewViewController(repository: repo)
        let navigation = UINavigationController(rootViewController: controller)
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 320, height: 568))
        window.rootViewController = navigation
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        controller.loadViewIfNeeded()
        let buttons = controller.view.subviews.compactMap { $0 as? UIButton }
        XCTAssertTrue(buttons.contains { $0.title(for: .normal) == "查看答案" })
        let stacks = controller.view.subviews.compactMap { $0 as? SwipeCardStack }
        XCTAssertEqual(stacks.count, 1)
        XCTAssertTrue(stacks[0].protectsVerticalContentScroll)
        // Notes is now the middle Tab; the flashcard top-right keeps only
        // Card Collection, rather than a duplicate global Notes action.
        XCTAssertEqual(Set(controller.navigationItem.rightBarButtonItems?
            .compactMap(\.accessibilityLabel) ?? []), Set([V3L("卡片集")]))
        XCTAssertEqual(controller.navigationItem.rightBarButtonItems?.count, 1)
        XCTAssertEqual(controller.navigationItem.rightBarButtonItems?.first?
            .accessibilityIdentifier, "impress.review.card-collection")
        // The primary '+' directly opens the three-type native card editor.
        XCTAssertEqual(controller.navigationItem.leftBarButtonItem?.accessibilityLabel,
                       V3L("新增卡片"))
        // NAV-04 supersedes the old chart mandate: full calibration is not
        // embedded above the active review card or in the primary review path.
        XCTAssertNil(controller.view.subviews.first {
            $0.accessibilityIdentifier == "impress.review.calibration-week"
        })
        XCTAssertFalse(buttons.contains { $0.title(for: .normal) == "困难" })
        XCTAssertFalse(buttons.contains { $0.title(for: .normal) == "简单" })
    }
}


// R04.2-C: disposable WCDB fixtures; no production user database touched.
final class ImpressV3AtomicBatchTests: XCTestCase {
    private func fixture() throws -> ReviewWCDBRepository {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("ImpressBatch-" + UUID().uuidString)
            .appendingPathComponent("v3.sqlite")
        return try ReviewWCDBRepository(databasePath: path.path,
                                        calculator: FSRS6ReviewCalculator())
    }

    func testAtomicBatchPersistsAllWithFSRSZeroRevisionAndVaultPath() async throws {
        let repo = try fixture()
        let calculator = FSRS6ReviewCalculator()
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let source = try ImpressBatchSourceKey.encode(ImVaultFileIdentity(
            vaultID: "vault-A", relativePath: "First/Sub/笔记.md"))
        let a = WCDBV3CardInput(question: "第一题", answerText: "回答一", sourceNotePath: source)
        let b = WCDBV3CardInput(question: "第二题", answerText: "回答二")
        let result = try await repo.insertBatchCards([
            (a, try calculator.newCardSnapshot(id: a.cardID, now: now)),
            (b, try calculator.newCardSnapshot(id: b.cardID, now: now))
        ], now: now)
        XCTAssertEqual(result, 2)
        let candidates = try await repo.fetchQueueCandidates()
        XCTAssertEqual(candidates.count, 2)
        XCTAssertTrue(candidates.allSatisfy { $0.revision == 0 && $0.status == .new })
        let stored = try await repo.content(for: a.cardID)
        XCTAssertEqual(stored?.sourceNotePath, source)
        XCTAssertEqual(try ImpressBatchSourceKey.decode(stored!.sourceNotePath!), try ImVaultFileIdentity(
            vaultID: "vault-A", relativePath: "First/Sub/笔记.md"))
    }

    func testCollisionAfterFirstInsertRollsBackEntireTransaction() async throws {
        let repo = try fixture()
        let calculator = FSRS6ReviewCalculator()
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let existing = WCDBV3CardInput(question: "原有", answerText: "不可变")
        try await repo.insertNewCard(existing,
            initial: try calculator.newCardSnapshot(id: existing.cardID, now: now), now: now)
        let good = WCDBV3CardInput(question: "候选一", answerText: "只可全部提交")
        let collision = WCDBV3CardInput(cardID: existing.cardID, question: "候选二", answerText: "重复 ID")
        do {
            _ = try await repo.insertBatchCards([
                (good, try calculator.newCardSnapshot(id: good.cardID, now: now)),
                (collision, try calculator.newCardSnapshot(id: collision.cardID, now: now))
            ], now: now)
            XCTFail("Must fail atomically")
        } catch ReviewWCDBError.duplicateCard { }
        let snapshot = try await repo.fetchQueueCandidates()
        XCTAssertEqual(snapshot.count, 1)
        let rolledBackContent = try await repo.content(for: good.cardID)
        let existingContent = try await repo.content(for: existing.cardID)
        XCTAssertNil(rolledBackContent)
        XCTAssertEqual(existingContent?.answerText, "不可变")
    }

    func testInvalidAnswerOrDuplicateQuestionNeverPartiallyPersists() async throws {
        let repo = try fixture()
        let calculator = FSRS6ReviewCalculator()
        let now = Date()
        let a = WCDBV3CardInput(question: "Case", answerText: "A")
        let invalid = WCDBV3CardInput(question: "Missing", answerText: nil)
        do {
            _ = try await repo.insertBatchCards([
                (a, try calculator.newCardSnapshot(id: a.cardID, now: now)),
                (invalid, try calculator.newCardSnapshot(id: invalid.cardID, now: now))
            ], now: now)
            XCTFail("Reject a malformed card before any write")
        } catch ReviewWCDBError.invalidSchedulerOutput { }
        let b = WCDBV3CardInput(question: " case ", answerText: "B")
        do {
            _ = try await repo.insertBatchCards([
                (a, try calculator.newCardSnapshot(id: a.cardID, now: now)),
                (b, try calculator.newCardSnapshot(id: b.cardID, now: now))
            ], now: now)
            XCTFail("Reject duplicate content")
        } catch ReviewWCDBError.duplicateContent { }
        let remaining = try await repo.fetchQueueCandidates()
        XCTAssertEqual(remaining.count, 0)
    }

    @MainActor
    func testCreatingBatchPreviewWithoutConfirmationDoesNotWrite() async throws {
        let repo = try fixture()
        let input = WCDBV3CardInput(question: "Not confirmed", answerText: "No write")
        let parsed = ImpressBatchParser.parse("Q: Not confirmed\nA: No write", as: .text)
        XCTAssertEqual(parsed.count, 1)
        XCTAssertTrue(parsed[0].isValid)
        let found = try await repo.content(for: input.cardID)
        XCTAssertNil(found)
        let remaining = try await repo.fetchQueueCandidates()
        XCTAssertEqual(remaining.count, 0)

    }
}


@MainActor
final class ImpressV3BatchPreviewIntegrationTests: XCTestCase {
    func testInvalidCandidateDisablesAtomicCommit() {
        let parsed = ImpressBatchParser.parse("Q: 尚未回答", as: .text)
        let preview = ImpressV3BatchPreviewViewController(
            rows: parsed.map { ImpressV3BatchCandidate(parsed: $0, sourceKey: nil) })
        preview.loadViewIfNeeded()
        XCTAssertEqual(preview.rows.count, 1)
        XCTAssertEqual(preview.rows[0].raw, "Q: 尚未回答")
        let cell = preview.tableView(preview.tableView,
                                     cellForRowAt: IndexPath(row: 0, section: 0))
        XCTAssertEqual(cell.accessoryType, .detailDisclosureButton)
        XCTAssertFalse(preview.navigationItem.rightBarButtonItem?.isEnabled ?? true)
        XCTAssertEqual(preview.tableView.numberOfRows(inSection: 0), 1)
    }

    func testValidPreviewRequiresExplicitCommit() throws {
        let parsed = ImpressBatchParser.parse("Q: Why?\nA: Because.", as: .text)
        let preview = ImpressV3BatchPreviewViewController(
            rows: parsed.map { ImpressV3BatchCandidate(parsed: $0, sourceKey: nil) })
        preview.loadViewIfNeeded()
        XCTAssertTrue(preview.navigationItem.rightBarButtonItem?.isEnabled ?? false)
        XCTAssertEqual(preview.rows[0].draft.question, "Why?")
        XCTAssertNotNil(try preview.rows[0].draft.validatedInput())
    }
    func testConfirmAlertMustPrecedeAnyDatabaseCallback() {
        let parsed = ImpressBatchParser.parse("Q: What?\nA: A fact.", as: .text)
        let screen = ImpressV3BatchPreviewViewController(
            rows: parsed.map { ImpressV3BatchCandidate(parsed: $0, sourceKey: nil) })
        let navigation = UINavigationController(rootViewController: screen)
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 375, height: 667))
        window.rootViewController = navigation
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        var calls = 0
        screen.onCommit = { _ in calls += 1 }
        screen.loadViewIfNeeded()
        guard let button = screen.navigationItem.rightBarButtonItem,
              let action = button.action else {
            return XCTFail("Native import action missing")
        }
        UIApplication.shared.sendAction(action, to: button.target, from: button, for: nil)
        XCTAssertEqual(calls, 0)
        let alert = screen.presentedViewController as? UIAlertController
        XCTAssertNotNil(alert)
        XCTAssertEqual(alert?.actions.map(\.title), ["返回预览", "确认导入"])
        alert?.dismiss(animated: false)
    }

}


// New API surfaces may be reached without calling a live provider. UI tests
// must not create API keys, send network requests or alter the real Vault.
@MainActor
final class ImpressAICustomAPIUITests: XCTestCase {
    /// CHAT-05 / SAFE-08: consent is a separate pre-network state. Two
    /// rapid Send callbacks cannot create two competing remote scope prompts.
    @MainActor
    func testNativeChatRapidSendPresentsOnlyOneBoundedContextConsent() async throws {
        let priorIntro = UserDefaults.standard.object(
            forKey: "ImpressV11ChatIntroductionSeen")
        UserDefaults.standard.set(true, forKey: "ImpressV11ChatIntroductionSeen")
        defer {
            if let priorIntro {
                UserDefaults.standard.set(priorIntro,
                    forKey: "ImpressV11ChatIntroductionSeen")
            } else {
                UserDefaults.standard.removeObject(
                    forKey: "ImpressV11ChatIntroductionSeen")
            }
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "impress-chat-consent-" + UUID().uuidString)
        let repo = try ReviewWCDBRepository(
            databasePath: root.path, calculator: FSRS6ReviewCalculator())
        let source = "chat:consent-fixture:" + UUID().uuidString
        var session = WCDBV3ChatSession(sourceIdentity: source)
        session.messages = (0..<18).map { index in
            WCDBV3ChatMessage(role: .user,
                text: "Completed local history item " + String(index),
                status: .completed)
        }
        try await repo.saveChatSession(session, expectedRevision: nil)
        XCTAssertEqual(ImpressChatWindowPolicy.omittedCompletedCount(
            in: session.messages), 2)
        let chat = ImpressAINativeChatViewController(
            repository: repo, sourceKey: source)
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.rootViewController = UINavigationController(rootViewController: chat)
        window.makeKeyAndVisible()
        defer {
            chat.dismiss(animated: false)
            window.isHidden = true
        }
        chat.loadViewIfNeeded()
        func descendants(_ view: UIView) -> [UIView] {
            [view] + view.subviews.flatMap { descendants($0) }
        }
        let collection = try XCTUnwrap(descendants(chat.view)
            .compactMap { $0 as? UICollectionView }.first)
        for _ in 0..<100 {
            if collection.numberOfSections > 0,
               collection.numberOfItems(inSection: 0) >= 18 { break }
            try await Task.sleep(for: .milliseconds(30))
        }
        XCTAssertGreaterThanOrEqual(collection.numberOfItems(inSection: 0), 18,
            "The real stored history must load before triggering the consent gate")
        let input = try XCTUnwrap(descendants(chat.view)
            .compactMap { $0 as? UITextView }.first {
                $0.accessibilityIdentifier == "impress.ai.chat.input"
            })
        input.text = "Synthetic consent race; do not contact any provider."
        chat.textViewDidChange(input)
        let send = try XCTUnwrap(descendants(chat.view)
            .compactMap { $0 as? UIButton }.first {
                $0.accessibilityIdentifier == "impress.ai.chat.send"
            })
        XCTAssertTrue(send.isEnabled)
        send.sendActions(for: .touchUpInside)
        XCTAssertFalse(send.isEnabled,
            "The first tap must synchronously disable Send while consent is pending")
        let alert = try XCTUnwrap(chat.presentedViewController as? UIAlertController)
        XCTAssertEqual(alert.title, V3L("确认有限对话上下文"))
        // Force the callback despite disabled UIKit controls. The controller's
        // internal gate must protect against stale/double-dispatched events.
        XCTAssertTrue(UIApplication.shared.sendAction(
            NSSelectorFromString("submitOrStopMessage"),
            to: chat, from: send, for: nil))
        XCTAssertTrue(chat.presentedViewController === alert)
        XCTAssertEqual(alert.actions.count, 2)
        XCTAssertFalse(send.isEnabled)
        XCTAssertFalse(ImVaultGuardedWrite.productionWriteEnabled)
    }

    func testNativeChatHasPrivacyDisclosureAndSendIsInitiallyDisabled() {
        let conversation = ImpressAINativeChatViewController()
        conversation.loadViewIfNeeded()
        XCTAssertTrue(conversation.title?.isEmpty ?? true)
        XCTAssertNil(conversation.navigationItem.prompt)
        func descendants(_ view: UIView) -> [UIView] {
            [view] + view.subviews.flatMap { descendants($0) }
        }
        let elements = descendants(conversation.view)
        let send = elements.compactMap { $0 as? UIButton }.first {
            $0.accessibilityIdentifier == "impress.ai.chat.send"
        }
        XCTAssertNotNil(send)
        XCTAssertFalse(send?.isEnabled ?? true)
        XCTAssertNotNil(elements.compactMap { $0 as? UIButton }.first {
            $0.accessibilityIdentifier == "impress.ai.chat.add-material"
        })
        XCTAssertFalse(elements.compactMap { $0 as? UILabel }.contains {
            $0.text == V3L("对话与草稿保存在本机；只有点击发送并确认材料后才会发送给服务商。不会自动写入 Obsidian。")
        })
        XCTAssertFalse(ImVaultGuardedWrite.productionWriteEnabled)
    }

    func testV3RatingOverlayUsesCompactSemanticFeedback() {
        for direction in [SwipeDirection.left, .up, .right, .down] {
            let overlay = ImpressV3RatingOverlay(direction: direction)
            overlay.frame = CGRect(x: 0, y: 0, width: 300, height: 420)
            overlay.layoutIfNeeded()
            XCTAssertFalse(overlay.isUserInteractionEnabled)
            XCTAssertEqual(overlay.subviews.count, 1)
            XCTAssertEqual(overlay.subviews.first?.layer.borderWidth, 0)
            XCTAssertEqual(overlay.subviews.first?.layer.shadowOpacity, 0)
        }
    }


    func testAISettingsHasProviderAndTaskRoutingWithoutNewPrimaryTab() {
        let ai = ImpressAISettingsViewController()
        ai.loadViewIfNeeded()
        XCTAssertEqual(ai.tableView.numberOfSections, 3)
        XCTAssertEqual(ai.tableView(ai.tableView, numberOfRowsInSection: 1), 3)
        XCTAssertEqual(ai.navigationItem.rightBarButtonItem?.accessibilityLabel,
                       V3L("添加 API 连接"))
        let generation = ai.tableView(ai.tableView,
                         cellForRowAt: IndexPath(row: 0, section: 1))
        XCTAssertEqual((generation.contentConfiguration as? UIListContentConfiguration)?.text,
                       V3L("指定笔记出题"))
        let privacy = ai.tableView(ai.tableView,
                         cellForRowAt: IndexPath(row: 0, section: 2))
        XCTAssertEqual((privacy.contentConfiguration as? UIListContentConfiguration)?.text,
                       V3L("数据上传规则"))
    }

    func testSelectedNoteQuestionRouteNeverWritesSourceOnOpening() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ImpressAI-Vault-" + UUID().uuidString)
        let folder = root.appendingPathComponent("Study")
        try FileManager.default.createDirectory(at: folder,
                                                 withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let sourceURL = folder.appendingPathComponent("Knowledge.md")
        let original = Data("# 知识整理\n一个段落。\n\n## 应用\n已有原则。\n".utf8)
        try original.write(to: sourceURL)
        let identity = try ImVaultFileIdentity(vaultID: "fixture-" + UUID().uuidString,
                                                relativePath: "Study/Knowledge.md")
        let source = try ImVaultReadSync.load(root: root, identity: identity)
        let generator = ImpressAIQuestionGenerationViewController(document: source)
        generator.loadViewIfNeeded()
        XCTAssertEqual(generator.tableView.numberOfSections, 2)
        XCTAssertEqual(generator.tableView(generator.tableView, numberOfRowsInSection: 0), 1)
        XCTAssertGreaterThan(generator.tableView(generator.tableView,
                              numberOfRowsInSection: 1), 0)
        XCTAssertEqual(generator.navigationItem.rightBarButtonItem?.title, V3L("生成"))
        XCTAssertEqual(try Data(contentsOf: sourceURL), original)
        XCTAssertFalse(ImVaultGuardedWrite.productionWriteEnabled)
    }

    /// ACCEPT-01: the candidate pool must not queue two independent final
    /// consent sheets before its WCDB batch insertion lock becomes active.
    /// A synthetic document is displayed only; no real Vault or model call.
    @MainActor
    func testQuestionPoolRapidImportTapPresentsSingleConsentBeforeAnyWrite() throws {
        let identity = try ImVaultFileIdentity(
            vaultID: "qa-import-" + UUID().uuidString,
            relativePath: "Study/Mechanics.md")
        let markdown = "# Mechanics\nNet force is mass times acceleration.\n"
        let bytes = Data(markdown.utf8)
        let document = ImVaultRawDocument(
            identity: identity, sourceBytes: bytes, markdown: markdown,
            digest: ImVaultDigest.sha256(bytes))
        let section = try XCTUnwrap(
            ImpressAISectionExtractor.sections(in: markdown).first)
        let source = ImpressAISource(vaultID: identity.vaultID,
            relativePath: identity.relativePath,
            documentSHA256: document.digest, heading: section.heading)
        let excerpt = ImpressAIExcerpt(id: section.id, source: source,
            text: section.text, sectionHeading: section.heading)
        let pool = ImpressAIQuestionPool(source: source, excerpts: [excerpt],
            requestedCount: 1, modelProfileID: UUID(), candidates: [
                ImpressAIQuestionCandidate(
                    question: "What does F = ma describe?",
                    answer: "Net force, mass and acceleration.",
                    dimension: .mechanism, evidenceIDs: [excerpt.id])
            ])
        XCTAssertEqual(try ImpressAIQuestionValidator.validatedSelection(
            ImpressAIQuestionValidator.audit(pool)).count, 1)
        let page = ImpressAIQuestionPoolViewController(
            document: document, pool: pool)
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.rootViewController = UINavigationController(rootViewController: page)
        window.makeKeyAndVisible()
        defer {
            page.dismiss(animated: false)
            window.isHidden = true
        }
        page.loadViewIfNeeded()
        let item = try XCTUnwrap(page.navigationItem.rightBarButtonItem)
        let action = try XCTUnwrap(item.action)
        XCTAssertTrue(item.isEnabled)
        XCTAssertTrue(UIApplication.shared.sendAction(
            action, to: item.target, from: item, for: nil))
        XCTAssertFalse(item.isEnabled,
            "The first import tap must lock consent before the modal resolves")
        let sheet = try XCTUnwrap(page.presentedViewController as? UIAlertController)
        XCTAssertEqual(sheet.title, V3L("加入卡片集？"))
        // Directly dispatch again even though UIKit has already disabled the
        // bar item: the controller itself must reject a duplicate callback.
        XCTAssertTrue(UIApplication.shared.sendAction(
            action, to: item.target, from: item, for: nil))
        XCTAssertTrue(page.presentedViewController === sheet,
            "A second tap must not replace or queue another approval sheet")
        XCTAssertEqual(sheet.actions.filter {
            $0.title == V3L("确认加入")
        }.count, 1)
        XCTAssertFalse(ImVaultGuardedWrite.productionWriteEnabled)
    }

    func testPendingAIQuestionPoolRoundtripAndVaultIsolation() throws {
        let vault = "qa-pool-" + UUID().uuidString
        let identity = try ImVaultFileIdentity(vaultID: vault,
                                                relativePath: "Study/Knowledge.md")
        let source = ImpressAISource(vaultID: vault,
             relativePath: identity.relativePath,
             documentSHA256: String(repeating: "a", count: 64),
             heading: "Knowledge")
        let excerpt = ImpressAIExcerpt(id: "section-0", source: source,
                                        text: "Reasoning is testable.")
        let candidate = ImpressAIQuestionCandidate(
            question: "Why test?", answer: "To verify behavior.",
            dimension: .mechanism, evidenceIDs: ["section-0"], selected: false)
        let pending = ImpressAIQuestionPool(source: source,
            excerpts: [excerpt], requestedCount: 5, modelProfileID: UUID(),
            candidates: [candidate])
        defer { try? ImVaultPrivateStore.deleteQuestionPool(identity: identity) }
        try ImVaultPrivateStore.saveQuestionPool(pending)
        let restored = try XCTUnwrap(ImVaultPrivateStore.loadQuestionPool(identity: identity))
        XCTAssertEqual(restored.id, pending.id)
        XCTAssertEqual(restored.source.documentSHA256, source.documentSHA256)
        XCTAssertEqual(restored.candidates.first?.question, candidate.question)
        XCTAssertEqual(restored.candidates.first?.selected, false)
        let other = try ImVaultFileIdentity(vaultID: "separate-" + UUID().uuidString,
                                            relativePath: identity.relativePath)
        XCTAssertNil(try ImVaultPrivateStore.loadQuestionPool(identity: other))
        try ImVaultPrivateStore.deleteQuestionPool(identity: identity)
        XCTAssertNil(try ImVaultPrivateStore.loadQuestionPool(identity: identity))
    }
}


// In-process transport fixture: no OpenCode request, account credit or
// privately authored Markdown is sent while exercising these native paths.
private final class ImpressAIMockURLProtocol: URLProtocol {
    private static let fixtureLock = NSLock()
    private static var fixtureCode: Int = 200
    private static var fixtureBody: Data =
        Data(#"{"choices":[{"message":{"role":"assistant","content":"OK"}}]}"#.utf8)
    // Only path and boolean match are stored. Test request credentials and
    // bodies are never printed, returned to the UI, or sent over the network.
    private static var seenAuthenticatedPaths: [(path: String, valid: Bool)] = []

    static func resetAuthCapture() {
        fixtureLock.lock()
        defer { fixtureLock.unlock() }
        seenAuthenticatedPaths.removeAll()
    }

    static func authenticatedPaths() -> [(path: String, valid: Bool)] {
        fixtureLock.lock()
        defer { fixtureLock.unlock() }
        return seenAuthenticatedPaths
    }

    static func respond(status: Int, json: String) {
        fixtureLock.lock()
        defer { fixtureLock.unlock() }
        fixtureCode = status
        fixtureBody = Data(json.utf8)
    }

    override class func canInit(with request: URLRequest) -> Bool {
        ["opencode.ai", "open.bigmodel.cn", "api.z.ai"].contains(request.url?.host ?? "")
    }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.fixtureLock.lock()
        let status = Self.fixtureCode
        let data = Self.fixtureBody
        let passed = request.value(forHTTPHeaderField: "Authorization") ==
            "Bearer synthetic-keychain-fixture"
        Self.seenAuthenticatedPaths.append(
            (path: request.url?.path ?? "", valid: passed))
        Self.fixtureLock.unlock()
        guard let url = request.url,
              let http = HTTPURLResponse(url: url, statusCode: status,
                                         httpVersion: "HTTP/1.1",
                                         headerFields: ["Content-Type": "application/json"])
        else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        client?.urlProtocol(self, didReceive: http, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@MainActor
final class ImpressAITransportAndCredentialTests: XCTestCase {
    private func mockClient() -> ImpressAIHTTPClient {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [ImpressAIMockURLProtocol.self]
        return ImpressAIHTTPClient(session: URLSession(configuration: config))
    }

    private func freeRoute() -> ImpressAIResolvedRoute {
        let connection = ImpressAIOpenCodeFreeQA.connection()
        let model = ImpressAIOpenCodeFreeQA.models(for: connection.id)[0]
        return ImpressAIResolvedRoute(connection: connection, model: model)
    }

    func testFreeMultiTurnTextResponseWithoutLiveNetwork() async throws {
        ImpressAIMockURLProtocol.respond(status: 200, json:
            #"{"choices":[{"message":{"content":"Model reply","role":"assistant"}}]}"#)
        let result = try await mockClient().converseDetailed(
            route: freeRoute(), system: "Test fixture only.",
            turns: [
                ImpressAIChatTurn(role: .user, text: "ping"),
                ImpressAIChatTurn(role: .assistant, text: "OK"),
                ImpressAIChatTurn(role: .user, text: "second ping")
            ])
        XCTAssertEqual(result.statusCode, 200)
        XCTAssertEqual(result.text, "Model reply")
    }

    func testProviderHTTPFailuresRemainDistinctWithoutLiveNetwork() async {
        let client = mockClient()
        for status in [401, 403, 404, 429] {
            ImpressAIMockURLProtocol.respond(status: status, json:
                #"{"error":{"message":"mock refusal"}}"#)
            do {
                _ = try await client.converse(route: freeRoute(), system: "Fixture.",
                    turns: [ImpressAIChatTurn(role: .user, text: "ping")])
                XCTFail("HTTP \(status) should not become a successful response")
            } catch ImpressAIServiceError.unauthorized where status == 401 {
            } catch ImpressAIServiceError.forbidden where status == 403 {
            } catch ImpressAIServiceError.status(let code) where status == 404 && code == 404 {
            } catch ImpressAIServiceError.rateLimited where status == 429 {
            } catch {
                XCTFail("Unexpected error for HTTP \(status): \(type(of: error))")
            }
        }
    }

    func testHTTP200WithoutVisibleReplyFailsClosed() async {
        ImpressAIMockURLProtocol.respond(status: 200, json:
            #"{"choices":[{"message":{"reasoning_content":"private","content":null}}]}"#)
        do {
            _ = try await mockClient().converse(route: freeRoute(), system: "Fixture.",
                turns: [ImpressAIChatTurn(role: .user, text: "ping")])
            XCTFail("Reasoning-only reply must not be accepted")
        } catch ImpressAIServiceError.response {
        } catch {
            XCTFail("Unexpected empty-reply error: \(type(of: error))")
        }
    }

    func testSyntheticGenerationCallsRealJSONRequestParserAndEvidenceValidator() async throws {
        let connection = ImpressAIOpenCodeFreeQA.connection()
        let model = ImpressAIOpenCodeFreeQA.models(for: connection.id)[0]
        let route = ImpressAIResolvedRoute(connection: connection, model: model)
        let source = ImpressAISource(vaultID: "qa-only",
            relativePath: "Synthetic_QA.md",
            documentSHA256: String(repeating: "a", count: 64),
            heading: "Synthetic")
        let excerpt = ImpressAIExcerpt(id: "qa-evidence-1",
            source: source,
            text: "Active recall retrieves knowledge without looking at the answer.")
        let envelope: [String: Any] = [
            "questions": [[
                "question": "How does active recall differ from rereading?",
                "answer": "It tests retrieval without showing the answer first.",
                "dimension": "comparison",
                "evidenceIDs": ["qa-evidence-1"]
            ]]
        ]
        let encoded = try JSONSerialization.data(withJSONObject: envelope)
        let answer = try XCTUnwrap(String(data: encoded, encoding: .utf8))
        let body: [String: Any] = [
            "choices": [["message": ["role": "assistant", "content": answer]]]
        ]
        let serialized = try JSONSerialization.data(withJSONObject: body)
        ImpressAIMockURLProtocol.respond(status: 200,
            json: try XCTUnwrap(String(data: serialized, encoding: .utf8)))
        let completion = try await mockClient().completeDetailed(
            route: route, system: ImpressAIQuestionPrompt.system(count: 1),
            user: try ImpressAIQuestionPrompt.input([excerpt]))
        XCTAssertEqual(completion.statusCode, 200)
        let candidates = try ImpressAIQuestionPrompt.decode(completion.text)
        let pool = ImpressAIQuestionPool(source: source, excerpts: [excerpt],
            requestedCount: 1, modelProfileID: model.id,
            candidates: candidates.map {
                ImpressAIQuestionCandidate(question: $0.question,
                    answer: $0.answer, dimension: $0.dimension,
                    evidenceIDs: $0.evidenceIDs)
            })
        XCTAssertEqual(try ImpressAIQuestionValidator.validatedSelection(pool).count, 1)
    }

    func testGLMBearerUsesCorrectChatJSONAndModelsEndpointWithoutNetwork() async throws {
        let keyID = UUID()
        defer { ImpressAIKeychain.delete(id: keyID) }
        try ImpressAIKeychain.write("synthetic-keychain-fixture", id: keyID)
        let c = ImpressAIConnection(title: "GLM China", provider: .zhipu,
            apiProtocol: .chatCompletions,
            baseURL: URL(string: "https://open.bigmodel.cn/api/paas/v4")!,
            credentialID: keyID)
        let m = ImpressAIModel(connectionID: c.id, identifier: "glm-4.5-flash",
                                jsonMode: .promptOnly)
        let route = ImpressAIResolvedRoute(connection: c, model: m)
        let client = mockClient()
        ImpressAIMockURLProtocol.resetAuthCapture()

        ImpressAIMockURLProtocol.respond(status: 200, json:
            #"{"choices":[{"message":{"role":"assistant","content":"GLM reply"}}]}"#)
        let chat = try await client.converseDetailed(route: route,
            system: "Fixture only.", turns: [ImpressAIChatTurn(role: .user, text: "hello")])
        XCTAssertEqual(chat.statusCode, 200)
        XCTAssertEqual(chat.text, "GLM reply")

        ImpressAIMockURLProtocol.respond(status: 200, json:
            #"{"choices":[{"message":{"role":"assistant","content":"{\"ok\":true}"}}]}"#)
        let json = try await client.completeDetailed(route: route,
            system: "Return JSON.", user: "Fixture only.")
        XCTAssertEqual(json.statusCode, 200)
        XCTAssertEqual(try JSONSerialization.jsonObject(with: Data(json.text.utf8))
                       as? [String: Bool], ["ok": true])

        ImpressAIMockURLProtocol.respond(status: 200, json:
            #"{"data":[{"id":"glm-4.5-flash"}]}"#)
        let catalog = try await client.listModels(connection: c)
        XCTAssertEqual(catalog, ["glm-4.5-flash"])
        let captures = ImpressAIMockURLProtocol.authenticatedPaths()
        XCTAssertEqual(captures.map { $0.path }, [
            "/api/paas/v4/chat/completions",
            "/api/paas/v4/chat/completions",
            "/api/paas/v4/models"
        ])
        XCTAssertTrue(captures.allSatisfy { $0.valid },
                      "GLM must receive Bearer from the matching Keychain credential")
    }

    func testModelChooserShowsGLMAndDoesNotClaimFreeQAOnly() throws {
        let store = ImpressAIConfigStore.shared
        let previous = store.registry
        defer { try? store.replace(previous) }
        let glm = ImpressAIConnection(title: "GLM China", provider: .zhipu,
            apiProtocol: .chatCompletions,
            baseURL: URL(string: "https://open.bigmodel.cn/api/paas/v4")!, credentialID: UUID())
        let model = ImpressAIModel(connectionID: glm.id, identifier: "glm-4.5-flash")
        try store.update { registry in
            registry.connections.append(glm)
            registry.models.append(model)
        }
        let picker = ImpressAIModelChooser(task: .conversation)
        picker.loadViewIfNeeded()
        let rows = picker.tableView(picker.tableView, numberOfRowsInSection: 0)
        XCTAssertGreaterThan(rows, 0)
        var foundGLM = false
        for index in 0..<rows {
            let cell = picker.tableView(picker.tableView,
                cellForRowAt: IndexPath(row: index, section: 0))
            if (cell.contentConfiguration as? UIListContentConfiguration)?.text == "glm-4.5-flash" {
                foundGLM = true
            }
        }
        XCTAssertTrue(foundGLM, "GLM must be a selectable business model")
    }


    func testCredentialStoreSupportsRotationAndDeletionWithoutLoggingSecrets() throws {
        let id = UUID()
        defer { ImpressAIKeychain.delete(id: id) }
        XCTAssertThrowsError(try ImpressAIKeychain.read(id: id))
        try ImpressAIKeychain.write("fixture-only-key-one", id: id)
        XCTAssertEqual(try ImpressAIKeychain.read(id: id), "fixture-only-key-one")
        try ImpressAIKeychain.write("fixture-only-key-two", id: id)
        XCTAssertEqual(try ImpressAIKeychain.read(id: id), "fixture-only-key-two")
        ImpressAIKeychain.delete(id: id)
        XCTAssertThrowsError(try ImpressAIKeychain.read(id: id))
    }

    func testSavedKeychainBearerReachesConsoleChatJSONAndFreeCatalog() async throws {
        // Signed-simulator Keychain + in-process URLProtocol. No real API key,
        // no network access, no paid model, no personal Vault bytes.
        let credentialID = UUID()
        defer { ImpressAIKeychain.delete(id: credentialID) }
        try ImpressAIKeychain.write("synthetic-keychain-fixture", id: credentialID)
        var connection = ImpressAIOpenCodeFreeQA.connection()
        connection.authentication = .bearer
        connection.credentialID = credentialID
        let model = ImpressAIOpenCodeFreeQA.models(for: connection.id)[0]
        let route = ImpressAIResolvedRoute(connection: connection, model: model)
        let client = mockClient()
        ImpressAIMockURLProtocol.resetAuthCapture()

        ImpressAIMockURLProtocol.respond(status: 200, json: "{}")
        let keyProbeStatus = try await client.probeOpenCodeServiceAccount(
            connection: connection)
        XCTAssertEqual(keyProbeStatus, 200)

        ImpressAIMockURLProtocol.respond(status: 200, json:
            #"{"choices":[{"message":{"role":"assistant","content":"OK"}}]}"#)
        let first = try await client.converseDetailed(
            route: route, system: "Synthetic fixture only.",
            turns: [ImpressAIChatTurn(role: .user, text: "ping")])
        XCTAssertEqual(first.statusCode, 200)
        XCTAssertEqual(first.text, "OK")

        ImpressAIMockURLProtocol.respond(status: 200, json:
            #"{"choices":[{"message":{"role":"assistant","content":"{\"ok\":true}"}}]}"#)
        let json = try await client.completeDetailed(
            route: route, system: "Return JSON.", user: "Synthetic fixture.")
        XCTAssertEqual(json.statusCode, 200)
        XCTAssertEqual(try JSONSerialization.jsonObject(with: Data(json.text.utf8)) as? [String: Bool],
                       ["ok": true])

        ImpressAIMockURLProtocol.respond(status: 200, json:
            #"{"data":[{"id":"mimo-v2.6-flash-free"}]}"#)
        let available = try await client.listModels(connection: connection)
        XCTAssertEqual(available, ["mimo-v2.6-flash-free"])

        let captures = ImpressAIMockURLProtocol.authenticatedPaths()
        XCTAssertEqual(captures.map { $0.path }, [
            "/console/api/v2/config",
            "/inference/openai/v1/chat/completions",
            "/inference/openai/v1/chat/completions",
            "/inference/v1/models"
        ])
        XCTAssertTrue(captures.allSatisfy { $0.valid },
                      "Every explicit Free API request must attach the Keychain Bearer")
    }
}
