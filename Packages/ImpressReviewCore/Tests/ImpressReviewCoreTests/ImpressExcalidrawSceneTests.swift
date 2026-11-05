import Foundation
import Testing
@testable import ImpressReviewCore

@Suite("Excalidraw offline source envelopes and exact selection")
struct ImpressExcalidrawSceneTests {
    private var rawJSON: String {
        """
        {"type":"excalidraw","version":2,
         "elements":[
          {"id":"f","type":"frame","x":0,"y":0,"width":500,"height":300},
          {"id":"a","type":"rectangle","x":20,"y":30,"width":100,"height":60,
           "strokeColor":"#222222","groupIds":["group-one"],"frameId":"f"},
          {"id":"b","type":"text","x":170,"y":40,"width":200,"height":80,
           "text":"Meaning 🌱","groupIds":["group-one"],"frameId":"f"},
          {"id":"outside","type":"text","x":600,"y":80,"width":200,"height":90,
           "text":"Never in implicit source"}]}
        """
    }

    @Test func plainJSONAndMarkdownWrapperReadSameElements() throws {
        let plain = try ImpressExcalidrawScene.parse(Data(rawJSON.utf8),
            format: .excalidrawJSON)
        let grave = String(Character(UnicodeScalar(96)!))
        let markdown = """
        ---
        excalidraw-plugin: parsed
        ---
        # Text Elements
        Indexed text only

        # Drawing
        \(grave)\(grave)\(grave)json
        \(rawJSON)
        \(grave)\(grave)\(grave)
        """
        let wrapped = try ImpressExcalidrawScene.parse(Data(markdown.utf8),
            format: .excalidrawMarkdown)
        #expect(wrapped.elements == plain.elements)
        #expect(wrapped.elements[1].strokeColor == "#222222")
        #expect(wrapped.elements[2].text == "Meaning 🌱")
        #expect(wrapped.elements[2].frameId == "f")
    }

    @Test func markdownDrawingAllowsLongerBacktickAndTildeFencesWithExactUnicode() throws {
        // Obsidian Markdown may mix BOM, CRLF, LF and fence widths. Parsing the
        // drawing must preserve the same elements as plain JSON; it never
        // rewrites the authorized source bytes.
        let grave = String(Character(UnicodeScalar(96)!))
        let four = String(repeating: grave, count: 4)
        let pairs = [(four, four + grave), ("~~~", "~~~~"), (four, four)]
        for (open, close) in pairs {
            let source = "\u{FEFF}---\r\nexcalidraw-plugin: parsed\r\n---\r\n" +
                "# Drawing\r\n  " + open + "json\r\n" + rawJSON +
                "\n " + close + "\r\n"
            let scene = try ImpressExcalidrawScene.parse(Data(source.utf8),
                format: .excalidrawMarkdown)
            #expect(scene.elements.count == 4)
            #expect(scene.elements.map(\.id) == ["f", "a", "b", "outside"])
            #expect(scene.elements[2].text == "Meaning 🌱")
        }
    }

    @Test func markdownDrawingRejectsShorterMismatchedAndOverindentedFences() throws {
        let grave = String(Character(UnicodeScalar(96)!))
        let triple = String(repeating: grave, count: 3)
        let quadruple = triple + grave
        let incomplete = [
            "# Drawing\n" + quadruple + "json\n" + rawJSON + "\n" + triple + "\n",
            "# Drawing\n~~~json\n" + rawJSON + "\n" + triple + "\n",
            "# Drawing\n    " + triple + "json\n" + rawJSON + "\n" + triple + "\n"
        ]
        for source in incomplete {
            #expect(throws: ImpressExcalidrawReadError.missingDrawing) {
                try ImpressExcalidrawScene.parse(Data(source.utf8),
                    format: .excalidrawMarkdown)
            }
        }
    }

    @Test func exactSelectionDoesNotLeakOtherElementsOrEmbeddedFiles() throws {
        let model = try ImpressExcalidrawScene.parse(Data(rawJSON.utf8),
            format: .excalidrawJSON)
        let one = try model.selection(ids: ["a"])
        #expect(one.elements.map(\.id) == ["a"])
        let payload = try one.textContextJSON()
        #expect(!payload.contains("Never in implicit source"))
        #expect(!payload.contains("Meaning 🌱"))
        #expect(payload.contains("group-one"))
        #expect(!payload.contains("data:image"))
    }

    @Test func explicitExpansionIncludesGroupPeersAndFrameChildren() throws {
        let model = try ImpressExcalidrawScene.parse(Data(rawJSON.utf8),
            format: .excalidrawJSON)
        let group = try model.selection(ids: ["a"], expandGroups: true)
        #expect(group.elements.map(\.id) == ["a","b"])
        let frame = try model.selection(ids: ["f"], expandGroups: true)
        #expect(frame.elements.map(\.id) == ["f","a","b"])
        #expect(!frame.elementIDs.contains("outside"))
    }

    @Test func explicitFrameAndBoundTextExpansionPreservesSourceConsentBoundary() throws {
        // A nested Excalidraw frame and its bound text represent one visible
        // drawing subgraph. Exact selection remains exact unless the user
        // explicitly approves expanding the scope in the native sheet.
        let json = """
        {"type":"excalidraw","elements":[
         {"id":"outer","type":"frame","x":0,"y":0,"width":500,"height":360},
         {"id":"inner","type":"frame","x":10,"y":10,"width":250,"height":220,
          "frameId":"outer"},
         {"id":"shape","type":"rectangle","x":24,"y":32,"width":130,"height":65,
          "frameId":"inner","groupIds":["approved-group"]},
         {"id":"label","type":"text","x":26,"y":40,"width":122,"height":40,
          "containerId":"shape","frameId":"inner","text":"阅读任务 🧠"},
         {"id":"peer","type":"rectangle","x":800,"y":30,"width":80,"height":50,
          "groupIds":["approved-group"]},
         {"id":"secret","type":"text","x":900,"y":80,"width":100,"height":40,
          "text":"DO-NOT-SEND-UNSELECTED"},
         {"id":"retired","type":"text","x":26,"y":40,"width":120,"height":40,
          "containerId":"shape","isDeleted":true,"text":"DO-NOT-SEND-DELETED"}]}
        """
        let model = try ImpressExcalidrawScene.parse(
            Data(json.utf8), format: .excalidrawJSON)
        let exactShape = try model.selection(ids: ["shape"])
        #expect(exactShape.elements.map(\.id) == ["shape"])
        #expect(!((try exactShape.textContextJSON()).contains("阅读任务")))

        let approvedShape = try model.selection(ids: ["shape"], expandGroups: true)
        #expect(Set(approvedShape.elements.map(\.id)) == Set(["shape", "label", "peer"]))
        let chosenText = try approvedShape.textContextJSON()
        #expect(chosenText.contains("阅读任务 🧠"))
        #expect(!chosenText.contains("DO-NOT-SEND-UNSELECTED"))
        #expect(!chosenText.contains("DO-NOT-SEND-DELETED"))
        #expect(!approvedShape.elementIDs.contains("outer"))
        #expect(!approvedShape.elementIDs.contains("inner"))

        let exactFrame = try model.selection(ids: ["outer"])
        #expect(exactFrame.elements.map(\.id) == ["outer"])
        let expandedFrame = try model.selection(ids: ["outer"], expandGroups: true)
        #expect(Set(expandedFrame.elements.map(\.id)) ==
            Set(["outer", "inner", "shape", "label"]))
        #expect(!expandedFrame.elementIDs.contains("peer"),
                "A nested frame must not implicitly approve the child's other groups")
        #expect(!(try expandedFrame.textContextJSON()).contains("DO-NOT-SEND"))
        #expect(throws: ImpressExcalidrawReadError.emptySelection) {
            try model.selection(ids: ["outer", "not-present"], expandGroups: true)
        }
    }

    @Test func officialLZStringBase64TransportDecodesUTF16() throws {
        #expect(try ImpressLZStringBase64.decompress("BYUwNmD2Q===") == "hello")
        #expect(throws: ImpressLZStringBase64.Error.malformedInput) {
            try ImpressLZStringBase64.decompress("abc:not-base64")
        }
    }

    @Test func compressedDrawingParsesRealUnicodeJSONAndChunkedLines() throws {
        // Fixed vector generated by LZString.compressToBase64 (UTF-16), not
        // by our decompressor. Includes a non-BMP Unicode scalar.
        let payload = "N4IgLgngDgpiBcIYA8DGBDANgSwCYCd0B3EAGhADcZ8BnbAewDsEAmcmTGAWxkbBoQBtUHgQh0ZcNDiJ8MVGHSMA5p0nIEARgAM5CFoCs5InjAALBAE5dIMzGzKzYBAYMBfUiNxiARpMiwYmAozuQa8Cw2+hE2JrjmCAAsNnYOTqw2wcjOiIAG8oC+moA8G4CM+5LK+PQArlAAkrgC8IIg5VVQALQSALpu3UA==="
        let source = "# Drawing\n```compressed-json\n" +
            String(payload.prefix(100)) + "\n\n" + String(payload.dropFirst(100)) +
            "\n```"
        let scene = try ImpressExcalidrawScene.parse(Data(source.utf8),
            format: .excalidrawMarkdown)
        #expect(scene.elements.count == 2)
        #expect(scene.elements[0].id == "a")
        #expect(scene.elements[1].text == "你好🌱")
        #expect(try scene.selection(ids: ["b"]).textContextJSON().contains("你好🌱"))
        let damaged = "# Drawing\n```compressed-json\n!" + payload + "\n```"
        #expect(throws: ImpressExcalidrawReadError.invalidScene) {
            try ImpressExcalidrawScene.parse(Data(damaged.utf8),
                format: .excalidrawMarkdown)
        }
    }

    @Test func boundChineseTextRetainsFontGeometryAndAppCanvas() throws {
        let json = """
        {"type":"excalidraw","appState":{"viewBackgroundColor":"#fffefb"},
         "elements":[
          {"id":"container","type":"rectangle","x":0,"y":0,"width":320,"height":180},
          {"id":"task","type":"text","x":12,"y":16,"width":280,"height":100,
           "containerId":"container","fontSize":32,"fontFamily":2,
           "textAlign":"center","verticalAlign":"middle",
           "strokeColor":"#252525","text":"阅读任务：中文与 emoji 🧠"}]}
        """
        let scene = try ImpressExcalidrawScene.parse(Data(json.utf8),
            format: .excalidrawJSON)
        #expect(scene.appState?.viewBackgroundColor == "#fffefb")
        let label = try #require(scene.elements.first { $0.id == "task" })
        #expect(label.fontSize == 32)
        #expect(label.containerId == "container")
        #expect(label.textAlign == "center")
        #expect(label.text?.contains("阅读任务") == true)
        #expect(try scene.selection(ids: ["task"]).textContextJSON().contains("阅读任务"))
    }

    @Test func duplicateIDsAndInvalidGeometryFailClosed() throws {
        let corrupt = """
        {"type":"excalidraw","elements":[
          {"id":"same","type":"text","x":0,"y":0,"width":2,"height":2},
          {"id":"same","type":"text","x":3,"y":3,"width":2,"height":2}]}
        """
        #expect(throws: ImpressExcalidrawReadError.duplicateID) {
            try ImpressExcalidrawScene.parse(Data(corrupt.utf8),
                format: .excalidrawJSON)
        }
        #expect(throws: ImpressExcalidrawReadError.emptySelection) {
            try ImpressExcalidrawScene.parse(Data(rawJSON.utf8),
                format: .excalidrawJSON).selection(ids: ["not-present"])
        }
    }
    @Test func finiteButExtremePolylineCoordinatesAreRejectedBeforeUIKitDrawing() throws {
        // A finite Double is not necessarily a drawable canvas coordinate:
        // adversarial control points can exceed CGFloat/rendering limits.
        for coordinate in ["1e200", "-1e200"] {
            let json = """
            {"type":"excalidraw","elements":[
              {"id":"line","type":"line","x":0,"y":0,"width":10,"height":10,
               "points":[[0,0],[\(coordinate),5]]}]}
            """
            #expect(throws: ImpressExcalidrawReadError.invalidGeometry) {
                try ImpressExcalidrawScene.parse(Data(json.utf8),
                    format: .excalidrawJSON)
            }
        }
        let valid = """
        {"type":"excalidraw","elements":[
          {"id":"line","type":"line","x":0,"y":0,"width":10,"height":10,
           "points":[[0,0],[8,5]]}]}
        """
        #expect(try ImpressExcalidrawScene.parse(Data(valid.utf8),
            format: .excalidrawJSON).elements.count == 1)
    }

    @Test func plainMdObsidianDrawingIsReadableButDeniedByGenericDraft() throws {
        let fence = String(repeating: String(Character(UnicodeScalar(96)!)), count: 3)
        let drawing = "---\nexcalidraw-plugin: parsed\ntags: [excalidraw]\n---\n" +
            "# Text Elements\nOnly a text index\n# Drawing\n" +
            fence + "json\n" + rawJSON + "\n" + fence + "\n"
        let bytes = Data(drawing.utf8)
        #expect(ImpressObsidianDrawingEnvelope.isSupportedDrawing(bytes))
        let source = try ImVaultFileIdentity(vaultID: "fixture",
            relativePath: "Drawing.md")
        #expect(source.documentFormat == .markdown)
        #expect(throws: ImVaultCoreError.invalidDraft) {
            try ImVaultDraft(identity: source, baseText: drawing)
        }
        #expect(!ImpressObsidianDrawingEnvelope.isSupportedDrawing(Data(
            "---\ntags: [excalidraw]\n---\n" .utf8)))
        let forged = drawing.replacingOccurrences(of: "\"type\":\"excalidraw\"",
            with: "\"type\":\"unknown\"")
        #expect(!ImpressObsidianDrawingEnvelope.isSupportedDrawing(Data(forged.utf8)))
    }


}

