import UIKit
import ImpressReviewCore
import AVKit
#if DEBUG
import CoreVideo
#endif

/// An opt-in V3 pilot controller. It uses the EXISTING Tinder SwipeCardStack
/// and existing answer views, but delegates every grade to the durable V3 store.
@MainActor
final class ImpressV3ReviewViewController: UIViewController {
    private struct PendingSwipe {
        let cardID: UUID
        let index: Int
        var submission: ReviewSubmission?
        var visualFinished = false
        var sentAnimationAck = false
    }

    private let injectedRepository: ReviewWCDBRepository?
    private var repository: ReviewWCDBRepository?
    private var session: ReviewSessionCoordinator?
    private var items: [ReviewQueueItem] = []
    private var models: [UUID: ImCardModel] = [:]
    private var sourceLinks: [UUID: ImVaultFileIdentity] = [:]
    private var contentRevisions: [UUID: Int] = [:]
    private var videoCards = Set<UUID>()
    /// Installed by WCDB integration owner after media metadata migration.
    /// A nil resolver preserves the original image-preview path.
    var resolveCardVideo: ((UUID, Int) async throws -> ImpressCardVideoReference?)?
    private var mediaOpening = false
    private weak var mediaPlayer: AVPlayerViewController?
    private var currentIndex = 0
    private var pending: PendingSwipe?
    private var isLoading = false
    private var hasLoaded = false
    private var needsReloadAfterCollection = false

    private let cardStack = SwipeCardStack()
    private let revealButton = UIButton(type: .system)
    private let statusLabel = UILabel()
    /// The compact status line carries the mapping; only SwipeCardStack can rate.
    private let currentCardActions = UIStackView()
    /// Dedicated tag for the card-local edit/discussion row; not a separate toolbar.
    private static let cardActionRowTag = 941226
    private let sourceNoteButton = UIButton(type: .system)
    private let completionLabel = UILabel()
    private let repeatButton = UIButton(type: .system)
    private let busyIndicator = UIActivityIndicatorView(style: .medium)

    init(repository: ReviewWCDBRepository? = nil) {
        self.injectedRepository = repository
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("Use init(repository:) for V3 reviews")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = V3L("闪卡")
        view.backgroundColor = ImpressV3Appearance.page
        setupNativeLayout()
        setupNavigation()
        // A media resolver is a read-only metadata lookup; the view itself
        // verifies answer reveal/phase and the file's SHA on a worker thread.
        resolveCardVideo = { [weak self] cardID, revision in
            guard let self else { throw ReviewWCDBError.missingCard }
            let repo = try self.injectedRepository ?? self.repository ??
                ImpressV3ReviewEnvironment.repository()
            return try await repo.videoReference(for: cardID,
                                                  contentRevision: revision)
        }
        cardStack.numberOfVisibleCards = 3
        cardStack.protectsVerticalContentScroll = true
        // V3 tap is inert. Only explicit controls can create/edit a card.
        // Keep the existing Tinder pan and image-view tap untouched.
        cardStack.delegate = self
        cardStack.dataSource = self
        if !hasLoaded { reloadSession() }
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        if let mediaPlayer, mediaPlayer.presentingViewController == nil {
            mediaPlayer.player?.pause()
            self.mediaPlayer = nil
        }
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        refreshLocalizedReview()
        if needsReloadAfterCollection && pending == nil {
            needsReloadAfterCollection = false
            reloadSession()
        } else if hasLoaded && pending == nil && items.isEmpty && !isLoading {
            // Cards created from Notes/AI candidate review enter the same WCDB
            // but do not pass through Card Collection's reload flag. Recheck
            // the *empty* queue when returning to Flashcards; do not restart
            // an ongoing review, reveal answers or modify FSRS.
            reloadSession()
        } else if hasLoaded && pending == nil {
            verifyCurrentContentOnReturn()
        }
    }

    /// Recheck the WCDB content token after leaving Chat or Notes. A changed
    /// original card must invalidate a previously revealed answer and its swipe
    /// gesture; current cardID, position and FSRS history are preserved.
    private func verifyCurrentContentOnReturn() {
        guard !isLoading, pending == nil,
              let item = items[safe: currentIndex],
              let repository = repository else { return }
        let observedRevision = contentRevisions[item.cardID] ?? -1
        cardStack.isUserInteractionEnabled = false
        revealButton.isEnabled = false
        setRatingGesturesEnabled(false)
        setCurrentCardActionsRevealed(false)
        Task { [weak self] in
            guard let self else { return }
            do {
                guard let live = try await repository.content(for: item.cardID) else {
                    throw ReviewWCDBError.missingCard
                }
                guard self.pending == nil,
                      self.items[safe: self.currentIndex] == item else { return }
                if live.contentRevision != observedRevision {
                    try await self.refreshEditedCard(live, reviewItem: item)
                }
                guard self.pending == nil,
                      self.items[safe: self.currentIndex] == item else { return }
                self.cardStack.isUserInteractionEnabled = true
                self.revealButton.isEnabled = true
                self.setRatingGesturesEnabled(self.canRateCurrentCard)
                self.setCurrentCardActionsRevealed(self.canRateCurrentCard)
            } catch {
                // Fail closed: never score an answer whose source cannot be verified.
                self.cardStack.isUserInteractionEnabled = false
                self.revealButton.isEnabled = false
                self.setRatingGesturesEnabled(false)
                self.setCurrentCardActionsRevealed(false)
                self.displayFailure(error)
            }
        }
    }

    /// Re-label the existing controls without recreating a live FSRS session.
    private func refreshLocalizedReview() {
        title = V3L("闪卡")
        setupNavigation()
        if #available(iOS 15.0, *) {
            ImpressV3NativeButtonAppearance.reviewPrimary(revealButton, title: V3L("查看答案"))
        } else {
            revealButton.setTitle(V3L("查看答案"), for: .normal)
        }
        ImpressV3Appearance.styleQuietButton(
            repeatButton, title: V3L("刷新到期卡片"))
    }

    private var canRateCurrentCard: Bool {
        guard pending == nil, currentIndex < items.count,
              let cardID = items[safe: currentIndex]?.cardID else { return false }
        if let view = cardStack.topCard?.content as? ImMemoryCardView {
            return view.answerIsRevealed && items[currentIndex].cardID == cardID
        }
        if let view = cardStack.topCard?.content as? ImMultipleChoiceCardView {
            return view.answerIsRevealed
        }
        return false
    }

    private func setupNativeLayout() {
        cardStack.translatesAutoresizingMaskIntoConstraints = false
        revealButton.translatesAutoresizingMaskIntoConstraints = false
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        currentCardActions.translatesAutoresizingMaskIntoConstraints = false
        currentCardActions.axis = .horizontal
        currentCardActions.alignment = .center
        currentCardActions.spacing = ImpressV3Appearance.Metrics.rowSpacing
        currentCardActions.isHidden = true
        for (button, icon, label, action) in [
            (sourceNoteButton, "doc.text", V3L("打开来源笔记"), #selector(openCurrentSourceNote))
        ] {
            var configuration = UIButton.Configuration.plain()
            configuration.image = UIImage(systemName: icon)
            configuration.baseForegroundColor = ImpressV3Appearance.navigationActionInk
            button.configuration = configuration
            button.accessibilityLabel = label
            button.addTarget(self, action: action, for: .touchUpInside)
            button.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                button.widthAnchor.constraint(greaterThanOrEqualToConstant: 40),
                button.heightAnchor.constraint(greaterThanOrEqualToConstant: 40)
            ])
            currentCardActions.addArrangedSubview(button)
        }
        sourceNoteButton.accessibilityIdentifier = "impress.review.source-note"
        sourceNoteButton.isHidden = true
        revealButton.setTitle(V3L("查看答案"), for: .normal)
        revealButton.titleLabel?.font = ImpressV3Appearance.Typography.heading
        revealButton.titleLabel?.adjustsFontForContentSizeCategory = true
        if #available(iOS 15.0, *) {
            ImpressV3NativeButtonAppearance.reviewPrimary(revealButton, title: V3L("查看答案"))
        } else {
            revealButton.setTitleColor(ImpressV3Appearance.reviewPrimaryInk, for: .normal)
            revealButton.backgroundColor = ImpressV3Appearance.reviewPrimarySurface
            revealButton.layer.cornerRadius = ImpressV3Appearance.Metrics.primaryActionHeight / 2
        }
        revealButton.accessibilityIdentifier = "impress.review.reveal-answer"
        cardStack.accessibilityIdentifier = "impress.review.swipe-stack"
        revealButton.addTarget(self, action: #selector(revealCurrentAnswer),
                               for: .touchUpInside)
        revealButton.accessibilityHint = V3L("显示答案后才可以通过四向滑动进行复习评分")
        revealButton.isHidden = true
        busyIndicator.translatesAutoresizingMaskIntoConstraints = false
        completionLabel.translatesAutoresizingMaskIntoConstraints = false
        repeatButton.translatesAutoresizingMaskIntoConstraints = false

        statusLabel.font = ImpressV3Appearance.Typography.supporting
        statusLabel.adjustsFontForContentSizeCategory = true
        statusLabel.textColor = ImpressV3Appearance.primaryText
        statusLabel.textAlignment = .left
        statusLabel.numberOfLines = 0
        statusLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        statusLabel.text = V3L("正在准备复习…")
        statusLabel.accessibilityIdentifier = "impress.review.rating-summary"

        completionLabel.font = ImpressV3Appearance.Typography.body
        completionLabel.textColor = ImpressV3Appearance.secondaryText
        completionLabel.textAlignment = .center
        completionLabel.numberOfLines = 0
        completionLabel.isHidden = true

        repeatButton.setTitle(V3L("刷新到期卡片"), for: .normal)
        ImpressV3Appearance.styleQuietButton(repeatButton, title: V3L("刷新到期卡片"))
        repeatButton.addTarget(self, action: #selector(refreshCards), for: .touchUpInside)
        repeatButton.isHidden = true

        view.addSubview(statusLabel)
        view.addSubview(currentCardActions)
        view.addSubview(cardStack)
        view.addSubview(revealButton)
        view.addSubview(busyIndicator)
        view.addSubview(completionLabel)
        view.addSubview(repeatButton)
        NSLayoutConstraint.activate([
            statusLabel.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 8),
            statusLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            statusLabel.trailingAnchor.constraint(lessThanOrEqualTo: currentCardActions.leadingAnchor, constant: -8),
            statusLabel.heightAnchor.constraint(greaterThanOrEqualToConstant: 44),
            currentCardActions.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -16),
            currentCardActions.centerYAnchor.constraint(equalTo: statusLabel.centerYAnchor),
            cardStack.topAnchor.constraint(equalTo: statusLabel.bottomAnchor, constant: 8),
            cardStack.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 16),
            cardStack.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -16),
            cardStack.bottomAnchor.constraint(equalTo: revealButton.topAnchor, constant: -8),
            revealButton.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: ImpressV3Appearance.Metrics.screenInset),
            revealButton.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -ImpressV3Appearance.Metrics.screenInset),
            revealButton.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -12),
            revealButton.heightAnchor.constraint(greaterThanOrEqualToConstant: ImpressV3Appearance.Metrics.primaryActionHeight),
            busyIndicator.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            busyIndicator.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            completionLabel.centerYAnchor.constraint(equalTo: view.centerYAnchor, constant: -20),
            completionLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 30),
            completionLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -30),
            repeatButton.topAnchor.constraint(equalTo: completionLabel.bottomAnchor, constant: 20),
            repeatButton.centerXAnchor.constraint(equalTo: view.centerXAnchor)
        ])
    }

    private func setupNavigation() {
        // One low-friction entry for an idea; deliberate card CRUD and batch
        // import now belong exclusively in Card Collection.
        navigationItem.leftBarButtonItem = ImpressV3Appearance.navigationAction(
            symbol: "plus", label: V3L("新增卡片"),
            target: self, action: #selector(createCard))
        updateNavigationActions()
    }

    @objc private func openQuickCapture() {
        guard presentedViewController == nil, pending == nil else { return }
        // The same durable LearningEntry journal serves standalone thoughts
        // and card-linked understanding. No new parallel storage authority.
        let capture = ImpressV3CaptureViewController(cardID: nil, question: "")
        let navigation = UINavigationController(rootViewController: capture)
        navigation.modalPresentationStyle = .pageSheet
        navigation.sheetPresentationController?.detents = [.medium(), .large()]
        present(navigation, animated: true)
    }

    private func updateNavigationActions() {
        // Notes now has its own Tab. Keep only Card Collection in the header.
        let cardCollection = ImpressV3Appearance.navigationAction(
            symbol: "square.stack", label: V3L("卡片集"),
            target: self, action: #selector(openCardCollection))
        cardCollection.accessibilityIdentifier = "impress.review.card-collection"

        navigationItem.rightBarButtonItems = [cardCollection]
    }

    @objc private func openNotes() {
        // Notes retains its existing read-only Vault permission, search,
        // attachments and folder actions. The flashcard rating transaction
        // is never changed by this navigation.
        guard navigationController?.topViewController === self else { return }
        navigationController?.pushViewController(
            ImpressNoteListTableViewController(), animated: true)
    }

    @objc private func openCardCollection() {
        guard pending == nil, !isLoading else { return }
        do {
            let store = try repository ?? ImpressV3ReviewEnvironment.repository()
            let collection = ImpressV3CardCollectionViewController(repository: store)
            collection.onMutation = { [weak self] in
                self?.needsReloadAfterCollection = true
            }
            navigationController?.pushViewController(collection, animated: true)
        } catch { displayFailure(error) }
    }

    @objc private func openCurrentTimeline() {
        showUnderstandingTimeline()
    }

    private func displayFailure(_ error: Swift.Error) {
        let alert = UIAlertController(title: V3L("复习操作未完成"),
                                      message: error.localizedDescription,
                                      preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: V3L("确定"), style: .default))
        if presentedViewController == nil { present(alert, animated: true) }
    }

    @objc private func refreshCards() { reloadSession() }

    #if DEBUG
    /// The launch flag is accepted only with a validated disposable UUID Vault.
    /// This is a real AVFoundation -> private media -> WCDB card path, not a
    /// mocked playback screen. It never runs in Release or normal Debug use.
    private func installSyntheticPlaybackFixtureIfRequested(
        in repo: ReviewWCDBRepository) async throws {
        guard ImpressV11UITestFixture.enabled,
              ProcessInfo.processInfo.arguments.contains("-ImpressV11VideoPlaybackFixture"),
              let sessionRoot = ImpressV11UITestFixture.sessionRoot else { return }
        guard try await repo.fetchQueueCandidates().isEmpty else { return }
        let fm = FileManager.default
        let directory = sessionRoot.appendingPathComponent(
            "SyntheticVideo", isDirectory: true)
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        let movie = directory.appendingPathComponent("source.mov")
        if fm.fileExists(atPath: movie.path) { try fm.removeItem(at: movie) }
        defer { try? fm.removeItem(at: movie) }
        let writer = try AVAssetWriter(outputURL: movie, fileType: .mov)
        let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: 160, AVVideoHeightKey: 120
        ])
        videoInput.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: videoInput, sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: 160,
                kCVPixelBufferHeightKey as String: 120,
                kCVPixelBufferIOSurfacePropertiesKey as String: [:]
            ])
        writer.add(videoInput)
        guard writer.startWriting() else {
            throw writer.error ?? CocoaError(.fileWriteUnknown)
        }
        writer.startSession(atSourceTime: .zero)
        guard let pool = adaptor.pixelBufferPool else {
            throw CocoaError(.fileWriteUnknown)
        }
        let deadline = Date().addingTimeInterval(15)
        for frame in [0, 1, 2, 8, 12, 15] {
            while !videoInput.isReadyForMoreMediaData && Date() < deadline {
                try await Task.sleep(for: .milliseconds(10))
            }
            guard videoInput.isReadyForMoreMediaData else {
                throw writer.error ?? CocoaError(.fileWriteUnknown)
            }
            var raw: CVPixelBuffer?
            guard CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault,
                pool, &raw) == kCVReturnSuccess, let pixelBuffer = raw else {
                throw CocoaError(.fileWriteUnknown)
            }
            CVPixelBufferLockBaseAddress(pixelBuffer, [])
            if let buffer = CVPixelBufferGetBaseAddress(pixelBuffer) {
                memset(buffer, frame.isMultiple(of: 2) ? 0x30 : 0xaa,
                       CVPixelBufferGetDataSize(pixelBuffer))
            }
            CVPixelBufferUnlockBaseAddress(pixelBuffer, [])
            guard adaptor.append(pixelBuffer,
                withPresentationTime: CMTime(value: CMTimeValue(frame), timescale: 8)) else {
                throw writer.error ?? CocoaError(.fileWriteUnknown)
            }
        }
        videoInput.markAsFinished()
        writer.endSession(atSourceTime: CMTime(value: 16, timescale: 8))
        try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<Void, Error>) in
            writer.finishWriting {
                if writer.status == .completed { continuation.resume(returning: ()) }
                else { continuation.resume(throwing: writer.error ??
                    CocoaError(.fileWriteUnknown)) }
            }
        }
        let cardID = UUID()
        let stage = try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<
                ImpressCardVideoAVFoundationExporter.Staged, Error>) in
            _ = ImpressCardVideoAVFoundationExporter.export(.init(
                sourceURL: movie, cardID: cardID, expectedContentRevision: 0)) {
                    continuation.resume(with: $0)
                }
        }
        defer { stage.discard() }
        let cover = try Data(contentsOf: stage.coverURL)
        let input = WCDBV3CardInput(cardID: cardID,
            question: "视频播放回归用合成卡片",
            answerText: "视频仅在揭示答案后可播放",
            cardType: CardType.image.rawValue, imageData: cover)
        try await repo.commitCardVideo(input, staged: stage)
        guard try await repo.reviewHistory(for: cardID).isEmpty else {
            throw ReviewWCDBError.corruptRecord
        }
    }
    #endif


    private func reloadSession() {
        guard !isLoading, pending == nil else { return }
        isLoading = true
        hasLoaded = true
        statusLabel.text = V3L("正在载入到期卡片…")
        cardStack.isUserInteractionEnabled = false
        busyIndicator.startAnimating()
        completionLabel.isHidden = true
        repeatButton.isHidden = true
        revealButton.isHidden = true
        currentCardActions.isHidden = true

        Task { [weak self] in
            guard let self = self else { return }
            do {
                let repo = try self.injectedRepository ?? ImpressV3ReviewEnvironment.repository()
                #if DEBUG
                try await self.installSyntheticPlaybackFixtureIfRequested(in: repo)
                #endif
                let candidates = try await repo.fetchQueueCandidates()
                let queue = ReviewQueueBuilder.makeQueue(from: candidates, now: Date())
                var prepared: [UUID: ImCardModel] = [:]
                var verifiedSources: [UUID: ImVaultFileIdentity] = [:]
                var verifiedRevisions: [UUID: Int] = [:]
                var verifiedVideoCards = Set<UUID>()
                // At most six cards: read each image only when selected for THIS round.
                for selected in queue {
                    guard let row = try await repo.content(for: selected.cardID) else {
                        throw ReviewWCDBError.missingCard
                    }
                    var model = ImCardModel()
                    model.question = row.question
                    model.answer = row.answerText
                    model.cardType = row.cardType
                    model.imageData = row.imageData
                    model.choices = row.choices
                    model.correctAnswerIndices = row.correctIndices
                    if let saved = row.sourceNotePath,
                       let identity = try? ImpressBatchSourceKey.decode(saved) {
                        verifiedSources[selected.cardID] = identity
                    }
                    prepared[selected.cardID] = model
                    verifiedRevisions[selected.cardID] = row.contentRevision
                    if row.videoReference != nil {
                        verifiedVideoCards.insert(selected.cardID)
                    }
                }
                self.repository = repo
                self.items = queue
                self.models = prepared
                self.sourceLinks = verifiedSources
                self.contentRevisions = verifiedRevisions
                self.videoCards = verifiedVideoCards
                self.currentIndex = 0
                self.pending = nil
                self.session = ReviewSessionCoordinator(items: queue, repository: repo)
                self.isLoading = false
                self.busyIndicator.stopAnimating()
                self.cardStack.reloadData() // ONLY for a fresh session, never per-swipe.
                self.showCurrent()
            } catch {
                self.isLoading = false
                self.busyIndicator.stopAnimating()
                self.cardStack.isHidden = true
                self.currentCardActions.isHidden = true
                self.statusLabel.text = V3L("无法读取 V3 复习数据")
                self.displayFailure(error)
            }
        }
    }

    private func showCurrent() {
        updateNavigationActions()
        guard currentIndex < items.count else {
            currentCardActions.isHidden = true
            cardStack.isHidden = true
            completionLabel.isHidden = false
            repeatButton.isHidden = false
            revealButton.isHidden = true
                completionLabel.text = items.isEmpty ? V3L("暂无到期卡片，可以稍后再来。") :
                "本轮复习完成：\(items.count) 张"
            statusLabel.text = V3L("本轮完成")
            return
        }
        currentCardActions.isHidden = false
        sourceNoteButton.isHidden = sourceLinks[items[currentIndex].cardID] == nil
        cardStack.isHidden = false
        completionLabel.isHidden = true
        repeatButton.isHidden = true
        statusLabel.text = "第 \(currentIndex + 1) / \(items.count) 张 · 先回忆，再揭示答案"
        revealButton.isHidden = false
        revealButton.isEnabled = true
        cardStack.isUserInteractionEnabled = true
        setRatingGesturesEnabled(false)
        setCurrentCardActionsRevealed(false)
    }

    private func setRatingGesturesEnabled(_ enabled: Bool) {
        cardStack.shouldRecognizeHorizontalDrag = enabled
        cardStack.shouldRecognizeVerticalDrag = enabled
        cardStack.topCard?.panGestureRecognizer.isEnabled = enabled
    }

    /// Hiding the container removes both the hit region and accessibility children.
    /// Each queued card starts hidden and only its currently revealed front face can show it.
    private func setCurrentCardActionsRevealed(_ revealed: Bool) {
        guard let actions = cardStack.topCard?.viewWithTag(Self.cardActionRowTag) else { return }
        actions.isHidden = !revealed
        actions.isUserInteractionEnabled = revealed
        actions.accessibilityElementsHidden = !revealed
    }

    private func answerChanged(cardID: UUID, revealed: Bool) {
        guard pending == nil, !isLoading,
              items[safe: currentIndex]?.cardID == cardID,
              let session = session else { return }
        Task {
            do {
                let phase = await session.phase()
                if revealed && phase == .question(cardID) {
                    try await session.revealAnswer(cardID: cardID)
                } else if !revealed && phase == .answer(cardID) {
                    try await session.hideAnswer(cardID: cardID)
                } else if (revealed && phase != .answer(cardID)) ||
                          (!revealed && phase != .question(cardID)) {
                    return
                }
                // The queued card may have changed during an async phase transition.
                guard self.pending == nil,
                      self.items[safe: self.currentIndex]?.cardID == cardID else { return }
                self.setRatingGesturesEnabled(revealed)
                self.setCurrentCardActionsRevealed(revealed && self.canRateCurrentCard)
                self.revealButton.isHidden = revealed
                self.statusLabel.text = revealed
                    ? V3L("向四个方向滑动卡片评分") + "：←" + V3L("困难") +
                        " · ↑" + V3L("良好") + " · →" + V3L("容易") +
                        " · ↓" + V3L("重来")
                    : V3L("先回忆，再查看答案")
                self.updateNavigationActions()
            } catch {
                self.setRatingGesturesEnabled(false)
                self.setCurrentCardActionsRevealed(false)
            }
        }
    }

    /// Playback is a read-only presentation: no SwipeCardStack grading,
    /// no FSRS submission, no queue mutation.
    private func openImageOrVideo(cardID: UUID, model: ImCardModel) {
        guard !isLoading, pending == nil, !mediaOpening,
              items[safe: currentIndex]?.cardID == cardID else { return }
        guard let resolveCardVideo else {
            // Existing image cards retain the original preview behavior.
            guard let bytes = model.imageData, let image = UIImage(data: bytes) else { return }
            setRatingGesturesEnabled(false)
            present(ImImagePreviewViewController(
                image: image, usesV3Appearance: true), animated: true)
            return
        }
        // The resolver is only called after the actual answer is revealed.
        // UI state alone is insufficient; verify coordinator phase as well.
        guard canRateCurrentCard, let revision = contentRevisions[cardID] else { return }
        mediaOpening = true
        Task { [weak self] in
            guard let self else { return }
            defer { self.mediaOpening = false }
            do {
                guard self.pending == nil, self.items[safe: self.currentIndex]?.cardID == cardID,
                      self.canRateCurrentCard,
                      await self.session?.phase() == .answer(cardID) else { return }
                let reference = try await resolveCardVideo(cardID, revision)
                guard self.pending == nil, self.items[safe: self.currentIndex]?.cardID == cardID,
                      self.contentRevisions[cardID] == revision, self.canRateCurrentCard,
                      await self.session?.phase() == .answer(cardID) else { return }
                guard let reference else {
                    guard let bytes = model.imageData,
                          let image = UIImage(data: bytes) else { return }
                    self.setRatingGesturesEnabled(false)
                    self.present(ImImagePreviewViewController(
                        image: image, usesV3Appearance: true), animated: true)
                    return
                }
                guard reference.belongs(to: cardID, revision: revision) else {
                    throw ImpressCardVideoPrivateStore.Failure.wrongCardOrRevision
                }
                // Streamed SHA may read up to 160 MiB; never verify on main.
                let localURL = try await Task.detached(priority: .userInitiated) {
                    let store = try ImpressCardVideoPrivateStore.applicationSupportStore()
                    return try store.verifiedPlayback(cardID: cardID,
                        contentRevision: revision, reference: reference).movieURL
                }.value
                guard self.pending == nil, self.items[safe: self.currentIndex]?.cardID == cardID,
                      self.contentRevisions[cardID] == revision, self.canRateCurrentCard,
                      await self.session?.phase() == .answer(cardID) else { return }
                let player = AVPlayer(url: localURL)
                let controller = AVPlayerViewController()
                controller.player = player
                controller.modalPresentationStyle = .fullScreen
                self.mediaPlayer = controller
                self.setRatingGesturesEnabled(false)
                self.cardStack.isUserInteractionEnabled = false
                self.present(controller, animated: true) { player.play() }
            } catch {
                self.displayFailure(error)
            }
        }
    }

    @objc private func revealCurrentAnswer() {
        guard !isLoading, pending == nil, currentIndex < items.count else { return }
        if let multiple = cardStack.topCard?.content as? ImMultipleChoiceCardView {
            multiple.showAnswer()
        } else if let standard = cardStack.topCard?.content as? ImMemoryCardView {
            standard.revealAnswerIfNeeded()
        }
    }

    @objc private func showMultiChoiceAnswer() {
        revealCurrentAnswer()
    }

    /// A direct editor; neither a knowledge-capture detour nor a new FSRS session.
    @objc private func editCurrentCard() {
        guard pending == nil, !isLoading, canRateCurrentCard,
              let item = items[safe: currentIndex] else { return }
        Task { [weak self] in
            guard let self else { return }
            do {
                let repo = try repository ?? ImpressV3ReviewEnvironment.repository()
                guard let stored = try await repo.content(for: item.cardID) else {
                    throw ReviewWCDBError.missingCard
                }
                guard self.pending == nil,
                      self.items[safe: self.currentIndex]?.cardID == item.cardID,
                      self.canRateCurrentCard else { return }
                let correct = Set((stored.correctIndices ?? "")
                    .split(separator: ",").compactMap { Int($0) })
                let choices: [ImpressV3CardDraft.Choice] =
                    (stored.choices ?? "").isEmpty
                    ? [ImpressV3CardDraft.Choice(), ImpressV3CardDraft.Choice()]
                    : (stored.choices ?? "").components(separatedBy: "\n")
                        .enumerated().map { index, value in
                            ImpressV3CardDraft.Choice(
                                text: value, isCorrect: correct.contains(index))
                        }
                let draft = ImpressV3CardDraft(
                    kind: CardType(rawValue: stored.cardType) ?? .standard,
                    question: stored.question, answer: stored.answerText ?? "",
                    choices: choices, allowsMultipleCorrect: correct.count > 1,
                    imageData: stored.imageData,
                    sourceNotePath: stored.sourceNotePath)
                let editor = ImpressV3CardComposerViewController(
                    draft: draft, editingCardID: item.cardID,
                    expectedContentRevision: stored.contentRevision,
                    editingHasVideo: stored.videoReference != nil)
                editor.onSave = { [weak self] updated in
                    guard let self else { throw CocoaError(.userCancelled) }
                    try await repo.updateManagedCard(
                        updated, expectedRevision: item.revision,
                        expectedContentRevision: stored.contentRevision)
                    // Re-read the authoritative latest content after the same
                    // atomic transaction; never grade an answer from a stale UI.
                    guard let newValue = try await repo.content(for: item.cardID) else {
                        throw ReviewWCDBError.missingCard
                    }
                    if newValue.contentRevision != stored.contentRevision {
                        try await self.refreshEditedCard(newValue, reviewItem: item)
                    } // No-op saves retain answer reveal and the live FSRS phase.
                }
                editor.onRemoveVideo = { [weak self] updated in
                    guard let self else { throw CocoaError(.userCancelled) }
                    try await repo.updateManagedCard(
                        updated, expectedRevision: item.revision,
                        expectedContentRevision: stored.contentRevision,
                        videoMutation: .remove)
                    guard let saved = try await repo.content(for: item.cardID) else {
                        throw ReviewWCDBError.missingCard
                    }
                    try await self.refreshEditedCard(saved, reviewItem: item)
                }
                editor.onSaveVideo = { [weak self] updated, stage in
                    guard let self else { throw CocoaError(.userCancelled) }
                    try await repo.commitCardVideo(updated, staged: stage,
                        expectedReviewRevision: item.revision,
                        expectedContentRevision: stored.contentRevision)
                    guard let saved = try await repo.content(for: item.cardID) else {
                        throw ReviewWCDBError.missingCard
                    }
                    try await self.refreshEditedCard(saved, reviewItem: item)
                }
                editor.onOpenContentHistory = { [weak self, weak editor] in
                    editor?.dismiss(animated: true) {
                        self?.openContentHistory()
                    }
                }
                let navigation = ImNavigationViewController(rootViewController: editor)
                navigation.modalPresentationStyle = .pageSheet
                navigation.sheetPresentationController?.detents = [.large()]
                present(navigation, animated: true)
            } catch { displayFailure(error) }
        }
    }

    private func refreshEditedCard(_ value: WCDBV3CardContent,
                                   reviewItem: ReviewQueueItem) async throws {
        guard pending == nil, items[safe: currentIndex] == reviewItem else { return }
        if let session, await session.phase() == .answer(reviewItem.cardID) {
            try await session.hideAnswer(cardID: reviewItem.cardID)
        }
        var model = ImCardModel()
        model.question = value.question
        model.answer = value.answerText
        model.cardType = value.cardType
        model.imageData = value.imageData
        model.choices = value.choices
        model.correctAnswerIndices = value.correctIndices
        models[reviewItem.cardID] = model
        contentRevisions[reviewItem.cardID] = value.contentRevision
        if value.videoReference != nil {
            videoCards.insert(reviewItem.cardID)
        } else {
            videoCards.remove(reviewItem.cardID)
        }
        sourceLinks[reviewItem.cardID] = value.sourceNotePath.flatMap {
            try? ImpressBatchSourceKey.decode($0)
        }
        sourceNoteButton.isHidden = sourceLinks[reviewItem.cardID] == nil
        // Replace ONLY the top card's view. SwipeCardStack indexes and the
        // coordinator remain unchanged, so a save cannot restart this round.
        let refreshed = cardStack(cardStack, cardForIndexAt: currentIndex)
        cardStack.topCard?.content = refreshed.content
        setRatingGesturesEnabled(false)
        setCurrentCardActionsRevealed(false)
        revealButton.isHidden = false
        statusLabel.text = V3L("先回忆，再查看答案")
    }

    /// Resolve only this card's stable Vault identity; never search by title.
    /// A read does not grant write access or modify the original Markdown.
    @objc private func openCurrentSourceNote() {
        guard !isLoading, pending == nil,
              let item = items[safe: currentIndex],
              let identity = sourceLinks[item.cardID],
              let expectedContentVersion = contentRevisions[item.cardID] else { return }
        guard ImVaultReadOnlyProbe.shared.authorizedVaultID == identity.vaultID else {
            displayFailure(ImVaultSyncFailure.wrongVault)
            return
        }
        // Use the ORIGINAL card's currently verified source key and
        // content revision, not a title or a previously cached menu entry.
        Task { [weak self] in
            guard let self else { return }
            do {
                let repo = try self.repository ?? ImpressV3ReviewEnvironment.repository()
                guard let card = try await repo.content(for: item.cardID),
                      card.contentRevision == expectedContentVersion,
                      let link = card.sourceNotePath,
                      let linkedIdentity = try ImpressBatchSourceKey.decode(link),
                      linkedIdentity == identity else {
                    throw ReviewWCDBError.contentConflict
                }
                let anchoredSection = try ImpressBatchSourceKey.sectionDigest(for: link)
                ImVaultReadSync.shared.read(identity) { [weak self] result in
                    guard let self, self.pending == nil,
                          self.items[safe: self.currentIndex]?.cardID == item.cardID,
                          ImVaultReadOnlyProbe.shared.authorizedVaultID == identity.vaultID
                    else { return }
                    switch result {
                    case let .success(document):
                        guard document.identity == identity else {
                            self.displayFailure(ImVaultSyncFailure.wrongVault)
                            return
                        }
                        self.navigationController?.pushViewController(
                            ImVaultDocumentController(
                                document: document,
                                sourceSectionDigest: anchoredSection), animated: true)
                    case let .failure(error):
                        self.displayFailure(error)
                    }
                }
            } catch { self.displayFailure(error) }
        }
    }

    @objc private func openContentHistory() {
        guard pending == nil, !isLoading,
              let item = items[safe: currentIndex] else { return }
        do {
            let repo = try repository ?? ImpressV3ReviewEnvironment.repository()
            let list = ImpressV3CardVersionHistoryViewController(
                cardID: item.cardID, expectedReviewRevision: item.revision,
                repository: repo)
            list.onRestored = { [weak self] content in
                guard let self else { return }
                try await self.refreshEditedCard(content, reviewItem: item)
            }
            navigationController?.pushViewController(list, animated: true)
        } catch { displayFailure(error) }
    }


    private func showFullQuestion(_ question: String, cardID: UUID) {
        guard pending == nil, !isLoading,
              items[safe: currentIndex]?.cardID == cardID,
              presentedViewController == nil else { return }
        let detail = UIViewController()
        detail.title = V3L("题干全文")
        detail.view.backgroundColor = ImpressV3Appearance.page
        let body = UITextView()
        body.translatesAutoresizingMaskIntoConstraints = false
        body.backgroundColor = .clear
        body.isEditable = false
        body.isSelectable = true
        body.isScrollEnabled = true
        body.adjustsFontForContentSizeCategory = true
        body.font = ImpressV3Appearance.Typography.body
        body.attributedText = MarkdownKitRenderer().parseMarkdown(question)
            ?? NSAttributedString(string: question)
        body.accessibilityIdentifier = "impress.review.full-question"
        detail.view.addSubview(body)
        NSLayoutConstraint.activate([
            body.topAnchor.constraint(equalTo: detail.view.safeAreaLayoutGuide.topAnchor),
            body.bottomAnchor.constraint(equalTo: detail.view.safeAreaLayoutGuide.bottomAnchor),
            body.leadingAnchor.constraint(equalTo: detail.view.safeAreaLayoutGuide.leadingAnchor,
                                          constant: 16),
            body.trailingAnchor.constraint(equalTo: detail.view.safeAreaLayoutGuide.trailingAnchor,
                                           constant: -16)
        ])
        detail.navigationItem.rightBarButtonItem = UIBarButtonItem(
            barButtonSystemItem: .done, target: self,
            action: #selector(closeFullQuestion))
        detail.navigationItem.rightBarButtonItem?.tintColor =
            ImpressV3Appearance.navigationActionInk
        let nav = ImNavigationViewController(rootViewController: detail)
        ImpressV3Appearance.styleNavigationBar(nav.navigationBar)
        nav.modalPresentationStyle = .pageSheet
        present(nav, animated: true)
    }

    @objc private func closeFullQuestion() { dismiss(animated: true) }

    @objc private func openAIDiscussion() {
        guard pending == nil, !isLoading, canRateCurrentCard,
              let item = items[safe: currentIndex] else { return }
        Task { [weak self] in
            guard let self else { return }
            do {
                let repo = try repository ?? ImpressV3ReviewEnvironment.repository()
                guard let latest = try await repo.content(for: item.cardID),
                      pending == nil, items[safe: currentIndex]?.cardID == item.cardID,
                      self.canRateCurrentCard else {
                    return
                }
                // Explicitly prepare only THIS card's effective content;
                // never read/upload the entire linked Obsidian document.
                // A not-yet-revealed answer may never be silently inherited
                // by a Chat created from the current question.
                let answerWasRevealed = self.canRateCurrentCard
                var context = answerWasRevealed ? (latest.answerText ?? "") : ""
                if answerWasRevealed && latest.cardType == CardType.multipleChoice.rawValue {
                    context += "\n" + V3L("全部选项：") + (latest.choices ?? "")
                    context += "\n" + V3L("正确项索引：") + (latest.correctIndices ?? "")
                }
                if latest.cardType == CardType.image.rawValue {
                    context += "\n" + V3L("这是一张图片卡，本次纯文字对话不包含图片像素。")
                }
                let prompt = ImpressAIChatPromptSelection.selectedTemplate()?.content
                    ?? UserDefaults.standard.string(forKey: "kSystemPrompt")
                let payload = ImpressV3DeepSeekHandoff.makePayload(
                    question: latest.question,
                    answer: answerWasRevealed ? context : nil,
                    userPrompt: prompt)
                let web = ImWebViewController.forReviewHandoff(text: payload)
                let navigation = ImNavigationViewController(rootViewController: web)
                navigation.modalPresentationStyle = .fullScreen
                self.present(navigation, animated: true)
            } catch { displayFailure(error) }
        }
    }

    @objc private func exploreFromAnswer() {
        guard let current = items[safe: currentIndex],
              let model = models[current.cardID],
              let question = model.question, !question.isEmpty else { return }

        // Explicit handoff to DeepSeek Web, NOT the separate native API chat.
        // Preparing clipboard text does not transmit a private question.
        // The user explicitly chooses when to copy/paste and send.
        let payload = ImpressV3DeepSeekHandoff.makePayload(
            question: question,
            answer: model.answer,
            userPrompt: UserDefaults.standard.string(forKey: "kSystemPrompt"))
        let web = ImWebViewController.forReviewHandoff(text: payload)
        navigationController?.pushViewController(web, animated: true)
        // The current ReviewSessionCoordinator/SwipeCardStack stays alive.
        // Navigating back must not grade or reload the current card.
    }

    private func captureUnderstanding() {
        let item = items[safe: currentIndex]
        let editor = ImpressV3CaptureViewController(
            cardID: item?.cardID, question: item.flatMap { models[$0.cardID]?.question } ?? "")
        let nav = UINavigationController(rootViewController: editor)
        if #available(iOS 15.0, *) {
            nav.sheetPresentationController?.detents = [.medium(), .large()]
        }
        present(nav, animated: true)
    }

    private func showUnderstandingTimeline() {
        let item = items[safe: currentIndex]
        let history = ImpressV3TimelineViewController(
            cardID: item?.cardID, repository: repository)
        navigationController?.pushViewController(history, animated: true)
    }

    private func startBatchImport() {
        guard pending == nil, !isLoading else { return }
        let importVC = ImpressV3BatchImportViewController()
        importVC.onCommit = { [weak self] inputs in
            guard let self else { throw CocoaError(.userCancelled) }
            let store = try self.repository ?? ImpressV3ReviewEnvironment.repository()
            let now = Date()
            let calculator = FSRS6ReviewCalculator()
            let entries = try inputs.map { input in
                (input: input, initial: try calculator.newCardSnapshot(id: input.cardID, now: now))
            }
            _ = try await store.insertBatchCards(entries, now: now)
            // Do not rewind a live review; new cards join a future session.
            if self.items.isEmpty, self.pending == nil, !self.isLoading {
                self.reloadSession()
            }
        }
        let navigation = ImNavigationViewController(rootViewController: importVC)
        navigation.modalPresentationStyle = .pageSheet
        navigation.sheetPresentationController?.detents = [.large()]
        present(navigation, animated: true)
    }

    @objc private func createCard() {
        guard pending == nil, !isLoading else { return }
        // Dedicated V3 native editor. Legacy generic ImSubmit remains for
        // other callers; new cards use the same V3 WCDB and FSRS-6 authority.
        let composer = ImpressV3CardComposerViewController()
        composer.onSave = { [weak self] input in
            guard let self else { throw CocoaError(.userCancelled) }
            let store = try self.repository ?? ImpressV3ReviewEnvironment.repository()
            let now = Date()
            let initial = try FSRS6ReviewCalculator().newCardSnapshot(
                id: input.cardID, now: now)
            try await store.insertNewCard(input, initial: initial, now: now)
            // Never restart a live review or reveal/grade a card as a side
            // effect of creating content. Empty sessions may reload once.
            if self.items.isEmpty, self.pending == nil, !self.isLoading {
                self.reloadSession()
            }
        }
        // Main Flashcards creation must have the same CAS media owner as
        // Card Collection. A staged video is not a saved card.
        composer.onSaveVideo = { [weak self] input, stage in
            guard let self else { throw CocoaError(.userCancelled) }
            let repository = try self.repository ?? ImpressV3ReviewEnvironment.repository()
            try await repository.commitCardVideo(input, staged: stage)
            if self.items.isEmpty, self.pending == nil, !self.isLoading {
                self.reloadSession()
            }
        }
        let navigation = ImNavigationViewController(rootViewController: composer)
        navigation.modalPresentationStyle = .pageSheet
        if #available(iOS 15.0, *) {
            navigation.sheetPresentationController?.detents = [.large()]
        }
        present(navigation, animated: true)
    }

    private func enableReminders() {
        ImpressV3NotificationCoordinator.shared.requestPermissionFromUserAction { [weak self] success in
            guard let self = self else { return }
            if success {
                ImpressV3NotificationCoordinator.shared.enableSmartReminders()
            } else {
                let alert = UIAlertController(title: V3L("通知未授权"),
                                              message: "可以在 iOS 设置中允许 Impress 的通知。",
                                              preferredStyle: .alert)
                alert.addAction(UIAlertAction(title: V3L("确定"), style: .default))
                self.present(alert, animated: true)
            }
        }
    }

    private func requestHabitReminders() {
        ImpressV3NotificationCoordinator.shared.requestPermissionFromUserAction { [weak self] success in
            guard let self = self else { return }
            if success {
                ImpressV3NotificationCoordinator.shared.enableHabitReminders()
            } else {
                let alert = UIAlertController(title: V3L("通知未授权"),
                                              message: "可以在 iOS 设置中允许 Impress 的通知。",
                                              preferredStyle: .alert)
                alert.addAction(UIAlertAction(title: V3L("确定"), style: .default))
                self.present(alert, animated: true)
            }
        }
    }

    private func acknowledgeAnimationIfReady() {
        guard var p = pending,
              p.visualFinished,
              !p.sentAnimationAck,
              let request = p.submission,
              let session = session else { return }
        p.sentAnimationAck = true
        pending = p
        Task {
            do {
                let effect = try await session.animationDidFinish(eventID: request.eventID)
                apply(effect)
            } catch {
                recoverUnexpectedError(error, cardID: request.cardID)
            }
        }
    }

    private func apply(_ effect: ReviewFlowEffect) {
        switch effect {
        case .none:
            return
        case let .showNext(expected):
            guard pending != nil else { return }
            currentIndex += 1
            pending = nil
            guard items[safe: currentIndex]?.cardID == expected else {
                reloadSession()
                return
            }
            showCurrent()
            ImpressV3NotificationCoordinator.shared.requestReconciliation()
        case .sessionCompleted:
            pending = nil
            currentIndex = items.count
            showCurrent()
            ImpressV3NotificationCoordinator.shared.requestReconciliation()
        case let .restoreCard(id):
            guard pending?.cardID == id else { return }
            // On failure, no rating was committed: use the component's native
            // undo without a second grading event. Only error path is nonanimated.
            cardStack.undoLastSwipe(animated: false)
            guard let session = session else { return }
            Task {
                do {
                    try await session.recoveryDidFinish(cardID: id)
                    pending = nil
                    cardStack.isUserInteractionEnabled = true
                    if let cardView = cardStack.topCard?.content as? ImMemoryCardView {
                        cardView.revealAnswerIfNeeded()
                    } else if let choicesView = cardStack.topCard?.content as? ImMultipleChoiceCardView {
                        choicesView.showAnswer()
                    }
                    setRatingGesturesEnabled(false) // Reveal callback re-enables after the animation.
                    statusLabel.text = V3L("保存未成功，请重新滑动评分")
                    updateNavigationActions()
                } catch { recoverUnexpectedError(error, cardID: id) }
            }
        }
    }

    private func recoverUnexpectedError(_ error: Swift.Error, cardID: UUID) {
        pending = nil
        // If the coordinator and visual stack disagree, reload from the
        // durable database rather than risking a second grade for the wrong card.
        cardStack.isUserInteractionEnabled = false
        reloadSession()
        displayFailure(error)
    }
}

extension ImpressV3ReviewViewController: SwipeCardStackDataSource, SwipeCardStackDelegate {
    func numberOfCards(in cardStack: SwipeCardStack) -> Int {
        items.count
    }

    func cardStack(_ cardStack: SwipeCardStack, cardForIndexAt index: Int) -> SwipeCard {
        let card = SwipeCard()
        // The shared stack forwards top-card taps to its optional legacy
        // didSelect route. V3 must never interpret an answer tap as Create.
        card.tapGestureRecognizer.isEnabled = false
        card.swipeDirections = [.left, .up, .right, .down]
        for direction in card.swipeDirections {
            card.setOverlay(ImpressV3RatingOverlay(direction: direction), forDirection: direction)
        }
        guard let item = items[safe: index], let model = models[item.cardID] else {
            return card
        }
        if model.cardType == CardType.multipleChoice.rawValue {
            let multiple = ImMultipleChoiceCardView(model: model, usesNativeOptionButtons: true)
            multiple.onFullQuestionRequested = { [weak self] in
                self?.showFullQuestion(model.question ?? "", cardID: item.cardID)
            }
            multiple.onAnswerRevealed = { [weak self] in
                self?.answerChanged(cardID: item.cardID, revealed: true)
            }
            card.content = multiple
        } else {
            let content = ImMemoryCardView(model: model, v3Style: true)
            content.showsVideoPlayIndicator = videoCards.contains(item.cardID)
            content.onFullQuestionRequested = { [weak self] in
                self?.showFullQuestion(model.question ?? "", cardID: item.cardID)
            }
            content.onAnswerVisibilityChanged = { [weak self] revealed in
                self?.answerChanged(cardID: item.cardID, revealed: revealed)
            }
            if model.cardType == CardType.image.rawValue {
                content.onImageTapped = { [weak self] in
                    self?.openImageOrVideo(cardID: item.cardID, model: model)
                }
            }
            card.content = content
        }
        // Both actions belong to the card, not an external toolbar or menu.
        let actions = UIStackView()
        actions.axis = .horizontal
        actions.spacing = 4
        actions.translatesAutoresizingMaskIntoConstraints = false
        actions.tag = Self.cardActionRowTag
        actions.isHidden = true
        actions.isUserInteractionEnabled = false
        actions.accessibilityElementsHidden = true
        actions.backgroundColor = ImpressV3Appearance.surface
        actions.layer.cornerRadius = 14
        let cardButtons: [(String, String, String, Selector)] = [
            ("square.and.pencil", V3L("编辑当前卡片"),
             "impress.review.quick-edit", #selector(editCurrentCard)),
            ("bubble.left", V3L("AI 讨论"),
             "impress.review.ai-discussion", #selector(openAIDiscussion))
        ]
        for (symbol, label, identifier, action) in cardButtons {
            let button = UIButton(type: .system)
            var configuration = UIButton.Configuration.plain()
            configuration.image = UIImage(systemName: symbol)
            configuration.baseForegroundColor = ImpressV3Appearance.navigationActionInk
            button.configuration = configuration
            button.accessibilityLabel = label
            button.accessibilityIdentifier = identifier
            button.addTarget(self, action: action, for: .touchUpInside)
            button.widthAnchor.constraint(greaterThanOrEqualToConstant: 44).isActive = true
            button.heightAnchor.constraint(greaterThanOrEqualToConstant: 44).isActive = true
            actions.addArrangedSubview(button)
        }
        card.addSubview(actions)
        NSLayoutConstraint.activate([
            actions.topAnchor.constraint(equalTo: card.topAnchor, constant: 8),
            actions.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -8)
        ])
        card.content?.backgroundColor = ImpressV3Appearance.surface
        card.backgroundColor = ImpressV3Appearance.surface
        card.layer.cornerRadius = ImpressV3Appearance.Radius.card
        card.clipsToBounds = true
        card.layer.borderWidth = 0
        return card
    }

    func cardStack(_ cardStack: SwipeCardStack,
                   didSwipeCardAt index: Int,
                   with direction: SwipeDirection) {
        guard !isLoading, pending == nil,
              let item = items[safe: index],
              index == currentIndex, let session = session else {
            cardStack.isUserInteractionEnabled = false
            return
        }
        let rating: ReviewRating
        switch direction {
        case .left: rating = .hard
        case .up: rating = .good
        case .right: rating = .easy
        case .down: rating = .again
        }
        let eventID = UUID()
        pending = PendingSwipe(cardID: item.cardID, index: index)
        cardStack.isUserInteractionEnabled = false
        setRatingGesturesEnabled(false)
        Task {
            do {
                let submission = try await session.beginSwipe(
                    cardID: item.cardID, rating: rating,
                    at: Date(), eventID: eventID
                )
                guard pending?.cardID == item.cardID else { return }
                pending?.submission = submission
                acknowledgeAnimationIfReady()
                let effect = try await session.commitPending(submission)
                apply(effect)
            } catch {
                recoverUnexpectedError(error, cardID: item.cardID)
            }
        }
    }

    func cardStack(_ cardStack: SwipeCardStack,
                   didFinishSwipeCardAt index: Int, with direction: SwipeDirection) {
        guard pending?.index == index else { return }
        pending?.visualFinished = true
        acknowledgeAnimationIfReady()
    }

    func didSwipeAllCards(_ cardStack: SwipeCardStack) {
        // Intentionally do nothing: the final ReviewEvent and animation must
        // BOTH be committed before ReviewSessionCoordinator emits completion.
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}


// MARK: - V3.1 optional capture and understanding history
// Stored in a separate private, atomic journal. No legacy-card/FSRS schema
// changes, no Obsidian write, and cancelling NEVER creates a record.
struct ImpressV3LearningRevision: Codable, Equatable {
    let priorAnswer: String
    let replacedAt: Date
}

struct ImpressV3LearningEntry: Codable, Equatable {
    let id: UUID
    let cardID: UUID?
    let question: String
    var userAnswer: String
    let createdAt: Date
    var aiEvaluation: String?
    // Optional for transparent decoding of legacy LearningEntry-v1.json files.
    var revisions: [ImpressV3LearningRevision]? = nil
}

enum ImpressV3LearningEditError: LocalizedError {
    case missing, outdated, emptyAnswer, tooLong
    var errorDescription: String? {
        switch self {
        case .missing: return "原理解记录已不存在，未保存修改。"
        case .outdated: return "记录已在另一处更新，请重新打开后再修改。"
        case .emptyAnswer: return "理解内容不能留空。"
        case .tooLong: return "理解内容超出当前支持的长度，请精简后保存。"
        }
    }
}

enum ImpressV3LearningJournal {
    private static let lock = NSRecursiveLock()
    private static func storeURL() throws -> URL {
        let base = try FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: true)
        let path = base.appendingPathComponent("ImpressV3", isDirectory: true)
        try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true)
        return path.appendingPathComponent("LearningEntry-v1.json")
    }

    private static func load(at path: URL) throws -> [ImpressV3LearningEntry] {
        guard FileManager.default.fileExists(atPath: path.path) else { return [] }
        return try JSONDecoder().decode([ImpressV3LearningEntry].self,
                                        from: Data(contentsOf: path))
    }

    static func load() throws -> [ImpressV3LearningEntry] {
        lock.lock()
        defer { lock.unlock() }
        return try load(at: storeURL())
    }

    static func save(_ entry: ImpressV3LearningEntry) throws {
        lock.lock()
        defer { lock.unlock() }
        var records = try load()
        guard !records.contains(where: { $0.id == entry.id }) else { return }
        records.append(entry)
        try persist(records)
    }

    static func attachFeedback(_ feedback: String, to entryID: UUID) throws {
        lock.lock()
        defer { lock.unlock() }
        var records = try load()
        guard let i = records.firstIndex(where: { $0.id == entryID }) else {
            throw CocoaError(.fileNoSuchFile)
        }
        records[i].aiEvaluation = feedback
        try persist(records)
    }

    /// A compare-and-save edit protects the original answer and retains
    /// previous versions without modifying FSRS events or historic AI feedback.
    static func updateAnswer(id: UUID, expectedAnswer: String,
                             editedAnswer: String) throws -> ImpressV3LearningEntry {
        try updateAnswer(id: id, expectedAnswer: expectedAnswer,
                         editedAnswer: editedAnswer, at: nil, now: Date())
    }

    #if DEBUG
    static func testUpdateAnswer(id: UUID, expectedAnswer: String,
                                 editedAnswer: String, at url: URL,
                                 now: Date = Date()) throws -> ImpressV3LearningEntry {
        try updateAnswer(id: id, expectedAnswer: expectedAnswer,
                         editedAnswer: editedAnswer, at: url, now: now)
    }
    #endif

    private static func updateAnswer(id: UUID, expectedAnswer: String,
                                     editedAnswer: String, at url: URL?,
                                     now: Date) throws -> ImpressV3LearningEntry {
        lock.lock()
        defer { lock.unlock() }
        guard !editedAnswer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ImpressV3LearningEditError.emptyAnswer
        }
        guard editedAnswer.utf8.count <= 100_000 else {
            throw ImpressV3LearningEditError.tooLong
        }
        let path = try url ?? storeURL()
        var records = try load(at: path)
        guard let index = records.firstIndex(where: { $0.id == id }) else {
            throw ImpressV3LearningEditError.missing
        }
        guard records[index].userAnswer == expectedAnswer else {
            throw ImpressV3LearningEditError.outdated
        }
        if editedAnswer == expectedAnswer { return records[index] }
        var revisions = records[index].revisions ?? []
        revisions.append(ImpressV3LearningRevision(
            priorAnswer: records[index].userAnswer, replacedAt: now))
        records[index].revisions = revisions
        records[index].userAnswer = editedAnswer
        try persist(records, to: path, notifyBackup: url == nil)
        return records[index]
    }

    private static func persist(_ entries: [ImpressV3LearningEntry],
                                to target: URL? = nil,
                                notifyBackup: Bool = true) throws {
        let url = try target ?? storeURL()
        let data = try JSONEncoder().encode(entries)
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes(
            [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
            ofItemAtPath: url.path)
        // WCDB/JSON Date round-trips may round fractional seconds. Compare
        // durable content and allow sub-millisecond Date precision differences.
        let verified = try JSONDecoder().decode(
            [ImpressV3LearningEntry].self, from: Data(contentsOf: url))
        guard verified.count == entries.count,
              zip(verified, entries).allSatisfy({ persisted, original in
                  persisted.id == original.id &&
                  persisted.cardID == original.cardID &&
                  persisted.question == original.question &&
                  persisted.userAnswer == original.userAnswer &&
                  persisted.aiEvaluation == original.aiEvaluation &&
                  abs(persisted.createdAt.timeIntervalSince(original.createdAt)) < 0.002 &&
                  (persisted.revisions ?? []).count == (original.revisions ?? []).count &&
                  zip(persisted.revisions ?? [], original.revisions ?? [])
                      .allSatisfy { a, b in
                          a.priorAnswer == b.priorAnswer &&
                          abs(a.replacedAt.timeIntervalSince(b.replacedAt)) < 0.002
                      }
              }) else {
            throw CocoaError(.fileWriteUnknown)
        }
        if notifyBackup { ImpressV3BackupCoordinator.markDataChanged() }
    }
}

@MainActor
final class ImpressV3CaptureViewController: UIViewController {
    private let cardID: UUID?
    private let question: String
    private let input = UITextView()
    var onSaved: (() -> Void)?

    init(cardID: UUID?, question: String) {
        self.cardID = cardID
        self.question = question
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError("init(cardID:question:) required") }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = V3L("记录理解")
        view.backgroundColor = ImpressV3Appearance.page
        let subtitle = UILabel()
        subtitle.text = question.isEmpty ? V3L("记录此刻的想法") : question
        subtitle.numberOfLines = 3
        subtitle.textColor = ImpressV3Appearance.secondaryText
        subtitle.font = ImpressV3Appearance.Typography.supporting
        subtitle.translatesAutoresizingMaskIntoConstraints = false

        input.backgroundColor = ImpressV3Appearance.surface
        input.font = ImpressV3Appearance.Typography.body
        input.textColor = ImpressV3Appearance.primaryText
        input.textContainerInset = UIEdgeInsets(top: 14, left: 14, bottom: 14, right: 14)
        input.layer.cornerRadius = ImpressV3Appearance.Radius.field
        input.translatesAutoresizingMaskIntoConstraints = false
        input.accessibilityLabel = V3L("本次理解的文字记录")
        ImpressSpeechAccessory.install(on: input)
        view.addSubview(subtitle)
        view.addSubview(input)
        NSLayoutConstraint.activate([
            subtitle.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 20),
            subtitle.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -20),
            subtitle.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 12),
            input.topAnchor.constraint(equalTo: subtitle.bottomAnchor, constant: 14),
            input.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 16),
            input.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -16),
        ])
        // The keyboard can cover most of a medium detent on small phones.
        // Allow the input to shrink rather than creating required conflicts.
        let minimumInput = input.heightAnchor.constraint(greaterThanOrEqualToConstant: 96)
        minimumInput.priority = .defaultLow
        minimumInput.isActive = true
        if #available(iOS 15.0, *) {
            input.bottomAnchor.constraint(
                equalTo: view.keyboardLayoutGuide.topAnchor, constant: -12).isActive = true
        } else {
            input.bottomAnchor.constraint(
                equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -12).isActive = true
        }
        navigationItem.leftBarButtonItem = UIBarButtonItem(
            barButtonSystemItem: .cancel, target: self, action: #selector(cancel))
        navigationItem.rightBarButtonItem = UIBarButtonItem(
            title: V3L("提交"), style: .plain, target: self, action: #selector(save))
    }

    @objc private func cancel() { dismiss(animated: true) }

    @objc private func save() {
        let value = input.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return }
        let entry = ImpressV3LearningEntry(id: UUID(), cardID: cardID,
            question: question, userAnswer: value, createdAt: Date(),
            aiEvaluation: nil)
        do {
            try ImpressV3LearningJournal.save(entry)
            dismiss(animated: true) { [weak self] in self?.onSaved?() }
        } catch {
            let alert = UIAlertController(title: V3L("记录未保存"),
                message: error.localizedDescription, preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: V3L("确定"), style: .default))
            present(alert, animated: true)
        }
    }
}

// The timeline is one chronological stream, not two ordinary list sections.
@MainActor
final class ImpressV3TimelineViewController: UITableViewController {
    private enum Event {
        case understanding(ImpressV3LearningEntry)
        case review(ReviewEvent)

        var time: Date {
            switch self {
            case .understanding(let entry): return entry.createdAt
            case .review(let event): return event.reviewedAt
            }
        }
    }
    private let cardID: UUID?
    private let repository: ReviewWCDBRepository?
    private var notes: [ImpressV3LearningEntry] = []
    private var reviewEvents: [ReviewEvent] = []
    private var ordered: [Event] {
        (notes.map { Event.understanding($0) } + reviewEvents.map { Event.review($0) })
            .sorted { a, b in a.time > b.time }
    }

    init(cardID: UUID?, repository: ReviewWCDBRepository?) {
        self.cardID = cardID
        self.repository = repository
        super.init(style: .plain)
    }
    required init?(coder: NSCoder) { fatalError("init(cardID:repository:) required") }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = V3L("理解时间线")
        navigationItem.largeTitleDisplayMode = .never
        tableView.backgroundColor = ImpressV3Appearance.page
        tableView.separatorStyle = .none
        tableView.rowHeight = UITableView.automaticDimension
        tableView.estimatedRowHeight = 104
        tableView.register(ImpressV3TimelineNodeCell.self, forCellReuseIdentifier: "timeline.node")
        updateEmptyState()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        reloadLearningHistory()
        if let cardID, let repo = repository {
            Task { [weak self] in
                do {
                    let result = try await repo.reviewHistory(for: cardID)
                    self?.reviewEvents = result
                    self?.tableView.reloadData()
                    self?.updateEmptyState()
                } catch {
                    // Do not modify WCDB or erase previously loaded cognition entries.
                    NSLog("Review history currently unavailable")
                }
            }
        }
    }

    private func reloadLearningHistory() {
        do {
            notes = try ImpressV3LearningJournal.load()
                .filter { cardID == nil || $0.cardID == cardID }
        } catch {
            let alert = UIAlertController(title: V3L("读取历史失败"),
                message: error.localizedDescription, preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: V3L("确定"), style: .default))
            if presentedViewController == nil { present(alert, animated: true) }
        }
        tableView.reloadData()
        updateEmptyState()
    }

    private func updateEmptyState() {
        let empty = UILabel()
        empty.font = ImpressV3Appearance.Typography.body
        empty.adjustsFontForContentSizeCategory = true
        empty.textColor = ImpressV3Appearance.secondaryText
        empty.numberOfLines = 0
        empty.textAlignment = .center
        empty.text = V3L("还没有记录。\n回答、回顾和评价完成后会按时间展示在这里。")
        tableView.backgroundView = ordered.isEmpty ? empty : nil
    }

    override func tableView(_ tableView: UITableView,
                            numberOfRowsInSection section: Int) -> Int { ordered.count }

    override func tableView(_ tableView: UITableView,
                            cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        guard let cell = tableView.dequeueReusableCell(
            withIdentifier: "timeline.node", for: indexPath
        ) as? ImpressV3TimelineNodeCell else { return UITableViewCell() }
        switch ordered[indexPath.row] {
        case .understanding(let entry):
            cell.configure(time: entry.createdAt, title: V3L("理解记录"),
                           excerpt: entry.userAnswer,
                           footnote: entry.aiEvaluation == nil ? V3L("未评价") : V3L("含历史 AI 评价"),
                           emphasized: true)
        case .review(let event):
            let rating: String
            switch event.rating {
            case .again: rating = V3L("重来")
            case .hard: rating = V3L("困难")
            case .good: rating = V3L("良好")
            case .easy: rating = V3L("容易")
            }
            cell.configure(time: event.reviewedAt, title: "复习 · " + rating,
                           excerpt: "FSRS-6 · 修订 \(event.before.revision) → \(event.after.revision)",
                           footnote: V3L("真实评分事件"), emphasized: false)
        }
        return cell
    }

    override func tableView(_ tableView: UITableView,
                            didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        guard ordered.indices.contains(indexPath.row) else { return }
        switch ordered[indexPath.row] {
        case .understanding(let entry):
            navigationController?.pushViewController(
                ImpressV3UnderstandingDetailViewController(entry: entry),
                animated: true)
        case .review(let event):
            let rating: String
            switch event.rating {
            case .again: rating = V3L("重来")
            case .hard: rating = V3L("困难")
            case .good: rating = V3L("良好")
            case .easy: rating = V3L("容易")
            }
            let date = DateFormatter()
            date.dateStyle = .medium
            date.timeStyle = .short
            let details = "评分\n" + rating +
                "\n\n发生时间\n" + date.string(from: event.reviewedAt) +
                "\n\n复习修订\n\(event.before.revision) → \(event.after.revision)" +
                "\n\n下一次到期\n" + date.string(from: event.after.dueAt)
            navigationController?.pushViewController(
                makeTextDetail(title: V3L("复习记录"), content: details), animated: true)
        }
    }

    private func makeTextDetail(title: String, content: String) -> UIViewController {
        let detail = UIViewController()
        detail.title = title
        detail.navigationItem.largeTitleDisplayMode = .never
        detail.view.backgroundColor = ImpressV3Appearance.page
        let body = UITextView()
        body.isEditable = false
        body.isSelectable = true
        body.font = ImpressV3Appearance.Typography.body
        body.adjustsFontForContentSizeCategory = true
        body.textColor = ImpressV3Appearance.primaryText
        body.backgroundColor = ImpressV3Appearance.surface
        body.layer.cornerRadius = ImpressV3Appearance.Radius.field
        body.text = content
        body.textContainerInset = UIEdgeInsets(top: ImpressV3Appearance.Metrics.fieldPadding, left: ImpressV3Appearance.Metrics.fieldPadding,
                                             bottom: ImpressV3Appearance.Metrics.fieldPadding, right: ImpressV3Appearance.Metrics.fieldPadding)
        body.translatesAutoresizingMaskIntoConstraints = false
        detail.view.addSubview(body)
        NSLayoutConstraint.activate([
            body.leadingAnchor.constraint(
                equalTo: detail.view.safeAreaLayoutGuide.leadingAnchor, constant: ImpressV3Appearance.Metrics.screenInset),
            body.trailingAnchor.constraint(
                equalTo: detail.view.safeAreaLayoutGuide.trailingAnchor, constant: -ImpressV3Appearance.Metrics.screenInset),
            body.topAnchor.constraint(
                equalTo: detail.view.safeAreaLayoutGuide.topAnchor, constant: ImpressV3Appearance.Metrics.compactInset),
            body.bottomAnchor.constraint(
                equalTo: detail.view.safeAreaLayoutGuide.bottomAnchor, constant: -ImpressV3Appearance.Metrics.compactInset)
        ])
        return detail
    }
}

/// The editable understanding body is not an FSRS grade. Edits preserve a
/// separate historical answer version; original AI evaluation is read-only.
@MainActor
final class ImpressV3UnderstandingDetailViewController: UITableViewController {
    private var entry: ImpressV3LearningEntry

    init(entry: ImpressV3LearningEntry) {
        self.entry = entry
        super.init(style: .insetGrouped)
    }
    required init?(coder: NSCoder) { fatalError("init(entry:) required") }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = V3L("理解记录")
        navigationItem.largeTitleDisplayMode = .never
        ImpressV3Appearance.styleGroupedTable(tableView)
        navigationItem.rightBarButtonItem = UIBarButtonItem(
            title: V3L("编辑"), style: .plain, target: self, action: #selector(editAnswer))
        navigationItem.rightBarButtonItem?.accessibilityIdentifier = "impress.learning.edit"
    }

    override func numberOfSections(in tableView: UITableView) -> Int {
        (entry.revisions ?? []).isEmpty ? 3 : 4
    }

    override func tableView(_ tableView: UITableView,
                            numberOfRowsInSection section: Int) -> Int {
        section == 3 ? (entry.revisions ?? []).count : 1
    }

    override func tableView(_ tableView: UITableView,
                            titleForHeaderInSection section: Int) -> String? {
        switch section {
        case 0: return V3L("原始题目")
        case 1: return V3L("我的理解")
        case 2: return V3L("历史 AI 评价（只读）")
        default: return V3L("之前的版本 · 不会被覆盖")
        }
    }

    override func tableView(_ tableView: UITableView,
                            titleForFooterInSection section: Int) -> String? {
        section == 1 ? V3L("修改理解会保存上一版本，不影响既有复习评分和历史评价。") : nil
    }

    override func tableView(_ tableView: UITableView,
                            cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "learning.detail")
            ?? UITableViewCell(style: .subtitle, reuseIdentifier: "learning.detail")
        var content = UIListContentConfiguration.subtitleCell()
        content.textProperties.font = ImpressV3Appearance.Typography.body
        content.textProperties.color = ImpressV3Appearance.primaryText
        content.textProperties.numberOfLines = 0
        content.secondaryTextProperties.font = ImpressV3Appearance.Typography.footnote
        content.secondaryTextProperties.color = ImpressV3Appearance.secondaryText
        content.secondaryTextProperties.numberOfLines = 1
        cell.accessoryType = .none
        cell.selectionStyle = .none
        switch indexPath.section {
        case 0: content.text = entry.question
        case 1: content.text = entry.userAnswer
        case 2: content.text = entry.aiEvaluation ?? V3L("尚未评价")
        default:
            let revisions = Array((entry.revisions ?? []).reversed())
            let prior = revisions[indexPath.row]
            content.text = prior.priorAnswer
            let date = DateFormatter()
            date.dateStyle = .medium
            date.timeStyle = .short
            content.secondaryText = date.string(from: prior.replacedAt)
            content.textProperties.numberOfLines = 3
            cell.accessoryType = .disclosureIndicator
            cell.selectionStyle = .default
        }
        cell.contentConfiguration = content
        ImpressV3Appearance.styleGroupedCell(cell)
        return cell
    }

    override func tableView(_ tableView: UITableView,
                            didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        guard indexPath.section == 3 else { return }
        let revisions = Array((entry.revisions ?? []).reversed())
        guard revisions.indices.contains(indexPath.row) else { return }
        let detail = UIViewController()
        detail.title = V3L("历史版本")
        detail.view.backgroundColor = ImpressV3Appearance.page
        let body = UITextView()
        ImpressV3Appearance.styleReadingTextView(body)
        body.text = revisions[indexPath.row].priorAnswer
        body.translatesAutoresizingMaskIntoConstraints = false
        detail.view.addSubview(body)
        NSLayoutConstraint.activate([
            body.topAnchor.constraint(equalTo: detail.view.safeAreaLayoutGuide.topAnchor,
                                      constant: ImpressV3Appearance.Metrics.compactInset),
            body.bottomAnchor.constraint(equalTo: detail.view.safeAreaLayoutGuide.bottomAnchor,
                                         constant: -ImpressV3Appearance.Metrics.compactInset),
            body.leadingAnchor.constraint(equalTo: detail.view.safeAreaLayoutGuide.leadingAnchor,
                                          constant: ImpressV3Appearance.Metrics.screenInset),
            body.trailingAnchor.constraint(equalTo: detail.view.safeAreaLayoutGuide.trailingAnchor,
                                           constant: -ImpressV3Appearance.Metrics.screenInset)
        ])
        navigationController?.pushViewController(detail, animated: true)
    }

    @objc private func editAnswer() {
        navigationController?.pushViewController(
            ImpressV3UnderstandingEditorViewController(entry: entry) { [weak self] saved in
                self?.entry = saved
                self?.tableView.reloadData()
            }, animated: true)
    }
}

@MainActor
final class ImpressV3UnderstandingEditorViewController: UIViewController, UITextViewDelegate {
    private let entry: ImpressV3LearningEntry
    private let onSaved: (ImpressV3LearningEntry) -> Void
    private let input = UITextView()
    private var saveAction: UIBarButtonItem!

    init(entry: ImpressV3LearningEntry,
         onSaved: @escaping (ImpressV3LearningEntry) -> Void) {
        self.entry = entry
        self.onSaved = onSaved
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError("init(entry:onSaved:) required") }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = V3L("编辑理解")
        navigationItem.largeTitleDisplayMode = .never
        view.backgroundColor = ImpressV3Appearance.page
        ImpressV3Appearance.styleReadingTextView(input)
        input.isEditable = true
        input.delegate = self
        input.accessibilityIdentifier = "impress.learning.edit.body"
        ImpressSpeechAccessory.install(on: input)
        input.text = entry.userAnswer
        input.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(input)
        NSLayoutConstraint.activate([
            input.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor,
                                       constant: ImpressV3Appearance.Metrics.compactInset),
            input.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor,
                                           constant: ImpressV3Appearance.Metrics.screenInset),
            input.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor,
                                            constant: -ImpressV3Appearance.Metrics.screenInset)
        ])
        if #available(iOS 15.0, *) {
            input.bottomAnchor.constraint(equalTo: view.keyboardLayoutGuide.topAnchor,
                constant: -ImpressV3Appearance.Metrics.compactInset).isActive = true
        } else {
            input.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor,
                constant: -ImpressV3Appearance.Metrics.compactInset).isActive = true
        }
        saveAction = UIBarButtonItem(
            title: V3L("保存"), style: .plain, target: self, action: #selector(save))
        saveAction.accessibilityIdentifier = "impress.learning.edit.save"
        navigationItem.rightBarButtonItem = saveAction
        updateSaveEnabled()
    }

    func textViewDidChange(_ textView: UITextView) { updateSaveEnabled() }

    private func updateSaveEnabled() {
        let text = input.text ?? ""
        saveAction.isEnabled = text != entry.userAnswer &&
            !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
            text.utf8.count <= 100_000
    }

    @objc private func save() {
        do {
            let saved = try ImpressV3LearningJournal.updateAnswer(
                id: entry.id, expectedAnswer: entry.userAnswer,
                editedAnswer: input.text ?? "")
            onSaved(saved)
            navigationController?.popViewController(animated: true)
        } catch {
            let alert = UIAlertController(title: V3L("无法保存理解记录"),
                message: error.localizedDescription, preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: V3L("确定"), style: .default))
            present(alert, animated: true)
        }
    }
}

/// Native timeline rail, node and connected line; reusable and Dynamic Type-safe.
@MainActor
final class ImpressV3TimelineNodeCell: UITableViewCell {
    private let rail = UIView()
    private let dot = UIView()
    private let dateText = UILabel()
    private let titleText = UILabel()
    private let excerptText = UILabel()
    private let footnoteText = UILabel()

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        accessibilityIdentifier = "impress.v3.timeline.node"
        backgroundColor = ImpressV3Appearance.page
        contentView.backgroundColor = ImpressV3Appearance.page
        rail.translatesAutoresizingMaskIntoConstraints = false
        rail.backgroundColor = ImpressV3Appearance.divider
        dot.translatesAutoresizingMaskIntoConstraints = false
        dot.layer.cornerRadius = ImpressV3Appearance.Radius.timelineNode
        dateText.font = ImpressV3Appearance.Typography.caption
        dateText.textColor = ImpressV3Appearance.secondaryText
        titleText.font = ImpressV3Appearance.Typography.heading
        titleText.textColor = ImpressV3Appearance.primaryText
        excerptText.font = ImpressV3Appearance.Typography.supporting
        excerptText.textColor = ImpressV3Appearance.secondaryText
        excerptText.numberOfLines = 3
        footnoteText.font = ImpressV3Appearance.Typography.micro
        footnoteText.textColor = ImpressV3Appearance.mutedText
        for label in [dateText, titleText, excerptText, footnoteText] {
            label.adjustsFontForContentSizeCategory = true
            label.translatesAutoresizingMaskIntoConstraints = false
        }
        contentView.addSubview(rail)
        contentView.addSubview(dot)
        contentView.addSubview(dateText)
        contentView.addSubview(titleText)
        contentView.addSubview(excerptText)
        contentView.addSubview(footnoteText)
        NSLayoutConstraint.activate([
            rail.widthAnchor.constraint(equalToConstant: ImpressV3Appearance.Metrics.timelineRailWidth),
            rail.centerXAnchor.constraint(equalTo: contentView.leadingAnchor, constant: ImpressV3Appearance.Metrics.timelineRailOffset),
            rail.topAnchor.constraint(equalTo: contentView.topAnchor),
            rail.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            dot.centerXAnchor.constraint(equalTo: rail.centerXAnchor),
            dot.centerYAnchor.constraint(equalTo: dateText.centerYAnchor),
            dot.widthAnchor.constraint(equalToConstant: ImpressV3Appearance.Metrics.timelineDotDiameter),
            dot.heightAnchor.constraint(equalToConstant: ImpressV3Appearance.Metrics.timelineDotDiameter),
            dateText.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 15),
            dateText.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: ImpressV3Appearance.Metrics.timelineTextOffset),
            dateText.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -20),
            titleText.topAnchor.constraint(equalTo: dateText.bottomAnchor, constant: 5),
            titleText.leadingAnchor.constraint(equalTo: dateText.leadingAnchor),
            titleText.trailingAnchor.constraint(equalTo: dateText.trailingAnchor),
            excerptText.topAnchor.constraint(equalTo: titleText.bottomAnchor, constant: 5),
            excerptText.leadingAnchor.constraint(equalTo: titleText.leadingAnchor),
            excerptText.trailingAnchor.constraint(equalTo: titleText.trailingAnchor),
            footnoteText.topAnchor.constraint(equalTo: excerptText.bottomAnchor, constant: 6),
            footnoteText.leadingAnchor.constraint(equalTo: excerptText.leadingAnchor),
            footnoteText.trailingAnchor.constraint(equalTo: excerptText.trailingAnchor),
            footnoteText.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -18)
        ])
        accessoryType = .disclosureIndicator
        selectionStyle = .default
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) unsupported") }

    func configure(time: Date, title: String, excerpt: String,
                   footnote: String, emphasized: Bool) {
        let date = DateFormatter()
        date.dateStyle = .medium
        date.timeStyle = .short
        dateText.text = date.string(from: time)
        titleText.text = title
        excerptText.text = excerpt
        footnoteText.text = footnote
        dot.backgroundColor = emphasized ? ImpressV3Appearance.accent : ImpressV3Appearance.timelineInactive
        accessibilityLabel = (dateText.text ?? "") + "，" +
            title + "，" + excerpt + "，" + footnote
    }
}

// MARK: - R04.2-D settings as the third native tab

@MainActor
final class ImpressV3SettingsHubViewController: UITableViewController {
    private enum Destination {
        case aiService, promptLibrary, reminders, calibration, appearance, language, speech, backup
    }
    private struct Item {
        let title: String
        let detail: String
        let symbol: String
        let destination: Destination
    }
    private let groups: [(name: String, items: [Item])] = [
        ("内容工具", [
            Item(title: "AI 服务", detail: "多 API 连接、多模型与智能出题路由",
                 symbol: "sparkles", destination: .aiService),
            Item(title: "提示词", detail: "费曼总结、选择题、问题与答案 · 可建立多份自定义模板",
                 symbol: "text.book.closed", destination: .promptLibrary)
        ]),
        ("学习节奏", [
            Item(title: "每日校准", detail: "五项评估、历史走势与提醒",
                 symbol: "chart.xyaxis.line", destination: .calibration),
            Item(title: "复习通知", detail: "关闭、到期提醒或每日习惯提醒",
                 symbol: "bell", destination: .reminders)
        ]),
        ("外观", [
            Item(title: "显示模式", detail: "跟随系统、浅色或深色",
                 symbol: "circle.lefthalf.filled", destination: .appearance),
            Item(title: "应用语言", detail: "简体中文、繁体中文或英文",
                 symbol: "globe", destination: .language)
        ]),
        ("语音输入", [
            Item(title: "语音与听写", detail: "识别语言、Apple 端侧模型与录音权限",
                 symbol: "mic", destination: .speech)
        ]),
        ("数据安全", [
            Item(title: "数据与备份", detail: "静默自动备份、iCloud 副本与受控恢复",
                 symbol: "externaldrive", destination: .backup)
        ])
    ]

    init() { super.init(style: .insetGrouped) }
    required init?(coder: NSCoder) { fatalError("init(coder:) unsupported") }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = V3L("设置")
        navigationItem.largeTitleDisplayMode = .always
        tableView.backgroundColor = ImpressV3Appearance.page
        tableView.rowHeight = UITableView.automaticDimension
        tableView.estimatedRowHeight = 66
        tableView.cellLayoutMarginsFollowReadableWidth = true
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        title = V3L("设置")
        tableView.reloadData()
    }

    override func numberOfSections(in tableView: UITableView) -> Int { groups.count }
    override func tableView(_ tableView: UITableView,
                            numberOfRowsInSection section: Int) -> Int {
        groups[section].items.count
    }
    override func tableView(_ tableView: UITableView,
                            titleForHeaderInSection section: Int) -> String? {
        V3L(groups[section].name)
    }
    override func tableView(_ tableView: UITableView,
                            titleForFooterInSection section: Int) -> String? {
        switch section {
        case 0: return V3L("API Key 由 Keychain 管理；私人笔记只在明确授权的生成任务中发送。")
        case 1: return V3L("FSRS-6 决定到期时间；通知仅负责提醒。")
        case 2: return V3L("默认跟随系统；手动选择仅影响 Impress，不修改 iPhone 系统外观。")
        case 3: return V3L("仅使用 Apple 端侧语音模型，录音不会写入历史或发送到服务器。")
        default: return V3L("备份保存在本机；连接 iCloud Drive 文件夹后可自动创建副本。")
        }
    }
    override func tableView(_ tableView: UITableView,
                            cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let item = groups[indexPath.section].items[indexPath.row]
        let cell = tableView.dequeueReusableCell(withIdentifier: "setting")
            ?? UITableViewCell(style: .subtitle, reuseIdentifier: "setting")
        var content = UIListContentConfiguration.subtitleCell()
        content.text = V3L(item.title)
        switch item.destination {
        case .appearance:
            content.secondaryText = ImpressV3Appearance.selectedMode().title
        case .language:
            content.secondaryText = ImpressV3Language.selected().title
        default:
            content.secondaryText = V3L(item.detail)
        }
        content.textProperties.font = ImpressV3Appearance.Typography.body
        content.secondaryTextProperties.font = ImpressV3Appearance.Typography.supporting
        content.secondaryTextProperties.color = ImpressV3Appearance.secondaryText
        content.secondaryTextProperties.numberOfLines = 2
        content.image = UIImage(systemName: item.symbol)
        content.imageProperties.tintColor = ImpressV3Appearance.secondaryText
        cell.contentConfiguration = content
        ImpressV3Appearance.styleGroupedCell(cell)
        cell.accessoryType = .disclosureIndicator
        // A stable semantic destination lets VoiceOver and actual XCUITest
        // locate the bottom-most backup row after explicit table scrolling.
        // UITableView reuses cells: clear identifiers on every other route.
        if case .backup = item.destination {
            cell.accessibilityIdentifier = "impress.settings.backup"
        } else {
            cell.accessibilityIdentifier = nil
        }
        return cell
    }

    override func tableView(_ tableView: UITableView,
                            didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        switch groups[indexPath.section].items[indexPath.row].destination {
        case .aiService:
            navigationController?.pushViewController(
                ImpressAISettingsViewController(), animated: true)
        case .promptLibrary:
            navigationController?.pushViewController(
                ImpressV3PromptLibraryViewController(), animated: true)
        case .reminders:
            navigationController?.pushViewController(
                ImpressV3ReminderSettingsController(), animated: true)
        case .calibration:
            navigationController?.pushViewController(
                ImpressCalibrationViewController(), animated: true)
        case .appearance:
            navigationController?.pushViewController(
                ImpressV3AppearanceSettingsViewController(), animated: true)
        case .language:
            navigationController?.pushViewController(
                ImpressV3LanguageSettingsViewController(), animated: true)
        case .speech:
            navigationController?.pushViewController(
                ImpressSpeechSettingsViewController(), animated: true)
        case .backup:
            navigationController?.pushViewController(
                ImpressV3BackupSettingsViewController(), animated: true)
        }
    }
}

/// Native selection rows keep the current theme visible without an extra
/// global UI state manager. UIWindow traits propagate through existing UIKit.
@MainActor
final class ImpressV3AppearanceSettingsViewController: UITableViewController {
    private let choices = ImpressV3Appearance.Mode.allCases

    init() { super.init(style: .insetGrouped) }
    required init?(coder: NSCoder) { fatalError("init(coder:) unsupported") }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = V3L("显示模式")
        navigationItem.largeTitleDisplayMode = .never
        ImpressV3Appearance.styleGroupedTable(tableView)
    }

    override func tableView(_ tableView: UITableView,
                            numberOfRowsInSection section: Int) -> Int { choices.count }

    override func tableView(_ tableView: UITableView,
                            titleForFooterInSection section: Int) -> String? {
        V3L("跟随系统是默认选项。浅色或深色仅对本 App 生效，并在重新启动后保留。")
    }

    override func tableView(_ tableView: UITableView,
                            cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "appearance.mode")
            ?? UITableViewCell(style: .default, reuseIdentifier: "appearance.mode")
        var content = UIListContentConfiguration.cell()
        content.text = choices[indexPath.row].title
        content.textProperties.font = ImpressV3Appearance.Typography.body
        cell.contentConfiguration = content
        ImpressV3Appearance.styleGroupedCell(cell)
        cell.accessoryType = ImpressV3Appearance.selectedMode() == choices[indexPath.row]
            ? .checkmark : .none
        cell.accessibilityIdentifier = "impress.settings.appearance.\(choices[indexPath.row].rawValue)"
        return cell
    }

    override func tableView(_ tableView: UITableView,
                            didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        ImpressV3Appearance.setAppearance(choices[indexPath.row])
        tableView.reloadData()
    }
}

/// Three user-selected interface languages. The installed data and private
/// Vault are never transformed, rewritten, migrated or machine translated.
@MainActor
final class ImpressV3LanguageSettingsViewController: UITableViewController {
    private let choices = ImpressV3Language.allCases
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        super.init(style: .insetGrouped)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) unsupported") }

    override func viewDidLoad() {
        super.viewDidLoad()
        navigationItem.largeTitleDisplayMode = .never
        ImpressV3Appearance.styleGroupedTable(tableView)
        refreshLanguage()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        refreshLanguage()
    }

    private func refreshLanguage() {
        title = V3L("应用语言")
        tableView.reloadData()
    }

    override func tableView(_ tableView: UITableView,
                            numberOfRowsInSection section: Int) -> Int { choices.count }

    override func tableView(_ tableView: UITableView,
                            titleForFooterInSection section: Int) -> String? {
        V3L("显示语言只改变界面文本，不会翻译或修改你保存的卡片、笔记和历史。")
    }

    override func tableView(_ tableView: UITableView,
                            cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let mode = choices[indexPath.row]
        let cell = tableView.dequeueReusableCell(withIdentifier: "impress.language")
            ?? UITableViewCell(style: .default, reuseIdentifier: "impress.language")
        var content = UIListContentConfiguration.cell()
        content.text = mode.title
        content.textProperties.font = ImpressV3Appearance.Typography.body
        cell.contentConfiguration = content
        ImpressV3Appearance.styleGroupedCell(cell)
        cell.accessoryType = mode == ImpressV3Language.selected(in: defaults) ? .checkmark : .none
        cell.accessibilityIdentifier = "impress.settings.language.\(mode.rawValue)"
        return cell
    }

    override func tableView(_ tableView: UITableView,
                            didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        ImpressV3Language.change(to: choices[indexPath.row], defaults: defaults)
        refreshLanguage()
    }
}

@MainActor
final class ImpressV3ReminderSettingsController: UITableViewController {
    private let labels = [V3L("关闭提醒"), V3L("智能到期提醒 · 每天 09:00 起"), V3L("每日习惯提醒 · 09:00")]
    private let modeKey = "ImpressV3ReminderMode"

    init() { super.init(style: .insetGrouped) }
    required init?(coder: NSCoder) { fatalError("init(coder:) unsupported") }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = V3L("提醒通知")
        navigationItem.largeTitleDisplayMode = .never
        tableView.backgroundColor = ImpressV3Appearance.page
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "reminder")
    }

    override func tableView(_ tableView: UITableView,
                            numberOfRowsInSection section: Int) -> Int { labels.count }

    override func tableView(_ tableView: UITableView,
                            titleForFooterInSection section: Int) -> String? {
        "FSRS-6 决定到期时间；通知只负责提醒。智能提醒之间至少间隔 72 小时，关闭提醒不清除复习进度。"
    }

    override func tableView(_ tableView: UITableView,
                            cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = UITableViewCell(style: .default, reuseIdentifier: nil)
        cell.textLabel?.text = labels[indexPath.row]
        cell.textLabel?.font = ImpressV3Appearance.Typography.body
        cell.textLabel?.adjustsFontForContentSizeCategory = true
        ImpressV3Appearance.styleGroupedCell(cell)
        let mode = UserDefaults.standard.string(forKey: modeKey) ?? "off"
        let current = ["off", "smart", "habit"][indexPath.row]
        cell.accessoryType = mode == current ? .checkmark : .none
        return cell
    }

    override func tableView(_ tableView: UITableView,
                            didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        if indexPath.row == 0 {
            ImpressV3NotificationCoordinator.shared.disableReminders()
            tableView.reloadData()
            return
        }
        // iOS permission prompt must only follow an explicit user action.
        ImpressV3NotificationCoordinator.shared.requestPermissionFromUserAction {
            [weak self] granted in
            guard let self = self else { return }
            guard granted else {
                let notice = UIAlertController(title: V3L("通知未授权"),
                    message: "可在 iOS 系统设置中允许通知；当前模式不会被强制修改。",
                    preferredStyle: .alert)
                notice.addAction(UIAlertAction(title: V3L("确定"), style: .default))
                self.present(notice, animated: true)
                return
            }
            if indexPath.row == 1 {
                ImpressV3NotificationCoordinator.shared.enableSmartReminders()
            } else {
                ImpressV3NotificationCoordinator.shared.enableHabitReminders()
            }
            self.tableView.reloadData()
        }
    }
}

@MainActor
final class ImpressV3WeeklyCalibrationOverview: UIControl {
    private var days: [CalibrationDayPoint] = []
    private let shortDays = ["周一", "周二", "周三", "周四", "周五", "周六", "周日"]

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        isAccessibilityElement = true
        accessibilityTraits = [.button]
        accessibilityHint = V3L("点击打开每日校准")
        configure([])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) unsupported") }

    func configure(_ points: [CalibrationDayPoint]) {
        days = points.count == 7 ? points : []
        let values = days.enumerated().map { offset, point in
            V3L(shortDays[offset]) + " " + (point.netScore.map(String.init) ?? V3L("未评估"))
        }
        accessibilityLabel = V3L("本周校准") + "：" + values.joined(separator: "，")
        setNeedsDisplay()
    }

    override func draw(_ rect: CGRect) {
        guard rect.width > 160, rect.height > 85 else { return }
        let primary = ImpressV3Appearance.secondaryText
        let axis = ImpressV3Appearance.divider
        let accent = ImpressV3Appearance.accent
        let headerFont = UIFont.preferredFont(forTextStyle: .caption1)
        let labelFont = UIFont.preferredFont(forTextStyle: .caption2)
        let headerAttributes: [NSAttributedString.Key: Any] = [
            .font: headerFont, .foregroundColor: primary]
        let labelAttributes: [NSAttributedString.Key: Any] = [
            .font: labelFont, .foregroundColor: primary]
        (V3L("本周校准") as NSString).draw(at: CGPoint(x: 4, y: 0),
                                         withAttributes: headerAttributes)
        let left = ImpressV3Appearance.Metrics.calibrationWeekChartInset
        let right = rect.width - 12
        let top: CGFloat = 29
        let bottom = rect.height - 22
        let mid = (top + bottom) / 2
        let y: (Int) -> CGFloat = { score in
            mid - CGFloat(score) / 5 * (bottom - top) / 2
        }
        func stroke(_ x1: CGFloat, _ y1: CGFloat, _ x2: CGFloat, _ y2: CGFloat,
                    width: CGFloat = 0.5, color: UIColor) {
            let line = UIBezierPath()
            line.move(to: CGPoint(x: x1, y: y1))
            line.addLine(to: CGPoint(x: x2, y: y2))
            line.lineWidth = width
            color.setStroke()
            line.stroke()
        }
        // Fixed -5/0/+5: no automatic zooming to exaggerate variation.
        for value in [-5, 0, 5] {
            let position = y(value)
            stroke(left, position, right, position,
                   width: value == 0 ? 1 : 0.45,
                   color: axis.withAlphaComponent(value == 0 ? 0.8 : 0.3))
            let label = String(value) as NSString
            label.draw(at: CGPoint(x: 1, y: position - labelFont.lineHeight / 2),
                       withAttributes: labelAttributes)
        }
        var previous: CGPoint?
        for index in 0..<7 {
            let x = left + CGFloat(index) * (right - left) / 6
            let weekday = V3L(shortDays[index]) as NSString
            let size = weekday.size(withAttributes: labelAttributes)
            weekday.draw(at: CGPoint(x: x - size.width / 2, y: bottom + 4),
                         withAttributes: labelAttributes)
            guard days.indices.contains(index),
                  let score = days[index].netScore else {
                previous = nil // missing data NEVER connected to adjacent days
                continue
            }
            let current = CGPoint(x: x, y: y(score))
            if let previous {
                stroke(previous.x, previous.y, current.x, current.y,
                       width: 1.5, color: accent)
            }
            accent.setFill()
            UIBezierPath(ovalIn: CGRect(x: current.x - 2, y: current.y - 2,
                                        width: 4, height: 4)).fill()
            previous = current
        }
    }
}


@MainActor
final class ImpressV3CardVersionHistoryViewController: UITableViewController {
    var onRestored: ((WCDBV3CardContent) async throws -> Void)?
    private let cardID: UUID
    private let expectedReviewRevision: Int
    private let repository: ReviewWCDBRepository
    private var versions: [WCDBV3ContentVersion] = []
    private var openedContentRevision: Int?

    init(cardID: UUID, expectedReviewRevision: Int, repository: ReviewWCDBRepository) {
        self.cardID = cardID
        self.expectedReviewRevision = expectedReviewRevision
        self.repository = repository
        super.init(style: .insetGrouped)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) unsupported") }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = V3L("查看历史版本")
        tableView.backgroundColor = ImpressV3Appearance.page
        load()
    }
    private func load() {
        Task {
            do {
                let loaded = try await repository.contentHistory(for: cardID)
                versions = Array(loaded.reversed())
                if openedContentRevision == nil {
                    openedContentRevision = try await repository.content(for: cardID)?.contentRevision
                }
                tableView.reloadData()
            } catch { showProblem(error) }
        }
    }
    override func tableView(_ tableView: UITableView,
                            numberOfRowsInSection section: Int) -> Int { versions.count }
    override func tableView(_ tableView: UITableView,
                            cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let version = versions[indexPath.row]
        let cell = UITableViewCell(style: .subtitle, reuseIdentifier: nil)
        cell.textLabel?.text = version.question
        let stamp = DateFormatter()
        stamp.dateStyle = .medium
        stamp.timeStyle = .short
        cell.detailTextLabel?.text = "v\(version.contentRevision) · " +
            stamp.string(from: version.recordedAt)
        cell.textLabel?.numberOfLines = 2
        ImpressV3Appearance.styleGroupedCell(cell)
        cell.accessoryType = .disclosureIndicator
        return cell
    }
    override func tableView(_ tableView: UITableView,
                            didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        let version = versions[indexPath.row]
        let details = ImpressV3CardVersionDetailViewController(version: version)
        details.onRestore = { [weak self] in self?.confirmRestore(version) }
        navigationController?.pushViewController(details, animated: true)
    }
    private func confirmRestore(_ version: WCDBV3ContentVersion) {
        let confirm = UIAlertController(
            title: V3L("恢复历史版本"),
            message: V3L("恢复将产生新版本，保留现有历史；不会修改 FSRS 评分。"),
            preferredStyle: .alert)
        confirm.addAction(UIAlertAction(title: V3L("取消"), style: .cancel))
        confirm.addAction(UIAlertAction(title: V3L("恢复"), style: .default) { [weak self] _ in
            guard let self else { return }
            Task {
                do {
                    guard let expected = self.openedContentRevision else {
                        throw ReviewWCDBError.missingCard
                    }
                    try await self.repository.restoreContentVersion(
                        cardID: self.cardID, savedRevision: version.contentRevision,
                        expectedContentRevision: expected,
                        expectedReviewRevision: self.expectedReviewRevision)
                    guard let latest = try await self.repository.content(for: self.cardID) else {
                        throw ReviewWCDBError.missingCard
                    }
                    try await self.onRestored?(latest)
                    self.openedContentRevision = latest.contentRevision
                    self.load()
                    self.navigationController?.popViewController(animated: true)
                } catch { self.showProblem(error) }
            }
        })
        present(confirm, animated: true)
    }
    private func showProblem(_ error: Error) {
        let alert = UIAlertController(title: V3L("操作未完成"),
                                      message: error.localizedDescription,
                                      preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: V3L("确定"), style: .default))
        present(alert, animated: true)
    }
}

@MainActor
final class ImpressV3CardVersionDetailViewController: UIViewController {
    var onRestore: (() -> Void)?
    private let version: WCDBV3ContentVersion
    init(version: WCDBV3ContentVersion) {
        self.version = version
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) unsupported") }
    override func viewDidLoad() {
        super.viewDidLoad()
        title = "v\(version.contentRevision)"
        view.backgroundColor = ImpressV3Appearance.page
        navigationItem.rightBarButtonItem = UIBarButtonItem(
            title: V3L("恢复"), style: .plain, target: self,
            action: #selector(restoreTapped))
        let textView = UITextView()
        textView.isEditable = false
        textView.isSelectable = true
        textView.backgroundColor = ImpressV3Appearance.surface
        textView.font = ImpressV3Appearance.Typography.body
        textView.textColor = ImpressV3Appearance.primaryText
        textView.adjustsFontForContentSizeCategory = true
        var body = version.question
        if let choices = version.choices {
            body += "\n\n" + choices
            body += "\n" + (version.correctIndices ?? "")
        }
        if let answer = version.answerText { body += "\n\n" + answer }
        if let path = version.sourceNotePath { body += "\n\n" + path }
        textView.text = body
        textView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(textView)
        let image = UIImageView(image: version.imageData.flatMap { UIImage(data: $0) })
        image.contentMode = .scaleAspectFit
        image.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(image)
        NSLayoutConstraint.activate([
            textView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor,
                                          constant: ImpressV3Appearance.Metrics.compactInset),
            textView.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor,
                                              constant: ImpressV3Appearance.Metrics.screenInset),
            textView.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor,
                                               constant: -ImpressV3Appearance.Metrics.screenInset),
            image.topAnchor.constraint(equalTo: textView.bottomAnchor,
                                       constant: ImpressV3Appearance.Metrics.compactInset),
            image.leadingAnchor.constraint(equalTo: textView.leadingAnchor),
            image.trailingAnchor.constraint(equalTo: textView.trailingAnchor),
            image.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor),
            image.heightAnchor.constraint(equalToConstant: version.imageData == nil ? 0 :
                ImpressV3Appearance.Metrics.contentVersionImageHeight),
            textView.heightAnchor.constraint(greaterThanOrEqualTo: view.heightAnchor,
                                              multiplier: version.imageData == nil ? 0.6 : 0.4)
        ])
    }
    @objc private func restoreTapped() { onRestore?() }
}
