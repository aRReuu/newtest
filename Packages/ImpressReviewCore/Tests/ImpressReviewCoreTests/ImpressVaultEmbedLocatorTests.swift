import XCTest
@testable import ImpressReviewCore

final class ImpressVaultEmbedLocatorTests: XCTestCase {
    func testUTF8MixedNewlinesAndInlineCodeDoNotGuessSource() {
        let tick = String(Character(UnicodeScalar(96)!))
        let source = "\u{FEFF}# Example\r\n![[Study/Diagram.canvas]]\r\n" +
            "some " + tick + "![[ignored.canvas]]" + tick + " text\n" +
            "~~~markdown\n![[inside-fence.excalidraw]]\n~~~\r\n" +
            "<!-- ![[comment.png]] -->\n" +
            "![[Drawing.excalidraw|绘图]] and ![[Photo.png]]\n"
        let found = ImpressVaultEmbedLocator.references(in: source)
        XCTAssertEqual(found.map(\.target),
                       ["Study/Diagram.canvas", "Drawing.excalidraw|绘图", "Photo.png"])
        let bytes = Array(source.utf8)
        for item in found {
            XCTAssertEqual(String(decoding: bytes[item.startUTF8..<item.endUTF8], as: UTF8.self),
                           "![[" + item.target + "]]")
            XCTAssertTrue(item.startUTF8 < item.endUTF8)
        }
    }

    func testEmbedsAreNotParsedInsideVariableLengthFences() {
        let ticks = String(repeating: String(Character(UnicodeScalar(96)!)), count: 4)
        let source = "   " + ticks + "md\n" +
            "![[false.canvas]]\n" + ticks + "\n" +
            "    ![[indented-code.canvas]]\n" +
            "![[true.canvas]]\n"
        XCTAssertEqual(ImpressVaultEmbedLocator.references(in: source).map(\.target),
                       ["true.canvas"])
    }
}
