import XCTest

/// Real-process XCUITest, not controller instantiation or a service-level
/// contract. Uses only accessibility events against the running Simulator app.
/// This establishes the UI test target and navigation smoke evidence; it does
/// NOT claim the separate 18-step Vault/Chat/duplex end-to-end matrix passes.
final class ImpressV11NavigationUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testFourPrimaryDestinationsAndColdRestart() throws {
        let app = XCUIApplication()
        app.launchArguments += ["-AppleLanguages", "(zh-Hans)",
                                "-AppleLocale", "zh_CN"]
        app.launch()
        try validateNativeTabNavigation(in: app, capture: true)

        // Exercise an actual termination/relaunch boundary through SpringBoard.
        // This catches stale tab routing and startup failures in the real app.
        app.terminate()
        app.launch()
        try validateNativeTabNavigation(in: app, capture: false)
    }

    /// Open the real installed app through its registered URL scheme. This
    /// tests the external WidgetKit tap route without a test-only navigation hook.
    func testWidgetWeekMonthYearDeepLinksReusePrimaryCalibrationController() throws {
        let app = XCUIApplication()
        app.launchArguments += ["-AppleLanguages", "(zh-Hans)"]
        app.launch()
        XCTAssertTrue(app.tabBars.firstMatch.waitForExistence(timeout: 25))
        let periods: [(String, Int)] = [
            ("week", 0), ("month", 1), ("year", 2)
        ]
        for (key, segmentIndex) in periods {
            let url = try XCTUnwrap(URL(string: "impress://calibration/" + key))
            app.open(url)
            // Use the agreed four-Tab order, not localized title strings.
            let tab = app.tabBars.buttons.element(boundBy: 2)
            XCTAssertTrue(tab.waitForExistence(timeout: 20))
            XCTAssertTrue(tab.isSelected,
                "Widget link must navigate to existing calibration Tab for " + key)
            let selector = app.segmentedControls["impress.calibration.period"]
            XCTAssertTrue(selector.waitForExistence(timeout: 15))
            XCTAssertTrue(selector.buttons.element(boundBy: segmentIndex).isSelected,
                "Widget period identity must survive deep-link routing")
        }
    }

    /// U06/U07: actual visible folder disclosure, collapsed descendants and
    /// document-title projection. This is a real UIKit interaction in the
    /// disposable scoped Vault, not an inspector shortcut or service-only test.
    func testNativeVaultOutlineFoldAndDocumentTitleWithoutPathBanner() throws {
        let app = XCUIApplication()
        app.launchArguments += ["-ImpressV11SyntheticVault",
                                "-AppleLanguages", "(zh-Hans)"]
        app.launchEnvironment["IMPRESS_V11_FIXTURE_ID"] = UUID().uuidString
        app.launch()
        XCTAssertTrue(app.tabBars.firstMatch.waitForExistence(timeout: 30))
        app.tabBars.buttons.element(boundBy: 1).tap()
        let folder = app.cells.matching(identifier: "impress.notes.folder-row")
            .matching(NSPredicate(format: "label == %@", "Study")).firstMatch
        let graph = app.cells.matching(identifier: "impress.notes.file-row")
            .matching(NSPredicate(format: "label == %@", "Graph")).firstMatch
        XCTAssertTrue(folder.waitForExistence(timeout: 25))
        XCTAssertEqual(folder.value as? String, "已折叠")
        XCTAssertFalse(graph.exists, "The initial folder must not leak descendants")

        folder.tap()
        XCTAssertTrue(graph.waitForExistence(timeout: 15))
        XCTAssertEqual(folder.value as? String, "已展开")
        let expanded = XCTAttachment(screenshot: app.screenshot())
        expanded.name = "Impress-V1.1-native-outline-expanded"
        expanded.lifetime = .keepAlways
        add(expanded)

        folder.tap()
        let hidden = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == false"), object: graph)
        XCTAssertEqual(XCTWaiter.wait(for: [hidden], timeout: 10), .completed,
            "UITableView collapse must actually remove hidden child rows")
        XCTAssertEqual(folder.value as? String, "已折叠")
        folder.tap()
        XCTAssertTrue(graph.waitForExistence(timeout: 15))
        graph.tap()
        let reader = app.webViews["impress.notes.markdown-webview"]
        XCTAssertTrue(reader.waitForExistence(timeout: 30))
        XCTAssertEqual(reader.label, "Graph",
            "The single scroll reader must expose the verified document name")
        XCTAssertFalse(app.staticTexts["impress.notes.source-path"].exists)
        XCTAssertFalse(app.staticTexts["impress.notes.document-title"].exists,
            "The old detached UIKit title must not occupy the first viewport")
        let readable = XCTAttachment(screenshot: app.screenshot())
        readable.name = "Impress-V1.1-document-heading-no-path-banner"
        readable.lifetime = .keepAlways
        add(readable)
    }

    /// RDR-01/RDR-03/RDR-05: real application process, synthetic Vault only.
    /// These checks do not claim private Obsidian screenshot parity or device QA.
    func testNativeTypedPropertiesAndInlineReaderDiagrams() throws {
        let app = openSyntheticFile("Reader-Properties")
        let readable = app.webViews["impress.notes.markdown-webview"]
        XCTAssertTrue(readable.waitForExistence(timeout: 20))
        XCTAssertEqual(readable.label, "Reader-Properties",
            "Title, typed frontmatter and body should share one web scroll")
        XCTAssertFalse(app.staticTexts["impress.notes.document-title"].exists)
        let ready = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "value == %@", "ready:g=0/0:m=0"),
            object: readable)
        XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 30), .completed)
        let toggle = app.descendants(matching: .any).matching(
            NSPredicate(format: "label CONTAINS %@", "属性 (")).firstMatch
        XCTAssertTrue(toggle.waitForExistence(timeout: 15),
            "The semantic Properties expander must be in the document DOM")
        let date = app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS %@", "2026-01-31")).firstMatch
        XCTAssertTrue(date.waitForExistence(timeout: 15))
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "Impress-reader-single-scroll-typed-properties"
        screenshot.lifetime = .keepAlways
        add(screenshot)
        toggle.tap()
        XCTAssertFalse(date.isHittable,
            "Collapsing native-parsed Properties must hide its document rows")
        app.buttons["更多笔记操作"].tap()
        app.buttons["查看 Markdown 源码"].tap()
        XCTAssertTrue(app.textViews.firstMatch.waitForExistence(timeout: 10))
    }

    /// RDR-01: KaTeX must render inside the same offline note reading surface.
    func testMathMarkdownUsesBundledOfflineReader() throws {
        let app = openSyntheticFile("Reader-Math")
        let reader = app.webViews["impress.notes.markdown-webview"]
        XCTAssertTrue(reader.waitForExistence(timeout: 25))
        let ready = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "value == %@", "ready:g=0/0:m=2"), object: reader)
        XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 35), .completed)
        let image = XCTAttachment(screenshot: app.screenshot())
        image.name = "Impress-reader-inline-KaTeX"
        image.lifetime = .keepAlways
        add(image)
    }

    /// RDR-05: a genuine Markmap code fence renders without the extra menu.
    func testInlineMarkmapFenceRendersInReadingPosition() throws {
        let app = openSyntheticFile("Reader-Markmap")
        let web = app.webViews["impress.notes.markdown-webview"]
        XCTAssertTrue(web.waitForExistence(timeout: 25))
        let expectation = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "value == %@", "ready:g=1/1:m=0"), object: web)
        XCTAssertEqual(XCTWaiter.wait(for: [expectation], timeout: 35), .completed)
        let snapshot = XCTAttachment(screenshot: app.screenshot())
        snapshot.name = "Impress-reader-inline-Markmap"
        snapshot.lifetime = .keepAlways
        add(snapshot)
    }

    /// RDR-06: a bounded Markdown embed keeps the source hierarchy visible
    /// without recursively importing the entire Vault into the reading host.
    func testInlineMarkdownSectionEmbedOpensInsideReader() throws {
        let app = openSyntheticFile("Reader-Embedded")
        let web = app.webViews["impress.notes.markdown-webview"]
        XCTAssertTrue(web.waitForExistence(timeout: 25))
        let ready = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "value == %@", "ready:g=0/0:m=0"),
            object: web)
        XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 35), .completed)
        let snapshot = XCTAttachment(screenshot: app.screenshot())
        snapshot.name = "Impress-reader-inline-Markdown-source-section"
        snapshot.lifetime = .keepAlways
        add(snapshot)
    }

    /// RDR-06: two bounded local composites render inside Markdown without
    /// opening their independent native readers or remote asset requests.
    func testInlineCanvasAndExcalidrawUseAuthorizedSyntheticVault() throws {
        let app = openSyntheticFile("Reader-Composite")
        let reader = app.webViews["impress.notes.markdown-webview"]
        XCTAssertTrue(reader.waitForExistence(timeout: 25))
        let ready = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "value == %@", "ready:g=2/2:m=0"), object: reader)
        XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 35), .completed,
            "Both embedded geometric documents must render within the offline reader")
        let snapshot = XCTAttachment(screenshot: app.screenshot())
        snapshot.name = "Impress-reader-inline-Canvas-Excalidraw"
        snapshot.lifetime = .keepAlways
        add(snapshot)
    }

    func testMarkdownMermaidRendersInlineWithoutEnteringSeparateReader() throws {
        let app = openSyntheticFile("Graph")
        let rendered = app.webViews["impress.notes.markdown-webview"]
        XCTAssertTrue(rendered.waitForExistence(timeout: 25))
        let ready = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "value == %@", "ready:g=1/1:m=0"), object: rendered)
        XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 35), .completed,
                       "The inline Markdown Mermaid must render from bundled JS")
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "Impress-reader-inline-Mermaid"
        screenshot.lifetime = .keepAlways
        add(screenshot)
        app.buttons["更多笔记操作"].tap()
        XCTAssertTrue(app.buttons["阅读 Mermaid 图形"].waitForExistence(timeout: 10),
            "The existing independently selectable source-scoped diagram must survive")
    }

    /// Real UIKit navigation from a disposable Vault into an offline diagram,
    /// a user-selected node, full source preview and the normal Chat screen.
    /// No fake completion button, repository shortcut or network model call.
    func testTemporaryVaultDiagramToChatWithColdLaunch() throws {
        let app = XCUIApplication()
        app.launchArguments += ["-ImpressV11SyntheticVault",
                                "-AppleLanguages", "(zh-Hans)"]
        app.launchEnvironment["IMPRESS_V11_FIXTURE_ID"] = UUID().uuidString
        app.launch()
        XCTAssertTrue(app.tabBars.firstMatch.waitForExistence(timeout: 30))
        app.tabBars.buttons.element(boundBy: 1).tap()
        let folder = app.cells.matching(identifier: "impress.notes.folder-row")
            .matching(NSPredicate(format: "label == %@", "Study")).firstMatch
        XCTAssertTrue(folder.waitForExistence(timeout: 30))
        folder.tap()
        let note = app.cells.matching(identifier: "impress.notes.file-row")
            .matching(NSPredicate(format: "label == %@", "Graph")).firstMatch
        XCTAssertTrue(note.waitForExistence(timeout: 20))
        note.tap()
        XCTAssertTrue(app.webViews["impress.notes.markdown-webview"]
            .waitForExistence(timeout: 15))
        app.buttons["更多笔记操作"].tap()
        let action = app.buttons["阅读 Mermaid 图形"]
        XCTAssertTrue(action.waitForExistence(timeout: 10))
        action.tap()
        XCTAssertTrue(app.webViews["impress.diagram.offline-graph"]
            .waitForExistence(timeout: 20))
        let renderState = app.staticTexts["impress.diagram.render-state"]
        XCTAssertTrue(renderState.waitForExistence(timeout: 20))
        let rendered = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "value == %@", "ready"),
            object: renderState)
        XCTAssertEqual(XCTWaiter.wait(for: [rendered], timeout: 30), .completed,
            "An actual offline Mermaid SVG must render, not merely a WKWebView shell")
        let options = app.tables["impress.diagram.source-selection"]
        XCTAssertTrue(options.waitForExistence(timeout: 15))
        XCTAssertGreaterThan(options.cells.count, 0)
        options.cells.element(boundBy: 0).tap()
        let preview = app.buttons["impress.diagram.preview-material"]
        XCTAssertTrue(preview.waitForExistence(timeout: 10))
        XCTAssertTrue(preview.isEnabled)
        preview.tap()
        XCTAssertTrue(app.textViews["impress.diagram.material-preview"]
            .waitForExistence(timeout: 15))
        app.buttons["impress.diagram.confirm-material"].tap()
        let input = app.textViews["impress.ai.chat.input"]
        XCTAssertTrue(input.waitForExistence(timeout: 20))
        let introduction = app.alerts["关于讨论"]
        if introduction.waitForExistence(timeout: 3) {
            introduction.buttons["知道了"].tap()
        }
        input.tap()
        input.typeText("Please explain the approved Mermaid branch.")
        let send = app.buttons["impress.ai.chat.send"]
        XCTAssertTrue(send.isEnabled)
        send.tap()
        let scope = app.alerts["是否附带当前笔记材料？"]
        if scope.waitForExistence(timeout: 10) {
            scope.buttons["附带本次笔记材料"].tap()
        }
        let assistant = app.textViews.matching(
            identifier: "impress.ai.chat.message-body").matching(
                NSPredicate(format: "value CONTAINS %@", "合成模型回复")).firstMatch
        XCTAssertTrue(assistant.waitForExistence(timeout: 30),
            "The isolated synthetic provider must persist a real completed Chat message")
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "Impress-V1.1-Scoped-Diagram-Chat"
        screenshot.lifetime = .keepAlways
        add(screenshot)
        app.terminate()
        app.launch()
        XCTAssertTrue(app.tabBars.firstMatch.waitForExistence(timeout: 30))
        app.tabBars.buttons.element(boundBy: 1).tap()
        XCTAssertTrue(folder.waitForExistence(timeout: 20))
    }

    func testMarkmapOfflineListBranchAndChatUsesOnlyApprovedSubtree() throws {
        let app = openSyntheticFile("Graph")
        app.buttons["更多笔记操作"].tap()
        let markmap = app.buttons["阅读 Markmap 思维导图"]
        XCTAssertTrue(markmap.waitForExistence(timeout: 12))
        markmap.tap()
        assertOfflineDiagramReady(app)
        let table = app.tables["impress.diagram.source-selection"]
        XCTAssertTrue(table.waitForExistence(timeout: 12))
        let search = app.searchFields["impress.diagram.node-search"]
        XCTAssertTrue(search.waitForExistence(timeout: 12))
        search.tap()
        search.typeText("经过审核的子节点\n")
        let branch = table.cells.matching(
            NSPredicate(format: "label CONTAINS %@", "经过审核的子节点")).firstMatch
        XCTAssertTrue(branch.waitForExistence(timeout: 12),
            "A real matching Markmap node must be selectable in the source tree")
        XCTAssertTrue(branch.isHittable)
        branch.tap()
        app.buttons["impress.diagram.preview-material"].tap()
        let material = app.textViews["impress.diagram.material-preview"]
        XCTAssertTrue(material.waitForExistence(timeout: 12))
        let scope = String(describing: material.value ?? "")
        XCTAssertTrue(scope.contains("经过审核的子节点"))
        XCTAssertFalse(scope.contains("未获批准的兄弟分支"),
            "Markmap selection must never include an unapproved sibling")
        app.buttons["impress.diagram.confirm-material"].tap()
        sendSyntheticChatAndVerifyReply(app, message: "Explain the selected subtree only.")
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "Markmap-offline-approved-subtree-to-Chat"
        shot.lifetime = .keepAlways
        add(shot)
    }

    func testNativeJSONCanvasOnlySelectedNodeMovesIntoChat() throws {
        let app = openSyntheticFile("Diagram")
        // The source label must hug its two lines rather than consuming the
        // entire reader viewport and hiding native canvas controls.
        let sourcePath = app.staticTexts["impress.notes.document-title"]
        XCTAssertLessThan(sourcePath.frame.height, 120, "Canvas viewport layout is collapsed")
        // Require an actual rendered, interactable node rather than the
        // accessibility *type* of a UIScrollView (UIKit may flatten it).
        let node = app.buttons["impress.canvas.node.a"]
        XCTAssertTrue(node.waitForExistence(timeout: 18),
            "Canvas node missing in native tree: " + app.debugDescription)
        XCTAssertTrue(node.isHittable)
        node.tap()
        XCTAssertEqual(node.value as? String, "已选择")
        app.buttons["更多笔记操作"].tap()
        app.buttons["所选画布节点预览并加入 Chat"].tap()
        let material = app.textViews["impress.canvas.material-preview"]
        XCTAssertTrue(material.waitForExistence(timeout: 12))
        XCTAssertTrue(String(describing: material.value ?? "").contains("a"))
        app.buttons["impress.canvas.confirm-material"].tap()
        sendSyntheticChatAndVerifyReply(app, message: "Analyze the approved Canvas node.")
    }

    func testPlainMarkdownPluginEnvelopeRendersActualExcalidraw() throws {
        let app = openSyntheticFile("Legacy-Drawing")
        let element = app.buttons["impress.excalidraw.element.a"]
        XCTAssertTrue(element.waitForExistence(timeout: 25),
            "The ordinary .md plugin file must render a real native shape")
        XCTAssertFalse(app.webViews["impress.notes.markdown-webview"].exists)
        app.buttons["更多笔记操作"].tap()
        XCTAssertTrue(app.buttons["所选绘图元素预览并加入 Chat"].exists)
        XCTAssertFalse(app.buttons["编辑独立草稿"].exists)
    }

    func testExcalidrawNativeReadSelectionAndChatRejectsUnselectedElement() throws {
        let app = openSyntheticFile("Drawing")
        let sourcePath = app.staticTexts["impress.notes.document-title"]
        XCTAssertLessThan(sourcePath.frame.height, 120, "Excalidraw viewport layout is collapsed")
        let rectangle = app.buttons["impress.excalidraw.element.a"]
        XCTAssertTrue(rectangle.waitForExistence(timeout: 18),
            "Excalidraw shape missing in native tree: " + app.debugDescription)
        XCTAssertTrue(rectangle.isHittable)
        rectangle.tap()
        XCTAssertEqual(rectangle.value as? String, "已选择")
        app.buttons["更多笔记操作"].tap()
        app.buttons["所选绘图元素预览并加入 Chat"].tap()
        let material = app.textViews["impress.excalidraw.material-preview"]
        XCTAssertTrue(material.waitForExistence(timeout: 12))
        XCTAssertFalse(String(describing: material.value ?? "").contains("Unapproved"))
        app.buttons["impress.excalidraw.confirm-material"].tap()
        sendSyntheticChatAndVerifyReply(app, message: "Analyze only the approved rectangle.")
    }

    private func openSyntheticFile(_ title: String) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += ["-ImpressV11SyntheticVault",
                                "-AppleLanguages", "(zh-Hans)"]
        app.launchEnvironment["IMPRESS_V11_FIXTURE_ID"] = UUID().uuidString
        app.launch()
        XCTAssertTrue(app.tabBars.firstMatch.waitForExistence(timeout: 30))
        app.tabBars.buttons.element(boundBy: 1).tap()
        let folder = app.cells.matching(identifier: "impress.notes.folder-row")
            .matching(NSPredicate(format: "label == %@", "Study")).firstMatch
        XCTAssertTrue(folder.waitForExistence(timeout: 30))
        folder.tap()
        let file = app.cells.matching(identifier: "impress.notes.file-row")
            .matching(NSPredicate(format: "label == %@", title)).firstMatch
        XCTAssertTrue(file.waitForExistence(timeout: 25))
        file.tap()
        let nativeHeading = app.staticTexts["impress.notes.document-title"]
        if !nativeHeading.exists {
            XCTAssertTrue(app.webViews["impress.notes.markdown-webview"]
                .waitForExistence(timeout: 20))
        }
        return app
    }

    private func assertOfflineDiagramReady(_ app: XCUIApplication) {
        XCTAssertTrue(app.webViews["impress.diagram.offline-graph"]
            .waitForExistence(timeout: 20))
        let state = app.staticTexts["impress.diagram.render-state"]
        XCTAssertTrue(state.waitForExistence(timeout: 15))
        let didRender = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "value == %@", "ready"), object: state)
        XCTAssertEqual(XCTWaiter.wait(for: [didRender], timeout: 30), .completed)
    }

    private func sendSyntheticChatAndVerifyReply(_ app: XCUIApplication,
                                                 message: String) {
        // The real production route must use the block-based renderer, not
        // the standalone Debug POC or the retired UITableView transcript.
        let transcript = app.collectionViews["impress.ai.chat.transcript"]
        XCTAssertTrue(transcript.waitForExistence(timeout: 25),
                      "Production Chat must mount its native diffable transcript")
        XCTAssertFalse(app.tables["impress.ai.chat.transcript"].exists)
        let input = app.textViews["impress.ai.chat.input"]
        XCTAssertTrue(input.waitForExistence(timeout: 25))
        let guide = app.alerts["关于讨论"]
        if guide.waitForExistence(timeout: 2) { guide.buttons["知道了"].tap() }
        input.tap()
        input.typeText(message)
        let send = app.buttons["impress.ai.chat.send"]
        XCTAssertTrue(send.isEnabled)
        send.tap()
        let permission = app.alerts["是否附带当前笔记材料？"]
        if permission.waitForExistence(timeout: 10) {
            permission.buttons["附带本次笔记材料"].tap()
        }
        let assistant = app.textViews.matching(
            identifier: "impress.ai.chat.message-body").matching(
                NSPredicate(format: "value CONTAINS %@", "合成模型回复")).firstMatch
        XCTAssertTrue(assistant.waitForExistence(timeout: 35))
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "Composite-Selected-Material-Chat-RoundTrip"
        shot.lifetime = .keepAlways
        add(shot)
    }

    /// CARD-VIDEO-01: the genuine installed app must not reveal its cover
    /// before the answer, and AVPlayer playback must return to the same card
    /// without completing or grading the review. Only a disposable synthetic
    /// video/UUID Vault is used; no Photos, iCloud, live Vault or Provider.
    func testCardVideoNativePlaybackReturnsToSameRevealedReview() throws {
        let app = XCUIApplication()
        app.launchArguments = [
            "-ImpressV11SyntheticVault",
            "-ImpressV11VideoPlaybackFixture",
            "-AppleLanguages", "(zh-Hans)"
        ]
        app.launchEnvironment["IMPRESS_V11_FIXTURE_ID"] = UUID().uuidString
        app.launch()
        XCTAssertTrue(app.tabBars.firstMatch.waitForExistence(timeout: 35))
        let reveal = app.buttons["impress.review.reveal-answer"]
        XCTAssertTrue(reveal.waitForExistence(timeout: 90),
            "The actual AVFoundation/export/WCDB fixture must load")
        let cover = app.descendants(matching: .any).matching(
            identifier: "impress.review.video.play").firstMatch
        XCTAssertFalse(cover.exists,
            "Video cover and playback must not be discoverable before reveal")
        reveal.tap()
        XCTAssertTrue(cover.waitForExistence(timeout: 20),
            "Only the revealed answer can expose the playable video cover")
        // The pre-reveal "第 1 / 1 张" counter is intentionally replaced
        // after reveal by the swipe-rating instruction. Assert the live
        // revealed state instead of looking for a label that no longer exists.
        let revealedStatus = app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS %@", "向四个方向滑动卡片评分")).firstMatch
        XCTAssertTrue(revealedStatus.waitForExistence(timeout: 12),
            "The real answer-revealed state must expose the swipe-rating instruction")
        cover.tap()

        // AVPlayerViewController provides the system Done control; no test
        // shortcut dismisses it or directly changes the review coordinator.
        let done = app.buttons.matching(NSPredicate(
            format: "label IN %@", ["Done", "完成", "关闭", "Close"])).firstMatch
        if !done.waitForExistence(timeout: 12) {
            app.coordinate(withNormalizedOffset:
                CGVector(dx: 0.5, dy: 0.5)).tap()
        }
        XCTAssertTrue(done.waitForExistence(timeout: 15),
            "The real fullscreen AVPlayer must offer its system close control")
        done.tap()
        XCTAssertTrue(cover.waitForExistence(timeout: 20),
            "Dismissing AVPlayer must return to the same revealed cover")
        XCTAssertTrue(revealedStatus.waitForExistence(timeout: 12),
            "Playback dismissal must preserve the revealed state and grading affordance")
        XCTAssertFalse(reveal.exists,
            "The revealed card may not be reset or implicitly graded by playback")
        XCTAssertFalse(app.staticTexts["本轮复习完成：1 张"].exists)
    }

    /// Candidate review and WCDB card creation happen through genuine UI
    /// controls, with an explicit fixed synthetic provider for this fixture.
    func testSyntheticQuestionPoolReviewAndNativeFlashcard() throws {
        let app = XCUIApplication()
        app.launchArguments += ["-ImpressV11SyntheticVault",
                                "-AppleLanguages", "(zh-Hans)"]
        app.launchEnvironment["IMPRESS_V11_FIXTURE_ID"] = UUID().uuidString
        app.launch()
        XCTAssertTrue(app.tabBars.firstMatch.waitForExistence(timeout: 30))
        app.tabBars.buttons.element(boundBy: 1).tap()
        let folder = app.cells.matching(identifier: "impress.notes.folder-row")
            .matching(NSPredicate(format: "label == %@", "Study")).firstMatch
        XCTAssertTrue(folder.waitForExistence(timeout: 30))
        folder.tap()
        let note = app.cells.matching(identifier: "impress.notes.file-row")
            .matching(NSPredicate(format: "label == %@", "Impress_E2E_Proof")).firstMatch
        XCTAssertTrue(note.waitForExistence(timeout: 15))
        note.tap()
        app.buttons["更多笔记操作"].tap()
        app.buttons["根据笔记生成卡片"].tap()
        XCTAssertTrue(app.navigationBars["生成综合问题"].waitForExistence(timeout: 15))
        app.navigationBars.buttons["生成"].tap()
        let consent = app.alerts["模拟器合成出题"]
        XCTAssertTrue(consent.waitForExistence(timeout: 10))
        consent.buttons["生成"].tap()
        XCTAssertTrue(app.navigationBars["问题候选池"].waitForExistence(timeout: 20))
        let candidates = app.tables.cells
        XCTAssertGreaterThanOrEqual(candidates.count, 2)
        candidates.element(boundBy: 1).tap()  // exclude the unwanted candidate
        let importButton = app.navigationBars.buttons.matching(
            NSPredicate(format: "label BEGINSWITH %@", "加入")).firstMatch
        XCTAssertTrue(importButton.isEnabled)
        importButton.tap()
        let approval = app.alerts["加入卡片集？"]
        XCTAssertTrue(approval.waitForExistence(timeout: 10))
        XCTAssertFalse(importButton.isEnabled,
            "Pending card-import consent must disable duplicate taps")
        approval.buttons["取消"].tap()
        XCTAssertTrue(importButton.isEnabled,
            "Cancelled consent must restore import without inserting cards")
        importButton.tap()
        XCTAssertTrue(approval.waitForExistence(timeout: 10))
        XCTAssertFalse(importButton.isEnabled)
        approval.buttons["确认加入"].tap()
        let done = app.alerts["卡片已添加"]
        XCTAssertTrue(done.waitForExistence(timeout: 20))
        done.buttons["完成"].tap()
        app.tabBars.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(app.tabBars.firstMatch.waitForExistence(timeout: 10))
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "Impress-V1.1-Real-Reviewed-Card"
        screenshot.lifetime = .keepAlways
        add(screenshot)
        app.terminate()
        app.launch()
        XCTAssertTrue(app.tabBars.firstMatch.waitForExistence(timeout: 30))
    }

    /// One *continuous* visible UI path using one fixed disposable Vault and
    /// the actual WCDB, Chat, draft, approval and guarded Debug QA writer.
    /// The synthetic model only returns a fixed message after normal consent
    /// and source revision checks. No business operation is auto-completed by
    /// a test-only button or by a direct Swift repository call.
    /// F03 process-layer proof. The only crash injection is DEBUG +
    /// synthetic fixture + independently authorized QA write folder. The
    /// note is actually committed, but the post-write receipt is not saved.
    /// Restart/reconciliation must not execute the writer a second time.
    func testF03ProcessDeathAfterQAWriteReconcilesViaVisibleUI() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-ImpressV11SyntheticVault",
            "-ImpressV11FaultF03AfterNoteCommit", "-AppleLanguages", "(zh-Hans)"]
        app.launchEnvironment["IMPRESS_V11_FIXTURE_ID"] = UUID().uuidString
        app.launch()
        let tabs = app.tabBars.firstMatch
        XCTAssertTrue(tabs.waitForExistence(timeout: 30))
        tabs.buttons.element(boundBy: 1).tap()
        let folder = app.cells.matching(identifier: "impress.notes.folder-row")
            .matching(NSPredicate(format: "label == %@", "Study")).firstMatch
        XCTAssertTrue(folder.waitForExistence(timeout: 30))
        folder.tap()
        let note = app.cells.matching(identifier: "impress.notes.file-row")
            .matching(NSPredicate(format: "label == %@", "Impress_E2E_Proof")).firstMatch
        XCTAssertTrue(note.waitForExistence(timeout: 20))
        note.tap()
        XCTAssertTrue(app.webViews["impress.notes.markdown-webview"]
            .waitForExistence(timeout: 40))
        app.buttons["更多笔记操作"].tap()
        app.buttons["根据笔记生成卡片"].tap()
        XCTAssertTrue(app.navigationBars["生成综合问题"]
            .waitForExistence(timeout: 15))
        app.navigationBars.buttons["生成"].tap()
        let proposalGeneration = app.alerts["模拟器合成出题"]
        XCTAssertTrue(proposalGeneration.waitForExistence(timeout: 12))
        proposalGeneration.buttons["生成"].tap()
        XCTAssertTrue(app.navigationBars["问题候选池"]
            .waitForExistence(timeout: 20))
        XCTAssertGreaterThanOrEqual(app.tables.cells.count, 2)
        app.tables.cells.element(boundBy: 1).tap()
        let add = app.navigationBars.buttons.matching(
            NSPredicate(format: "label BEGINSWITH %@", "加入")).firstMatch
        XCTAssertTrue(add.waitForExistence(timeout: 12))
        add.tap()
        let approveCard = app.alerts["加入卡片集？"]
        XCTAssertTrue(approveCard.waitForExistence(timeout: 12))
        approveCard.buttons["确认加入"].tap()
        let saved = app.alerts["卡片已添加"]
        XCTAssertTrue(saved.waitForExistence(timeout: 30))
        saved.buttons["完成"].tap()

        tabs.buttons.element(boundBy: 0).tap()
        let reveal = app.buttons["impress.review.reveal-answer"]
        XCTAssertTrue(reveal.waitForExistence(timeout: 25))
        reveal.tap()
        let discussion = app.buttons["impress.review.ai-discussion"]
        XCTAssertTrue(discussion.waitForExistence(timeout: 15))
        discussion.tap()
        let intro = app.alerts["关于讨论"]
        if intro.waitForExistence(timeout: 2) { intro.buttons["知道了"].tap() }
        let input = app.textViews["impress.ai.chat.input"]
        XCTAssertTrue(input.waitForExistence(timeout: 20))
        input.tap()
        input.typeText("合成 F03 写入后丢失回执验证")
        app.buttons["impress.ai.chat.send"].tap()
        let context = app.alerts["是否附带当前卡片？"]
        if context.waitForExistence(timeout: 8) {
            context.buttons["附带当前卡片"].tap()
        }
        let more = app.buttons["impress.ai.chat.reply-more"].firstMatch
        XCTAssertTrue(more.waitForExistence(timeout: 30))
        more.tap()
        let createDiff = app.buttons["统一预览笔记与原卡修订"]
        XCTAssertTrue(createDiff.waitForExistence(timeout: 12))
        createDiff.tap()
        let noteEdit = app.buttons["impress.duplex.edit-note"]
        XCTAssertTrue(noteEdit.waitForExistence(timeout: 20))
        tapVisible(noteEdit, in: app)
        let sectionAction = app.buttons["指定原章节并编辑 AI 建议"]
        XCTAssertTrue(sectionAction.waitForExistence(timeout: 15))
        sectionAction.tap()
        let chapters = app.tables["impress.duplex.note-section-picker"]
        XCTAssertTrue(chapters.waitForExistence(timeout: 15))
        XCTAssertGreaterThanOrEqual(chapters.cells.count, 2)
        chapters.cells.element(boundBy: 1).tap()
        let editor = app.textViews["impress.duplex.section-replacement"]
        XCTAssertTrue(editor.waitForExistence(timeout: 15))
        editor.tap()
        editor.typeText("\n## F03_UIDurableProof\n测试保存后进程中断，不允许自动重复写入。")
        app.buttons["impress.duplex.save-section-draft"].tap()
        let preview = app.buttons["impress.duplex.preview"]
        tapVisible(preview, in: app)
        let diff = app.textViews["impress.duplex.full-diff"]
        XCTAssertTrue(diff.waitForExistence(timeout: 20))
        let approval = app.buttons["impress.duplex.confirm"]
        XCTAssertTrue(approval.isEnabled)
        approval.tap()
        let finalConsent = app.alerts["确认这两个目标的所选修改？"]
        XCTAssertTrue(finalConsent.waitForExistence(timeout: 15))
        finalConsent.buttons["确认执行"].tap()
        let stopped = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            app.state == .notRunning
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [stopped], timeout: 35), .completed,
            "The real fixture process must terminate after coordinated note write")

        // Disable the one-time fault only for this same synthetic fixture.
        app.launchArguments.removeAll {
            $0 == "-ImpressV11FaultF03AfterNoteCommit"
        }
        app.launch()
        XCTAssertTrue(tabs.waitForExistence(timeout: 30))
        tabs.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(reveal.waitForExistence(timeout: 30))
        reveal.tap()
        XCTAssertTrue(discussion.waitForExistence(timeout: 15))
        discussion.tap()
        XCTAssertTrue(more.waitForExistence(timeout: 25),
            "The completed AI reply and its exact proposal must survive cold restart")
        more.tap()
        XCTAssertTrue(createDiff.waitForExistence(timeout: 15))
        createDiff.tap()
        XCTAssertTrue(preview.waitForExistence(timeout: 20))
        tapVisible(preview, in: app)
        let recovered = app.textViews["impress.duplex.full-diff"]
        XCTAssertTrue(recovered.waitForExistence(timeout: 20))
        XCTAssertTrue(String(describing: recovered.value ?? "").contains("applying"),
            "No receipt was durably written during the injected F03 window")
        let reconcile = app.buttons["impress.duplex.reconcile-interrupted"]
        XCTAssertTrue(reconcile.waitForExistence(timeout: 20))
        XCTAssertTrue(reconcile.isEnabled)
        XCTAssertFalse(app.buttons["impress.duplex.confirm"].isEnabled,
            "An interrupted source modification must not be applied twice")
        reconcile.tap()
        let adjudicated = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in
                let value = String(describing: recovered.value ?? "")
                return value.contains("中断核查") && value.contains("applied")
            }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [adjudicated], timeout: 30), .completed,
            "Only readback of exact approved SHA can resolve a missing receipt")
        let evidence = XCTAttachment(screenshot: app.screenshot())
        evidence.name = "Impress-V1.1-F03-real-process-death-and-readonly-reconciliation"
        evidence.lifetime = .keepAlways
        self.add(evidence)
        // Only the already-written note is immutable. The original card has
        // not been written in this F03 window, so it may legitimately remain
        // separately approvable after a fresh review/confirmation. Do not
        // weaken the production partial-success behavior to satisfy this test.
        let savedNoteTarget = app.switches["impress.duplex.select-note"]
        XCTAssertTrue(savedNoteTarget.exists)
        XCTAssertFalse(savedNoteTarget.isEnabled,
            "Readback must permanently disable reapplication of the same QA note")
        let cardTarget = app.switches["impress.duplex.select-card"]
        if app.buttons["impress.duplex.confirm"].isEnabled {
            XCTAssertTrue(cardTarget.exists && cardTarget.isEnabled,
                "Only a separately reviewed remaining card can be confirmed")
        }
    }

    /// F04 uses a real WCDB card transaction, then a DEBUG synthetic-only
    /// SIGKILL before its Chat receipt is durable. The restarted UI must
    /// reconcile the already-applied content without replaying a second edit.
    func testF04ProcessDeathAfterCardCommitReconcilesWithoutSecondVersion() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-ImpressV11SyntheticVault",
            "-ImpressV11FaultF04AfterCardCommit", "-AppleLanguages", "(zh-Hans)"]
        app.launchEnvironment["IMPRESS_V11_FIXTURE_ID"] = UUID().uuidString
        app.launch()
        let tabs = app.tabBars.firstMatch
        XCTAssertTrue(tabs.waitForExistence(timeout: 30))
        tabs.buttons.element(boundBy: 1).tap()
        let folder = app.cells.matching(identifier: "impress.notes.folder-row")
            .matching(NSPredicate(format: "label == %@", "Study")).firstMatch
        XCTAssertTrue(folder.waitForExistence(timeout: 30))
        folder.tap()
        let note = app.cells.matching(identifier: "impress.notes.file-row")
            .matching(NSPredicate(format: "label == %@", "Impress_E2E_Proof")).firstMatch
        XCTAssertTrue(note.waitForExistence(timeout: 20))
        note.tap()
        XCTAssertTrue(app.webViews["impress.notes.markdown-webview"]
            .waitForExistence(timeout: 40))
        app.buttons["更多笔记操作"].tap()
        app.buttons["根据笔记生成卡片"].tap()
        XCTAssertTrue(app.navigationBars["生成综合问题"].waitForExistence(timeout: 15))
        app.navigationBars.buttons["生成"].tap()
        let synthetic = app.alerts["模拟器合成出题"]
        XCTAssertTrue(synthetic.waitForExistence(timeout: 12))
        synthetic.buttons["生成"].tap()
        XCTAssertTrue(app.navigationBars["问题候选池"].waitForExistence(timeout: 20))
        XCTAssertGreaterThanOrEqual(app.tables.cells.count, 2)
        app.tables.cells.element(boundBy: 1).tap()
        let importButton = app.navigationBars.buttons.matching(
            NSPredicate(format: "label BEGINSWITH %@", "加入")).firstMatch
        XCTAssertTrue(importButton.waitForExistence(timeout: 12))
        importButton.tap()
        let consent = app.alerts["加入卡片集？"]
        XCTAssertTrue(consent.waitForExistence(timeout: 12))
        consent.buttons["确认加入"].tap()
        let saved = app.alerts["卡片已添加"]
        XCTAssertTrue(saved.waitForExistence(timeout: 30))
        saved.buttons["完成"].tap()

        tabs.buttons.element(boundBy: 0).tap()
        let reveal = app.buttons["impress.review.reveal-answer"]
        XCTAssertTrue(reveal.waitForExistence(timeout: 25))
        reveal.tap()
        let discussion = app.buttons["impress.review.ai-discussion"]
        XCTAssertTrue(discussion.waitForExistence(timeout: 15))
        discussion.tap()
        let intro = app.alerts["关于讨论"]
        if intro.waitForExistence(timeout: 2) { intro.buttons["知道了"].tap() }
        let input = app.textViews["impress.ai.chat.input"]
        XCTAssertTrue(input.waitForExistence(timeout: 20))
        input.tap()
        input.typeText("合成 F04 原卡内容已提交但回执中断")
        app.buttons["impress.ai.chat.send"].tap()
        let sourceConsent = app.alerts["是否附带当前卡片？"]
        if sourceConsent.waitForExistence(timeout: 8) {
            sourceConsent.buttons["附带当前卡片"].tap()
        }
        let more = app.buttons["impress.ai.chat.reply-more"].firstMatch
        XCTAssertTrue(more.waitForExistence(timeout: 30))
        more.tap()
        let createDiff = app.buttons["统一预览笔记与原卡修订"]
        XCTAssertTrue(createDiff.waitForExistence(timeout: 12))
        createDiff.tap()
        let adopt = app.buttons["impress.duplex.use-suggestion"]
        XCTAssertTrue(adopt.waitForExistence(timeout: 15))
        tapVisible(adopt, in: app)
        let preview = app.buttons["impress.duplex.preview"]
        tapVisible(preview, in: app)
        let fullDiff = app.textViews["impress.duplex.full-diff"]
        XCTAssertTrue(fullDiff.waitForExistence(timeout: 20))
        XCTAssertTrue(String(describing: fullDiff.value ?? "").contains("cardID:"))
        let noteToggle = app.switches["impress.duplex.select-note"]
        let cardToggle = app.switches["impress.duplex.select-card"]
        XCTAssertTrue(noteToggle.exists && cardToggle.exists)
        XCTAssertFalse(noteToggle.isEnabled,
            "F04 must modify only the original card, not an unreviewed note")
        XCTAssertTrue(cardToggle.isEnabled)
        if String(describing: cardToggle.value ?? "") == "0" { cardToggle.tap() }
        let execute = app.buttons["impress.duplex.confirm"]
        XCTAssertTrue(execute.isEnabled)
        execute.tap()
        let approval = app.alerts["确认这两个目标的所选修改？"]
        XCTAssertTrue(approval.waitForExistence(timeout: 15))
        XCTAssertFalse(execute.isEnabled,
            "F05: presenting final consent must lock duplicate execution taps")
        approval.buttons["取消"].tap()
        XCTAssertTrue(execute.isEnabled,
            "Cancelling F05 consent must restore an independently reviewed target")
        execute.tap()
        XCTAssertTrue(approval.waitForExistence(timeout: 15))
        XCTAssertFalse(execute.isEnabled)
        approval.buttons["确认执行"].tap()
        let killed = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            app.state == .notRunning
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [killed], timeout: 35), .completed,
            "The synthetic app must actually die after committing card content")

        app.launchArguments.removeAll {
            $0 == "-ImpressV11FaultF04AfterCardCommit"
        }
        app.launch()
        XCTAssertTrue(tabs.waitForExistence(timeout: 30))
        tabs.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(reveal.waitForExistence(timeout: 30))
        reveal.tap()
        XCTAssertTrue(discussion.waitForExistence(timeout: 15))
        discussion.tap()
        XCTAssertTrue(more.waitForExistence(timeout: 25))
        more.tap()
        XCTAssertTrue(createDiff.waitForExistence(timeout: 15))
        createDiff.tap()
        XCTAssertTrue(preview.waitForExistence(timeout: 20))
        tapVisible(preview, in: app)
        let recovered = app.textViews["impress.duplex.full-diff"]
        XCTAssertTrue(recovered.waitForExistence(timeout: 20))
        XCTAssertTrue(String(describing: recovered.value ?? "").contains("applying"),
            "Content was written, but the original Chat receipt must still be interrupted")
        XCTAssertFalse(app.buttons["impress.duplex.confirm"].isEnabled,
            "F04 applying state must stop any automatic or user replay")
        let reconcile = app.buttons["impress.duplex.reconcile-interrupted"]
        XCTAssertTrue(reconcile.waitForExistence(timeout: 15))
        reconcile.tap()
        let verified = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            let value = String(describing: recovered.value ?? "")
            return value.contains("中断核查") && value.contains("applied")
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [verified], timeout: 30), .completed,
            "Only actual WCDB content-version readback may confirm F04")
        XCTAssertFalse(app.switches["impress.duplex.select-card"].isEnabled,
            "Previously committed card must stay unselectable after readback")
        let evidence = XCTAttachment(screenshot: app.screenshot())
        evidence.name = "Impress-V1.1-F04-real-WCDB-process-death-readback"
        evidence.lifetime = .keepAlways
        add(evidence)
    }

    /// F06 injects a true DEBUG-only SIGKILL after the card's real WCDB
    /// inverse transaction but before the durable Chat inverse receipt.
    /// Reopened UI must reconcile the original content version without replay.
    func testF06ProcessDeathAfterCardUndoReconcilesWithoutSecondInverse() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-ImpressV11SyntheticVault",
            "-ImpressV11FaultF06AfterCardUndo", "-AppleLanguages", "(zh-Hans)"]
        app.launchEnvironment["IMPRESS_V11_FIXTURE_ID"] = UUID().uuidString
        app.launch()
        let tabs = app.tabBars.firstMatch
        XCTAssertTrue(tabs.waitForExistence(timeout: 30))
        tabs.buttons.element(boundBy: 1).tap()
        let folder = app.cells.matching(identifier: "impress.notes.folder-row")
            .matching(NSPredicate(format: "label == %@", "Study")).firstMatch
        XCTAssertTrue(folder.waitForExistence(timeout: 30))
        folder.tap()
        let note = app.cells.matching(identifier: "impress.notes.file-row")
            .matching(NSPredicate(format: "label == %@", "Impress_E2E_Proof")).firstMatch
        XCTAssertTrue(note.waitForExistence(timeout: 20))
        note.tap()
        XCTAssertTrue(app.webViews["impress.notes.markdown-webview"]
            .waitForExistence(timeout: 40))
        app.buttons["更多笔记操作"].tap()
        app.buttons["根据笔记生成卡片"].tap()
        XCTAssertTrue(app.navigationBars["生成综合问题"].waitForExistence(timeout: 15))
        app.navigationBars.buttons["生成"].tap()
        let generation = app.alerts["模拟器合成出题"]
        XCTAssertTrue(generation.waitForExistence(timeout: 12))
        generation.buttons["生成"].tap()
        XCTAssertTrue(app.navigationBars["问题候选池"].waitForExistence(timeout: 20))
        XCTAssertGreaterThanOrEqual(app.tables.cells.count, 2)
        app.tables.cells.element(boundBy: 1).tap()
        let importCard = app.navigationBars.buttons.matching(
            NSPredicate(format: "label BEGINSWITH %@", "加入")).firstMatch
        XCTAssertTrue(importCard.waitForExistence(timeout: 12))
        importCard.tap()
        let consent = app.alerts["加入卡片集？"]
        XCTAssertTrue(consent.waitForExistence(timeout: 12))
        consent.buttons["确认加入"].tap()
        let saved = app.alerts["卡片已添加"]
        XCTAssertTrue(saved.waitForExistence(timeout: 30))
        saved.buttons["完成"].tap()

        tabs.buttons.element(boundBy: 0).tap()
        let reveal = app.buttons["impress.review.reveal-answer"]
        XCTAssertTrue(reveal.waitForExistence(timeout: 25))
        reveal.tap()
        let discussion = app.buttons["impress.review.ai-discussion"]
        XCTAssertTrue(discussion.waitForExistence(timeout: 15))
        discussion.tap()
        let guide = app.alerts["关于讨论"]
        if guide.waitForExistence(timeout: 2) { guide.buttons["知道了"].tap() }
        let input = app.textViews["impress.ai.chat.input"]
        XCTAssertTrue(input.waitForExistence(timeout: 20))
        input.tap()
        input.typeText("F06 合成逆向修改已提交但回执强杀")
        app.buttons["impress.ai.chat.send"].tap()
        let sourceConsent = app.alerts["是否附带当前卡片？"]
        if sourceConsent.waitForExistence(timeout: 8) {
            sourceConsent.buttons["附带当前卡片"].tap()
        }
        let more = app.buttons["impress.ai.chat.reply-more"].firstMatch
        XCTAssertTrue(more.waitForExistence(timeout: 30))
        more.tap()
        let createDiff = app.buttons["统一预览笔记与原卡修订"]
        XCTAssertTrue(createDiff.waitForExistence(timeout: 12))
        createDiff.tap()
        let adopt = app.buttons["impress.duplex.use-suggestion"]
        XCTAssertTrue(adopt.waitForExistence(timeout: 15))
        tapVisible(adopt, in: app)
        let preview = app.buttons["impress.duplex.preview"]
        tapVisible(preview, in: app)
        let diff = app.textViews["impress.duplex.full-diff"]
        XCTAssertTrue(diff.waitForExistence(timeout: 20))
        let noteToggle = app.switches["impress.duplex.select-note"]
        let cardToggle = app.switches["impress.duplex.select-card"]
        XCTAssertTrue(noteToggle.exists && cardToggle.exists)
        XCTAssertFalse(noteToggle.isEnabled,
            "Only the reviewed card is eligible for this inverse test")
        XCTAssertTrue(cardToggle.isEnabled)
        if String(describing: cardToggle.value ?? "") == "0" { cardToggle.tap() }
        let confirm = app.buttons["impress.duplex.confirm"]
        XCTAssertTrue(confirm.isEnabled)
        confirm.tap()
        let approval = app.alerts["确认这两个目标的所选修改？"]
        XCTAssertTrue(approval.waitForExistence(timeout: 15))
        approval.buttons["确认执行"].tap()
        let approved = app.alerts["所选修改已处理"]
        XCTAssertTrue(approved.waitForExistence(timeout: 30))
        approved.buttons["确定"].tap()

        let undo = app.navigationBars.buttons["安全撤销"]
        XCTAssertTrue(undo.waitForExistence(timeout: 12))
        XCTAssertTrue(undo.isEnabled)
        undo.tap()
        let undoCard = app.buttons["撤销原卡改动"]
        XCTAssertTrue(undoCard.waitForExistence(timeout: 12))
        undoCard.tap()
        let inversePreview = app.textViews["impress.duplex.undo.full-diff"]
        XCTAssertTrue(inversePreview.waitForExistence(timeout: 20))
        XCTAssertTrue(String(describing: inversePreview.value ?? "").contains("cardID:"))
        let inverse = app.buttons["impress.duplex.undo.confirm"]
        XCTAssertTrue(inverse.isEnabled)
        inverse.tap()
        let inverseConsent = app.alerts["确认撤销这个目标？"]
        XCTAssertTrue(inverseConsent.waitForExistence(timeout: 12))
        XCTAssertFalse(inverse.isEnabled,
            "F05 inverse consent must immediately lock the repeated undo tap")
        inverseConsent.buttons["确认撤销"].tap()
        let killed = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            app.state == .notRunning
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [killed], timeout: 35), .completed,
            "The process must die only after the actual inverse content commit")

        app.launchArguments.removeAll { $0 == "-ImpressV11FaultF06AfterCardUndo" }
        app.launch()
        XCTAssertTrue(tabs.waitForExistence(timeout: 30))
        tabs.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(reveal.waitForExistence(timeout: 30))
        reveal.tap()
        XCTAssertTrue(discussion.waitForExistence(timeout: 15))
        discussion.tap()
        XCTAssertTrue(more.waitForExistence(timeout: 25))
        more.tap()
        XCTAssertTrue(createDiff.waitForExistence(timeout: 15))
        createDiff.tap()
        XCTAssertTrue(preview.waitForExistence(timeout: 20))
        tapVisible(preview, in: app)
        let recoveryDiff = app.textViews["impress.duplex.full-diff"]
        XCTAssertTrue(recoveryDiff.waitForExistence(timeout: 20))
        XCTAssertTrue(String(describing: recoveryDiff.value ?? "").contains("undoing"),
            "Committed inverse must retain the original interrupted receipt")
        XCTAssertFalse(app.buttons["impress.duplex.confirm"].isEnabled,
            "Interrupted inverse must not permit a new forward write")
        XCTAssertFalse(app.navigationBars.buttons["安全撤销"].isEnabled,
            "The same inverse cannot be authorized again before readback")
        let reconcile = app.buttons["impress.duplex.reconcile-interrupted"]
        XCTAssertTrue(reconcile.waitForExistence(timeout: 15))
        XCTAssertTrue(reconcile.isEnabled)
        reconcile.tap()
        let verified = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            let value = String(describing: recoveryDiff.value ?? "")
            return value.contains("撤销中断核查") && value.contains("reverted")
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [verified], timeout: 30), .completed,
            "The exact WCDB original content at revision+2 must prove F06")
        XCTAssertFalse(app.switches["impress.duplex.select-card"].isEnabled,
            "Verified inverse must not remain a selectable pending card")
        let evidence = XCTAttachment(screenshot: app.screenshot())
        evidence.name = "Impress-V1.1-F06-card-inverse-actual-SIGKILL-readback"
        evidence.lifetime = .keepAlways
        self.add(evidence)
    }

    /// F06 note inverse must cross a *real* process boundary: the isolated QA
    /// Markdown is restored by the authorized coordinated writer, but Chat
    /// continues to hold the persisted .undoing intent until exact SHA readback.
    func testF06ProcessDeathAfterNoteUndoReconcilesExactSourceBytes() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-ImpressV11SyntheticVault",
            "-ImpressV11FaultF06AfterNoteUndo", "-AppleLanguages", "(zh-Hans)"]
        app.launchEnvironment["IMPRESS_V11_FIXTURE_ID"] = UUID().uuidString
        app.launch()
        let tabs = app.tabBars.firstMatch
        XCTAssertTrue(tabs.waitForExistence(timeout: 30))
        tabs.buttons.element(boundBy: 1).tap()
        let folder = app.cells.matching(identifier: "impress.notes.folder-row")
            .matching(NSPredicate(format: "label == %@", "Study")).firstMatch
        XCTAssertTrue(folder.waitForExistence(timeout: 30))
        folder.tap()
        let note = app.cells.matching(identifier: "impress.notes.file-row")
            .matching(NSPredicate(format: "label == %@", "Impress_E2E_Proof")).firstMatch
        XCTAssertTrue(note.waitForExistence(timeout: 20))
        note.tap()
        XCTAssertTrue(app.webViews["impress.notes.markdown-webview"]
            .waitForExistence(timeout: 40))
        app.buttons["更多笔记操作"].tap()
        app.buttons["根据笔记生成卡片"].tap()
        XCTAssertTrue(app.navigationBars["生成综合问题"].waitForExistence(timeout: 15))
        app.navigationBars.buttons["生成"].tap()
        let generate = app.alerts["模拟器合成出题"]
        XCTAssertTrue(generate.waitForExistence(timeout: 12))
        generate.buttons["生成"].tap()
        XCTAssertTrue(app.navigationBars["问题候选池"].waitForExistence(timeout: 20))
        XCTAssertGreaterThanOrEqual(app.tables.cells.count, 2)
        app.tables.cells.element(boundBy: 1).tap()
        let addCard = app.navigationBars.buttons.matching(
            NSPredicate(format: "label BEGINSWITH %@", "加入")).firstMatch
        XCTAssertTrue(addCard.waitForExistence(timeout: 12))
        addCard.tap()
        let approveNewCard = app.alerts["加入卡片集？"]
        XCTAssertTrue(approveNewCard.waitForExistence(timeout: 12))
        approveNewCard.buttons["确认加入"].tap()
        let savedCard = app.alerts["卡片已添加"]
        XCTAssertTrue(savedCard.waitForExistence(timeout: 30))
        savedCard.buttons["完成"].tap()

        tabs.buttons.element(boundBy: 0).tap()
        let reveal = app.buttons["impress.review.reveal-answer"]
        XCTAssertTrue(reveal.waitForExistence(timeout: 25))
        reveal.tap()
        let discuss = app.buttons["impress.review.ai-discussion"]
        XCTAssertTrue(discuss.waitForExistence(timeout: 15))
        discuss.tap()
        let info = app.alerts["关于讨论"]
        if info.waitForExistence(timeout: 2) { info.buttons["知道了"].tap() }
        let input = app.textViews["impress.ai.chat.input"]
        XCTAssertTrue(input.waitForExistence(timeout: 20))
        input.tap()
        input.typeText("F06 合成源文件已恢复但撤销回执未写，禁止重放")
        app.buttons["impress.ai.chat.send"].tap()
        let material = app.alerts["是否附带当前卡片？"]
        if material.waitForExistence(timeout: 8) {
            material.buttons["附带当前卡片"].tap()
        }
        let more = app.buttons["impress.ai.chat.reply-more"].firstMatch
        XCTAssertTrue(more.waitForExistence(timeout: 30))
        more.tap()
        let change = app.buttons["统一预览笔记与原卡修订"]
        XCTAssertTrue(change.waitForExistence(timeout: 12))
        change.tap()
        let editNote = app.buttons["impress.duplex.edit-note"]
        XCTAssertTrue(editNote.waitForExistence(timeout: 15))
        tapVisible(editNote, in: app)
        let sectionAction = app.buttons["指定原章节并编辑 AI 建议"]
        XCTAssertTrue(sectionAction.waitForExistence(timeout: 15))
        sectionAction.tap()
        let chapters = app.tables["impress.duplex.note-section-picker"]
        XCTAssertTrue(chapters.waitForExistence(timeout: 15))
        XCTAssertGreaterThanOrEqual(chapters.cells.count, 2)
        chapters.cells.element(boundBy: 1).tap()
        let editor = app.textViews["impress.duplex.section-replacement"]
        XCTAssertTrue(editor.waitForExistence(timeout: 15))
        editor.tap()
        editor.typeText("\n## F06_ReverseProof\n完整来源文件先写入，待人工撤销并强杀。")
        app.buttons["impress.duplex.save-section-draft"].tap()
        let preview = app.buttons["impress.duplex.preview"]
        tapVisible(preview, in: app)
        let diff = app.textViews["impress.duplex.full-diff"]
        XCTAssertTrue(diff.waitForExistence(timeout: 20))
        let noteToggle = app.switches["impress.duplex.select-note"]
        let cardToggle = app.switches["impress.duplex.select-card"]
        XCTAssertTrue(noteToggle.exists && cardToggle.exists)
        XCTAssertTrue(noteToggle.isEnabled)
        if String(describing: noteToggle.value ?? "") == "0" { noteToggle.tap() }
        if cardToggle.isEnabled && String(describing: cardToggle.value ?? "") == "1" {
            cardToggle.tap()
        }
        let confirm = app.buttons["impress.duplex.confirm"]
        XCTAssertTrue(confirm.isEnabled)
        confirm.tap()
        let consent = app.alerts["确认这两个目标的所选修改？"]
        XCTAssertTrue(consent.waitForExistence(timeout: 15))
        consent.buttons["确认执行"].tap()
        let applied = app.alerts["所选修改已处理"]
        XCTAssertTrue(applied.waitForExistence(timeout: 30),
            "Actual isolated QA Markdown must be committed before note undo")
        applied.buttons["确定"].tap()

        let undo = app.navigationBars.buttons["安全撤销"]
        XCTAssertTrue(undo.waitForExistence(timeout: 15))
        undo.tap()
        let undoNote = app.buttons["撤销笔记改动"]
        XCTAssertTrue(undoNote.waitForExistence(timeout: 15))
        undoNote.tap()
        let inversePreview = app.textViews["impress.duplex.undo.full-diff"]
        XCTAssertTrue(inversePreview.waitForExistence(timeout: 20))
        XCTAssertTrue(String(describing: inversePreview.value ?? "").contains("SHA-256:"))
        let inverse = app.buttons["impress.duplex.undo.confirm"]
        XCTAssertTrue(inverse.isEnabled)
        inverse.tap()
        let inverseConsent = app.alerts["确认撤销这个目标？"]
        XCTAssertTrue(inverseConsent.waitForExistence(timeout: 12))
        XCTAssertFalse(inverse.isEnabled,
            "F05 note inverse must not accept another overlapping undo consent")
        inverseConsent.buttons["确认撤销"].tap()
        let death = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            app.state == .notRunning
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [death], timeout: 35), .completed,
            "Only durable isolated QA note inverse may terminate test process")

        app.launchArguments.removeAll { $0 == "-ImpressV11FaultF06AfterNoteUndo" }
        app.launch()
        XCTAssertTrue(tabs.waitForExistence(timeout: 30))
        tabs.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(reveal.waitForExistence(timeout: 30))
        reveal.tap()
        XCTAssertTrue(discuss.waitForExistence(timeout: 15))
        discuss.tap()
        XCTAssertTrue(more.waitForExistence(timeout: 25))
        more.tap()
        XCTAssertTrue(change.waitForExistence(timeout: 15))
        change.tap()
        XCTAssertTrue(preview.waitForExistence(timeout: 20))
        tapVisible(preview, in: app)
        let recovered = app.textViews["impress.duplex.full-diff"]
        XCTAssertTrue(recovered.waitForExistence(timeout: 20))
        XCTAssertTrue(String(describing: recovered.value ?? "").contains("undoing"))
        XCTAssertFalse(app.buttons["impress.duplex.confirm"].isEnabled)
        XCTAssertFalse(app.navigationBars.buttons["安全撤销"].isEnabled)
        let reconcile = app.buttons["impress.duplex.reconcile-interrupted"]
        XCTAssertTrue(reconcile.waitForExistence(timeout: 15))
        XCTAssertTrue(reconcile.isEnabled)
        reconcile.tap()
        let verdict = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            let text = String(describing: recovered.value ?? "")
            return text.contains("撤销中断核查") && text.contains("reverted")
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [verdict], timeout: 30), .completed,
            "Only the exact restored original source SHA may close note inverse")
        XCTAssertFalse(app.switches["impress.duplex.select-note"].isEnabled)
        let evidence = XCTAttachment(screenshot: app.screenshot())
        evidence.name = "Impress-V1.1-F06-original-bytes-note-inverse-process-death"
        evidence.lifetime = .keepAlways
        self.add(evidence)
    }


    /// F01 real UI: actual disposable Markdown write first, then a concurrent
    /// legal WCDB card content CAS. Both facts survive process termination.
    func testF01RealPartialNoteSuccessCardConflictRetainsColdStartFacts() throws {
        try verifyRealPartialDuplex(
            fault: "-ImpressV11FaultF01AfterNoteCardConflict",
            expectedNote: "applied", expectedCard: "conflict",
            sourceShouldContainApprovedEdit: true)
    }

    /// F02 real UI: production Vault guard refuses a synthetic source write
    /// while the independently approved WCDB card is still committed.
    func testF02RealPartialNoteDenialCardSuccessRetainsColdStartFacts() throws {
        try verifyRealPartialDuplex(
            fault: "-ImpressV11FaultF02DenyNote",
            expectedNote: "failed", expectedCard: "applied",
            sourceShouldContainApprovedEdit: false)
    }

    private func verifyRealPartialDuplex(
        fault: String, expectedNote: String, expectedCard: String,
        sourceShouldContainApprovedEdit: Bool) throws {
        let app = XCUIApplication()
        app.launchArguments = [
            "-ImpressV11SyntheticVault", fault,
            "-AppleLanguages", "(zh-Hans)"
        ]
        app.launchEnvironment["IMPRESS_V11_FIXTURE_ID"] = UUID().uuidString
        app.launch()
        let tabs = app.tabBars.firstMatch
        XCTAssertTrue(tabs.waitForExistence(timeout: 30))
        tabs.buttons.element(boundBy: 1).tap()
        let folder = app.cells.matching(identifier: "impress.notes.folder-row")
            .matching(NSPredicate(format: "label == %@", "Study")).firstMatch
        XCTAssertTrue(folder.waitForExistence(timeout: 30))
        folder.tap()
        let note = app.cells.matching(identifier: "impress.notes.file-row")
            .matching(NSPredicate(format: "label == %@", "Impress_E2E_Proof")).firstMatch
        XCTAssertTrue(note.waitForExistence(timeout: 20))
        note.tap()
        XCTAssertTrue(app.webViews["impress.notes.markdown-webview"]
            .waitForExistence(timeout: 40))

        // Generate, reject one candidate, then explicitly import ONE card.
        app.buttons["更多笔记操作"].tap()
        app.buttons["根据笔记生成卡片"].tap()
        XCTAssertTrue(app.navigationBars["生成综合问题"].waitForExistence(timeout: 15))
        app.navigationBars.buttons["生成"].tap()
        let generate = app.alerts["模拟器合成出题"]
        XCTAssertTrue(generate.waitForExistence(timeout: 12))
        generate.buttons["生成"].tap()
        XCTAssertTrue(app.navigationBars["问题候选池"].waitForExistence(timeout: 20))
        XCTAssertGreaterThanOrEqual(app.tables.cells.count, 2)
        app.tables.cells.element(boundBy: 1).tap()
        let importButton = app.navigationBars.buttons.matching(
            NSPredicate(format: "label BEGINSWITH %@", "加入")).firstMatch
        XCTAssertTrue(importButton.waitForExistence(timeout: 12))
        importButton.tap()
        let importConsent = app.alerts["加入卡片集？"]
        XCTAssertTrue(importConsent.waitForExistence(timeout: 12))
        importConsent.buttons["确认加入"].tap()
        let saved = app.alerts["卡片已添加"]
        XCTAssertTrue(saved.waitForExistence(timeout: 30))
        saved.buttons["完成"].tap()

        tabs.buttons.element(boundBy: 0).tap()
        let reveal = app.buttons["impress.review.reveal-answer"]
        XCTAssertTrue(reveal.waitForExistence(timeout: 25))
        reveal.tap()
        let discuss = app.buttons["impress.review.ai-discussion"]
        XCTAssertTrue(discuss.waitForExistence(timeout: 15))
        discuss.tap()
        let intro = app.alerts["关于讨论"]
        if intro.waitForExistence(timeout: 2) { intro.buttons["知道了"].tap() }
        let input = app.textViews["impress.ai.chat.input"]
        XCTAssertTrue(input.waitForExistence(timeout: 20))
        input.tap()
        input.typeText("合成 F01/F02 双目标部分成功与真实冷启动回读")
        app.buttons["impress.ai.chat.send"].tap()
        let context = app.alerts["是否附带当前卡片？"]
        if context.waitForExistence(timeout: 8) {
            context.buttons["附带当前卡片"].tap()
        }
        let more = app.buttons["impress.ai.chat.reply-more"].firstMatch
        XCTAssertTrue(more.waitForExistence(timeout: 30))
        more.tap()
        let openProposal = app.buttons["统一预览笔记与原卡修订"]
        XCTAssertTrue(openProposal.waitForExistence(timeout: 12))
        openProposal.tap()

        // Both targets must really be changed by a reviewed AI proposal and
        // a separately edited original section; a bare no-op is not F01/F02.
        let adopt = app.buttons["impress.duplex.use-suggestion"]
        XCTAssertTrue(adopt.waitForExistence(timeout: 20))
        tapVisible(adopt, in: app)
        let noteEdit = app.buttons["impress.duplex.edit-note"]
        XCTAssertTrue(noteEdit.waitForExistence(timeout: 15))
        tapVisible(noteEdit, in: app)
        let sectionAction = app.buttons["指定原章节并编辑 AI 建议"]
        XCTAssertTrue(sectionAction.waitForExistence(timeout: 15))
        sectionAction.tap()
        let sections = app.tables["impress.duplex.note-section-picker"]
        XCTAssertTrue(sections.waitForExistence(timeout: 15))
        XCTAssertGreaterThanOrEqual(sections.cells.count, 2)
        sections.cells.element(boundBy: 1).tap()
        let editor = app.textViews["impress.duplex.section-replacement"]
        XCTAssertTrue(editor.waitForExistence(timeout: 15))
        editor.tap()
        let marker = "F01_F02_Approved_Source_Change"
        editor.typeText("\n## " + marker +
                        "\n这是已人工确认的合成资料修改。")
        app.buttons["impress.duplex.save-section-draft"].tap()
        let preview = app.buttons["impress.duplex.preview"]
        tapVisible(preview, in: app)
        let diff = app.textViews["impress.duplex.full-diff"]
        XCTAssertTrue(diff.waitForExistence(timeout: 20))
        XCTAssertTrue(String(describing: diff.value ?? "").contains("Vault ID:"))
        let noteSwitch = app.switches["impress.duplex.select-note"]
        let cardSwitch = app.switches["impress.duplex.select-card"]
        XCTAssertTrue(noteSwitch.isEnabled && cardSwitch.isEnabled,
            "Both independent targets must be authorizable before execution")
        let approve = app.buttons["impress.duplex.confirm"]
        XCTAssertTrue(approve.isEnabled)
        approve.tap()
        let finalConsent = app.alerts["确认这两个目标的所选修改？"]
        XCTAssertTrue(finalConsent.waitForExistence(timeout: 12))
        finalConsent.buttons["确认执行"].tap()
        let partial = app.alerts["存在未完成的修改"]
        XCTAssertTrue(partial.waitForExistence(timeout: 40),
            "F01/F02 cannot report full success when one target failed")
        partial.buttons["确定"].tap()
        func assertStatuses() {
            let detail = String(describing: diff.value ?? "")
            let parts = detail.components(separatedBy: "cardID:")
            XCTAssertGreaterThanOrEqual(parts.count, 2)
            XCTAssertTrue(parts[0].contains("状态：" + expectedNote),
                "Actual note outcome must retain its own durable status")
            XCTAssertTrue(parts.dropFirst().joined(separator: "cardID:")
                .contains("状态：" + expectedCard),
                "Actual card CAS outcome must retain its own durable status")
        }
        assertStatuses()
        if sourceShouldContainApprovedEdit {
            XCTAssertFalse(noteSwitch.isEnabled, "F01 applied note is immutable")
            XCTAssertFalse(cardSwitch.isEnabled,
                "F01 conflicting card requires NEW human review")
            XCTAssertFalse(approve.isEnabled,
                "A conflicting old consent may not be confirmed again")
        } else {
            XCTAssertTrue(noteSwitch.isEnabled,
                "F02 failed note may be re-reviewed independently")
            XCTAssertFalse(cardSwitch.isEnabled,
                "F02 successful card may not be applied again")
        }
        let evidence = XCTAttachment(screenshot: app.screenshot())
        evidence.name = "Impress-V1.1-" + expectedNote + "-" + expectedCard +
            "-actual-partial-receipts"
        evidence.lifetime = .keepAlways
        add(evidence)

        // Reopen the exact WCDB + disposable source; do not use a test reset.
        app.terminate()
        app.launchArguments.removeAll { $0 == fault }
        app.launch()
        XCTAssertTrue(tabs.waitForExistence(timeout: 30))
        tabs.buttons.element(boundBy: 1).tap()
        XCTAssertTrue(folder.waitForExistence(timeout: 30))
        folder.tap()
        XCTAssertTrue(note.waitForExistence(timeout: 20))
        note.tap()
        XCTAssertTrue(app.webViews["impress.notes.markdown-webview"]
            .waitForExistence(timeout: 30))
        app.buttons["更多笔记操作"].tap()
        app.buttons["查看 Markdown 源码"].tap()
        let source = app.textViews.firstMatch
        XCTAssertTrue(source.waitForExistence(timeout: 15))
        XCTAssertEqual(String(describing: source.value ?? "").contains(marker),
            sourceShouldContainApprovedEdit,
            "Read the real persisted QA Markdown, not the Chat draft")

        // Reopen the same originating card session via visible navigation and
        // verify that neither successful target is replayed on cold start.
        var backs = 0
        while !tabs.exists && backs < 5 {
            let back = app.navigationBars.buttons.element(boundBy: 0)
            XCTAssertTrue(back.waitForExistence(timeout: 12))
            back.tap()
            backs += 1
        }
        XCTAssertTrue(tabs.waitForExistence(timeout: 15))
        tabs.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(reveal.waitForExistence(timeout: 30))
        reveal.tap()
        XCTAssertTrue(discuss.waitForExistence(timeout: 15))
        discuss.tap()
        XCTAssertTrue(more.waitForExistence(timeout: 25))
        more.tap()
        XCTAssertTrue(openProposal.waitForExistence(timeout: 15))
        openProposal.tap()
        let conflictPrompt = app.alerts["目标版本存在冲突"]
        if expectedCard == "conflict" {
            XCTAssertTrue(conflictPrompt.waitForExistence(timeout: 15),
                "A conflicting prior approval cannot silently become executable")
            XCTAssertTrue(conflictPrompt.buttons["重新核查最新版本"].exists)
            conflictPrompt.buttons["查看旧提案"].tap()
        }
        // A cold-start recovery opens the existing Change screen, not the
        // Approval screen. Reach the immutable receipt by the same visible
        // Preview action used in production; do not bypass any UI or CAS gate.
        let restoredPreview = app.buttons["impress.duplex.preview"]
        XCTAssertTrue(restoredPreview.waitForExistence(timeout: 20),
            "The pending proposal must reopen its visible Change screen")
        let enabledPreview = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "enabled == true"),
            object: restoredPreview)
        XCTAssertEqual(XCTWaiter.wait(for: [enabledPreview], timeout: 20),
            .completed, "Recovered approval preview must be enabled after load")
        tapVisible(restoredPreview, in: app)
        XCTAssertTrue(diff.waitForExistence(timeout: 20))
        assertStatuses()
        if expectedCard == "conflict" {
            XCTAssertFalse(app.buttons["impress.duplex.confirm"].isEnabled,
                "Restart may not reauthorize an obsolete card CAS")
        }
        let cold = XCTAttachment(screenshot: app.screenshot())
        cold.name = "Impress-V1.1-" + expectedNote + "-" + expectedCard +
            "-cold-restart-source-and-receipt"
        cold.lifetime = .keepAlways
        add(cold)

        if expectedCard == "conflict" {
            // Fresh review must be reachable WITHOUT replacing the archived
            // partial-success receipt and WITHOUT reusing old card content.
            // Back from Approval -> Change -> the existing production Chat.
            for _ in 0..<2 {
                let back = app.navigationBars.buttons.element(boundBy: 0)
                XCTAssertTrue(back.waitForExistence(timeout: 12))
                back.tap()
            }
            XCTAssertTrue(more.waitForExistence(timeout: 15))
            more.tap()
            XCTAssertTrue(openProposal.waitForExistence(timeout: 12))
            openProposal.tap()
            XCTAssertTrue(conflictPrompt.waitForExistence(timeout: 15))
            conflictPrompt.buttons["重新核查最新版本"].tap()
            let currentQuestion = app.textViews["impress.duplex.question"]
            XCTAssertTrue(currentQuestion.waitForExistence(timeout: 25))
            XCTAssertTrue(String(describing: currentQuestion.value ?? "")
                .contains("F01 外部合法内容修改"),
                "Fresh proposal must use latest actual WCDB card content")
            XCTAssertTrue(currentQuestion.isEnabled,
                "Conflicting old consent must not leave a read-only editor")
            let newReview = XCTAttachment(screenshot: app.screenshot())
            newReview.name = "Impress-F01-explicit-fresh-card-content-review"
            newReview.lifetime = .keepAlways
            add(newReview)

            let back = app.navigationBars.buttons.element(boundBy: 0)
            XCTAssertTrue(back.waitForExistence(timeout: 12))
            back.tap()
            XCTAssertTrue(more.waitForExistence(timeout: 15))
            more.tap()
            let receiptHistory = app.buttons["查看修订记录与逐项回执"]
            XCTAssertTrue(receiptHistory.waitForExistence(timeout: 12))
            receiptHistory.tap()
            let history = app.tables["impress.duplex.receipt-history"]
            XCTAssertTrue(history.waitForExistence(timeout: 15))
            XCTAssertGreaterThanOrEqual(history.cells.count, 1,
                "Archiving a conflicted proposal must preserve its prior receipts")
            history.cells.element(boundBy: 0).tap()
            let previous = app.textViews["impress.duplex.receipt-detail"]
            XCTAssertTrue(previous.waitForExistence(timeout: 15))
            let oldReceipt = String(describing: previous.value ?? "")
            XCTAssertTrue(oldReceipt.contains("状态：applied"))
            XCTAssertTrue(oldReceipt.contains("状态：conflict"))
            XCTAssertTrue(oldReceipt.contains("此页为历史回执，不自动重试"))
        }
    }

    /// Single launch fixture: note -> original card -> completed Chat -> dual CAS
    /// approval/receipt -> safe undo -> source impact -> FSRS -> real Files ZIP
    /// export, picker import, human restore and cold-reopened WCDB. The two
    /// mutually exclusive source-impact outcomes remain separate tests.
    // XCTest executes selected methods alphabetically, not by -only-testing
    // argument order. Run the full same-fixture Files E2E before standalone
    // F12 touches the hosted Files document-provider scene. Keep every
    // picker, explicit approval and cold-restart assertion intact.
    func testA00SingleFixture18StepSourceCardChatFSRSAndRealFilesRestore() throws {
        try runContinuousSourceCardChatDoubleTargetApprovalAndRestart(
            reviseSourceAffected: false, includeRealFilesBackupRestore: true)
    }

    func testContinuousSourceCardChatDoubleTargetApprovalAndRestart() throws {
        try runContinuousSourceCardChatDoubleTargetApprovalAndRestart(
            reviseSourceAffected: false)
    }

    func testAffectedSourceImpactEditsOriginalCardThroughVisibleUIAndColdRestart() throws {
        try runContinuousSourceCardChatDoubleTargetApprovalAndRestart(
            reviseSourceAffected: true)
    }

    /// F08 / visible step 16: a later human edit must defeat the inverse of
    /// the original Chat proposal, including when reopened from historic receipts.
    /// Existing successful undo and both source-impact decisions remain untouched.
    func testF08VisibleLaterCardRevisionRefusesHistoricInverseAfterColdRestart() throws {
        try runContinuousSourceCardChatDoubleTargetApprovalAndRestart(
            reviseSourceAffected: false, staleInverseAfterNewCardEdit: true)
    }

    private func runContinuousSourceCardChatDoubleTargetApprovalAndRestart(
        reviseSourceAffected: Bool,
        staleInverseAfterNewCardEdit: Bool = false,
        includeRealFilesBackupRestore: Bool = false
    ) throws {
        let app = XCUIApplication()
        app.launchArguments += ["-ImpressV11SyntheticVault",
                                "-AppleLanguages", "(zh-Hans)"]
        if includeRealFilesBackupRestore {
            // The hook is DEBUG-only: it exposes a checksum-identical copy of
            // a genuinely user-exported ZIP to the genuine system Files UI.
            app.launchArguments += ["-ImpressV11RestorePickerE2E",
                                    "-AppleLocale", "zh_CN"]
        }
        let id = UUID().uuidString
        app.launchEnvironment["IMPRESS_V11_FIXTURE_ID"] = id
        app.launch()
        let tabs = app.tabBars.firstMatch
        XCTAssertTrue(tabs.waitForExistence(timeout: 30))
        tabs.buttons.element(boundBy: 1).tap()
        let folder = app.cells.matching(identifier: "impress.notes.folder-row")
            .matching(NSPredicate(format: "label == %@", "Study")).firstMatch
        XCTAssertTrue(folder.waitForExistence(timeout: 30))
        folder.tap()
        let note = app.cells.matching(identifier: "impress.notes.file-row")
            .matching(NSPredicate(format: "label == %@", "Impress_E2E_Proof")).firstMatch
        XCTAssertTrue(note.waitForExistence(timeout: 20))
        note.tap()
        // A cold Xcode 27 simulator can stall coordinated source reads while
        // its full-Vault scan and accessibility bootstrap settle. Keep the
        // actual source/identity assertion (never skip or inject a document).
        let actualReader = app.webViews["impress.notes.markdown-webview"]
        XCTAssertTrue(actualReader.waitForExistence(timeout: 40),
            "The real selected note must open through its authorized Vault reader")
        XCTAssertEqual(actualReader.label, "Impress_E2E_Proof",
            "The verified document name must be inside the continuous reader")

        // Real chapter picker -> review a deterministic AI candidate, reject
        // the second candidate, and explicitly commit one original card.
        app.buttons["更多笔记操作"].tap()
        app.buttons["根据笔记生成卡片"].tap()
        XCTAssertTrue(app.navigationBars["生成综合问题"].waitForExistence(timeout: 15))
        app.navigationBars.buttons["生成"].tap()
        let generateConsent = app.alerts["模拟器合成出题"]
        XCTAssertTrue(generateConsent.waitForExistence(timeout: 12))
        generateConsent.buttons["生成"].tap()
        XCTAssertTrue(app.navigationBars["问题候选池"].waitForExistence(timeout: 20))
        let candidates = app.tables.cells
        XCTAssertGreaterThanOrEqual(candidates.count, 2)
        candidates.element(boundBy: 1).tap()
        let importButton = app.navigationBars.buttons.matching(
            NSPredicate(format: "label BEGINSWITH %@", "加入")).firstMatch
        XCTAssertTrue(importButton.isEnabled)
        importButton.tap()
        let saveCard = app.alerts["加入卡片集？"]
        XCTAssertTrue(saveCard.waitForExistence(timeout: 12))
        saveCard.buttons["确认加入"].tap()
        let saved = app.alerts["卡片已添加"]
        XCTAssertTrue(saved.waitForExistence(timeout: 30))
        saved.buttons["完成"].tap()

        // UI re-entry to the exact card and its verified source. No alternate
        // database, title matching, or source inference is used.
        tabs.buttons.element(boundBy: 0).tap()
        let discuss = app.buttons["impress.review.ai-discussion"]
        XCTAssertFalse(discuss.exists, "Discussion is intentionally hidden before answer reveal")
        let reveal = app.buttons["impress.review.reveal-answer"]
        XCTAssertTrue(reveal.waitForExistence(timeout: 20))
        reveal.tap()
        XCTAssertTrue(discuss.waitForExistence(timeout: 15))
        // The non-interactive status sentence replaces all four chip buttons.
        XCTAssertFalse(app.otherElements["impress.review.rating-guide"].exists)
        let summary = app.staticTexts["impress.review.rating-summary"]
        XCTAssertTrue(summary.waitForExistence(timeout: 15))
        for arrow in ["←", "↑", "→", "↓"] {
            XCTAssertTrue(summary.label.contains(arrow),
                "The mapping belongs in one compact guidance sentence")
        }
        let ratingEvidence = XCTAttachment(screenshot: app.screenshot())
        ratingEvidence.name = "Impress-V1.1-compact-swipe-guidance"
        ratingEvidence.lifetime = .keepAlways
        add(ratingEvidence)
        let source = app.buttons["impress.review.source-note"]
        XCTAssertTrue(source.waitForExistence(timeout: 20))
        source.tap()
        XCTAssertTrue(app.webViews["impress.notes.markdown-webview"]
            .waitForExistence(timeout: 15))
        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(discuss.waitForExistence(timeout: 15))
        discuss.tap()

        let input = app.textViews["impress.ai.chat.input"]
        XCTAssertTrue(input.waitForExistence(timeout: 20))
        let guide = app.alerts["关于讨论"]
        if guide.waitForExistence(timeout: 2) { guide.buttons["知道了"].tap() }
        input.tap()
        input.typeText("请根据所选来源明确推导、反例与下一步可检验的假设。")
        let send = app.buttons["impress.ai.chat.send"]
        XCTAssertTrue(send.isEnabled)
        send.tap()
        let context = app.alerts["是否附带当前卡片？"]
        if context.waitForExistence(timeout: 8) {
            context.buttons["附带当前卡片"].tap()
        }
        let completedText = app.textViews.matching(
            identifier: "impress.ai.chat.message-body").matching(
                NSPredicate(format: "value CONTAINS %@", "合成模型回复")).firstMatch
        XCTAssertTrue(completedText.waitForExistence(timeout: 30))
        // The completed response presents a visible native Copy / More
        // footer. Its buttons, rather than the non-accessibility-element
        // UICollectionViewCell that owns selectable text, are the real user
        // interaction. This also gates approval on a completed AI response:
        // pending/failed replies never get a reply-actions footer.
        let replyMore = app.buttons["impress.ai.chat.reply-more"].firstMatch
        XCTAssertTrue(replyMore.waitForExistence(timeout: 20),
            "A completed AI reply must expose its native More actions; partial output must not")
        replyMore.tap()
        let change = app.buttons["统一预览笔记与原卡修订"]
        XCTAssertTrue(change.waitForExistence(timeout: 12))
        change.tap()

        let answer = app.textViews["impress.duplex.answer"]
        XCTAssertTrue(answer.waitForExistence(timeout: 20))
        let adopt = app.buttons["impress.duplex.use-suggestion"]
        XCTAssertTrue(adopt.waitForExistence(timeout: 15))
        tapVisible(adopt, in: app)
        let editNote = app.buttons["impress.duplex.edit-note"]
        XCTAssertTrue(editNote.waitForExistence(timeout: 15))
        tapVisible(editNote, in: app)
        let kind = app.buttons["指定原章节并编辑 AI 建议"]
        XCTAssertTrue(kind.waitForExistence(timeout: 12))
        kind.tap()
        let sectionList = app.tables["impress.duplex.note-section-picker"]
        XCTAssertTrue(sectionList.waitForExistence(timeout: 15))
        XCTAssertGreaterThanOrEqual(sectionList.cells.count, 2)
        sectionList.cells.element(boundBy: 1).tap()
        let replacement = app.textViews["impress.duplex.section-replacement"]
        XCTAssertTrue(replacement.waitForExistence(timeout: 15))
        replacement.tap()
        replacement.typeText("\n## 观察\n（经人工核查）这是一条可检验的解释。")
        app.buttons["impress.duplex.save-section-draft"].tap()

        // The actual existing proposal and Approval screens are both used.
        // Switching target choices is non-destructive; neither target is
        // written until the explicit confirmation alert.
        XCTAssertTrue(answer.waitForExistence(timeout: 20))
        let reviewProposal = app.buttons["impress.duplex.preview"]
        tapVisible(reviewProposal, in: app)
        let fullDiff = app.textViews["impress.duplex.full-diff"]
        XCTAssertTrue(fullDiff.waitForExistence(timeout: 20))
        XCTAssertTrue(String(describing: fullDiff.value ?? "").contains("Vault ID:"))
        let noteToggle = app.switches["impress.duplex.select-note"]
        let cardToggle = app.switches["impress.duplex.select-card"]
        XCTAssertTrue(noteToggle.exists && cardToggle.exists)
        let approve = app.buttons["impress.duplex.confirm"]
        XCTAssertTrue(approve.isEnabled)
        approve.tap()
        let finalConsent = app.alerts["确认这两个目标的所选修改？"]
        XCTAssertTrue(finalConsent.waitForExistence(timeout: 12))
        // F05 real UI: pending human consent must close the tap race before
        // any note or card transaction. Cancelling must restore eligibility
        // without leaving either target in an applied/in-flight state.
        XCTAssertFalse(approve.isEnabled,
            "A visible first consent must disable a duplicate confirmation")
        XCTAssertEqual(app.alerts.matching(
            identifier: "确认这两个目标的所选修改？").count, 1,
            "Rapid or repeated approval must never stack consent sheets")
        finalConsent.buttons["取消"].tap()
        let consentCancelled = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "enabled == true"), object: approve)
        XCTAssertEqual(XCTWaiter.wait(for: [consentCancelled], timeout: 10), .completed,
            "Cancelling F05 consent must restore approval without writing")
        XCTAssertTrue(noteToggle.isEnabled && cardToggle.isEnabled,
            "No note or original-card state may be consumed by a cancelled dialog")
        approve.tap()
        XCTAssertTrue(finalConsent.waitForExistence(timeout: 12))
        XCTAssertFalse(approve.isEnabled,
            "The renewed F05 consent must also prevent duplicate submissions")
        finalConsent.buttons["确认执行"].tap()
        let applied = app.alerts["所选修改已处理"]
        XCTAssertTrue(applied.waitForExistence(timeout: 30),
            "Both source and original card must be verified before a success receipt")
        applied.buttons["确定"].tap()
        let receipt = String(describing: fullDiff.value ?? "")
        XCTAssertTrue(receipt.contains("applied"))
        // F05 post-commit: both targets are now consumed. They must remain
        // disabled rather than permitting a second CAS or a second consent.
        XCTAssertFalse(approve.isEnabled,
            "An already-applied proposal cannot be submitted a second time")
        XCTAssertFalse(noteToggle.isEnabled,
            "The approved Markdown target must never be offered again")
        XCTAssertFalse(cardToggle.isEnabled,
            "The committed card revision must never be offered again")
        // Keep the actual inverse-review route available, without silently
        // undoing a user-approved write or conflating an offer with an undo.
        let safeUndo = app.navigationBars.buttons["安全撤销"]
        XCTAssertTrue(safeUndo.waitForExistence(timeout: 12))
        XCTAssertTrue(safeUndo.isEnabled)
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "Impress-V1.1-continuous-double-target-CAS-approval"
        screenshot.lifetime = .keepAlways
        add(screenshot)


        if staleInverseAfterNewCardEdit {
            // F08 real user route: after the approved two-target write, change
            // the SAME card legitimately from Review rather than injecting a
            // newer WCDB revision. The former proposal remains visible in
            // Chat history and must NOT acquire a new inverse authorization.
            var backSteps = 0
            while !tabs.exists && backSteps < 7 {
                let back = app.navigationBars.buttons.element(boundBy: 0)
                XCTAssertTrue(back.waitForExistence(timeout: 12),
                    "F08 must leave the approval hierarchy through real navigation")
                back.tap()
                backSteps += 1
            }
            XCTAssertTrue(tabs.waitForExistence(timeout: 20))
            tabs.buttons.element(boundBy: 0).tap()
            let freshReveal = app.buttons["impress.review.reveal-answer"]
            XCTAssertTrue(freshReveal.waitForExistence(timeout: 30))
            freshReveal.tap()
            let quickEdit = app.buttons["impress.review.quick-edit"]
            XCTAssertTrue(quickEdit.waitForExistence(timeout: 15))
            quickEdit.tap()
            let cardEditor = app.navigationBars["编辑卡片"]
            XCTAssertTrue(cardEditor.waitForExistence(timeout: 20))
            let editableQuestion = app.textViews.matching(
                NSPredicate(format: "label == %@", "问题")).firstMatch
            XCTAssertTrue(editableQuestion.waitForExistence(timeout: 15))
            editableQuestion.tap()
            for _ in 0..<3 where !app.keyboards.firstMatch.exists {
                editableQuestion.tap()
            }
            XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 12))
            editableQuestion.typeText("（F08后续合法修订）")
            let saveLater = app.buttons["impress.composer.save"]
            XCTAssertTrue(saveLater.waitForExistence(timeout: 12))
            XCTAssertTrue(saveLater.isEnabled)
            saveLater.tap()
            let editorDismissed = XCTNSPredicateExpectation(
                predicate: NSPredicate(format: "exists == false"), object: cardEditor)
            XCTAssertEqual(XCTWaiter.wait(for: [editorDismissed], timeout: 30), .completed,
                "The newer legitimate revision must be durably committed first")

            // Re-enter the original persisted session and its old executed
            // receipt, not a new proposal or synthetic direct repository API.
            let restoredDiscussion = app.buttons["impress.review.ai-discussion"]
            if !restoredDiscussion.exists {
                XCTAssertTrue(freshReveal.waitForExistence(timeout: 20))
                freshReveal.tap()
            }
            XCTAssertTrue(restoredDiscussion.waitForExistence(timeout: 15))
            restoredDiscussion.tap()
            let features = app.buttons["impress.ai.chat.features"]
            XCTAssertTrue(features.waitForExistence(timeout: 20))
            let introduction = app.alerts["关于讨论"]
            if introduction.waitForExistence(timeout: 2) {
                introduction.buttons["知道了"].tap()
            }
            features.tap()
            let historyButton = app.buttons["历史讨论"]
            XCTAssertTrue(historyButton.waitForExistence(timeout: 12))
            historyButton.tap()
            let historyTable = app.tables["impress.ai.chat.history-list"]
            XCTAssertTrue(historyTable.waitForExistence(timeout: 15))
            let search = app.searchFields.firstMatch
            XCTAssertTrue(search.waitForExistence(timeout: 12))
            search.tap()
            search.typeText("请根据所选来源明确推导")
            let historicalSession = historyTable.cells.matching(
                identifier: "impress.ai.chat.history-row").matching(
                    NSPredicate(format: "label CONTAINS %@",
                                "请根据所选来源明确推导")).firstMatch
            XCTAssertTrue(historicalSession.waitForExistence(timeout: 20),
                "The old completed discussion must remain searchable after a newer card edit")
            historicalSession.tap()
            let historicalAnswer = app.textViews.matching(
                identifier: "impress.ai.chat.message-body").matching(
                    NSPredicate(format: "value CONTAINS %@", "合成模型回复")).firstMatch
            XCTAssertTrue(historicalAnswer.waitForExistence(timeout: 20))
            let historicalMore = app.buttons["impress.ai.chat.reply-more"].firstMatch
            XCTAssertTrue(historicalMore.waitForExistence(timeout: 15))
            historicalMore.tap()
            let receiptsAction = app.buttons["查看修订记录与逐项回执"]
            XCTAssertTrue(receiptsAction.waitForExistence(timeout: 12))
            receiptsAction.tap()
            let receiptList = app.tables["impress.duplex.receipt-history"]
            XCTAssertTrue(receiptList.waitForExistence(timeout: 20))
            XCTAssertGreaterThanOrEqual(receiptList.cells.count, 1)
            receiptList.cells.element(boundBy: 0).tap()
            let historicReceipt = app.textViews["impress.duplex.receipt-detail"]
            XCTAssertTrue(historicReceipt.waitForExistence(timeout: 15))
            XCTAssertTrue(String(describing: historicReceipt.value ?? "").contains("applied"),
                "The old proposal must retain its auditable applied receipt")

            // The older applied proposal is still offered for an *independent*
            // explicit undo review. Its version preflight must reject the
            // new card content before any .undoing intent or inverse write.
            let historyUndo = app.navigationBars.buttons["安全撤销"]
            XCTAssertTrue(historyUndo.waitForExistence(timeout: 12))
            historyUndo.tap()
            // The historical receipt intentionally returns to the exact
            // recorded proposal in the read-only change editor first.
            // Re-open its EXISTING approval screen via the same visible
            // "full preview" action used for a newly authored proposal;
            // the receipt is never executable directly from Chat history.
            let historicEditor = app.navigationBars["笔记与原卡修订"]
            XCTAssertTrue(historicEditor.waitForExistence(timeout: 20),
                "Historic undo must first reopen its persisted proposal editor")
            let historicPreview = app.buttons["impress.duplex.preview"]
            XCTAssertTrue(historicPreview.waitForExistence(timeout: 15))
            XCTAssertTrue(historicPreview.isEnabled)
            tapVisible(historicPreview, in: app)
            XCTAssertTrue(app.navigationBars["逐项核对并确认修改"]
                .waitForExistence(timeout: 20),
                "The exact old proposal must reopen the real approval view")
            let proposalUndo = app.navigationBars.buttons["安全撤销"]
            XCTAssertTrue(proposalUndo.waitForExistence(timeout: 20))
            proposalUndo.tap()
            let cardInverse = app.buttons["撤销原卡改动"]
            XCTAssertTrue(cardInverse.waitForExistence(timeout: 12))
            cardInverse.tap()
            let rejection = app.alerts["无法安全撤销"]
            XCTAssertTrue(rejection.waitForExistence(timeout: 30),
                "F08 must refuse stale historical inverse using the CURRENT card revision")
            XCTAssertFalse(app.alerts["撤销结果已保存"].exists,
                "A stale inverse cannot masquerade as a completed undo")
            XCTAssertFalse(app.textViews["impress.duplex.undo.full-diff"].exists,
                "Preflight conflict must not open an executable inverse diff")
            let refusalProof = XCTAttachment(screenshot: app.screenshot())
            refusalProof.name = "Impress-V1.1-F08-visible-old-inverse-vs-newer-legitimate-edit"
            refusalProof.lifetime = .keepAlways
            add(refusalProof)
            rejection.buttons["确定"].tap()

            // Genuine process death and WCDB reopen: the later legal revision
            // must survive. No stale undo, rescore or duplicate approved write.
            app.terminate()
            app.launch()
            XCTAssertTrue(tabs.waitForExistence(timeout: 35))
            tabs.buttons.element(boundBy: 0).tap()
            let reopenReveal = app.buttons["impress.review.reveal-answer"]
            XCTAssertTrue(reopenReveal.waitForExistence(timeout: 30))
            reopenReveal.tap()
            let reopenedEdit = app.buttons["impress.review.quick-edit"]
            XCTAssertTrue(reopenedEdit.waitForExistence(timeout: 15))
            reopenedEdit.tap()
            XCTAssertTrue(cardEditor.waitForExistence(timeout: 20))
            XCTAssertTrue(editableQuestion.waitForExistence(timeout: 15))
            XCTAssertTrue(String(describing: editableQuestion.value ?? "")
                .contains("（F08后续合法修订）"),
                "Old inverse must not overwrite the newer human edit after cold restart")
            let durableProof = XCTAttachment(screenshot: app.screenshot())
            durableProof.name = "Impress-V1.1-F08-newer-card-content-durable-after-restart"
            durableProof.lifetime = .keepAlways
            add(durableProof)
            return
        }

        // F08: actual human-controlled inverse of the already-applied CARD,
        // through the same visible approval controller (never direct WCDB).
        safeUndo.tap()
        let undoCard = app.buttons["撤销原卡改动"]
        XCTAssertTrue(undoCard.waitForExistence(timeout: 12),
            "Applied card must offer an independently authorized inverse")
        undoCard.tap()
        let undoPreview = app.textViews["impress.duplex.undo.full-diff"]
        XCTAssertTrue(undoPreview.waitForExistence(timeout: 20))
        XCTAssertTrue(String(describing: undoPreview.value ?? "").contains("cardID:"),
            "Undo must show the exact original card ID, not a generic confirmation")
        let undoConfirm = app.buttons["impress.duplex.undo.confirm"]
        XCTAssertTrue(undoConfirm.isEnabled)
        undoConfirm.tap()
        let inverseConsent = app.alerts["确认撤销这个目标？"]
        XCTAssertTrue(inverseConsent.waitForExistence(timeout: 12))
        inverseConsent.buttons["确认撤销"].tap()
        let inverseReceipt = app.alerts["撤销结果已保存"]
        XCTAssertTrue(inverseReceipt.waitForExistence(timeout: 30),
            "CAS-approved inverse must save its receipt; failure is not success")
        inverseReceipt.buttons["确定"].tap()
        let afterInverse = String(describing: fullDiff.value ?? "")
        XCTAssertTrue(afterInverse.contains("reverted"),
            "Card inverse status must persist independently of the note target")
        XCTAssertTrue(afterInverse.contains("applied"),
            "Undoing the card must not silently undo the approved Markdown")
        let inverseProof = XCTAttachment(screenshot: app.screenshot())
        inverseProof.name = "Impress-V1.1-approved-card-actual-safe-undo"
        inverseProof.lifetime = .keepAlways
        add(inverseProof)

        // This process boundary must not replace the existing WCDB or Vault.
        app.terminate()
        app.launch()
        XCTAssertTrue(tabs.waitForExistence(timeout: 30))
        tabs.buttons.element(boundBy: 1).tap()
        XCTAssertTrue(folder.waitForExistence(timeout: 25))
        folder.tap()
        let reopened = app.cells.matching(identifier: "impress.notes.file-row")
            .matching(NSPredicate(format: "label == %@", "Impress_E2E_Proof")).firstMatch
        XCTAssertTrue(reopened.waitForExistence(timeout: 20))
        reopened.tap()
        let persistedReader = app.webViews["impress.notes.markdown-webview"]
        XCTAssertTrue(persistedReader.waitForExistence(timeout: 15))
        // Verify the actual QA Markdown byte change after a true process boundary,
        // not merely that the folder shell can open again.
        app.buttons["更多笔记操作"].tap()
        app.buttons["查看 Markdown 源码"].tap()
        let savedNote = app.textViews.matching(
            NSPredicate(format: "value CONTAINS %@", "经人工核查")).firstMatch
        XCTAssertTrue(savedNote.waitForExistence(timeout: 15),
            "Approved source edits must survive cold launch in the same disposable Vault")
        // The reverse note -> original-card check is a real visible action.
        // A changed relevant section must offer an explicit human decision,
        // not silently rewrite the original card after a source edit.
        app.buttons["更多笔记操作"].tap()
        app.buttons["核查笔记更新是否影响原卡"].tap()
        let impactSheet = app.sheets["核查关联原卡"]
        XCTAssertTrue(impactSheet.waitForExistence(timeout: 20),
            "A changed note section must produce a real original-card review")
        impactSheet.buttons.element(boundBy: 0).tap()
        let impact = app.textViews["impress.notes.source-impact.full-text"]
        XCTAssertTrue(impact.waitForExistence(timeout: 20))
        let editAffected = app.buttons["impress.notes.source-impact.edit-original"]
        let unaffected = app.buttons["impress.notes.source-impact.unaffected"]
        XCTAssertTrue(editAffected.waitForExistence(timeout: 15))
        XCTAssertTrue(unaffected.waitForExistence(timeout: 15))
        XCTAssertTrue(unaffected.isEnabled,
            "Verified source and exact original card must enable an explicit decision")
        // Step 15 affected-card branch: open the real bound card editor, then
        // cancel without a content edit. A no-op editor visit MUST NOT silently
        // certify that the source change is irrelevant or change FSRS.
        XCTAssertTrue(editAffected.isEnabled)
        editAffected.tap()
        let originalCardEditor = app.navigationBars["编辑卡片"]
        XCTAssertTrue(originalCardEditor.waitForExistence(timeout: 20),
            "Affected note must reach the actual editor for the same original card")
        XCTAssertFalse(unaffected.isHittable,
            "The competing source decision must not remain tappable behind the editor")
        originalCardEditor.buttons.element(boundBy: 0).tap()
        XCTAssertFalse(originalCardEditor.exists)
        XCTAssertTrue(unaffected.waitForExistence(timeout: 15))
        XCTAssertTrue(unaffected.isEnabled && editAffected.isEnabled,
            "Cancelling editor must restore explicit source review, not auto-acknowledge")
        // Step 15: do not confuse merely seeing the impact screen with having
        // completed the human no-impact path. Cancel must be side-effect-free.
        if reviseSourceAffected {
            // Execute the OTHER real step-15 decision on an independent
            // synthetic run, rather than treating opening/cancelling an editor
            // as proof of a successful affected-source revision.
            editAffected.tap()
            XCTAssertTrue(originalCardEditor.waitForExistence(timeout: 20))
            let questionField = app.textViews.matching(
                NSPredicate(format: "label == %@", "问题")).firstMatch
            XCTAssertTrue(questionField.waitForExistence(timeout: 15),
                "The linked original card must expose its actual editable question")
            XCTAssertFalse(String(describing: questionField.value ?? "").isEmpty)
            questionField.tap()
            for _ in 0..<3 where !app.keyboards.firstMatch.exists {
                questionField.tap()
            }
            XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 12),
                "A real native keyboard must edit the linked original card")
            questionField.typeText("（来源核查修订）")
            let saveAffected = app.buttons["impress.composer.save"]
            XCTAssertTrue(saveAffected.waitForExistence(timeout: 12))
            XCTAssertTrue(saveAffected.isEnabled)
            saveAffected.tap()
            let editorClosed = XCTNSPredicateExpectation(
                predicate: NSPredicate(format: "exists == false"),
                object: originalCardEditor)
            XCTAssertEqual(XCTWaiter.wait(for: [editorClosed], timeout: 30), .completed,
                "Editor must close only after WCDB content/source CAS succeeds")
            XCTAssertFalse(unaffected.isEnabled,
                "Successful affected revision must consume the old source review")
            XCTAssertFalse(editAffected.isEnabled,
                "The consumed source version cannot launch another editor")
            app.navigationBars.buttons.element(boundBy: 0).tap()
            XCTAssertFalse(impact.exists)
            let returnedSource = app.textViews.matching(
                NSPredicate(format: "value CONTAINS %@", "经人工核查")).firstMatch
            XCTAssertTrue(returnedSource.waitForExistence(timeout: 15))
            app.buttons["更多笔记操作"].tap()
            app.buttons["查看 Markdown 源码"].tap()
            XCTAssertTrue(persistedReader.waitForExistence(timeout: 15))
        } else {
            unaffected.tap()
            let unaffectedConsent = app.alerts["确认不影响原卡？"]
            XCTAssertTrue(unaffectedConsent.waitForExistence(timeout: 12))
            XCTAssertFalse(unaffected.isEnabled,
                "The first tap must lock the repeated no-impact consent itself")
            XCTAssertFalse(editAffected.isEnabled,
                "A competing card editor cannot open while consent is pending")
            unaffectedConsent.buttons["取消"].tap()
            XCTAssertTrue(unaffected.isEnabled && editAffected.isEnabled,
                "Cancellation restores both choices without any side effect")
            unaffected.tap()
            XCTAssertTrue(unaffectedConsent.waitForExistence(timeout: 12))
            unaffectedConsent.buttons["确认不影响"].tap()
            XCTAssertFalse(editAffected.isEnabled,
                "No competing card editor may open during source-digest CAS")
            let unaffectedReceipt = app.alerts["已确认这张原卡不受影响"]
            XCTAssertTrue(unaffectedReceipt.waitForExistence(timeout: 30),
                "Source SHA must be re-read and persisted with the same original card")
            XCTAssertFalse(unaffected.isEnabled,
                "An already-acknowledged source cannot reuse the old approval")
            XCTAssertFalse(editAffected.isEnabled,
                "The original source version must not be edited after CAS")
            unaffectedReceipt.buttons["确定"].tap()
            // The user explicitly switched to Markdown SOURCE mode before
            // reviewing the linked original card. Navigation must preserve that
            // mode on return; the WKWebView is deliberately hidden until the user
            // switches back. Do not mistake this state retention for a failed pop.
            XCTAssertFalse(impact.exists,
                "Successful source acknowledgement must dismiss the impact controller")
            let returnedSource = app.textViews.matching(
                NSPredicate(format: "value CONTAINS %@", "经人工核查")).firstMatch
            XCTAssertTrue(returnedSource.waitForExistence(timeout: 15),
                "Returning to the note must preserve visible source-mode content")
            app.buttons["更多笔记操作"].tap()
            app.buttons["查看 Markdown 源码"].tap()
            XCTAssertTrue(persistedReader.waitForExistence(timeout: 15),
                "Switching the actual note from source mode restores the Markdown reader")
        }
        // Later original-card reveal, FSRS swipe, receipt history and second
        // process restart remain active checks of non-destructive acknowledgement.
        // The real session (and its receipt history) must remain discoverable;
        // opening the source is not permission to upload another message.
        app.buttons["impress.notes.ai-discussion"].tap()
        let features = app.buttons["impress.ai.chat.features"]
        XCTAssertTrue(features.waitForExistence(timeout: 15))
        features.tap()
        // Native pop-up menu, not a pushed feature-list controller.
        let history = app.buttons["历史讨论"]
        XCTAssertTrue(history.waitForExistence(timeout: 15))
        history.tap()
        let sessions = app.tables["impress.ai.chat.history-list"]
        XCTAssertTrue(sessions.waitForExistence(timeout: 15))
        let persistedSession = sessions.cells["impress.ai.chat.history-row"].firstMatch
        XCTAssertTrue(persistedSession.waitForExistence(timeout: 20),
            "Completed discussion must remain in persisted local history")

        // The previous check proved only that *a* row survived. Exercise
        // the actual built-in local history SEARCH to locate the exact original
        // card prompt across note re-entry and process death; a visible row
        // without that message or a new empty note session is not sufficient.
        // This also avoids assuming every unfiltered history row is onscreen.
        let historySearch = app.searchFields.firstMatch
        XCTAssertTrue(historySearch.waitForExistence(timeout: 12),
            "Conversation history must expose native full-text search")
        historySearch.tap()
        historySearch.typeText("请根据所选来源明确推导")
        let exactHistory = sessions.cells.matching(
            identifier: "impress.ai.chat.history-row").matching(
                NSPredicate(format: "label CONTAINS %@", "请根据所选来源明确推导")).firstMatch
        XCTAssertTrue(exactHistory.waitForExistence(timeout: 15),
            "The persisted original card message must be found by real history search")
        exactHistory.tap()
        let restoredQuestion = app.textViews.matching(
            identifier: "impress.ai.chat.message-body").matching(
                NSPredicate(format: "value CONTAINS %@", "请根据所选来源明确推导")).firstMatch
        XCTAssertTrue(restoredQuestion.waitForExistence(timeout: 20),
            "Opening the persisted session must restore the approved original prompt")
        let restoredAnswer = app.textViews.matching(
            identifier: "impress.ai.chat.message-body").matching(
                NSPredicate(format: "value CONTAINS %@", "合成模型回复")).firstMatch
        XCTAssertTrue(restoredAnswer.waitForExistence(timeout: 20),
            "History selection must restore the complete model reply, not just a title")
        let restoredActions = app.buttons["impress.ai.chat.reply-more"].firstMatch
        XCTAssertTrue(restoredActions.waitForExistence(timeout: 15),
            "A cold-restored completed answer must still expose receipt navigation")
        restoredActions.tap()
        let receiptHistoryAction = app.buttons["查看修订记录与逐项回执"]
        XCTAssertTrue(receiptHistoryAction.waitForExistence(timeout: 12),
            "Cold-restored completed reply must retain its audited proposal receipts")
        receiptHistoryAction.tap()
        let savedReceipts = app.tables["impress.duplex.receipt-history"]
        XCTAssertTrue(savedReceipts.waitForExistence(timeout: 15))
        XCTAssertGreaterThanOrEqual(savedReceipts.cells.count, 1,
            "Approval receipts must not be lost while switching source identities")
        savedReceipts.cells.element(boundBy: 0).tap()
        let historicalDetail = app.textViews["impress.duplex.receipt-detail"]
        XCTAssertTrue(historicalDetail.waitForExistence(timeout: 15))
        let preservedFacts = String(describing: historicalDetail.value ?? "")
        XCTAssertTrue(preservedFacts.contains("applied"),
            "The human-approved Markdown write must still be recorded after restart")
        XCTAssertTrue(preservedFacts.contains("reverted"),
            "The card's separate approved undo must not erase the note receipt")
        XCTAssertTrue(preservedFacts.contains("此页为历史回执，不自动重试"),
            "Viewing a historical receipt must never be an implicit retry")
        let historyProof = XCTAttachment(screenshot: app.screenshot())
        historyProof.name = "Impress-V1.1-original-Chat-session-and-dual-CAS-receipt-after-restart"
        historyProof.lifetime = .keepAlways
        add(historyProof)
        app.navigationBars.buttons.element(boundBy: 0).tap()
        app.navigationBars.buttons.element(boundBy: 0).tap()

        // P0-B step 13/18: return from the same persisted Chat session to the
        // same reviewed original card (after approved note edit + card undo).
        // A swipe is the only normal route to an FSRS event, and MUST require
        // a fresh answer reveal. We never grade by calling repository methods.
        // Chat history is several native pushes below the notes root.
        // ImNavigationViewController intentionally hides the TabBar when
        // pushing a secondary screen. Return through REAL visible back
        // controls; do not tap a nonexistent bar or bypass persisted UI state.
        var backSteps = 0
        while !tabs.exists && backSteps < 5 {
            let back = app.navigationBars.buttons.element(boundBy: 0)
            XCTAssertTrue(back.waitForExistence(timeout: 12),
                "History / Chat / document must provide a native return path")
            back.tap()
            backSteps += 1
        }
        XCTAssertTrue(tabs.waitForExistence(timeout: 15),
            "Navigating back to the primary notes screen must restore four Tabs")
        tabs.buttons.element(boundBy: 0).tap()
        let newReveal = app.buttons["impress.review.reveal-answer"]
        XCTAssertTrue(newReveal.waitForExistence(timeout: 30),
            "Original restored card must remain in the actual due queue")
        if reviseSourceAffected {
            let revisedQuestion = app.textViews.matching(
                NSPredicate(format: "value CONTAINS %@", "（来源核查修订）")).firstMatch
            XCTAssertTrue(revisedQuestion.waitForExistence(timeout: 20),
                "The exact manually revised original question must survive process death")
        }
        let guardedActions = app.buttons["impress.review.ai-discussion"]
        XCTAssertFalse(guardedActions.exists,
            "An old Chat/undo cannot silently expose the answer on return")
        newReveal.tap()
        XCTAssertTrue(guardedActions.waitForExistence(timeout: 12),
            "Only an explicitly revealed current answer may enable grading")
        let stack = app.otherElements["impress.review.swipe-stack"]
        XCTAssertTrue(stack.waitForExistence(timeout: 15))
        // Horizontal rating avoids scrolling the revealed long answer.
        stack.swipeRight()
        let completed = app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS %@", "本轮复习完成")).firstMatch
        XCTAssertTrue(completed.waitForExistence(timeout: 30),
            "One visible Tinder swipe must produce a completed FSRS review")
        let rated = XCTAttachment(screenshot: app.screenshot())
        rated.name = "Impress-V1.1-original-card-restored-then-FSRS-scored"
        rated.lifetime = .keepAlways
        add(rated)

        // Restart again without recreating or resetting the same WCDB:
        // graded new card should not be due for a second immediate review.
        app.terminate()
        app.launch()
        XCTAssertTrue(tabs.waitForExistence(timeout: 30))
        tabs.buttons.element(boundBy: 0).tap()
        let noDue = app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS %@", "暂无到期卡片")).firstMatch
        XCTAssertTrue(noDue.waitForExistence(timeout: 30),
            "A restarted session must not re-grade a just-scheduled card")

        if includeRealFilesBackupRestore {
            // Steps 17-18 occur AFTER review, against the SAME fixture ID,
            // WCDB, human-approved note and original Chat history. This test
            // cannot be made green by stitching two independent XCUITests.
            openVisibleBackupSettings(in: app)
            let export = app.cells["impress.backup.export"]
            XCTAssertTrue(export.waitForExistence(timeout: 15))
            export.tap()
            let dismissPredicate = NSPredicate(
                format: "label == %@ OR label == %@ OR label == %@ OR label == %@",
                "取消", "Cancel", "关闭", "Close")
            let systemFiles = XCUIApplication(bundleIdentifier: "com.apple.DocumentsApp")
            let springBoard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
            let dismissInApp = app.buttons.matching(dismissPredicate).firstMatch
            let dismissInFiles = systemFiles.buttons.matching(dismissPredicate).firstMatch
            let dismissInSpringBoard = springBoard.buttons.matching(dismissPredicate).firstMatch
            func realFolderPickerIsVisible() -> Bool {
                // Only genuine, user-interactive system Files controls qualify.
                return dismissInApp.waitForExistence(timeout: 18) ||
                    dismissInFiles.waitForExistence(timeout: 12) ||
                    dismissInSpringBoard.waitForExistence(timeout: 10)
            }
            var filesPickerVisible = realFolderPickerIsVisible()
            if !filesPickerVisible {
                // Hosted iOS 27 may leave a document-provider remote scene
                // inaccessible after repeated synthetic-app cold launches.
                // Preserve an actual failure artifact, then allow ONE full
                // process relaunch of this exact persistent fixture and retry
                // the ordinary Settings -> Files export interaction.
                // Never seed a ZIP or treat a UIKit window as export consent.
                let phaseBeforeRetry = String(describing: export.value ?? "UNAVAILABLE")
                let firstAttempt = XCTAttachment(screenshot: app.screenshot())
                firstAttempt.name = "Impress-V1.1-18-step-first-Files-export-unavailable"
                firstAttempt.lifetime = .keepAlways
                add(firstAttempt)
                XCTAssertFalse(app.alerts["操作未完成"].exists,
                    "An actual backup failure is not a transient Files picker delay. Phase: " +
                    phaseBeforeRetry)
                app.terminate()
                app.launch()
                XCTAssertTrue(tabs.waitForExistence(timeout: 35),
                    "A stalled Files scene must not corrupt same-fixture relaunch")
                tabs.buttons.element(boundBy: 0).tap()
                XCTAssertTrue(noDue.waitForExistence(timeout: 25),
                    "Retry must preserve the genuinely FSRS-graded card, not recreate it")
                openVisibleBackupSettings(in: app)
                let retryExport = app.cells["impress.backup.export"]
                XCTAssertTrue(retryExport.waitForExistence(timeout: 15))
                retryExport.tap()
                filesPickerVisible = realFolderPickerIsVisible()
                XCTAssertTrue(filesPickerVisible,
                    "Both real Files export attempts lacked user-visible controls. " +
                    "First phase: " + phaseBeforeRetry + ", retry phase: " +
                    String(describing: retryExport.value ?? "UNAVAILABLE") +
                    ". App hierarchy: " + String(app.debugDescription.prefix(3500)))
            }
            XCTAssertTrue(chooseRealSystemExportFolder(in: app),
                "Step 17 requires human-visible selection of the actual Files export folder")
            let exported = app.alerts["备份已导出"]
            XCTAssertTrue(exported.waitForExistence(timeout: 35),
                "Step 17 requires an actual verified user-export ZIP receipt")
            exported.buttons["确定"].tap()
            let backToSettings = app.navigationBars.buttons.element(boundBy: 0)
            XCTAssertTrue(backToSettings.waitForExistence(timeout: 12))
            backToSettings.tap()

            openVisibleBackupSettings(in: app)
            let restore = app.cells["impress.backup.restore"]
            XCTAssertTrue(restore.waitForExistence(timeout: 15))
            restore.tap()
            // Import only the ZIP made by the genuine export above, never the
            // independent -restorable fixture used for partial F12 diagnosis.
            selectSyntheticZIPUsingSystemFiles(in: app, fixtureID: id,
                                                exportedByUser: true)
            let approval = app.alerts["确认恢复 Impress 数据？"]
            XCTAssertTrue(approval.waitForExistence(timeout: 40),
                "Step 18 requires the real system picker and checksum-approved ZIP")
            XCTAssertTrue(approval.staticTexts.matching(
                NSPredicate(format: "label CONTAINS %@", "卡片：1 张"))
                .firstMatch.exists,
                "The single original card must remain in this same fixture")
            approval.buttons["确认恢复"].tap()
            let staged = app.alerts["恢复文件已安全暂存"]
            XCTAssertTrue(staged.waitForExistence(timeout: 40),
                "Human approval must durably stage real recovery, not mutate live WCDB")
            staged.buttons["确定"].tap()
            let stagedProof = XCTAttachment(screenshot: app.screenshot())
            stagedProof.name = "Impress-V1.1-single-fixture-18-step-Files-approved-staged"
            stagedProof.lifetime = .keepAlways
            add(stagedProof)

            app.navigationBars.buttons.element(boundBy: 0).tap()
            tabs.buttons.element(boundBy: 0).tap()
            XCTAssertTrue(noDue.waitForExistence(timeout: 20),
                "Staging must not silently regrade the existing FSRS-scheduled card")
            app.terminate()
            app.launch()
            XCTAssertTrue(tabs.waitForExistence(timeout: 35),
                "The real cold launch must apply the verified ZIP transaction")
            tabs.buttons.element(boundBy: 0).tap()
            XCTAssertTrue(noDue.waitForExistence(timeout: 30),
                "The restored WCDB must retain the exact original FSRS schedule")

            // The original approved Markdown must still be attached to this
            // UUID's Vault; a pass on a second synthetic fixture is forbidden.
            tabs.buttons.element(boundBy: 1).tap()
            XCTAssertTrue(folder.waitForExistence(timeout: 25))
            folder.tap()
            XCTAssertTrue(reopened.waitForExistence(timeout: 20))
            reopened.tap()
            XCTAssertTrue(app.webViews["impress.notes.markdown-webview"]
                .waitForExistence(timeout: 25))
            app.buttons["更多笔记操作"].tap()
            app.buttons["查看 Markdown 源码"].tap()
            let sourceAfterRestore = app.textViews.matching(
                NSPredicate(format: "value CONTAINS %@", "经人工核查")).firstMatch
            XCTAssertTrue(sourceAfterRestore.waitForExistence(timeout: 20),
                "The same approved source bytes must survive actual Files ZIP restore")
            let finalProof = XCTAttachment(screenshot: app.screenshot())
            finalProof.name = "Impress-V1.1-single-fixture-18-step-cold-restored-source"
            finalProof.lifetime = .keepAlways
            add(finalProof)
        }
    }


    /// F12 / visible steps 17–18: actual Settings export, system Files ZIP
    /// import, explicit human restore consent and genuine process relaunch.
    /// The only DEBUG hook creates a discoverable COPY of the verified
    /// synthetic export in this app's Files-sharing Documents directory; it
    /// does not bypass UIDocumentPicker, the approval sheet, stageRecovery,
    /// applyPendingAtColdLaunch, WCDB or production write prohibition.
    func testF12VisibleSettingsFilesZIPApprovalRestoresCardAfterColdRestart() throws {
        let app = XCUIApplication()
        let fixtureID = UUID().uuidString
        app.launchArguments = [
            "-ImpressV11SyntheticVault", "-ImpressV11RestorePickerE2E",
            "-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"
        ]
        app.launchEnvironment["IMPRESS_V11_FIXTURE_ID"] = fixtureID
        app.launch()
        let tabs = app.tabBars.firstMatch
        XCTAssertTrue(tabs.waitForExistence(timeout: 30))

        // Create a real reviewed card via Notes → chapter candidate pool →
        // explicit import; do not seed WCDB directly from the UI test.
        tabs.buttons.element(boundBy: 1).tap()
        let folder = app.cells.matching(identifier: "impress.notes.folder-row")
            .matching(NSPredicate(format: "label == %@", "Study")).firstMatch
        XCTAssertTrue(folder.waitForExistence(timeout: 30))
        folder.tap()
        let note = app.cells.matching(identifier: "impress.notes.file-row")
            .matching(NSPredicate(format: "label == %@", "Impress_E2E_Proof")).firstMatch
        XCTAssertTrue(note.waitForExistence(timeout: 20))
        note.tap()
        XCTAssertTrue(app.webViews["impress.notes.markdown-webview"]
            .waitForExistence(timeout: 40))
        app.buttons["更多笔记操作"].tap()
        app.buttons["根据笔记生成卡片"].tap()
        XCTAssertTrue(app.navigationBars["生成综合问题"].waitForExistence(timeout: 15))
        app.navigationBars.buttons["生成"].tap()
        let generation = app.alerts["模拟器合成出题"]
        XCTAssertTrue(generation.waitForExistence(timeout: 15))
        generation.buttons["生成"].tap()
        XCTAssertTrue(app.navigationBars["问题候选池"].waitForExistence(timeout: 20))
        XCTAssertGreaterThanOrEqual(app.tables.cells.count, 2)
        app.tables.cells.element(boundBy: 1).tap()
        let addCard = app.navigationBars.buttons.matching(
            NSPredicate(format: "label BEGINSWITH %@", "加入")).firstMatch
        XCTAssertTrue(addCard.waitForExistence(timeout: 15))
        addCard.tap()
        let importConsent = app.alerts["加入卡片集？"]
        XCTAssertTrue(importConsent.waitForExistence(timeout: 15))
        importConsent.buttons["确认加入"].tap()
        let imported = app.alerts["卡片已添加"]
        XCTAssertTrue(imported.waitForExistence(timeout: 30))
        imported.buttons["完成"].tap()

        tabs.buttons.element(boundBy: 0).tap()
        let reveal = app.buttons["impress.review.reveal-answer"]
        XCTAssertTrue(reveal.waitForExistence(timeout: 30))
        reveal.tap()
        let edit = app.buttons["impress.review.quick-edit"]
        XCTAssertTrue(edit.waitForExistence(timeout: 15))
        edit.tap()
        let composer = app.navigationBars["编辑卡片"]
        XCTAssertTrue(composer.waitForExistence(timeout: 20))
        let question = app.textViews.matching(
            NSPredicate(format: "label == %@", "问题")).firstMatch
        XCTAssertTrue(question.waitForExistence(timeout: 15))
        let originalQuestion = String(describing: question.value ?? "")
        XCTAssertFalse(originalQuestion.isEmpty)
        composer.buttons.element(boundBy: 0).tap() // no-op; no new revision

        // The real Settings export composes a verified ZIP; an explicit DEBUG
        // fixture flag also makes a checksum-identical copy selectable in
        // the app's normal On My iPhone Files container.
        openVisibleBackupSettings(in: app)
        let export = app.cells["impress.backup.export"]
        XCTAssertTrue(export.waitForExistence(timeout: 15))
        export.tap()
        // The actual system Files folder picker must offer a native cancel
        // control. We then explicitly choose a folder and require the ZIP
        // copy-verification receipt before restoring that SAME exported file.
        // No direct coordinator/Files URL injection is permitted by UI tests.
        let systemDismissal = NSPredicate(
            format: "label == %@ OR label == %@ OR label == %@ OR label == %@",
            "取消", "Cancel", "关闭", "Close")
        // On hosted iOS 26/27 the genuine Files remote view may appear in
        // Files instead of the host app's accessibility tree. Check both;
        // never replace the system interaction with a direct coordinator call.
        let dismissInApp = app.buttons.matching(systemDismissal).firstMatch
        let filesApp = XCUIApplication(bundleIdentifier: "com.apple.DocumentsApp")
        let dismissInFiles = filesApp.buttons.matching(systemDismissal).firstMatch
        let dismissInSpringBoard = XCUIApplication(
            bundleIdentifier: "com.apple.springboard").buttons
            .matching(systemDismissal).firstMatch
        let appHasFilesUI = dismissInApp.waitForExistence(timeout: 18)
        let externalFilesUI = !appHasFilesUI &&
            dismissInFiles.waitForExistence(timeout: 12)
        let springBoardUI = !appHasFilesUI && !externalFilesUI &&
            dismissInSpringBoard.waitForExistence(timeout: 10)
        // setUpWithError sets continueAfterFailure=false. An XCTFail here
        // aborts the test immediately, so earlier runs never reached the
        // system restore picker, confirmation, staging, or cold-start checks.
        // Keep export's failure as a FINAL hard assertion while also probing
        // the genuine independent restore UI after a real process restart.
        // This is PARTIAL_E2E diagnosis, never a substitute export success.
        var missingExportDialogFailure: String?
        if !appHasFilesUI && !externalFilesUI && !springBoardUI {
            let evidence = XCTAttachment(screenshot: app.screenshot())
            evidence.name = "Impress-V1.1-F12-export-dialog-or-real-error"
            evidence.lifetime = .keepAlways
            add(evidence)
            let appError = app.alerts["操作未完成"]
            let problem = appError.exists ? appError.debugDescription :
                "no native backup-error alert"
            let exportPhase = String(describing: export.value ?? "UNAVAILABLE")
            missingExportDialogFailure =
                "Real export did not present a dismissible system Files UI. " +
                "QA phase: \(exportPhase). Observed: \(problem). " +
                "App hierarchy: \(app.debugDescription.prefix(5000)). " +
                "Files hierarchy: \(filesApp.debugDescription.prefix(1500))"
            // Recover from the stuck hosted export by killing/reopening the
            // actual app, retaining its verified UUID-scoped fixture ZIP in
            // Documents. The subsequent import must STILL use the real Files
            // picker and explicit restore consent; no direct database API.
            app.terminate()
            app.launch()
            XCTAssertTrue(tabs.waitForExistence(timeout: 35),
                "A hung system export must not corrupt the real app relaunch")
        }
        if missingExportDialogFailure == nil {
            // This must be a genuine system Files selection, not dismissing
            // the export sheet and restoring the fixture's QA-only copy.
            let selected = chooseRealSystemExportFolder(in: app)
            let exported = app.alerts["备份已导出"]
            if !selected || !exported.waitForExistence(timeout: 35) {
                let evidence = XCTAttachment(screenshot: app.screenshot())
                evidence.name = "Impress-V1.1-F12-folder-export-consent-or-verified-copy"
                evidence.lifetime = .keepAlways
                add(evidence)
                missingExportDialogFailure =
                    "Real system folder selection or verified ZIP copy did not complete. " +
                    "QA phase: \(String(describing: export.value ?? "UNAVAILABLE")). " +
                    "Picker hierarchy: \(app.debugDescription.prefix(5000))"
                app.terminate()
                app.launch()
                XCTAssertTrue(tabs.waitForExistence(timeout: 35),
                    "Failed manual Files export must not corrupt app restart")
            } else {
                exported.buttons["确定"].tap()
            }
        }
        if missingExportDialogFailure == nil {
            XCTAssertTrue(export.waitForExistence(timeout: 20))
            app.navigationBars.buttons.element(boundBy: 0).tap()
        }

        // Introduce a legitimate newer card revision *after* snapshot. Only
        // the selected older verified ZIP is permitted to restore the prior
        // version. A UI-only success message would not prove this.
        tabs.buttons.element(boundBy: 0).tap()
        // A successful Files export does not relaunch the app. This same card
        // was explicitly revealed before visiting Settings, so its in-memory
        // revealed state may legitimately survive tab navigation. Earlier
        // failure-path tests relaunched the app, which hid this assumption.
        // Do not grade, recreate or silently substitute a different card.
        let originalReviewStack = app.otherElements["impress.review.swipe-stack"]
        XCTAssertTrue(originalReviewStack.waitForExistence(timeout: 25),
            "A verified Files export must preserve the imported due card")
        if !edit.waitForExistence(timeout: 3) {
            XCTAssertTrue(reveal.waitForExistence(timeout: 15),
                "The original card must be either already revealed or revealable")
            reveal.tap()
        }
        XCTAssertTrue(edit.waitForExistence(timeout: 15),
            "An explicitly revealed original card must still allow native editing")
        edit.tap()
        XCTAssertTrue(composer.waitForExistence(timeout: 20))
        XCTAssertTrue(question.waitForExistence(timeout: 15))
        question.tap()
        for _ in 0..<3 where !app.keyboards.firstMatch.exists {
            question.tap()
        }
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 12),
            "The actual native card editor must accept the later legal revision")
        question.typeText("（备份后的合法新版本）")
        let save = app.buttons["impress.composer.save"]
        XCTAssertTrue(save.waitForExistence(timeout: 15))
        XCTAssertTrue(save.isEnabled)
        save.tap()
        let closed = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == false"), object: composer)
        XCTAssertEqual(XCTWaiter.wait(for: [closed], timeout: 30), .completed)
        let changedQuestion = app.textViews.matching(
            NSPredicate(format: "value CONTAINS %@", "备份后的合法新版本")).firstMatch
        XCTAssertTrue(changedQuestion.waitForExistence(timeout: 20),
            "A later legitimate edit must really be committed before recovery")

        openVisibleBackupSettings(in: app)
        let restore = app.cells["impress.backup.restore"]
        XCTAssertTrue(restore.waitForExistence(timeout: 15))
        restore.tap()
        selectSyntheticZIPUsingSystemFiles(
            in: app, fixtureID: fixtureID,
            exportedByUser: missingExportDialogFailure == nil)
        let approval = app.alerts["确认恢复 Impress 数据？"]
        XCTAssertTrue(approval.waitForExistence(timeout: 40),
            "Only a real picker-selected and verified ZIP may reach consent")
        XCTAssertTrue(approval.staticTexts.matching(
            NSPredicate(format: "label CONTAINS %@", "卡片：1 张"))
            .firstMatch.exists, "Verified ZIP preview must report one card")
        approval.buttons["确认恢复"].tap()
        let staged = app.alerts["恢复文件已安全暂存"]
        XCTAssertTrue(staged.waitForExistence(timeout: 40))
        staged.buttons["确定"].tap()
        let pendingProof = XCTAttachment(screenshot: app.screenshot())
        pendingProof.name = "Impress-V1.1-F12-real-Files-consent-and-pending"
        pendingProof.lifetime = .keepAlways
        add(pendingProof)
        // Staging is never an in-process database replacement. The newer
        // legal revision must remain visible until the NEXT actual launch.
        app.navigationBars.buttons.element(boundBy: 0).tap()
        tabs.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(changedQuestion.waitForExistence(timeout: 20),
            "Pending recovery must not overwrite the running WCDB before relaunch")

        app.terminate()
        app.launch()
        XCTAssertTrue(tabs.waitForExistence(timeout: 35),
            "The real cold launch must apply the staged transactional restore")
        tabs.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(reveal.waitForExistence(timeout: 30),
            "A restored card must be due, without any implicit FSRS scoring")
        reveal.tap()
        XCTAssertTrue(edit.waitForExistence(timeout: 15))
        edit.tap()
        XCTAssertTrue(composer.waitForExistence(timeout: 20))
        XCTAssertTrue(question.waitForExistence(timeout: 15))
        XCTAssertEqual(String(describing: question.value ?? ""), originalQuestion,
            "Real ZIP restore must recover exact pre-edit card content, not a stale UI")
        let reopenedProof = XCTAttachment(screenshot: app.screenshot())
        reopenedProof.name = "Impress-V1.1-F12-actual-cold-reopened-WCDB-card"
        reopenedProof.lifetime = .keepAlways
        add(reopenedProof)
        // A real restore PASS does not erase the export UI failure: both
        // must pass in one uninterrupted 18-step release acceptance run.
        if let missingExportDialogFailure {
            XCTFail(missingExportDialogFailure +
                " The separately observed Files import/approval/cold restore " +
                "must be recorded as PARTIAL_E2E only.")
        }
    }

    /// A genuine four-Tab Settings visit. Backup is in the LAST grouped
    /// section and offscreen at iPhone simulator heights: UITableView need not
    /// expose an uninstantiated cell until it has been scrolled into view.
    /// Never substitute a direct controller instantiation for visible UI.
    private func openVisibleBackupSettings(in app: XCUIApplication) {
        let tabBar = app.tabBars.firstMatch
        XCTAssertTrue(tabBar.waitForExistence(timeout: 20))
        tabBar.buttons.element(boundBy: 3).tap()
        XCTAssertTrue(app.navigationBars["设置"].waitForExistence(timeout: 15))
        let table = app.tables.firstMatch
        XCTAssertTrue(table.waitForExistence(timeout: 15))
        let backup = app.cells["impress.settings.backup"]
        for _ in 0..<6 where !backup.isHittable {
            table.swipeUp()
        }
        XCTAssertTrue(backup.waitForExistence(timeout: 10),
            "The real last-section backup destination must exist after scrolling")
        XCTAssertTrue(backup.isHittable,
            "The visible backup destination must accept a real accessibility tap")
        backup.tap()
        XCTAssertTrue(app.navigationBars["数据与备份"].waitForExistence(timeout: 15))
    }

    /// Real system Files folder authorization, not a QA-supplied destination.
    /// A successful export must be selected in On My iPhone / miemie. The
    /// fallback restore-only ZIP never counts as exported-by-user evidence.
    private func chooseRealSystemExportFolder(in app: XCUIApplication) -> Bool {
        let browse = app.buttons.matching(NSPredicate(
            format: "label == %@ OR label == %@", "浏览", "Browse")).firstMatch
        if browse.waitForExistence(timeout: 5) { browse.tap() }
        let onDevice = NSPredicate(
            format: "label CONTAINS %@ OR label CONTAINS %@",
            "我的 iPhone", "On My iPhone")
        let deviceCell = app.cells.matching(onDevice).firstMatch
        let deviceButton = app.buttons.matching(onDevice).firstMatch
        if deviceCell.waitForExistence(timeout: 8) {
            deviceCell.tap()
        } else if deviceButton.waitForExistence(timeout: 5) {
            deviceButton.tap()
        }
        let folderName = NSPredicate(format: "label == %@", "miemie")
        let folderCell = app.cells.matching(folderName).firstMatch
        let folderButton = app.buttons.matching(folderName).firstMatch
        let folderText = app.staticTexts.matching(folderName).firstMatch
        if folderCell.waitForExistence(timeout: 8) {
            folderCell.tap()
        } else if folderButton.waitForExistence(timeout: 5) {
            folderButton.tap()
        } else if folderText.waitForExistence(timeout: 5) {
            folderText.tap()
        } else {
            // Don't silently select some other provider or unrelated folder.
            return false
        }
        // Some iOS Files versions treat a folder tap as the final user
        // selection; only a confirmed real copy makes this a success.
        if app.alerts["备份已导出"].waitForExistence(timeout: 3) {
            return true
        }
        let accept = app.buttons.matching(NSPredicate(
            format: "label == %@ OR label == %@ OR label == %@ OR label == %@ " +
                    "OR label == %@ OR label == %@ OR label == %@ OR label == %@",
            "打开", "Open", "选择", "Select", "选取", "Choose",
            "选择文件夹", "Choose Folder")).firstMatch
        guard accept.waitForExistence(timeout: 12), accept.isHittable else {
            return false
        }
        accept.tap()
        return true
    }

    /// Use the real iOS document browser. This helper only locates a generated
    /// file through accessibility; it never calls a repository/restore API.
    /// When export succeeded, require the DISTINCT user-exported file: the
    /// synthetic recovery-only copy is not a substitute for user Files export.
    private func selectSyntheticZIPUsingSystemFiles(
        in app: XCUIApplication, fixtureID: String,
        exportedByUser: Bool = false
    ) {
        let wanted = fixtureID +
            (exportedByUser ? "-user-export" : "-restorable")
        let selected = NSPredicate(format: "label CONTAINS %@", wanted)
        let archive = app.cells.matching(selected).firstMatch
        if !archive.waitForExistence(timeout: 10) {
            // Real UIDocumentPicker can reopen in Recents or Locations. Enter
            // Browse, then On My iPhone, without replacing the system picker.
            let browse = app.buttons.matching(NSPredicate(
                format: "label == %@ OR label == %@", "浏览", "Browse")).firstMatch
            if browse.waitForExistence(timeout: 5) { browse.tap() }
            let onDevice = NSPredicate(
                format: "label CONTAINS %@ OR label CONTAINS %@",
                "我的 iPhone", "On My iPhone")
            let deviceCell = app.cells.matching(onDevice).firstMatch
            let deviceButton = app.buttons.matching(onDevice).firstMatch
            if deviceCell.waitForExistence(timeout: 8) {
                deviceCell.tap()
            } else if deviceButton.waitForExistence(timeout: 5) {
                deviceButton.tap()
            }
            if !archive.waitForExistence(timeout: 5) {
                // The shipped Info.plist uses CFBundleDisplayName="miemie",
                // rather than "Impress": Files uses the app's display name.
                // Retain legacy names; select only the exact UUID-scoped ZIP.
                let appFolderName = NSPredicate(
                    format: "label == %@ OR label == %@ OR label == %@",
                    "miemie", "Impress", "Impress-iPhone")
                let folderCell = app.cells.matching(appFolderName).firstMatch
                let folderButton = app.buttons.matching(appFolderName).firstMatch
                let folderText = app.staticTexts.matching(appFolderName).firstMatch
                if folderCell.waitForExistence(timeout: 8) {
                    folderCell.tap()
                } else if folderButton.waitForExistence(timeout: 5) {
                    folderButton.tap()
                } else if folderText.waitForExistence(timeout: 5) {
                    folderText.tap()
                }
            }
        }
        let fileText = app.staticTexts.matching(selected).firstMatch
        let exactZIPVisible = archive.waitForExistence(timeout: 15) ||
            fileText.waitForExistence(timeout: 5)
        if !exactZIPVisible {
            let evidence = XCTAttachment(screenshot: app.screenshot())
            evidence.name = "Impress-V1.1-F12-real-system-Files-import-missing-UUID"
            evidence.lifetime = .keepAlways
            add(evidence)
        }
        XCTAssertTrue(exactZIPVisible,
            "System Files must expose the exact UUID-scoped ZIP, not another backup. " +
            "Host picker AX: \(app.debugDescription.prefix(6000))")
        if archive.exists { archive.tap() } else if fileText.exists { fileText.tap() }
    }

    private func tapVisible(_ element: XCUIElement, in app: XCUIApplication) {
        let scroll = app.scrollViews["impress.duplex.change-scroll"]
        for _ in 0..<8 where !element.isHittable {
            if scroll.exists { scroll.swipeUp() } else { app.swipeUp() }
        }
        XCTAssertTrue(element.isHittable)
        element.tap()
    }

    private func validateNativeTabNavigation(in app: XCUIApplication,
                                              capture: Bool) throws {
        let bar = app.tabBars.firstMatch
        XCTAssertTrue(bar.waitForExistence(timeout: 30),
            "App should show the native four-tab shell, not a database error")
        XCTAssertEqual(bar.buttons.count, 4,
            "The agreed primary tabs are Flashcard, Notes, Calibration and Settings")
        for index in 0..<4 {
            let destination = bar.buttons.element(boundBy: index)
            XCTAssertTrue(destination.isHittable, "Tab \(index) must be tappable")
            destination.tap()
            XCTAssertTrue(bar.exists, "Tab bar must remain visible after navigation")
            if capture {
                let screenshot = XCTAttachment(screenshot: app.screenshot())
                screenshot.name = "Impress-V1.1-primary-tab-\(index)"
                screenshot.lifetime = .keepAlways
                add(screenshot)
            }
        }
    }
}
