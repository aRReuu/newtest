import UIKit
import ImpressReviewCore
#if DEBUG
import Darwin
#endif

/// Reuse the editable Settings → Prompt Library as the single authoring
/// authority. Only a template UUID (never its private text) is kept as a local
/// preference; the live template body is read when the user explicitly Sends.
enum ImpressAIChatPromptSelection {
    static let storageKey = "ImpressV1NativeChatPromptTemplateID"

    static func selectedTemplate() -> ImpressV3PromptTemplate? {
        guard let raw = UserDefaults.standard.string(forKey: storageKey),
              let id = UUID(uuidString: raw) else { return nil }
        return ImpressV3PromptLibrary.load().first(where: { $0.id == id })
    }

    static func choose(_ templateID: UUID?) {
        if let templateID {
            UserDefaults.standard.set(templateID.uuidString, forKey: storageKey)
        } else {
            UserDefaults.standard.removeObject(forKey: storageKey)
        }
        ImpressV3BackupCoordinator.markDataChanged()
    }

    static func systemText() -> String {
        selectedTemplate()?.content ??
            V3L("以第一性原理和奥卡姆剃刀分析问题，明确假设、证据与边界。不编造笔记内容。")
    }
}

/// Source-scoped native API chat. A cardID (not a mutable title) binds the
/// conversation to the existing V3 SQLite/backup authority. Local history is
/// complete; the remote request window is bounded and independently consented.
/// Ordinary Chat produces no FSRS events or Markdown writes.

enum ImpressChatWindowPolicy {
    static let maximumPreviousTurns = 16

    /// Keep the complete archive locally but never imply that the remote
    /// model received the entire transcript when its context was bounded.
    static func omittedCompletedCount(in history: [WCDBV3ChatMessage]) -> Int {
        max(0, history.filter { $0.status == .completed }.count -
            maximumPreviousTurns)
    }
}

@MainActor
enum ImpressChatNoteUploadGate {
    /// The user approves THIS exact Vault version and these excerpt bytes,
    /// not arbitrary saved text that happens to share a title or session ID.
    /// This is checked after a coordinated File Provider read, immediately
    /// before any paid or free HTTP call is attempted.
    static let maximumSentNoteBytes = 40_000

    static func validate(document: ImVaultRawDocument,
                         expectedIdentity: ImVaultFileIdentity,
                         expectedDigest: String?,
                         conversationKey: String?,
                         excerpts: [WCDBV3ChatContextReference]) throws {
        guard let expectedDigest, let conversationKey, !conversationKey.isEmpty,
              document.identity == expectedIdentity,
              document.digest == expectedDigest,
              ImVaultDigest.sha256(document.sourceBytes) == expectedDigest,
              !excerpts.isEmpty else {
            throw ImVaultSyncFailure.conflict
        }
        let format = expectedIdentity.documentFormat
        let isPluginDrawing = format == .markdown &&
            ImpressObsidianDrawingEnvelope.isSupportedDrawing(document.sourceBytes)
        let sections = format == .markdown && !isPluginDrawing
            ? ImpressAISectionExtractor.sections(in: document.markdown) : []
        let canvas = format == .jsonCanvas
            ? try ImpressCanvasDocument.parse(document.sourceBytes) : nil
        let drawing = (format == .excalidrawJSON || format == .excalidrawMarkdown ||
                       isPluginDrawing)
            ? try ImpressExcalidrawScene.parse(document.sourceBytes,
                format: isPluginDrawing ? .excalidrawMarkdown : format) : nil
        var bytes = 0
        for item in excerpts {
            bytes += item.excerpt.utf8.count
            guard bytes <= maximumSentNoteBytes else {
                throw ImpressAIServiceError.tooLarge
            }
            guard item.stableIdentity == conversationKey,
                  item.sourceRevision == expectedDigest,
                  !item.excerpt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw ImVaultSyncFailure.conflict
            }
            switch format {
            case .markdown:
                if item.sourceFormat == "excalidraw-structure" {
                    guard isPluginDrawing, let drawing,
                          item.sourceStartUTF8 == nil, item.sourceEndUTF8 == nil,
                          let ids = item.selectedCanvasNodeIDs, !ids.isEmpty,
                          Set(ids).count == ids.count else {
                        throw ImVaultSyncFailure.conflict
                    }
                    let selection = try drawing.selection(ids: Set(ids))
                    guard selection.elements.count == ids.count,
                          try selection.textContextJSON() == item.excerpt else {
                        throw ImVaultSyncFailure.conflict
                    }
                    continue
                }
                // A drawing with .md suffix cannot be uploaded as plain text.
                guard !isPluginDrawing else { throw ImVaultSyncFailure.conflict }
                if item.sourceFormat == "mermaid-structure" ||
                   item.sourceFormat == "markmap-structure" {
                    let scoped: ImpressDiagramDocument
                    if item.sourceFormat == "mermaid-structure" {
                        let blocks = try ImpressDiagramDocument.mermaidBlocks(
                            in: document.sourceBytes)
                        guard let found = blocks.first(where: {
                            $0.startUTF8 == item.sourceStartUTF8 &&
                            $0.endUTF8 == item.sourceEndUTF8
                        }) else { throw ImVaultSyncFailure.conflict }
                        scoped = found
                    } else {
                        scoped = try ImpressDiagramDocument.markmap(in: document.sourceBytes)
                    }
                    guard scoped.startUTF8 == item.sourceStartUTF8,
                          scoped.endUTF8 == item.sourceEndUTF8,
                          let ids = item.selectedCanvasNodeIDs, !ids.isEmpty,
                          Set(ids).count == ids.count else {
                        throw ImVaultSyncFailure.conflict
                    }
                    let selection = try scoped.selection(ids: Set(ids))
                    guard selection.ids == ids.sorted(),
                          try selection.contextJSON() == item.excerpt else {
                        throw ImVaultSyncFailure.conflict
                    }
                    continue
                }
                guard (item.sourceFormat == nil || item.sourceFormat == "markdown"),
                      item.selectedCanvasNodeIDs == nil else {
                    throw ImVaultSyncFailure.conflict
                }
                // Legacy v1-v3 excerpts have no byte span. Retain strict text
                // compatibility, but verify BOTH offsets for V1.1 materials.
                let matched = sections.contains { section in
                    guard section.text == item.excerpt else { return false }
                    if let start = item.sourceStartUTF8, let end = item.sourceEndUTF8 {
                        return section.startUTF8 == start && section.endUTF8 == end
                    }
                    return item.sourceStartUTF8 == nil && item.sourceEndUTF8 == nil
                }
                let legacyFull = item.sourceStartUTF8 == nil &&
                    item.sourceEndUTF8 == nil && item.excerpt == document.markdown
                guard matched || legacyFull else { throw ImVaultSyncFailure.conflict }
            case .jsonCanvas:
                guard let canvas,
                      item.sourceFormat == "json-canvas",
                      item.sourceStartUTF8 == nil, item.sourceEndUTF8 == nil,
                      let requested = item.selectedCanvasNodeIDs, !requested.isEmpty,
                      Set(requested).count == requested.count else {
                    throw ImVaultSyncFailure.conflict
                }
                let selected = try canvas.selection(nodeIDs: Set(requested))
                guard selected.nodes.count == requested.count,
                      selected.nodes.allSatisfy(\.isKnownType),
                      try selected.serializedJSON() == item.excerpt else {
                    throw ImVaultSyncFailure.conflict
                }
            case .excalidrawMarkdown, .excalidrawJSON:
                guard let drawing, item.sourceFormat == "excalidraw-structure",
                      item.sourceStartUTF8 == nil, item.sourceEndUTF8 == nil,
                      let ids = item.selectedCanvasNodeIDs, !ids.isEmpty,
                      Set(ids).count == ids.count else {
                    throw ImVaultSyncFailure.conflict
                }
                let selection = try drawing.selection(ids: Set(ids))
                guard selection.elements.count == ids.count,
                      try selection.textContextJSON() == item.excerpt else {
                    throw ImVaultSyncFailure.conflict
                }
                // Approved structure only: no binary pixels or embedded files.
            case .unsupported:
                throw ImVaultSyncFailure.conflict
            }
        }
    }
}

@MainActor
enum ImpressChatProviderConsentGate {
    /// A failed or cancelled first call may have disclosed user text. Do not
    /// treat that attempt as if the user never selected a provider.
    static func needsReapproval(history: [WCDBV3ChatMessage],
                                destination: UUID) -> Bool {
        guard let previous = history.reversed().first(where: {
            $0.role == .user && $0.providerID != nil
        })?.providerID else { return false }
        return previous != destination
    }
}

@MainActor
final class ImpressAINativeChatViewController: UIViewController,
                                                UITextViewDelegate {
    private let sourceQuestion: String?
    private let sourceAnswer: String?
    private let sourceCardID: UUID?
    private let sourceContentRevision: Int?
    private let injectedRepository: ReviewWCDBRepository?
    private let explicitSourceKey: String?
    private let sourceVersionToken: String?
    private let noteIdentity: ImVaultFileIdentity?
    /// Navigation-only target from a card's stable source identity.
    /// Does not authorize uploading the note or writing to its Vault.
    private let linkedNoteIdentity: ImVaultFileIdentity?
    private var chatRepository: ReviewWCDBRepository?
    private var storedSession: WCDBV3ChatSession?
    private var pendingDuplex: WCDBV3DuplexProposal?
    private var previousDuplex: [WCDBV3DuplexProposal] = []
    // Archiving an unresolved but NON-INFLIGHT conflict requires one
    // explicit human decision and an atomic WCDB session CAS.
    private var startingFreshConflictReview = false
    private var contextReferences: [WCDBV3ChatContextReference] = []
    private var history: [WCDBV3ChatMessage] = []
    private var requestFailure: String?
    private var activeProviderID: UUID?
    /// An override belongs only to this Chat; global task defaults remain intact.
    private var selectedModelID: UUID?
    private var contextChoiceMade = false
    private var contextConsentGranted = false
    private var includeCardContext = false
    private var acknowledgedBoundedContext = false
    private var restoring = false
    private var sending = false
    /// An on-screen consent sheet is not yet a network request. Lock before
    /// presenting it so rapid Send callbacks cannot queue extra approvals.
    private var sendConsentPending = false
    private var saveChain: Task<Void, Never>?
    private var requestTask: Task<Void, Never>?
    private var draftDebounce: Task<Void, Never>?

    private var entrySourceIdentity: String? {
        if let explicitSourceKey { return explicitSourceKey }
        if let sourceCardID { return "card:" + sourceCardID.uuidString }
        if let note = noteIdentity ?? linkedNoteIdentity {
            let scoped = note.vaultID + "\n" + note.relativePath
            return "note:" + ImVaultDigest.sha256(Data(scoped.utf8))
        }
        return "chat:standalone:v1"
    }
    private var sourceIdentity: String? {
        storedSession?.sourceIdentity ?? entrySourceIdentity
    }
    private var isForeignSession: Bool {
        guard let storedSession else { return false }
        return storedSession.sourceIdentity != entrySourceIdentity
    }
    private var entrySourceDisplayName: String {
        if let note = noteIdentity ?? linkedNoteIdentity {
            return note.relativePath
        }
        if let question = sourceQuestion, !question.isEmpty {
            return String(question.prefix(160))
        }
        return V3L("独立讨论")
    }

    private var currentSourceVersion: String {
        sourceVersionToken ?? String(sourceContentRevision ?? -1)
    }
    private var noteDraftTarget: ImVaultFileIdentity? {
        let note = noteIdentity ?? linkedNoteIdentity
        return note?.documentFormat == .markdown ? note : nil
    }

    private let transcript = ImpressChatProductionTranscript()
    private let messageInput = UITextView()
    private let inputPlaceholder = UILabel()
    private let sendButton = UIButton(type: .system)
    private let inputBar = UIView()
    private let privacyLabel = UILabel()
    private let materialButton = UIButton(type: .system)
    private let speechButton = UIButton(type: .system)
    private var statusTask: Task<Void, Never>?
    private let attachmentChip = UIButton(type: .system)
    private let composerColumn = UIStackView()
    private let composerRow = UIStackView()
    private let localAttachmentScroller = UIScrollView()
    private let localAttachmentRow = UIStackView()
    private let localAttachmentHint = UILabel()
    private var localAttachmentHeight: NSLayoutConstraint?
    private var acknowledgedTextOnlyPreviews = false
    // Frozen only after a real Send confirmation. No bytes reach WCDB/backup.
    private var approvedImagesForSend: ImpressChatEphemeralFileConsent.ImageSnapshot?
    /// One approved text-material request. Never persisted in WCDB/backup.
    private var approvedTextForSend: ImpressChatEphemeralFileConsent.Snapshot?
    // Stable identity for an unsaved first discussion. Consent must not be
    // invalidated simply because WCDB assigns a session row on first send.
    private var provisionalChatSessionID = UUID()

    private struct ApprovedFileRoute: Encodable {
        let connection: ImpressAIConnection
        let model: ImpressAIModel
    }

    private func attachmentDestination(_ route: ImpressAIResolvedRoute)
        -> ImpressChatEphemeralFileConsent.Destination? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let routeFingerprint = try? encoder.encode(ApprovedFileRoute(
            connection: route.connection, model: route.model)) else { return nil }
        return ImpressChatEphemeralFileConsent.Destination(
            providerID: route.connection.id, modelID: route.model.id,
            modelName: route.model.identifier,
            endpoint: route.connection.baseURL.absoluteString,
            wireProtocol: String(describing: route.effectiveProtocol),
            sessionID: storedSession?.sessionID ?? provisionalChatSessionID,
            routeFingerprint: routeFingerprint)
    }

    private func liveAttachmentRoute(for approved: ImpressAIResolvedRoute)
        -> ImpressAIResolvedRoute? {
        #if DEBUG
        // Synthetic E2E routing is deliberately absent from the live registry.
        if ImpressV11UITestFixture.enabled &&
           (noteIdentity?.vaultID == ImpressV11UITestFixture.vaultID ||
            sourceCardID != nil) {
            return approved
        }
        #endif
        return try? liveRoute()
    }
    // Existing bounded system picker implementation becomes a real production
    // composer preview. Its data never enters WCDB or provider payloads.
    private lazy var localAttachments = ImpressChatPOCLocalAttachments(presenting: self)
    private var messageHeight: NSLayoutConstraint?
    private static let introductionKey = "ImpressV11ChatIntroductionSeen"
    private var pendingInitialMaterials: [WCDBV3ChatContextReference]
    private var sessionPromptOverride: String?

    init(question: String? = nil, answer: String? = nil,
         cardID: UUID? = nil, contentRevision: Int? = nil,
         repository: ReviewWCDBRepository? = nil,
         sourceKey: String? = nil, sourceVersion: String? = nil,
         noteIdentity: ImVaultFileIdentity? = nil,
         linkedNoteIdentity: ImVaultFileIdentity? = nil,
         initialMaterials: [WCDBV3ChatContextReference] = []) {
        self.pendingInitialMaterials = initialMaterials
        self.linkedNoteIdentity = linkedNoteIdentity
        self.explicitSourceKey = sourceKey
        self.sourceVersionToken = sourceVersion
        self.noteIdentity = noteIdentity
        self.sourceQuestion = question
        self.sourceAnswer = answer
        self.sourceCardID = cardID
        self.sourceContentRevision = contentRevision
        self.injectedRepository = repository
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) unsupported") }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        draftDebounce?.cancel()
        enqueuePersistence()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        inputPlaceholder.text = V3L("询问任何问题")
        refreshModelPicker()
    }

    private func liveRoute() throws -> ImpressAIResolvedRoute {
        let registry = ImpressAIConfigStore.shared.registry
        if let selectedModelID {
            guard let model = registry.models.first(where: { $0.id == selectedModelID }),
                  let connection = registry.connections.first(where: {
                      $0.id == model.connectionID
                  }) else { throw ImpressAIContractError.invalidRoute }
            let route = ImpressAIResolvedRoute(connection: connection, model: model)
            try ImpressAIRequestPolicy.validate(route)
            return route
        }
        return try registry.resolve(.conversation)
    }

    private func refreshModelPicker() {
        navigationItem.prompt = nil
        let more = ImpressV3Appearance.navigationAction(
            symbol: "ellipsis.circle", label: V3L("对话功能"),
            target: nil, action: nil)
        // A UIBarButtonItem menu takes precedence over its target/action.
        // All feature choices are native inline menus, never a pushed list page.
        more.menu = chatFeaturesMenu()
        more.accessibilityIdentifier = "impress.ai.chat.features"
        let fresh = ImpressV3Appearance.navigationAction(
            symbol: "square.and.pencil", label: V3L("新建讨论"),
            target: self, action: #selector(startNewDiscussion))
        fresh.accessibilityIdentifier = "impress.ai.chat.new-discussion"
        navigationItem.rightBarButtonItems = [fresh, more]
    }

    private func chatFeaturesMenu() -> UIMenu {
        var receipts: [UIMenuElement] = []
        if pendingDuplex != nil || !previousDuplex.isEmpty {
            receipts.append(UIAction(title: V3L("修订记录与回执"),
                image: UIImage(systemName: "checklist")) { [weak self] _ in
                    self?.openDuplexReceipts()
                })
        }
        receipts.append(UIAction(title: V3L("已删除会话修订回执"),
            image: UIImage(systemName: "archivebox")) { [weak self] _ in
                self?.openArchivedDuplexReceipts()
            })
        return UIMenu(children: [
            UIAction(title: V3L("历史讨论"),
                image: UIImage(systemName: "clock.arrow.circlepath")) { [weak self] _ in
                    self?.openDiscussionHistory()
                },
            UIMenu(title: V3L("对话设置"), image: UIImage(systemName: "slider.horizontal.3"),
                children: [
                    UIAction(title: V3L("模型"), image: UIImage(systemName: "cpu")) {
                        [weak self] _ in self?.chooseConversationModel()
                    },
                    UIAction(title: V3L("提示词"), image: UIImage(systemName: "text.alignleft")) {
                        [weak self] _ in self?.openSessionPrompt()
                    },
                    UIAction(title: V3L("本次材料"), image: UIImage(systemName: "paperclip")) {
                        [weak self] _ in self?.reviewSessionMaterials()
                    }
                ]),
            UIMenu(title: V3L("历史回执"), image: UIImage(systemName: "archivebox"),
                   children: receipts),
            UIAction(title: V3L("使用说明"), image: UIImage(systemName: "info.circle")) {
                [weak self] _ in self?.showChatIntroduction()
            }
        ])
    }

    private func showChatIntroduction() {
        let alert = UIAlertController(title: V3L("关于讨论"),
            message: V3L("对话和草稿保存在本机。只有主动发送并确认材料后才会请求服务商；普通讨论不会自动修改笔记或卡片。"),
            preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: V3L("知道了"), style: .default))
        present(alert, animated: true)
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        guard !UserDefaults.standard.bool(forKey: Self.introductionKey) else { return }
        UserDefaults.standard.set(true, forKey: Self.introductionKey)
        showChatIntroduction()
    }

    @objc private func chooseConversationModel() {
        // A session override must never change the global default route.
        let picker = ImpressAIModelChooser(task: .conversation,
            selectedOverrideID: selectedModelID) { [weak self] picked in
                self?.selectedModelID = picked
                self?.approvedTextForSend = nil
                self?.approvedImagesForSend = nil
                self?.refreshModelPicker()
                self?.enqueuePersistence() // Preserve model before Send.
            }
        navigationController?.pushViewController(picker, animated: true)
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = ""
        view.backgroundColor = ImpressV3Appearance.page
        navigationItem.largeTitleDisplayMode = .never

        // Production uses stable message/block IDs and a diffable content layout.
        // Reuse the original knowledge-approval menu at message identity scope.
        transcript.menuForMessage = { [weak self] id in
            guard let self,
                  let turn = self.history.first(where: { $0.messageID == id })
            else { return nil }
            return self.messageMenu(for: turn)
        }

        privacyLabel.font = ImpressV3Appearance.Typography.caption
        privacyLabel.adjustsFontForContentSizeCategory = true
        privacyLabel.numberOfLines = 2
        privacyLabel.textColor = ImpressV3Appearance.secondaryText
        privacyLabel.textAlignment = .center
        // Explanatory privacy text is a one-time introduction; this label is
        // reserved for exceptional transient status, never an empty-state banner.
        privacyLabel.text = nil
        privacyLabel.backgroundColor = ImpressV3Appearance.surface
        privacyLabel.layer.cornerRadius = 10
        privacyLabel.layer.masksToBounds = true
        privacyLabel.isHidden = true

        messageInput.font = ImpressV3Appearance.Typography.body
        messageInput.adjustsFontForContentSizeCategory = true
        messageInput.textColor = ImpressV3Appearance.primaryText
        messageInput.backgroundColor = ImpressV3Appearance.surface
        messageInput.layer.cornerRadius = ImpressV3Appearance.Radius.field
        messageInput.textContainerInset = UIEdgeInsets(
            top: ImpressV3Appearance.Metrics.chatComposerTextVerticalInset,
            left: ImpressV3Appearance.Metrics.chatComposerTextHorizontalInset,
            bottom: ImpressV3Appearance.Metrics.chatComposerTextVerticalInset,
            right: ImpressV3Appearance.Metrics.chatComposerTextHorizontalInset)
        messageInput.delegate = self
        messageInput.accessibilityLabel = V3L("消息内容")
        messageInput.accessibilityIdentifier = "impress.ai.chat.input"
        // A visual hint, never part of UITextView.text, session drafts or
        // transmitted requests. Hides when the real input contains characters.
        inputPlaceholder.translatesAutoresizingMaskIntoConstraints = false
        inputPlaceholder.text = V3L("询问任何问题")
        inputPlaceholder.font = ImpressV3Appearance.Typography.body
        inputPlaceholder.adjustsFontForContentSizeCategory = true
        inputPlaceholder.textColor = ImpressV3Appearance.chatComposerPlaceholder
        inputPlaceholder.isUserInteractionEnabled = false
        inputPlaceholder.accessibilityIdentifier = "impress.ai.chat.input-placeholder"
        messageInput.addSubview(inputPlaceholder)
        NSLayoutConstraint.activate([
            inputPlaceholder.leadingAnchor.constraint(
                equalTo: messageInput.leadingAnchor,
                constant: ImpressV3Appearance.Metrics.chatComposerTextHorizontalInset +
                    messageInput.textContainer.lineFragmentPadding),
            inputPlaceholder.trailingAnchor.constraint(
                lessThanOrEqualTo: messageInput.trailingAnchor, constant: -8),
            inputPlaceholder.centerYAnchor.constraint(equalTo: messageInput.centerYAnchor)
        ])
        // Chat keeps its native speech-to-text workflow accessible directly
        // in the compact composer. Other text editors retain keyboard access.

        if #available(iOS 15.0, *) {
            var config = UIButton.Configuration.filled()
            config.image = UIImage(systemName: "arrow.up")
            config.cornerStyle = .capsule
            config.buttonSize = .small
            // ChatGPT-like compact monochrome send control, never the blue
            // system accent used by selection. This does not alter Send/Stop.
            config.baseBackgroundColor = ImpressV3Appearance.chatComposerSendFill
            config.baseForegroundColor = ImpressV3Appearance.chatComposerSendInk
            sendButton.configuration = config
        } else {
            sendButton.setImage(UIImage(systemName: "arrow.up"), for: .normal)
        }
        sendButton.addTarget(self, action: #selector(submitOrStopMessage), for: .touchUpInside)
        sendButton.accessibilityLabel = V3L("发送消息")
        sendButton.accessibilityIdentifier = "impress.ai.chat.send"
        sendButton.isEnabled = false

        inputBar.backgroundColor = ImpressV3Appearance.chatComposerSurface
        inputBar.layer.cornerRadius = ImpressV3Appearance.Metrics.chatComposerRadius
        inputBar.layer.borderColor = ImpressV3Appearance.chatComposerBorder
            .resolvedColor(with: traitCollection).cgColor
        inputBar.layer.borderWidth = 0.5
        composerColumn.axis = .vertical
        composerColumn.spacing = 2
        composerRow.axis = .horizontal
        composerRow.alignment = .center
        composerRow.spacing = 0
        var add = UIButton.Configuration.plain()
        add.image = UIImage(systemName: "plus",
            withConfiguration: UIImage.SymbolConfiguration(
                pointSize: ImpressV3Appearance.Metrics.chatComposerGlyphPointSize,
                weight: .regular))
        add.baseForegroundColor = ImpressV3Appearance.primaryText
        materialButton.configuration = add
        materialButton.accessibilityLabel = V3L("添加相册、文件或拍照")
        materialButton.accessibilityIdentifier = "impress.ai.chat.add-material"
        materialButton.menu = localAttachments.pickerMenu()
        materialButton.showsMenuAsPrimaryAction = true
        localAttachments.onChange = { [weak self] _ in
            self?.acknowledgedTextOnlyPreviews = false
            self?.approvedImagesForSend = nil
            self?.approvedTextForSend = nil
            self?.updateLocalPreviewStrip()
            if let self { self.textViewDidChange(self.messageInput) }
        }
        var dictation = UIButton.Configuration.plain()
        dictation.image = UIImage(systemName: "mic",
            withConfiguration: UIImage.SymbolConfiguration(
                pointSize: ImpressV3Appearance.Metrics.chatComposerGlyphPointSize,
                weight: .regular))
        dictation.baseForegroundColor = ImpressV3Appearance.primaryText
        speechButton.configuration = dictation
        speechButton.accessibilityLabel = V3L("语音输入转文字")
        speechButton.accessibilityIdentifier = "impress.ai.chat.speech-input"
        speechButton.addTarget(self, action: #selector(openSpeechInput), for: .touchUpInside)

        attachmentChip.setTitle(V3L("查看已选材料"), for: .normal)
        attachmentChip.setImage(UIImage(systemName: "paperclip"), for: .normal)
        attachmentChip.titleLabel?.font = ImpressV3Appearance.Typography.caption
        attachmentChip.contentHorizontalAlignment = .leading
        attachmentChip.accessibilityIdentifier = "impress.ai.chat.attachment"
        attachmentChip.addTarget(self, action: #selector(reviewSessionMaterials),
                                 for: .touchUpInside)
        attachmentChip.isHidden = true
        for element in [transcript, inputBar, privacyLabel] {
            element.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(element)
        }
        composerColumn.translatesAutoresizingMaskIntoConstraints = false
        inputBar.addSubview(composerColumn)
        for element in [materialButton, messageInput, speechButton, sendButton] {
            element.translatesAutoresizingMaskIntoConstraints = false
        }
        composerRow.addArrangedSubview(materialButton)
        composerRow.addArrangedSubview(messageInput)
        composerRow.addArrangedSubview(speechButton)
        composerRow.addArrangedSubview(sendButton)
        localAttachmentScroller.showsHorizontalScrollIndicator = false
        localAttachmentScroller.accessibilityIdentifier = "impress.ai.chat.local-preview-strip"
        localAttachmentScroller.isHidden = true
        localAttachmentRow.axis = .horizontal
        localAttachmentRow.alignment = .center
        localAttachmentRow.spacing = 8
        localAttachmentRow.translatesAutoresizingMaskIntoConstraints = false
        localAttachmentScroller.addSubview(localAttachmentRow)
        let previewHeight = localAttachmentScroller.heightAnchor.constraint(equalToConstant: 0)
        localAttachmentHeight = previewHeight
        NSLayoutConstraint.activate([
            previewHeight,
            localAttachmentRow.leadingAnchor.constraint(
                equalTo: localAttachmentScroller.contentLayoutGuide.leadingAnchor),
            localAttachmentRow.trailingAnchor.constraint(
                equalTo: localAttachmentScroller.contentLayoutGuide.trailingAnchor),
            localAttachmentRow.centerYAnchor.constraint(
                equalTo: localAttachmentScroller.contentLayoutGuide.centerYAnchor),
            localAttachmentRow.heightAnchor.constraint(
                equalTo: localAttachmentScroller.frameLayoutGuide.heightAnchor)
        ])
        localAttachmentHint.font = .preferredFont(forTextStyle: .caption2)
        localAttachmentHint.textColor = .secondaryLabel
        localAttachmentHint.adjustsFontForContentSizeCategory = true
        localAttachmentHint.numberOfLines = 2
        localAttachmentHint.text = V3L(
            "附件未发送。文本 TXT/MD/CSV/JSON、支持的图片须逐次批准才能发送；其他文件仅预览。")
        localAttachmentHint.accessibilityIdentifier =
            "impress.ai.chat.local-preview-not-transmitted"
        localAttachmentHint.isHidden = true
        composerColumn.addArrangedSubview(localAttachmentScroller)
        composerColumn.addArrangedSubview(localAttachmentHint)
        composerColumn.addArrangedSubview(attachmentChip)
        composerColumn.addArrangedSubview(composerRow)
        messageInput.isScrollEnabled = false
        messageInput.backgroundColor = .clear
        messageInput.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let dynamicHeight = messageInput.heightAnchor.constraint(equalToConstant: 44)
        messageHeight = dynamicHeight
        NSLayoutConstraint.activate([
            transcript.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            transcript.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor),
            transcript.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor),
            transcript.bottomAnchor.constraint(equalTo: inputBar.topAnchor, constant: -8),
            privacyLabel.leadingAnchor.constraint(
                equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 20),
            privacyLabel.trailingAnchor.constraint(
                equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -20),
            privacyLabel.bottomAnchor.constraint(equalTo: inputBar.topAnchor, constant: -10),
            privacyLabel.heightAnchor.constraint(lessThanOrEqualToConstant: 64),
            inputBar.leadingAnchor.constraint(
                equalTo: view.safeAreaLayoutGuide.leadingAnchor,
                constant: ImpressV3Appearance.Metrics.screenInset),
            inputBar.trailingAnchor.constraint(
                equalTo: view.safeAreaLayoutGuide.trailingAnchor,
                constant: -ImpressV3Appearance.Metrics.screenInset),
            inputBar.bottomAnchor.constraint(equalTo: view.keyboardLayoutGuide.topAnchor,
                                             constant: -4),
            composerColumn.topAnchor.constraint(equalTo: inputBar.topAnchor, constant: 3),
            composerColumn.bottomAnchor.constraint(equalTo: inputBar.bottomAnchor, constant: -3),
            composerColumn.leadingAnchor.constraint(equalTo: inputBar.leadingAnchor,
                constant: ImpressV3Appearance.Metrics.chatComposerInnerInset),
            composerColumn.trailingAnchor.constraint(equalTo: inputBar.trailingAnchor,
                constant: -ImpressV3Appearance.Metrics.chatComposerInnerInset),
            dynamicHeight,
            materialButton.widthAnchor.constraint(equalToConstant: 44),
            materialButton.heightAnchor.constraint(equalToConstant: 44),
            speechButton.widthAnchor.constraint(equalToConstant: 44),
            speechButton.heightAnchor.constraint(equalToConstant: 44),
            sendButton.widthAnchor.constraint(equalToConstant: 44),
            sendButton.heightAnchor.constraint(equalToConstant: 44),
            attachmentChip.heightAnchor.constraint(greaterThanOrEqualToConstant: 26)
        ])
        updateAttachmentPresentation()
        refreshModelPicker() // Header is valid before appearance and after cold start.
        Task { await restoreLocalSession() }
    }

    @objc private func openSpeechInput() {
        guard !sending && !restoring else { return }
        ImpressSpeechAccessory.present(for: messageInput)
    }

    private func showTransientStatus(_ text: String) {
        statusTask?.cancel()
        privacyLabel.text = text
        privacyLabel.isHidden = false
        view.bringSubviewToFront(privacyLabel)
        statusTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(5))
            guard !Task.isCancelled else { return }
            self?.privacyLabel.isHidden = true
        }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        updateComposerHeight()
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        inputBar.layer.borderColor = ImpressV3Appearance.chatComposerBorder
            .resolvedColor(with: traitCollection).cgColor
    }

    private func updateComposerHeight() {
        guard messageInput.bounds.width > 0 else { return }
        let ideal = messageInput.sizeThatFits(
            CGSize(width: messageInput.bounds.width,
                   height: CGFloat.greatestFiniteMagnitude)).height
        let limit = max(80, min(160, view.bounds.height * 0.34))
        let height = max(44, min(limit, ideal))
        if let constraint = messageHeight, abs(constraint.constant - height) > 1 {
            constraint.constant = height
        }
        messageInput.isScrollEnabled = ideal > limit
    }

    private func updateLocalPreviewStrip() {
        for control in localAttachmentRow.arrangedSubviews {
            localAttachmentRow.removeArrangedSubview(control)
            control.removeFromSuperview()
        }
        let items = localAttachments.items
        let visible = !items.isEmpty
        localAttachmentScroller.isHidden = !visible
        localAttachmentHint.isHidden = !visible
        localAttachmentHeight?.constant = visible ? 52 : 0
        for item in items {
            let chip = UIView()
            chip.backgroundColor = .tertiarySystemFill
            chip.layer.cornerRadius = 12
            chip.translatesAutoresizingMaskIntoConstraints = false
            chip.accessibilityIdentifier = "impress.ai.chat.local-preview"
            let content = UIStackView()
            content.axis = .horizontal
            content.alignment = .center
            content.spacing = 5
            content.translatesAutoresizingMaskIntoConstraints = false
            if let thumbnail = item.thumbnail {
                let preview = UIImageView(image: thumbnail)
                preview.contentMode = .scaleAspectFill
                preview.clipsToBounds = true
                preview.layer.cornerRadius = 7
                preview.translatesAutoresizingMaskIntoConstraints = false
                content.addArrangedSubview(preview)
                NSLayoutConstraint.activate([
                    preview.widthAnchor.constraint(equalToConstant: 36),
                    preview.heightAnchor.constraint(equalToConstant: 36)
                ])
            }
            // The exact locally selected bytes must be inspectable before
            // one-shot network consent. The chip is an action, not a filename
            // label that cannot open its image or text document.
            let open = UIButton(type: .system)
            open.setTitle(item.title, for: .normal)
            open.setTitleColor(.label, for: .normal)
            open.titleLabel?.font = .preferredFont(forTextStyle: .caption1)
            open.titleLabel?.lineBreakMode = .byTruncatingMiddle
            open.titleLabel?.adjustsFontForContentSizeCategory = true
            open.contentHorizontalAlignment = .leading
            open.accessibilityLabel = V3L("查看已选材料") + " " + item.title
            open.accessibilityIdentifier = "impress.ai.chat.local-preview-open"
            open.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            let previewID = item.id
            open.addAction(UIAction { [weak self] _ in
                self?.localAttachments.presentLocalPreview(id: previewID)
            }, for: .touchUpInside)
            content.addArrangedSubview(open)
            let remove = UIButton(type: .system)
            remove.setImage(UIImage(systemName: "xmark.circle.fill"), for: .normal)
            remove.tintColor = .secondaryLabel
            remove.accessibilityLabel = V3L("移除附件") + " " + item.title
            remove.accessibilityIdentifier = "impress.ai.chat.local-preview-remove"
            remove.addAction(UIAction { [weak self] _ in
                self?.localAttachments.remove(id: item.id)
            }, for: .touchUpInside)
            content.addArrangedSubview(remove)
            NSLayoutConstraint.activate([
                remove.widthAnchor.constraint(equalToConstant: 44),
                remove.heightAnchor.constraint(equalToConstant: 44)
            ])
            chip.addSubview(content)
            NSLayoutConstraint.activate([
                chip.widthAnchor.constraint(equalToConstant: 198),
                chip.heightAnchor.constraint(equalToConstant: 48),
                content.leadingAnchor.constraint(equalTo: chip.leadingAnchor, constant: 8),
                content.trailingAnchor.constraint(equalTo: chip.trailingAnchor, constant: -3),
                content.centerYAnchor.constraint(equalTo: chip.centerYAnchor)
            ])
            localAttachmentRow.addArrangedSubview(chip)
        }
        view.setNeedsLayout()
    }

    #if DEBUG
    func addLocalPreviewFixtureForTest(_ name: String) {
        loadViewIfNeeded()
        localAttachments.addSyntheticPreviewForTest(name)
    }
    #endif

    private func updateAttachmentPresentation() {
        let count = contextReferences.count
        attachmentChip.isHidden = count == 0
        attachmentChip.setTitle(V3L("已选材料") + " · " + String(count), for: .normal)
    }

    func textViewDidChange(_ textView: UITextView) {
        inputPlaceholder.isHidden = !(textView.text?.isEmpty ?? true)
        updateComposerHeight()
        updateAttachmentPresentation()
        let content = textView.text.trimmingCharacters(in: .whitespacesAndNewlines)
        let chosenTextFile = localAttachments.textPayloadsForExplicitSend() != nil
        let chosenImageFile = localAttachments.imagePayloadsForExplicitSend() != nil
        sendButton.isEnabled = sending || (!restoring && !sendConsentPending &&
            ImpressChatEphemeralFileConsent.mayBeginSend(
                input: content, hasTextAttachment: chosenTextFile,
                hasImageAttachment: chosenImageFile))
        sendButton.configuration?.image = UIImage(systemName: sending ? "stop.fill" : "arrow.up")
        sendButton.accessibilityLabel = sending ? V3L("停止生成") : V3L("发送消息")
        guard !restoring else { return }
        draftDebounce?.cancel()
        draftDebounce = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(750))
            guard !Task.isCancelled else { return }
            self?.enqueuePersistence()
        }
    }

    @objc private func openSessionPrompt() {
        guard !sending && !restoring else { return }
        let picker = UIAlertController(title: V3L("本次讨论提示词"),
            message: V3L("选择只影响当前讨论的后续消息，不会覆盖全局模板。"),
            preferredStyle: .actionSheet)
        picker.addAction(UIAlertAction(title: V3L("默认：第一性原理 + 奥卡姆剃刀"),
            style: .default) { [weak self] _ in
            self?.sessionPromptOverride = nil
            self?.enqueuePersistence()
        })
        for item in ImpressV3PromptLibrary.load() {
            picker.addAction(UIAlertAction(title: item.title, style: .default) { [weak self] _ in
                self?.previewPrompt(title: item.title, text: item.content)
            })
        }
        picker.addAction(UIAlertAction(title: V3L("编辑本次提示词"),
            style: .default) { [weak self] _ in
            guard let self else { return }
            let editor = UIAlertController(title: V3L("临时提示词"),
                message: V3L("仅在本次讨论使用。可在设置的提示词库长期编辑模板。"),
                preferredStyle: .alert)
            editor.addTextField { $0.text = self.sessionPromptOverride ??
                ImpressAIChatPromptSelection.systemText() }
            editor.addAction(UIAlertAction(title: V3L("取消"), style: .cancel))
            editor.addAction(UIAlertAction(title: V3L("本次使用"), style: .default) { [weak self, weak editor] _ in
                let value = editor?.textFields?.first?.text?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                guard !value.isEmpty else { return }
                self?.sessionPromptOverride = value
                self?.enqueuePersistence()
            })
            self.present(editor, animated: true)
        })
        picker.addAction(UIAlertAction(title: V3L("取消"), style: .cancel))
        picker.popoverPresentationController?.sourceView = view
        present(picker, animated: true)
    }

    /// Display the complete user-authored prompt. A 1,000-character alert
    /// preview could conceal important instructions before user approval.
    private func previewPrompt(title: String, text: String) {
        let page = UIViewController()
        page.title = title
        page.view.backgroundColor = ImpressV3Appearance.page
        let body = UITextView()
        body.translatesAutoresizingMaskIntoConstraints = false
        body.isEditable = false
        body.isSelectable = true
        body.isScrollEnabled = true
        body.font = ImpressV3Appearance.Typography.body
        body.adjustsFontForContentSizeCategory = true
        body.textColor = ImpressV3Appearance.primaryText
        body.backgroundColor = ImpressV3Appearance.surface
        body.text = text
        body.accessibilityIdentifier = "impress.ai.chat.full-prompt-preview"
        page.view.addSubview(body)
        NSLayoutConstraint.activate([
            body.topAnchor.constraint(equalTo: page.view.safeAreaLayoutGuide.topAnchor),
            body.leadingAnchor.constraint(equalTo: page.view.safeAreaLayoutGuide.leadingAnchor),
            body.trailingAnchor.constraint(equalTo: page.view.safeAreaLayoutGuide.trailingAnchor),
            body.bottomAnchor.constraint(equalTo: page.view.safeAreaLayoutGuide.bottomAnchor)
        ])
        page.navigationItem.rightBarButtonItem = UIBarButtonItem(
            primaryAction: UIAction(title: V3L("本次使用")) { [weak self, weak page] _ in
                self?.sessionPromptOverride = text
                self?.enqueuePersistence()
                page?.navigationController?.popViewController(animated: true)
            })
        navigationController?.pushViewController(page, animated: true)
    }

    @objc private func reviewSessionMaterials() {
        guard !sending && !restoring else { return }
        // The overview names the exact stored scope and byte count.
        // Never present a 350-character excerpt as though it is the full source.
        let preview = contextReferences.map {
            $0.stableIdentity + " · " + String($0.excerpt.utf8.count) + " bytes"
        }.joined(separator: "\n")
        let alert = UIAlertController(title: V3L("本次引用材料"),
            message: preview.isEmpty
                ? V3L("暂无引用。选择材料不会自动发送到云端。")
                : preview + (contextConsentGranted ? "\n\n" + V3L("已确认发送范围")
                             : "\n\n" + V3L("尚未确认发送范围")),
            preferredStyle: .actionSheet)
        if !contextReferences.isEmpty {
            alert.addAction(UIAlertAction(title: V3L("完整预览已选材料"),
                style: .default) { [weak self] _ in
                    self?.showFullMaterialPreview()
                })
        }
        if noteIdentity?.documentFormat == .markdown && !isForeignSession {
            alert.addAction(UIAlertAction(title: V3L("选择笔记章节"),
                style: .default) { [weak self] _ in self?.openNoteSectionPicker() })
        }
        alert.addAction(UIAlertAction(title: V3L("移除引用材料"),
            style: .destructive) { [weak self] _ in
            self?.includeCardContext = false
            self?.contextChoiceMade = true
            self?.contextConsentGranted = false
            self?.contextReferences = []
            self?.updateAttachmentPresentation()
            self?.enqueuePersistence()
        })
        alert.addAction(UIAlertAction(title: V3L("下次发送时重新选择"),
            style: .default) { [weak self] _ in
            self?.includeCardContext = false
            self?.contextChoiceMade = false
            self?.contextConsentGranted = false
            self?.contextReferences = []
            self?.enqueuePersistence()
        })
        alert.addAction(UIAlertAction(title: V3L("取消"), style: .cancel))
        alert.popoverPresentationController?.sourceView = materialButton
        present(alert, animated: true)
    }

    private func showFullMaterialPreview() {
        let page = UIViewController()
        page.title = V3L("本次引用材料")
        page.view.backgroundColor = ImpressV3Appearance.page
        let body = UITextView()
        body.translatesAutoresizingMaskIntoConstraints = false
        body.isEditable = false
        body.isSelectable = true
        body.font = ImpressV3Appearance.Typography.body
        body.adjustsFontForContentSizeCategory = true
        body.textColor = ImpressV3Appearance.primaryText
        body.backgroundColor = ImpressV3Appearance.surface
        body.text = contextReferences.enumerated().map { index, reference in
            String(index + 1) + ". " + reference.stableIdentity + "\n" +
            "Version: " + reference.sourceRevision + "\n" +
            String(reference.excerpt.utf8.count) + " bytes\n\n" + reference.excerpt
        }.joined(separator: "\n\n---\n\n")
        body.accessibilityIdentifier = "impress.ai.chat.full-material-preview"
        page.view.addSubview(body)
        NSLayoutConstraint.activate([
            body.topAnchor.constraint(equalTo: page.view.safeAreaLayoutGuide.topAnchor),
            body.leadingAnchor.constraint(equalTo: page.view.safeAreaLayoutGuide.leadingAnchor),
            body.trailingAnchor.constraint(equalTo: page.view.safeAreaLayoutGuide.trailingAnchor),
            body.bottomAnchor.constraint(equalTo: page.view.safeAreaLayoutGuide.bottomAnchor)
        ])
        navigationController?.pushViewController(page, animated: true)
    }

    private func openNoteSectionPicker() {
        guard !sending && !restoring, !isForeignSession,
              let identity = noteIdentity, identity.documentFormat == .markdown else { return }
        ImVaultReadSync.shared.read(identity) { [weak self] result in
            guard let self else { return }
            switch result {
            case let .success(current):
                guard current.identity == identity,
                      current.digest == self.sourceVersionToken else {
                    let alert = UIAlertController(title: V3L("来源笔记已变化"),
                        message: V3L("当前 Chat 的来源版本已过期。请返回笔记，刷新后再进入讨论。"),
                        preferredStyle: .alert)
                    alert.addAction(UIAlertAction(title: V3L("确定"), style: .default))
                    self.present(alert, animated: true)
                    return
                }
                let selector = ImpressChatNoteSectionPicker(
                    sections: ImpressAISectionExtractor.sections(in: current.markdown))
                selector.onApply = { [weak self] items in
                    guard let self, let key = self.sourceIdentity else { return }
                    self.contextReferences = items.map {
                        WCDBV3ChatContextReference(stableIdentity: key,
                            sourceRevision: current.digest, excerpt: $0.text,
                            sourceStartUTF8: $0.startUTF8,
                            sourceEndUTF8: $0.endUTF8,
                            sourceFormat: "markdown")
                    }
                    self.updateAttachmentPresentation()
                    // Drafting a set of materials is not consent to send it.
                    self.includeCardContext = false
                    self.contextChoiceMade = false
                    self.contextConsentGranted = false
                    self.enqueuePersistence()
                    self.navigationController?.popViewController(animated: true)
                }
                self.navigationController?.pushViewController(selector, animated: true)
            case let .failure(error):
                self.showProblem(error)
            }
        }
    }

    /// A deliberate message action, not a model-generated file command.
    /// Pasting/revising selected text happens manually inside the existing
    /// source-preserving draft editor. The formal Vault write gate is unchanged.
    func messageMenu(for turn: WCDBV3ChatMessage) -> UIMenu {
        var actions: [UIMenuElement] = [
            UIAction(title: V3L("复制消息"),
                     image: UIImage(systemName: "doc.on.doc")) { _ in
                UIPasteboard.general.string = turn.text
            }
        ]
        if turn.role == .user {
            actions.append(UIAction(
                title: V3L("编辑并新发问题"),
                image: UIImage(systemName: "pencil")) { [weak self] _ in
                    self?.restoreQuestionAsDraft(from: turn)
                })
        } else if turn.role == .assistant &&
                    (turn.status == .completed || turn.status == .cancelled ||
                     turn.status == .failed) {
            actions.append(UIAction(
                title: V3L("以原问题重新提问"),
                image: UIImage(systemName: "arrow.clockwise")) { [weak self] _ in
                    self?.restoreQuestionAsDraft(from: turn)
                })
        }
        if turn.role == .assistant && turn.status == .completed {
            if sourceCardID != nil || noteDraftTarget != nil {
                actions.append(UIAction(
                    title: V3L("统一预览笔记与原卡修订"),
                    image: UIImage(systemName: "checklist")) { [weak self] _ in
                        self?.openDuplexReview(sourceMessageID: turn.messageID)
                    })
            }
            if sourceCardID != nil {
                actions.append(UIAction(
                    title: V3L("修订关联原卡"),
                    image: UIImage(systemName: "rectangle.and.pencil.and.ellipsis")) {
                        [weak self] _ in self?.openReviewedOriginalCard()
                    })
            }
            if noteDraftTarget != nil {
                actions.append(UIAction(
                    title: V3L("在关联笔记草稿中整理"),
                    image: UIImage(systemName: "square.and.pencil")) { [weak self] _ in
                        self?.openAuthorizedNoteDraft()
                    })
                actions.append(UIAction(
                    title: V3L("生成关联笔记候选卡"),
                    image: UIImage(systemName: "square.stack.3d.up")) { [weak self] _ in
                        self?.openNoteCandidatePool()
                    })
            }
            if pendingDuplex != nil || !previousDuplex.isEmpty {
                actions.append(UIAction(
                    title: V3L("查看修订记录与逐项回执"),
                    image: UIImage(systemName: "doc.text.magnifyingglass")) {
                        [weak self] _ in self?.openDuplexReceipts()
                    })
            }
        }
        return UIMenu(children: actions)
    }

    /// Explicit edit/resend is a new draft. It never mutates history, replays a
    /// provider request, or reuses a previous external-material approval.
    private func restoreQuestionAsDraft(from turn: WCDBV3ChatMessage) {
        guard !sending, !restoring else { return }
        let question: String
        if turn.role == .user {
            question = turn.text
        } else if let index = history.firstIndex(where: { $0.messageID == turn.messageID }),
                  let previous = history[..<index].last(where: { $0.role == .user }) {
            question = previous.text
        } else {
            return
        }
        guard !question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return
        }
        // The ordinary send action must re-run the source/version/consent gates.
        contextConsentGranted = false
        contextChoiceMade = false
        messageInput.text = question
        textViewDidChange(messageInput)
        messageInput.becomeFirstResponder()
    }

    @objc private func openDuplexReceipts() {
        let recorded = (pendingDuplex.map { [$0] } ?? []) + previousDuplex
        guard !recorded.isEmpty else { return }
        let page = ImpressDuplexReceiptHistoryController(records: recorded)
        page.onSelect = { [weak self] record in
            self?.showDuplexReceipt(record)
        }
        page.onRefresh = { [weak self] in
            guard let self else { return [] }
            return (self.pendingDuplex.map { [$0] } ?? []) + self.previousDuplex
        }
        navigationController?.pushViewController(page, animated: true)
    }

    private func showDuplexReceipt(_ receipt: WCDBV3DuplexProposal,
                                   allowUndo: Bool = true) {
        let page = UIViewController()
        page.title = V3L("修订回执详情")
        page.view.backgroundColor = ImpressV3Appearance.page
        let text = UITextView()
        text.translatesAutoresizingMaskIntoConstraints = false
        text.isEditable = false
        text.isSelectable = true
        text.font = ImpressV3Appearance.Typography.body
        text.adjustsFontForContentSizeCategory = true
        text.textColor = ImpressV3Appearance.primaryText
        text.backgroundColor = ImpressV3Appearance.surface
        text.accessibilityIdentifier = "impress.duplex.receipt-detail"
        text.text = V3L("提案 ID：") + receipt.proposalID.uuidString +
            "\n\nVault ID: " + (receipt.noteIdentity?.vaultID ?? "-") +
            "\n" + V3L("笔记：") + (receipt.noteIdentity?.relativePath ??
                V3L("笔记未选择")) +
            "\nSHA-256: " + (receipt.noteBaseDigest ?? "-") +
            "\n" + V3L("状态：") + receipt.state.noteStatus.rawValue +
            "\n" + V3L("笔记回执：") + (receipt.noteReceipt ??
                V3L("尚无回执")) +
            "\n\n" + V3L("原卡：") + (receipt.cardID?.uuidString ??
                V3L("原卡未选择")) +
            "\nRevision: " + String(receipt.cardContentRevision ?? -1) +
            "\n" + V3L("状态：") + receipt.state.cardStatus.rawValue +
            "\n" + V3L("卡片回执：") + (receipt.cardReceipt ??
                V3L("尚无回执")) +
            "\n\n" + V3L("此页为历史回执，不自动重试或改写任何内容。") +
            "\n\n" + V3L("涉及原文的字节级恢复快照仅存于本机受保护目录；普通未加密 ZIP 不包含私人 Markdown。删除应用或迁移设备后可能无法撤销旧文件修改。")
        page.view.addSubview(text)
        NSLayoutConstraint.activate([
            text.topAnchor.constraint(equalTo: page.view.safeAreaLayoutGuide.topAnchor),
            text.bottomAnchor.constraint(equalTo: page.view.safeAreaLayoutGuide.bottomAnchor),
            text.leadingAnchor.constraint(equalTo: page.view.safeAreaLayoutGuide.leadingAnchor),
            text.trailingAnchor.constraint(equalTo: page.view.safeAreaLayoutGuide.trailingAnchor)
        ])
        // Historical receipts are read-only unless their exact completed
        // proposal has a reversible target. Undo is a separate explicit
        // full-diff, CAS-protected operation, never a tap on old message text.
        if allowUndo && (
            [.applied, .undoing].contains(receipt.state.noteStatus) ||
            [.applied, .undoing].contains(receipt.state.cardStatus)) {
            let action = UIAction(title: V3L("安全撤销"),
                                  image: UIImage(systemName: "arrow.uturn.backward")) {
                [weak self] _ in
                guard let self, let repo = self.chatRepository else { return }
                self.showDuplexEditor(repository: repo, cardID: receipt.cardID,
                    contentRevision: nil, messageID: receipt.sourceMessageID,
                    recovering: receipt)
            }
            page.navigationItem.rightBarButtonItem = UIBarButtonItem(primaryAction: action)
        }
        navigationController?.pushViewController(page, animated: true)
    }

    @objc private func openArchivedDuplexReceipts() {
        guard let repository = chatRepository else { return }
        Task { [weak self] in
            guard let self else { return }
            do {
                let sessions = try await repository.retainedChatReceipts()
                let receipts = sessions.flatMap { $0.duplexHistory ?? [] }
                guard !receipts.isEmpty else {
                    let alert = UIAlertController(title: V3L("暂无保留回执"),
                        message: V3L("当前没有已删除会话保留的执行记录。"),
                        preferredStyle: .alert)
                    alert.addAction(UIAlertAction(title: V3L("确定"), style: .default))
                    self.present(alert, animated: true)
                    return
                }
                let page = ImpressDuplexReceiptHistoryController(records: receipts)
                page.onSelect = { [weak self] entry in
                    self?.showDuplexReceipt(entry, allowUndo: false)
                }
                page.onRefresh = { receipts }
                self.navigationController?.pushViewController(page, animated: true)
            } catch { self.showProblem(error) }
        }
    }

    @objc private func resumeDuplexReview() {
        openDuplexReview(sourceMessageID: pendingDuplex?.sourceMessageID)
    }

    private func openDuplexReview(sourceMessageID: UUID?) {
        guard !sending && !restoring && !startingFreshConflictReview,
              sourceIdentity != nil, let repo = chatRepository else { return }
        // A foreign session's immutable entry card/note is NOT the proposal
        // target. Reopen its real source before authoring any new proposal.
        guard !isForeignSession else {
            let alert = UIAlertController(title: V3L("请从原来源继续修订"),
                message: V3L("已恢复历史消息及回执，但不能将另一个卡片或笔记的身份当作当前修订目标。请从该会话真实来源重新进入并核验。"),
                preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: V3L("确定"), style: .default))
            present(alert, animated: true)
            return
        }
        // Never replace an in-flight write with another suggestion. A real
        // CONFLICT differs: the old approved version cannot be retried, but
        // the user must be able to make an independent fresh-version proposal.
        // Archive the full old partial receipt only after separate consent
        // and an atomic local Chat CAS. No target is modified by this action.
        if let p = pendingDuplex, !p.state.completed {
            let hasConflict = p.state.noteStatus == .conflict ||
                p.state.cardStatus == .conflict
            let inFlight = [p.state.noteStatus, p.state.cardStatus].contains {
                $0 == .applying || $0 == .undoing
            }
            if hasConflict && !inFlight {
                let alert = UIAlertController(title: V3L("目标版本存在冲突"),
                    message: V3L("旧提案的成功、失败和冲突回执均会保留。重新核查将归档旧提案，再读取当前原卡/原笔记创建一份全新人工审批；绝不会自动重试旧批准。"),
                    preferredStyle: .alert)
                alert.addAction(UIAlertAction(title: V3L("取消"), style: .cancel))
                alert.addAction(UIAlertAction(title: V3L("查看旧提案"), style: .default) {
                    [weak self] _ in
                    self?.showDuplexEditor(repository: repo, cardID: p.cardID,
                        contentRevision: nil, messageID: p.sourceMessageID,
                        recovering: p)
                })
                alert.addAction(UIAlertAction(title: V3L("重新核查最新版本"),
                    style: .default) { [weak self] _ in
                    guard let self, !self.startingFreshConflictReview else { return }
                    self.startingFreshConflictReview = true
                    Task { [weak self] in
                        guard let self else { return }
                        defer { self.startingFreshConflictReview = false }
                        await self.saveChain?.value
                        guard !self.sending && !self.restoring,
                              let current = self.pendingDuplex,
                              current.proposalID == p.proposalID,
                              (current.state.noteStatus == .conflict ||
                               current.state.cardStatus == .conflict),
                              ![current.state.noteStatus, current.state.cardStatus]
                                  .contains(where: { $0 == .applying || $0 == .undoing })
                        else { return }
                        if let identity = current.noteIdentity,
                           ImVaultReadOnlyProbe.shared.authorizedVaultID != identity.vaultID {
                            self.showProblem(ImVaultSyncFailure.wrongVault)
                            return
                        }
                        let previous = self.previousDuplex
                        self.previousDuplex.append(current)
                        self.pendingDuplex = nil
                        guard await self.persistLocal() else {
                            self.pendingDuplex = current
                            self.previousDuplex = previous
                            return
                        }
                        self.showDuplexEditor(repository: repo, cardID: current.cardID,
                            contentRevision: nil, messageID: current.sourceMessageID,
                            recovering: nil)
                    }
                })
                present(alert, animated: true)
            } else {
                showDuplexEditor(repository: repo, cardID: p.cardID,
                    contentRevision: nil, messageID: p.sourceMessageID,
                    recovering: p)
            }
            return
        }
        if sourceCardID == nil, let identity = noteDraftTarget {
            // Reverse direction: a note may have several original cards. User
            // chooses by stable cardID instead of guessing from the title.
            Task { [weak self] in
                guard let self else { return }
                do {
                    let cards = try await repo.listRelatedCards(for: identity, limit: 20)
                    let picker = UIAlertController(title: V3L("选择关联原卡"),
                        message: V3L("可仅修改笔记，或选择一张已关联的原卡共同预览。"),
                        preferredStyle: .actionSheet)
                    picker.addAction(UIAlertAction(title: V3L("仅修改笔记"),
                        style: .default) { [weak self] _ in
                        self?.showDuplexEditor(repository: repo, cardID: nil,
                            contentRevision: nil, messageID: sourceMessageID, recovering: nil)
                    })
                    for card in cards {
                        picker.addAction(UIAlertAction(
                            title: String(card.question.prefix(48)),
                            style: .default) { [weak self] _ in
                            self?.showDuplexEditor(repository: repo, cardID: card.cardID,
                                contentRevision: nil, messageID: sourceMessageID, recovering: nil)
                        })
                    }
                    picker.addAction(UIAlertAction(title: V3L("取消"), style: .cancel))
                    picker.popoverPresentationController?.sourceView = self.view
                    picker.popoverPresentationController?.sourceRect = CGRect(
                        x: self.view.bounds.midX, y: self.view.bounds.midY,
                        width: 1, height: 1)
                    self.present(picker, animated: true)
                } catch { self.showProblem(error) }
            }
            return
        }
        showDuplexEditor(repository: repo, cardID: sourceCardID,
            contentRevision: sourceContentRevision, messageID: sourceMessageID,
            recovering: nil)
    }

    private func showDuplexEditor(repository: ReviewWCDBRepository, cardID: UUID?,
                                  contentRevision: Int?, messageID: UUID?,
                                  recovering: WCDBV3DuplexProposal?) {
        // A suggestion may originate only from the exact completed
        // assistant turn the user selected. An unrelated historic message
        // is never allowed to become an executable patch.
        let candidate = messageID.flatMap { target in
            history.first(where: {
                $0.messageID == target && $0.role == .assistant &&
                $0.status == .completed
            })?.text
        }
        let editor = ImpressDuplexChangeController(
            repository: repository, cardID: cardID,
            sourceContentRevision: contentRevision,
            noteIdentity: recovering?.noteIdentity ?? noteDraftTarget,
            sourceMessageID: messageID, pending: recovering,
            suggestedText: candidate) { [weak self] changed in
                guard let self else { return false }
                await self.saveChain?.value
                if let index = self.previousDuplex.firstIndex(where: {
                    $0.proposalID == changed.proposalID
                }) {
                    // Undo an archived proposal IN PLACE; do not replace the
                    // newer active proposal or erase unrelated receipts.
                    let oldArchived = self.previousDuplex[index]
                    self.previousDuplex[index] = changed
                    let success = await self.persistLocal()
                    if !success { self.previousDuplex[index] = oldArchived }
                    return success
                }
                let original = self.pendingDuplex
                let archived = self.previousDuplex
                if let original, original.proposalID != changed.proposalID {
                    // Do not silently discard old receipts. If the WCDB
                    // record reaches its protective size cap, fail closed and
                    // keep the prior durable proposal instead.
                    guard original.state.completed else { return false }
                    self.previousDuplex.insert(original, at: 0)
                }
                self.pendingDuplex = changed
                let ok = await self.persistLocal()
                if !ok {
                    self.pendingDuplex = original
                    self.previousDuplex = archived
                }
                if ok { self.refreshModelPicker() }
                return ok
            }
        navigationController?.pushViewController(editor, animated: true)
    }

    /// These actions reuse the existing authoritative editor and WCDB CAS.
    /// AI message text is advice, never executable instructions or an implicit
    /// replacement answer. The user manually reviews and saves the ORIGINAL ID.
    private func openReviewedOriginalCard() {
        guard !sending && !restoring, let cardID = sourceCardID,
              let expected = sourceContentRevision else { return }
        Task { [weak self] in
            guard let self else { return }
            do {
                let repo = try self.chatRepository ?? self.injectedRepository ??
                    ImpressV3ReviewEnvironment.repository()
                guard let card = try await repo.content(for: cardID) else {
                    throw ReviewWCDBError.missingCard
                }
                guard card.contentRevision == expected else {
                    throw ChatFlowError.sourceChanged
                }
                guard let queueItem = try await repo.fetchQueueCandidates().first(where: {
                    $0.cardID == cardID
                }) else { throw ReviewWCDBError.missingCard }
                let correct = Set((card.correctIndices ?? "").split(separator: ",")
                    .compactMap { Int($0) })
                let choices: [ImpressV3CardDraft.Choice] =
                    (card.choices ?? "").isEmpty
                    ? [.init(), .init()]
                    : (card.choices ?? "").components(separatedBy: "\n")
                        .enumerated().map { index, text in
                            .init(text: text, isCorrect: correct.contains(index))
                        }
                let draft = ImpressV3CardDraft(
                    kind: CardType(rawValue: card.cardType) ?? .standard,
                    question: card.question, answer: card.answerText ?? "",
                    choices: choices, allowsMultipleCorrect: correct.count > 1,
                    imageData: card.imageData, sourceNotePath: card.sourceNotePath)
                let editor = ImpressV3CardComposerViewController(
                    draft: draft, editingCardID: cardID)
                editor.onSave = { [weak self] updated in
                    try await repo.updateManagedCard(updated,
                        expectedRevision: queueItem.revision,
                        expectedContentRevision: card.contentRevision,
                        origin: .approvedAI)
                    self?.privacyLabel.text = V3L(
                        "原卡已按确认内容保存；继续讨论前请重新打开以读取新版本。")
                    // The Chat source version is immutable for this controller:
                    // a subsequent Send fails closed rather than reusing stale context.
                }
                let nav = ImNavigationViewController(rootViewController: editor)
                nav.modalPresentationStyle = .pageSheet
                nav.sheetPresentationController?.detents = [.large()]
                self.present(nav, animated: true)
            } catch { self.showProblem(error) }
        }
    }

    /// Reuse the existing confirmed question-pool flow; no implicit model call,
    /// no new duplicate-card path, and no automatic upload of the linked note.
    private func openNoteCandidatePool() {
        guard !sending && !restoring, let identity = noteDraftTarget else { return }
        guard ImVaultReadOnlyProbe.shared.authorizedVaultID == identity.vaultID else {
            showProblem(ImVaultSyncFailure.wrongVault)
            return
        }
        ImVaultReadSync.shared.read(identity) { [weak self] result in
            guard let self,
                  ImVaultReadOnlyProbe.shared.authorizedVaultID == identity.vaultID
            else { return }
            switch result {
            case .success(let document):
                guard document.identity == identity else {
                    self.showProblem(ImVaultSyncFailure.wrongVault)
                    return
                }
                self.navigationController?.pushViewController(
                    ImpressAIQuestionGenerationViewController(document: document),
                    animated: true)
            case .failure(let error): self.showProblem(error)
            }
        }
    }

    private func openAuthorizedNoteDraft() {
        guard !sending && !restoring, let identity = noteDraftTarget else { return }
        guard ImVaultReadOnlyProbe.shared.authorizedVaultID == identity.vaultID else {
            showProblem(ImVaultSyncFailure.wrongVault)
            return
        }
        ImVaultReadSync.shared.read(identity) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let live):
                do {
                    try ImVaultDraftEntry.open(live: live, presenter: self)
                } catch { self.showProblem(error) }
            case .failure(let error):
                self.showProblem(error)
            }
        }
    }

    private enum ChatFlowError: LocalizedError {
        case localSaveFailed, sourceChanged
        var errorDescription: String? {
            switch self {
            case .localSaveFailed:
                return V3L("本地聊天保存失败，未向模型发送。")
            case .sourceChanged:
                return V3L("卡片内容已更新。请返回卡片后重新进入讨论，避免使用过期答案。")
            }
        }
    }

    private func presentSendConsent(_ sheet: UIAlertController) {
        guard !sendConsentPending else { return }
        sendConsentPending = true
        sendButton.isEnabled = false
        present(sheet, animated: true)
    }

    private func resolveSendConsent() {
        sendConsentPending = false
        textViewDidChange(messageInput)
    }

    @objc private func submitOrStopMessage() {
        if sending {
            // Cancels the in-flight Task/URLSession request; never executes a
            // partial response or silently retries against a billed model.
            requestTask?.cancel()
            return
        }
        submitMessage()
    }

    @objc private func submitMessage() {
        let text = messageInput.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard ImpressChatEphemeralFileConsent.mayBeginSend(
                  input: text,
                  hasTextAttachment: localAttachments.textPayloadsForExplicitSend() != nil,
                  hasImageAttachment: localAttachments.imagePayloadsForExplicitSend() != nil),
              !sending, !restoring, !sendConsentPending else { return }
        let omitted = ImpressChatWindowPolicy.omittedCompletedCount(in: history)
        if omitted > 0 && !acknowledgedBoundedContext {
            let alert = UIAlertController(title: V3L("确认有限对话上下文"),
                message: V3L("本次仅向云端模型发送最近 16 条已完成对话及当前输入；更早的消息仍完整保存在本机，不代表模型已经读过。") +
                    "\n" + V3L("本次未传送的早期消息条数：") + String(omitted),
                preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: V3L("取消"), style: .cancel) {
                [weak self] _ in self?.resolveSendConsent()
            })
            alert.addAction(UIAlertAction(title: V3L("确认此会话的发送范围"),
                style: .default) { [weak self] _ in
                guard let self else { return }
                self.resolveSendConsent()
                self.acknowledgedBoundedContext = true
                self.submitMessage()
            })
            presentSendConsent(alert)
            return
        }
        #if DEBUG
        if ImpressV11UITestFixture.enabled &&
           (noteIdentity?.vaultID == ImpressV11UITestFixture.vaultID ||
            sourceCardID != nil) {
            // This route never reaches URLSession. It exists only for the
            // disposable fixture and retains ordinary material consent.
            let syntheticID = UUID(uuidString: "00000000-0000-4000-8000-000000000005")!
            let connection = ImpressAIConnection(id: syntheticID,
                title: "Impress E2E Synthetic (offline)", provider: .custom,
                apiProtocol: .chatCompletions,
                baseURL: URL(string: "https://impress.invalid")!,
                credentialID: nil, enabled: true,
                authentication: .noAuthentication)
            let model = ImpressAIModel(id: syntheticID, connectionID: syntheticID,
                identifier: "impress-local-fixture", jsonVerified: true)
            chooseSourceContext(text,
                route: ImpressAIResolvedRoute(connection: connection, model: model))
            return
        }
        #endif
        let route: ImpressAIResolvedRoute
        do { route = try liveRoute() }
        catch {
            let explanation: String
            switch error as? ImpressAIContractError {
            case .missingCredential:
                explanation = V3L("所选对话模型尚未保存 API Key，请打开该连接填写密钥。")
            case .disabled:
                explanation = V3L("所选模型或连接已停用，请重新选择有效模型。")
            case .freeModelQAOnly:
                explanation = V3L("当前连接属于 OpenCode 免费 QA，请选择此连接允许的模型。")
            default:
                explanation = V3L("请先在「设置 → AI 服务 → 业务默认模型」选择可用的对话模型。")
            }
            let alert = UIAlertController(title: V3L("无法使用当前对话模型"),
                message: explanation, preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: V3L("取消"), style: .cancel) {
                [weak self] _ in self?.resolveSendConsent()
            })
            alert.addAction(UIAlertAction(title: V3L("打开 AI 服务"),
                style: .default) { [weak self] _ in
                    guard let self else { return }
                    self.resolveSendConsent()
                    self.navigationController?.pushViewController(
                        ImpressAISettingsViewController(), animated: true)
                })
            presentSendConsent(alert)
            return
        }

        if ImpressChatProviderConsentGate.needsReapproval(
            history: history, destination: route.connection.id) {
            let warning = UIAlertController(
                title: V3L("切换 AI 服务商"),
                message: V3L("此次请求会把近期对话材料发送给新服务商，是否同意？"),
                preferredStyle: .alert)
            warning.addAction(UIAlertAction(title: V3L("取消"), style: .cancel) {
                [weak self] _ in self?.resolveSendConsent()
            })
            warning.addAction(UIAlertAction(title: V3L("同意并发送"),
                                            style: .default) { [weak self] _ in
                guard let self else { return }
                self.resolveSendConsent()
                self.chooseSourceContext(text, route: route)
            })
            presentSendConsent(warning)
            return
        }
        chooseSourceContext(text, route: route)
    }

    private func chooseSourceContext(_ text: String,
                                     route: ImpressAIResolvedRoute) {
        if !contextChoiceMade, !isForeignSession,
           let question = sourceQuestion, !question.isEmpty {
            let confirm = UIAlertController(title: noteIdentity == nil
                ? V3L("是否附带当前卡片？") : V3L("是否附带当前笔记材料？"),
                message: noteIdentity == nil
                    ? V3L("只有确认后，才会发送当前卡片的问题与答案。")
                    : V3L("只有确认后，才会发送本次明确载入的笔记材料。过长笔记不会自动发送全文。"),
                preferredStyle: .alert)
            confirm.addAction(UIAlertAction(title: V3L("取消"), style: .cancel) {
                [weak self] _ in self?.resolveSendConsent()
            })
            confirm.addAction(UIAlertAction(title: V3L("仅发送输入内容"),
                                            style: .default) { [weak self] _ in
                guard let self else { return }
                self.resolveSendConsent()
                self.contextChoiceMade = true
                self.contextConsentGranted = false
                self.includeCardContext = false
                self.contextReferences = []
                self.performSend(text, route: route)
            })
            confirm.addAction(UIAlertAction(title: noteIdentity == nil
                ? V3L("附带当前卡片") : V3L("附带本次笔记材料"),
                                            style: .default) { [weak self] _ in
                guard let self else { return }
                self.resolveSendConsent()
                if let key = self.sourceIdentity {
                    if self.noteIdentity != nil && self.sourceAnswer == nil &&
                       self.contextReferences.isEmpty {
                        self.openNoteSectionPicker()
                        return // Keep draft; choose sections without sending.
                    }
                    if !self.contextReferences.allSatisfy({
                        $0.stableIdentity == key &&
                        $0.sourceRevision == self.currentSourceVersion
                    }) {
                        self.contextReferences = []
                        self.contextConsentGranted = false
                        self.openNoteSectionPicker()
                        return
                    }
                    if self.contextReferences.isEmpty {
                        let excerpt = self.noteIdentity == nil
                            ? question + "\n" + (self.sourceAnswer ?? "")
                            : (self.sourceAnswer ?? "")
                        self.contextReferences = [WCDBV3ChatContextReference(
                            stableIdentity: key,
                            sourceRevision: self.currentSourceVersion, excerpt: excerpt)]
                    }
                }
                self.contextChoiceMade = true
                self.contextConsentGranted = true
                self.includeCardContext = true
                self.performSend(text, route: route)
            })
            presentSendConsent(confirm)
        } else {
            performSend(text, route: route)
        }
    }

    private func performSend(_ message: String, route: ImpressAIResolvedRoute) {
        guard !sending, !restoring, !sendConsentPending else { return }
        // A provider/source/attachment consent sheet can outlive the typed draft.
        // Do not send an outdated question under that sheet's authorization.
        guard messageInput.text.trimmingCharacters(in: .whitespacesAndNewlines) == message else {
            approvedImagesForSend = nil
            approvedTextForSend = nil
            acknowledgedTextOnlyPreviews = false
            showTransientStatus(V3L("输入已改变；请重新发送并确认附件。"))
            return
        }
        if !localAttachments.items.isEmpty && !acknowledgedTextOnlyPreviews &&
           approvedImagesForSend == nil && approvedTextForSend == nil {
            let available = localAttachments.imagePayloadsForExplicitSend()
            let textFiles = localAttachments.textPayloadsForExplicitSend()
            let canSendImages = route.model.supportsImageInput == true &&
                !ImpressAIOpenCodeFreeQA.isQAProfile(route.connection) &&
                available != nil
            let canSendText = textFiles != nil
            let textDetails = (textFiles ?? []).map {
                $0.displayName + " (" + String($0.rawUTF8Bytes) + " bytes)"
            }.joined(separator: "\n")
            let messageDetails = canSendText
                ? V3L("仅本次将以下文本文件内容传给：") + "\n" +
                  route.connection.title + " · " + route.model.identifier +
                  "\n" + textDetails +
                  "\n" + V3L("批准后仅作为本条用户消息引用，不保存原始文件到聊天记录。")
                : (canSendImages
                    ? V3L("将向以下服务商和模型发送所选图片：") + "\n" +
                      route.connection.title + " · " + route.model.identifier +
                      "\n" + V3L("图片只在本次请求发送，不加入以后自动上传的上下文。")
                    : V3L("当前选择包含混合类型、未知文件或不支持的模型能力。请移除不支持材料分别发送；不会悄悄遗漏选中的附件。"))
            let alert = UIAlertController(
                title: V3L("确认本次附件发送范围"),
                message: messageDetails, preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: V3L("取消"), style: .cancel) {
                [weak self] _ in
                guard let self else { return }
                self.resolveSendConsent()
                self.approvedTextForSend = nil
                self.localAttachments.discardSelectedText()
            })
            if !message.isEmpty {
                alert.addAction(UIAlertAction(title: V3L("仅发送文字"),
                    style: .default) { [weak self] _ in
                        guard let self else { return }
                        self.resolveSendConsent()
                        self.localAttachments.discardSelectedText()
                        self.acknowledgedTextOnlyPreviews = true
                        self.performSend(message, route: route)
                    })
            }
            if canSendText, let textFiles {
                alert.addAction(UIAlertAction(
                    title: V3L("批准发送") + " " + String(textFiles.count) +
                        V3L(" 份文本文件"),
                    style: .default) { [weak self] _ in
                    guard let self else { return }
                    self.resolveSendConsent()
                    do {
                        guard let destination = self.attachmentDestination(route) else {
                            throw ImpressChatEphemeralFileConsent.Rejection.changedDestination
                        }
                        self.approvedTextForSend = try
                            ImpressChatEphemeralFileConsent.Snapshot.freeze(
                                destination: destination,
                                input: message,
                                previewIDs: self.localAttachments.items.map(\.id),
                                prepared: textFiles)
                        self.performSend(message, route: route)
                    } catch {
                        self.approvedTextForSend = nil
                        self.localAttachments.discardSelectedText()
                        self.showTransientStatus(V3L("所选文件授权无效，请重新选择。"))
                    }
                })
            }
            if canSendImages, let available {
                alert.addAction(UIAlertAction(
                    title: V3L("批准发送") + " " + String(available.count) +
                        V3L(" 张图片"),
                    style: .default) { [weak self] _ in
                    guard let self else { return }
                    self.resolveSendConsent()
                    do {
                        guard let destination = self.attachmentDestination(route) else {
                            throw ImpressChatEphemeralFileConsent.Rejection.changedDestination
                        }
                        self.approvedImagesForSend = try
                            ImpressChatEphemeralFileConsent.ImageSnapshot.freeze(
                                destination: destination, input: message,
                                previewIDs: self.localAttachments.items.map(\.id),
                                images: available)
                        self.performSend(message, route: route)
                    } catch {
                        self.approvedImagesForSend = nil
                        self.localAttachments.clear()
                        self.showTransientStatus(V3L("所选图片授权无效，请重新选择。"))
                    }
                })
            }
            presentSendConsent(alert)
            return
        }
        let frozenImageConsent = approvedImagesForSend
        let authorizedImages: [ImpressAIImagePayload]
        // Never send images to a destination that changed behind the consent.
        if let proof = frozenImageConsent {
            guard route.model.supportsImageInput == true,
                  !ImpressAIOpenCodeFreeQA.isQAProfile(route.connection),
                  let activeRoute = liveAttachmentRoute(for: route),
                  let expected = attachmentDestination(route),
                  let actual = attachmentDestination(activeRoute),
                  expected == actual,
                  let current = localAttachments.imagePayloadsForExplicitSend(),
                  let approved = try? proof.approvedPayloads(
                      destination: actual, input: message, previewIDs: localAttachments.items.map(\.id),
                      images: current) else {
                approvedImagesForSend = nil
                localAttachments.clear()
                showTransientStatus(V3L("附件、会话或模型已改变；图片授权失效，请重新选择。"))
                return
            }
            authorizedImages = approved
        } else {
            authorizedImages = []
        }
        var approvedRemoteUserText = message
        let sentTextFiles = approvedTextForSend != nil
        // Capture the exact approved proof for the async pre-wire recheck.
        // Not persisted to WCDB or exposed to provider as a system instruction.
        let frozenTextConsent = approvedTextForSend
        let approvedFileNames = approvedTextForSend?.prepared.map(\.displayName) ?? []
        if let consent = approvedTextForSend {
            // Verify the live route, including credential and selected session.
            guard let currentRoute = liveAttachmentRoute(for: route),
                  let expectedDestination = attachmentDestination(route),
                  let liveDestination = attachmentDestination(currentRoute),
                  expectedDestination == liveDestination,
                  let prepared = localAttachments.textPayloadsForExplicitSend(),
                  let outgoing = try? consent.approvedUserTurn(
                    destination: liveDestination, input: message,
                    previewIDs: localAttachments.items.map(\.id),
                    prepared: prepared) else {
                approvedTextForSend = nil
                localAttachments.discardSelectedText()
                showTransientStatus(V3L("附件、会话或模型已改变；文本授权失效，请重新选择。"))
                return
            }
            approvedRemoteUserText = outgoing
        }
        let frozenApprovedUserTurn = approvedRemoteUserText
        approvedTextForSend = nil
        approvedImagesForSend = nil
        acknowledgedTextOnlyPreviews = false
        draftDebounce?.cancel()
        sending = true
        // Freeze the exact approved material selection for this Send. A later
        // draft/save callback may not change the material sent by this turn.
        let authorizedReferences = contextReferences
        let authorizedSourceIdentity = sourceIdentity
        let includeApprovedContext = includeCardContext
        let prompt = sessionPromptOverride ?? ImpressAIChatPromptSelection.systemText()
        let providerID = route.connection.id
        let modelName = route.model.identifier
        var system = prompt
        if includeApprovedContext, !isForeignSession,
           let question = sourceQuestion, !question.isEmpty {
            if noteIdentity != nil {
                if noteIdentity?.documentFormat == .jsonCanvas {
                    system += "\n" + V3L("这仅是 JSON Canvas 的显式节点与连线文本，没有发送图像像素，不能声称完成视觉理解。")
                }
                system += "\n" + V3L("当前笔记来源：") + question
                for reference in authorizedReferences {
                    system += "\n" + V3L("本次明确批准的章节或摘录：") + reference.excerpt
                }
            } else {
                system += "\n" + V3L("当前卡片的问题：") + question
                if let answer = sourceAnswer, !answer.isEmpty {
                    system += "\n" + V3L("当前卡片的参考答案：") + answer
                }
            }
        }
        let messageID = UUID()
        // WCDB stores a receipt/name marker, never original picked file bytes.
        let visibleMessage: String
        if message.isEmpty && !authorizedImages.isEmpty {
            // Satisfy WCDB's nonempty completed-message contract without
            // inventing user text or retaining any original image bytes.
            visibleMessage = ImpressChatEphemeralFileConsent.imageOnlyHistoryReceipt
        } else {
            visibleMessage = approvedFileNames.isEmpty ? message :
                message + (message.isEmpty ? "" : "\n") +
                "[本次已批准文本附件：" + approvedFileNames.joined(separator: "、") + "]"
        }
        history.append(WCDBV3ChatMessage(
            messageID: messageID, role: .user, text: visibleMessage,
            status: .pending, providerID: providerID,
            modelIdentifier: modelName, promptSnapshot: prompt,
            approvedImages: authorizedImages.isEmpty ? nil :
                authorizedImages.map {
                    WCDBV3ChatImageApproval(
                        name: String($0.displayName
                            .replacingOccurrences(of: "\n", with: " ")
                            .replacingOccurrences(of: "\r", with: " ")
                            .prefix(24)),
                        jpegBytes: $0.jpeg.count)
                }))
        messageInput.text = ""
        privacyLabel.text = V3L("正在请求模型…")
        sendButton.isEnabled = true
        sendButton.configuration?.image = UIImage(systemName: "stop.fill")
        sendButton.accessibilityLabel = V3L("停止生成")
        transcript.followNewestMessage()
        reloadAndScroll()

        let priorSave = saveChain
        requestTask = Task {
            await priorSave?.value
            // Shared by success and failure paths; partial responses survive errors.
            var assistantID: UUID?
            do {
                try Task.checkCancellation()
                // Re-check the authorized Vault and content SHA immediately
                // before any note context is sent to a remote provider.
                if includeApprovedContext, let noteID = self.noteIdentity {
                    let current: ImVaultRawDocument = try await withCheckedThrowingContinuation {
                        (continuation: CheckedContinuation<ImVaultRawDocument, Error>) in
                        ImVaultReadSync.shared.read(noteID) { result in
                            continuation.resume(with: result)
                        }
                    }
                    guard ImVaultReadOnlyProbe.shared.authorizedVaultID ==
                          noteID.vaultID else {
                        throw ImVaultSyncFailure.wrongVault
                    }
                    try ImpressChatNoteUploadGate.validate(
                        document: current, expectedIdentity: noteID,
                        expectedDigest: self.sourceVersionToken,
                        conversationKey: authorizedSourceIdentity,
                        excerpts: authorizedReferences)
                }
                // The current card can change while this controller is open.
                // Never transmit or grade using a stale identity/revision.
                if !isForeignSession, let id = sourceCardID,
                   let revision = sourceContentRevision {
                    let store = try chatRepository ?? injectedRepository ??
                        ImpressV3ReviewEnvironment.repository()
                    guard let card = try await store.content(for: id),
                          card.contentRevision == revision else {
                        throw ChatFlowError.sourceChanged
                    }
                }
                guard await persistLocal() else { throw ChatFlowError.localSaveFailed }
                // persistLocal may suspend. Revalidate the *whole* one-shot
                // approval just before the request is constructed: destination
                // AND session, current ordered previews and their exact bytes.
                // Checking only routeFingerprint would miss a session switch or
                // a file being replaced after the user pressed Approve.
                if sentTextFiles || frozenImageConsent != nil {
                    guard let currentRoute = liveAttachmentRoute(for: route),
                          let expected = attachmentDestination(route),
                          let actual = attachmentDestination(currentRoute),
                          expected == actual else {
                        throw ImpressChatEphemeralFileConsent.Rejection.changedDestination
                    }
                    if sentTextFiles {
                        guard let proof = frozenTextConsent,
                              let selected = localAttachments.textPayloadsForExplicitSend(),
                              let revalidated = try? proof.approvedUserTurn(
                                  destination: actual, input: message,
                                  previewIDs: localAttachments.items.map(\.id),
                                  prepared: selected),
                              revalidated == frozenApprovedUserTurn else {
                            throw ImpressChatEphemeralFileConsent.Rejection.changedSelection
                        }
                    }
                    if let imageProof = frozenImageConsent {
                        guard let selected = localAttachments.imagePayloadsForExplicitSend(),
                              let refreshed = try? imageProof.approvedPayloads(
                                  destination: actual, input: message,
                                  previewIDs: localAttachments.items.map(\.id),
                                  images: selected),
                              refreshed.count == authorizedImages.count,
                              zip(refreshed, authorizedImages).allSatisfy({
                                  $0.0.jpeg == $0.1.jpeg &&
                                      $0.0.displayName == $0.1.displayName
                              }) else {
                            throw ImpressChatEphemeralFileConsent.Rejection.changedSelection
                        }
                    }
                }
                // The user may tap Stop while persistLocal() is suspended.
                // Do not begin an outbound request after that cancellation,
                // even if the immutable file approval still matches.
                try Task.checkCancellation()
                let earlier = history.filter {
                    $0.messageID != messageID && $0.status == .completed
                }.suffix(ImpressChatWindowPolicy.maximumPreviousTurns)
                let safeWindow = earlier.drop(while: { $0.role != .user })
                var turns = safeWindow.map { saved in
                    ImpressAIChatTurn(
                        role: saved.role == .user ? .user : .assistant,
                        text: saved.text)
                }
                turns.append(ImpressAIChatTurn(role: .user, text: frozenApprovedUserTurn))
                // Production sends consume the same provider-normalized SSE events
                // already validated by the offline Chat POC. A terminal event alone
                // may mark a reply completed; partial EOF and cancellation may not.
                var terminalReceived = false
                var lastCheckpoint = Date.distantPast
                @MainActor func appendChunk(_ text: String) {
                    guard !text.isEmpty else { return }
                    if let id = assistantID,
                       let index = history.firstIndex(where: { $0.messageID == id }) {
                        history[index].text += text
                    } else {
                        let id = UUID()
                        assistantID = id
                        history.append(WCDBV3ChatMessage(
                            messageID: id, role: .assistant, text: text, status: .pending,
                            providerID: providerID, modelIdentifier: modelName,
                            promptSnapshot: prompt))
                    }
                    // WCDB saves are separately serialized from the 30Hz renderer.
                    // Persist an early partial reply, then bounded checkpoints.
                    if Date().timeIntervalSince(lastCheckpoint) >= 2 {
                        enqueuePersistence()
                        lastCheckpoint = Date()
                    }
                    reloadAndScroll()
                }
                #if DEBUG
                if ImpressV11UITestFixture.enabled &&
                   (self.noteIdentity?.vaultID == ImpressV11UITestFixture.vaultID ||
                    self.sourceCardID != nil) {
                    // The real production controller, not a disconnected POC,
                    // streams a deterministic offline fixture through its UI.
                    // All existing consent, SHA and local-save gates ran above.
                    let offlineReply = "合成模型回复：依据已核准的来源，先确定前提，再提出可检验的机制，最后检查反例。原笔记与原卡必须分别审阅修改后才可批准。"
                    let characters = Array(offlineReply)
                    for offset in stride(from: 0, to: characters.count, by: 18) {
                        try Task.checkCancellation()
                        appendChunk(String(characters[offset..<min(offset + 18, characters.count)]))
                        try await Task.sleep(for: .milliseconds(65))
                    }
                    terminalReceived = true
                } else {
                    let events = try await ImpressAIHTTPClient.shared.converseStream(
                        route: route, system: system, turns: turns,
                        images: authorizedImages)
                    for try await event in events {
                        try Task.checkCancellation()
                        switch event {
                        case .delta(let text): appendChunk(text)
                        case .completed: terminalReceived = true
                        case .failed: throw ImpressAIServiceError.response
                        }
                    }
                }
                #else
                let events = try await ImpressAIHTTPClient.shared.converseStream(
                    route: route, system: system, turns: turns,
                        images: authorizedImages)
                for try await event in events {
                    try Task.checkCancellation()
                    switch event {
                    case .delta(let text): appendChunk(text)
                    case .completed: terminalReceived = true
                    case .failed: throw ImpressAIServiceError.response
                    }
                }
                #endif
                try Task.checkCancellation()
                guard terminalReceived, let id = assistantID,
                      let assistantIndex = history.firstIndex(where: { $0.messageID == id }),
                      !history[assistantIndex].text.isEmpty else {
                    throw ImpressAIServiceError.response
                }
                if let userIndex = history.firstIndex(where: { $0.messageID == messageID }) {
                    history[userIndex].status = .completed
                }
                history[assistantIndex].status = .completed
                activeProviderID = providerID
                requestFailure = nil
                privacyLabel.text = authorizedImages.isEmpty
                    ? V3L("对话已保存至本机；更新内容仍需预览确认。")
                    : V3L("已批准图片随本次请求提交。模型的实际视觉能力以服务商为准。")
                // The temporary image bytes are not retained in chat history.
                if !authorizedImages.isEmpty || sentTextFiles { localAttachments.clear() }
            } catch {
                let cancelled = Task.isCancelled || error is CancellationError
                if let index = history.firstIndex(where: { $0.messageID == messageID }) {
                    history[index].status = cancelled ? .cancelled : .failed
                }
                if let id = assistantID,
                   let index = history.firstIndex(where: { $0.messageID == id }) {
                    // Retain every already displayed token; incomplete output is
                    // never eligible for knowledge approval or auto replay.
                    history[index].status = cancelled ? .cancelled : .failed
                }
                requestFailure = cancelled ? V3L("生成已停止") : error.localizedDescription
                if messageInput.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    messageInput.text = message
                }
                privacyLabel.text = cancelled
                    ? V3L("已停止生成；原始输入和历史仍保留在本机。")
                    : V3L("请求失败，输入内容已保留。")
                if sentTextFiles { localAttachments.discardSelectedText() }
                if !cancelled { showProblem(error) }
            }
            enqueuePersistence()
            await saveChain?.value
            sending = false
            requestTask = nil
            textViewDidChange(messageInput)
            reloadAndScroll()
        }
    }

    private func restoreLocalSession() async {
        guard let identity = sourceIdentity else {
            textViewDidChange(messageInput)
            return
        }
        restoring = true
        defer {
            restoring = false
            textViewDidChange(messageInput)
        }
        do {
            let repo = try injectedRepository ?? ImpressV3ReviewEnvironment.repository()
            chatRepository = repo
            if !pendingInitialMaterials.isEmpty {
                // Explicit new Canvas selection creates its own session.
                // Never overwrite a previous source's materials or draft.
                guard pendingInitialMaterials.allSatisfy({
                    $0.stableIdentity == identity &&
                    $0.sourceRevision == currentSourceVersion
                }) else { throw WCDBV3ChatStorageError.invalidRecord }
                var fresh = WCDBV3ChatSession(sourceIdentity: identity)
                fresh.sourceDisplayName = entrySourceDisplayName
                fresh.contextReferences = pendingInitialMaterials
                try await repo.saveChatSession(fresh, expectedRevision: nil)
                pendingInitialMaterials = []
                activateSession(fresh)
            } else {
                let sessions = try await repo.chatSessions(for: identity)
                if let latest = sessions.first {
                    activateSession(latest)
                    if history != latest.messages { enqueuePersistence() }
                }
            }
        } catch {
            showTransientStatus(V3L("本地聊天恢复失败。请保留当前页面，不要覆盖历史。"))
        }
    }

    private func activateSession(_ session: WCDBV3ChatSession) {
        if storedSession?.sessionID != session.sessionID {
            // A pending Photos/Files/Camera callback has no visible item yet.
            // Revoke it even when the current preview list is still empty:
            // otherwise the old session's image can arrive in this session.
            localAttachments.clear()
            approvedTextForSend = nil
        }
        transcript.activateConversation(session.sessionID)
        storedSession = session
        acknowledgedBoundedContext = false
        pendingDuplex = session.pendingDuplex
        previousDuplex = session.duplexHistory ?? []
        sessionPromptOverride = session.promptOverride
        history = session.messages
        for i in history.indices where history[i].status == .pending {
            history[i].status = .failed // No auto-replay after interruption.
        }
        messageInput.text = session.inputDraft
        contextReferences = session.contextReferences
        updateAttachmentPresentation()
        requestFailure = session.requestError
        // Restoring a session opened from another card/note never gives
        // this entry card's material to the foreign session by accident.
        contextConsentGranted = !isForeignSession &&
            session.contextConsentGranted == true
        let approved = contextReferences.first(where: { $0.stableIdentity == sourceIdentity })
        let stillCurrent = approved?.sourceRevision == currentSourceVersion
        includeCardContext = contextConsentGranted && approved != nil && stillCurrent
        contextChoiceMade = isForeignSession || includeCardContext
        if isForeignSession {
            privacyLabel.text = V3L("已恢复该来源的消息、模型、提示词和材料记录。进入其他来源的讨论不会自动批准或发送当前卡片的附件。")
        } else if approved != nil && !stillCurrent {
            showTransientStatus(V3L("来源内容有更新；发送前请重新确认引用范围。"))
        }
        activeProviderID = history.reversed().compactMap(\.providerID).first
        selectedModelID = session.selectedChatModelID
        // Older conversations may infer the last used model. Explicitly
        // stored but unavailable models must NOT auto-switch providers.
        if selectedModelID == nil,
           let prior = history.reversed().first(where: {
               $0.providerID != nil && $0.modelIdentifier != nil
           }), let connectionID = prior.providerID, let modelName = prior.modelIdentifier {
            let registry = ImpressAIConfigStore.shared.registry
            selectedModelID = registry.models.first(where: { item in
                item.identifier == modelName && registry.connections.contains(where: {
                    $0.id == connectionID && $0.id == item.connectionID
                })
            })?.id
        }
        refreshModelPicker()
        reloadAndScroll()
    }

    // Flush draft/CAS before changing session IDs. Never overwrite an old row
    // with a newly created empty transcript or a concurrently changed record.
    private func flushBeforeSwitch() async -> Bool {
        draftDebounce?.cancel()
        await saveChain?.value
        if storedSession == nil && history.isEmpty &&
           messageInput.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return true
        }
        return await persistLocal()
    }

    @objc private func openDiscussionHistory() {
        guard !restoring && !sending,
              let repository = chatRepository else { return }
        Task { [weak self] in
            guard let self else { return }
            do {
                let sessions = try await repository.allChatSessions()
                let page = ImpressChatSessionHistoryViewController(
                    sessions: sessions, currentSessionID: self.storedSession?.sessionID,
                    repository: repository)
                page.onSelect = { [weak self] id, matchedMessageID in
                    self?.switchDiscussion(to: id, highlightedMessageID: matchedMessageID)
                }
                page.onDeleted = { [weak self] id in
                    self?.handleDeletedDiscussion(id)
                }
                self.navigationController?.pushViewController(page, animated: true)
            } catch { self.showProblem(error) }
        }
    }

    private func handleDeletedDiscussion(_ id: UUID) {
        transcript.forgetConversation(id)
        guard storedSession?.sessionID == id else { return }
        draftDebounce?.cancel()
        // The DB tombstone rejects any previously queued asynchronous writes.
        storedSession = nil
        provisionalChatSessionID = UUID()
        approvedTextForSend = nil
        localAttachments.clear()
        history = []
        pendingDuplex = nil
        previousDuplex = []
        contextReferences = []
        requestFailure = nil
        sessionPromptOverride = nil
        selectedModelID = nil
        contextConsentGranted = false
        includeCardContext = false
        contextChoiceMade = false
        messageInput.text = ""
        updateAttachmentPresentation()
        reloadAndScroll()
        textViewDidChange(messageInput)
    }

    @objc private func startNewDiscussion() {
        guard !restoring && !sending, let identity = sourceIdentity,
              let repository = chatRepository else { return }
        restoring = true
        Task { [weak self] in
            guard let self else { return }
            defer { self.restoring = false; self.textViewDidChange(self.messageInput) }
            guard await self.flushBeforeSwitch() else {
                self.privacyLabel.text = V3L("当前聊天保存失败；已阻止新建，避免丢失草稿。")
                return
            }
            do {
                var fresh = WCDBV3ChatSession(sourceIdentity: identity)
                fresh.sourceDisplayName = self.entrySourceDisplayName
                try await repository.saveChatSession(fresh, expectedRevision: nil)
                self.activateSession(fresh)
                self.privacyLabel.text = V3L("新讨论已创建。旧会话仍可从历史讨论打开。")
            } catch { self.showProblem(error) }
        }
    }

    private func switchDiscussion(to id: UUID, highlightedMessageID: UUID? = nil) {
        guard !restoring && !sending,
              let repository = chatRepository else { return }
        restoring = true
        Task { [weak self] in
            guard let self else { return }
            defer { self.restoring = false; self.textViewDidChange(self.messageInput) }
            guard await self.flushBeforeSwitch() else {
                self.privacyLabel.text = V3L("当前聊天保存失败；已阻止切换，避免覆盖旧会话。")
                return
            }
            do {
                // Re-read authoritative row instead of using a possibly stale
                // snapshot from the history list.
                let all = try await repository.allChatSessions()
                guard let chosen = all.first(where: { $0.sessionID == id }) else {
                    throw WCDBV3ChatStorageError.invalidRecord
                }
                self.activateSession(chosen)
                self.reloadAndScroll(to: highlightedMessageID)
                self.navigationController?.popViewController(animated: true)
                if self.history != chosen.messages { self.enqueuePersistence() }
            } catch { self.showProblem(error) }
        }
    }

    private func enqueuePersistence() {
        guard sourceIdentity != nil, chatRepository != nil else { return }
        let previous = saveChain
        saveChain = Task { [self] in
            await previous?.value
            _ = await persistLocal()
        }
    }

    /// Serial actor-backed CAS. This persists all local turns, not just the
    /// bounded suffix supplied to the remote model.
    private func persistLocal() async -> Bool {
        guard let identity = sourceIdentity, let repository = chatRepository else {
            return sourceIdentity == nil
        }
        // A queued save after deletion must not create an empty new record.
        if storedSession == nil && history.isEmpty &&
           messageInput.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
           contextReferences.isEmpty && pendingDuplex == nil &&
           previousDuplex.isEmpty && selectedModelID == nil &&
           sessionPromptOverride == nil { return true }
        let base = storedSession ?? WCDBV3ChatSession(
            sessionID: provisionalChatSessionID, sourceIdentity: identity)
        if storedSession != nil && base.messages == history &&
           (base.sourceDisplayName != nil || isForeignSession) &&
           base.inputDraft == messageInput.text &&
           base.contextReferences == contextReferences &&
           base.requestError == requestFailure &&
           base.promptOverride == sessionPromptOverride &&
           base.selectedChatModelID == selectedModelID &&
           base.pendingDuplex == pendingDuplex &&
           (base.duplexHistory ?? []) == previousDuplex &&
           (base.contextConsentGranted == true) == contextConsentGranted { return true }
        var next = base
        if next.sourceDisplayName == nil && !isForeignSession {
            next.sourceDisplayName = entrySourceDisplayName
        }
        next.messages = history
        next.inputDraft = messageInput.text ?? ""
        next.contextReferences = contextReferences
        next.requestError = requestFailure
        next.promptOverride = sessionPromptOverride
        next.selectedChatModelID = selectedModelID
        next.pendingDuplex = pendingDuplex
        next.duplexHistory = previousDuplex
        next.contextConsentGranted = contextConsentGranted
        // Device clock and imported backups can be older than a saved row.
        // WCDB uses monotonic CAS timestamps, including before New Discussion.
        next.updatedAt = max(Date(), base.updatedAt.addingTimeInterval(0.001))
        next.revision = storedSession == nil ? 0 : base.revision + 1
        do {
            try await repository.saveChatSession(
                next, expectedRevision: storedSession?.revision)
            storedSession = next
            return true
        } catch {
            showTransientStatus(V3L("本地聊天保存失败。未能确认草稿或对话已保存。"))
            return false
        }
    }

    private func showProblem(_ error: Error) {
        showTransientStatus(error.localizedDescription)
        let alert = UIAlertController(title: V3L("AI 对话失败"),
            message: error.localizedDescription, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: V3L("确定"), style: .default))
        if presentedViewController == nil { present(alert, animated: true) }
    }

    private func reloadAndScroll(to messageID: UUID? = nil) {
        transcript.update(history, focusMessageID: messageID)
    }
}

@MainActor
final class ImpressChatFeatureListViewController: UITableViewController {
    struct Entry {
        let title: String
        let symbol: String
        let identifier: String
        let action: () -> Void
    }
    private let entries: [Entry]
    init(entries: [Entry]) {
        self.entries = entries
        super.init(style: .insetGrouped)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) unsupported") }
    override func viewDidLoad() {
        super.viewDidLoad()
        title = V3L("对话功能")
        navigationItem.largeTitleDisplayMode = .never
        tableView.backgroundColor = ImpressV3Appearance.page
        tableView.accessibilityIdentifier = "impress.ai.chat.feature-list"
    }
    override func tableView(_ tableView: UITableView,
                            numberOfRowsInSection section: Int) -> Int { entries.count }
    override func tableView(_ tableView: UITableView,
                            cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let entry = entries[indexPath.row]
        let cell = UITableViewCell(style: .default, reuseIdentifier: nil)
        var config = UIListContentConfiguration.cell()
        config.text = entry.title
        config.image = UIImage(systemName: entry.symbol)
        cell.contentConfiguration = config
        cell.accessoryType = .disclosureIndicator
        cell.accessibilityIdentifier = "impress.ai.chat.feature." + entry.identifier
        return cell
    }
    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        guard entries.indices.contains(indexPath.row) else { return }
        let action = entries[indexPath.row].action
        tableView.deselectRow(at: indexPath, animated: true)
        navigationController?.popViewController(animated: false)
        action()
    }
}

@MainActor
final class ImpressChatSessionHistoryViewController: UITableViewController,
                                                      UISearchResultsUpdating {
    private struct Hit {
        let session: WCDBV3ChatSession
        let messageID: UUID?
        let preview: String
    }

    private var sessions: [WCDBV3ChatSession]
    private var hits: [Hit] = []
    private let currentSessionID: UUID?
    private let repository: ReviewWCDBRepository
    private let search = UISearchController(searchResultsController: nil)
    var onSelect: ((UUID, UUID?) -> Void)?
    var onDeleted: ((UUID) -> Void)?

    init(sessions: [WCDBV3ChatSession], currentSessionID: UUID?,
         repository: ReviewWCDBRepository) {
        self.sessions = sessions
        self.currentSessionID = currentSessionID
        self.repository = repository
        super.init(style: .insetGrouped)
        buildHits(query: "")
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) unsupported") }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = V3L("历史讨论")
        tableView.backgroundColor = ImpressV3Appearance.page
        tableView.rowHeight = UITableView.automaticDimension
        tableView.accessibilityIdentifier = "impress.ai.chat.history-list"
        search.searchResultsUpdater = self
        search.obscuresBackgroundDuringPresentation = false
        search.searchBar.placeholder = V3L("搜索标题、消息或来源")
        navigationItem.searchController = search
        navigationItem.hidesSearchBarWhenScrolling = false
        definesPresentationContext = true
        updateEmptyState()
    }

    private func displayTitle(for session: WCDBV3ChatSession) -> String {
        let first = session.messages.first(where: { $0.role == .user })?.text ??
            (session.inputDraft.isEmpty ? V3L("空白讨论") : session.inputDraft)
        return String(first.prefix(100))
    }

    private func matchingPreview(_ text: String, term: String) -> String {
        guard let range = text.range(of: term, options: .caseInsensitive) else {
            return String(text.prefix(140))
        }
        // A long reply may match near the end; show the user's search term
        // rather than an unrelated 140-character opening.
        let beginning = text.index(range.lowerBound, offsetBy: -45,
                                   limitedBy: text.startIndex) ?? text.startIndex
        let ending = text.index(range.upperBound, offsetBy: 75,
                                limitedBy: text.endIndex) ?? text.endIndex
        return (beginning == text.startIndex ? "" : "…") +
            String(text[beginning..<ending]) +
            (ending == text.endIndex ? "" : "…")
    }

    private func buildHits(query: String) {
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
        var next: [Hit] = []
        for session in sessions where session.isDeleted != true {
            let title = displayTitle(for: session)
            if term.isEmpty {
                next.append(Hit(session: session, messageID: nil, preview: title))
                continue
            }
            // A first-hit-only session row hides every later matching reply.
            // Search results carry the exact message ID for scroll-to-match.
            let matchingMessages = session.messages.filter {
                $0.text.localizedCaseInsensitiveContains(term)
            }
            if !matchingMessages.isEmpty {
                for message in matchingMessages {
                    next.append(Hit(session: session,
                        messageID: message.messageID,
                        preview: matchingPreview(message.text, term: term)))
                }
            } else if title.localizedCaseInsensitiveContains(term) ||
                      session.sourceIdentity.localizedCaseInsensitiveContains(term) ||
                      (session.sourceDisplayName?.localizedCaseInsensitiveContains(term) ?? false) ||
                      session.inputDraft.localizedCaseInsensitiveContains(term) {
                next.append(Hit(session: session, messageID: nil, preview: title))
            }
        }
        hits = next
    }

    func updateSearchResults(for searchController: UISearchController) {
        buildHits(query: searchController.searchBar.text ?? "")
        tableView.reloadData()
        updateEmptyState()
    }

    private func updateEmptyState() {
        guard hits.isEmpty else {
            tableView.backgroundView = nil
            return
        }
        let label = UILabel()
        label.text = sessions.isEmpty
            ? V3L("还没有历史讨论；新建不会删除旧会话。")
            : V3L("没有符合搜索条件的本地讨论。")
        label.numberOfLines = 0
        label.textAlignment = .center
        label.font = ImpressV3Appearance.Typography.body
        label.textColor = ImpressV3Appearance.secondaryText
        tableView.backgroundView = label
    }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        hits.count
    }

    override func tableView(_ tableView: UITableView,
                            cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let hit = hits[indexPath.row]
        let session = hit.session
        let cell = tableView.dequeueReusableCell(withIdentifier: "chat.history")
            ?? UITableViewCell(style: .subtitle, reuseIdentifier: "chat.history")
        var config = UIListContentConfiguration.subtitleCell()
        config.text = hit.preview
        config.secondaryText = (session.sourceDisplayName ?? session.sourceIdentity) + " · " +
            DateFormatter.localizedString(from: session.updatedAt,
                dateStyle: .short, timeStyle: .short)
        config.textProperties.numberOfLines = 2
        config.secondaryTextProperties.numberOfLines = 1
        config.textProperties.font = ImpressV3Appearance.Typography.body
        config.secondaryTextProperties.font = ImpressV3Appearance.Typography.caption
        cell.contentConfiguration = config
        cell.backgroundColor = ImpressV3Appearance.surface
        cell.accessoryType = session.sessionID == currentSessionID
            ? .checkmark : .disclosureIndicator
        // Make the actual preview searchable by VoiceOver and XCTest. UIKit
        // does not consistently synthesize the cell's accessibility label
        // from UIListContentConfiguration on every iOS runtime. The row must
        // expose its own persisted message text, not only a generic ID.
        cell.accessibilityLabel = hit.preview + " · " +
            (session.sourceDisplayName ?? session.sourceIdentity)
        cell.accessibilityIdentifier = "impress.ai.chat.history-row"
        return cell
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        guard hits.indices.contains(indexPath.row) else { return }
        let hit = hits[indexPath.row]
        onSelect?(hit.session.sessionID, hit.messageID)
        tableView.deselectRow(at: indexPath, animated: true)
    }

    override func tableView(_ tableView: UITableView,
                            trailingSwipeActionsConfigurationForRowAt indexPath: IndexPath)
        -> UISwipeActionsConfiguration? {
        guard hits.indices.contains(indexPath.row) else { return nil }
        let id = hits[indexPath.row].session.sessionID
        let action = UIContextualAction(style: .destructive, title: V3L("删除")) {
            [weak self] _, _, completion in
            // The swipe itself is NOT approval. Cancel the swipe and show an
            // explicit, full-scope confirmation first.
            completion(false)
            self?.confirmDeletion(of: id)
        }
        action.image = UIImage(systemName: "trash")
        let config = UISwipeActionsConfiguration(actions: [action])
        config.performsFirstActionWithFullSwipe = false
        return config
    }

    private func confirmDeletion(of id: UUID) {
        let warning = UIAlertController(title: V3L("删除本地讨论？"),
            message: V3L("将清除普通消息、草稿和未执行提案。已经执行的卡片或笔记修改不会撤销，必要回执仍保留在本机修订记录中；旧的未加密备份可能仍包含删除前的聊天。执行中或未核实的修订必须先核查。"),
            preferredStyle: .alert)
        warning.addAction(UIAlertAction(title: V3L("取消"), style: .cancel))
        warning.addAction(UIAlertAction(title: V3L("确认删除"), style: .destructive) {
            [weak self] _ in
            guard let self else { return }
            Task {
                do {
                    let latest = try await self.repository.allChatSessions()
                    guard let session = latest.first(where: { $0.sessionID == id }) else {
                        throw WCDBV3ChatStorageError.invalidRecord
                    }
                    try await self.repository.deleteChatSession(id,
                        expectedRevision: session.revision)
                    self.sessions = try await self.repository.allChatSessions()
                    self.buildHits(query: self.search.searchBar.text ?? "")
                    self.tableView.reloadData()
                    self.updateEmptyState()
                    self.onDeleted?(id)
                } catch {
                    let explanation: String
                    if case WCDBV3ChatStorageError.unsafeDeletion = error {
                        explanation = V3L("存在执行中、撤销中或部分成功但未核实的修订。请先从原来源核查回执，删除已被阻止。")
                    } else {
                        explanation = V3L("删除未成功，原会话保持不变：") +
                            error.localizedDescription
                    }
                    let alert = UIAlertController(title: V3L("无法安全删除"),
                        message: explanation, preferredStyle: .alert)
                    alert.addAction(UIAlertAction(title: V3L("确定"), style: .default))
                    self.present(alert, animated: true)
                }
            }
        })
        present(warning, animated: true)
    }
}

@MainActor
final class ImpressChatNoteSectionPicker: UITableViewController {
    private let sections: [ImpressAISectionItem]
    private var selected: Set<String> = []
    var onApply: (([ImpressAISectionItem]) -> Void)?

    init(sections: [ImpressAISectionItem]) {
        self.sections = sections
        super.init(style: .insetGrouped)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) unsupported") }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = V3L("选择笔记章节")
        tableView.backgroundColor = ImpressV3Appearance.page
        navigationItem.rightBarButtonItem = UIBarButtonItem(
            title: V3L("使用所选"), style: .plain,
            target: self, action: #selector(acceptSelection))
        navigationItem.rightBarButtonItem?.accessibilityIdentifier =
            "impress.ai.chat.section-confirm"
        navigationItem.rightBarButtonItem?.isEnabled = false
    }
    override func numberOfSections(in tableView: UITableView) -> Int { 1 }
    override func tableView(_ tableView: UITableView,
                            numberOfRowsInSection section: Int) -> Int { sections.count }
    override func tableView(_ tableView: UITableView,
                            cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let item = sections[indexPath.row]
        let cell = tableView.dequeueReusableCell(withIdentifier: "chat.section")
            ?? UITableViewCell(style: .subtitle, reuseIdentifier: "chat.section")
        var config = UIListContentConfiguration.subtitleCell()
        config.text = String(repeating: "  ", count: max(0, item.level - 1)) + item.heading
        config.secondaryText = String(item.text.utf8.count) + " bytes"
        config.textProperties.numberOfLines = 2
        cell.contentConfiguration = config
        cell.accessoryType = selected.contains(item.id) ? .checkmark : .none
        cell.backgroundColor = ImpressV3Appearance.surface
        return cell
    }
    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        let id = sections[indexPath.row].id
        if selected.contains(id) { selected.remove(id) } else { selected.insert(id) }
        tableView.reloadRows(at: [indexPath], with: .none)
        let size = ImpressAISectionExtractor.effectiveSelection(
            sections, selectedIDs: selected).reduce(0) { $0 + $1.text.utf8.count }
        navigationItem.rightBarButtonItem?.isEnabled = !selected.isEmpty && size <= 8_000
    }

    @objc private func acceptSelection() {
        let selection = ImpressAISectionExtractor.effectiveSelection(
            sections, selectedIDs: selected)
        let size = selection.reduce(0) { $0 + $1.text.utf8.count }
        guard !selection.isEmpty, size <= 8_000 else { return }
        onApply?(selection)
    }
}



@MainActor
final class ImpressDuplexReceiptHistoryController: UITableViewController {
    private var records: [WCDBV3DuplexProposal]
    var onSelect: ((WCDBV3DuplexProposal) -> Void)?
    var onRefresh: (() -> [WCDBV3DuplexProposal])?

    init(records: [WCDBV3DuplexProposal]) {
        self.records = records
        super.init(style: .insetGrouped)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) unsupported") }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = V3L("修订回执历史")
        tableView.accessibilityIdentifier = "impress.duplex.receipt-history"
    }
    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        if let onRefresh { records = onRefresh() }
        tableView.reloadData()
    }
    override func tableView(_ tableView: UITableView,
                            numberOfRowsInSection section: Int) -> Int {
        records.count
    }
    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath)
        -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "duplex.receipt")
            ?? UITableViewCell(style: .subtitle, reuseIdentifier: "duplex.receipt")
        let entry = records[indexPath.row]
        cell.textLabel?.text = entry.noteIdentity?.relativePath ??
            (entry.cardID?.uuidString ?? entry.proposalID.uuidString)
        cell.detailTextLabel?.text = V3L("笔记：") + entry.state.noteStatus.rawValue +
            " · " + V3L("原卡：") + entry.state.cardStatus.rawValue
        cell.accessoryType = .disclosureIndicator
        return cell
    }
    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        onSelect?(records[indexPath.row])
    }
}

// MARK: - Explicit, recoverable note + ORIGINAL card change review
//
// This deliberately uses the existing private Vault draft, authorized scoped
// file writer, WCDB card CAS, and Chat session record. The AI response is only
// discussion; there is no model-to-file command and NO implicit production write.
@MainActor
final class ImpressDuplexChangeController: UIViewController {
    typealias SaveProposal = @MainActor (WCDBV3DuplexProposal) async -> Bool
    private let repository: ReviewWCDBRepository
    private let cardID: UUID?
    private let sourceContentRevision: Int?
    private let noteIdentity: ImVaultFileIdentity?
    private let sourceMessageID: UUID?
    private let suggestedText: String?
    private let suggestionReadOnly = UITextView()
    private let applySuggestionButton = UIButton(type: .system)
    private let saveProposal: SaveProposal
    private var pending: WCDBV3DuplexProposal?
    private var card: WCDBV3CardContent?
    private var reviewRevision: Int?
    private var draft: ImVaultDraft?
    private var loaded = false

    private let cardInfo = UILabel()
    private let noteInfo = UILabel()
    private let questionInput = UITextView()
    private let answerInput = UITextView()
    private let editNoteButton = UIButton(type: .system)
    private let previewButton = UIButton(type: .system)

    init(repository: ReviewWCDBRepository, cardID: UUID?,
         sourceContentRevision: Int?, noteIdentity: ImVaultFileIdentity?,
         sourceMessageID: UUID?, pending: WCDBV3DuplexProposal?,
         suggestedText: String? = nil, saveProposal: @escaping SaveProposal) {
        self.repository = repository
        self.cardID = cardID
        self.sourceContentRevision = sourceContentRevision
        self.noteIdentity = noteIdentity
        self.sourceMessageID = sourceMessageID
        self.pending = pending
        self.suggestedText = suggestedText
        self.saveProposal = saveProposal
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) unsupported") }

    private func label(_ content: String) -> UILabel {
        let label = UILabel()
        label.text = content
        label.font = ImpressV3Appearance.Typography.body
        label.adjustsFontForContentSizeCategory = true
        label.textColor = ImpressV3Appearance.primaryText
        label.numberOfLines = 0
        return label
    }
    private func configure(_ view: UITextView, identifier: String, height: CGFloat) {
        view.font = ImpressV3Appearance.Typography.body
        view.adjustsFontForContentSizeCategory = true
        view.textColor = ImpressV3Appearance.primaryText
        view.backgroundColor = ImpressV3Appearance.surface
        view.layer.cornerRadius = ImpressV3Appearance.Radius.field
        view.textContainerInset = UIEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
        view.heightAnchor.constraint(equalToConstant: height).isActive = true
        view.accessibilityIdentifier = identifier
        ImpressSpeechAccessory.install(on: view)
    }
    override func viewDidLoad() {
        super.viewDidLoad()
        title = V3L("笔记与原卡修订")
        view.backgroundColor = ImpressV3Appearance.page
        navigationItem.largeTitleDisplayMode = .never
        let scroll = UIScrollView()
        let stack = UIStackView()
        scroll.accessibilityIdentifier = "impress.duplex.change-scroll"
        scroll.translatesAutoresizingMaskIntoConstraints = false
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.axis = .vertical
        stack.spacing = ImpressV3Appearance.Metrics.rowSpacing
        stack.isLayoutMarginsRelativeArrangement = true
        stack.directionalLayoutMargins = NSDirectionalEdgeInsets(top: 12, leading: 16,
                                                                  bottom: 24, trailing: 16)
        cardInfo.font = ImpressV3Appearance.Typography.footnote
        noteInfo.font = ImpressV3Appearance.Typography.footnote
        for info in [cardInfo, noteInfo] {
            info.adjustsFontForContentSizeCategory = true
            info.numberOfLines = 0
            info.textColor = ImpressV3Appearance.secondaryText
        }
        configure(questionInput, identifier: "impress.duplex.question", height: 114)
        configure(answerInput, identifier: "impress.duplex.answer", height: 160)
        suggestionReadOnly.font = ImpressV3Appearance.Typography.body
        suggestionReadOnly.adjustsFontForContentSizeCategory = true
        suggestionReadOnly.textColor = ImpressV3Appearance.primaryText
        suggestionReadOnly.backgroundColor = ImpressV3Appearance.surface
        suggestionReadOnly.layer.cornerRadius = ImpressV3Appearance.Radius.field
        suggestionReadOnly.isEditable = false
        suggestionReadOnly.isSelectable = true
        suggestionReadOnly.text = suggestedText ?? ""
        suggestionReadOnly.accessibilityIdentifier = "impress.duplex.assistant-suggestion"
        suggestionReadOnly.heightAnchor.constraint(equalToConstant: 145).isActive = true
        ImpressV3Appearance.styleQuietButton(applySuggestionButton,
            title: V3L("采用选定 AI 回复作为原卡答案候选"),
            symbol: "arrow.down.doc")
        applySuggestionButton.accessibilityIdentifier = "impress.duplex.use-suggestion"
        applySuggestionButton.addTarget(self, action: #selector(adoptSuggestion),
                                         for: .touchUpInside)
        applySuggestionButton.isEnabled = false
        ImpressV3Appearance.styleQuietButton(editNoteButton,
            title: V3L("修改对应笔记的私有草稿"), symbol: "square.and.pencil")
        editNoteButton.addTarget(self, action: #selector(editNote), for: .touchUpInside)
        editNoteButton.accessibilityIdentifier = "impress.duplex.edit-note"
        ImpressV3Appearance.styleQuietButton(previewButton,
            title: V3L("预览两个对象的完整修改"), symbol: "checkmark.shield")
        previewButton.addTarget(self, action: #selector(preparePreview), for: .touchUpInside)
        previewButton.accessibilityIdentifier = "impress.duplex.preview"
        previewButton.isEnabled = false
        if let suggestedText, !suggestedText.isEmpty {
            stack.addArrangedSubview(label(V3L("选定的 AI 回复 · 只读建议，尚未修改任何对象")))
            stack.addArrangedSubview(suggestionReadOnly)
            stack.addArrangedSubview(applySuggestionButton)
        }
        stack.addArrangedSubview(label(V3L("原卡 · 编辑题目与答案")))
        stack.addArrangedSubview(cardInfo)
        stack.addArrangedSubview(label(V3L("题目")))
        stack.addArrangedSubview(questionInput)
        stack.addArrangedSubview(label(V3L("答案")))
        stack.addArrangedSubview(answerInput)
        stack.addArrangedSubview(label(V3L("关联笔记 · 局部改动")))
        stack.addArrangedSubview(noteInfo)
        stack.addArrangedSubview(editNoteButton)
        stack.addArrangedSubview(previewButton)
        view.addSubview(scroll)
        scroll.addSubview(stack)
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            scroll.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            stack.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor),
            stack.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor),
            stack.widthAnchor.constraint(equalTo: scroll.frameLayoutGuide.widthAnchor)
        ])
        Task { await loadTargets() }
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        if loaded { refreshDraft() }
    }

    private func loadTargets() async {
        do {
            if let cardID {
                guard let item = try await repository.content(for: cardID),
                      let queue = try await repository.fetchQueueCandidates()
                        .first(where: { $0.cardID == cardID }) else {
                    throw ReviewWCDBError.missingCard
                }
                if pending == nil, let expected = sourceContentRevision,
                   item.contentRevision != expected {
                    throw ReviewWCDBError.contentConflict
                }
                // A card+note proposal may only target the card's exact
                // verified Vault identity, never a same-title note.
                if let identity = noteIdentity {
                    guard let encoded = item.sourceNotePath,
                          (try? ImpressBatchSourceKey.decode(encoded)) == identity else {
                        throw ImVaultSyncFailure.wrongVault
                    }
                }
                card = item
                reviewRevision = queue.revision
                let canEditStandard = item.cardType == 0
                questionInput.isEditable = canEditStandard && pending == nil
                answerInput.isEditable = canEditStandard && pending == nil
                questionInput.text = pending?.cardEditedQuestion ?? item.question
                answerInput.text = pending?.cardEditedAnswer ?? item.answerText ?? ""
                applySuggestionButton.isEnabled = canEditStandard &&
                    pending == nil && suggestedText != nil &&
                    !(suggestedText ?? "").isEmpty &&
                    (suggestedText?.utf8.count ?? 0) <= 40_000
                cardInfo.text = "cardID: " + cardID.uuidString +
                    "\nContent revision: " + String(item.contentRevision) +
                    (canEditStandard ? "" :
                        "\n" + V3L("非普通卡片请在原卡编辑器修改；本次可仅确认笔记。"))
            } else {
                cardInfo.text = V3L("没有关联原卡，本次仅核查笔记修改。")
                questionInput.isHidden = true
                answerInput.isHidden = true
            }
            if noteIdentity == nil {
                editNoteButton.isHidden = true
                noteInfo.text = V3L("没有可核实的来源笔记，仅修改原卡。")
            }
            if pending != nil {
                editNoteButton.isEnabled = false
                navigationItem.prompt = V3L("恢复待处理提案；不会自动重放任何写入。")
            }
            loaded = true
            previewButton.isEnabled = true
            refreshDraft()
        } catch { presentIssue(V3L("读取原卡或来源失败"), error.localizedDescription) }
    }

    private func refreshDraft() {
        guard let identity = noteIdentity else { return }
        do {
            guard ImVaultReadOnlyProbe.shared.authorizedVaultID == identity.vaultID else {
                throw ImVaultSyncFailure.wrongVault
            }
            if let pending, pending.noteIdentity == identity {
                draft = try ImVaultPrivateStore.approvedDraft(identity: identity,
                    baseDigest: pending.noteBaseDigest,
                    editedDigest: pending.noteEditedDigest)
            } else {
                draft = try ImVaultPrivateStore.loadDraft(identity: identity)
            }
            if let draft {
                let diff = ImVaultDiff.summary(base: draft.byteFaithfulBaseText,
                    edited: draft.byteFaithfulEditedText, maximumLines: 200)
                noteInfo.text = "Vault ID: " + identity.vaultID +
                    "\n" + V3L("目标：") + identity.relativePath +
                    "\nSHA-256: " + draft.baseDigest +
                    "\n" + (draft.hasChanges
                        ? (diff.complete ? V3L("已有局部修订草稿，可预览与选择写回。") :
                           V3L("修改范围超过预览上限，禁止确认笔记写回。"))
                        : V3L("草稿未修改；可只更新原卡。"))
            } else {
                noteInfo.text = "Vault ID: " + identity.vaultID +
                    "\n" + V3L("目标：") + identity.relativePath +
                    "\n" + V3L("尚无笔记修订草稿；打开编辑器增量修改原文。")
            }
        } catch {
            draft = nil
            noteInfo.text = V3L("无法读取笔记草稿：") + error.localizedDescription
        }
    }

    @objc private func editNote() {
        guard pending == nil, let identity = noteIdentity,
              identity.documentFormat == .markdown,
              ImVaultReadOnlyProbe.shared.authorizedVaultID == identity.vaultID else {
            presentIssue(V3L("来源身份已失效"), ImVaultSyncFailure.wrongVault.localizedDescription)
            return
        }
        if let suggestion = suggestedText, !suggestion.isEmpty {
            let choice = UIAlertController(title: V3L("选择笔记修订方式"),
                message: V3L("选定 AI 回复只能成为可编辑建议，不能直接覆写原笔记。请选择指定章节或继续手动编辑草稿。"),
                preferredStyle: .actionSheet)
            choice.addAction(UIAlertAction(title: V3L("指定原章节并编辑 AI 建议"),
                style: .default) { [weak self] _ in
                self?.openNoteDraftEditor(useAIResponse: true)
            })
            choice.addAction(UIAlertAction(title: V3L("手动编辑独立草稿"),
                style: .default) { [weak self] _ in
                self?.openNoteDraftEditor(useAIResponse: false)
            })
            choice.addAction(UIAlertAction(title: V3L("取消"), style: .cancel))
            choice.popoverPresentationController?.sourceView = view
            choice.popoverPresentationController?.sourceRect = CGRect(
                x: view.bounds.midX, y: view.bounds.midY, width: 1, height: 1)
            present(choice, animated: true)
        } else {
            openNoteDraftEditor(useAIResponse: false)
        }
    }

    private func openNoteDraftEditor(useAIResponse: Bool) {
        guard pending == nil, let identity = noteIdentity,
              identity.documentFormat == .markdown,
              ImVaultReadOnlyProbe.shared.authorizedVaultID == identity.vaultID else {
            presentIssue(V3L("来源身份已失效"), ImVaultSyncFailure.wrongVault.localizedDescription)
            return
        }
        ImVaultReadSync.shared.read(identity) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let source):
                guard source.identity == identity,
                      ImVaultReadOnlyProbe.shared.authorizedVaultID ==
                          identity.vaultID else {
                    self.presentIssue(V3L("来源已变化"),
                        ImVaultSyncFailure.wrongVault.localizedDescription)
                    return
                }
                do {
                    if useAIResponse, let suggestion = self.suggestedText {
                        let picker = ImpressDuplexNoteSectionTargetController(
                            live: source, proposedText: suggestion) { [weak self] in
                            guard let self else { return }
                            self.navigationController?.popToViewController(
                                self, animated: true)
                        }
                        self.navigationController?.pushViewController(
                            picker, animated: true)
                    } else {
                        try ImVaultDraftEntry.open(live: source, presenter: self)
                    }
                } catch {
                    self.presentIssue(V3L("笔记草稿不可用"), error.localizedDescription)
                }
            case .failure(let error):
                self.presentIssue(V3L("源笔记读取失败"), error.localizedDescription)
            }
        }
    }

    @objc private func adoptSuggestion() {
        guard loaded, pending == nil, card?.cardType == 0,
              let suggestion = suggestedText,
              !suggestion.isEmpty, suggestion.utf8.count <= 40_000 else {
            return
        }
        // Explicit user operation changes ONLY the editor field. No FSRS
        // mutation, Vault write, proposal or network request happens here.
        answerInput.text = suggestion
        // Adopting a read-only suggestion must not cover the Note editor with
        // a keyboard; the user may focus Answer explicitly to edit it.
        answerInput.resignFirstResponder()
    }

    @objc private func preparePreview() {
        guard loaded else { return }
        Task { [weak self] in
            guard let self else { return }
            if let pending = self.pending {
                self.openApproval(pending)
                return
            }
            let revisedQ = self.questionInput.text.trimmingCharacters(
                in: .whitespacesAndNewlines)
            let revisedA = self.answerInput.text ?? ""
            let changedCard = self.card?.cardType == 0 &&
                (self.card?.question != revisedQ || self.card?.answerText != revisedA)
            let changedNote = self.draft?.hasChanges == true
            guard changedCard || changedNote else {
                self.presentIssue(V3L("内容未变化"), V3L("请先编辑笔记草稿或原卡。"))
                return
            }
            guard !changedCard || (!revisedQ.isEmpty && revisedQ.utf8.count <= 10_000 &&
                                  revisedA.utf8.count <= 40_000) else {
                self.presentIssue(V3L("卡片内容无效"), V3L("题目不能为空或超过安全长度。"))
                return
            }
            if changedNote, let d = self.draft {
                guard ImVaultDiff.summary(base: d.byteFaithfulBaseText, edited: d.byteFaithfulEditedText,
                                          maximumLines: 200).complete else {
                    self.presentIssue(V3L("修改预览过长"),
                        V3L("请把笔记修改缩小到可完整核对的范围。"))
                    return
                }
            }
            let p = WCDBV3DuplexProposal(sourceMessageID: self.sourceMessageID,
                noteIdentity: changedNote ? self.noteIdentity : nil,
                noteBaseDigest: changedNote ? self.draft?.baseDigest : nil,
                noteEditedDigest: changedNote ? self.draft.map {
                    ImVaultDigest.sha256($0.proposedBytes)
                } : nil,
                cardID: changedCard ? self.cardID : nil,
                cardReviewRevision: changedCard ? self.reviewRevision : nil,
                cardContentRevision: changedCard ? self.card?.contentRevision : nil,
                cardBaseQuestion: changedCard ? self.card?.question : nil,
                cardBaseAnswer: changedCard ? self.card?.answerText : nil,
                cardEditedQuestion: changedCard ? revisedQ : nil,
                cardEditedAnswer: changedCard ? revisedA : nil,
                state: ImDuplexApprovalState(noteSelected: changedNote,
                                             cardSelected: changedCard))
            if changedNote, let candidate = self.draft {
                do { try ImVaultPrivateStore.archiveApprovedDraft(candidate) }
                catch {
                    self.presentIssue(V3L("无法锁定笔记版本快照"), error.localizedDescription)
                    return
                }
            }
            guard await self.saveProposal(p) else {
                self.presentIssue(V3L("提案未保存"),
                    V3L("Chat 的原子版本检查失败；修改尚未得到保存确认，禁止执行。"))
                return
            }
            self.pending = p
            self.openApproval(p)
        }
    }

    private func openApproval(_ proposal: WCDBV3DuplexProposal) {
        let page = ImpressDuplexApprovalController(
            repository: repository, proposal: proposal) { [weak self] changed in
                guard let self else { return false }
                let saved = await self.saveProposal(changed)
                if saved { self.pending = changed }
                return saved
            }
        navigationController?.pushViewController(page, animated: true)
    }

    private func presentIssue(_ title: String, _ detail: String) {
        let alert = UIAlertController(title: title, message: detail, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: V3L("确定"), style: .default))
        if presentedViewController == nil { present(alert, animated: true) }
    }
}

/// Only local, verified bytes form a reverse note edit. Reconstructing
/// Markdown from rendered rich text or from an AI transcript is forbidden.
@MainActor
enum ImpressDuplexUndoGate {
    static func inverseDraft(_ existing: ImVaultDraft,
                             expectedBaseDigest: String?,
                             expectedAppliedDigest: String?) throws -> ImVaultDraft {
        try existing.validate()
        guard existing.baseDigest == expectedBaseDigest,
              ImVaultDigest.sha256(existing.proposedBytes) == expectedAppliedDigest,
              let appliedText = String(data: existing.proposedBytes, encoding: .utf8) else {
            throw ImVaultSyncFailure.conflict
        }
        let reversed = try ImVaultDraft(identity: existing.identity,
            baseText: appliedText, baseRawData: existing.proposedBytes,
            editedText: existing.baseText)
        try reversed.validate()
        guard reversed.proposedBytes == existing.baseRawData,
              reversed.hasChanges else {
            throw ImVaultSyncFailure.verificationFailed
        }
        return reversed
    }

    /// Revalidate the EXACT source shown in the undo preview before recording
    /// a durable .undoing intent. A later legitimate edit must be a clean
    /// conflict, not an orphaned interrupted inverse receipt.
    static func requireFreshNotePreflight(_ inverse: ImVaultDraft,
                                          identity: ImVaultFileIdentity,
                                          bytes: Data) throws {
        guard inverse.identity == identity,
              inverse.decision(against: bytes) == .safeToWrite else {
            throw ImVaultSyncFailure.conflict
        }
    }

    static func requireFreshCardPreflight(
        expectedContentRevision: Int, currentContentRevision: Int,
        appliedQuestion: String, appliedAnswer: String?,
        originalQuestion: String, originalAnswer: String?,
        currentQuestion: String, currentAnswer: String?
    ) throws {
        guard ImDuplexCardVersionGate.decide(
            expectedContentRevision: expectedContentRevision,
            currentContentRevision: currentContentRevision,
            baseQuestion: appliedQuestion, baseAnswer: appliedAnswer,
            proposedQuestion: originalQuestion, proposedAnswer: originalAnswer,
            currentQuestion: currentQuestion, currentAnswer: currentAnswer
        ) == .safeToWrite else {
            throw ReviewWCDBError.contentConflict
        }
    }
}

@MainActor
final class ImpressDuplexUndoReviewController: UIViewController {
    typealias UndoAction = @MainActor () async -> Result<String, Error>
    private let content: String
    private let onConfirm: UndoAction
    private let button = UIButton(type: .system)
    private var applying = false
    // F05: inverse confirmation is also a single outstanding human consent.
    private var consentPending = false

    init(content: String, onConfirm: @escaping UndoAction) {
        self.content = content
        self.onConfirm = onConfirm
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) unsupported") }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = V3L("核对撤销内容")
        view.backgroundColor = ImpressV3Appearance.page
        let body = UITextView()
        body.translatesAutoresizingMaskIntoConstraints = false
        body.text = content
        body.font = ImpressV3Appearance.Typography.compactCode
        body.adjustsFontForContentSizeCategory = true
        body.textColor = ImpressV3Appearance.primaryText
        body.backgroundColor = ImpressV3Appearance.surface
        body.isEditable = false
        body.isSelectable = true
        body.accessibilityIdentifier = "impress.duplex.undo.full-diff"
        ImpressV3Appearance.styleQuietButton(button,
            title: V3L("确认按当前版本撤销"), symbol: "arrow.uturn.backward")
        button.translatesAutoresizingMaskIntoConstraints = false
        button.accessibilityIdentifier = "impress.duplex.undo.confirm"
        button.addTarget(self, action: #selector(askUndo), for: .touchUpInside)
        view.addSubview(body)
        view.addSubview(button)
        NSLayoutConstraint.activate([
            body.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 8),
            body.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor,
                                          constant: 12),
            body.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor,
                                           constant: -12),
            body.bottomAnchor.constraint(equalTo: button.topAnchor, constant: -10),
            button.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor,
                                             constant: 16),
            button.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor,
                                              constant: -16),
            button.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor,
                                           constant: -8),
            button.heightAnchor.constraint(greaterThanOrEqualToConstant: 48)
        ])
    }

    @objc private func askUndo() {
        guard !applying, !consentPending else { return }
        consentPending = true
        button.isEnabled = false
        let alert = UIAlertController(title: V3L("确认撤销这个目标？"),
            message: V3L("撤销也会重新验证当前内容版本；若别人已合法修改，必须停止。不会删除 FSRS 历史或自动重放。"),
            preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: V3L("取消"), style: .cancel) {
            [weak self] _ in
            self?.consentPending = false
            self?.button.isEnabled = true
        })
        alert.addAction(UIAlertAction(title: V3L("确认撤销"), style: .destructive) {
            [weak self] _ in
            guard let self else { return }
            self.consentPending = false
            self.applying = true
            self.button.isEnabled = false
            Task {
                let result = await self.onConfirm()
                self.applying = false
                if case .failure = result { self.button.isEnabled = true }
                let succeeded: Bool
                let message: String
                switch result {
                case .success(let detail):
                    succeeded = true
                    message = detail
                case .failure(let error):
                    succeeded = false
                    message = error.localizedDescription
                }
                let response = UIAlertController(
                    title: succeeded ? V3L("撤销结果已保存") : V3L("撤销未完成"),
                    message: message, preferredStyle: .alert)
                response.addAction(UIAlertAction(title: V3L("确定"), style: .default) {
                    [weak self] _ in
                    if succeeded {
                        self?.navigationController?.popViewController(animated: true)
                    }
                })
                self.present(response, animated: true)
            }
        })
        present(alert, animated: true)
    }
}

@MainActor
final class ImpressDuplexApprovalController: UIViewController {
    private let repository: ReviewWCDBRepository
    private let saveProposal: @MainActor (WCDBV3DuplexProposal) async -> Bool
    private var proposal: WCDBV3DuplexProposal
    private let noteToggle = UISwitch()
    private let cardToggle = UISwitch()
    private let preview = UITextView()
    private let confirm = UIButton(type: .system)
    private var undoBarItem: UIBarButtonItem?
    private var reconcileBarItem: UIBarButtonItem?
    private var discardBarItem: UIBarButtonItem?
    private var notePreviewValid = false
    private var committing = false
    // F05: a confirmation alert is an in-flight authorization, not an
    // opportunity to present multiple dialogs and schedule competing writes.
    // Keep the UI gated from the first tap through persisted execution.
    private var executionConsentPending = false

    init(repository: ReviewWCDBRepository, proposal: WCDBV3DuplexProposal,
         saveProposal: @escaping @MainActor (WCDBV3DuplexProposal) async -> Bool) {
        self.repository = repository
        self.proposal = proposal
        self.saveProposal = saveProposal
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) unsupported") }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = V3L("逐项核对并确认修改")
        view.backgroundColor = ImpressV3Appearance.page
        preview.translatesAutoresizingMaskIntoConstraints = false
        preview.isEditable = false
        preview.isSelectable = true
        preview.backgroundColor = ImpressV3Appearance.surface
        preview.textColor = ImpressV3Appearance.primaryText
        preview.font = ImpressV3Appearance.Typography.compactCode
        preview.adjustsFontForContentSizeCategory = true
        preview.accessibilityIdentifier = "impress.duplex.full-diff"
        preview.textContainerInset = UIEdgeInsets(top: 14, left: 12, bottom: 22, right: 12)

        let controls = UIStackView()
        controls.translatesAutoresizingMaskIntoConstraints = false
        controls.axis = .vertical
        controls.spacing = 6
        controls.addArrangedSubview(makeToggleRow(V3L("修改原笔记"), noteToggle))
        controls.addArrangedSubview(makeToggleRow(V3L("修改原卡"), cardToggle))
        noteToggle.accessibilityIdentifier = "impress.duplex.select-note"
        cardToggle.accessibilityIdentifier = "impress.duplex.select-card"
        noteToggle.isOn = proposal.state.noteSelected
        cardToggle.isOn = proposal.state.cardSelected
        noteToggle.addTarget(self, action: #selector(updateConfirmation), for: .valueChanged)
        cardToggle.addTarget(self, action: #selector(updateConfirmation), for: .valueChanged)
        noteToggle.isEnabled = proposal.noteIdentity != nil &&
            ![.conflict, .applied, .undoing, .reverted].contains(proposal.state.noteStatus)
        cardToggle.isEnabled = proposal.cardID != nil &&
            ![.conflict, .applied, .undoing, .reverted].contains(proposal.state.cardStatus)

        ImpressV3Appearance.styleQuietButton(confirm,
            title: V3L("确认执行所选修改"), symbol: "checkmark.shield")
        confirm.addTarget(self, action: #selector(confirmChanges), for: .touchUpInside)
        confirm.accessibilityIdentifier = "impress.duplex.confirm"
        confirm.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(preview)
        view.addSubview(controls)
        view.addSubview(confirm)
        NSLayoutConstraint.activate([
            preview.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 8),
            preview.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 12),
            preview.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -12),
            preview.bottomAnchor.constraint(equalTo: controls.topAnchor, constant: -8),
            controls.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 16),
            controls.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -16),
            controls.bottomAnchor.constraint(equalTo: confirm.topAnchor, constant: -8),
            confirm.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 16),
            confirm.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -16),
            confirm.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -8),
            confirm.heightAnchor.constraint(greaterThanOrEqualToConstant: 48)
        ])
        let discard = UIBarButtonItem(
            title: V3L("放弃未完成项"), style: .plain,
            target: self, action: #selector(discardUnapplied))
        let inverse = UIBarButtonItem(
            title: V3L("安全撤销"), style: .plain,
            target: self, action: #selector(openUndoOptions))
        undoBarItem = inverse
        let reconcile = UIBarButtonItem(title: V3L("核查中断"), style: .plain,
            target: self, action: #selector(reconcileInterrupted))
        reconcile.accessibilityIdentifier = "impress.duplex.reconcile-interrupted"
        reconcileBarItem = reconcile
        discardBarItem = discard
        navigationItem.rightBarButtonItems = [discard, inverse, reconcile]
        refreshPreview()
    }

    @objc private func discardUnapplied() {
        guard !committing, proposal.state.noteStatus != .applying,
              proposal.state.cardStatus != .applying,
              !proposal.state.needsNoteUndo,
              !proposal.state.needsCardUndo else { return }
        let confirmDiscard = UIAlertController(title: V3L("放弃未完成项？"),
            message: V3L("仅取消尚未执行的目标，已成功的笔记和原卡保留且不会撤销。"),
            preferredStyle: .alert)
        confirmDiscard.addAction(UIAlertAction(title: V3L("取消"), style: .cancel))
        confirmDiscard.addAction(UIAlertAction(title: V3L("确认放弃"), style: .destructive) {
            [weak self] _ in
            guard let self else { return }
            Task {
                var cancelled = self.proposal
                // Re-check immediately before saving: a pending async write
                // could have recorded .applying while this alert was open.
                guard cancelled.state.noteStatus != .applying,
                      cancelled.state.cardStatus != .applying,
                      !cancelled.state.needsNoteUndo,
                      !cancelled.state.needsCardUndo else { return }
                // Discard may stop an unexecuted forward proposal only.
                // Undoing/reverted targets are immutable audit history; hiding
                // an undoing flag would orphan an in-flight inverse write.
                if ![.applied, .undoing, .reverted].contains(cancelled.state.noteStatus) {
                    cancelled.state.noteSelected = false
                }
                if ![.applied, .undoing, .reverted].contains(cancelled.state.cardStatus) {
                    cancelled.state.cardSelected = false
                }
                guard await self.saveProposal(cancelled) else {
                    self.showResult(V3L("无法保存取消决定"),
                        V3L("原待处理项仍然保留，不执行任何写回。"))
                    return
                }
                self.proposal = cancelled
                self.navigationController?.popViewController(animated: true)
            }
        })
        present(confirmDiscard, animated: true)
    }

    private func makeToggleRow(_ name: String, _ control: UISwitch) -> UIView {
        let label = UILabel()
        label.text = name
        label.font = ImpressV3Appearance.Typography.body
        label.adjustsFontForContentSizeCategory = true
        label.textColor = ImpressV3Appearance.primaryText
        let row = UIStackView(arrangedSubviews: [label, control])
        row.axis = .horizontal
        row.alignment = .center
        row.distribution = .equalSpacing
        row.heightAnchor.constraint(greaterThanOrEqualToConstant: 44).isActive = true
        return row
    }

    private func refreshPreview() {
        var pieces = [V3L("文件与数据库不是同一个事务；按对象保留回执、冲突与重试。"),
                      V3L("必须逐项核对下方完整差异；无确认不会写入。"),
                      V3L("个人 Markdown 批准快照只保存在本机受保护目录，不包含在普通未加密 ZIP 备份。卸载或迁移后旧文件撤销可能不可用。")]
        if let identity = proposal.noteIdentity {
            pieces.append("\nVault ID: " + identity.vaultID +
                          "\n" + V3L("笔记：") + identity.relativePath +
                          "\nSHA-256: " + (proposal.noteBaseDigest ?? "?") +
                          "\n" + V3L("状态：") + proposal.state.noteStatus.rawValue)
            do {
                guard let draft = try ImVaultPrivateStore.approvedDraft(
                    identity: identity, baseDigest: proposal.noteBaseDigest,
                    editedDigest: proposal.noteEditedDigest) else {
                    throw ImVaultSyncFailure.conflict
                }
                let diff = ImVaultDiff.summary(base: draft.byteFaithfulBaseText,
                    edited: draft.byteFaithfulEditedText, maximumLines: 200)
                notePreviewValid = diff.complete
                pieces.append(diff.text)
            } catch {
                notePreviewValid = false
                pieces.append(V3L("草稿变更或不存在：旧批准已失效，不能写入。") +
                              "\n" + error.localizedDescription)
            }
        }
        if let id = proposal.cardID {
            pieces.append("\ncardID: " + id.uuidString +
                          "\nContent revision: " + String(proposal.cardContentRevision ?? -1) +
                          "\n" + V3L("状态：") + proposal.state.cardStatus.rawValue)
            pieces.append("\n" + V3L("原题目：") + "\n" + (proposal.cardBaseQuestion ?? "") +
                          "\n" + V3L("新题目：") + "\n" + (proposal.cardEditedQuestion ?? "") +
                          "\n" + V3L("原答案：") + "\n" + (proposal.cardBaseAnswer ?? "") +
                          "\n" + V3L("新答案：") + "\n" + (proposal.cardEditedAnswer ?? ""))
        }
        if proposal.state.noteStatus == .conflict ||
           proposal.state.cardStatus == .conflict {
            pieces.append(V3L("冲突目标的旧批准已失效。请回到最新来源重新核查并创建新提案；已经应用的独立目标不会重放。"))
        }
        if let receipt = proposal.noteReceipt {
            pieces.append("\n" + V3L("笔记回执：") + receipt)
        }
        if let receipt = proposal.cardReceipt {
            pieces.append("\n" + V3L("卡片回执：") + receipt)
        }
        preview.text = pieces.joined(separator: "\n")
        // A source identity alone is not an approved editable draft.
        // Invalid or missing private bytes must disable the note control,
        // while an independently reviewed card may remain approvable.
        noteToggle.isEnabled = proposal.noteIdentity != nil && notePreviewValid &&
            ![.conflict, .applying, .applied, .undoing, .reverted].contains(proposal.state.noteStatus)
        cardToggle.isEnabled = proposal.cardID != nil &&
            ![.conflict, .applying, .applied, .undoing, .reverted].contains(proposal.state.cardStatus)
        let interrupted = proposal.state.noteStatus == .applying ||
            proposal.state.cardStatus == .applying
        reconcileBarItem?.isEnabled = !committing && (interrupted ||
            proposal.state.noteStatus == .undoing ||
            proposal.state.cardStatus == .undoing)
        discardBarItem?.isEnabled = !committing && !interrupted &&
            !proposal.state.needsNoteUndo && !proposal.state.needsCardUndo
        if proposal.state.noteStatus == .applying ||
           proposal.state.cardStatus == .applying ||
           proposal.state.noteStatus == .undoing ||
           proposal.state.cardStatus == .undoing {
            pieces.append(V3L("执行或撤销曾经中断。禁止直接重试；请通过「核查中断」只读回查目标。无法确认的撤销必须保持冻结。"))
            preview.text = pieces.joined(separator: "\n")
        }
        // An interrupted inverse is not a new permission to replay it.
        // Its outcome must first be resolved by read-only reconciliation.
        // F06: an unresolved write/inverse on EITHER target freezes every
        // new inverse. The other target may already be applied, but undoing
        // it before read-only reconciliation would overlap two transactions.
        let hasUnresolvedTransaction =
            [.applying, .undoing].contains(proposal.state.noteStatus) ||
            [.applying, .undoing].contains(proposal.state.cardStatus)
        undoBarItem?.isEnabled = !committing && !hasUnresolvedTransaction && (
            proposal.state.noteStatus == .applied ||
            proposal.state.cardStatus == .applied)
        updateConfirmation()
    }

    @objc private func updateConfirmation() {
        confirm.isEnabled = !committing && !executionConsentPending &&
            proposal.state.noteStatus != .applying &&
            proposal.state.cardStatus != .applying &&
            !proposal.state.needsNoteUndo && !proposal.state.needsCardUndo &&
            ((noteToggle.isOn && noteToggle.isEnabled && notePreviewValid) ||
             (cardToggle.isOn && cardToggle.isEnabled))
    }

    @objc private func confirmChanges() {
        guard !committing, !executionConsentPending, confirm.isEnabled,
              proposal.state.noteStatus != .applying,
              proposal.state.cardStatus != .applying else { return }
        let noteChosen = (noteToggle.isOn && noteToggle.isEnabled && notePreviewValid) ||
            (proposal.state.noteSelected && proposal.state.noteStatus == .applied)
        let cardChosen = (cardToggle.isOn && cardToggle.isEnabled) ||
            (proposal.state.cardSelected && proposal.state.cardStatus == .applied)
        guard noteChosen || cardChosen else { return }
        // Gate repeat taps before UIKit begins presenting the consent sheet.
        // The saved proposal CAS remains the independent durable safeguard.
        executionConsentPending = true
        updateConfirmation()
        // The two selection bits belong to this exact saved proposal, not a
        // mutable UI draft. A new material revision needs a NEW proposal.
        var selected = proposal
        selected.state.noteSelected = noteChosen
        selected.state.cardSelected = cardChosen
        let targets = [
            noteChosen ? ("Vault ID: " + (selected.noteIdentity?.vaultID ?? "") +
                "\n" + V3L("笔记：") + (selected.noteIdentity?.relativePath ?? "")) : nil,
            cardChosen ? (V3L("原卡：") + (selected.cardID?.uuidString ?? "")) : nil
        ].compactMap { $0 }.joined(separator: "\n")
        let consent = UIAlertController(title: V3L("确认这两个目标的所选修改？"),
            message: targets + "\n\n" +
                V3L("只写入明确选择并已授权的 Obsidian Markdown 与原卡；来源冲突时停止覆盖。笔记须有完整差异预览、源文件版本校验、写前恢复副本及写后回读。两个目标分别保存回执，可能部分成功。"),
            preferredStyle: .alert)
        consent.addAction(UIAlertAction(title: V3L("取消"), style: .cancel) {
            [weak self] _ in
            self?.executionConsentPending = false
            self?.updateConfirmation()
        })
        consent.addAction(UIAlertAction(title: V3L("确认执行"), style: .destructive) {
            [weak self] _ in
            guard let self else { return }
            Task {
                await self.execute(selected)
                self.executionConsentPending = false
                self.updateConfirmation()
            }
        })
        present(consent, animated: true)
    }

    private func execute(_ chosen: WCDBV3DuplexProposal) async {
        guard !committing,
              chosen.state.noteStatus != .applying,
              chosen.state.cardStatus != .applying else { return }
        committing = true
        updateConfirmation()
        defer { committing = false; refreshPreview() }
        guard await saveProposal(chosen) else {
            showResult(V3L("回执无法保存"), V3L("未执行任何修改。"))
            return
        }
        proposal = chosen
        if proposal.state.needsNoteAction {
            // Intent recorded before the first side effect. On restart this
            // remains pending and is NEVER auto-replayed.
            proposal.state.noteStatus = .applying
            guard await saveProposal(proposal) else {
                showResult(V3L("笔记状态无法保存"), V3L("未执行文件写入。"))
                return
            }
            do {
                guard let id = proposal.noteIdentity,
                      let draft = try ImVaultPrivateStore.approvedDraft(
                          identity: id, baseDigest: proposal.noteBaseDigest,
                          editedDigest: proposal.noteEditedDigest),
                      ImVaultDiff.summary(base: draft.byteFaithfulBaseText, edited: draft.byteFaithfulEditedText,
                                          maximumLines: 200).complete else {
                    throw ImVaultSyncFailure.conflict
                }
                let qaAuthorized: Bool = await withCheckedContinuation { continuation in
                    ImVaultGuardedWrite.checkQAVaultEligibility(for: id) { result in
                        continuation.resume(returning: (try? result.get()) == true)
                    }
                }
                #if DEBUG
                // F02: explicit Debug-only fault injection refuses an
                // authorized disposable fixture's note write. Card CAS must
                // remain independently permitted after that refusal.
                let faultDenyQACopy = qaAuthorized &&
                    ImpressV11UITestFixture.enabled &&
                    id.vaultID == ImpressV11UITestFixture.vaultID &&
                    ProcessInfo.processInfo.arguments.contains(
                        "-ImpressV11FaultF02DenyNote")
                #else
                let faultDenyQACopy = false
                #endif
                let result: Result<ImVaultCommitOutcome, Error> =
                    await withCheckedContinuation { continuation in
                        ImVaultGuardedWrite.commitAuthorized(
                            draft: draft, userConfirmedDiff: true,
                            deviceQATestCopyConfirmed: qaAuthorized && !faultDenyQACopy) { r in
                                continuation.resume(returning: r)
                            }
                    }
                switch result {
                case .success(let outcome):
                    proposal.state.noteStatus = .applied
                    let receipt = ImVaultWriteReceiptText.present(
                        .success(outcome), testCopy: qaAuthorized)
                    proposal.noteReceipt = receipt.title + " · " + receipt.detail
                    #if DEBUG
                    // Synthetic fixture ONLY. Exercise the real F03 boundary:
                    // coordinated Markdown bytes are already durable, while
                    // WCDB still holds the preceding .applying intent.
                    // Force a genuine process death before saving this receipt;
                    // reboot/reconciliation must never replay the writer.
                    if qaAuthorized && ImpressV11UITestFixture.enabled &&
                       ProcessInfo.processInfo.arguments.contains(
                           "-ImpressV11FaultF03AfterNoteCommit") {
                        NSLog("IMPRESS_FAULT_F03_NOTE_COMMITTED_RECEIPT_UNSAVED")
                        _ = Darwin.kill(Darwin.getpid(), SIGKILL)
                    }
                    #endif
                case .failure(let error):
                    if case ImVaultSyncFailure.conflict = error {
                        proposal.state.noteStatus = .conflict
                    } else {
                        proposal.state.noteStatus = .failed
                    }
                    proposal.noteReceipt = error.localizedDescription
                }
            } catch {
                if case ImVaultSyncFailure.conflict = error {
                    proposal.state.noteStatus = .conflict
                } else {
                    proposal.state.noteStatus = .failed
                }
                proposal.noteReceipt = error.localizedDescription
            }
            guard await saveProposal(proposal) else {
                showResult(V3L("写回回执未能保存"),
                    V3L("文件结果不明，请先检查目标和本机恢复副本；不可重试卡片，避免失配。"))
                return
            }
        }
        if proposal.state.needsCardAction {
            proposal.state.cardStatus = .applying
            guard await saveProposal(proposal) else {
                showResult(V3L("卡片状态无法保存"), V3L("未修改数据库。"))
                return
            }
            do {
                guard let id = proposal.cardID, let original = proposal.cardBaseQuestion,
                      let replacement = proposal.cardEditedQuestion,
                      let revision = proposal.cardContentRevision,
                      let card = try await repository.content(for: id) else {
                    throw ReviewWCDBError.missingCard
                }
                if let note = proposal.noteIdentity {
                    guard let link = card.sourceNotePath,
                          (try? ImpressBatchSourceKey.decode(link)) == note else {
                        throw ImVaultSyncFailure.wrongVault
                    }
                }
                switch ImDuplexCardVersionGate.decide(
                    expectedContentRevision: revision, currentContentRevision: card.contentRevision,
                    baseQuestion: original, baseAnswer: proposal.cardBaseAnswer,
                    proposedQuestion: replacement, proposedAnswer: proposal.cardEditedAnswer,
                    currentQuestion: card.question, currentAnswer: card.answerText) {
                case .unchanged, .alreadyApplied:
                    proposal.state.cardStatus = .applied
                    proposal.cardReceipt = V3L("原卡内容已一致；未重复保存、未评分。")
                case .conflict:
                    proposal.state.cardStatus = .conflict
                    proposal.cardReceipt = V3L("原卡内容已被其他编辑修改，拒绝覆盖。")
                case .safeToWrite:
                    // A legitimate FSRS rating after proposal creation is
                    // independent of card content. Take the CURRENT scheduling
                    // revision for transactional CAS, while the content gate
                    // above still rejects any intervening content edit.
                    guard let queue = try await repository.fetchQueueCandidates()
                            .first(where: { $0.cardID == id }) else {
                        throw ReviewWCDBError.missingCard
                    }
                    #if DEBUG
                    // F01: a legal external card edit wins the real WCDB CAS
                    // AFTER the QA Markdown write, BEFORE this proposed card
                    // update. The original proposal must retain note success,
                    // reject the stale card version and never replay the note.
                    if ImpressV11UITestFixture.enabled,
                       ProcessInfo.processInfo.arguments.contains(
                           "-ImpressV11FaultF01AfterNoteCardConflict"),
                       proposal.state.noteStatus == .applied,
                       let noteIdentity = proposal.noteIdentity,
                       let link = card.sourceNotePath,
                       let sourceID = try? ImpressBatchSourceKey.decode(link),
                       sourceID == noteIdentity,
                       sourceID.vaultID == ImpressV11UITestFixture.vaultID {
                        try await repository.updateManagedCard(
                            WCDBV3CardInput(cardID: id,
                                question: "F01 外部合法内容修改",
                                answerText: card.answerText, choices: card.choices,
                                correctIndices: card.correctIndices, cardType: card.cardType,
                                imageData: card.imageData, sourceNotePath: card.sourceNotePath),
                            expectedRevision: queue.revision,
                            expectedContentRevision: revision, origin: .manual)
                        NSLog("IMPRESS_FAULT_F01_NOTE_APPLIED_CARD_EXTERNAL_CAS")
                    }
                    #endif
                    try await repository.updateManagedCard(
                        WCDBV3CardInput(cardID: id, question: replacement,
                            answerText: proposal.cardEditedAnswer, choices: card.choices,
                            correctIndices: card.correctIndices, cardType: card.cardType,
                            imageData: card.imageData, sourceNotePath: card.sourceNotePath),
                        expectedRevision: queue.revision,
                        expectedContentRevision: revision, origin: .approvedAI)
                    #if DEBUG
                    // F04: on a synthetic source-backed card only, deliberately
                    // terminate after the real WCDB content transaction and
                    // before durable Chat approval receipt. Never injected for
                    // a real user card or in a Release build.
                    if ImpressV11UITestFixture.enabled,
                       ProcessInfo.processInfo.arguments.contains(
                           "-ImpressV11FaultF04AfterCardCommit"),
                       let link = card.sourceNotePath,
                       let sourceID = try? ImpressBatchSourceKey.decode(link),
                       sourceID.vaultID == ImpressV11UITestFixture.vaultID {
                        NSLog("IMPRESS_FAULT_F04_CARD_COMMITTED_RECEIPT_UNSAVED")
                        _ = Darwin.kill(Darwin.getpid(), SIGKILL)
                    }
                    #endif
                    proposal.state.cardStatus = .applied
                    proposal.cardReceipt = V3L("原卡已按确认内容更新；cardID 与 FSRS 历史保留。")
                }
            } catch {
                if case ReviewWCDBError.contentConflict = error {
                    proposal.state.cardStatus = .conflict
                } else if case ReviewWCDBError.revisionConflict = error {
                    proposal.state.cardStatus = .conflict
                } else {
                    proposal.state.cardStatus = .failed
                }
                proposal.cardReceipt = error.localizedDescription
            }
            guard await saveProposal(proposal) else {
                showResult(V3L("卡片回执未能保存"),
                    V3L("请从原卡重新读取当前版本，确认是否已经更新；不可盲目重试。"))
                return
            }
        }
        showResult(proposal.state.completed ? V3L("所选修改已处理") : V3L("存在未完成的修改"),
            (proposal.noteReceipt ?? V3L("笔记未选择")) + "\n\n" +
            (proposal.cardReceipt ?? V3L("原卡未选择")) + "\n\n" +
            V3L("所有回执存于原 Chat 会话；失败目标仅允许再次手动核查后重试。"))
    }

    /// Explicit, read-only adjudication for forward F03/F04 and reverse F06
    /// crash windows. No write path is called here. If current source or
    /// content revision cannot be verified, applying/undoing remains durable
    /// and the interrupted target cannot be replayed.
    @objc private func reconcileInterrupted() {
        guard !committing &&
              (proposal.state.noteStatus == .applying ||
               proposal.state.cardStatus == .applying ||
               proposal.state.noteStatus == .undoing ||
               proposal.state.cardStatus == .undoing) else { return }
        committing = true
        updateConfirmation()
        Task { [weak self] in
            guard let self else { return }
            var result = self.proposal
            if result.state.noteStatus == .applying,
               let id = result.noteIdentity,
               let base = result.noteBaseDigest,
               let proposed = result.noteEditedDigest {
                do {
                    guard let draft = try ImVaultPrivateStore.approvedDraft(
                        identity: id, baseDigest: base, editedDigest: proposed),
                        draft.baseDigest == base,
                        ImVaultDigest.sha256(draft.proposedBytes) == proposed else {
                        throw ImVaultSyncFailure.conflict
                    }
                    let live: ImVaultRawDocument = try await withCheckedThrowingContinuation {
                        (continuation: CheckedContinuation<ImVaultRawDocument, Error>) in
                        ImVaultReadSync.shared.read(id) { response in
                            continuation.resume(with: response)
                        }
                    }
                    guard live.identity == id,
                          live.digest == ImVaultDigest.sha256(live.sourceBytes) else {
                        throw ImVaultSyncFailure.conflict
                    }
                    if let state = ImDuplexInterruptedRecovery.noteStatus(
                        currentDigest: live.digest, baseDigest: base,
                        proposedDigest: proposed) {
                        result.state.noteStatus = state
                        result.noteReceipt = state == .applied
                            ? V3L("中断核查：源文件 SHA 与已批准版本吻合；不重复写入。")
                            : V3L("中断核查：源文件与批准版本不一致；必须重新核对并批准。")
                    }
                } catch {
                    // No receipt fabricated when File Provider permission,
                    // ApprovedDraft or protected recovery bytes are missing.
                }
            }
            if result.state.cardStatus == .applying,
               let id = result.cardID,
               let revision = result.cardContentRevision,
               let base = result.cardBaseQuestion,
               let proposed = result.cardEditedQuestion {
                do {
                    let current = try await self.repository.content(for: id)
                    if let status = ImDuplexInterruptedRecovery.cardStatus(
                        currentContentRevision: current?.contentRevision,
                        expectedContentRevision: revision,
                        baseQuestion: base, baseAnswer: result.cardBaseAnswer,
                        proposedQuestion: proposed, proposedAnswer: result.cardEditedAnswer,
                        currentQuestion: current?.question, currentAnswer: current?.answerText) {
                        result.state.cardStatus = status
                        result.cardReceipt = status == .applied
                            ? V3L("中断核查：原卡内容版本吻合；不生成第二次编辑或评分。")
                            : V3L("中断核查：原卡版本不吻合；拒绝自动重放。")
                    }
                } catch {
                    // Unknown state remains applying and cannot be retried.
                }
            }
            // F06: A process may terminate after inverse storage writes but
            // before the durable inverse receipt. Resolve ONLY verified
            // already-restored targets; never invoke an inverse writer here.
            if result.state.noteStatus == .undoing,
               let id = result.noteIdentity,
               let original = result.noteBaseDigest,
               let approved = result.noteEditedDigest {
                do {
                    guard let draft = try ImVaultPrivateStore.approvedDraft(
                        identity: id, baseDigest: original, editedDigest: approved),
                        draft.baseDigest == original,
                        ImVaultDigest.sha256(draft.proposedBytes) == approved else {
                        throw ImVaultSyncFailure.conflict
                    }
                    let live: ImVaultRawDocument = try await withCheckedThrowingContinuation {
                        (continuation: CheckedContinuation<ImVaultRawDocument, Error>) in
                        ImVaultReadSync.shared.read(id) { outcome in
                            continuation.resume(with: outcome)
                        }
                    }
                    if live.identity == id,
                       live.digest == ImVaultDigest.sha256(live.sourceBytes),
                       ImDuplexInterruptedRecovery.noteUndoStatus(
                           currentDigest: live.digest, approvedDigest: approved,
                           originalDigest: original) == .reverted {
                        result.state.noteStatus = .reverted
                        result.noteReceipt = (result.noteReceipt ?? "") + "\n" +
                            V3L("撤销中断核查：当前源字节与原始 SHA 匹配；没有再次写入，也不代表 iCloud 远端同步。")
                    }
                } catch {
                    // No verified raw-byte identity => leave undoing durable.
                }
            }
            if result.state.cardStatus == .undoing,
               let id = result.cardID,
               let revision = result.cardContentRevision,
               let original = result.cardBaseQuestion,
               let approved = result.cardEditedQuestion {
                do {
                    let card = try await self.repository.content(for: id)
                    if ImDuplexInterruptedRecovery.cardUndoStatus(
                        currentContentRevision: card?.contentRevision,
                        expectedBaseContentRevision: revision,
                        originalQuestion: original, originalAnswer: result.cardBaseAnswer,
                        approvedQuestion: approved, approvedAnswer: result.cardEditedAnswer,
                        currentQuestion: card?.question, currentAnswer: card?.answerText) == .reverted {
                        result.state.cardStatus = .reverted
                        result.cardReceipt = (result.cardReceipt ?? "") + "\n" +
                            V3L("撤销中断核查：原卡内容版本与恢复内容吻合；没有二次修改或 FSRS 评分。")
                    }
                } catch {
                    // Missing card, later human edit, or unreadable WCDB =>
                    // not a verified inverse completion. Keep undoing locked.
                }
            }
            let changed = result.state != self.proposal.state ||
                result.noteReceipt != self.proposal.noteReceipt ||
                result.cardReceipt != self.proposal.cardReceipt
            if changed {
                if await self.saveProposal(result) {
                    self.proposal = result
                }
            }
            self.committing = false
            self.refreshPreview()
            self.showResult(V3L("中断结果已核查"),
                V3L("已核实目标按回执记录；无法验证的目标保留执行中断状态并禁止重试。此操作不执行任何写回。"))
        }
    }

    private enum UndoTarget { case note, card }

    @objc private func openUndoOptions() {
        guard !committing,
              ![.applying, .undoing].contains(proposal.state.noteStatus),
              ![.applying, .undoing].contains(proposal.state.cardStatus) else { return }
        let actions = UIAlertController(title: V3L("撤销已执行的目标"),
            message: V3L("每个目标单独预览、确认及记录回执。不会自动覆盖后续人工编辑。"),
            preferredStyle: .actionSheet)
        if proposal.state.noteStatus == .applied,
           proposal.noteIdentity != nil {
            actions.addAction(UIAlertAction(title: V3L("撤销笔记改动"),
                style: .default) { [weak self] _ in
                Task { await self?.prepareUndo(.note) }
            })
        }
        if proposal.state.cardStatus == .applied,
           proposal.cardID != nil {
            actions.addAction(UIAlertAction(title: V3L("撤销原卡改动"),
                style: .default) { [weak self] _ in
                Task { await self?.prepareUndo(.card) }
            })
        }
        actions.addAction(UIAlertAction(title: V3L("取消"), style: .cancel))
        actions.popoverPresentationController?.barButtonItem = undoBarItem
        present(actions, animated: true)
    }

    private func prepareUndo(_ target: UndoTarget) async {
        guard !committing,
              ![.applying, .undoing].contains(proposal.state.noteStatus),
              ![.applying, .undoing].contains(proposal.state.cardStatus) else { return }
        do {
            let details: String
            switch target {
            case .note:
                guard let id = proposal.noteIdentity,
                      let existing = try ImVaultPrivateStore.approvedDraft(
                          identity: id, baseDigest: proposal.noteBaseDigest,
                          editedDigest: proposal.noteEditedDigest) else {
                    throw ImVaultSyncFailure.conflict
                }
                let inverse = try ImpressDuplexUndoGate.inverseDraft(existing,
                    expectedBaseDigest: proposal.noteBaseDigest,
                    expectedAppliedDigest: proposal.noteEditedDigest)
                let qaEnabled: Bool = await withCheckedContinuation { c in
                    ImVaultGuardedWrite.checkQAVaultEligibility(for: id) { answer in
                        c.resume(returning: (try? answer.get()) == true)
                    }
                }
                guard ImVaultGuardedWrite.productionWriteEnabled || qaEnabled else {
                    throw ImVaultSyncFailure.writesLocked
                }
                let current: ImVaultRawDocument = try await withCheckedThrowingContinuation {
                    (continuation: CheckedContinuation<ImVaultRawDocument, Error>) in
                    ImVaultReadSync.shared.read(id) { outcome in
                        continuation.resume(with: outcome)
                    }
                }
                guard current.identity == id else { throw ImVaultSyncFailure.wrongVault }
                let decision = inverse.decision(against: current.sourceBytes)
                guard decision == .safeToWrite || decision == .alreadyApplied else {
                    throw ImVaultSyncFailure.conflict
                }
                let diff = ImVaultDiff.summary(
                    base: inverse.byteFaithfulBaseText, edited: inverse.byteFaithfulEditedText, maximumLines: 200)
                guard diff.complete else { throw ImVaultSyncFailure.previewTruncated }
                details = V3L("撤销笔记改动") + "\nVault ID: " + id.vaultID +
                    "\n" + id.relativePath +
                    "\nExpected SHA-256: " + (proposal.noteEditedDigest ?? "?") +
                    "\n" + V3L("目标恢复 SHA-256：") + (proposal.noteBaseDigest ?? "?") +
                    "\n\n" + diff.text
            case .card:
                guard let id = proposal.cardID,
                      let oldRevision = proposal.cardContentRevision,
                      let card = try await repository.content(for: id),
                      let revised = proposal.cardEditedQuestion,
                      let original = proposal.cardBaseQuestion else {
                    throw ReviewWCDBError.missingCard
                }
                let decision = ImDuplexCardVersionGate.decide(
                    expectedContentRevision: oldRevision + 1,
                    currentContentRevision: card.contentRevision,
                    baseQuestion: revised, baseAnswer: proposal.cardEditedAnswer,
                    proposedQuestion: original, proposedAnswer: proposal.cardBaseAnswer,
                    currentQuestion: card.question, currentAnswer: card.answerText)
                guard decision == .safeToWrite || decision == .alreadyApplied else {
                    throw ReviewWCDBError.contentConflict
                }
                details = V3L("撤销原卡改动") + "\ncardID: " + id.uuidString +
                    "\nContent revision: " + String(oldRevision + 1) +
                    "\n\n" + V3L("原题目：") + revised +
                    "\n\n" + V3L("恢复题目：") + original +
                    "\n\n" + V3L("原答案：") + (proposal.cardEditedAnswer ?? "") +
                    "\n\n" + V3L("恢复答案：") + (proposal.cardBaseAnswer ?? "")
            }
            let page = ImpressDuplexUndoReviewController(content: details) { [weak self] in
                guard let self else { return .failure(WCDBV3ChatStorageError.invalidRecord) }
                do {
                    return .success(try await self.executeUndo(target))
                } catch { return .failure(error) }
            }
            navigationController?.pushViewController(page, animated: true)
        } catch {
            showResult(V3L("无法安全撤销"), error.localizedDescription)
        }
    }

    private func executeUndo(_ target: UndoTarget) async throws -> String {
        guard !committing,
              ![.applying, .undoing].contains(proposal.state.noteStatus),
              ![.applying, .undoing].contains(proposal.state.cardStatus) else {
            throw WCDBV3ChatStorageError.conflict
        }
        committing = true
        updateConfirmation()
        defer {
            committing = false
            refreshPreview()
        }
        // A persisted .undoing is not a valid second user approval after a
        // crash. Only .applied may begin a new, freshly previewed inverse.
        switch target {
        case .note:
            guard proposal.state.noteStatus == .applied,
                  let id = proposal.noteIdentity,
                  let existing = try ImVaultPrivateStore.approvedDraft(
                      identity: id, baseDigest: proposal.noteBaseDigest,
                      editedDigest: proposal.noteEditedDigest) else {
                throw ImVaultSyncFailure.conflict
            }
            let inverse = try ImpressDuplexUndoGate.inverseDraft(existing,
                expectedBaseDigest: proposal.noteBaseDigest,
                expectedAppliedDigest: proposal.noteEditedDigest)
            let qaCopy: Bool = await withCheckedContinuation { c in
                ImVaultGuardedWrite.checkQAVaultEligibility(for: id) { response in
                    c.resume(returning: (try? response.get()) == true)
                }
            }
            // Do not persist an undo intent when no authorized source
            // target is available. No source change is authorized by a stale proposal.
            guard ImVaultGuardedWrite.productionWriteEnabled || qaCopy else {
                throw ImVaultSyncFailure.writesLocked
            }
            // F08: a newer legal note edit between visible inverse Diff and
            // confirmation is not an interrupted undo. Re-read the authorized
            // source before writing the durable inverse intent. commitAuthorized
            // still performs the decisive coordinated byte CAS after this read.
            let currentNote: ImVaultRawDocument = try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<ImVaultRawDocument, Error>) in
                ImVaultReadSync.shared.read(id) { result in
                    continuation.resume(with: result)
                }
            }
            try ImpressDuplexUndoGate.requireFreshNotePreflight(inverse,
                identity: currentNote.identity, bytes: currentNote.sourceBytes)
            if proposal.state.noteStatus != .undoing {
                var starting = proposal
                starting.state.noteStatus = .undoing
                guard await saveProposal(starting) else {
                    throw WCDBV3ChatStorageError.conflict
                }
                proposal = starting
            }
            do {
                let result: Result<ImVaultCommitOutcome, Error> =
                    await withCheckedContinuation { c in
                        ImVaultGuardedWrite.commitAuthorized(
                            draft: inverse, userConfirmedDiff: true,
                            deviceQATestCopyConfirmed: qaCopy) { result in
                                c.resume(returning: result)
                            }
                    }
                let outcome = try result.get()
                #if DEBUG
                // F06 note inverse: deliberately die only after the actual
                // isolated QA source's original bytes are durable and before
                // the pending .undoing receipt is saved. A reopen must check
                // SHA in read-only reconciliation and must not replay writer.
                if qaCopy && ImpressV11UITestFixture.enabled &&
                   ProcessInfo.processInfo.arguments.contains(
                       "-ImpressV11FaultF06AfterNoteUndo"),
                   id.vaultID == ImpressV11UITestFixture.vaultID,
                   case .written = outcome {
                    NSLog("IMPRESS_FAULT_F06_NOTE_UNDONE_RECEIPT_UNSAVED")
                    _ = Darwin.kill(Darwin.getpid(), SIGKILL)
                }
                #endif
                guard case .unchanged = outcome else {
                    var completed = proposal
                    completed.state.noteStatus = .reverted
                    completed.noteReceipt = (completed.noteReceipt ?? "") +
                        "\n" + V3L("已按版本校验撤销笔记；本机字节回读，不代表 iCloud 远端同步。")
                    guard await saveProposal(completed) else {
                        throw WCDBV3ChatStorageError.conflict
                    }
                    proposal = completed
                    return completed.noteReceipt ?? ""
                }
                throw ImVaultSyncFailure.verificationFailed
            } catch {
                // Undo intent is durable. Do not auto-replay it after restart.
                var failed = proposal
                failed.noteReceipt = (failed.noteReceipt ?? "") +
                    "\n" + V3L("撤销待核查：") + error.localizedDescription
                if await saveProposal(failed) { proposal = failed }
                throw error
            }
        case .card:
            guard proposal.state.cardStatus == .applied,
                  let id = proposal.cardID, let revision = proposal.cardContentRevision,
                  let revised = proposal.cardEditedQuestion,
                  let original = proposal.cardBaseQuestion else {
                throw ReviewWCDBError.missingCard
            }
            // F08: reject a subsequent legitimate card edit before recording
            // .undoing. The later repository CAS still protects a race between
            // this preflight read and the actual inverse content transaction.
            guard let preflightCard = try await repository.content(for: id) else {
                throw ReviewWCDBError.missingCard
            }
            try ImpressDuplexUndoGate.requireFreshCardPreflight(
                expectedContentRevision: revision + 1,
                currentContentRevision: preflightCard.contentRevision,
                appliedQuestion: revised, appliedAnswer: proposal.cardEditedAnswer,
                originalQuestion: original, originalAnswer: proposal.cardBaseAnswer,
                currentQuestion: preflightCard.question,
                currentAnswer: preflightCard.answerText)
            if proposal.state.cardStatus != .undoing {
                var starting = proposal
                starting.state.cardStatus = .undoing
                guard await saveProposal(starting) else { throw WCDBV3ChatStorageError.conflict }
                proposal = starting
            }
            do {
                guard let current = try await repository.content(for: id) else {
                    throw ReviewWCDBError.missingCard
                }
                switch ImDuplexCardVersionGate.decide(
                    expectedContentRevision: revision + 1,
                    currentContentRevision: current.contentRevision,
                    baseQuestion: revised, baseAnswer: proposal.cardEditedAnswer,
                    proposedQuestion: original, proposedAnswer: proposal.cardBaseAnswer,
                    currentQuestion: current.question, currentAnswer: current.answerText) {
                case .conflict, .unchanged:
                    throw ReviewWCDBError.contentConflict
                case .alreadyApplied:
                    break
                case .safeToWrite:
                    guard let queue = try await repository.fetchQueueCandidates()
                        .first(where: { $0.cardID == id }) else {
                        throw ReviewWCDBError.missingCard
                    }
                    // Use the CURRENT FSRS revision for CAS: a review between
                    // original approval and undo must NOT reset the scheduler.
                    try await repository.updateManagedCard(
                        WCDBV3CardInput(cardID: id, question: original,
                            answerText: proposal.cardBaseAnswer, choices: current.choices,
                            correctIndices: current.correctIndices, cardType: current.cardType,
                            imageData: current.imageData, sourceNotePath: current.sourceNotePath),
                        expectedRevision: queue.revision,
                        expectedContentRevision: revision + 1, origin: .restored)
                    #if DEBUG
                    // F06 inverse crash window: only a synthetic fixture card.
                    // The restored WCDB content is durable but the .undoing
                    // intent has not yet received its Chat receipt. Reboot
                    // must verify revision+2 without a second inverse write.
                    if ImpressV11UITestFixture.enabled,
                       ProcessInfo.processInfo.arguments.contains(
                           "-ImpressV11FaultF06AfterCardUndo"),
                       let link = current.sourceNotePath,
                       let sourceID = try? ImpressBatchSourceKey.decode(link),
                       sourceID.vaultID == ImpressV11UITestFixture.vaultID {
                        NSLog("IMPRESS_FAULT_F06_CARD_UNDONE_RECEIPT_UNSAVED")
                        _ = Darwin.kill(Darwin.getpid(), SIGKILL)
                    }
                    #endif
                }
                var completed = proposal
                completed.state.cardStatus = .reverted
                completed.cardReceipt = (completed.cardReceipt ?? "") +
                    "\n" + V3L("原卡已安全恢复旧内容；cardID、FSRS 评分和中间内容版本均保留。")
                guard await saveProposal(completed) else { throw WCDBV3ChatStorageError.conflict }
                proposal = completed
                return completed.cardReceipt ?? ""
            } catch {
                var failed = proposal
                failed.cardReceipt = (failed.cardReceipt ?? "") +
                    "\n" + V3L("撤销待核查：") + error.localizedDescription
                if await saveProposal(failed) { proposal = failed }
                throw error
            }
        }
    }

    private func showResult(_ name: String, _ message: String) {
        let alert = UIAlertController(title: name, message: message,
                                      preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: V3L("确定"), style: .default))
        present(alert, animated: true)
    }
}


// MARK: - V1.1 AI-response-to-exact-source-range draft proposal

/// This helper never writes an Obsidian source. It constructs a private draft
/// only after the caller selected one authenticated file + original section.
/// Real file writes still require the independent production-disabled gate.
@MainActor
enum ImpressDuplexScopedDraftBuilder {
    static func proposed(live: ImVaultRawDocument,
                         section: ImpressMarkdownSection,
                         replacement: String) throws -> ImVaultDraft {
        guard live.identity.documentFormat == .markdown,
              live.digest == ImVaultDigest.sha256(live.sourceBytes),
              String(data: live.sourceBytes, encoding: .utf8) == live.markdown,
              section.startUTF8 >= 0, section.endUTF8 > section.startUTF8,
              section.endUTF8 <= live.sourceBytes.count,
              ImpressMarkdownStructure.sections(in: live.markdown).contains(where: {
                  $0.id == section.id && $0.startUTF8 == section.startUTF8 &&
                  $0.endUTF8 == section.endUTF8 && $0.rawUTF8 == section.rawUTF8
              }) else { throw ImVaultSyncFailure.conflict }
        let bytes = Array(live.sourceBytes)
        let raw = Array(section.rawUTF8.utf8)
        // Foundation decodes and removes a file's UTF-8 BOM, while
        // structured section positions are relative to the decoded Markdown.
        // Shift to original-file byte positions for the scoped CAS draft.
        let bomLength = live.sourceBytes.starts(with: [0xEF, 0xBB, 0xBF]) ? 3 : 0
        let fileStart = section.startUTF8 + bomLength
        let fileEnd = section.endUTF8 + bomLength
        guard fileStart >= bomLength, fileEnd <= bytes.count,
              Array(bytes[fileStart..<fileEnd]) == raw else {
            throw ImVaultSyncFailure.conflict
        }
        var changed = Data(bytes[..<fileStart])
        changed.append(contentsOf: replacement.utf8)
        changed.append(contentsOf: bytes[fileEnd...])
        guard changed.count <= 8 * 1024 * 1024,
              let value = String(data: changed, encoding: .utf8) else {
            throw ImVaultSyncFailure.tooLarge
        }
        var draft = try ImVaultDraft(identity: live.identity,
            baseText: live.markdown, baseRawData: live.sourceBytes)
        // An original BOM belongs to the file byte prefix, never to the
        // UITextView replacement payload. The shared draft writer restores
        // exactly one BOM and does not normalize mixed newlines invisibly.
        let edited = value // String(data:) already strips a UTF-8 BOM.
        try draft.update(edited)
        try draft.validate()
        guard draft.hasChanges else { throw ImVaultSyncFailure.approvalMissing }
        guard ImVaultDiff.summary(base: draft.byteFaithfulBaseText,
            edited: draft.byteFaithfulEditedText, maximumLines: 200).complete else {
            throw ImVaultSyncFailure.previewTruncated
        }
        return draft
    }
}

@MainActor
final class ImpressDuplexNoteSectionTargetController: UITableViewController {
    private let live: ImVaultRawDocument
    private let proposedText: String
    private let sections: [ImpressMarkdownSection]
    private let onSaved: () -> Void

    init(live: ImVaultRawDocument, proposedText: String,
         onSaved: @escaping () -> Void) {
        self.live = live
        self.proposedText = proposedText
        self.sections = ImpressMarkdownStructure.sections(in: live.markdown)
        self.onSaved = onSaved
        super.init(style: .insetGrouped)
    }
    required init?(coder: NSCoder) { fatalError("init(live:) unsupported") }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = V3L("选择原笔记的目标章节")
        tableView.backgroundColor = ImpressV3Appearance.page
        tableView.accessibilityIdentifier = "impress.duplex.note-section-picker"
    }

    override func tableView(_ tableView: UITableView,
                            numberOfRowsInSection section: Int) -> Int {
        sections.count
    }

    override func tableView(_ tableView: UITableView,
                            cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let section = sections[indexPath.row]
        let cell = UITableViewCell(style: .subtitle, reuseIdentifier: nil)
        var content = UIListContentConfiguration.subtitleCell()
        content.text = String(repeating: "  ", count: max(0, section.level - 1)) +
            (section.heading.isEmpty ? V3L("无标题段落") : section.heading)
        content.secondaryText = String(section.byteCount) + " bytes · " +
            String(section.startUTF8) + "–" + String(section.endUTF8)
        cell.contentConfiguration = content
        cell.accessoryType = .disclosureIndicator
        cell.accessibilityIdentifier = "impress.duplex.note-section-row"
        return cell
    }

    override func tableView(_ tableView: UITableView,
                            didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        guard sections.indices.contains(indexPath.row) else { return }
        let page = ImpressDuplexNoteReplacementController(
            live: live, section: sections[indexPath.row],
            proposedText: proposedText, onSaved: onSaved)
        navigationController?.pushViewController(page, animated: true)
    }
}

@MainActor
final class ImpressDuplexNoteReplacementController: UIViewController {
    private let live: ImVaultRawDocument
    private let section: ImpressMarkdownSection
    private let onSaved: () -> Void
    private let editor = UITextView()
    private let original = UITextView()

    init(live: ImVaultRawDocument, section: ImpressMarkdownSection,
         proposedText: String, onSaved: @escaping () -> Void) {
        self.live = live
        self.section = section
        self.onSaved = onSaved
        super.init(nibName: nil, bundle: nil)
        // Preserve the original section's trailing line boundary visibly in
        // the editable proposal; otherwise the following heading may join
        // the suggestion into an unintended paragraph.
        let suffix = section.rawUTF8.hasSuffix("\r\n") ? "\r\n" :
            (section.rawUTF8.hasSuffix("\n") ? "\n" :
             (section.rawUTF8.hasSuffix("\r") ? "\r" : ""))
        editor.text = suffix.isEmpty || proposedText.hasSuffix(suffix)
            ? proposedText : proposedText + suffix
    }
    required init?(coder: NSCoder) { fatalError("init(live:section:) unsupported") }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = V3L("核对原文与局部建议")
        view.backgroundColor = ImpressV3Appearance.page

        let scroll = UIScrollView()
        let stack = UIStackView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.axis = .vertical
        stack.spacing = ImpressV3Appearance.Metrics.rowSpacing
        stack.isLayoutMarginsRelativeArrangement = true
        stack.directionalLayoutMargins = NSDirectionalEdgeInsets(
            top: 14, leading: 16, bottom: 24, trailing: 16)

        original.isEditable = false
        original.isSelectable = true
        original.text = section.rawUTF8
        original.accessibilityIdentifier = "impress.duplex.section-original"
        editor.accessibilityIdentifier = "impress.duplex.section-replacement"
        editor.isEditable = true
        for field in [original, editor] {
            field.font = ImpressV3Appearance.Typography.body
            field.adjustsFontForContentSizeCategory = true
            field.backgroundColor = ImpressV3Appearance.surface
            field.textColor = ImpressV3Appearance.primaryText
            field.layer.cornerRadius = ImpressV3Appearance.Radius.field
            field.heightAnchor.constraint(equalToConstant: 190).isActive = true
        }
        ImpressSpeechAccessory.install(on: editor)
        func info(_ text: String) -> UILabel {
            let label = UILabel()
            label.font = ImpressV3Appearance.Typography.supporting
            label.numberOfLines = 0
            label.adjustsFontForContentSizeCategory = true
            label.textColor = ImpressV3Appearance.secondaryText
            label.text = text
            return label
        }
        stack.addArrangedSubview(info("Vault ID: " + live.identity.vaultID +
            "\n" + live.identity.relativePath + "\nSHA-256: " + live.digest +
            "\nUTF-8: " + String(section.startUTF8) + "–" + String(section.endUTF8)))
        stack.addArrangedSubview(info(V3L("原文范围 · 只读")))
        stack.addArrangedSubview(original)
        stack.addArrangedSubview(info(V3L("建议替换文本 · 可编辑；不会直接写入 Vault")))
        stack.addArrangedSubview(editor)
        view.addSubview(scroll)
        scroll.addSubview(stack)
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            scroll.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            stack.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor),
            stack.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor),
            stack.widthAnchor.constraint(equalTo: scroll.frameLayoutGuide.widthAnchor)
        ])
        navigationItem.rightBarButtonItem = UIBarButtonItem(
            title: V3L("预览并保存私有草稿"),
            style: .plain, target: self, action: #selector(saveScopedDraft))
        navigationItem.rightBarButtonItem?.accessibilityIdentifier =
            "impress.duplex.save-section-draft"
    }

    @objc private func saveScopedDraft() {
        let proposal = editor.text ?? ""
        // Resolve another coordinated read before constructing any draft:
        // stale note sections cannot overwrite new legitimate Vault edits.
        ImVaultReadSync.shared.read(live.identity) { [weak self] result in
            guard let self else { return }
            do {
                let current = try result.get()
                guard current.identity == self.live.identity,
                      current.digest == self.live.digest,
                      ImVaultReadOnlyProbe.shared.authorizedVaultID ==
                          current.identity.vaultID else {
                    throw ImVaultSyncFailure.conflict
                }
                if let existing = try ImVaultPrivateStore.loadDraft(
                    identity: current.identity), existing.hasChanges {
                    throw ImVaultSyncFailure.conflict
                }
                let draft = try ImpressDuplexScopedDraftBuilder.proposed(
                    live: current, section: self.section, replacement: proposal)
                try ImVaultPrivateStore.saveDraft(draft)
                guard let persisted = try ImVaultPrivateStore.loadDraft(
                    identity: current.identity),
                      persisted.baseDigest == draft.baseDigest,
                      persisted.proposedBytes == draft.proposedBytes else {
                    throw ImVaultSyncFailure.verificationFailed
                }
                self.onSaved()
            } catch {
                let alert = UIAlertController(title: V3L("无法保存局部草稿"),
                    message: error.localizedDescription,
                    preferredStyle: .alert)
                alert.addAction(UIAlertAction(title: V3L("确定"), style: .default))
                self.present(alert, animated: true)
            }
        }
    }
}
