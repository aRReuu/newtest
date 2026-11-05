import XCTest
@testable import ImpressReviewCore

final class ImpressBatchParserTests: XCTestCase {
    func testSortedSourcePayloadIsDeterministicAndLegacyPayloadStillDecodes() throws {
        let source = try ImVaultFileIdentity(vaultID: "a", relativePath: "Dir/Topic.md")
        let canonical = try ImpressBatchSourceKey.encode(source)
        XCTAssertEqual(canonical, try ImpressBatchSourceKey.encode(source))
        let historicJSON = #"{"relativePath":"Dir/Topic.md","vaultID":"a"}"#
        let historic = Data(historicJSON.utf8).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        XCTAssertEqual(try ImpressBatchSourceKey.decode("obsidian+v1:" + historic), source)
    }

    func testVersionedVaultSourceKeyRoundTripAndDigestValidation() throws {
        let source = try ImVaultFileIdentity(vaultID: "vault-1",
                                             relativePath: "Folder/Topic.md")
        let digest = String(repeating: "Ab", count: 32)
        let versioned = try ImpressBatchSourceKey.encode(source, documentDigest: digest)
        XCTAssertEqual(try ImpressBatchSourceKey.decode(versioned), source)
        XCTAssertEqual(try ImpressBatchSourceKey.documentDigest(for: versioned),
                       digest.lowercased())
        XCTAssertTrue(versioned.hasPrefix(try ImpressBatchSourceKey.versionedPrefix(for: source)))
        XCTAssertNil(try ImpressBatchSourceKey.documentDigest(
            for: ImpressBatchSourceKey.encode(source)))
        XCTAssertThrowsError(try ImpressBatchSourceKey.encode(
            source, documentDigest: "not-a-real-sha"))
        XCTAssertThrowsError(try ImpressBatchSourceKey.decode(versioned + ":spoofed"))
        let other = try ImVaultFileIdentity(vaultID: "vault-2",
                                            relativePath: "Folder/Topic.md")
        XCTAssertFalse(versioned.hasPrefix(try ImpressBatchSourceKey.versionedPrefix(for: other)))
    }

    func testSectionAnchoredSourceKeysRoundTripAndRejectForgedValues() throws {
        let source = try ImVaultFileIdentity(vaultID: "Vault-18",
                                               relativePath: "A/Topic.md")
        let other = try ImVaultFileIdentity(vaultID: "Another-Vault",
                                              relativePath: "A/Topic.md")
        let digest = String(repeating: "7", count: 64)
        let first = "## Principle\nA claim and its explanation."
        let second = "## Another\nDifferent evidence."
        let key = try ImpressBatchSourceKey.encode(source,
            documentDigest: digest, anchoredSection: first)
        XCTAssertTrue(key.hasPrefix("obsidian+v3:"))
        XCTAssertEqual(try ImpressBatchSourceKey.decode(key), source)
        XCTAssertNotEqual(try ImpressBatchSourceKey.decode(key), other)
        XCTAssertEqual(try ImpressBatchSourceKey.documentDigest(for: key), digest)
        XCTAssertEqual(try ImpressBatchSourceKey.sectionDigest(for: key),
                       ImVaultDigest.sha256(Data(first.utf8)))
        XCTAssertNotEqual(try ImpressBatchSourceKey.sectionDigest(for: key),
                          ImVaultDigest.sha256(Data(second.utf8)))
        XCTAssertNil(try ImpressBatchSourceKey.sectionDigest(for:
            ImpressBatchSourceKey.encode(source, documentDigest: digest)))
        XCTAssertNil(try ImpressBatchSourceKey.sectionDigest(for:
            ImpressBatchSourceKey.encode(source)))
        XCTAssertThrowsError(try ImpressBatchSourceKey.decode(key + ":extra"))
        XCTAssertThrowsError(try ImpressBatchSourceKey.decode(
            key.replacingOccurrences(of: digest, with: "unverified", range: nil)))
        XCTAssertThrowsError(try ImpressBatchSourceKey.encode(
            source, anchoredSection: first))
        XCTAssertThrowsError(try ImpressBatchSourceKey.encode(
            source, documentDigest: digest, anchoredSection: " \n "))
        XCTAssertEqual(try ImpressBatchSourceKey.encode(source,
            documentDigest: digest, anchoredSection: first), key)
    }

    func testUnicodeAndMultilineLabeledQuestions() {
        let rows = ImpressBatchParser.parse("Q: 光合作用的机理？\nA: 光能转化为\n化学能。\n\n问题：为什么回忆？\n答案：检索会巩固记忆。", as: .text)
        XCTAssertEqual(rows.count, 2)
        XCTAssertTrue(rows.allSatisfy(\.isValid))
        XCTAssertEqual(rows[0].answer, "光能转化为\n化学能。")
        XCTAssertEqual(rows[1].line, 5)
    }

    func testCSVQuotedCommaNewlineAndEscapedQuote() {
        let csv = "question,answer\n\"What, exactly?\",\"He said \"\"yes\"\".\nThen stopped.\"\n"
        let rows = ImpressBatchParser.parse(csv, as: .csv)
        XCTAssertEqual(rows.count, 1)
        XCTAssertTrue(rows[0].isValid)
        XCTAssertEqual(rows[0].question, "What, exactly?")
        XCTAssertEqual(rows[0].answer, "He said \"yes\".\nThen stopped.")
    }

    func testTSVChoicesRequireExplicitCorrectIndices() {
        let tsv = "question\ttype\toptions\tcorrect\n选哪个？\tchoice\tA|B|C\t1,3\n未标记？\tchoice\tA|B\t\n"
        let rows = ImpressBatchParser.parse(tsv, as: .tsv)
        XCTAssertTrue(rows[0].isValid)
        XCTAssertEqual(rows[0].correctIndices, [0, 2])
        XCTAssertFalse(rows[1].isValid)
        XCTAssertEqual(rows[1].raw.contains("未标记？"), true)
    }

    func testInvalidInputNeverInventsAnswer() {
        let rows = ImpressBatchParser.parse("## 模糊标题\n没有显式的问答结构", as: .markdown)
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].answer, "")
        XCTAssertFalse(rows[0].isValid)
        XCTAssertFalse(rows[0].raw.isEmpty)
    }

    func testInvalidCSVQuoteIsNotSilentlySaved() {
        let rows = ImpressBatchParser.parse("question,answer\n\"Q\"garbage,A", as: .csv)
        XCTAssertEqual(rows.count, 1)
        XCTAssertFalse(rows[0].isValid)
        XCTAssertTrue(rows[0].issues.contains(where: { $0.contains("引号") }))
    }

    func testMarkdownExplicitFieldsAndNoNetwork() {
        let rows = ImpressBatchParser.parse("## Q: 为什么？\n**A:** 因为有机制。", as: .markdown)
        XCTAssertEqual(rows.count, 1)
        XCTAssertTrue(rows[0].isValid)
    }

    func testEmptyAndOversizedInputIsRejectedSafely() {
        XCTAssertTrue(ImpressBatchParser.parse("", as: .text).isEmpty)
        let result = ImpressBatchParser.parse(String(repeating: "A", count: ImpressBatchParser.maximumBytes + 1),
            as: .text)
        XCTAssertEqual(result.count, 1)
        XCTAssertFalse(result[0].isValid)
    }
}


extension ImpressBatchParserTests {
    func testVaultIdentityRoundTripAndLegacySafety() throws {
        let key = try ImVaultFileIdentity(vaultID: "vault-alpha", relativePath: "Folder/复习.md")
        let stored = try ImpressBatchSourceKey.encode(key)
        XCTAssertEqual(try ImpressBatchSourceKey.decode(stored), key)
        XCTAssertNil(try ImpressBatchSourceKey.decode("Old/path.md"))
        XCTAssertThrowsError(try ImpressBatchSourceKey.decode("obsidian+v1:invalid$$"))
    }
}
