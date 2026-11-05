import Foundation
import Testing
@testable import ImpressReviewCore

@Suite("Obsidian Vault content authority and conflict gates")
struct ImVaultSyncCoreTests {
    @Test func oldVaultScanCannotCompleteAfterSwitch() {
        var gate = ImVaultAsyncReadGate()
        let fromA = gate.begin(for: "Vault-A")
        #expect(gate.accepts(fromA))
        let switchedVault = gate.changeSource(to: "Vault-B")
        #expect(switchedVault)
        #expect(!gate.accepts(fromA))
        let fromB = gate.begin(for: "Vault-B")
        #expect(gate.accepts(fromB))
        #expect(!gate.accepts(fromA))
    }

    @Test func lateScanCannotCompleteAfterDisconnectOrRefresh() {
        var gate = ImVaultAsyncReadGate()
        let stale = gate.begin(for: "Vault-A")
        let latest = gate.begin(for: "Vault-A")
        #expect(!gate.accepts(stale))
        #expect(gate.accepts(latest))
        let disconnectedVault = gate.changeSource(to: nil)
        #expect(disconnectedVault)
        #expect(!gate.accepts(latest))
        #expect(gate.activeVaultID == nil)
    }

    @Test func privacyProjectionBlocksInlineAndReferenceImages() {
        let markdown = """
        # Personal note
        ![remote](https://example.com/track.png)
        ![reference][asset]
        [asset]: https://example.com/track2.png
        ![shortcut]
        [shortcut]: https://example.com/track3.png
        <img src="https://example.com/fetch">
        ![[local-chart.png]]
        """
        let preview = ImVaultSafetyProjection.withoutUntrustedImages(markdown)
        #expect(!preview.contains("![remote]"))
        #expect(!preview.contains("![reference]"))
        #expect(!preview.contains("![shortcut]"))
        #expect(!preview.contains("<img"))
        #expect(preview.contains("![[local-chart.png]]"))
        #expect(preview.contains("（外部图片已屏蔽）"))
    }

    @Test func unknownImageDataUriIsNotLoadedDirectly() {
        let payload = "![payload](data:image/svg+xml;base64,PGh0bWw+)"
        let projected = ImVaultSafetyProjection.withoutUntrustedImages(payload)
        #expect(!projected.contains("data:image/svg"))
    }

    @Test func wikiLinksRemainInAuthorizedInternalRoute() {
        let source = "See [[Studies/Physics|Mechanics]] and ![[chart.png]]"
        let preview = ImVaultSafetyProjection.withWikiLinks(source)
        #expect(preview.contains("[Mechanics](https://impress.invalid/wiki?target="))
        #expect(preview.contains("[Mechanics]"))
        #expect(preview.contains("![[chart.png]]"))
        #expect(!preview.contains("https://example.com"))
    }

    @Test func dangerousWikiPathsRemainLiteralAndUnrouted() {
        let source = "[[../secret]] [[https://evil.example]] [[C:\\\\private]]"
        let preview = ImVaultSafetyProjection.withWikiLinks(source)
        #expect(!preview.contains("impress.invalid"))
    }

    @Test func calloutUsesOrdinarySafeBlockquoteMarkdown() {
        let source = "> [!NOTE] First principle\n> Test the assumption"
        let result = ImVaultSafetyProjection.withCalloutHeadings(source)
        #expect(result.contains("> **NOTE · First principle**"))
        #expect(result.contains("> Test the assumption"))
    }

    @Test func standardSHA256Vectors() {
        #expect(ImVaultDigest.sha256(Data()) ==
            "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
        #expect(ImVaultDigest.sha256(Data("abc".utf8)) ==
            "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    }
    @Test func binaryByteDifferenceAlwaysChangesVersion() {
        #expect(ImVaultDigest.sha256(Data("one\r\n".utf8)) !=
                ImVaultDigest.sha256(Data("one\n".utf8)))
    }
    @Test func sameNamesDifferentFoldersAreDifferentDocuments() throws {
        let a = try ImVaultFileIdentity(vaultID: "Vault-001", relativePath: "A/笔记.md")
        let b = try ImVaultFileIdentity(vaultID: "Vault-001", relativePath: "B/笔记.md")
        let c = try ImVaultFileIdentity(vaultID: "Vault-002", relativePath: "A/笔记.md")
        #expect(a != b)
        #expect(a != c)
        #expect(Set([a,b,c]).count == 3)
    }
    @Test(arguments: ["../secret.md", "/absolute.md", "A/../secret.md",
                       "A//empty.md", ".obsidian/config.md", "notes.txt",
                       "C:\\users\\note.md", "note.md:stream", "./note.md"])
    func rejectPathTraversal(_ path: String) {
        #expect(throws: ImVaultCoreError.invalidRelativePath) {
            try ImVaultFileIdentity(vaultID: "vault", relativePath: path)
        }
    }
    @Test func compositeReadIdentitiesNeverGrantGenericWriteAuthority() throws {
        let formats: [(String, ImVaultDocumentFormat)] = [
            ("Lessons/Ordinary.md", .markdown),
            ("Lessons/Graph.canvas", .jsonCanvas),
            ("Drawings/Sketch.excalidraw", .excalidrawJSON),
            ("Drawings/Sketch.excalidraw.md", .excalidrawMarkdown)
        ]
        for (path, format) in formats {
            let id = try ImVaultFileIdentity(vaultID: "fixture", relativePath: path)
            #expect(id.documentFormat == format)
            if format == .markdown {
                #expect((try? ImVaultDraft(identity: id, baseText: "# Safe")) != nil)
            } else {
                #expect(throws: ImVaultCoreError.invalidDraft) {
                    try ImVaultDraft(identity: id, baseText: "structured content")
                }
            }
        }
        #expect(ImVaultDocumentFormat.detect(relativePath: "unknown.bin") == nil)
        #expect(throws: ImVaultCoreError.invalidRelativePath) {
            try ImVaultFileIdentity(vaultID: "fixture", relativePath: "unknown.bin")
        }
    }

    @Test func renderedDiffUsesActualProposedBOMAndNewlineBytes() throws {
        let original = "\u{FEFF}# Heading\r\nOriginal\r\n"
        let id = try ImVaultFileIdentity(vaultID: "qa-bom",
            relativePath: "Notes/Original.md")
        let originalBytes = Data(original.utf8)
        // ImVaultReadSync.load returns Foundation-decoded Markdown without
        // UTF-8 BOM while the original file bytes still contain the BOM.
        let sourceProjection = try #require(String(data: originalBytes,
            encoding: .utf8))
        var draft = try ImVaultDraft(identity: id, baseText: sourceProjection,
            baseRawData: originalBytes)
        try draft.update("# Heading\nRevised\n")
        #expect(draft.byteFaithfulEditedText ==
            "\u{FEFF}# Heading\r\nRevised\r\n")
        #expect(draft.proposedBytes ==
            Data(draft.byteFaithfulEditedText.utf8))
        #expect(draft.byteFaithfulBaseText == original)
        let diff = ImVaultDiff.summary(base: draft.byteFaithfulBaseText,
            edited: draft.byteFaithfulEditedText, maximumLines: 200)
        #expect(diff.complete)
        #expect(diff.text.contains("Revised"))
    }

    @Test func draftPreservesOriginalMarkdown() throws {
        let text = "---\ntags: [demo]\n---\n# Heading\n![[image.png]]\n[[Linked]]\n"
        let id = try ImVaultFileIdentity(vaultID: "v",relativePath: "notes/test.md")
        var draft = try ImVaultDraft(identity: id, baseText: text)
        try draft.update(text + "\nAdded text")
        try draft.validate()
        #expect(draft.baseText == text)
        #expect(draft.hasChanges)
        #expect(draft.decision(against: Data(text.utf8)) == .safeToWrite)
    }
    @Test func concurrentEditorMustNotOverwrite() throws {
        let id = try ImVaultFileIdentity(vaultID: "v", relativePath: "A.md")
        var a = try ImVaultDraft(identity: id, baseText: "A")
        var b = try ImVaultDraft(identity: id, baseText: "A")
        try a.update("from Obsidian")
        try b.update("from Impress")
        #expect(a.decision(against: Data("A".utf8)) == .safeToWrite)
        #expect(b.decision(against: Data(a.editedText.utf8)) == .conflict)
        #expect(b.editedText == "from Impress")
    }
    @Test func idempotentRetryIsNotASecondWrite() throws {
        let id = try ImVaultFileIdentity(vaultID: "v", relativePath: "A.md")
        var draft = try ImVaultDraft(identity: id, baseText: "A")
        try draft.update("B")
        #expect(draft.decision(against: Data("B".utf8)) == .alreadyApplied)
    }
    @Test func noContentChangeMeansNoWriteEvenWhenRemoteChanged() throws {
        let id = try ImVaultFileIdentity(vaultID: "v", relativePath: "A.md")
        let draft = try ImVaultDraft(identity: id, baseText: "A")
        #expect(draft.decision(against: Data("B".utf8)) == .unchanged)
    }
    @Test func previewCapNeverApprovesTruncatedDiff() {
        let a = (0..<1000).map { "old \($0)" }.joined(separator: "\n")
        let b = (0..<1000).map { "new \($0)" }.joined(separator: "\n")
        let short = ImVaultDiff.summary(base: a,edited: b,maximumLines: 20)
        #expect(!short.complete)
        #expect(short.text.contains("禁止提交"))
        #expect(ImVaultDiff.summary(base: a,edited: b,maximumLines: 4000).complete)
    }

    @Test func distantSmallEditsPreviewOnlyActualChangedHunks() {
        let original = (0..<1_200).map { "Line \($0)" }
        var modified = original
        modified[18] = "Improved early concept"
        modified[1_090] = "Improved late concept"
        let result = ImVaultDiff.summary(
            base: original.joined(separator: "\n"),
            edited: modified.joined(separator: "\n"), maximumLines: 8)
        #expect(result.complete)
        #expect(result.text.contains("第 19 行"))
        #expect(result.text.contains("第 1091 行"))
        #expect(result.text.contains("- Line 18"))
        #expect(result.text.contains("+ Improved early concept"))
        #expect(result.text.contains("- Line 1090"))
        #expect(result.text.contains("+ Improved late concept"))
        #expect(!result.text.contains("Line 500"))
        #expect(!result.text.contains("禁止提交"))
    }

    @Test func separateInsertAndRemovalRemainVisible() {
        let before = (0..<300).map { "Line \($0)" }
        var after = before
        after.insert("New assumption", at: 12)
        after.remove(at: 250)
        let diff = ImVaultDiff.summary(base: before.joined(separator: "\n"),
            edited: after.joined(separator: "\n"), maximumLines: 6)
        #expect(diff.complete)
        #expect(diff.text.contains("+ New assumption"))
        #expect(diff.text.contains("- Line 249"))
        #expect(!diff.text.contains("Line 120"))
    }

    @Test func utf8BOMAndCRLFRemainUntouchedWhenUITextViewNormalizesNewlines() throws {
        let identity = try ImVaultFileIdentity(vaultID: "qa",
            relativePath: "Study/CRLF.md")
        let raw = Data([0xEF, 0xBB, 0xBF]) +
            Data("# Topic\r\n- First\r\n- Second\r\n".utf8)
        let initialText = try #require(String(data: raw, encoding: .utf8))
        var draft = try ImVaultDraft(identity: identity, baseText: initialText,
                                    baseRawData: raw)
        #expect(draft.proposedBytes == raw)
        #expect(!draft.hasChanges)
        try draft.update("# Topic\n- First\n- Second\n")
        #expect(!draft.hasChanges,
                "UIKit newline normalization is not a user edit")
        #expect(draft.decision(against: raw) == .unchanged)
        try draft.update("# Topic\n- First\n- Revised\n")
        #expect(draft.hasChanges)
        #expect(draft.proposedBytes.starts(with: [0xEF, 0xBB, 0xBF]))
        #expect(draft.proposedBytes == Data([0xEF, 0xBB, 0xBF]) +
            Data("# Topic\r\n- First\r\n- Revised\r\n".utf8))
        #expect(draft.decision(against: raw) == .safeToWrite)
        #expect(draft.decision(against: draft.proposedBytes) == .alreadyApplied)
        let restored = try JSONDecoder().decode(ImVaultDraft.self,
            from: JSONEncoder().encode(draft))
        #expect(restored.proposedBytes == draft.proposedBytes)
    }
    @Test func uniformClassicMacNewlinesRemainConsistent() throws {
        let identity = try ImVaultFileIdentity(vaultID: "qa",
            relativePath: "Legacy.md")
        let bytes = Data("A\rB\r".utf8)
        var draft = try ImVaultDraft(identity: identity,
            baseText: "A\rB\r", baseRawData: bytes)
        try draft.update("A\nB\n")
        #expect(!draft.hasChanges)
        try draft.update("A\nCorrected\n")
        #expect(draft.proposedBytes == Data("A\rCorrected\r".utf8))
    }

    @Test func revisionDiffDoesNotMislabelOriginalUniformLineEndings() {
        let original = (0..<1500).map { "Line \($0)" }.joined(separator: "\r\n")
        var newLines = (0..<1500).map { "Line \($0)" }
        newLines[725] = "Corrected line"
        let current = newLines.joined(separator: "\n")
        let result = ImVaultDiff.summary(base: original, edited: current, maximumLines: 6)
        #expect(result.complete)
        #expect(result.text.contains("第 726 行"))
        #expect(result.text.contains("- Line 725"))
        #expect(result.text.contains("+ Corrected line"))
        let merelyNormalized = ImVaultDiff.summary(base: original,
            edited: original.replacingOccurrences(of: "\r\n", with: "\n"))
        #expect(merelyNormalized.complete)
        #expect(merelyNormalized.text == "没有变更")
    }

    @Test func mixedNewlineFormattingChangeMustNotBeInvisible() {
        let original = "One\r\nTwo\nThree\r\n"
        let newText = "One\nTwo\nThree\n"
        let diff = ImVaultDiff.summary(base: original, edited: newText)
        #expect(diff.complete)
        #expect(diff.text != "没有变更")
    }

    @Test func draftDetectsModifiedBaseline() throws {
        let id = try ImVaultFileIdentity(vaultID: "v",relativePath: "A.md")
        let initial = try ImVaultDraft(identity: id, baseText: "A")
        let decoder = JSONDecoder()
        let encoder = JSONEncoder()
        let data = try encoder.encode(initial)
        let tampered = String(decoding: data, as: UTF8.self).replacingOccurrences(
            of: "\"baseText\":\"A\"", with: "\"baseText\":\"malicious\"")
        #expect(tampered != String(decoding: data, as: UTF8.self))
        let loaded = try decoder.decode(ImVaultDraft.self, from: Data(tampered.utf8))
        #expect(throws: ImVaultCoreError.invalidDraft) { try loaded.validate() }
    } 
    @Test func duplexIndividualTargetsAndExplicitRetryAreIdempotent() {
        var both = ImDuplexApprovalState(noteSelected: true, cardSelected: true)
        #expect(both.needsNoteAction && both.needsCardAction)
        #expect(!both.completed)
        both.noteStatus = .applied
        both.cardStatus = .failed
        #expect(!both.needsNoteAction && both.needsCardAction)
        #expect(!both.completed)
        let restored = try? JSONDecoder().decode(ImDuplexApprovalState.self,
            from: JSONEncoder().encode(both))
        #expect(restored == both)
        #expect(restored?.needsCardAction == true)
        both.cardStatus = .applied
        #expect(both.completed)
        var cardOnly = ImDuplexApprovalState(noteSelected: false, cardSelected: true)
        #expect(!cardOnly.needsNoteAction)
        cardOnly.cardStatus = .applied
        #expect(cardOnly.completed)
        var discarded = ImDuplexApprovalState(noteSelected: true, cardSelected: true)
        discarded.noteSelected = false
        discarded.cardSelected = false
        #expect(discarded.completed)
        #expect(!discarded.needsNoteAction && !discarded.needsCardAction)
    }

    @Test func interruptedUndoNeverReplaysForwardWrite() throws {
        var state = ImDuplexApprovalState(noteSelected: true, cardSelected: true,
            noteStatus: .applied, cardStatus: .applied)
        #expect(state.completed)
        state.noteStatus = .undoing
        #expect(!state.needsNoteAction)
        #expect(state.needsNoteUndo)
        #expect(!state.completed)
        let data = try JSONEncoder().encode(state)
        let reopened = try JSONDecoder().decode(ImDuplexApprovalState.self, from: data)
        #expect(reopened.needsNoteUndo)
        #expect(!reopened.needsNoteAction,
            "A crashed inverse operation must not run the forward writer")
        state.noteStatus = .reverted
        #expect(!state.needsNoteAction)
        #expect(!state.needsNoteUndo)
        #expect(state.completed)
        state.cardStatus = .undoing
        #expect(state.needsCardUndo && !state.needsCardAction)
        state.cardStatus = .reverted
        #expect(state.completed)
    }

    @Test func F06DeselectCannotEraseInterruptedForwardApplication() throws {
        var state = ImDuplexApprovalState(noteSelected: true, cardSelected: true,
            noteStatus: .applying, cardStatus: .pending)
        #expect(state.needsNoteAction && state.needsCardAction)
        #expect(!state.completed)
        // A stale destructive UI request once cleared both selection bits.
        state.noteSelected = false
        state.cardSelected = false
        let recovered = try JSONDecoder().decode(ImDuplexApprovalState.self,
            from: JSONEncoder().encode(state))
        #expect(recovered.noteStatus == .applying)
        #expect(!recovered.completed)
        #expect(!recovered.needsNoteUndo && !recovered.needsCardUndo)
        // Only an explicit read-after-crash reconciliation can resolve the
        // unknown forward intent; caller must not infer success from a flag.
        state.noteStatus = .conflict
        #expect(state.completed)
        state.noteSelected = true
        #expect(!state.completed)
    }

    @Test func deselectionCannotErasePendingUndoAfterCrash() throws {
        var state = ImDuplexApprovalState(noteSelected: true, cardSelected: true,
            noteStatus: .undoing, cardStatus: .undoing)
        // A historic faulty cancel action could persist the selections as
        // false. Never interpret this as a completed or replayable proposal.
        state.noteSelected = false
        state.cardSelected = false
        let encoded = try JSONEncoder().encode(state)
        let restored = try JSONDecoder().decode(ImDuplexApprovalState.self, from: encoded)
        #expect(restored.needsNoteUndo)
        #expect(restored.needsCardUndo)
        #expect(!restored.needsNoteAction && !restored.needsCardAction)
        #expect(!restored.completed)
        #expect(restored.noteStatus == .undoing)
    }


    @Test func F03InterruptedNoteReconciliationNeverReplaysStaleBytes() throws {
        let id = try ImVaultFileIdentity(vaultID: "recovery-test",
            relativePath: "A/Knowledge.md")
        var draft = try ImVaultDraft(identity: id, baseText: "Before")
        try draft.update("After")
        let proposed = ImVaultDigest.sha256(draft.proposedBytes)
        #expect(ImDuplexInterruptedRecovery.noteStatus(
            currentDigest: proposed, baseDigest: draft.baseDigest,
            proposedDigest: proposed) == .applied)
        // Missing source authorization is *unknown*, never success.
        #expect(ImDuplexInterruptedRecovery.noteStatus(
            currentDigest: nil, baseDigest: draft.baseDigest,
            proposedDigest: proposed) == nil)
        #expect(ImDuplexInterruptedRecovery.noteStatus(
            currentDigest: draft.baseDigest, baseDigest: draft.baseDigest,
            proposedDigest: proposed) == .conflict)
        #expect(ImDuplexInterruptedRecovery.noteStatus(
            currentDigest: ImVaultDigest.sha256(Data("Later legitimate edit".utf8)),
            baseDigest: draft.baseDigest, proposedDigest: proposed) == .conflict)
        #expect(!ImDuplexApprovalState(noteSelected: true, cardSelected: false,
            noteStatus: .undoing).needsNoteAction)
    }

    @Test func F04InterruptedCardReconciliationUsesContentVersionNotReviewSchedule() {
        func check(revision: Int?, question: String?, answer: String?) -> ImDuplexTargetStatus? {
            ImDuplexInterruptedRecovery.cardStatus(
                currentContentRevision: revision, expectedContentRevision: 4,
                baseQuestion: "Old", baseAnswer: "Original",
                proposedQuestion: "New", proposedAnswer: "Improved",
                currentQuestion: question, currentAnswer: answer)
        }
        #expect(check(revision: 5, question: "New", answer: "Improved") == .applied)
        #expect(check(revision: 4, question: "Old", answer: "Original") == .conflict)
        #expect(check(revision: 6, question: "New", answer: "Improved") == .conflict)
        #expect(check(revision: 5, question: "Another edit", answer: "Improved") == .conflict)
        #expect(check(revision: nil, question: nil, answer: nil) == nil)
        #expect(ImDuplexInterruptedRecovery.cardStatus(
            currentContentRevision: 0, expectedContentRevision: Int.max,
            baseQuestion: "Old", baseAnswer: nil,
            proposedQuestion: "New", proposedAnswer: nil,
            currentQuestion: "New", currentAnswer: nil) == nil)
        #expect(ImDuplexInterruptedRecovery.cardStatus(
            currentContentRevision: 7, expectedContentRevision: 7,
            baseQuestion: "Same", baseAnswer: nil,
            proposedQuestion: "Same", proposedAnswer: nil,
            currentQuestion: "Same", currentAnswer: nil) == .applied)
    }
    @Test func reverseCardEditUsesFreshCASAndRejectsInterveningRevision() {
        let originallyApplied = ImDuplexCardVersionGate.decide(
            expectedContentRevision: 5, currentContentRevision: 5,
            baseQuestion: "AI revised", baseAnswer: "Corrected",
            proposedQuestion: "Original", proposedAnswer: "Initial",
            currentQuestion: "AI revised", currentAnswer: "Corrected")
        #expect(originallyApplied == .safeToWrite)
        let undoneOnRetry = ImDuplexCardVersionGate.decide(
            expectedContentRevision: 5, currentContentRevision: 6,
            baseQuestion: "AI revised", baseAnswer: "Corrected",
            proposedQuestion: "Original", proposedAnswer: "Initial",
            currentQuestion: "Original", currentAnswer: "Initial")
        #expect(undoneOnRetry == .alreadyApplied)
        let userContinuedEditing = ImDuplexCardVersionGate.decide(
            expectedContentRevision: 5, currentContentRevision: 6,
            baseQuestion: "AI revised", baseAnswer: "Corrected",
            proposedQuestion: "Original", proposedAnswer: "Initial",
            currentQuestion: "Second valid human edit", currentAnswer: "Corrected")
        #expect(userContinuedEditing == .conflict)
    }

    @Test func F06InterruptedInverseSourceOnlyAcceptsRestoredBytes() {
        #expect(ImDuplexInterruptedRecovery.noteUndoStatus(
            currentDigest: "original", approvedDigest: "approved",
            originalDigest: "original") == .reverted)
        #expect(ImDuplexInterruptedRecovery.noteUndoStatus(
            currentDigest: "approved", approvedDigest: "approved",
            originalDigest: "original") == nil,
            "Still-approved source must not silently retry the inverse")
        #expect(ImDuplexInterruptedRecovery.noteUndoStatus(
            currentDigest: "later-human-edit", approvedDigest: "approved",
            originalDigest: "original") == nil,
            "Newer bytes cannot produce a false restored receipt")
        #expect(ImDuplexInterruptedRecovery.noteUndoStatus(
            currentDigest: nil, approvedDigest: "approved",
            originalDigest: "original") == nil)
        #expect(ImDuplexInterruptedRecovery.noteUndoStatus(
            currentDigest: "original", approvedDigest: "same",
            originalDigest: "same") == nil)
    }

    @Test func F06InterruptedInverseCardRequiresSecondContentRevision() {
        func classify(revision: Int?, question: String?, answer: String?) -> ImDuplexTargetStatus? {
            ImDuplexInterruptedRecovery.cardUndoStatus(
                currentContentRevision: revision,
                expectedBaseContentRevision: 12,
                originalQuestion: "Original Q", originalAnswer: "Original A",
                approvedQuestion: "AI Q", approvedAnswer: "AI A",
                currentQuestion: question, currentAnswer: answer)
        }
        #expect(classify(revision: 14, question: "Original Q",
                         answer: "Original A") == .reverted)
        #expect(classify(revision: 13, question: "AI Q", answer: "AI A") == nil)
        #expect(classify(revision: 14, question: "Later human Q",
                         answer: "Original A") == nil)
        #expect(classify(revision: 15, question: "Original Q",
                         answer: "Original A") == nil,
            "Equal visible text at a later revision is not a verified inverse")
        #expect(classify(revision: nil, question: nil, answer: nil) == nil)
        #expect(ImDuplexInterruptedRecovery.cardUndoStatus(
            currentContentRevision: Int.max,
            expectedBaseContentRevision: Int.max,
            originalQuestion: "Original Q", originalAnswer: "A",
            approvedQuestion: "AI Q", approvedAnswer: "B",
            currentQuestion: "Original Q", currentAnswer: "A") == nil)
    }

    @Test func F04RevisionOverflowCannotCreateFalseIdempotentReceipt() {
        let result = ImDuplexCardVersionGate.decide(
            expectedContentRevision: Int.max, currentContentRevision: Int.max,
            baseQuestion: "Old", baseAnswer: "Old",
            proposedQuestion: "New", proposedAnswer: "New",
            currentQuestion: "New", currentAnswer: "New")
        #expect(result == .conflict)
        // The old gate returned safeToWrite for Int.max/-1 when the
        // current text matched the baseline, and unchanged for a no-op.
        // Neither is a valid content revision or a safe WCDB CAS intent.
        for (expected, current) in [
            (-1, -1), (-1, 0), (0, -1),
            (Int.max, Int.max), (Int.max, Int.max - 1)
        ] {
            #expect(ImDuplexCardVersionGate.decide(
                expectedContentRevision: expected, currentContentRevision: current,
                baseQuestion: "Old", baseAnswer: "Old",
                proposedQuestion: "New", proposedAnswer: "New",
                currentQuestion: "Old", currentAnswer: "Old") == .conflict)
            #expect(ImDuplexCardVersionGate.decide(
                expectedContentRevision: expected, currentContentRevision: current,
                baseQuestion: "Old", baseAnswer: "Old",
                proposedQuestion: "Old", proposedAnswer: "Old",
                currentQuestion: "Old", currentAnswer: "Old") == .conflict)
        }
    }

    @Test func F09NoOpCardApprovalRejectsStaleContentWithoutRescoring() {
        func noOp(currentRevision: Int, question: String, answer: String?) -> ImDuplexCardVersionDecision {
            ImDuplexCardVersionGate.decide(
                expectedContentRevision: 12, currentContentRevision: currentRevision,
                baseQuestion: "Original", baseAnswer: "Answer",
                proposedQuestion: "Original", proposedAnswer: "Answer",
                currentQuestion: question, currentAnswer: answer)
        }
        // A legal FSRS rating changes review revision, NOT content revision.
        // A true no-op remains safe only for the same authoritative content CAS.
        #expect(noOp(currentRevision: 12, question: "Original", answer: "Answer") == .unchanged)
        #expect(noOp(currentRevision: 12, question: "Human edit", answer: "Answer") == .conflict)
        #expect(noOp(currentRevision: 12, question: "Original", answer: "Human edit") == .conflict)
        #expect(noOp(currentRevision: 13, question: "Human edit", answer: "Answer") == .conflict)
        #expect(noOp(currentRevision: 13, question: "Original", answer: "Answer") == .conflict,
            "Restored visible text at a newer revision must not fabricate a no-op receipt")

        // A crash-window readback must obey the same no-op contract. Without
        // this guard an unrelated +1 content revision was falsely marked applied.
        func recovered(_ revision: Int) -> ImDuplexTargetStatus? {
            ImDuplexInterruptedRecovery.cardStatus(
                currentContentRevision: revision, expectedContentRevision: 12,
                baseQuestion: "Original", baseAnswer: "Answer",
                proposedQuestion: "Original", proposedAnswer: "Answer",
                currentQuestion: "Original", currentAnswer: "Answer")
        }
        #expect(recovered(12) == .applied)
        #expect(recovered(13) == .conflict)
        #expect(recovered(14) == .conflict)

        // A real changed proposal still observes fresh content CAS after FSRS.
        #expect(ImDuplexCardVersionGate.decide(
            expectedContentRevision: 12, currentContentRevision: 12,
            baseQuestion: "Original", baseAnswer: "Answer",
            proposedQuestion: "Revised", proposedAnswer: "Answer",
            currentQuestion: "Original", currentAnswer: "Answer") == .safeToWrite)
    }

    @Test func duplexCardConflictAndRepeatNeverOverwriteAnotherVersion() {
        let safe = ImDuplexCardVersionGate.decide(expectedContentRevision: 3,
            currentContentRevision: 3, baseQuestion: "Original Q", baseAnswer: "Original A",
            proposedQuestion: "Revised Q", proposedAnswer: "Revised A",
            currentQuestion: "Original Q", currentAnswer: "Original A")
        #expect(safe == .safeToWrite)
        let retry = ImDuplexCardVersionGate.decide(expectedContentRevision: 3,
            currentContentRevision: 4, baseQuestion: "Original Q", baseAnswer: "Original A",
            proposedQuestion: "Revised Q", proposedAnswer: "Revised A",
            currentQuestion: "Revised Q", currentAnswer: "Revised A")
        #expect(retry == .alreadyApplied)
        let conflict = ImDuplexCardVersionGate.decide(expectedContentRevision: 3,
            currentContentRevision: 4, baseQuestion: "Original Q", baseAnswer: "Original A",
            proposedQuestion: "Revised Q", proposedAnswer: "Revised A",
            currentQuestion: "A different edit", currentAnswer: "Original A")
        #expect(conflict == .conflict)
        #expect(ImDuplexCardVersionGate.decide(expectedContentRevision: 3,
            currentContentRevision: 3, baseQuestion: "Original Q", baseAnswer: "Original A",
            proposedQuestion: "Original Q", proposedAnswer: "Original A",
            currentQuestion: "Original Q", currentAnswer: "Original A") == .unchanged)
    }


}
