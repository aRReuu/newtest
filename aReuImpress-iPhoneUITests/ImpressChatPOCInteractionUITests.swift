import XCTest

/// Actual Debug Simulator input/stream/scroll/stop, using synthetic text only.
final class ImpressChatPOCInteractionUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    func testOfflineChatRendererSendStreamHistoryAndStop() throws {
        let app = XCUIApplication()
        app.launchArguments += ["-ImpressChatPOC", "-ImpressChatPOCControlledStopReplay",
                                "-AppleLanguages", "(zh-Hans)"]
        app.launch()
        let transcript = app.collectionViews["impress.chat.poc.transcript"]
        XCTAssertTrue(transcript.waitForExistence(timeout: 30))
        let input = app.textViews["impress.chat.poc.input"]
        XCTAssertTrue(input.exists)
        input.tap()
        input.typeText("Explain incremental blocks")
        let control = app.buttons["impress.chat.poc.send-stop"]
        control.tap()
        XCTAssertTrue(transcript.cells.firstMatch.waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["impress.chat.poc.send-stop"].waitForExistence(timeout: 10))
        transcript.swipeDown()
        XCTAssertTrue(waitForLabel(control, "停止生成", timeout: 10),
                      "Must verify active streaming before stopping")
        control.tap()
        XCTAssertTrue(waitForLabel(control, "重新生成", timeout: 10))
        XCTAssertEqual(control.label, "重新生成",
                       "A stopped answer must be retained and explicitly retryable")
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "chat-poc-after-stop"
        shot.lifetime = .keepAlways
        add(shot)
        XCTAssertTrue(transcript.exists)
    }    
    func testStopRetainsPartialAndAllowsExplicitRegeneration() throws {
        let app = XCUIApplication()
        app.launchArguments += ["-ImpressChatPOC", "-ImpressChatPOCControlledStopReplay",
                                "-AppleLanguages", "(zh-Hans)"]
        app.launch()
        let transcript = app.collectionViews["impress.chat.poc.transcript"]
        XCTAssertTrue(transcript.waitForExistence(timeout: 25))
        let input = app.textViews["impress.chat.poc.input"]
        XCTAssertTrue(input.waitForExistence(timeout: 25))
        input.tap()
        input.typeText("Retry scenario")
        XCTAssertEqual(input.value as? String, "Retry scenario",
                       "Visible input must be present before the actual send")
        let action = app.buttons["impress.chat.poc.send-stop"]
        action.tap()
        XCTAssertTrue(transcript.cells.firstMatch.waitForExistence(timeout: 10))
        // FollowingBottom continuously animates streamed snapshots; reading
        // history permits XCUI to sample the active stop control before SSE
        // finishes. This is the same real gesture as the already-passing stop UI.
        transcript.swipeDown()
        XCTAssertTrue(waitForLabel(action, "停止生成", timeout: 10))
        action.tap()
        XCTAssertTrue(waitForLabel(action, "重新生成", timeout: 10))
        action.tap()
        transcript.swipeDown()
        XCTAssertTrue(waitForLabel(action, "停止生成", timeout: 10))
    }

    func testFullOfflineSSEReplayMustReachExplicitCompletion() throws {
        let app = XCUIApplication()
        app.launchArguments += ["-ImpressChatPOC", "-AppleLanguages", "(zh-Hans)"]
        app.launch()
        let input = app.textViews["impress.chat.poc.input"]
        XCTAssertTrue(input.waitForExistence(timeout: 25))
        // On a cold iOS Simulator keyboard service, a successful UIKit tap
        // does not yet prove that this UITextView owns keyboard focus.
        // Require the real responder before synthesizing typed input; repeat
        // the visible tap if keyboard startup temporarily drops first responder.
        focusAndType("Explain", into: input)
        let control = app.buttons["impress.chat.poc.send-stop"]
        control.tap()
        XCTAssertTrue(app.textViews.matching(
            NSPredicate(format: "label CONTAINS %@", "已完成")).firstMatch
            .waitForExistence(timeout: 60),
                      "A successful full stream needs an actual SSE terminal")
        XCTAssertEqual(control.label, "发送")
        XCTAssertTrue(app.collectionViews["impress.chat.poc.transcript"].exists)
    }
    func testSingleOfflineWebComparatorOpensWithSameFixture() throws {
        let app = XCUIApplication()
        app.launchArguments += ["-ImpressChatPOC", "-AppleLanguages", "(zh-Hans)"]
        app.launch()
        let control = app.buttons["Web 对照"]
        XCTAssertTrue(control.waitForExistence(timeout: 25))
        control.tap()
        let web = app.webViews["impress.chat.poc.single-web-control"]
        XCTAssertTrue(web.waitForExistence(timeout: 25),
                      "The comparison must load a real, single offline WKWebView")
        let report = app.staticTexts["impress.chat.poc.web-report"]
        XCTAssertTrue(report.waitForExistence(timeout: 20))
        // WKWebView is present before its local HTML, scripts, and KaTeX
        // resource graph finish loading. Wait for the real ready callback:
        // an initial placeholder is not A/B render evidence.
        let ready = NSPredicate(format: "label CONTAINS %@", "实验对照")
        let readyExpectation = XCTNSPredicateExpectation(predicate: ready, object: report)
        XCTAssertEqual(XCTWaiter.wait(for: [readyExpectation], timeout: 25),
                       .completed, "Offline Markdown A/B must report a loaded renderer")
        XCTAssertTrue(report.label.contains("全页解析"))
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "chat-poc-single-offline-web-ab-control"
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }

    /// UI-only keyboard readiness check: no launch flag, text injection, or
    /// skipped stream/terminal assertions. A genuinely non-focusable input
    /// still fails after bounded user-visible tap attempts.
    private func focusAndType(_ text: String, into input: XCUIElement) {
        let keyboardFocus = NSPredicate(format: "hasKeyboardFocus == true")
        var focused = false
        for _ in 0..<3 {
            input.tap()
            let ready = XCTNSPredicateExpectation(
                predicate: keyboardFocus, object: input)
            if XCTWaiter.wait(for: [ready], timeout: 8) == .completed {
                focused = true
                break
            }
        }
        XCTAssertTrue(focused, "Chat composer must accept real keyboard focus")
        input.typeText(text)
        XCTAssertEqual(input.value as? String, text,
            "Synthesized keyboard input must be present before SSE send")
    }

    private func waitForLabel(_ element: XCUIElement, _ expected: String,
                              timeout: TimeInterval) -> Bool {
        let predicate = NSPredicate(format: "label == %@", expected)
        let expectation = XCTNSPredicateExpectation(predicate: predicate, object: element)
        return XCTWaiter.wait(for: [expectation], timeout: timeout) == .completed
    }

}
