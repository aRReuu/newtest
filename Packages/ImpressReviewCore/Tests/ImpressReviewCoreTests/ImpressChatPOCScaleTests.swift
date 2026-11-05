import XCTest
@testable import ImpressReviewCore

final class ImpressChatPOCScaleTests: XCTestCase {
    func testResponseSizesRemainSemanticallyEquivalentAcrossChunkings() {
        for bytes in [1_024, 16_384, 65_536] {
            let phrase = "中文🧠 **证据**：逐层解释。"
            let paragraph = String(repeating: phrase, count: max(1, bytes / phrase.utf8.count))
            let markdown = "# 压力测试\n\n" + paragraph + "\n\n" +
                "~~~swift\nlet observation = true\n~~~\n\n" +
                "| 格式 | 结果 |\n| --- | --- |\n| GFM | 可解析 |\n\n" +
                "$$\nE=mc^2\n$$"
            let expected = ImpressChatPOCStream.parseOnce(markdown)
            let scalars = Array(markdown.unicodeScalars)
            // Quadratic dirty-tail stress belongs to a bounded separate
            // test; 64KB one-scalar callbacks are not a realistic network
            // update cadence and would overwhelm the CI budget.
            for eventSize in [max(1, bytes / 256), 257, 1_024] {
                var engine = ImpressChatPOCStream()
                engine.start()
                for index in stride(from: 0, to: scalars.count, by: eventSize) {
                    engine.append(scalars[index..<min(scalars.count, index+eventSize)]
                        .map(String.init).joined())
                }
                // Algorithmic work counters permit repeatable 1/16/64KB
                // comparisons without inventing a device FPS or CPU figure.
                XCTAssertGreaterThan(engine.eventCount, 0)
                XCTAssertGreaterThanOrEqual(engine.cumulativeReparsedUTF8Count,
                                            engine.lastReparsedUTF8Count)
                XCTAssertLessThanOrEqual(engine.peakDirtyTailUTF8Count,
                                         markdown.utf8.count)
                print("CHAT_POC_INCREMENTAL_COST source_bytes=\(markdown.utf8.count) " +
                      "event_scalars=\(eventSize) events=\(engine.eventCount) " +
                      "reparsed_utf8_bytes=\(engine.cumulativeReparsedUTF8Count) " +
                      "peak_dirty_tail_bytes=\(engine.peakDirtyTailUTF8Count) " +
                      "committed_blocks=\(engine.committedBlockCount)")
                engine.finish()
                XCTAssertEqual(engine.blocks, expected,
                    "\(bytes) bytes, \(eventSize)-scalar fragments")
                XCTAssertEqual(engine.phase, .completed)
            }
        }
    }

    func testUnclosedLargeCodeBlockNeverFabricatesCompletedAnswer() {
        var engine = ImpressChatPOCStream()
        engine.start()
        engine.append("~~~swift\n")
        for index in 0..<1_000 {
            engine.append("let item\(index) = \"中文🧠\"\n")
        }
        XCTAssertEqual(engine.blocks.count, 1)
        XCTAssertEqual(engine.blocks[0].kind, .code)
        XCTAssertFalse(engine.blocks[0].stable)
        XCTAssertEqual(engine.phase, .streaming)
        engine.stop()
        engine.finish()
        XCTAssertEqual(engine.phase, .stopped)
        XCTAssertFalse(engine.blocks[0].stable)
    }
}
