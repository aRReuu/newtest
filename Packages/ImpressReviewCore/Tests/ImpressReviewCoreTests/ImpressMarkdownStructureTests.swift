import XCTest
@testable import ImpressReviewCore

final class ImpressMarkdownStructureTests: XCTestCase {
    func testNestedHeadingRangesPreserveExactUTF8BOMAndMixedNewlines() {
        let source = "\u{FEFF}---\r\nheadline: '# fake'\r\n---\r\n" +
            "Prelude 👩🏽‍💻\n\n# 重复\r\nParent content\r\n" +
            "## 子节\r\n子节内容 🌱\n### Leaf\rline\r" +
            "# 重复\r\nSecond section\n"
        let result = ImpressMarkdownStructure.sections(in: source)
        XCTAssertEqual(result.map(\.heading),
            ["全文", "重复", "子节", "Leaf", "重复"])
        XCTAssertEqual(result.map(\.level), [0, 1, 2, 3, 1])
        XCTAssertEqual(result[2].parentID, result[1].id)
        XCTAssertEqual(result[3].parentID, result[2].id)
        XCTAssertNil(result[4].parentID)
        XCTAssertTrue(result[1].text.contains("子节内容"))
        XCTAssertFalse(result[1].text.contains("Second section"))
        XCTAssertEqual(result[0].startUTF8, 0)
        XCTAssertEqual(result[0].rawUTF8.hasPrefix("\u{FEFF}---\r\n"), true)
        let bytes = Array(source.utf8)
        for section in result {
            XCTAssertEqual(Array(section.rawUTF8.utf8),
                Array(bytes[section.startUTF8..<section.endUTF8]))
            XCTAssertEqual(section.byteCount, section.rawUTF8.utf8.count)
        }
        XCTAssertNotEqual(result[1].id, result[4].id)
    }

    func testSetextAndVariableLengthFencesIgnoreFabricatedHeadings() {
        let grave = String(Character(UnicodeScalar(96)!))
        let input = "Intro\n====\n" +
            "~~~~md\n# Fake from tilde fence\n~~~~\n" +
            grave.repeatElement(4) + "swift\n" +
            grave.repeatElement(3) + "\n# Still fenced\n" +
            grave.repeatElement(4) + "\n" +
            "<!--\n# Fake comment\n-->\n" +
            "    # Indented fake\n> # Quoted fake\n" +
            "Subtopic\n---\nbody\n## Real\nactual"
        let sections = ImpressMarkdownStructure.sections(in: input)
        XCTAssertEqual(sections.map(\.heading),
            ["Intro", "Subtopic", "Real"])
        XCTAssertEqual(sections.map(\.level), [1, 2, 2])
        XCTAssertEqual(sections[1].parentID, sections[0].id)
        XCTAssertFalse(sections[1].text.contains("Still fenced"))
    }

    func testParentChildSelectionDeduplicatesWithoutInventingContent() {
        let source = "# Root\nA\n## First\nAlpha\n## Second\nBeta\n# Next\nC"
        let all = ImpressMarkdownStructure.sections(in: source)
        XCTAssertEqual(all.count, 4)
        let both = ImpressMarkdownStructure.effectiveSelection(all,
            selectedIDs: Set(all.map(\.id)))
        XCTAssertEqual(both.map(\.heading), ["Root", "Next"])
        XCTAssertEqual(both.map(\.text), ["# Root\nA\n## First\nAlpha\n## Second\nBeta",
                                         "# Next\nC"])
        let children = ImpressMarkdownStructure.effectiveSelection(all,
            selectedIDs: [all[1].id, all[2].id])
        XCTAssertEqual(children.map(\.heading), ["First", "Second"])
        XCTAssertEqual(children.map(\.text), ["## First\nAlpha", "## Second\nBeta"])
        XCTAssertTrue(ImpressMarkdownStructure.effectiveSelection(all,
            selectedIDs: []).isEmpty)
    }

    func testHeadingLookalikesDoNotChangeDocumentRanges() {
        let source = "Before\n<!-- # fake -->\n\n# Real\n" +
            "- list\n  # nested pseudo\n" +
            "    # code\n" +
            "~~~mermaid\n# graph title\n~~~\n" +
            "## Child\n> ## quote title\n" +
            "### Deep"
        let all = ImpressMarkdownStructure.sections(in: source)
        XCTAssertEqual(all.map(\.heading), ["全文", "Real", "Child", "Deep"])
        XCTAssertTrue(all[1].text.contains("### Deep"))
        XCTAssertEqual(all[2].parentID, all[1].id)
    }

    func testEmptyAndUntitledSourcesHaveAccessibleSelections() {
        XCTAssertEqual(ImpressMarkdownStructure.sections(in: "").count, 0)
        let text = "没有标题\n\n清晰的原文。\r\n"
        let results = ImpressMarkdownStructure.sections(in: text)
        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results[0].heading, "全文")
        XCTAssertEqual(results[0].rawUTF8, text)
    }

    func testThousandsOfUnicodeHeadingsPreserveExactSourceBytesWithoutQuadraticLookup() {
        // Many same-level headings are legal in an 8 MB Obsidian note.
        // Each section must terminate at the next heading, without scanning
        // every later heading or silently changing CRLF/Unicode offsets.
        let pieces = (0..<12_000).map { "# 同名🧠\($0)\r\n正文🌱\n" }
        let source = pieces.joined()
        let sections = ImpressMarkdownStructure.sections(in: source)
        XCTAssertEqual(sections.count, pieces.count)
        var offset = 0
        for index in pieces.indices {
            let item = sections[index]
            XCTAssertEqual(item.startUTF8, offset)
            offset += pieces[index].utf8.count
            XCTAssertEqual(item.endUTF8, offset)
            XCTAssertEqual(item.rawUTF8, pieces[index])
            XCTAssertNil(item.parentID)
        }
        XCTAssertEqual(offset, source.utf8.count)
    }

    func testThousandsOfSelectedParentChildSectionsRemainExactAndLinear() {
        // Parent/child intervals nest, independent roots do not. A selected
        // parent must suppress its child without changing any UTF-8 bytes.
        let fragments = (0..<4_500).map { index in
            "# 根🧠\(index)\r\n正文🌱\n## 子\(index)\r\n附注\n"
        }
        let source = fragments.joined()
        let all = ImpressMarkdownStructure.sections(in: source)
        XCTAssertEqual(all.count, fragments.count * 2)
        let selected = ImpressMarkdownStructure.effectiveSelection(all,
            selectedIDs: Set(all.map(\.id)))
        XCTAssertEqual(selected.count, fragments.count)
        XCTAssertTrue(selected.allSatisfy { $0.level == 1 })
        XCTAssertEqual(selected.map(\.rawUTF8), fragments)
        let children = ImpressMarkdownStructure.effectiveSelection(all,
            selectedIDs: Set(all.filter { $0.level == 2 }.map(\.id)))
        XCTAssertEqual(children.count, fragments.count)
        XCTAssertTrue(children.allSatisfy { $0.level == 2 })
        XCTAssertEqual(children.first?.rawUTF8, "## 子0\r\n附注\n")
    }
}

private extension String {
    func repeatElement(_ count: Int) -> String {
        String(repeating: self, count: count)
    }
}