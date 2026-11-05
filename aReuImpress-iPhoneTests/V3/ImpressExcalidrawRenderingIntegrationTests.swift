import XCTest
import UIKit
import ImpressReviewCore
@testable import aReuImpress_iPhone

/// RDR native glyph fidelity: synthetic read-only Excalidraw, not user Vault.
final class ImpressExcalidrawRenderingIntegrationTests: XCTestCase {
    @MainActor
    func testAuthorizedMarkdownEmbedIncludesOnlyReferencedRasterPixels() throws {
        // A disposable fake Vault: no personal attachments or network input.
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("Impress-G3-Images-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let drawings = root.appendingPathComponent("Drawings")
        try FileManager.default.createDirectory(
            at: drawings, withIntermediateDirectories: true)
        let renderer = UIGraphicsImageRenderer(
            size: CGSize(width: 4, height: 4))
        let png = try XCTUnwrap(renderer.image { context in
            UIColor.systemGreen.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 4, height: 4))
        }.pngData())
        let authorizedRaster = "data:image/png;base64," + png.base64EncodedString()
        let unreferencedCanary = "data:image/png;base64," +
            Data("UNREFERENCED_PIXEL_BYTES".utf8).base64EncodedString()
        let source: [String: Any] = [
            "type": "excalidraw",
            "elements": [
                ["id": "visible", "type": "image", "x": 0, "y": 0,
                 "width": 80, "height": 80, "fileId": "authorized"],
                ["id": "deleted", "type": "image", "x": 100, "y": 0,
                 "width": 80, "height": 80, "fileId": "private",
                 "isDeleted": true]
            ],
            "files": [
                "authorized": ["mimeType": "image/png", "dataURL": authorizedRaster],
                "private": ["mimeType": "image/png", "dataURL": unreferencedCanary],
                "unreferenced": ["mimeType": "image/png",
                                  "dataURL": unreferencedCanary]
            ]
        ]
        let drawingData = try JSONSerialization.data(withJSONObject: source)
        let drawingFile = drawings.appendingPathComponent("Inline.excalidraw")
        try drawingData.write(to: drawingFile)
        let identity = try ImVaultFileIdentity(
            vaultID: "g3-disposable", relativePath: "Notes/Host.md")
        let markdown = "# Host\n![[Drawings/Inline.excalidraw]]\nAfter"
        let projected = try ImVaultReadSync.safeMarkdownProjection(
            root: root, identity: identity, source: markdown)
        let sections = projected.components(separatedBy: "~~~impress-excalidraw\n")
        XCTAssertEqual(sections.count, 2,
            "The authorized one-hop Drawing must enter the real Markdown projection")
        let base64 = try XCTUnwrap(sections.last?
            .components(separatedBy: "\n~~~").first)
        let packed = try XCTUnwrap(Data(base64Encoded: base64))
        let decoded = try XCTUnwrap(JSONSerialization.jsonObject(
            with: packed) as? [String: Any])
        let files = try XCTUnwrap(decoded["files"] as? [String: Any])
        let selected = try XCTUnwrap(files["authorized"] as? [String: String])
        XCTAssertEqual(selected["mimeType"], "image/png")
        XCTAssertEqual(selected["dataURL"], authorizedRaster)
        XCTAssertNil(files["private"],
            "Deleted Excalidraw pixels must never enter the inline WebKit projection")
        XCTAssertNil(files["unreferenced"],
            "Non-displayed source bytes must stay inside the authorized file")
        XCTAssertFalse(projected.contains(unreferencedCanary))
        XCTAssertTrue(projected.contains("After"))
        XCTAssertEqual(try Data(contentsOf: drawingFile), drawingData,
            "The embed must never write back to the source Drawing")
    }

    @MainActor
    func testBoundChineseTextHasRealUIKitLabelAndDocumentFontSize() throws {
        let json = """
        {"type":"excalidraw","appState":{"viewBackgroundColor":"#ffffff"},
         "elements":[
          {"id":"panel","type":"rectangle","x":0,"y":0,"width":400,"height":240,
           "backgroundColor":"#f9f9f9","strokeColor":"#111111"},
          {"id":"task","type":"text","x":24,"y":24,"width":330,"height":130,
           "containerId":"panel","fontSize":32,"fontFamily":2,
           "textAlign":"left","strokeColor":"#202020",
           "text":"任务文字：复习及理解 🧠"}]}
        """
        let model = try ImpressExcalidrawScene.parse(Data(json.utf8),
            format: .excalidrawJSON)
        let reader = try ImpressExcalidrawNativeView(source: model)
        reader.frame = CGRect(x: 0, y: 0, width: 390, height: 430)
        reader.layoutIfNeeded()
        let labels = reader.subviews.flatMap(\.subviews)
            .flatMap(\.subviews).compactMap { $0 as? UILabel }
        let task = try XCTUnwrap(labels.first { $0.text?.contains("复习及理解") == true })
        XCTAssertEqual(task.font.pointSize, 32, accuracy: 0.1)
        XCTAssertEqual(task.textAlignment, .left)
        XCTAssertFalse(task.isHidden)
        XCTAssertGreaterThan(task.frame.height, 30)
    }
    @MainActor
    func testNativeExcalidrawOpacityAffectsStrokeFillAndTextWithoutHidingSelection() throws {
        let json = """
        {"type":"excalidraw","appState":{"viewBackgroundColor":"#ffffff"},
         "elements":[
          {"id":"panel","type":"rectangle","x":0,"y":0,"width":160,"height":90,
           "opacity":35,"strokeColor":"#111111","backgroundColor":"#999999"},
          {"id":"caption","type":"text","x":10,"y":10,"width":120,"height":50,
           "opacity":60,"fontSize":20,"strokeColor":"#222222","text":"透明文字"}]}
        """
        let scene = try ImpressExcalidrawScene.parse(Data(json.utf8),
            format: .excalidrawJSON)
        let reader = try ImpressExcalidrawNativeView(source: scene)
        let controls = reader.subviews.flatMap(\.subviews)
            .compactMap { $0 as? UIButton }
        let panel = try XCTUnwrap(controls.first {
            $0.accessibilityIdentifier == "impress.excalidraw.element.panel"
        })
        let shape = try XCTUnwrap(panel.layer.sublayers?
            .compactMap { $0 as? CAShapeLayer }.first)
        XCTAssertEqual(shape.opacity, 0.35, accuracy: 0.001,
            "The outline and the fill must share Excalidraw opacity")
        XCTAssertEqual(panel.alpha, 1, accuracy: 0.001,
            "Selection border must remain visible even when artwork is translucent")
        let caption = try XCTUnwrap(controls.first {
            $0.accessibilityIdentifier == "impress.excalidraw.element.caption"
        })
        let label = try XCTUnwrap(caption.subviews
            .compactMap { $0 as? UILabel }
            .first(where: { $0.text == "透明文字" }),
            "Inspect the authored Excalidraw label, never UIButton.titleLabel")
        XCTAssertEqual(label.alpha, 0.60, accuracy: 0.001)
    }

    @MainActor
    func testBoundTextKeepsSourceOcclusionAndActualVerticalCenter() throws {
        let drawing = """
        {"type":"excalidraw","elements":[
          {"id":"base","type":"rectangle","x":0,"y":0,"width":320,"height":210,
           "backgroundColor":"#dddddd"},
          {"id":"bound","type":"text","x":15,"y":15,"width":290,"height":180,
           "containerId":"base","fontSize":26,"lineHeight":1.6,
           "verticalAlign":"middle","text":"先复习再验证"},
          {"id":"front","type":"ellipse","x":10,"y":10,"width":100,"height":90,
           "backgroundColor":"#ffffff"}]}
        """
        let scene = try ImpressExcalidrawScene.parse(Data(drawing.utf8),
            format: .excalidrawJSON)
        let reader = try ImpressExcalidrawNativeView(source: scene)
        reader.frame = CGRect(x: 0, y: 0, width: 390, height: 430)
        reader.layoutIfNeeded()
        let buttons = reader.subviews.flatMap(\.subviews)
            .compactMap { $0 as? UIButton }
        func node(_ name: String) throws -> UIButton {
            try XCTUnwrap(buttons.first {
                $0.accessibilityIdentifier == "impress.excalidraw.element." + name
            })
        }
        let container = try node("base")
        let textNode = try node("bound")
        let occluder = try node("front")
        XCTAssertGreaterThan(textNode.layer.zPosition, container.layer.zPosition)
        XCTAssertLessThan(textNode.layer.zPosition, occluder.layer.zPosition,
            "Later Excalidraw shapes must still cover earlier bound text")
        let label = try XCTUnwrap(textNode.subviews.compactMap { $0 as? UILabel }
            .first(where: { $0.text == "先复习再验证" }),
            "Inspect the authored Excalidraw glyph label, not UIButton.titleLabel")
        XCTAssertGreaterThan(label.frame.minY, 12,
            "Middle-aligned text must use measured glyph height, not full box height")
        let style = try XCTUnwrap(label.attributedText?.attribute(.paragraphStyle,
            at: 0, effectiveRange: nil) as? NSParagraphStyle)
        XCTAssertEqual(style.minimumLineHeight, 26 * 1.6, accuracy: 0.5)
    }



    @MainActor
    func testLateSerializedBoundTextCannotCoverNewerOccludingShape() throws {
        // Match the offline Markdown SVG painter: a label's owner determines
        // its layer even when the source serializes that label at the end.
        let drawing = """
        {"type":"excalidraw","elements":[
          {"id":"base","type":"rectangle","x":0,"y":0,"width":220,"height":180,
           "backgroundColor":"#cccccc"},
          {"id":"front","type":"ellipse","x":20,"y":20,"width":120,"height":80,
           "backgroundColor":"#ffffff"},
          {"id":"late-bound","type":"text","containerId":"base",
           "x":12,"y":12,"width":200,"height":100,
           "fontSize":22,"text":"晚序列化绑定文字 🧠"}]}
        """
        let scene = try ImpressExcalidrawScene.parse(Data(drawing.utf8),
            format: .excalidrawJSON)
        let reader = try ImpressExcalidrawNativeView(source: scene)
        let controls = reader.subviews.flatMap(\.subviews)
            .compactMap { $0 as? UIButton }
        func node(_ id: String) throws -> UIButton {
            try XCTUnwrap(controls.first {
                $0.accessibilityIdentifier == "impress.excalidraw.element." + id
            })
        }
        let base = try node("base")
        let front = try node("front")
        let label = try node("late-bound")
        XCTAssertGreaterThan(label.layer.zPosition, base.layer.zPosition)
        XCTAssertLessThan(label.layer.zPosition, front.layer.zPosition,
            "Bound text must not escape its owner to cover later shapes")
        XCTAssertNotNil(label.subviews.compactMap { $0 as? UILabel }
            .first(where: { $0.text == "晚序列化绑定文字 🧠" }))
    }

    @MainActor
    func testSerializedArrowheadsHaveIndependentGeometryAndRespectNoHead() throws {
        // Synthetic source, identical geometry but distinct authored endpoints.
        let drawing = """
        {"type":"excalidraw","elements":[
          {"id":"first","type":"arrow","x":0,"y":0,"width":150,"height":60,
           "points":[[0,0],[150,60]],"startArrowhead":"dot",
           "endArrowhead":"triangle","opacity":55,"strokeStyle":"dashed",
           "strokeColor":"#224466"},
          {"id":"plain","type":"arrow","x":0,"y":90,"width":150,"height":60,
           "points":[[0,0],[150,60]],"startArrowhead":"none",
           "endArrowhead":"none","strokeColor":"#224466"},
          {"id":"third","type":"arrow","x":0,"y":180,"width":150,"height":60,
           "points":[[0,0],[150,60]],"startArrowhead":"bar",
           "endArrowhead":"diamond_outline","strokeColor":"#224466"}]}
        """
        let scene = try ImpressExcalidrawScene.parse(Data(drawing.utf8),
            format: .excalidrawJSON)
        let first = try XCTUnwrap(scene.elements.first)
        XCTAssertEqual(first.startArrowhead, "dot")
        XCTAssertEqual(first.endArrowhead, "triangle")
        let excerpt = try scene.selection(ids: ["first"]).textContextJSON()
        XCTAssertTrue(excerpt.contains("triangle"))
        XCTAssertFalse(excerpt.contains("diamond_outline"),
            "Unselected diagram elements must never enter Chat source excerpts")
        let reader = try ImpressExcalidrawNativeView(source: scene)
        let buttons = reader.subviews.flatMap(\.subviews)
            .compactMap { $0 as? UIButton }
        func layers(_ id: String) throws -> [CAShapeLayer] {
            let button = try XCTUnwrap(buttons.first {
                $0.accessibilityIdentifier == "impress.excalidraw.element." + id
            })
            return button.layer.sublayers?.compactMap { $0 as? CAShapeLayer } ?? []
        }
        let image = try layers("first")
        XCTAssertEqual(image.count, 3)
        XCTAssertEqual(image[0].lineDashPattern, [8, 8])
        let start = try XCTUnwrap(image.first {
            $0.name == "impress.excalidraw.arrowhead.start"
        })
        let end = try XCTUnwrap(image.first {
            $0.name == "impress.excalidraw.arrowhead.end"
        })
        XCTAssertEqual(start.opacity, 0.55, accuracy: 0.001)
        XCTAssertEqual(end.opacity, 0.55, accuracy: 0.001)
        XCTAssertNil(start.lineDashPattern)
        XCTAssertNil(end.lineDashPattern)
        XCTAssertNotNil(start.path)
        XCTAssertNotNil(end.path)
        XCTAssertGreaterThan(try XCTUnwrap(end.path).boundingBox.width, 0)
        XCTAssertGreaterThan(try XCTUnwrap(start.path).boundingBox.height, 0)
        let empty = try layers("plain")
        XCTAssertEqual(empty.count, 1,
            "An explicit 'none' arrow end cannot inherit a default V head")
        let alternate = try layers("third")
        XCTAssertEqual(alternate.count, 3)
        XCTAssertNotNil(alternate.first {
            $0.name == "impress.excalidraw.arrowhead.start"
        })
        XCTAssertNotNil(alternate.first {
            $0.name == "impress.excalidraw.arrowhead.end"
        })
        // This is a native geometry test, not an official SVG pixel A/B.
    }

    @MainActor
    func testSerializedExcalidrawRoundnessAndDashStylesReachRealShapePaths() throws {
        // Types 1/2/3 and nil are official serialized source semantics.
        // No user Vault, network, SVG scripts or fixture images are loaded.
        let drawing = """
        {"type":"excalidraw","elements":[
          {"id":"sharp","type":"rectangle","x":0,"y":0,"width":160,"height":120,
           "strokeStyle":"solid","backgroundColor":"#dddddd"},
          {"id":"round","type":"rectangle","x":170,"y":0,"width":160,"height":120,
           "roundness":{"type":3},"strokeStyle":"dashed","backgroundColor":"#eeeeee"},
          {"id":"proportional","type":"rectangle","x":340,"y":0,"width":160,"height":120,
           "roundness":{"type":2},"strokeStyle":"dotted"},
          {"id":"frame","type":"frame","x":0,"y":130,"width":160,"height":120}]}
        """
        let scene = try ImpressExcalidrawScene.parse(Data(drawing.utf8),
            format: .excalidrawJSON)
        let reader = try ImpressExcalidrawNativeView(source: scene)
        let buttons = reader.subviews.flatMap(\.subviews)
            .compactMap { $0 as? UIButton }
        func shape(_ id: String) throws -> CAShapeLayer {
            let button = try XCTUnwrap(buttons.first {
                $0.accessibilityIdentifier == "impress.excalidraw.element." + id
            })
            return try XCTUnwrap(button.layer.sublayers?
                .compactMap { $0 as? CAShapeLayer }.first)
        }
        let sharp = try shape("sharp")
        let round = try shape("round")
        let proportional = try shape("proportional")
        let frame = try shape("frame")
        let corner = CGPoint(x: 2, y: 2)
        XCTAssertTrue(try XCTUnwrap(sharp.path).contains(corner),
            "Nil roundness means true sharp corners; the old unconditional 4pt radius was wrong")
        XCTAssertFalse(try XCTUnwrap(round.path).contains(corner))
        XCTAssertFalse(try XCTUnwrap(proportional.path).contains(corner))
        XCTAssertTrue(try XCTUnwrap(frame.path).contains(corner))
        XCTAssertNil(sharp.lineDashPattern)
        XCTAssertEqual(round.lineDashPattern, [8, 8])
        XCTAssertEqual(proportional.lineDashPattern, [1, 6])
        XCTAssertEqual(proportional.lineCap, .round)
    }
}
