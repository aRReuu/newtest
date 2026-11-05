import Foundation
import Testing
@testable import ImpressReviewCore

@Suite("JSON Canvas spatial scope and read-only authoring boundaries")
struct ImpressCanvasDocumentTests {
    private let bytes = Data("""
    {
      "nodes": [
        {"id":"g", "type":"group","x":-20,"y":10,"width":600,"height":400,"label":"Review"},
        {"id":"a", "type":"text","x":10,"y":30,"width":180,"height":120,"text":"含义 A"},
        {"id":"b", "type":"file","x":230,"y":35,"width":180,"height":120,
         "file":"Courses/Notes.md","subpath":"#Concept"},
        {"id":"out","type":"link","x":900,"y":50,"width":190,"height":100,
         "url":"https://example.invalid/not-requested"}
      ],
      "edges": [
        {"id":"edge-a","fromNode":"a","fromSide":"right",
         "toNode":"b","toSide":"left","toEnd":"arrow","label":"causes"},
        {"id":"edge-b","fromNode":"b","toNode":"out","label":"not selected"}
      ]
    }
    """.utf8)

    @Test func geometryAndOrderAreRetainedWithoutAutomaticLayout() throws {
        let doc = try ImpressCanvasDocument.parse(bytes)
        #expect(doc.nodes.map(\.id) == ["g", "a", "b", "out"])
        #expect(doc.nodes[0].x == -20)
        #expect(doc.nodes[0].width == 600)
        #expect(doc.nodes[2].file == "Courses/Notes.md")
        #expect(doc.nodes[2].subpath == "#Concept")
        #expect(doc.edges[0].fromSide == "right")
    }

    @Test func selectingSingleNodeNeverReadsOthersOrFollowsLinks() throws {
        let doc = try ImpressCanvasDocument.parse(bytes)
        let selection = try doc.selection(nodeIDs: ["a"])
        #expect(selection.nodes.map(\.id) == ["a"])
        #expect(selection.edges.isEmpty)
        let json = try selection.serializedJSON()
        #expect(json.contains("含义 A"))
        #expect(!json.contains("Courses/Notes.md"))
        #expect(!json.contains("example.invalid"))
    }

    @Test func explicitGroupExpansionIncludesVisibleMembersOnly() throws {
        let doc = try ImpressCanvasDocument.parse(bytes)
        let groupOnly = try doc.selection(nodeIDs: ["g"])
        #expect(groupOnly.nodes.map(\.id) == ["g"])
        let expanded = try doc.selection(nodeIDs: ["g"], includeGroupMembers: true)
        #expect(expanded.nodes.map(\.id) == ["g", "a", "b"])
        #expect(expanded.edges.map(\.id) == ["edge-a"])
        #expect(!expanded.nodeIDs.contains("out"))
        let exact = try doc.selection(nodeIDs: ["a","b"])
        #expect(exact.edges.map(\.id) == ["edge-a"])
    }

    @Test func corruptGeometryAndDanglingEdgesAreRejected() throws {
        let bad = """
        {"nodes":[{"id":"a","type":"text","x":0,"y":0,"width":0,"height":2}]}
        """
        #expect(throws: ImpressCanvasError.invalidGeometry) {
            try ImpressCanvasDocument.parse(Data(bad.utf8))
        }
        let dangling = """
        {"nodes":[{"id":"a","type":"text","x":0,"y":0,"width":2,"height":2}],
        "edges":[{"id":"e","fromNode":"a","toNode":"missing"}]}
        """
        #expect(throws: ImpressCanvasError.invalidReference) {
            try ImpressCanvasDocument.parse(Data(dangling.utf8))
        }
        let dup = """
        {"nodes":[{"id":"a","type":"text","x":0,"y":0,"width":2,"height":2},
                  {"id":"a","type":"text","x":1,"y":1,"width":2,"height":2}]}
        """
        #expect(throws: ImpressCanvasError.duplicateID) {
            try ImpressCanvasDocument.parse(Data(dup.utf8))
        }
        #expect(throws: ImpressCanvasError.emptySelection) {
            try ImpressCanvasDocument.parse(bytes).selection(nodeIDs: ["not-here"])
        }
    }

    @Test func arbitraryAndUnknownPayloadDoesNotGainScriptExecution() throws {
        let text = """
        {"nodes":[{"id":"plugin","type":"plugin-script","x":0,"y":0,"width":10,"height":10,
          "text":"<script>fetch('https://evil')</script>"}]}
        """
        let document = try ImpressCanvasDocument.parse(Data(text.utf8))
        #expect(!document.nodes[0].isKnownType)
        let selection = try document.selection(nodeIDs: ["plugin"])
        #expect(selection.nodes.count == 1)
        // These remain inert JSON string values. Rendering must escape them,
        // and neither the decoder nor this test executes any embedded script.
        #expect(try selection.serializedJSON().contains("<script>"))
    }
}