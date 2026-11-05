import XCTest
import UIKit
import ImpressReviewCore
@testable import aReuImpress_iPhone

/// A real UIKit/SwipeCardStack integration test, not a mocked gesture stack.
/// Uses the V3 database in an isolated temporary location on iOS Simulator.
@MainActor
final class ImpressV3SwipeIntegrationTests: XCTestCase {
    func testNativeSegmentsRemainCenteredAfterWidthIsCapped() {
        for compact in [false, true] {
            let control = UISegmentedControl(items: ["问答", "选择", "图片"])
            ImpressV3Appearance.styleSegmentedControl(control, prominent: true)
            let row = ImpressV3Appearance.segmentedRow(control, compact: compact)
            let host = UIView(frame: CGRect(x: 0, y: 0, width: 720, height: 80))
            row.translatesAutoresizingMaskIntoConstraints = false
            host.addSubview(row)
            NSLayoutConstraint.activate([
                row.leadingAnchor.constraint(equalTo: host.leadingAnchor),
                row.trailingAnchor.constraint(equalTo: host.trailingAnchor),
                row.topAnchor.constraint(equalTo: host.topAnchor),
                row.bottomAnchor.constraint(equalTo: host.bottomAnchor)
            ])
            host.layoutIfNeeded()
            let cap = compact
                ? ImpressV3Appearance.Metrics.compactSegmentWidth
                : ImpressV3Appearance.Metrics.maximumSegmentWidth
            XCTAssertLessThanOrEqual(control.bounds.width, cap + 0.5)
            XCTAssertEqual(control.center.x, row.bounds.midX, accuracy: 0.5)
            XCTAssertGreaterThanOrEqual(control.frame.minX, -0.5)
            XCTAssertLessThanOrEqual(control.frame.maxX, row.bounds.maxX + 0.5)
        }
    }

    func testEditorAndBatchImportShareExactNativeSegmentedStyle() throws {
        let editor = ImpressV3CardComposerViewController()
        editor.loadViewIfNeeded()
        let importer = ImpressV3BatchImportViewController()
        importer.loadViewIfNeeded()
        func find(_ root: UIView, named label: String) -> UISegmentedControl? {
            if let control = root as? UISegmentedControl,
               control.accessibilityLabel == label { return control }
            for child in root.subviews {
                if let result = find(child, named: label) { return result }
            }
            return nil
        }
        let card = try XCTUnwrap(find(editor.view, named: V3L("卡片类型")))
        let batch = try XCTUnwrap(find(importer.view, named: V3L("导入格式")))
        XCTAssertEqual(card.backgroundColor, batch.backgroundColor)
        XCTAssertEqual(card.selectedSegmentTintColor, batch.selectedSegmentTintColor)
        XCTAssertEqual(card.apportionsSegmentWidthsByContent,
                       batch.apportionsSegmentWidthsByContent)
        let action = try XCTUnwrap(importer.navigationItem.rightBarButtonItem)
        XCTAssertEqual(action.style, .plain)
        XCTAssertTrue(action.image?.isSymbolImage == true)
        XCTAssertEqual(action.accessibilityLabel, V3L("预览"))
        XCTAssertEqual(action.tintColor, ImpressV3Appearance.navigationActionInk)
    }

    func testNavigationChromeAndButtonsNeverUseSystemBlue() throws {
        let host = ImNavigationViewController(rootViewController: UIViewController())
        host.loadViewIfNeeded()
        XCTAssertEqual(host.navigationBar.tintColor,
                       ImpressV3Appearance.navigationActionInk)
        XCTAssertNotEqual(host.navigationBar.tintColor, UIColor.systemBlue)
        let action = ImpressV3Appearance.navigationAction(
            symbol: "square.and.pencil", label: "编辑",
            target: nil, action: nil)
        XCTAssertEqual(action.tintColor, ImpressV3Appearance.navigationActionInk)
        XCTAssertNotEqual(action.tintColor, UIColor.systemBlue)
    }

    @MainActor
    func testFourRatingBadgesHaveOpaqueLegibleCenterOverlay() throws {
        for (direction, name) in [
            (SwipeDirection.left, V3L("困难")),
            (.up, V3L("良好")),
            (.right, V3L("容易")),
            (.down, V3L("重来"))
        ] {
            let overlay = ImpressV3RatingOverlay(direction: direction)
            overlay.frame = CGRect(x: 0, y: 0, width: 320, height: 440)
            overlay.layoutIfNeeded()
            let badge = try XCTUnwrap(overlay.subviews.first)
            XCTAssertEqual(badge.backgroundColor,
                           ImpressV3Appearance.reviewOverlaySurface(for: direction))
            XCTAssertGreaterThanOrEqual(badge.bounds.height, 60)
            func labels(_ view: UIView) -> [UILabel] {
                let own: [UILabel] = (view as? UILabel).map { [$0] } ?? []
                return own + view.subviews.flatMap { labels($0) }
            }
            XCTAssertTrue(labels(overlay).contains(where: {
                $0.text == name &&
                $0.textColor == ImpressV3Appearance.reviewOverlayInk(for: direction)
            }))
            XCTAssertFalse(overlay.isUserInteractionEnabled,
                "Overlay may inform but must not grade a card by tapping")
        }
    }

    func testAIServiceListSymbolsUseNeutralSharedIconRole() throws {
        let settings = ImpressAISettingsViewController()
        settings.loadViewIfNeeded()
        let cell = settings.tableView(settings.tableView,
            cellForRowAt: IndexPath(row: 0, section: 2))
        let content = try XCTUnwrap(cell.contentConfiguration as? UIListContentConfiguration)
        XCTAssertEqual(content.imageProperties.tintColor,
                       ImpressV3Appearance.listIconTint)
        XCTAssertNotEqual(content.imageProperties.tintColor, UIColor.systemBlue)
    }

    @MainActor
    func testContentHistoryIsEditorOnly() throws {
        let editor = ImpressV3CardComposerViewController(editingCardID: UUID())
        editor.onOpenContentHistory = {}
        editor.loadViewIfNeeded()
        XCTAssertTrue(editor.navigationItem.rightBarButtonItems?.contains(where: {
            $0.accessibilityIdentifier == "impress.composer.content-history"
        }) == true)
        let review = ImpressV3ReviewViewController()
        review.loadViewIfNeeded()
        XCTAssertFalse(review.view.subviews.compactMap { $0 as? UIButton }.contains(where: {
            $0.accessibilityIdentifier == "impress.review.content-history"
        }))
    }

    @MainActor
    func testQuestionIsAtMostThreeLinesAndFullTextReturnsWithoutRating() async throws {
        var card = ImCardModel()
        card.cardType = CardType.standard.rawValue
        card.question = "# Heading\n\n" +
            String(repeating: "## Subheading\nLong question with **emphasis**.\n", count: 100)
        card.answer = "# Answer\n\n" +
            String(repeating: "A long structured answer with **bold** and lists.\n", count: 130)
        let review = ImMemoryCardView(model: card, v3Style: true)
        let host = UIView(frame: CGRect(x: 0, y: 0, width: 390, height: 650))
        review.frame = host.bounds
        host.addSubview(review)
        host.layoutIfNeeded()
        review.layoutIfNeeded()
        try await Task.sleep(for: .milliseconds(150))
        review.layoutIfNeeded()
        let question = review.questionTextView
        XCTAssertFalse(question.isScrollEnabled)
        XCTAssertEqual(question.textContainer.maximumNumberOfLines, 3)
        XCTAssertTrue(question.isSelectable)
        XCTAssertTrue(review.isQuestionTruncated)
        XCTAssertEqual(question.textContainer.lineBreakMode, .byTruncatingTail)
        let questionFont = try XCTUnwrap(question.font)
        XCTAssertTrue(questionFont.fontDescriptor.symbolicTraits.contains(.traitBold))
        XCTAssertEqual(questionFont.pointSize,
                       ImpressV3Appearance.Typography.flashQuestion.pointSize)
        XCTAssertGreaterThanOrEqual(question.bounds.height,
            questionFont.lineHeight * 3 + question.textContainerInset.top +
                question.textContainerInset.bottom - 1,
            "Before reveal the card must show three visible question lines")
        review.revealAnswerIfNeeded()
        try await Task.sleep(for: .milliseconds(700))
        review.layoutIfNeeded()
        func allTextViews(_ root: UIView) -> [ImExtractTextView] {
            let selfView = (root as? ImExtractTextView).map { [$0] } ?? []
            return selfView + root.subviews.flatMap { allTextViews($0) }
        }
        let answer = try XCTUnwrap(allTextViews(review).first(where: { $0 !== question }))
        XCTAssertTrue(answer.isScrollEnabled)
        XCTAssertTrue(answer.isSelectable)
        XCTAssertFalse(try XCTUnwrap(answer.font).fontDescriptor.symbolicTraits.contains(.traitBold))
        XCTAssertEqual(answer.font?.pointSize,
                       ImpressV3Appearance.Typography.flashAnswer.pointSize)
        XCTAssertGreaterThan(answer.contentSize.height, answer.bounds.height)
        XCTAssertLessThan(question.bounds.height, review.bounds.height * 0.55)
        XCTAssertTrue(review.answerIsRevealed)
    }

    @MainActor
    func testMinimalChatChromeAndComposerStates() {
        let chat = ImpressAINativeChatViewController()
        chat.loadViewIfNeeded()
        XCTAssertTrue(chat.title?.isEmpty ?? true)
        XCTAssertNil(chat.navigationItem.prompt)
        XCTAssertEqual(chat.navigationItem.rightBarButtonItems?
            .compactMap(\.accessibilityIdentifier),
            ["impress.ai.chat.new-discussion", "impress.ai.chat.features"])
        XCTAssertNotNil(chat.navigationItem.rightBarButtonItems?.last?.menu,
            "Chat features must be a native UIMenu rather than a pushed list")
        let menu = try? XCTUnwrap(chat.navigationItem.rightBarButtonItems?.last?.menu)
        XCTAssertTrue(menu?.children.contains(where: { $0.title == V3L("历史讨论") }) == true)
        XCTAssertTrue(menu?.children.compactMap({ $0 as? UIMenu }).contains(where: {
            $0.title == V3L("对话设置")
        }) == true)
        func allViews(_ view: UIView) -> [UIView] {
            [view] + view.subviews.flatMap { allViews($0) }
        }
        let ids = Set(allViews(chat.view).compactMap(\.accessibilityIdentifier))
        XCTAssertTrue(ids.contains("impress.ai.chat.add-material"))
        XCTAssertTrue(ids.contains("impress.ai.chat.speech-input"))
        XCTAssertTrue(ids.contains("impress.ai.chat.input"))
        XCTAssertFalse(ids.contains("impress.ai.chat.prompt"))
        XCTAssertFalse(ids.contains("impress.ai.chat.materials"))
        let views = allViews(chat.view)
        let send = views.compactMap { $0 as? UIButton }.first {
            $0.accessibilityIdentifier == "impress.ai.chat.send"
        }
        XCTAssertEqual(send?.configuration?.baseBackgroundColor,
                       ImpressV3Appearance.chatComposerSendFill)
        XCTAssertNotEqual(send?.configuration?.baseBackgroundColor, UIColor.systemBlue)
        let placeholder = views.compactMap { $0 as? UILabel }.first {
            $0.accessibilityIdentifier == "impress.ai.chat.input-placeholder"
        }
        XCTAssertEqual(placeholder?.text, V3L("询问任何问题"))
        let inputField = views.compactMap { $0 as? UITextView }.first {
            $0.accessibilityIdentifier == "impress.ai.chat.input"
        }
        XCTAssertEqual(inputField?.textContainerInset.top,
                       ImpressV3Appearance.Metrics.chatComposerTextVerticalInset)
        XCTAssertFalse(placeholder?.isHidden ?? true)
        let input = views.compactMap { $0 as? UITextView }.first {
            $0.accessibilityIdentifier == "impress.ai.chat.input"
        }
        let actual = try? XCTUnwrap(input)
        actual?.text = "Explain this"
        if let actual { chat.textViewDidChange(actual) }
        XCTAssertTrue(placeholder?.isHidden ?? false,
            "Placeholder must not overlap a real draft or enter transmitted text")
    }

    func testSwipeSummaryReplacesFourChipsAndNeverTapScores() async throws {
        let store = try makeRepository()
        let id = UUID()
        let now = Date()
        try await store.insertNewCard(
            WCDBV3CardInput(cardID: id, question: "Grade after reveal?", answerText: "Only then."),
            initial: FSRS6ReviewCalculator().newCardSnapshot(id: id, now: now),
            now: now)
        let review = ImpressV3ReviewViewController(repository: store)
        let window = UIWindow(frame: UIScreen.main.bounds)
        window.rootViewController = ImNavigationViewController(rootViewController: review)
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        review.loadViewIfNeeded()
        XCTAssertFalse(review.view.subviews.contains {
            $0.accessibilityIdentifier == "impress.review.rating-guide"
        }, "The redundant chip row and reserved space must be removed")
        let summary = try XCTUnwrap(review.view.subviews.first {
            $0.accessibilityIdentifier == "impress.review.rating-summary"
        } as? UILabel)
        XCTAssertFalse(summary.text?.contains(V3L("困难")) ?? false)
        let stack = try XCTUnwrap(review.view.subviews.compactMap {
            $0 as? SwipeCardStack
        }.first)
        let hasCard = try await eventually {
            stack.topCard?.content is ImMemoryCardView
        }
        XCTAssertTrue(hasCard)
        (stack.topCard?.content as? ImMemoryCardView)?.revealAnswerIfNeeded()
        let hasFourDirections = try await eventually {
            [V3L("困难"), V3L("良好"), V3L("容易"), V3L("重来")].allSatisfy {
                summary.text?.contains($0) == true
            }
        }
        XCTAssertTrue(hasFourDirections)
        let events = try await store.reviewHistory(for: id)
        XCTAssertTrue(events.isEmpty, "Exposing guidance must not submit a rating")
    }

    private func makeRepository() throws -> ReviewWCDBRepository {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("V3Swipe-" + UUID().uuidString, isDirectory: true)
            .appendingPathComponent("cards.sqlite").path
        return try ReviewWCDBRepository(databasePath: path,
                                        calculator: FSRS6ReviewCalculator())
    }

    private func eventually(timeout: TimeInterval = 4.0,
                            _ predicate: @escaping @MainActor () -> Bool) async throws -> Bool {
        let count = Int(timeout / 0.08)
        for _ in 0..<count {
            if predicate() { return true }
            try await Task.sleep(nanoseconds: 80_000_000)
        }
        return predicate()
    }

    func testReturningAfterExternalCardEditRequiresRevealingTheNewAnswer() async throws {
        let store = try makeRepository()
        let id = UUID()
        let now = Date()
        try await store.insertNewCard(
            WCDBV3CardInput(cardID: id, question: "Old question", answerText: "Old answer"),
            initial: FSRS6ReviewCalculator().newCardSnapshot(id: id, now: now),
            now: now)
        let review = ImpressV3ReviewViewController(repository: store)
        let window = UIWindow(frame: UIScreen.main.bounds)
        window.rootViewController = UINavigationController(rootViewController: review)
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        review.loadViewIfNeeded()
        let stack = try XCTUnwrap(review.view.subviews.compactMap {
            $0 as? SwipeCardStack
        }.first)
        let hasCard = try await eventually { stack.topCard?.content is ImMemoryCardView }
        XCTAssertTrue(hasCard)
        let first = try XCTUnwrap(stack.topCard?.content as? ImMemoryCardView)
        first.revealAnswerIfNeeded()
        let canRate = try await eventually {
            stack.topCard?.panGestureRecognizer.isEnabled == true
        }
        XCTAssertTrue(canRate)
        try await store.updateManagedCard(
            WCDBV3CardInput(cardID: id, question: "Updated question",
                            answerText: "Updated answer"),
            expectedRevision: 0, expectedContentRevision: 0)
        review.viewWillAppear(false)
        func labels(in root: UIView) -> [UILabel] {
            let own = (root as? UILabel).map { [$0] } ?? []
            return own + root.subviews.flatMap { labels(in: $0) }
        }
        let reset = try await eventually {
            let newContent = stack.topCard?.content as? ImMemoryCardView
            let hidden = !(newContent?.answerIsRevealed ?? true)
            let swipeDisabled = !(stack.topCard?.panGestureRecognizer.isEnabled ?? true)
            let buttonsHidden = stack.topCard?.subviews.compactMap { $0 as? UIStackView }.contains {
                $0.arrangedSubviews.contains { $0.accessibilityIdentifier == "impress.review.quick-edit" } && $0.isHidden
            } == true
            let requiresReveal = labels(in: review.view).contains {
                $0.text == V3L("先回忆，再查看答案")
            }
            return hidden && swipeDisabled && buttonsHidden && requiresReveal
        }
        XCTAssertTrue(reset)
        let refreshed = try await store.content(for: id)
        let latest = try XCTUnwrap(refreshed)
        XCTAssertEqual(latest.contentRevision, 1)
        let events = try await store.reviewHistory(for: id)
        XCTAssertTrue(events.isEmpty)
    }

    func testCardActionsRequireRevealedAnswerWhileSourceRemainsAvailableWithoutScoring() async throws {
        let store = try makeRepository()
        let id = UUID()
        let vault = try ImVaultFileIdentity(vaultID: "disposable-test-vault",
                                            relativePath: "Notes/Example.md")
        let source = try ImpressBatchSourceKey.encode(vault)
        let now = Date()
        try await store.insertNewCard(
            WCDBV3CardInput(cardID: id, question: "What is the original source?",
                            answerText: "The linked Markdown note.", sourceNotePath: source),
            initial: FSRS6ReviewCalculator().newCardSnapshot(id: id, now: now),
            now: now)
        let review = ImpressV3ReviewViewController(repository: store)
        let window = UIWindow(frame: UIScreen.main.bounds)
        window.rootViewController = UINavigationController(rootViewController: review)
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        review.loadViewIfNeeded()
        func controls(in root: UIView) -> [UIButton] {
            (root as? UIButton).map { [$0] } ?? root.subviews.flatMap(controls(in:))
        }
        let stack = try XCTUnwrap(review.view.subviews.compactMap {
            $0 as? SwipeCardStack
        }.first)
        let ready = try await eventually {
            let elements = controls(in: review.view)
            let edit = elements.first {
                $0.accessibilityIdentifier == "impress.review.quick-edit"
            }
            let discussion = elements.first {
                $0.accessibilityIdentifier == "impress.review.ai-discussion"
            }
            let source = elements.first {
                $0.accessibilityIdentifier == "impress.review.source-note"
            }
            return stack.topCard?.content is ImMemoryCardView &&
                edit?.superview?.isHidden == true &&
                discussion?.superview?.isHidden == true &&
                edit?.superview?.accessibilityElementsHidden == true &&
                source?.superview?.isHidden == false &&
                source?.isHidden == false &&
                stack.topCard?.panGestureRecognizer.isEnabled == false
        }
        XCTAssertTrue(ready, "Unrevealed edit and discussion must be hidden; verified source remains reachable")
        let content = try XCTUnwrap(stack.topCard?.content as? ImMemoryCardView)
        content.revealAnswerIfNeeded()
        let revealed = try await eventually {
            let elements = controls(in: review.view)
            let edit = elements.first { $0.accessibilityIdentifier == "impress.review.quick-edit" }
            let discussion = elements.first { $0.accessibilityIdentifier == "impress.review.ai-discussion" }
            return edit?.superview?.isHidden == false &&
                discussion?.superview?.isHidden == false &&
                edit?.superview?.accessibilityElementsHidden == false &&
                stack.topCard?.panGestureRecognizer.isEnabled == true
        }
        XCTAssertTrue(revealed, "Both actions are available only after answer reveal")
        let events = try await store.reviewHistory(for: id)
        XCTAssertTrue(events.isEmpty, "Revealing and showing actions never grades the card")
    }

    func testComposerSaveUsesNavigationCheckmarkWithAccessibleSaveName() throws {
        let composer = ImpressV3CardComposerViewController()
        composer.loadViewIfNeeded()
        let save = try XCTUnwrap(composer.navigationItem.rightBarButtonItem)
        XCTAssertNil(save.title, "Save is a native symbol, not a text button")
        XCTAssertTrue(save.image?.isSymbolImage == true)
        XCTAssertEqual(save.accessibilityIdentifier, "impress.composer.save")
        XCTAssertEqual(save.accessibilityLabel, V3L("保存"))
        XCTAssertEqual(save.style, .plain)
        let navigation = ImNavigationViewController(rootViewController: composer)
        navigation.loadViewIfNeeded()
        XCTAssertEqual(navigation.navigationBar.tintColor,
                       ImpressV3Appearance.navigationActionInk)
    }

    func testActualTinderSwipeSavesOneFSRSEventOnlyAfterRevealingAnswer() async throws {
        let repository = try makeRepository()
        let cardID = UUID()
        let time = Date()
        let seed = try FSRS6ReviewCalculator().newCardSnapshot(id: cardID, now: time)
        try await repository.insertNewCard(
            WCDBV3CardInput(cardID: cardID,
                            question: "What is active recall?",
                            answerText: "Retrieving knowledge without rereading."),
            initial: seed, now: time)

        let controller = ImpressV3ReviewViewController(repository: repository)
        let window = UIWindow(frame: UIScreen.main.bounds)
        window.rootViewController = UINavigationController(rootViewController: controller)
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        controller.loadViewIfNeeded()

        guard let stack = controller.view.subviews.compactMap({ $0 as? SwipeCardStack }).first else {
            XCTFail("V3 should render the original SwipeCardStack")
            return
        }
        let prepared = try await eventually {
            stack.topCard?.content is ImMemoryCardView
        }
        XCTAssertTrue(prepared)
        XCTAssertEqual(stack.topCardIndex, 0)
        XCTAssertFalse(stack.topCard?.panGestureRecognizer.isEnabled ?? true)
        let before = try await repository.reviewHistory(for: cardID)
        XCTAssertTrue(before.isEmpty)

        guard let content = stack.topCard?.content as? ImMemoryCardView else {
            XCTFail("Expected the existing text/image card content view")
            return
        }
        content.revealAnswerIfNeeded()
        let enabled = try await eventually {
            stack.topCard?.panGestureRecognizer.isEnabled == true
        }
        XCTAssertTrue(enabled, "The answer must be revealed before rating")

        // Exercise the real card animator, delegate index, FSRS calculator and
        // WCDB transaction. A successful swipe must produce exactly one event.
        stack.swipe(.right, animated: true)
        let committed = try await eventually(timeout: 7) {
            stack.numberOfRemainingCards() == 0
        }
        XCTAssertTrue(committed)
        let eventsAvailable = try await eventually(timeout: 7) {
            let labels = controller.view.subviews.compactMap { $0 as? UILabel }
            return labels.contains { $0.text?.contains("本轮完成") == true }
        }
        XCTAssertTrue(eventsAvailable, "The last swipe must await animation and commit")
        let events = try await repository.reviewHistory(for: cardID)
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events.first?.rating, .easy)
        XCTAssertEqual(events.first?.before.revision, 0)
        XCTAssertEqual(events.first?.after.revision, 1)
    }

    func testMultipleChoiceAnswerRequiresExplicitGradeSwipe() async throws {
        let repository = try makeRepository()
        let id = UUID()
        let now = Date()
        try await repository.insertNewCard(
            WCDBV3CardInput(cardID: id, question: "Choose the true statement",
                            choices: "A\nB", correctIndices: "0", cardType: 2),
            initial: FSRS6ReviewCalculator().newCardSnapshot(id: id, now: now),
            now: now)

        let controller = ImpressV3ReviewViewController(repository: repository)
        let window = UIWindow(frame: UIScreen.main.bounds)
        window.rootViewController = UINavigationController(rootViewController: controller)
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        controller.loadViewIfNeeded()
        guard let stack = controller.view.subviews.compactMap({ $0 as? SwipeCardStack }).first else {
            XCTFail("Expected original Tinder stack")
            return
        }
        let cardReady = try await eventually { stack.topCard?.content is ImMultipleChoiceCardView }
        XCTAssertTrue(cardReady)
        XCTAssertFalse(stack.topCard?.panGestureRecognizer.isEnabled ?? true)
        guard let answer = stack.topCard?.content as? ImMultipleChoiceCardView else {
            XCTFail("Multiple choice card missing")
            return
        }
        // R04.2-D2: native options live inside a vertically scrollable
        // card container; no longer look only at immediate subviews.
        func buttons(in root: UIView) -> [UIButton] {
            let own = (root as? UIButton).map { [$0] } ?? []
            return own + root.subviews.flatMap(buttons(in:))
        }
        let options = buttons(in: answer)
        XCTAssertEqual(options.count, 2)
        XCTAssertEqual(answer.subviews.compactMap { $0 as? UIScrollView }.count, 1)
        XCTAssertTrue(options.allSatisfy { $0.buttonType == .system })
        answer.showAnswer()
        let revealed = try await eventually {
            stack.topCard?.panGestureRecognizer.isEnabled == true
        }
        XCTAssertTrue(revealed)
        let events = try await repository.reviewHistory(for: id)
        XCTAssertEqual(events.count, 0, "Answering a multiple-choice question is not an FSRS grade")
    }
    func testAllFourDirectionsPersistCorrectFSRSRating() async throws {
        let cases: [(SwipeDirection, ReviewRating)] = [
            (.down, .again), (.left, .hard), (.up, .good), (.right, .easy)
        ]
        for (direction, rating) in cases {
            let repository = try makeRepository()
            let id = UUID()
            let now = Date()
            try await repository.insertNewCard(
                WCDBV3CardInput(cardID: id, question: "Q", answerText: "A"),
                initial: try FSRS6ReviewCalculator().newCardSnapshot(id: id, now: now),
                now: now)
            let controller = ImpressV3ReviewViewController(repository: repository)
            let window = UIWindow(frame: UIScreen.main.bounds)
            window.rootViewController = UINavigationController(rootViewController: controller)
            window.makeKeyAndVisible()
            defer { window.isHidden = true }
            controller.loadViewIfNeeded()
            guard let stack = controller.view.subviews.compactMap({ $0 as? SwipeCardStack }).first else {
                XCTFail("Missing the original Tinder SwipeCardStack")
                return
            }
            let ready = try await eventually { stack.topCard?.content is ImMemoryCardView }
            XCTAssertTrue(ready)
            (stack.topCard?.content as? ImMemoryCardView)?.revealAnswerIfNeeded()
            let enabled = try await eventually {
                stack.topCard?.panGestureRecognizer.isEnabled == true
            }
            XCTAssertTrue(enabled)
            stack.swipe(direction, animated: true)
            let finished = try await eventually(timeout: 7) {
                controller.view.subviews.compactMap { $0 as? UILabel }
                    .contains(where: { $0.text == "本轮完成" })
            }
            XCTAssertTrue(finished, "Direction \(direction) must wait for a durable grade")
            let events = try await repository.reviewHistory(for: id)
            XCTAssertEqual(events.count, 1)
            XCTAssertEqual(events.first?.rating, rating)
        }
    }

    func testRapidDuplicateSwipeCannotCreateSecondWCDBEvent() async throws {
        let repo = try makeRepository()
        let id = UUID()
        let now = Date()
        try await repo.insertNewCard(
            WCDBV3CardInput(cardID: id, question: "Double tap?", answerText: "Once"),
            initial: try FSRS6ReviewCalculator().newCardSnapshot(id: id, now: now), now: now)
        let controller = ImpressV3ReviewViewController(repository: repo)
        let window = UIWindow(frame: UIScreen.main.bounds)
        window.rootViewController = UINavigationController(rootViewController: controller)
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        controller.loadViewIfNeeded()
        guard let stack = controller.view.subviews.compactMap({ $0 as? SwipeCardStack }).first else {
            XCTFail("Missing SwipeCardStack")
            return
        }
        let ready = try await eventually { stack.topCard?.content is ImMemoryCardView }
        XCTAssertTrue(ready)
        (stack.topCard?.content as? ImMemoryCardView)?.revealAnswerIfNeeded()
        let enabled = try await eventually {
            stack.topCard?.panGestureRecognizer.isEnabled == true
        }
        XCTAssertTrue(enabled)
        stack.swipe(.left, animated: true)
        stack.swipe(.right, animated: true)
        let finished = try await eventually(timeout: 7) {
            controller.view.subviews.compactMap { $0 as? UILabel }
                .contains(where: { $0.text == "本轮完成" })
        }
        XCTAssertTrue(finished)
        let events = try await repo.reviewHistory(for: id)
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events.first?.rating, .hard)
    }

    func testInterruptedTwoCardSwipeStillAdvancesOnlyAfterSingleCommit() async throws {
        let repo = try makeRepository()
        let firstID = UUID()
        let secondID = UUID()
        let now = Date()
        let calc = FSRS6ReviewCalculator()
        try await repo.insertNewCard(
            WCDBV3CardInput(cardID: firstID, question: "First", answerText: "A"),
            initial: try calc.newCardSnapshot(id: firstID, now: now.addingTimeInterval(-2)),
            now: now.addingTimeInterval(-2))
        try await repo.insertNewCard(
            WCDBV3CardInput(cardID: secondID, question: "Second", answerText: "B"),
            initial: try calc.newCardSnapshot(id: secondID, now: now.addingTimeInterval(-1)),
            now: now.addingTimeInterval(-1))
        let controller = ImpressV3ReviewViewController(repository: repo)
        let window = UIWindow(frame: UIScreen.main.bounds)
        window.rootViewController = UINavigationController(rootViewController: controller)
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        controller.loadViewIfNeeded()
        guard let stack = controller.view.subviews.compactMap({ $0 as? SwipeCardStack }).first else {
            XCTFail("Missing SwipeCardStack")
            return
        }
        let firstReady = try await eventually { stack.topCard?.content is ImMemoryCardView }
        XCTAssertTrue(firstReady)
        XCTAssertEqual(stack.topCardIndex, 0)
        (stack.topCard?.content as? ImMemoryCardView)?.revealAnswerIfNeeded()
        let gestureEnabled = try await eventually {
            stack.topCard?.panGestureRecognizer.isEnabled == true
        }
        XCTAssertTrue(gestureEnabled)
        guard let retiringCard = stack.topCard else {
            XCTFail("First card not found")
            return
        }
        stack.swipe(.up, animated: true)
        // Simulates UIKit animation cancellation during an interruption.
        retiringCard.removeAllAnimations()
        stack.backgroundCards.forEach { $0.removeAllAnimations() }

        let resumed = try await eventually(timeout: 8) {
            stack.topCardIndex == 1 && stack.isUserInteractionEnabled &&
                stack.topCard?.content is ImMemoryCardView
        }
        XCTAssertTrue(resumed, "Animation interruption must not strand persisted review")
        let firstEvents = try await repo.reviewHistory(for: firstID)
        let secondEvents = try await repo.reviewHistory(for: secondID)
        XCTAssertEqual(firstEvents.count, 1)
        XCTAssertEqual(firstEvents.first?.rating, .good)
        XCTAssertTrue(secondEvents.isEmpty)
    }

    func testFailedWCDBCommitRestoresCardAndAllowsExactlyOneRetry() async throws {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("V3SwipeFailure-" + UUID().uuidString, isDirectory: true)
            .appendingPathComponent("cards.sqlite").path
        let repository = try ReviewWCDBRepository(
            databasePath: path, calculator: OneShotReviewCalculator())
        let id = UUID()
        let now = Date()
        try await repository.insertNewCard(
            WCDBV3CardInput(cardID: id, question: "Retry?", answerText: "Yes."),
            initial: try FSRS6ReviewCalculator().newCardSnapshot(id: id, now: now),
            now: now)

        let controller = ImpressV3ReviewViewController(repository: repository)
        let window = UIWindow(frame: UIScreen.main.bounds)
        window.rootViewController = UINavigationController(rootViewController: controller)
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        controller.loadViewIfNeeded()
        guard let stack = controller.view.subviews.compactMap({ $0 as? SwipeCardStack }).first else {
            XCTFail("Expected the Tinder card stack")
            return
        }
        let ready = try await eventually { stack.topCard?.content is ImMemoryCardView }
        XCTAssertTrue(ready)
        (stack.topCard?.content as? ImMemoryCardView)?.revealAnswerIfNeeded()
        let enabled = try await eventually { stack.topCard?.panGestureRecognizer.isEnabled == true }
        XCTAssertTrue(enabled)
        stack.swipe(.left, animated: true)

        let recovered = try await eventually(timeout: 8) {
            stack.topCardIndex == 0 &&
                stack.topCard?.panGestureRecognizer.isEnabled == true &&
                stack.isUserInteractionEnabled
        }
        XCTAssertTrue(recovered, "Failed ratings must restore the SAME interactable card")
        let before = try await repository.reviewHistory(for: id)
        XCTAssertTrue(before.isEmpty)

        stack.swipe(.up, animated: true)
        let completed = try await eventually(timeout: 7) {
            controller.view.subviews.compactMap { $0 as? UILabel }
                .contains(where: { $0.text == "本轮完成" })
        }
        XCTAssertTrue(completed)
        let events = try await repository.reviewHistory(for: id)
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events.first?.rating, .good)
    }

}


private enum OneShotReviewFailure: Swift.Error { case injected }

private final class OneShotReviewCalculator: WCDBReviewCalculating, @unchecked Sendable {
    private let lock = NSLock()
    private var failNext = true

    func next(before: ReviewScheduleSnapshot, status: ReviewCardStatus,
              submission: ReviewSubmission) throws -> WCDBCalculatedReview {
        lock.lock()
        let shouldFail = failNext
        failNext = false
        lock.unlock()
        if shouldFail { throw OneShotReviewFailure.injected }
        return try FSRS6ReviewCalculator().next(
            before: before, status: status, submission: submission)
    }
}


// R04 native web handoff is pure until the user copies/pastes in DeepSeek.
// This must never create a second FSRS event or start a native chat.
final class ImpressV3DeepSeekHandoffTests: XCTestCase {
    func testDeepSeekPayloadUsesCurrentQuestionAndFirstPrinciplesByDefault() {
        let payload = ImpressV3DeepSeekHandoff.makePayload(
            question: "检验假设", answer: "观察因果", userPrompt: nil)
        XCTAssertTrue(payload.contains("第一性原理"))
        XCTAssertTrue(payload.contains("检验假设"))
        XCTAssertTrue(payload.contains("观察因果"))
    }

    func testDeepSeekPayloadRespectsSavedUserPromptWithoutAutoSending() {
        let payload = ImpressV3DeepSeekHandoff.makePayload(
            question: "问题", answer: nil, userPrompt: "自定义学习方式")
        XCTAssertTrue(payload.contains("自定义学习方式"))
        XCTAssertTrue(payload.contains("没有可用的文字答案"))
    }
}


// V3 knowledge lifecycle: Settings remains a primary Tab and Learning Rhythm
// now exposes both Daily Calibration and Review Notifications.
@MainActor
final class ImpressR041NativeNavigationTests: XCTestCase {
    func testSettingsIncludesAppearanceLanguageAndDataSafety() {
        let settings = ImpressV3SettingsHubViewController()
        settings.loadViewIfNeeded()
        XCTAssertEqual(settings.numberOfSections(in: settings.tableView), 5)
        XCTAssertEqual(settings.navigationItem.largeTitleDisplayMode, .always)
        // Exactly two entries under Learning Rhythm: direct calibration
        // detail, then Review Notifications. Keep the other settings intact.
        for (section, title) in ["AI 服务", "每日校准", "显示模式", "语音与听写", "数据与备份"].enumerated() {
            let expectedRows = section <= 2 ? 2 : 1
            XCTAssertEqual(settings.tableView(settings.tableView,
                              numberOfRowsInSection: section), expectedRows)
            let cell = settings.tableView(settings.tableView,
                              cellForRowAt: IndexPath(row: 0, section: section))
            let content = cell.contentConfiguration as? UIListContentConfiguration
            XCTAssertEqual(content?.text, V3L(title))
        }
        let notifications = settings.tableView(settings.tableView,
            cellForRowAt: IndexPath(row: 1, section: 1))
        XCTAssertEqual((notifications.contentConfiguration as? UIListContentConfiguration)?.text,
                       V3L("复习通知"))
        let prompts = settings.tableView(settings.tableView,
            cellForRowAt: IndexPath(row: 1, section: 0))
        XCTAssertEqual((prompts.contentConfiguration as? UIListContentConfiguration)?.text,
                       V3L("提示词"))
        let language = settings.tableView(settings.tableView,
            cellForRowAt: IndexPath(row: 1, section: 2))
        XCTAssertEqual((language.contentConfiguration as? UIListContentConfiguration)?.text,
                       V3L("应用语言"))
        XCTAssertEqual(settings.tableView(settings.tableView,
                          titleForHeaderInSection: 4), V3L("数据安全"))
    }

    func testAppearanceModesPersistAndApplyOnlyToRequestedWindow() throws {
        let suite = "test.appearance." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        XCTAssertEqual(ImpressV3Appearance.selectedMode(in: defaults), .system)
        ImpressV3Appearance.setAppearance(.dark, defaults: defaults, windows: [window])
        XCTAssertEqual(window.overrideUserInterfaceStyle, .dark)
        XCTAssertEqual(ImpressV3Appearance.selectedMode(in: defaults), .dark)
        ImpressV3Appearance.setAppearance(.light, defaults: defaults, windows: [window])
        XCTAssertEqual(window.overrideUserInterfaceStyle, .light)
        ImpressV3Appearance.setAppearance(.system, defaults: defaults, windows: [window])
        XCTAssertEqual(window.overrideUserInterfaceStyle, .unspecified)
        XCTAssertEqual(ImpressV3Appearance.selectedMode(in: defaults), .system)
    }


    func testDuplexSourceRevisionAndPrivacyWarningsAreLocalized() {
        for original in [
            "核查后修订这张原卡",
            "确认有限对话上下文",
            "本次仅向云端模型发送最近 16 条已完成对话及当前输入；更早的消息仍完整保存在本机，不代表模型已经读过。",
            "确认此会话的发送范围",
            "原卡已按人工修订保存；cardID 和 FSRS 历史保留。返回可继续复习。",
            "已应用的笔记草稿",
            "建立下一版笔记草稿",
            "个人 Markdown 批准快照只保存在本机受保护目录，不包含在普通未加密 ZIP 备份。卸载或迁移后旧文件撤销可能不可用。"
        ] {
            let english = ImpressV3Language.text(original, language: .english)
            let traditional = ImpressV3Language.text(original, language: .traditional)
            XCTAssertNotEqual(english, original)
            XCTAssertNotEqual(traditional, original)
            XCTAssertFalse(english.isEmpty)
        }
    }

    func testThreeUserLanguagesPersistWithoutEditingSavedContent() throws {
        let suite = "test.interface.language." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        XCTAssertEqual(ImpressV3Language.selected(in: defaults), .simplified)
        XCTAssertEqual(ImpressV3Language.text("闪卡", language: .traditional), "閃卡")
        XCTAssertEqual(ImpressV3Language.text("闪卡", language: .english), "Flashcards")
        XCTAssertEqual(ImpressV3Language.text("数据与备份", language: .english),
                       "Data & Backup")
        XCTAssertEqual(ImpressV3Language.text("用户保存的自定义笔记", language: .english),
                       "用户保存的自定义笔记")
        let controller = ImpressV3LanguageSettingsViewController(defaults: defaults)
        controller.loadViewIfNeeded()
        XCTAssertEqual(controller.tableView.numberOfRows(inSection: 0), 3)
        controller.tableView(controller.tableView,
            didSelectRowAt: IndexPath(row: 2, section: 0))
        XCTAssertEqual(ImpressV3Language.selected(in: defaults), .english)
        let selected = controller.tableView(controller.tableView,
            cellForRowAt: IndexPath(row: 2, section: 0))
        XCTAssertEqual(selected.accessoryType, .checkmark)
        controller.tableView(controller.tableView,
            didSelectRowAt: IndexPath(row: 1, section: 0))
        XCTAssertEqual(ImpressV3Language.selected(in: defaults), .traditional)
        controller.tableView(controller.tableView,
            didSelectRowAt: IndexPath(row: 0, section: 0))
        XCTAssertEqual(ImpressV3Language.selected(in: defaults), .simplified)
    }

    func testVaultListMatchesSettingsNativeInsetGroupedAppearance() {
        let notes = ImpressNoteListTableViewController()
        notes.loadViewIfNeeded()
        XCTAssertEqual(notes.tableView.style, .insetGrouped)
        XCTAssertEqual(notes.tableView.backgroundColor, ImpressV3Appearance.page)
        XCTAssertEqual(notes.tableView.estimatedRowHeight,
                       ImpressV3Appearance.Metrics.noteRowEstimatedHeight)
        XCTAssertNil(notes.tableView.refreshControl,
            "No pull-to-refresh control should be mounted on the Vault outline")
    }

    func testSpeechInputTextMutationRespectsUTF16SelectionAndNoDataLoss() throws {
        let original = "你好👩‍💻 markdown"
        let at = (original as NSString).range(of: "markdown")
        XCTAssertEqual(ImpressSpeechTextInsertion.inserting(
            "STT", into: original, selected: at), "你好👩‍💻 STT")
        XCTAssertNil(ImpressSpeechTextInsertion.inserting(
            "dictation", into: original,
            selected: NSRange(location: 100000, length: 0)))
        let uneditable = UITextView()
        uneditable.isEditable = false
        ImpressSpeechAccessory.install(on: uneditable)
        XCTAssertNil(uneditable.inputAccessoryView)

        let editor = UITextView()
        editor.text = "Original"
        editor.selectedRange = NSRange(location: 8, length: 0)
        ImpressSpeechAccessory.install(on: editor)
        XCTAssertNotNil(editor.inputAccessoryView)
        let binder = try XCTUnwrap(ImpressSpeechTextBinding(view: editor))
        editor.text = "Changed elsewhere"
        XCTAssertThrowsError(try binder.commit(" spoken"))
        XCTAssertEqual(editor.text, "Changed elsewhere")
    }

    func testSpeechInputCommitUsesExistingEditorChangeDelegate() throws {
        final class Spy: NSObject, UITextViewDelegate {
            var edits = 0
            func textViewDidChange(_ textView: UITextView) { edits += 1 }
        }
        let editor = UITextView()
        let observer = Spy()
        editor.delegate = observer
        editor.text = "ABC"
        editor.selectedRange = NSRange(location: 1, length: 1)
        let binding = try XCTUnwrap(ImpressSpeechTextBinding(view: editor))
        try binding.commit("word")
        XCTAssertEqual(editor.text, "AwordC")
        XCTAssertEqual(editor.selectedRange.location, 5)
        XCTAssertEqual(observer.edits, 1)
    }

    func testSpeechSettingsShowsThreeLocalesWithoutMicrophoneUse() {
        let screen = ImpressSpeechSettingsViewController()
        screen.loadViewIfNeeded()
        XCTAssertEqual(screen.tableView.numberOfSections, 3)
        XCTAssertEqual(screen.tableView.numberOfRows(inSection: 0), 3)
        XCTAssertEqual(screen.tableView.numberOfRows(inSection: 1), 2)
        XCTAssertEqual(screen.tableView.numberOfRows(inSection: 2), 2)
        XCTAssertEqual(ImpressSpeechLocale.allCases.map(\.rawValue),
                       ["zh-CN", "zh-TW", "en-US"])
        // No action was invoked and the test does not request microphone access.
        XCTAssertEqual(ImpressSpeechService.shared.state, .idle)
    }

    func testSpeechVolatileResultUpdatesWithoutDuplication() {
        var buffer = ImpressTranscriptBuffer()
        buffer.accept(key: "0/1000", text: "hel", isFinal: false)
        buffer.accept(key: "0/1000", text: "hello", isFinal: false)
        XCTAssertEqual(buffer.previewText, "hello")
        XCTAssertEqual(buffer.finalText, "")
        buffer.accept(key: "0/1000", text: "Hello", isFinal: true)
        buffer.accept(key: "0/1000", text: "Hello duplicate", isFinal: true)
        buffer.accept(key: "100/1000", text: "world", isFinal: true)
        XCTAssertEqual(buffer.finalText, "Hello world")
    }

    func testDirectWebBrowserDoesNotAutoSendPrivateQuestions() {
        let browser = ImWebViewController.forDirectBrowse()
        browser.loadViewIfNeeded()
        XCTAssertEqual(browser.title, "网页聊天")
        XCTAssertTrue(browser.navigationItem.leftBarButtonItems?.isEmpty ?? true)
        let actions = browser.navigationItem.rightBarButtonItems ?? []
        XCTAssertFalse(actions.contains { $0.title == "复制问题" })
        XCTAssertTrue(actions.contains { $0.accessibilityLabel == "从提示词库复制" })
    }
}

// CI alone cannot sign off the iPhone appearance. These tests guard the
// actual semantic roles, tab coloring and native selected-control state.
@MainActor
final class ImpressR042AppearanceTests: XCTestCase {
    func testGroupedCanvasAndElevatedSurfacesUseOneAuthority() {
        XCTAssertEqual(ImpressV3Appearance.page, UIColor.systemGroupedBackground)
        XCTAssertEqual(ImpressV3Appearance.surface,
                       UIColor.secondarySystemGroupedBackground)
        XCTAssertEqual(ImpressV3Appearance.accent, funBtnColor)
        let bar = UITabBar()
        ImpressV3Appearance.styleTabBar(bar)
        XCTAssertEqual(bar.tintColor, ImpressV3Appearance.accent)
        XCTAssertEqual(bar.unselectedItemTintColor, ImpressV3Appearance.secondaryText)
        let navigation = UINavigationBar()
        ImpressV3Appearance.styleNavigationBar(navigation)
        XCTAssertEqual(navigation.tintColor,
                       ImpressV3Appearance.navigationActionInk)
    }

    func testSystemLightAndDarkResolveDifferentSemanticSurfaces() {
        // The app must not force Light/Dark; UIKit owns Automatic.
        XCTAssertEqual(Bundle.main.object(
            forInfoDictionaryKey: "UIUserInterfaceStyle") as? String, "Automatic")

        let light = UITraitCollection(userInterfaceStyle: .light)
        let dark = UITraitCollection(userInterfaceStyle: .dark)
        for role in [ImpressV3Appearance.page, ImpressV3Appearance.surface,
                     ImpressV3Appearance.primaryText, ImpressV3Appearance.optionSurface,
                     ImpressV3Appearance.selectedOptionSurface,
                     ImpressV3Appearance.correctOptionSurface,
                     ImpressV3Appearance.incorrectOptionSurface,
                     ImpressV3Appearance.imagePreviewBackdrop] {
            XCTAssertNotEqual(role.resolvedColor(with: light),
                              role.resolvedColor(with: dark),
                              "Semantic visual roles must follow the active trait.")
        }
        XCTAssertEqual(
            ImpressV3Appearance.primaryButtonText.resolvedColor(with: light),
            UIColor.white)
        XCTAssertEqual(
            ImpressV3Appearance.primaryButtonText.resolvedColor(with: dark),
            UIColor.black)
    }

    func testVisibleComposerAndSegmentsFollowLiveWindowAppearance() throws {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.overrideUserInterfaceStyle = .light
        let composer = ImpressV3CardComposerViewController()
        window.rootViewController = composer
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        composer.loadViewIfNeeded()
        window.layoutIfNeeded()

        func segments(in root: UIView) -> [UISegmentedControl] {
            let own = (root as? UISegmentedControl).map { [$0] } ?? []
            return own + root.subviews.flatMap(segments(in:))
        }
        let selected = try XCTUnwrap(
            segments(in: composer.view).first { $0.numberOfSegments == 3 })
        let lightTraits = window.traitCollection
        XCTAssertEqual(lightTraits.userInterfaceStyle, .light)
        let before = try XCTUnwrap(composer.view.backgroundColor)
            .resolvedColor(with: lightTraits)
        XCTAssertEqual(
            selected.titleTextAttributes(for: .selected)?[.foregroundColor] as? UIColor,
            ImpressV3Appearance.primaryText)

        window.overrideUserInterfaceStyle = .dark
        window.layoutIfNeeded()
        let darkTraits = window.traitCollection
        XCTAssertEqual(darkTraits.userInterfaceStyle, .dark)
        let after = try XCTUnwrap(composer.view.backgroundColor)
            .resolvedColor(with: darkTraits)
        XCTAssertNotEqual(before, after)
        XCTAssertEqual(after,
            ImpressV3Appearance.page.resolvedColor(with: darkTraits))
        XCTAssertEqual(selected.selectedSegmentTintColor,
                       ImpressV3Appearance.secondarySegmentSelection)
    }

    func testLocalVaultCompositeReadingProjectionUsesValidatedFileBytes() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ImpressReader-" + UUID().uuidString, isDirectory: true)
        let study = root.appendingPathComponent("Study", isDirectory: true)
        try FileManager.default.createDirectory(at: study,
            withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let canvas = """
        {"nodes":[{"id":"box","type":"text","x":0,"y":0,
        "width":160,"height":80,"text":"Vault only"}],"edges":[]}
        """
        let drawing = """
        {"type":"excalidraw","elements":[{"id":"circle","type":"ellipse",
        "x":10,"y":40,"width":100,"height":120,"strokeColor":"#123456"}]}
        """
        try Data(canvas.utf8).write(to: study.appendingPathComponent("Diagram.canvas"))
        try Data(drawing.utf8).write(to: study.appendingPathComponent("Drawing.excalidraw"))
        let identity = try ImVaultFileIdentity(
            vaultID: "reader-synthetic", relativePath: "Study/Reader-Composite.md")
        let input = """
        # Reader-Composite
        ![[Study/Diagram.canvas]]
        ![[Study/Drawing.excalidraw]]
        ~~~markdown
        ![[Study/Missing.canvas]]
        ~~~
        """
        let body = try ImVaultReadSync.safeMarkdownProjection(
            root: root, identity: identity, source: input)
        XCTAssertTrue(body.contains("~~~impress-canvas"))
        XCTAssertTrue(body.contains("~~~impress-excalidraw"))
        XCTAssertTrue(body.contains("![[Study/Missing.canvas]]"),
            "Fenced literal code must not load or replace attachment syntax")
        XCTAssertFalse(body.contains("Vault only"),
            "The geometry passes through a bounded encoded in-memory projection")
    }


    func testNativeMarkdownEmbedIsSourceBoundedAndCannotRecurse() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ImpressReaderMD-" + UUID().uuidString,
                                    isDirectory: true)
        let folder = root.appendingPathComponent("Study", isDirectory: true)
        try FileManager.default.createDirectory(at: folder,
            withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let child = "# 背景\n不可包含。\n## 事实\n仅此段与子节。\n" +
            "### 子节\n内层证据。\n# 后文\n不可包含。\n" +
            "![[Study/Child.md]]\n"
        try Data(child.utf8).write(to: folder.appendingPathComponent("Child.md"))
        let parent = try ImVaultFileIdentity(
            vaultID: "markdown-test", relativePath: "Study/Parent.md")
        let selected = try ImVaultReadSync.safeMarkdownProjection(root: root,
            identity: parent, source: "![[Study/Child.md#事实]]")
        XCTAssertTrue(selected.contains("仅此段与子节"))
        XCTAssertTrue(selected.contains("内层证据"))
        XCTAssertFalse(selected.contains("不可包含"))
        XCTAssertFalse(selected.contains("后文"))
        XCTAssertTrue(selected.contains("打开来源文件并独立选材"))
        let whole = try ImVaultReadSync.safeMarkdownProjection(root: root,
            identity: parent, source: "![[Study/Child.md]]")
        XCTAssertTrue(whole.contains("背景"))
        XCTAssertTrue(whole.contains("嵌入深度限制"))
        XCTAssertFalse(whole.contains("![[Study/Child.md]]"))
        let unsafe = try ImVaultReadSync.safeMarkdownProjection(root: root,
            identity: parent, source:
            "![[Study/Parent.md]]\n![[Study/../private.md]]\n![[Study/Missing.md]]")
        XCTAssertFalse(unsafe.contains("~~~impress-canvas"))
        XCTAssertTrue(unsafe.contains("嵌入缺失"))

        let change = "# 背景\n原文已更新。\n## 事实\n修订后内容。\n"
        try Data(change.utf8).write(to: folder.appendingPathComponent("Child.md"),
                                        options: .atomic)
        let updated = try ImVaultReadSync.safeMarkdownProjection(root: root,
            identity: parent, source: "![[Study/Child.md#事实]]")
        XCTAssertTrue(updated.contains("修订后内容"))
        XCTAssertFalse(updated.contains("内层证据"),
            "A prior preview must not be a reusable source authority")
        let block = try ImVaultReadSync.safeMarkdownProjection(root: root,
            identity: parent, source: "![[Study/Child.md#^unverified]]")
        XCTAssertTrue(block.contains("嵌入缺失"),
            "Unverified block references must not guess a source line")

        let external = FileManager.default.temporaryDirectory
            .appendingPathComponent("Impress-Out-" + UUID().uuidString + ".md")
        try Data("PRIVATE OUTSIDE".utf8).write(to: external)
        defer { try? FileManager.default.removeItem(at: external) }
        try FileManager.default.createSymbolicLink(
            at: folder.appendingPathComponent("Escaped.md"),
            withDestinationURL: external)
        let forbidden = try ImVaultReadSync.safeMarkdownProjection(root: root,
            identity: parent, source: "![[Study/Escaped.md]]")
        XCTAssertFalse(forbidden.contains("PRIVATE OUTSIDE"))
        XCTAssertTrue(forbidden.contains("嵌入缺失"),
            "A symlink escaping the authorized root cannot become read authority")
    }

    func testLocalVaultMarkdownHasNativeDarkCSSWithoutRemoteNetworkInjection() {
        let css = ImpressV3Appearance.markdownReaderCSS
        XCTAssertTrue(css.contains("prefers-color-scheme: dark"))
        XCTAssertTrue(css.contains("color-scheme: light dark"))
        XCTAssertTrue(css.contains("markdown-body"))
        XCTAssertTrue(css.contains("--im-paper"))
        XCTAssertTrue(css.contains("--im-ink"))
        XCTAssertFalse(css.contains("@import"))
        XCTAssertFalse(css.contains("url("))
        XCTAssertFalse(css.contains("<script"))
    }

    func testSwipeOverlayReResolvesCGColorOnAppearanceChange() throws {
        // Color for .down is UIColor.label: its border must invert in Dark.
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.overrideUserInterfaceStyle = .light
        let root = UIViewController()
        window.rootViewController = root
        let overlay = ImMemoryCardOverlay(direction: .down)
        root.view.addSubview(overlay)
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        window.layoutIfNeeded()
        let inner = try XCTUnwrap(overlay.subviews.first { $0.layer.borderWidth > 0 })
        let lightBorder = try XCTUnwrap(inner.layer.borderColor)
        window.overrideUserInterfaceStyle = .dark
        window.layoutIfNeeded()
        let darkBorder = try XCTUnwrap(inner.layer.borderColor)
        XCTAssertNotEqual(lightBorder, darkBorder,
                          "Core Animation colors cannot remain frozen in Light.")
    }

    func testNativeThreeTypeSelectorMatchesBatchImportNeutralSelection() throws {
        let composer = ImpressV3CardComposerViewController()
        composer.loadViewIfNeeded()
        func findSegments(_ view: UIView) -> [UISegmentedControl] {
            let own = (view as? UISegmentedControl).map { [$0] } ?? []
            return own + view.subviews.flatMap(findSegments)
        }
        let selectors = findSegments(composer.view)
        let types = try XCTUnwrap(selectors.first(where: { $0.numberOfSegments == 3 }))
        let answerMode = try XCTUnwrap(selectors.first(where: { $0.numberOfSegments == 2 }))
        XCTAssertEqual(types.selectedSegmentTintColor,
                       ImpressV3Appearance.secondarySegmentSelection)
        XCTAssertEqual(types.backgroundColor, ImpressV3Appearance.segmentTrack)
        XCTAssertEqual(types.accessibilityLabel, "卡片类型")
        XCTAssertEqual(types.selectedSegmentIndex, 0)
        XCTAssertEqual(answerMode.selectedSegmentTintColor,
                       ImpressV3Appearance.secondarySegmentSelection)
        XCTAssertEqual(answerMode.accessibilityLabel, "单选或多选")
        let attrs = types.titleTextAttributes(for: .selected)
        XCTAssertNotNil(attrs?[.font] as? UIFont)
        XCTAssertEqual(attrs?[.foregroundColor] as? UIColor,
                       ImpressV3Appearance.primaryText)
    }
    func testCentralButtonTapTargetsAndQuietSecondaryFeedback() {
        guard #available(iOS 15.0, *) else { return }
        let main = UIButton(type: .system)
        ImpressV3NativeButtonAppearance.primary(main, title: "查看答案")
        XCTAssertEqual(main.configuration?.baseBackgroundColor,
                       ImpressV3Appearance.accent)
        XCTAssertTrue(main.constraints.contains {
            $0.firstAttribute == .height &&
            $0.relation == .greaterThanOrEqual &&
            $0.constant >= ImpressV3Appearance.Metrics.primaryActionHeight
        })

        let secondary = UIButton(type: .system)
        ImpressV3NativeButtonAppearance.quiet(
            secondary, title: "选择图片", symbol: "photo")
        XCTAssertEqual(secondary.configuration?.baseBackgroundColor,
                       ImpressV3Appearance.quietControlSurface)
        XCTAssertTrue(secondary.constraints.contains {
            $0.firstAttribute == .height &&
            $0.relation == .greaterThanOrEqual &&
            $0.constant >= ImpressV3Appearance.Metrics.controlHeight
        })
    }

    func testSegmentsHaveEqualItemsAndResponsiveMaximumWidth() {
        let picker = UISegmentedControl(items: ["问答", "选择题", "图片"])
        ImpressV3Appearance.styleSegmentedControl(picker, prominent: true)
        let row = ImpressV3Appearance.segmentedRow(picker)
        row.frame = CGRect(x: 0, y: 0, width: 350, height: 50)
        row.setNeedsLayout()
        row.layoutIfNeeded()
        XCTAssertFalse(picker.apportionsSegmentWidthsByContent)
        XCTAssertEqual(picker.numberOfSegments, 3)
        XCTAssertGreaterThan(picker.bounds.width, 300)
        XCTAssertTrue(picker.constraints.contains {
            $0.firstAttribute == .height &&
            $0.relation == .greaterThanOrEqual &&
            $0.constant >= ImpressV3Appearance.Metrics.segmentHeight
        })
        row.frame.size.width = 900
        row.setNeedsLayout()
        row.layoutIfNeeded()
        XCTAssertLessThanOrEqual(
            picker.bounds.width, ImpressV3Appearance.Metrics.maximumSegmentWidth + 1)
    }

    func testBatchImportFormatSegmentsAreShortAndAccessible() throws {
        let importer = ImpressV3BatchImportViewController()
        importer.loadViewIfNeeded()
        func segments(in root: UIView) -> [UISegmentedControl] {
            let own = (root as? UISegmentedControl).map { [$0] } ?? []
            return own + root.subviews.flatMap(segments(in:))
        }
        let selector = try XCTUnwrap(segments(in: importer.view).first)
        XCTAssertEqual(selector.numberOfSegments, 4)
        XCTAssertEqual(selector.titleForSegment(at: 3), "MD")
        XCTAssertEqual(selector.accessibilityLabel, "导入格式")
        XCTAssertEqual(selector.selectedSegmentTintColor,
                       ImpressV3Appearance.secondarySegmentSelection)
    }

    func testTwelveAnswerChoicesRemainScrollableWithoutDuplicateRating() {
        guard #available(iOS 15.0, *) else { return }
        var model = ImCardModel()
        model.question = "从 12 个选项中选择正确项"
        model.cardType = CardType.multipleChoice.rawValue
        model.choices = (1...12).map { "选项 \($0)" }.joined(separator: "\n")
        model.correctAnswerIndices = "0,4"
        model.answer = "选项 1、选项 5\n\n解析：\n## 解析标题\n**原因**：" +
            String(repeating: "详细解释。", count: 70)
        let view = ImMultipleChoiceCardView(
            model: model, usesNativeOptionButtons: true)
        view.frame = CGRect(x: 0, y: 0, width: 350, height: 420)
        view.setNeedsLayout()
        view.layoutIfNeeded()
        func descendants<T: UIView>(_ root: UIView, _ type: T.Type) -> [T] {
            let own = (root as? T).map { [$0] } ?? []
            return own + root.subviews.flatMap { descendants($0, type) }
        }
        let options = descendants(view, UIButton.self)
        XCTAssertEqual(options.count, 12)
        XCTAssertEqual(descendants(view, UIScrollView.self).count, 1)
        XCTAssertTrue(options.allSatisfy { button in
            button.constraints.contains {
                $0.firstAttribute == .height &&
                $0.relation == .greaterThanOrEqual &&
                $0.constant >= ImpressV3Appearance.Metrics.answerOptionHeight
            }
        })
        XCTAssertTrue(options.allSatisfy {
            $0.configuration?.background.backgroundColor == ImpressV3Appearance.optionSurface
        })
        let explanation = descendants(view, UILabel.self).first {
            $0.accessibilityIdentifier == "impress.review.choice-explanation"
        }
        XCTAssertNotNil(explanation)
        XCTAssertTrue(explanation?.superview?.isHidden == true)
        XCTAssertFalse(view.answerIsRevealed)
        view.showAnswer()
        XCTAssertTrue(view.answerIsRevealed)
        XCTAssertFalse(explanation?.superview?.isHidden ?? true)
        XCTAssertTrue(explanation?.attributedText?.string.contains("解析标题") == true)
        XCTAssertFalse(options[0].isUserInteractionEnabled)
        XCTAssertTrue(options[0].isEnabled) // no dimmed correct-answer text
        XCTAssertEqual(options[0].configuration?.background.backgroundColor,
                       ImpressV3Appearance.correctOptionSurface)
        XCTAssertEqual(options[1].configuration?.background.backgroundColor,
                       ImpressV3Appearance.optionSurface)
    }

}

// R04.2: native creation must be separate from legacy generic ImSubmit,
// must preserve uncommitted content when switching card types, and must
// serialize choice answers without changing WCDB schema or FSRS semantics.
@MainActor
final class ImpressR042CardComposerTests: XCTestCase {
    func testChoiceSerializesWithoutSpecialSyntax() throws {
        var draft = ImpressV3CardDraft()
        draft.kind = .multipleChoice
        draft.question = "唐朝开国皇帝是谁？"
        draft.choices = [
            .init(text: "李世民", isCorrect: false),
            .init(text: "李渊", isCorrect: true),
            .init(text: "李白", isCorrect: false)
        ]
        let input = try draft.validatedInput()
        XCTAssertEqual(input.cardType, CardType.multipleChoice.rawValue)
        XCTAssertEqual(input.question, "唐朝开国皇帝是谁？")
        XCTAssertEqual(input.choices, "李世民\n李渊\n李白")
        XCTAssertEqual(input.correctIndices, "1")
        XCTAssertEqual(input.answerText, "李渊")
    }

    func testChoiceExplanationIsIndependentFromCorrectIndicesAndSurvivesLegacyReads() throws {
        var draft = ImpressV3CardDraft()
        draft.kind = .multipleChoice
        draft.question = "解释这个答案"
        draft.choices = [
            .init(text: "A", isCorrect: true),
            .init(text: "B", isCorrect: false)
        ]
        draft.answer = "## 理由\n不因为它更长。"
        let input = try draft.validatedInput()
        XCTAssertEqual(input.correctIndices, "0")
        XCTAssertEqual(input.answerText, "A\n\n解析：\n## 理由\n不因为它更长。")
        XCTAssertEqual(ImpressV3ChoiceExplanation.decode(
            try XCTUnwrap(input.answerText), correctLabels: "A"), draft.answer)
        XCTAssertEqual(ImpressV3ChoiceExplanation.decode("A", correctLabels: "A"), "")
        XCTAssertEqual(ImpressV3ChoiceExplanation.decode("原有导入解析",
            correctLabels: "A"), "原有导入解析")
    }

    func testMultipleAnswerSerializesSortedIndicesAndSourcePath() throws {
        var draft = ImpressV3CardDraft()
        draft.kind = .multipleChoice
        draft.question = "选择正确选项"
        draft.allowsMultipleCorrect = true
        draft.sourceNotePath = "知识/物理/问题.md"
        draft.choices = [
            .init(text: "C", isCorrect: true),
            .init(text: "A", isCorrect: false),
            .init(text: "B", isCorrect: true)
        ]
        let card = try draft.validatedInput()
        XCTAssertEqual(card.correctIndices, "0,2")
        XCTAssertEqual(card.sourceNotePath, "知识/物理/问题.md")
    }

    func testInvalidChoiceRefusesSaveAndDoesNotGuessCorrectAnswer() {
        var draft = ImpressV3CardDraft()
        draft.kind = .multipleChoice
        draft.question = "Question"
        draft.choices = [.init(text: "A"), .init(text: "B")]
        XCTAssertThrowsError(try draft.validatedInput())
        draft.choices[0].isCorrect = true
        draft.choices[1].text = "A"
        XCTAssertThrowsError(try draft.validatedInput())
    }

    func testSwitchingVisibleEditorPreservesQuestionAndAnswer() throws {
        let composer = ImpressV3CardComposerViewController()
        composer.loadViewIfNeeded()
        func descendants<T: UIView>(_ root: UIView, matching type: T.Type) -> [T] {
            (root as? T).map { [$0] } ?? root.subviews.flatMap { descendants($0, matching: type) }
        }
        let fields = descendants(composer.view, matching: UITextView.self)
        XCTAssertEqual(fields.count, 2)
        guard fields.count == 2 else { return }
        fields[0].text = "问题草稿"
        fields[1].text = "答案草稿"
        let switchers = descendants(composer.view, matching: UISegmentedControl.self)
        guard let picker = switchers.first(where: { $0.numberOfSegments == 3 }) else {
            return XCTFail("Missing native card type switcher")
        }
        picker.selectedSegmentIndex = 1
        picker.sendActions(for: .valueChanged)
        picker.selectedSegmentIndex = 2
        picker.sendActions(for: .valueChanged)
        picker.selectedSegmentIndex = 0
        picker.sendActions(for: .valueChanged)
        XCTAssertEqual(fields[0].text, "问题草稿")
        XCTAssertEqual(fields[1].text, "答案草稿")
    }
}
