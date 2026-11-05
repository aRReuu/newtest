import XCTest
@testable import ImpressReviewCore

final class ImpressFrontmatterReadingTests: XCTestCase {
    func testTypedPropertiesAndSourceByteBoundaries() {
        let raw = "\u{FEFF}---\r\nmindmap-plugin: basic\r\ntags:\r\n  - focus\r\n  - review\r\n" +
            "Date: 2026-01-31\r\nStatus:\r\nCount: 12\r\nDone: false\r\n" +
            "Next: \"[[Work#Plan|计划]]\"\r\n---\r\n# 正文\r\n- 一级\r\n  - 二级\r\n"
        let result = ImpressFrontmatterReader.parse(raw)
        XCTAssertEqual(result.state, .valid)
        XCTAssertEqual(result.fields.map(\.name),
                       ["mindmap-plugin", "tags", "Date", "Status", "Count", "Done", "Next"])
        XCTAssertEqual(result.fields.map(\.kind),
                       [.text, .tags, .date, .empty, .number, .boolean, .wikilink])
        XCTAssertEqual(result.fields[1].values, ["focus", "review"])
        XCTAssertEqual(result.fields[3].displayValue, "—")
        XCTAssertEqual(result.body, "# 正文\r\n- 一级\r\n  - 二级\r\n")
        XCTAssertEqual(Array(raw.utf8)[result.bodyStartUTF8...],
                       Array(result.body.utf8)[...])
        for field in result.fields {
            XCTAssertTrue(field.startUTF8 < field.endUTF8)
            XCTAssertTrue(field.endUTF8 <= result.bodyStartUTF8)
        }
        XCTAssertTrue(result.fields[0].values[0] == "basic",
                      "mindmap-plugin metadata must not create an invented graph")
    }

    func testNonFrontmatterAndIncompleteFrontmatterRemainVisible() {
        let plain = "# Article\n---\nBody"
        let absent = ImpressFrontmatterReader.parse(plain)
        XCTAssertEqual(absent.state, .absent)
        XCTAssertEqual(absent.body, plain)
        let malformed = "---\nname: yes\n# no closing fence"
        let invalid = ImpressFrontmatterReader.parse(malformed)
        XCTAssertEqual(invalid.state, .invalid)
        XCTAssertEqual(invalid.body, malformed)
        XCTAssertNotNil(invalid.diagnostic)
        XCTAssertEqual(invalid.bodyStartUTF8, 0)
    }

    func testUnsupportedComplexYAMLDoesNotSilentlyRemoveData() {
        let complex = "---\nsettings:\n  child: true\n---\nActual content"
        let result = ImpressFrontmatterReader.parse(complex)
        XCTAssertEqual(result.state, .unsupported)
        XCTAssertEqual(result.body, complex)
        XCTAssertNotNil(result.diagnostic)
    }

    func testEmptyTagArrayAndInlineList() {
        let text = "---\ntags: []\naliases: ['alpha', 'beta']\nactive: true\n---\nBody"
        let result = ImpressFrontmatterReader.parse(text)
        XCTAssertEqual(result.state, .valid)
        XCTAssertEqual(result.fields[0].kind, .tags)
        XCTAssertTrue(result.fields[0].values.isEmpty)
        XCTAssertEqual(result.fields[1].values, ["alpha", "beta"])
        XCTAssertEqual(result.fields[2].kind, .boolean)
        XCTAssertEqual(result.body, "Body")
    }

    func testDuplicateKeysFailClosedWithoutDiscardingBytes() {
        let source = "---\r\nDate: 2026-01-31\r\nDate: 2026-02-01\r\n---\r\n# Body"
        let result = ImpressFrontmatterReader.parse(source)
        XCTAssertEqual(result.state, .invalid)
        XCTAssertEqual(result.body, source)
    }
}
