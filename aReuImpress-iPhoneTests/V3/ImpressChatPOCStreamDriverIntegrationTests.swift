import Foundation
import UIKit
import XCTest
import ImpressReviewCore
@testable import aReuImpress_iPhone

/// POC-02 vertical integration: domain events -> incremental blocks -> UIKit.
@MainActor
final class ImpressChatPOCStreamDriverIntegrationTests: XCTestCase {
    func testInjectedDomainDeltasCompleteOnlyOnTerminal() async throws {
        let vc = ImpressChatPOCViewController()
        vc.loadViewIfNeeded()
        var observedPrompt = ""
        vc.injectOfflineDomainStreamForTest { prompt in
            observedPrompt = prompt
            return AsyncThrowingStream { stream in
                stream.yield(.delta("# 新理解\n\n"))
                stream.yield(.delta("可验证的解释。"))
                stream.yield(.completed)
                stream.finish()
            }
        }
        let input = try XCTUnwrap(subviews(in: vc.view, as: UITextView.self)
            .first(where: { $0.accessibilityIdentifier == "impress.chat.poc.input" }))
        input.text = "测试真实事件适配"
        vc.textViewDidChange(input)
        let send = try XCTUnwrap(subviews(in: vc.view, as: UIButton.self)
            .first(where: { $0.accessibilityIdentifier == "impress.chat.poc.send-stop" }))
        send.sendActions(for: .touchUpInside)
        for _ in 0..<80 where vc.testVisibleStreamPhase != .completed {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertEqual(observedPrompt, "测试真实事件适配")
        XCTAssertEqual(vc.testVisibleStreamPhase, .completed)
        XCTAssertEqual(send.accessibilityLabel, "发送")
    }

    func testInjectedStreamUnexpectedEOFKeepsPartialAsFailed() async throws {
        let vc = ImpressChatPOCViewController()
        vc.loadViewIfNeeded()
        vc.injectOfflineDomainStreamForTest { _ in
            AsyncThrowingStream { stream in
                stream.yield(.delta("只生成了部分文本"))
                stream.finish()
            }
        }
        let input = try XCTUnwrap(subviews(in: vc.view, as: UITextView.self)
            .first(where: { $0.accessibilityIdentifier == "impress.chat.poc.input" }))
        input.text = "异常断流"
        vc.textViewDidChange(input)
        let send = try XCTUnwrap(subviews(in: vc.view, as: UIButton.self)
            .first(where: { $0.accessibilityIdentifier == "impress.chat.poc.send-stop" }))
        send.sendActions(for: .touchUpInside)
        for _ in 0..<80 where vc.testVisibleStreamPhase != .failed {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertEqual(vc.testVisibleStreamPhase, .failed)
        XCTAssertEqual(send.accessibilityLabel, "重新生成")
    }

    func testSyntheticZeroToFiveThousandHistoryRowsReachRealDiffableSnapshot()
        async throws {
        for messageCount in [0, 100, 1_000, 5_000] {
            let controller = ImpressChatPOCViewController()
            controller.loadViewIfNeeded()
            let before = ProcessInfo.processInfo.systemUptime
            controller.testLoadSyntheticHistory(count: messageCount)
            let expectedRows = messageCount * 2
            // User = 1 block, assistant = heading + paragraph + terminal.
            // Alternating synthetic history therefore emits exactly 2N rows.
            for _ in 0..<250 where controller.testRenderedRowCount < expectedRows {
                try await Task.sleep(nanoseconds: 60_000_000)
            }
            let elapsed = ProcessInfo.processInfo.systemUptime - before
            print("CHAT_POC_HISTORY_BASELINE count=\(messageCount) " +
                  "rows=\(controller.testRenderedRowCount) " +
                  "elapsed_ms=\(Int(elapsed * 1_000))")
            XCTAssertEqual(controller.testModelMessageCount, messageCount)
            XCTAssertEqual(controller.testRenderedRowCount, expectedRows)
            XCTAssertLessThan(elapsed, 20,
                "Simulator-only sampling budget; does not prove device FPS")
        }
    }

    func testDynamicTypeNotificationsDoNotRaceStreamingSnapshot() async throws {
        let controller = ImpressChatPOCViewController()
        controller.loadViewIfNeeded()
        controller.injectOfflineDomainStreamForTest { _ in
            AsyncThrowingStream { output in
                for index in 0..<18 {
                    output.yield(.delta("内容 \(index)\n\n"))
                }
                output.yield(.completed)
                output.finish()
            }
        }
        let input = try XCTUnwrap(subviews(in: controller.view, as: UITextView.self)
            .first(where: { $0.accessibilityIdentifier == "impress.chat.poc.input" }))
        input.text = "验证动画刷新"
        let send = try XCTUnwrap(subviews(in: controller.view, as: UIButton.self)
            .first(where: { $0.accessibilityIdentifier == "impress.chat.poc.send-stop" }))
        send.sendActions(for: .touchUpInside)
        for _ in 0..<12 {
            NotificationCenter.default.post(
                name: UIContentSizeCategory.didChangeNotification, object: nil)
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        for _ in 0..<120 where controller.testVisibleStreamPhase != .completed {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertEqual(controller.testVisibleStreamPhase, .completed)
        XCTAssertGreaterThan(controller.testRenderedRowCount, 2)
    }


    func testNativeMessageContextMenuCopiesWholeTurnAndQuotesWithoutMutation() async throws {
        let controller = ImpressChatPOCViewController()
        controller.loadViewIfNeeded()
        controller.testLoadSyntheticHistory(count: 100)
        for _ in 0..<100 where controller.testRenderedRowCount < 200 {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertEqual(controller.testRenderedRowCount, 200)
        let first = controller.testMessageActionTitles(at: 0)
        XCTAssertEqual(first, ["复制问题", "引用问题并重新发送"])
        let assistant = controller.testMessageActionTitles(at: 1)
        XCTAssertTrue(assistant.contains("复制回复"))
        XCTAssertFalse(assistant.contains("重新生成"))
        XCTAssertEqual(controller.testModelMessageCount, 100)
    }

    private func subviews<T: UIView>(in root: UIView, as type: T.Type) -> [T] {
        root.subviews.flatMap { child in
            ((child as? T).map { [$0] } ?? []) + subviews(in: child, as: type)
        }
    }
}
