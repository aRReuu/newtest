import Foundation
import Testing
@testable import ImpressReviewCore

@Suite("Markdown diagrams preserve exact source scope and consent")
struct ImpressDiagramDocumentTests {
    @Test func mermaidUTF8CRLFAndOtherFencesDoNotConfuseParser() throws {
        let backtick = String(Character(UnicodeScalar(96)!))
        let source = "\u{FEFF}Hello 🌱\r\n" + backtick.repeatElement(3) +
            "json\r\n" + backtick.repeatElement(3) + "mermaid ignored\r\n" +
            backtick.repeatElement(3) + "\r\n## Visible\r\n" +
            backtick.repeatElement(4) + "mermaid\r\nflowchart LR\r\n" +
            "A[允许] --> B[确认]\r\nC[不得发送]\r\n" + backtick.repeatElement(4) + "\r\n"
        let blocks = try ImpressDiagramDocument.mermaidBlocks(in: Data(source.utf8))
        #expect(blocks.count == 1)
        let doc = try #require(blocks.first)
        #expect(doc.nodes.count == 2)
        let approved = try doc.selection(ids: [doc.nodes[0].id])
        let payload = try approved.contextJSON()
        #expect(payload.contains("允许"))
        #expect(!payload.contains("不得发送"))
        #expect(String(decoding: Array(source.utf8)[doc.startUTF8..<doc.endUTF8],
            as: UTF8.self).hasPrefix(backtick.repeatElement(4)))
    }
    @Test func duplicateHeadingsStaySeparateAndChildExpansionIsExplicit() throws {
        let doc = try ImpressDiagramDocument.markmap(in:
            Data("# Root\n## Same\nConcrete mechanism\n### Child\n## Same\nUnapproved\n".utf8))
        let same = doc.nodes.filter { $0.title == "Same" }
        #expect(same.count == 2)
        #expect(same[0].id != same[1].id)
        let one = try doc.selection(ids: [same[0].id])
        #expect(!one.ids.contains(doc.nodes[2].id))
        #expect(!((try one.contextJSON()).contains("Unapproved")))
        #expect((try one.contextJSON()).contains("Concrete mechanism"))
        let expanded = try doc.selection(ids: [same[0].id], includeDescendants: true)
        #expect(expanded.ids.contains(doc.nodes[2].id))
        #expect(!expanded.ids.contains(same[1].id))
        #expect(expanded.ancestors.contains(doc.nodes[0].id))
    }
    @Test func markdownListBranchesAreIndependentAndNeverLeakSiblings() throws {
        let raw = "# Topic\r\n- Main hypothesis\r\n" +
            "  - Approved 🌱\r\n  - Private secret\r\n" +
            "- Another group\r\n  1. Unselected answer\r\n"
        let doc = try ImpressDiagramDocument.markmap(in: Data(raw.utf8))
        let root = try #require(doc.nodes.first(where: { $0.title == "Main hypothesis" }))
        let approved = try #require(doc.nodes.first(where: { $0.title == "Approved 🌱" }))
        let sibling = try #require(doc.nodes.first(where: { $0.title == "Private secret" }))
        #expect(approved.parentID == root.id)
        #expect(sibling.parentID == root.id)
        let chosenOnly = try doc.selection(ids: [approved.id])
        let excerpt = try chosenOnly.contextJSON()
        #expect(excerpt.contains("Approved 🌱"))
        #expect(excerpt.contains("Main hypothesis"))
        #expect(!excerpt.contains("Private secret"))
        #expect(!excerpt.contains("Unselected answer"))
        // Merely clicking a parent is NOT approval to copy descendants.
        let parentOnly = try doc.selection(ids: [root.id])
        #expect(!((try parentOnly.contextJSON()).contains("Private secret")))
        #expect(!((try parentOnly.contextJSON()).contains("Approved 🌱")))
        // A separate explicit subtree consent can include these children.
        let full = try doc.selection(ids: [root.id], includeDescendants: true)
        #expect(full.ids.contains(approved.id))
        #expect(full.ids.contains(sibling.id))
        #expect(!full.ids.contains(try #require(
            doc.nodes.first(where: { $0.title == "Another group" })).id))
    }

    @Test func ancestorMetadataCannotUploadPrivateUnselectedParentBody() throws {
        let markdown = "# Parent\nPRIVATE PARENT BODY\n" +
            "## Selected child\nReviewed observation\n" +
            "## Secret sibling\nPRIVATE SIBLING BODY\n"
        let diagram = try ImpressDiagramDocument.markmap(in: Data(markdown.utf8))
        let child = try #require(diagram.nodes.first {
            $0.title == "Selected child"
        })
        let chosen = try diagram.selection(ids: [child.id])
        let exported = try chosen.contextJSON()
        #expect(exported.contains("Selected child"))
        #expect(exported.contains("Reviewed observation"))
        #expect(exported.contains("Parent"))
        #expect(!exported.contains("PRIVATE PARENT BODY"))
        #expect(!exported.contains("PRIVATE SIBLING BODY"))
        #expect(chosen.nodes.filter { chosen.ancestors.contains($0.id) }
            .allSatisfy { $0.ownSourceText.isEmpty })
    }

    @Test func headinglessListHasRealAncestorAndNoUnapprovedSibling() throws {
        let doc = try ImpressDiagramDocument.markmap(in:
            Data("- Parent\n  - Approved\n  - Secret\n".utf8))
        let root = try #require(doc.nodes.first { $0.title == "全文" })
        let parent = try #require(doc.nodes.first { $0.title == "Parent" })
        let child = try #require(doc.nodes.first { $0.title == "Approved" })
        #expect(parent.parentID == root.id)
        #expect(child.parentID == parent.id)
        let selection = try doc.selection(ids: [child.id])
        #expect(selection.ancestors.contains(root.id))
        #expect(!(try selection.contextJSON()).contains("Secret"))
    }

    @Test func listParserDoesNotTreatFrontmatterOrFencedExamplesAsNodes() throws {
        let md = "---\r\n- hidden: yes\r\n---\r\n# Topic\r\n" +
            "~~~swift\r\n- secret code line\r\n~~~\r\n" +
            "- Explicit branch\r\n  1) Nested item\r\n> - inert quote\r\n"
        let doc = try ImpressDiagramDocument.markmap(in: Data(md.utf8))
        #expect(doc.nodes.contains { $0.title == "Explicit branch" })
        #expect(doc.nodes.contains { $0.title == "Nested item" })
        #expect(!doc.nodes.contains { $0.title.contains("hidden") })
        #expect(!doc.nodes.contains { $0.title.contains("secret code") })
        #expect(!doc.nodes.contains { $0.title.contains("inert quote") })
        let child = try #require(doc.nodes.first { $0.title == "Nested item" })
        let parent = try #require(doc.nodes.first { $0.title == "Explicit branch" })
        #expect(child.parentID == parent.id)
        #expect(child.startUTF8 == Array(md.utf8).firstIndex(of: UInt8(ascii: "1"))! - 2)
    }

    @Test func forgedNodeAndMalformedBytesFailClosed() throws {
        let doc = try ImpressDiagramDocument.markmap(in: Data("# Hi\n".utf8))
        #expect(throws: ImpressDiagramError.invalidSelection) {
            try doc.selection(ids: ["fabricated"])
        }
        #expect(throws: ImpressDiagramError.invalidDocument) {
            try ImpressDiagramDocument.markmap(in: Data([0xFF,0xFF]))
        }
    }
}
private extension String {
    func repeatElement(_ count: Int) -> String { String(repeating: self, count: count) }
}
