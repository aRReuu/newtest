import UIKit
import ImpressReviewCore

/// Production conversation viewport. Unlike the disposable POC, this receives
/// existing WCDB message values without becoming another data store.
/// Only changed Markdown blocks are reconfigured; other cells retain identity.
@MainActor
final class ImpressChatProductionTranscript: UIView,
                                              UICollectionViewDelegate, UIScrollViewDelegate {
    private struct Row: Equatable {
        let messageID: UUID
        let user: Bool
        let text: String
        let kind: ImpressChatPOCBlock.Kind
        let headingLevel: Int
        let stable: Bool
        let completed: Bool
        let isStatus: Bool
        let isActions: Bool
    }

    private struct ParsedMessage {
        let text: String
        let status: WCDBV3ChatMessageStatus
        let blocks: [ImpressChatPOCBlock]
        let stream: ImpressChatPOCStream?
    }

    private enum ScrollMode {
        case followingBottom, readingHistory, keyboardTransition, restoring
    }

    private struct SessionAnchor {
        let rowID: String
        let distanceFromViewportTop: CGFloat
    }

    private enum SessionPosition {
        case followingBottom
        case reading(SessionAnchor)
    }

    var menuForMessage: ((UUID) -> UIMenu?)?
    private let collection: UICollectionView
    private var dataSource: UICollectionViewDiffableDataSource<Int, String>!
    private var rows: [String: Row] = [:]
    private var parsed: [UUID: ParsedMessage] = [:]
    private var latestMessages: [WCDBV3ChatMessage] = []
    private var publishedIDs: [String] = []
    private var scrollMode: ScrollMode = .followingBottom
    private var modeBeforeKeyboard: ScrollMode = .followingBottom
    private var snapshotInFlight = false
    private var snapshotNeedsRefresh = false
    private var renderQueued = false
    private var lastRenderedAt: CFAbsoluteTime = 0
    private var requestedFocus: UUID?
    // Transient viewport state only. WCDB remains the sole conversation source.
    // Never carry an unrelated session's offset or explicit search focus across.
    private var activeConversationID: UUID?
    private var savedSessionPositions: [UUID: SessionPosition] = [:]
    private var pendingSessionPosition: SessionPosition?
    private var refreshAll = false
    // Last committed viewport only; WCDB remains the sole persisted source.
    // Comparing a complete archive's immutable prefix avoids rebuilding 5,000
    // rows for every short SSE tail delta.
    private var renderedMessages: [WCDBV3ChatMessage] = []
    private var renderedConversationID: UUID?
    private var renderedTailIDs: [String] = []
    #if DEBUG
    private(set) var qaTailOnlyReconfigurations = 0
    private(set) var qaFullArchiveReconstructions = 0
    #endif

    override init(frame: CGRect) {
        let layout = UICollectionViewCompositionalLayout { _, _ in
            let size = NSCollectionLayoutSize(widthDimension: .fractionalWidth(1),
                                              heightDimension: .estimated(56))
            let item = NSCollectionLayoutItem(layoutSize: size)
            let group = NSCollectionLayoutGroup.vertical(layoutSize: size, subitems: [item])
            let section = NSCollectionLayoutSection(group: group)
            section.interGroupSpacing = 5
            section.contentInsets = NSDirectionalEdgeInsets(
                top: 16, leading: 14, bottom: 16, trailing: 14)
            return section
        }
        collection = UICollectionView(frame: .zero, collectionViewLayout: layout)
        super.init(frame: frame)
        collection.backgroundColor = .clear
        collection.delegate = self
        collection.keyboardDismissMode = .interactive
        collection.accessibilityIdentifier = "impress.ai.chat.transcript"
        collection.register(ImpressChatDocumentCell.self, forCellWithReuseIdentifier: "document")
        collection.register(ImpressChatPOCStructuredCell.self, forCellWithReuseIdentifier: "structured")
        collection.register(ImpressChatPOCMathCell.self, forCellWithReuseIdentifier: "math")
        collection.register(ImpressChatStatusCell.self, forCellWithReuseIdentifier: "status")
        collection.register(ImpressChatReplyActionsCell.self, forCellWithReuseIdentifier: "actions")
        let empty = UILabel()
        empty.text = V3L("从一个问题开始")
        empty.font = .preferredFont(forTextStyle: .body)
        empty.textAlignment = .center
        empty.textColor = .secondaryLabel
        collection.backgroundView = empty
        collection.translatesAutoresizingMaskIntoConstraints = false
        addSubview(collection)
        NSLayoutConstraint.activate([
            collection.leadingAnchor.constraint(equalTo: leadingAnchor),
            collection.trailingAnchor.constraint(equalTo: trailingAnchor),
            collection.topAnchor.constraint(equalTo: topAnchor),
            collection.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
        dataSource = UICollectionViewDiffableDataSource<Int, String>(
            collectionView: collection) { [weak self] list, indexPath, id in
            guard let self, let row = self.rows[id] else { return nil }
            if row.isActions {
                let cell = list.dequeueReusableCell(
                    withReuseIdentifier: "actions", for: indexPath)
                    as! ImpressChatReplyActionsCell
                cell.configure(messageID: row.messageID, text: row.text,
                               menu: self.menuForMessage?(row.messageID))
                return cell
            }
            if row.isStatus {
                let cell = list.dequeueReusableCell(
                    withReuseIdentifier: "status", for: indexPath) as! ImpressChatStatusCell
                cell.configure(row.text)
                return cell
            }
            if !row.user && (row.kind == .code || row.kind == .table) {
                let cell = list.dequeueReusableCell(
                    withReuseIdentifier: "structured", for: indexPath)
                    as! ImpressChatPOCStructuredCell
                cell.configure(markdown: row.text, kind: row.kind, stable: row.stable)
                cell.accessibilityIdentifier = "impress.ai.chat.rich-block"
                return cell
            }
            if !row.user && row.kind == .math {
                let cell = list.dequeueReusableCell(
                    withReuseIdentifier: "math", for: indexPath) as! ImpressChatPOCMathCell
                cell.configure(row.text, stable: row.stable)
                cell.accessibilityIdentifier = "impress.ai.chat.math-block"
                return cell
            }
            let cell = list.dequeueReusableCell(
                withReuseIdentifier: "document", for: indexPath) as! ImpressChatDocumentCell
            cell.configure(row.text, kind: row.kind, headingLevel: row.headingLevel,
                           user: row.user, stable: row.stable)
            cell.accessibilityIdentifier = row.completed && !row.user
                ? "impress.ai.chat.completed-assistant" : "impress.ai.chat.history-turn"
            return cell
        }
        NotificationCenter.default.addObserver(self,
            selector: #selector(contentSizeChanged),
            name: UIContentSizeCategory.didChangeNotification, object: nil)
        NotificationCenter.default.addObserver(self,
            selector: #selector(keyboardWillChange),
            name: UIResponder.keyboardWillChangeFrameNotification, object: nil)
        NotificationCenter.default.addObserver(self,
            selector: #selector(keyboardDidChange),
            name: UIResponder.keyboardDidChangeFrameNotification, object: nil)
        NotificationCenter.default.addObserver(self,
            selector: #selector(keyboardDidChange),
            name: UIResponder.keyboardDidHideNotification, object: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) unsupported") }
    deinit { NotificationCenter.default.removeObserver(self) }

    @objc private func contentSizeChanged() {
        refreshAll = true
        collection.collectionViewLayout.invalidateLayout()
        renderLatest()
    }

    @objc private func keyboardWillChange() {
        // Chinese input candidates may trigger repeated will-change notifications.
        // Do not overwrite the original ReadingHistory/FollowingBottom state.
        guard scrollMode != .keyboardTransition else { return }
        modeBeforeKeyboard = scrollMode
        scrollMode = .keyboardTransition
    }

    @objc private func keyboardDidChange() {
        scrollMode = modeBeforeKeyboard
        if scrollMode == .followingBottom { scrollToBottom() }
    }

    func followNewestMessage() {
        scrollMode = .followingBottom
        pendingSessionPosition = nil
    }

    private func visibleSessionAnchor() -> SessionAnchor? {
        guard let index = collection.indexPathsForVisibleItems.sorted().first,
              let id = dataSource.itemIdentifier(for: index),
              let attributes = collection.layoutAttributesForItem(at: index) else {
            return nil
        }
        return SessionAnchor(rowID: id,
            distanceFromViewportTop: attributes.frame.minY -
                collection.contentOffset.y)
    }

    /// Called before swapping WCDB histories, including cold-start restore.
    /// One conversation's reading anchor never becomes another's scroll state.
    func activateConversation(_ id: UUID) {
        guard activeConversationID != id else { return }
        if let old = activeConversationID {
            let reading = scrollMode == .readingHistory ||
                (scrollMode == .keyboardTransition &&
                 modeBeforeKeyboard == .readingHistory)
            if reading, let anchor = visibleSessionAnchor() {
                savedSessionPositions[old] = .reading(anchor)
            } else if scrollMode == .followingBottom {
                savedSessionPositions[old] = .followingBottom
            }
        }
        activeConversationID = id
        requestedFocus = nil
        pendingSessionPosition = savedSessionPositions[id] ?? .followingBottom
        scrollMode = .restoring
    }

    func forgetConversation(_ id: UUID) {
        savedSessionPositions.removeValue(forKey: id)
        guard activeConversationID == id else { return }
        activeConversationID = nil
        pendingSessionPosition = nil
        requestedFocus = nil
        scrollMode = .followingBottom
    }

    func update(_ messages: [WCDBV3ChatMessage], focusMessageID: UUID? = nil) {
        latestMessages = messages
        if messages.isEmpty {
            scrollMode = .followingBottom
            parsed.removeAll()
        }
        if let focusMessageID {
            requestedFocus = focusMessageID
            scrollMode = .restoring
        }
        // Network SSE events can arrive hundreds of times per second.
        // Model updates are lossless, while UI/layout transactions run at <= 30Hz.
        let now = CFAbsoluteTimeGetCurrent()
        if now - lastRenderedAt < (1.0 / 30.0) {
            if !renderQueued {
                renderQueued = true
                Task { [weak self] in
                    try? await Task.sleep(for: .milliseconds(34))
                    guard let self else { return }
                    self.renderQueued = false
                    self.renderLatest()
                }
            }
            return
        }
        renderLatest()
    }

    private func blocks(for message: WCDBV3ChatMessage) -> [ImpressChatPOCBlock] {
        if let old = parsed[message.messageID],
           old.text == message.text && old.status == message.status {
            return old.blocks
        }
        let blocks: [ImpressChatPOCBlock]
        var stream: ImpressChatPOCStream?
        if message.status == .pending {
            var next: ImpressChatPOCStream
            if let old = parsed[message.messageID], old.status == .pending,
               let previous = old.stream, message.text.hasPrefix(old.text) {
                next = previous
                next.append(String(message.text.dropFirst(old.text.count)))
            } else {
                next = ImpressChatPOCStream()
                next.start()
                next.append(message.text)
            }
            blocks = next.blocks
            stream = next
        } else if let old = parsed[message.messageID], old.text == message.text,
                  let previous = old.stream {
            var finished = previous
            switch message.status {
            case .completed: finished.finish()
            case .cancelled: finished.stop()
            case .failed: finished.fail()
            case .pending: break
            }
            blocks = finished.blocks
        } else if message.status == .failed || message.status == .cancelled {
            // Cold-start restore has no in-memory streaming parser. Replaying
            // the saved partial source as an interrupted stream preserves
            // provisional tail blocks; parseOnce would incorrectly mark an
            // unfinished code/table/math block stable after app relaunch.
            var partial = ImpressChatPOCStream()
            partial.start()
            partial.append(message.text)
            if message.status == .failed { partial.fail() }
            else { partial.stop() }
            blocks = partial.blocks
        } else {
            blocks = ImpressChatPOCStream.parseOnce(message.text)
        }
        parsed[message.messageID] = ParsedMessage(
            text: message.text, status: message.status, blocks: blocks, stream: stream)
        return blocks
    }

    /// Preserves the established stable row IDs and Markdown block projection.
    private func appendMessageRows(for message: WCDBV3ChatMessage,
                                   to identifiers: inout [String],
                                   nextRows: inout [String: Row]) {
            let prefix = message.messageID.uuidString
            let completed = message.status == .completed
            if message.role == .user {
                let id = "user-" + prefix
                identifiers.append(id)
                // Show only a metadata receipt, never a claim the remote model
                // actually perceived the image or has retained its pixels.
                // WCDB message.text remains the exact sent user text, and raw
                // images are never added to subsequent request history.
                let imageNotice: String
                if let images = message.approvedImages, !images.isEmpty {
                    let names = images.map { $0.name }.joined(separator: "、")
                    imageNotice = "\n\n" + V3L("已批准图片") + " · " +
                        String(images.count) + "\n" + names
                } else {
                    imageNotice = ""
                }
                nextRows[id] = Row(messageID: message.messageID, user: true,
                    text: message.text + imageNotice, kind: .paragraph, headingLevel: 0,
                    stable: true, completed: completed, isStatus: false, isActions: false)
            } else {
                for block in blocks(for: message) {
                    let id = "assistant-" + prefix + "-" + String(block.id)
                    identifiers.append(id)
                    nextRows[id] = Row(messageID: message.messageID, user: false,
                        text: block.markdown, kind: block.kind,
                        headingLevel: block.headingLevel, stable: block.stable,
                        completed: completed, isStatus: false, isActions: false)
                }
            }
            if message.status != .completed {
                let id = "status-" + prefix
                let description: String
                switch message.status {
                case .pending: description = message.role == .assistant
                    ? V3L("正在生成…") : V3L("正在发送…")
                case .cancelled: description = V3L("已停止 · 保留部分内容")
                case .failed: description = V3L("请求失败 · 保留部分内容")
                case .completed: description = ""
                }
                identifiers.append(id)
                nextRows[id] = Row(messageID: message.messageID, user: false,
                    text: description, kind: .paragraph, headingLevel: 0,
                    stable: true, completed: false, isStatus: true, isActions: false)
            } else if message.role == .assistant && !message.text.isEmpty {
                let id = "actions-" + prefix
                identifiers.append(id)
                nextRows[id] = Row(messageID: message.messageID, user: false,
                    text: message.text, kind: .paragraph, headingLevel: 0,
                    stable: true, completed: true, isStatus: false, isActions: true)
            }
    }

    /// Do not diff/reparse the whole persisted history on every SSE callback.
    /// Any changed earlier turn, session switch, row topology change, search
    /// focus or Dynamic Type refresh returns to the existing complete renderer.
    private func renderStreamingTailIfPossible() -> Bool {
        guard !refreshAll, pendingSessionPosition == nil,
              requestedFocus == nil,
              renderedConversationID == activeConversationID,
              latestMessages.count == renderedMessages.count,
              let current = latestMessages.last,
              let previous = renderedMessages.last,
              current.messageID == previous.messageID,
              latestMessages.dropLast().elementsEqual(renderedMessages.dropLast())
        else { return false }
        if current == previous { return true }
        var tailIDs: [String] = []
        var tailRows: [String: Row] = [:]
        appendMessageRows(for: current, to: &tailIDs, nextRows: &tailRows)
        guard tailIDs == renderedTailIDs else { return false }
        var changed: [String] = []
        for id in tailIDs {
            guard let old = rows[id], let new = tailRows[id],
                  old.kind == new.kind, old.user == new.user,
                  old.isStatus == new.isStatus, old.isActions == new.isActions
            else { return false }
            if old != new { changed.append(id) }
        }
        let previousSnapshot = dataSource.snapshot()
        guard Array(previousSnapshot.itemIdentifiers.suffix(tailIDs.count)) == tailIDs
        else { return false }
        for id in tailIDs { rows[id] = tailRows[id] }
        renderedMessages = latestMessages
        if changed.isEmpty { return true }
        var snapshot = previousSnapshot
        snapshot.reconfigureItems(changed)
        lastRenderedAt = CFAbsoluteTimeGetCurrent() // preserve <= 30Hz SSE layout cadence
        snapshotInFlight = true
        #if DEBUG
        qaTailOnlyReconfigurations += 1
        #endif
        let targetConversation = activeConversationID
        dataSource.apply(snapshot, animatingDifferences: false) { [weak self] in
            guard let self else { return }
            self.snapshotInFlight = false
            if self.activeConversationID != targetConversation ||
                self.snapshotNeedsRefresh {
                self.snapshotNeedsRefresh = false
                self.renderLatest()
            } else if self.scrollMode == .followingBottom {
                self.scrollToBottom()
            }
        }
        return true
    }

    private func renderLatest() {
        if snapshotInFlight {
            snapshotNeedsRefresh = true
            return
        }
        if renderStreamingTailIfPossible() { return }
        #if DEBUG
        qaFullArchiveReconstructions += 1
        #endif
        lastRenderedAt = CFAbsoluteTimeGetCurrent()
        var nextRows: [String: Row] = [:]
        var identifiers: [String] = []
        let surviving = Set(latestMessages.map(\.messageID))
        parsed = parsed.filter { surviving.contains($0.key) }
        var tailIDs: [String] = []
        for (index, message) in latestMessages.enumerated() {
            let initialCount = identifiers.count
            appendMessageRows(for: message, to: &identifiers, nextRows: &nextRows)
            if index == latestMessages.count - 1 {
                tailIDs = Array(identifiers.dropFirst(initialCount))
            }
        }
        collection.backgroundView?.isHidden = !identifiers.isEmpty
        let previous = dataSource.snapshot()
        let oldIDs = Set(previous.itemIdentifiers)
        let changed = identifiers.filter { oldIDs.contains($0) && rows[$0] != nextRows[$0] }
        let newKinds = changed.filter { id in
            guard let old = rows[id], let new = nextRows[id] else { return false }
            return old.kind != new.kind || old.user != new.user || old.isStatus != new.isStatus
        }
        let changedKinds = Set(newKinds)
        let ordinaryChanges = changed.filter { !changedKinds.contains($0) }
        let visibleAnchor = collection.indexPathsForVisibleItems.sorted().first.flatMap {
            index -> (String, CGFloat)? in
            guard let id = dataSource.itemIdentifier(for: index),
                  let attributes = collection.layoutAttributesForItem(at: index) else {
                return nil
            }
            return (id, attributes.frame.minY - collection.contentOffset.y)
        }
        rows = nextRows
        renderedMessages = latestMessages
        renderedConversationID = activeConversationID
        renderedTailIDs = tailIDs
        var snapshot = previous
        if snapshot.sectionIdentifiers.isEmpty { snapshot.appendSections([0]) }
        if identifiers == publishedIDs {
            // Even an initially empty conversation needs its first section
            // committed. Otherwise the no-op guard skips the first snapshot
            // and the collection permanently reports zero sections.
            if changed.isEmpty && !refreshAll && requestedFocus == nil &&
                pendingSessionPosition == nil &&
                !previous.sectionIdentifiers.isEmpty { return }
            if !newKinds.isEmpty { snapshot.reloadItems(newKinds) }
            let reconfigured = refreshAll
                ? identifiers.filter { !changedKinds.contains($0) } : ordinaryChanges
            if !reconfigured.isEmpty { snapshot.reconfigureItems(reconfigured) }
        } else if publishedIDs.count <= identifiers.count &&
                  Array(identifiers.prefix(publishedIDs.count)) == publishedIDs {
            snapshot.appendItems(Array(identifiers.dropFirst(publishedIDs.count)))
            if !newKinds.isEmpty { snapshot.reloadItems(newKinds) }
            let reconfigured = refreshAll
                ? publishedIDs.filter { !changedKinds.contains($0) } : ordinaryChanges
            if !reconfigured.isEmpty { snapshot.reconfigureItems(reconfigured) }
        } else {
            snapshot = NSDiffableDataSourceSnapshot<Int, String>()
            snapshot.appendSections([0])
            snapshot.appendItems(identifiers)
        }
        refreshAll = false
        // A large, entirely new history has no useful animated diff. Building
        // thousands of insertion transitions needlessly stresses self-sizing
        // layouts; retain the identical stable IDs via a reload-data snapshot.
        let initialLargeHistory = identifiers.count >= 1_000 &&
            oldIDs.isDisjoint(with: identifiers)
        publishedIDs = identifiers
        snapshotInFlight = true
        let snapshotConversationID = activeConversationID
        let finished: () -> Void = { [weak self] in
            guard let self else { return }
            // A session may switch while UIKit commits the previous snapshot.
            // Ignore that old completion; render the latest session instead.
            guard self.activeConversationID == snapshotConversationID else {
                self.snapshotInFlight = false
                self.snapshotNeedsRefresh = false
                self.renderLatest()
                return
            }
            self.collection.layoutIfNeeded()
            if let focus = self.requestedFocus,
               let index = identifiers.firstIndex(where: {
                   self.rows[$0]?.messageID == focus
               }) {
                self.collection.scrollToItem(
                    at: IndexPath(item: index, section: 0),
                    at: .centeredVertically, animated: false)
                self.requestedFocus = nil
                self.pendingSessionPosition = nil
                self.scrollMode = .readingHistory
            } else if let position = self.pendingSessionPosition {
                self.pendingSessionPosition = nil
                switch position {
                case .followingBottom:
                    self.scrollMode = .followingBottom
                    self.scrollToBottom()
                case .reading(let anchor):
                    if let index = identifiers.firstIndex(of: anchor.rowID) {
                        let item = IndexPath(item: index, section: 0)
                        self.collection.scrollToItem(at: item, at: .top,
                                                     animated: false)
                        self.collection.layoutIfNeeded()
                        if let frame = self.collection.layoutAttributesForItem(at: item) {
                            let minimum = -self.collection.adjustedContentInset.top
                            let maximum = max(minimum, self.collection.contentSize.height -
                                self.collection.bounds.height +
                                self.collection.adjustedContentInset.bottom)
                            let target = min(maximum, max(minimum,
                                frame.frame.minY - anchor.distanceFromViewportTop))
                            self.collection.setContentOffset(
                                CGPoint(x: self.collection.contentOffset.x, y: target),
                                animated: false)
                        }
                        self.scrollMode = .readingHistory
                    } else {
                        // A deleted/edited anchor cannot point to another
                        // conversation or silently invent a replacement row.
                        self.scrollMode = .followingBottom
                        self.scrollToBottom()
                    }
                }
            } else if self.scrollMode == .followingBottom {
                self.scrollToBottom()
            } else if let (id, dy) = visibleAnchor,
                      let index = identifiers.firstIndex(of: id),
                      let frame = self.collection.layoutAttributesForItem(
                          at: IndexPath(item: index, section: 0)) {
                let target = max(-self.collection.adjustedContentInset.top,
                                 frame.frame.minY - dy)
                self.collection.setContentOffset(
                    CGPoint(x: self.collection.contentOffset.x, y: target),
                    animated: false)
            }
            self.snapshotInFlight = false
            if self.snapshotNeedsRefresh {
                self.snapshotNeedsRefresh = false
                self.renderLatest()
            }
        }
        if initialLargeHistory {
            dataSource.applySnapshotUsingReloadData(snapshot, completion: finished)
        } else {
            dataSource.apply(snapshot, animatingDifferences: false,
                             completion: finished)
        }
    }

    private func scrollToBottom() {
        let ids = dataSource.snapshot().itemIdentifiers
        guard !ids.isEmpty else { return }
        collection.scrollToItem(at: IndexPath(item: ids.count - 1, section: 0),
                                at: .bottom, animated: false)
    }

    func collectionView(_ collectionView: UICollectionView,
                        contextMenuConfigurationForItemAt indexPath: IndexPath,
                        point: CGPoint) -> UIContextMenuConfiguration? {
        guard let id = dataSource.itemIdentifier(for: indexPath),
              let row = rows[id], !row.isStatus, !row.isActions,
              menuForMessage?(row.messageID) != nil
        else { return nil }
        return UIContextMenuConfiguration(identifier: nil, previewProvider: nil) {
            [weak self] _ in
            self?.menuForMessage?(row.messageID) ?? UIMenu(children: [])
        }
    }

    func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
        scrollMode = .readingHistory
    }

    func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate: Bool) {
        if !willDecelerate { updateFollowMode(scrollView) }
    }

    func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
        updateFollowMode(scrollView)
    }

    private func updateFollowMode(_ scrollView: UIScrollView) {
        let distance = scrollView.contentSize.height -
            (scrollView.contentOffset.y + scrollView.bounds.height)
        scrollMode = distance < 64 ? .followingBottom : .readingHistory
    }
}

/// Plain AI document paragraphs and a right-aligned user bubble. Never paints
/// a full-width IM row or draws redundant role labels.
@MainActor
final class ImpressChatDocumentCell: UICollectionViewCell, UITextViewDelegate {
    /// Untrusted AI Markdown may supply arbitrary schemes. Only an explicit
    /// tap on a standard external web URL may navigate away from Impress.
    static func safeExternalURL(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(),
              scheme == "https" || scheme == "http",
              let host = url.host, !host.isEmpty,
              url.user == nil, url.password == nil else { return false }
        return true
    }

    func textView(_ textView: UITextView, shouldInteractWith url: URL,
                  in characterRange: NSRange,
                  interaction: UITextItemInteraction) -> Bool {
        guard interaction == .invokeDefaultAction, Self.safeExternalURL(url)
        else { return false }
        UIApplication.shared.open(url, options: [:], completionHandler: nil)
        return false
    }

    private let bubble = UIView()
    private let body = UITextView()
    private let quoteStripe = UIView()
    private let rule = UIView()
    private var assistantLeading: NSLayoutConstraint!
    private var userWidth: NSLayoutConstraint!

    override init(frame: CGRect) {
        super.init(frame: frame)
        for element in [bubble, body, quoteStripe, rule] {
            element.translatesAutoresizingMaskIntoConstraints = false
        }
        body.isEditable = false
        body.isSelectable = true
        body.delegate = self
        body.isScrollEnabled = false
        body.backgroundColor = .clear
        body.textContainerInset = .zero
        body.textContainer.lineFragmentPadding = 0
        body.adjustsFontForContentSizeCategory = true
        body.textColor = .label
        body.dataDetectorTypes = [.link]
        body.accessibilityIdentifier = "impress.ai.chat.message-body"
        quoteStripe.backgroundColor = .tertiaryLabel
        quoteStripe.layer.cornerRadius = 1.5
        rule.backgroundColor = .separator
        rule.isAccessibilityElement = true
        rule.accessibilityLabel = V3L("分隔线")
        contentView.addSubview(bubble)
        bubble.addSubview(body)
        bubble.addSubview(quoteStripe)
        bubble.addSubview(rule)
        assistantLeading = bubble.leadingAnchor.constraint(equalTo: contentView.leadingAnchor)
        userWidth = bubble.widthAnchor.constraint(equalTo: contentView.widthAnchor,
                                                  multiplier: 0.84)
        NSLayoutConstraint.activate([
            bubble.topAnchor.constraint(equalTo: contentView.topAnchor),
            bubble.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            bubble.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            bubble.leadingAnchor.constraint(greaterThanOrEqualTo: contentView.leadingAnchor),
            body.topAnchor.constraint(equalTo: bubble.topAnchor, constant: 9),
            body.bottomAnchor.constraint(equalTo: bubble.bottomAnchor, constant: -9),
            body.leadingAnchor.constraint(equalTo: bubble.leadingAnchor, constant: 12),
            body.trailingAnchor.constraint(equalTo: bubble.trailingAnchor, constant: -12),
            quoteStripe.leadingAnchor.constraint(equalTo: bubble.leadingAnchor, constant: 2),
            quoteStripe.topAnchor.constraint(equalTo: bubble.topAnchor, constant: 5),
            quoteStripe.bottomAnchor.constraint(equalTo: bubble.bottomAnchor, constant: -5),
            quoteStripe.widthAnchor.constraint(equalToConstant: 3),
            rule.leadingAnchor.constraint(equalTo: bubble.leadingAnchor, constant: 12),
            rule.trailingAnchor.constraint(equalTo: bubble.trailingAnchor, constant: -12),
            rule.centerYAnchor.constraint(equalTo: bubble.centerYAnchor),
            rule.heightAnchor.constraint(equalToConstant: 1)
        ])
        assistantLeading.isActive = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) unsupported") }

    func configure(_ markdown: String, kind: ImpressChatPOCBlock.Kind,
                   headingLevel: Int, user: Bool, stable: Bool) {
        assistantLeading.isActive = !user
        userWidth.isActive = user
        bubble.backgroundColor = user ? .tertiarySystemFill : .clear
        bubble.layer.cornerRadius = user ? 19 : 0
        quoteStripe.isHidden = kind != .quote || user
        rule.isHidden = kind != .divider || user
        body.isHidden = kind == .divider
        let base = UIFont.preferredFont(forTextStyle: .body).pointSize
        let scale: [CGFloat] = [1.0, 1.58, 1.42, 1.28, 1.15, 1.07, 1.0]
        let level = min(6, max(1, headingLevel))
        let font = kind == .heading
            ? UIFont.systemFont(ofSize: base * scale[level], weight: .bold)
            : UIFont.preferredFont(forTextStyle: .body)
        body.font = font
        body.textColor = .label
        var displayed = markdown
        if !user && kind == .heading {
            displayed = String(markdown.dropFirst(headingLevel))
                .trimmingCharacters(in: .whitespaces)
        } else if !user && kind == .quote {
            displayed = markdown.components(separatedBy: "\n").map { line in
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                return trimmed.hasPrefix(">")
                    ? String(trimmed.dropFirst()).trimmingCharacters(in: .whitespaces)
                    : trimmed
            }.joined(separator: "\n")
        }
        if kind == .divider { displayed = " " }
        if !user && kind == .list {
            body.attributedText = listText(displayed, font: font)
        } else if !user {
            body.attributedText = richText(displayed, font: font)
        } else {
            body.attributedText = NSAttributedString(string: displayed, attributes: [
                .font: font, .foregroundColor: UIColor.label
            ])
        }
        // VoiceOver should read the visible semantic projection, never raw
        // Markdown punctuation or untrusted link destinations.
        let rolePrefix = !user && kind == .quote ? V3L("引用：") : ""
        body.accessibilityLabel = rolePrefix + body.attributedText.string +
            (stable ? "" : V3L("，生成中"))
    }

    /// UITextView.font/textColor may become nil with attributedText.
    /// Supply dynamic UIKit attributes to actual text runs and preserve Markdown
    /// emphasis. Offsets use UTF-16, matching TextKit/NSAttributedString.
    private func richText(_ markdown: String, font: UIFont) -> NSAttributedString {
        let fallback = NSAttributedString(string: markdown, attributes: [
            .font: font, .foregroundColor: UIColor.label
        ])
        guard let parsed = try? AttributedString(markdown: markdown) else {
            return fallback
        }
        let result = NSMutableAttributedString(
            attributedString: NSAttributedString(parsed))
        // Remove disallowed URL attributes, not just their visual ink. Do not
        // modify the attributed string while enumerating its original runs.
        let full = NSRange(location: 0, length: result.length)
        var invalidLinks: [NSRange] = []
        result.enumerateAttribute(.link, in: full, options: []) { value, range, _ in
            guard let value else { return }
            let url = (value as? URL) ?? (value as? String).flatMap(URL.init(string:))
            if url.map(Self.safeExternalURL) != true { invalidLinks.append(range) }
        }
        for range in invalidLinks { result.removeAttribute(.link, range: range) }
        var offset = 0
        for run in parsed.runs {
            let length = String(parsed[run.range].characters).utf16.count
            defer { offset += length }
            guard length > 0, offset + length <= result.length else { continue }
            let range = NSRange(location: offset, length: length)
            let intent = run.inlinePresentationIntent
            var traits = font.fontDescriptor.symbolicTraits
            if intent?.contains(.stronglyEmphasized) == true {
                traits.insert(.traitBold)
            }
            if intent?.contains(.emphasized) == true {
                traits.insert(.traitItalic)
            }
            let runFont = font.fontDescriptor.withSymbolicTraits(traits)
                .map { UIFont(descriptor: $0, size: font.pointSize) } ?? font
            result.addAttribute(.font, value: runFont, range: range)
            let ink: UIColor = result.attribute(.link, at: offset,
                                                effectiveRange: nil) == nil
                ? .label : .link
            result.addAttribute(.foregroundColor, value: ink, range: range)
            if intent?.contains(.strikethrough) == true {
                result.addAttribute(.strikethroughStyle,
                    value: NSUnderlineStyle.single.rawValue, range: range)
            }
        }
        return result
    }

    private func listText(_ markdown: String, font: UIFont) -> NSAttributedString {
        let result = NSMutableAttributedString(string: "")
        for line in markdown.components(separatedBy: "\n") {
            let spaces = line.prefix(while: { $0 == " " }).count
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            let dash = ["- ", "+ ", "* "].first { trimmed.hasPrefix($0) }
            let digits = trimmed.prefix(while: { $0.isNumber })
            let numbered = !digits.isEmpty &&
                (trimmed.dropFirst(digits.count).hasPrefix(". ") ||
                 trimmed.dropFirst(digits.count).hasPrefix(") "))
            let marker = dash != nil ? "• " :
                (numbered ? String(digits) + ". " : "")
            let body: String
            if let dash { body = String(trimmed.dropFirst(dash.count)) }
            else if numbered { body = String(trimmed.dropFirst(digits.count + 2)) }
            else { body = trimmed }
            let paragraph = NSMutableParagraphStyle()
            let x = CGFloat(min(8, spaces / 2)) * 18 + 4
            paragraph.firstLineHeadIndent = x
            paragraph.headIndent = x + (marker.isEmpty ? 0 : 20)
            paragraph.paragraphSpacing = 4
            let chunk = marker + body + "\n"
            let resultLine = NSMutableAttributedString(
                attributedString: richText(chunk, font: font))
            resultLine.addAttribute(.paragraphStyle, value: paragraph,
                range: NSRange(location: 0, length: resultLine.length))
            result.append(resultLine)
        }
        return result
    }
}

@MainActor
private final class ImpressChatStatusCell: UICollectionViewCell {
    private let label = UILabel()
    override init(frame: CGRect) {
        super.init(frame: frame)
        label.font = .preferredFont(forTextStyle: .caption1)
        label.adjustsFontForContentSizeCategory = true
        label.textColor = .secondaryLabel
        label.numberOfLines = 0
        label.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 14),
            label.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -14),
            label.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 3),
            label.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -3)
        ])
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) unsupported") }
    func configure(_ text: String) {
        label.text = text
        accessibilityIdentifier = "impress.ai.chat.stream-status"
    }
}


/// Compact assistant reply footer: native 44pt controls, no full-width IM bar.
@MainActor
final class ImpressChatReplyActionsCell: UICollectionViewCell {
    private let copyButton = UIButton(type: .system)
    private let moreButton = UIButton(type: .system)
    private let stack = UIStackView()
    private var currentText = ""

    override init(frame: CGRect) {
        super.init(frame: frame)
        stack.axis = .horizontal
        stack.alignment = .center
        stack.spacing = 0
        stack.translatesAutoresizingMaskIntoConstraints = false
        copyButton.translatesAutoresizingMaskIntoConstraints = false
        moreButton.translatesAutoresizingMaskIntoConstraints = false
        copyButton.setImage(UIImage(systemName: "doc.on.doc"), for: .normal)
        moreButton.setImage(UIImage(systemName: "ellipsis"), for: .normal)
        for button in [copyButton, moreButton] {
            button.tintColor = .secondaryLabel
            stack.addArrangedSubview(button)
        }
        copyButton.accessibilityLabel = V3L("复制回复")
        copyButton.accessibilityIdentifier = "impress.ai.chat.reply-copy"
        moreButton.accessibilityLabel = V3L("更多回复操作")
        moreButton.accessibilityIdentifier = "impress.ai.chat.reply-more"
        copyButton.addTarget(self, action: #selector(copyMessage), for: .touchUpInside)
        moreButton.showsMenuAsPrimaryAction = true
        contentView.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 2),
            stack.topAnchor.constraint(equalTo: contentView.topAnchor),
            stack.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: contentView.trailingAnchor),
            copyButton.widthAnchor.constraint(equalToConstant: 44),
            copyButton.heightAnchor.constraint(equalToConstant: 44),
            moreButton.widthAnchor.constraint(equalToConstant: 44),
            moreButton.heightAnchor.constraint(equalToConstant: 44)
        ])
        accessibilityIdentifier = "impress.ai.chat.reply-actions"
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) unsupported") }

    func configure(messageID: UUID, text: String, menu: UIMenu?) {
        currentText = text
        moreButton.menu = menu
        accessibilityValue = messageID.uuidString
    }

    @objc private func copyMessage() {
        UIPasteboard.general.string = currentText
    }
}
