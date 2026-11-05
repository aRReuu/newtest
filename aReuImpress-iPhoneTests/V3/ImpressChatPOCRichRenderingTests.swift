import XCTest
import UIKit
import WebKit
import Darwin
import ImpressReviewCore
@testable import aReuImpress_iPhone

/// Native Debug test host, disposable data only. Does not touch user chats.
@MainActor
final class ImpressChatPOCRichRenderingTests: XCTestCase {
    func testCodeHasSelectionAndCopiesActualBodyNotFences() throws {
        let cell = ImpressChatPOCStructuredCell(
            frame: CGRect(x: 0, y: 0, width: 320, height: 240))
        let source = "~~~swift\nlet task = \"学习\"\nprint(task)\n~~~"
        cell.configure(markdown: source, kind: .code, stable: true)
        cell.layoutIfNeeded()
        XCTAssertEqual(cell.accessibilityIdentifier, "impress.chat.poc.code")
        let controls = descendants(of: cell, as: UIButton.self)
        let copy = try XCTUnwrap(controls.first {
            $0.accessibilityIdentifier == "impress.chat.poc.content-copy"
        })
        copy.sendActions(for: .touchUpInside)
        XCTAssertEqual(UIPasteboard.general.string, "let task = \"学习\"\nprint(task)")
        let editor = try XCTUnwrap(descendants(of: cell, as: UITextView.self).first)
        XCTAssertTrue(editor.isSelectable)
        XCTAssertFalse(editor.isEditable)
        XCTAssertTrue(editor.attributedText.string.contains("print(task)"))
    }

    func testTableUsesRealGridAndHorizontalScroller() throws {
        let cell = ImpressChatPOCStructuredCell(
            frame: CGRect(x: 0, y: 0, width: 300, height: 260))
        let table = "| 较长的标题栏目 | 状态 | 来源 |\n" +
            "| --- | --- | --- |\n" +
            "| Markdown 内容 | 完成 | Offline Fixture |\n" +
            "| GFM 表格 | 已批准 | Local source |"
        cell.configure(markdown: table, kind: .table, stable: true)
        cell.layoutIfNeeded()
        XCTAssertEqual(cell.accessibilityIdentifier, "impress.chat.poc.table")
        let grid = try XCTUnwrap(descendants(of: cell, as: UIStackView.self)
            .first(where: { $0.arrangedSubviews.count == 3 }))
        XCTAssertEqual(grid.arrangedSubviews.count, 3,
                       "GFM delimiter must not become a data row")
        XCTAssertTrue(descendants(of: cell, as: UILabel.self)
            .contains { $0.text == "Offline Fixture" })
        let copy = try XCTUnwrap(descendants(of: cell, as: UIButton.self).first {
            $0.accessibilityIdentifier == "impress.chat.poc.content-copy"
        })
        copy.sendActions(for: .touchUpInside)
        XCTAssertEqual(UIPasteboard.general.string, table)
    }

    func testProductionGFMTableRetainsLongCellsAndLiteralWindowsPaths() throws {
        let cell = ImpressChatPOCStructuredCell(
            frame: CGRect(x: 0, y: 0, width: 310, height: 540))
        let windowsPath = #"C:\Notes\Projects\drawing.md"#
        let longValue = String(repeating: "长内容需要完整显示并支持纵向滚动。", count: 150)
        let source = "| 字段 | 值 |\n| --- | --- |\n" +
            "| 路径 | " + windowsPath + " |\n" +
            "| 管道 | alpha\\|beta |\n" +
            "| 说明 | " + longValue + " |"
        cell.configure(markdown: source, kind: .table, stable: true)
        cell.layoutIfNeeded()
        let labels = descendants(of: cell, as: UILabel.self)
        XCTAssertTrue(labels.contains { $0.text == windowsPath },
            "A literal Windows path must not lose its backslashes")
        XCTAssertTrue(labels.contains { $0.text == "alpha|beta" },
            "Only escaped separators should be unescaped")
        let longLabel = try XCTUnwrap(labels.first { $0.text == longValue })
        XCTAssertEqual(longLabel.numberOfLines, 0,
            "Long GFM table cells must not silently truncate at three lines")
        let scroll = try XCTUnwrap(descendants(of: cell, as: UIScrollView.self).first)
        XCTAssertTrue(scroll.showsVerticalScrollIndicator,
            "Tall cells need a vertical scroll range even with few rows")
        let copy = try XCTUnwrap(descendants(of: cell, as: UIButton.self).first {
            $0.accessibilityIdentifier == "impress.chat.poc.content-copy"
        })
        copy.sendActions(for: .touchUpInside)
        XCTAssertEqual(UIPasteboard.general.string, source,
            "Source copying must preserve all original Markdown escapes")

        // Reused collection cells cannot retain the previous tall-scroll state.
        cell.configure(markdown: "| Key | Value |\n| --- | --- |\n| A | B |",
                       kind: .table, stable: true)
        XCTAssertFalse(scroll.showsVerticalScrollIndicator)
        XCTAssertFalse(descendants(of: cell, as: UILabel.self).contains {
            $0.text == longValue
        })
    }

    func testWindowsCRLFCodeSelectionAndGFMTableProjection() throws {
        let code = ImpressChatPOCStructuredCell(
            frame: CGRect(x: 0, y: 0, width: 310, height: 250))
        code.configure(markdown: "~~~swift\r\nlet x = \"中文\"\r\n~~~",
                       kind: .code, stable: true)
        code.layoutIfNeeded()
        let editor = try XCTUnwrap(descendants(of: code, as: UITextView.self).first)
        XCTAssertEqual(editor.text, "let x = \"中文\"")
        let copy = try XCTUnwrap(descendants(of: code, as: UIButton.self).first {
            $0.accessibilityIdentifier == "impress.chat.poc.content-copy"
        })
        copy.sendActions(for: .touchUpInside)
        XCTAssertEqual(UIPasteboard.general.string, "let x = \"中文\"")

        let grid = ImpressChatPOCStructuredCell(
            frame: CGRect(x: 0, y: 0, width: 300, height: 200))
        let source = "| 条目 | 状态 |\r\n| --- | --- |\r\n| 中文 | 通过 |"
        grid.configure(markdown: source, kind: .table, stable: true)
        grid.layoutIfNeeded()
        XCTAssertTrue(descendants(of: grid, as: UILabel.self).contains {
            $0.text == "通过"
        }, "A CRLF GFM table must render cells, not raw source")
        let gridCopy = try XCTUnwrap(descendants(of: grid, as: UIButton.self).first {
            $0.accessibilityIdentifier == "impress.chat.poc.content-copy"
        })
        gridCopy.sendActions(for: .touchUpInside)
        XCTAssertEqual(UIPasteboard.general.string, source,
                       "The copy action retains original GFM source line endings")
    }

    func testMathEngineIsOfflineLocalAndHasCopyFallback() throws {
        let resource = try XCTUnwrap(Bundle.main.url(
            forResource: "index", withExtension: "html",
            subdirectory: "MarkdownReader"))
        XCTAssertTrue(resource.isFileURL)
        let cell = ImpressChatPOCMathCell(
            frame: CGRect(x: 0, y: 0, width: 390, height: 210))
        let source = "$$\n\\frac{1}{2} + \\sqrt{4}\n$$"
        cell.configure(source, stable: true)
        cell.layoutIfNeeded()
        let math = try XCTUnwrap(descendants(of: cell, as: WKWebView.self).first)
        XCTAssertEqual(math.accessibilityIdentifier, "impress.chat.poc.math-katex")
        XCTAssertEqual(math.scrollView.isScrollEnabled, false)
        let copy = try XCTUnwrap(descendants(of: cell, as: UIButton.self).first {
            $0.accessibilityIdentifier == "impress.chat.poc.math-copy"
        })
        copy.sendActions(for: .touchUpInside)
        XCTAssertEqual(UIPasteboard.general.string, source)
    }

    func testMathActuallyCreatesOfflineKaTeXDOMBeforeHidingTextFallback() throws {
        let cell = ImpressChatPOCMathCell(
            frame: CGRect(x: 0, y: 0, width: 390, height: 210))
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 220))
        let root = UIViewController()
        window.rootViewController = root
        root.view.addSubview(cell)
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        let formula = "$$\n\\frac{1}{2}+\\sqrt{4}\n$$"
        cell.configure(formula, stable: false)
        let web = try XCTUnwrap(descendants(of: cell, as: WKWebView.self).first)
        let cover = try XCTUnwrap(descendants(of: cell, as: UIView.self)
            .first(where: { $0.accessibilityIdentifier ==
                "impress.chat.poc.math-fallback-cover" }))
        XCTAssertFalse(cover.isHidden,
            "Provisional math must keep the opaque selectable fallback visible")
        cell.configure(formula, stable: true)
        let appears = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            cover.isHidden
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [appears], timeout: 25), .completed,
                       "Fallback may disappear only after real offline KaTeX DOM verification")
        let verified = expectation(description: "Real offline KaTeX node")
        web.evaluateJavaScript("document.querySelectorAll('.katex').length") {
            value, error in
            XCTAssertNil(error)
            XCTAssertGreaterThan((value as? NSNumber)?.intValue ?? 0, 0)
            verified.fulfill()
        }
        wait(for: [verified], timeout: 5)
        cell.configure("not a formula", stable: false)
        XCTAssertFalse(cover.isHidden,
                      "Cell reuse must cover stale mathematical rendering")
        XCTAssertEqual(cell.accessibilityLabel, "公式：not a formula")
    }

    func testProductionTranscriptUsesRealDiffableBlocksAndRetainsPartialState() throws {
        let viewport = ImpressChatProductionTranscript(
            frame: CGRect(x: 0, y: 0, width: 390, height: 700))
        let list = try XCTUnwrap(descendants(of: viewport, as: UICollectionView.self).first)
        XCTAssertEqual(list.accessibilityIdentifier, "impress.ai.chat.transcript")
        let userID = UUID()
        let assistantID = UUID()
        let question = WCDBV3ChatMessage(
            messageID: userID, role: .user, text: "解释可验证的假设", status: .completed)
        var answer = WCDBV3ChatMessage(
            messageID: assistantID, role: .assistant,
            text: "# 标题\n\n首段", status: .pending)
        viewport.update([question, answer])
        let started = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in list.numberOfItems(inSection: 0) >= 4 },
            object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [started], timeout: 8), .completed,
            "A real production message must be split into user, Markdown and stream rows")

        answer.text += "\n\n~~~swift\nlet n = 1\n~~~"
        viewport.update([question, answer])
        let appended = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in list.numberOfItems(inSection: 0) >= 5 },
            object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [appended], timeout: 8), .completed)
        answer.status = .failed
        viewport.update([question, answer])
        let retained = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in list.numberOfItems(inSection: 0) >= 5 },
            object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [retained], timeout: 8), .completed,
            "A failed stream retains code and partial text instead of discarding them")
    }

    func testColdRestoredFailedAnswerKeepsUnfinishedGFMTableProvisional() throws {
        let viewport = ImpressChatProductionTranscript(
            frame: CGRect(x: 0, y: 0, width: 390, height: 700))
        let window = UIWindow(frame: viewport.bounds)
        let root = UIViewController()
        window.rootViewController = root
        root.view.addSubview(viewport)
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        let list = try XCTUnwrap(descendants(of: viewport, as: UICollectionView.self).first)
        let assistant = WCDBV3ChatMessage(
            messageID: UUID(), role: .assistant,
            text: "| Name | Result |\n| --- | --- |\n| Chinese | part",
            status: .failed)
        viewport.update([assistant])
        viewport.layoutIfNeeded()
        let appeared = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            viewport.layoutIfNeeded()
            return list.visibleCells.contains { $0 is ImpressChatPOCStructuredCell }
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [appeared], timeout: 8), .completed)
        let table = try XCTUnwrap(list.visibleCells
            .compactMap { $0 as? ImpressChatPOCStructuredCell }.first)
        XCTAssertTrue(descendants(of: table, as: UILabel.self)
            .contains { $0.text == "表格 · 生成中" },
            "Cold-restored unfinished Markdown must not masquerade as a complete table")
        XCTAssertFalse(list.visibleCells.contains {
            $0.accessibilityIdentifier == "impress.ai.chat.reply-more"
        }, "Failed replies cannot expose completed-answer operations")
    }

    func testProductionTranscriptActualLargeMarkdownLayoutsStayAddressable() throws {
        // 1/16/64 KB of completed mixed Markdown must reach real UIKit rows,
        // including a bounded scrolling code cell. Logs are simulator-only.
        for targetBytes in [1_024, 16_384, 65_536] {
            let unit = "let 中文 = \"🧠\" // syntax + Unicode\n"
            let code = String(repeating: unit,
                              count: max(1, targetBytes / unit.utf8.count))
            let markdown = "# 流式完成\n\n正文 **强调**。\n\n~~~swift\n" + code +
                "~~~\n\n| Key | State |\n| --- | --- |\n| Done | Yes |\n\n" +
                "$$\nE=mc^2\n$$"
            let viewport = ImpressChatProductionTranscript(
                frame: CGRect(x: 0, y: 0, width: 390, height: 680))
            let window = UIWindow(frame: viewport.bounds)
            let root = UIViewController()
            window.rootViewController = root
            root.view.addSubview(viewport)
            window.makeKeyAndVisible()
            let list = try XCTUnwrap(descendants(
                of: viewport, as: UICollectionView.self).first)
            let response = WCDBV3ChatMessage(messageID: UUID(),
                role: .assistant, text: markdown, status: .completed)
            let start = CFAbsoluteTimeGetCurrent()
            viewport.update([response])
            let applied = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
                viewport.layoutIfNeeded()
                return list.numberOfItems(inSection: 0) >= 5
            }, object: nil)
            let result = XCTWaiter.wait(for: [applied], timeout: 25)
            let elapsed = Int((CFAbsoluteTimeGetCurrent() - start) * 1_000)
            print("CHAT_SIMULATOR_RICH_RESPONSE source_bytes=\(markdown.utf8.count)" +
                  " target_bytes=\(targetBytes)" +
                  " blocks=\(list.numberOfItems(inSection: 0))" +
                  " elapsed_ms=\(elapsed) platform=simulator")
            XCTAssertEqual(result, .completed,
                "A real response must retain code, GFM, KaTeX and operation rows")
            XCTAssertGreaterThanOrEqual(list.numberOfItems(inSection: 0), 5)
            window.isHidden = true
        }
    }

    func testProductionTranscriptEmptyHistoryCommitsInitialSection() throws {
        // Regression: an empty first update must still install the section.
        // This is a real UIKit/Diffable transaction, not a parser-only check.
        let viewport = ImpressChatProductionTranscript(
            frame: CGRect(x: 0, y: 0, width: 390, height: 700))
        let window = UIWindow(frame: viewport.bounds)
        let root = UIViewController()
        window.rootViewController = root
        root.view.addSubview(viewport)
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        let collection = try XCTUnwrap(
            descendants(of: viewport, as: UICollectionView.self).first)
        viewport.update([])
        let applied = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            collection.numberOfSections == 1
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [applied], timeout: 8), .completed)
        XCTAssertEqual(collection.numberOfItems(inSection: 0), 0)
    }

    func testSwitchingChatSessionsRestoresOwnHistoryAnchorWithoutCrossSessionJump() throws {
        // Real UICollectionView snapshots with independent WCDB message IDs.
        // A session switch cannot inherit the former conversation's top offset.
        let viewport = ImpressChatProductionTranscript(
            frame: CGRect(x: 0, y: 0, width: 390, height: 700))
        let window = UIWindow(frame: viewport.bounds)
        let root = UIViewController()
        window.rootViewController = root
        root.view.addSubview(viewport)
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        let collection = try XCTUnwrap(
            descendants(of: viewport, as: UICollectionView.self).first)
        let firstID = UUID(), secondID = UUID()
        func fixture(_ prefix: String) -> [WCDBV3ChatMessage] {
            (0..<120).map { index in
                WCDBV3ChatMessage(messageID: UUID(), role: .user,
                    text: "\(prefix)-\(index)", status: .completed)
            }
        }
        let first = fixture("FIRST"), second = fixture("SECOND")
        func shows(_ token: String) -> Bool {
            viewport.layoutIfNeeded()
            return collection.visibleCells
                .flatMap { descendants(of: $0, as: UITextView.self) }
                .contains { $0.text == token }
        }
        func assertVisible(_ token: String) {
            let expectation = XCTNSPredicateExpectation(
                predicate: NSPredicate { _, _ in shows(token) }, object: nil)
            XCTAssertEqual(XCTWaiter.wait(for: [expectation], timeout: 12),
                .completed, "The active transcript must display \(token)")
        }
        viewport.activateConversation(firstID)
        viewport.update(first)
        assertVisible("FIRST-119")

        // Simulate the result of a real user history drag via the delegate:
        // the archived visible row and relative viewport offset are authoritative.
        viewport.scrollViewWillBeginDragging(collection)
        collection.scrollToItem(at: IndexPath(item: 8, section: 0),
                                at: .top, animated: false)
        viewport.layoutIfNeeded()
        viewport.scrollViewDidEndDragging(collection, willDecelerate: false)
        let oldTop = try XCTUnwrap(collection.indexPathsForVisibleItems.min()?.item)
        XCTAssertLessThan(oldTop, 20)

        viewport.activateConversation(secondID)
        viewport.update(second)
        assertVisible("SECOND-119")
        XCTAssertGreaterThan(try XCTUnwrap(
            collection.indexPathsForVisibleItems.min()?.item), 95,
            "A new conversation should follow its own latest message")

        viewport.activateConversation(firstID)
        viewport.update(first)
        let returned = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in
                viewport.layoutIfNeeded()
                return shows("FIRST-8") &&
                    (collection.indexPathsForVisibleItems.min()?.item ?? 120) < 20
            }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [returned], timeout: 12), .completed,
            "Returning to a prior conversation restores its history reading anchor")
        let restoredTop = try XCTUnwrap(collection.indexPathsForVisibleItems.min()?.item)
        XCTAssertLessThanOrEqual(abs(restoredTop - oldTop), 3)

        // The second conversation retains its own bottom-follow position.
        viewport.activateConversation(secondID)
        viewport.update(second)
        assertVisible("SECOND-119")
    }

    func testProductionTranscriptScaleLogsActualSimulatorLoadTime() throws {
        // Genuine UIKit/Diffable transactions, not parser counters. Values
        // are measured in the CI simulator; no iPhone13 FPS claim follows.
        func resourceSample() -> (cpuMilliseconds: Double, peakRSSMiB: Double)? {
            var usage = rusage()
            // RUSAGE_SELF is 0 on Darwin. Sample actual process CPU time and
            // lifetime peak resident bytes; neither is device FPS or layout time.
            guard getrusage(0, &usage) == 0 else { return nil }
            let user = Double(usage.ru_utime.tv_sec) * 1_000 +
                Double(usage.ru_utime.tv_usec) / 1_000
            let kernel = Double(usage.ru_stime.tv_sec) * 1_000 +
                Double(usage.ru_stime.tv_usec) / 1_000
            return (user + kernel, Double(usage.ru_maxrss) / (1024 * 1024))
        }
        for messageCount in [0, 100, 1_000, 5_000] {
            // NSLog flushes even if the simulator kills a pathological load.
            // This separates the data-source phase from the actual layout
            // without weakening the 5,000-message coverage or its assertions.
            NSLog("CHAT_SCALE_BEGIN messages=%d", messageCount)
            let viewport = ImpressChatProductionTranscript(
                frame: CGRect(x: 0, y: 0, width: 390, height: 700))
            let window = UIWindow(frame: viewport.bounds)
            let root = UIViewController()
            window.rootViewController = root
            root.view.addSubview(viewport)
            window.makeKeyAndVisible()
            viewport.layoutIfNeeded()
            let collection = try XCTUnwrap(
                descendants(of: viewport, as: UICollectionView.self).first)
            let messages: [WCDBV3ChatMessage] = (0..<messageCount).map { index in
                WCDBV3ChatMessage(messageID: UUID(), role: .user,
                    text: "Question \(index) 中文 🧠", status: .completed)
            }
            let baseline = resourceSample()
            let start = CFAbsoluteTimeGetCurrent()
            viewport.update(messages)
            NSLog("CHAT_SCALE_APPLY_REQUESTED messages=%d", messageCount)
            let applied = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
                return collection.numberOfSections > 0 &&
                    collection.numberOfItems(inSection: 0) == messageCount
            }, object: nil)
            // A repeated layoutIfNeeded inside this polling predicate caused
            // thousands of full-pass layouts; measure one visible layout after
            // the actual snapshot has committed instead.
            let outcome = XCTWaiter.wait(for: [applied], timeout: 25)
            NSLog("CHAT_SCALE_APPLY_FINISHED messages=%d result=%d",
                  messageCount, outcome.rawValue)
            let firstLayoutStart = CFAbsoluteTimeGetCurrent()
            if outcome == .completed { viewport.layoutIfNeeded() }
            let firstLayoutMilliseconds =
                (CFAbsoluteTimeGetCurrent() - firstLayoutStart) * 1_000
            let elapsed = (CFAbsoluteTimeGetCurrent() - start) * 1_000
            let measured = resourceSample()
            let cpuDelta = (measured?.cpuMilliseconds ?? 0) -
                (baseline?.cpuMilliseconds ?? 0)
            print("CHAT_SIMULATOR_TRANSCRIPT_LOAD messages=\(messageCount)" +
                  " rows=\(collection.numberOfItems(inSection: 0))" +
                  " elapsed_ms=\(Int(elapsed))" +
                  " initial_visible_layout_ms=\(Int(firstLayoutMilliseconds))" +
                  " cpu_ms=\(Int(cpuDelta))" +
                  " peak_process_rss_mib=\(Int(measured?.peakRSSMiB ?? 0))" +
                  " platform=simulator")
            XCTAssertEqual(outcome, .completed,
                "Real collection must load all \(messageCount) distinct messages")
            XCTAssertEqual(collection.numberOfItems(inSection: 0), messageCount)
            if messageCount == 5_000 {
                // Real 5,000-row diffable viewport: short SSE text changes
                // must not reconstruct every immutable historic row.
                var tailUpdate = messages
                tailUpdate[messageCount - 1].text += " streamed 中文 🧠"
                let oldFull = viewport.qaFullArchiveReconstructions
                let oldTail = viewport.qaTailOnlyReconfigurations
                viewport.update(tailUpdate)
                let incremental = XCTNSPredicateExpectation(
                    predicate: NSPredicate { _, _ in
                        viewport.qaTailOnlyReconfigurations > oldTail
                    }, object: nil)
                XCTAssertEqual(XCTWaiter.wait(for: [incremental], timeout: 8),
                               .completed)
                XCTAssertEqual(viewport.qaFullArchiveReconstructions, oldFull)
                // Editing an early persisted turn must invalidate the fast path.
                var oldTurnChanged = tailUpdate
                oldTurnChanged[0].text = "Revised earlier source 中文 🧠"
                viewport.update(oldTurnChanged)
                let fullRefresh = XCTNSPredicateExpectation(
                    predicate: NSPredicate { _, _ in
                        viewport.qaFullArchiveReconstructions > oldFull
                    }, object: nil)
                XCTAssertEqual(XCTWaiter.wait(for: [fullRefresh], timeout: 8),
                               .completed)
                XCTAssertEqual(collection.numberOfItems(inSection: 0), messageCount)
            }
            window.isHidden = true
        }
    }

    func testProductionActionsStayBoundToCorrectReplyAfterDiffableReuse() throws {
        let viewport = ImpressChatProductionTranscript(
            frame: CGRect(x: 0, y: 0, width: 390, height: 580))
        let window = UIWindow(frame: viewport.bounds)
        let root = UIViewController()
        window.rootViewController = root
        root.view.addSubview(viewport)
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        let collection = try XCTUnwrap(descendants(of: viewport, as: UICollectionView.self).first)
        viewport.menuForMessage = { id in
            UIMenu(children: [UIAction(title: id.uuidString, handler: { _ in })])
        }
        let first = WCDBV3ChatMessage(messageID: UUID(),
            role: .assistant, text: "第一条完整答案", status: .completed)
        let second = WCDBV3ChatMessage(messageID: UUID(),
            role: .assistant, text: "第二条独立回复", status: .completed)

        func assertReply(_ message: WCDBV3ChatMessage) throws {
            viewport.update([message])
            // A diffable snapshot may commit while the previous reply footer
            // remains offscreen. Assert that the *exact* stable actions row is
            // present, then make that row visible before testing its live
            // buttons; never mistake an unrelated reused cell for this reply.
            let actionRowID = "actions-" + message.messageID.uuidString
            let ready = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
                viewport.layoutIfNeeded()
                guard let source = collection.dataSource
                        as? UICollectionViewDiffableDataSource<Int, String>,
                      let index = source.indexPath(for: actionRowID),
                      index.section < collection.numberOfSections,
                      index.item < collection.numberOfItems(inSection: index.section)
                else { return false }
                if !collection.indexPathsForVisibleItems.contains(index) {
                    collection.scrollToItem(at: index, at: .bottom, animated: false)
                    viewport.layoutIfNeeded()
                }
                return collection.visibleCells.contains {
                    $0 is ImpressChatReplyActionsCell &&
                    $0.accessibilityValue == message.messageID.uuidString
                }
            }, object: nil)
            let outcome = XCTWaiter.wait(for: [ready], timeout: 15)
            XCTAssertEqual(outcome, .completed,
                "Expected visible footer bound to \(actionRowID); an offscreen " +
                "or different reply must not satisfy the Copy/More verification")
            let actions = try XCTUnwrap(collection.visibleCells.first {
                $0 is ImpressChatReplyActionsCell &&
                $0.accessibilityValue == message.messageID.uuidString
            })
            let buttons = descendants(of: actions, as: UIButton.self)
            let copy = try XCTUnwrap(buttons.first {
                $0.accessibilityIdentifier == "impress.ai.chat.reply-copy"
            })
            copy.sendActions(for: .touchUpInside)
            XCTAssertEqual(UIPasteboard.general.string, message.text)
            let more = try XCTUnwrap(buttons.first {
                $0.accessibilityIdentifier == "impress.ai.chat.reply-more"
            })
            XCTAssertEqual(more.menu?.children.first?.title, message.messageID.uuidString)
        }

        try assertReply(first)
        try assertReply(second)
        try assertReply(first)
        var incomplete = second
        incomplete.status = .failed
        viewport.update([incomplete])
        let forbidden = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            viewport.layoutIfNeeded()
            return collection.numberOfItems(inSection: 0) == 2 &&
                !collection.visibleCells.contains { $0 is ImpressChatReplyActionsCell }
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [forbidden], timeout: 8), .completed,
                       "Failed replies must not expose a stale completed reply menu")
    }

    func testProductionReplyFooterUsesNativeCopyAndExistingReviewMenu() throws {
        let cell = ImpressChatReplyActionsCell(
            frame: CGRect(x: 0, y: 0, width: 390, height: 44))
        let menu = UIMenu(children: [UIAction(title: "Review", handler: { _ in })])
        let response = "最终答复\n含中文和公式"
        cell.configure(messageID: UUID(), text: response, menu: menu)
        cell.layoutIfNeeded()
        let buttons = descendants(of: cell, as: UIButton.self)
        let copy = try XCTUnwrap(buttons.first {
            $0.accessibilityIdentifier == "impress.ai.chat.reply-copy"
        })
        copy.sendActions(for: .touchUpInside)
        XCTAssertEqual(UIPasteboard.general.string, response)
        let more = try XCTUnwrap(buttons.first {
            $0.accessibilityIdentifier == "impress.ai.chat.reply-more"
        })
        XCTAssertTrue(more.showsMenuAsPrimaryAction)
        XCTAssertEqual(more.menu?.children.count, 1)
        XCTAssertEqual(copy.bounds.height, 44)
    }

    func testQuadrupleCodeFencePreservesRealLanguageAndBody() throws {
        let cell = ImpressChatPOCStructuredCell(
            frame: CGRect(x: 0, y: 0, width: 350, height: 280))
        let code = "~~~~swift\r\nlet result = \"中文\"\r\n~~~~"
        cell.configure(markdown: code, kind: .code, stable: true)
        XCTAssertTrue(descendants(of: cell, as: UILabel.self)
            .contains(where: { $0.text == "swift" }),
            "Four-tilde code fences must not appear as ~swift in the header")
        let editor = try XCTUnwrap(descendants(of: cell, as: UITextView.self).first)
        XCTAssertEqual(editor.text, "let result = \"中文\"")
        let copy = try XCTUnwrap(descendants(of: cell, as: UIButton.self).first {
            $0.accessibilityIdentifier == "impress.chat.poc.content-copy"
        })
        copy.sendActions(for: .touchUpInside)
        XCTAssertEqual(UIPasteboard.general.string, "let result = \"中文\"")
    }

    func testModelMarkdownCannotOpenPrivateSchemesOrPreviewLinks() throws {
        let cell = ImpressChatDocumentCell(
            frame: CGRect(x: 0, y: 0, width: 390, height: 210))
        let editor = try XCTUnwrap(descendants(of: cell, as: UITextView.self).first)
        XCTAssertNotNil(editor.delegate)
        for raw in ["javascript:alert(1)", "file:///private/path",
                    "impress://calibration/week", "data:text/html,hi",
                    "https://user:secret@example.org/"] {
            let url = try XCTUnwrap(URL(string: raw))
            XCTAssertFalse(ImpressChatDocumentCell.safeExternalURL(url))
            XCTAssertFalse(cell.textView(editor, shouldInteractWith: url,
                in: NSRange(location: 0, length: 1), interaction: .invokeDefaultAction))
        }
        let valid = try XCTUnwrap(URL(string: "https://example.org/learn"))
        XCTAssertTrue(ImpressChatDocumentCell.safeExternalURL(valid))
        XCTAssertFalse(cell.textView(editor, shouldInteractWith: valid,
            in: NSRange(location: 0, length: 1), interaction: .preview),
            "Preview must not initiate a network navigation")
        cell.configure("[可靠](https://example.org) [危险](file:///private/path)",
                       kind: .paragraph, headingLevel: 0, user: false, stable: true)
        let rendered = try XCTUnwrap(editor.attributedText)
        let location = (rendered.string as NSString).range(of: "危险").location
        XCTAssertNotEqual(location, NSNotFound)
        XCTAssertNil(rendered.attribute(.link, at: location, effectiveRange: nil))
    }

    func testVoiceOverReadsRenderedDocumentRatherThanRawMarkdown() throws {
        let cell = ImpressChatDocumentCell(
            frame: CGRect(x: 0, y: 0, width: 390, height: 220))
        let body = try XCTUnwrap(descendants(of: cell, as: UITextView.self).first)
        cell.configure("**中文强调** 与 [安全链接](https://example.org)",
                       kind: .paragraph, headingLevel: 0, user: false, stable: true)
        let reading = try XCTUnwrap(body.accessibilityLabel)
        XCTAssertTrue(reading.contains("中文强调"))
        XCTAssertTrue(reading.contains("安全链接"))
        XCTAssertFalse(reading.contains("**"))
        XCTAssertFalse(reading.contains("](https://"),
            "Link destinations are not a substitute for readable link labels")
        cell.configure("> 第一条引用\n> 第二条引用",
                       kind: .quote, headingLevel: 0, user: false, stable: false)
        let quote = try XCTUnwrap(body.accessibilityLabel)
        XCTAssertTrue(quote.contains("引用："))
        XCTAssertTrue(quote.contains("第一条引用"))
        XCTAssertFalse(quote.contains("> "))
        XCTAssertTrue(quote.contains("生成中"))
    }

    func testProductionMarkdownRespectsDynamicDarkInkAndSelection() throws {
        let cell = ImpressChatDocumentCell(
            frame: CGRect(x: 0, y: 0, width: 390, height: 180))
        cell.overrideUserInterfaceStyle = .dark
        cell.configure("**中文强调** and plain text", kind: .paragraph,
                       headingLevel: 0, user: false, stable: true)
        let text = try XCTUnwrap(descendants(of: cell, as: UITextView.self).first)
        XCTAssertTrue(text.isSelectable)
        let rendered = try XCTUnwrap(text.attributedText)
        let boldRange = (rendered.string as NSString).range(of: "中文强调")
        let plainRange = (rendered.string as NSString).range(of: "plain text")
        XCTAssertNotEqual(boldRange.location, NSNotFound)
        XCTAssertNotEqual(plainRange.location, NSNotFound)
        let strongFont = try XCTUnwrap(rendered.attribute(.font,
            at: boldRange.location, effectiveRange: nil) as? UIFont)
        let plainFont = try XCTUnwrap(rendered.attribute(.font,
            at: plainRange.location, effectiveRange: nil) as? UIFont)
        XCTAssertGreaterThan(plainFont.pointSize, 12)
        XCTAssertTrue(strongFont.fontDescriptor.symbolicTraits.contains(.traitBold))
        XCTAssertFalse(plainFont.fontDescriptor.symbolicTraits.contains(.traitBold))
        let ink = try XCTUnwrap(rendered.attribute(.foregroundColor,
            at: plainRange.location, effectiveRange: nil) as? UIColor)
        XCTAssertEqual(ink, .label)
        XCTAssertEqual(ink.resolvedColor(with: text.traitCollection),
                       UIColor.label.resolvedColor(with: text.traitCollection))

        // Reuse must not leak assistant strong emphasis into plain/user text.
        cell.configure("普通问题", kind: .paragraph,
                       headingLevel: 0, user: true, stable: true)
        let userText = try XCTUnwrap(text.attributedText)
        let userFont = try XCTUnwrap(userText.attribute(.font,
            at: 0, effectiveRange: nil) as? UIFont)
        XCTAssertFalse(userFont.fontDescriptor.symbolicTraits.contains(.traitBold))
        cell.configure("普通回答", kind: .paragraph,
                       headingLevel: 0, user: false, stable: true)
        let normal = try XCTUnwrap(text.attributedText)
        let normalFont = try XCTUnwrap(normal.attribute(.font,
            at: 0, effectiveRange: nil) as? UIFont)
        XCTAssertFalse(normalFont.fontDescriptor.symbolicTraits.contains(.traitBold))
    }

    private func descendants<T: UIView>(of view: UIView, as type: T.Type) -> [T] {
        view.subviews.flatMap { child -> [T] in
            ((child as? T).map { [$0] } ?? []) +
                descendants(of: child, as: type)
        }
    }
}
