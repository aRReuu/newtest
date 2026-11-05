import UIKit
import ImpressReviewCore

/// V3-only management surface. Reviews still use SwipeCardStack/FSRS;
/// this page owns explicit CRUD actions on the same WCDB actor.
@MainActor
final class ImpressV3CardCollectionViewController: UITableViewController, UISearchResultsUpdating {
    var onMutation: (() -> Void)?

    private let repository: ReviewWCDBRepository
    private let sourceIdentity: ImVaultFileIdentity?
    private let searchController = UISearchController(searchResultsController: nil)
    private var cards: [WCDBV3ManagedCard] = []
    private var generation = 0
    private var loading = false
    private var hasMore = true
    private let pageSize = 80

    init(repository: ReviewWCDBRepository, sourceIdentity: ImVaultFileIdentity? = nil) {
        self.repository = repository
        self.sourceIdentity = sourceIdentity
        super.init(style: .insetGrouped)
    }
    required init?(coder: NSCoder) { fatalError("init(repository:) required") }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = sourceIdentity == nil ? V3L("卡片集") : V3L("关联卡片")
        navigationItem.largeTitleDisplayMode = .always
        tableView.backgroundColor = ImpressV3Appearance.page
        tableView.rowHeight = UITableView.automaticDimension
        tableView.estimatedRowHeight = 72

        searchController.searchBar.placeholder = V3L("搜索问题、答案、来源")
        searchController.searchResultsUpdater = self
        searchController.obscuresBackgroundDuringPresentation = false
        navigationItem.searchController = searchController
        navigationItem.hidesSearchBarWhenScrolling = false
        definesPresentationContext = true
        let create = UIAction(title: V3L("新建卡片"),
                              image: UIImage(systemName: "square.and.pencil")) { [weak self] _ in
            self?.createCard()
        }
        let batch = UIAction(title: V3L("批量导入"),
                             image: UIImage(systemName: "square.stack.3d.up")) { [weak self] _ in
            self?.startBatchImport()
        }
        let history = UIAction(title: V3L("理解记录"),
                               image: UIImage(systemName: "clock.arrow.circlepath")) { [weak self] _ in
            guard let self else { return }
            self.navigationController?.pushViewController(
                ImpressV3TimelineViewController(cardID: nil, repository: self.repository),
                animated: true)
        }
        navigationItem.rightBarButtonItem = UIBarButtonItem(
            image: UIImage(systemName: "plus"), menu: UIMenu(children: [create, batch, history]))
        navigationItem.rightBarButtonItem?.accessibilityLabel = V3L("卡片管理")
        navigationItem.rightBarButtonItem?.tintColor = ImpressV3Appearance.navigationActionInk
        reloadCards()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        // A returned editor may have changed content; never show a stale row.
        if isViewLoaded { reloadCards() }
    }

    func updateSearchResults(for searchController: UISearchController) {
        reloadCards()
    }

    private func reloadCards() {
        generation += 1
        loading = false
        hasMore = true
        cards.removeAll()
        tableView.reloadData()
        loadMore()
    }

    private func loadMore() {
        guard !loading, hasMore else { return }
        loading = true
        let ticket = generation
        let offset = cards.count
        let query = searchController.searchBar.text ?? ""
        Task { [weak self] in
            guard let self else { return }
            do {
                let next: [WCDBV3ManagedCard]
                if let source = self.sourceIdentity {
                    next = try await self.repository.listRelatedCards(
                        for: source, matching: query, offset: offset, limit: pageSize)
                } else {
                    next = try await self.repository.listManagedCards(
                        matching: query, offset: offset, limit: pageSize)
                }
                guard ticket == generation else { return }
                loading = false
                hasMore = next.count == pageSize
                cards.append(contentsOf: next)
                tableView.reloadData()
                updateEmptyView()
            } catch {
                guard ticket == generation else { return }
                loading = false
                hasMore = false
                showError(error)
                updateEmptyView()
            }
        }
    }

    private func updateEmptyView() {
        guard cards.isEmpty && !loading else {
            tableView.backgroundView = nil
            return
        }
        let label = UILabel()
        label.text = searchController.searchBar.text?.isEmpty == false
            ? V3L("没有找到匹配的卡片")
            : (sourceIdentity == nil
                ? V3L("暂无卡片，点击右上角新建")
                : V3L("这篇笔记暂时没有已确认关联的卡片"))
        label.textColor = ImpressV3Appearance.secondaryText
        label.textAlignment = .center
        label.font = ImpressV3Appearance.Typography.supporting
        label.numberOfLines = 0
        tableView.backgroundView = label
    }

    override func tableView(_ tableView: UITableView,
                            numberOfRowsInSection section: Int) -> Int {
        cards.count
    }

    override func tableView(_ tableView: UITableView,
                            cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let item = cards[indexPath.row]
        let cell = tableView.dequeueReusableCell(withIdentifier: "managed-card")
            ?? UITableViewCell(style: .subtitle, reuseIdentifier: "managed-card")
        var content = UIListContentConfiguration.subtitleCell()
        content.text = item.question
        let kind: String
        let symbol: String
        switch item.cardType {
        case CardType.multipleChoice.rawValue:
            kind = V3L("选择题"); symbol = "list.bullet.rectangle"
        case CardType.image.rawValue:
            kind = V3L("图片"); symbol = "photo"
        default:
            kind = V3L("问答"); symbol = "text.book.closed"
        }
        let status = item.isSuspended ? V3L("已暂停") : V3L("参与复习")
        let source = item.sourceNotePath.flatMap { try? ImpressBatchSourceKey.decode($0) }
        content.secondaryText = [kind, status, source?.relativePath ?? item.sourceNotePath]
            .compactMap { $0 }.joined(separator: " · ")
        content.textProperties.numberOfLines = 2
        content.secondaryTextProperties.numberOfLines = 2
        content.image = UIImage(systemName: symbol)
        content.imageProperties.tintColor = ImpressV3Appearance.secondaryText
        cell.contentConfiguration = content
        cell.accessoryType = .disclosureIndicator
        ImpressV3Appearance.styleGroupedCell(cell)
        return cell
    }

    override func tableView(_ tableView: UITableView,
                            willDisplay cell: UITableViewCell,
                            forRowAt indexPath: IndexPath) {
        if indexPath.row >= cards.count - 8 { loadMore() }
    }

    override func tableView(_ tableView: UITableView,
                            didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        guard cards.indices.contains(indexPath.row) else { return }
        editCard(cards[indexPath.row])
    }

    override func tableView(_ tableView: UITableView,
                            contextMenuConfigurationForRowAt indexPath: IndexPath,
                            point: CGPoint) -> UIContextMenuConfiguration? {
        guard cards.indices.contains(indexPath.row) else { return nil }
        let card = cards[indexPath.row]
        return UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { [weak self] _ in
            let timeline = UIAction(title: V3L("查看理解与复习历史"),
                          image: UIImage(systemName: "clock")) { [weak self] _ in
                guard let self else { return }
                self.navigationController?.pushViewController(
                    ImpressV3TimelineViewController(cardID: card.cardID, repository: self.repository),
                    animated: true)
            }
            let edit = UIAction(title: V3L("编辑卡片"),
                         image: UIImage(systemName: "square.and.pencil")) { [weak self] _ in
                self?.editCard(card)
            }
            var actions = [timeline, edit]
            if let raw = card.sourceNotePath,
               let source = try? ImpressBatchSourceKey.decode(raw) {
                let expectedDigest = try? ImpressBatchSourceKey.documentDigest(for: raw)
                actions.append(UIAction(title: V3L("打开来源笔记"),
                    image: UIImage(systemName: "doc.text")) { [weak self] _ in
                    self?.openLinkedNote(source, expectedDigest: expectedDigest)
                })
            }
            return UIMenu(children: actions)
        }
    }

    private func openLinkedNote(_ identity: ImVaultFileIdentity,
                                expectedDigest: String?) {
        // Do not infer a Vault from a title or cross an expired permission.
        guard ImVaultReadOnlyProbe.shared.authorizedVaultID == identity.vaultID else {
            showLinkedNoteProblem(V3L("来源 Vault 未授权，无法打开原笔记。"))
            return
        }
        ImVaultReadSync.shared.read(identity) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let source):
                guard source.identity == identity else {
                    self.showLinkedNoteProblem(V3L("来源身份不匹配，请刷新 Vault 授权。"))
                    return
                }
                if let expectedDigest, source.digest != expectedDigest {
                    // Path may have been replaced or its contents legitimately
                    // edited. Do NOT claim that the old card is now incorrect.
                    let alert = UIAlertController(title: V3L("来源笔记已变化"),
                        message: V3L("当前内容与生成卡片时的文档版本不同。仅供手动核查；不会自动更新或覆盖原卡。"),
                        preferredStyle: .alert)
                    alert.addAction(UIAlertAction(title: V3L("取消"), style: .cancel))
                    alert.addAction(UIAlertAction(title: V3L("只读查看"), style: .default) { _ in
                        self.navigationController?.pushViewController(
                            ImVaultDocumentController(document: source), animated: true)
                    })
                    self.present(alert, animated: true)
                } else {
                    self.navigationController?.pushViewController(
                        ImVaultDocumentController(document: source), animated: true)
                }
            case .failure(let error):
                self.showLinkedNoteProblem(error.localizedDescription)
            }
        }
    }

    private func showLinkedNoteProblem(_ detail: String) {
        let alert = UIAlertController(title: V3L("来源笔记不可用"),
            message: detail, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: V3L("确定"), style: .default))
        present(alert, animated: true)
    }

    private func startBatchImport() {
        let importVC = ImpressV3BatchImportViewController()
        importVC.onCommit = { [weak self] inputs in
            guard let self else { throw CocoaError(.userCancelled) }
            let now = Date()
            let calculator = FSRS6ReviewCalculator()
            let entries = try inputs.map { input in
                (input: input, initial: try calculator.newCardSnapshot(id: input.cardID, now: now))
            }
            _ = try await self.repository.insertBatchCards(entries, now: now)
            self.onMutation?()
            self.reloadCards()
        }
        let navigation = ImNavigationViewController(rootViewController: importVC)
        navigation.modalPresentationStyle = .pageSheet
        navigation.sheetPresentationController?.detents = [.large()]
        present(navigation, animated: true)
    }

    @objc private func createCard() {
        let composer = ImpressV3CardComposerViewController()
        composer.onSave = { [weak self] input in
            guard let self else { throw CocoaError(.userCancelled) }
            let now = Date()
            let initial = try FSRS6ReviewCalculator().newCardSnapshot(
                id: input.cardID, now: now)
            try await self.repository.insertNewCard(input, initial: initial, now: now)
            self.onMutation?()
            self.reloadCards()
        }
        composer.onSaveVideo = { [weak self] input, stage in
            guard let self else { throw CocoaError(.userCancelled) }
            try await self.commitVideo(input: input, stage: stage)
        }
        showComposer(composer)
    }

    private func commitVideo(
        input: WCDBV3CardInput,
        stage: ImpressCardVideoAVFoundationExporter.Staged,
        expectedReviewRevision: Int? = nil,
        expectedContentRevision: Int? = nil
    ) async throws {
        try await repository.commitCardVideo(input, staged: stage,
            expectedReviewRevision: expectedReviewRevision,
            expectedContentRevision: expectedContentRevision)
        onMutation?()
        reloadCards()
    }

    private func editCard(_ item: WCDBV3ManagedCard) {
        Task { [weak self] in
            guard let self else { return }
            do {
                guard let stored = try await self.repository.content(for: item.cardID) else {
                    throw ReviewWCDBError.missingCard
                }
                let selections = Set((stored.correctIndices ?? "")
                    .split(separator: ",").compactMap { Int($0) })
                let choices: [ImpressV3CardDraft.Choice] =
                    (stored.choices ?? "").isEmpty
                    ? [ImpressV3CardDraft.Choice(), ImpressV3CardDraft.Choice()]
                    : (stored.choices ?? "").components(separatedBy: "\n")
                        .enumerated().map { index, value in
                            ImpressV3CardDraft.Choice(
                                text: value, isCorrect: selections.contains(index))
                        }
                let draft = ImpressV3CardDraft(
                    kind: CardType(rawValue: stored.cardType) ?? .standard,
                    question: stored.question,
                    answer: stored.answerText ?? "",
                    choices: choices,
                    allowsMultipleCorrect: selections.count > 1,
                    imageData: stored.imageData,
                    sourceNotePath: stored.sourceNotePath)
                let editor = ImpressV3CardComposerViewController(
                    draft: draft, editingCardID: item.cardID,
                    expectedContentRevision: stored.contentRevision,
                    editingHasVideo: stored.videoReference != nil)
                editor.onSave = { [weak self] input in
                    guard let self else { throw CocoaError(.userCancelled) }
                    try await self.repository.updateManagedCard(
                        input, expectedRevision: item.revision,
                        expectedContentRevision: stored.contentRevision)
                    self.onMutation?()
                    self.reloadCards()
                }
                editor.onRemoveVideo = { [weak self] input in
                    guard let self else { throw CocoaError(.userCancelled) }
                    try await self.repository.updateManagedCard(
                        input, expectedRevision: item.revision,
                        expectedContentRevision: stored.contentRevision,
                        videoMutation: .remove)
                    self.onMutation?()
                    self.reloadCards()
                }
                editor.onSaveVideo = { [weak self] input, stage in
                    guard let self else { throw CocoaError(.userCancelled) }
                    try await self.commitVideo(input: input, stage: stage,
                        expectedReviewRevision: item.revision,
                        expectedContentRevision: stored.contentRevision)
                }
                editor.onOpenContentHistory = { [weak self, weak editor] in
                    editor?.dismiss(animated: true) {
                        guard let self else { return }
                        let page = ImpressV3CardVersionHistoryViewController(
                            cardID: item.cardID, expectedReviewRevision: item.revision,
                            repository: self.repository)
                        page.onRestored = { [weak self] _ in
                            self?.onMutation?()
                            self?.reloadCards()
                        }
                        self.navigationController?.pushViewController(page, animated: true)
                    }
                }
                showComposer(editor)
            } catch { self.showError(error) }
        }
    }

    private func showComposer(_ composer: ImpressV3CardComposerViewController) {
        let navigation = ImNavigationViewController(rootViewController: composer)
        navigation.modalPresentationStyle = .pageSheet
        if #available(iOS 15.0, *) {
            navigation.sheetPresentationController?.detents = [.large()]
        }
        present(navigation, animated: true)
    }

    private func changeSuspension(_ item: WCDBV3ManagedCard) {
        Task { [weak self] in
            guard let self else { return }
            do {
                try await self.repository.setManagedCardSuspended(
                    !item.isSuspended, id: item.cardID,
                    expectedRevision: item.revision)
                self.onMutation?()
                self.reloadCards()
            } catch { self.showError(error) }
        }
    }

    private func confirmDelete(_ item: WCDBV3ManagedCard) {
        let alert = UIAlertController(
            title: V3L("永久删除卡片？"),
            message: V3L("这将同时删除该卡片的 FSRS 复习事件。外部 Obsidian 原始笔记不会被修改。"),
            preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: V3L("取消"), style: .cancel))
        alert.addAction(UIAlertAction(title: V3L("删除"), style: .destructive) {
            [weak self] _ in
            guard let self else { return }
            Task {
                do {
                    try await self.repository.deleteManagedCard(
                        id: item.cardID, expectedRevision: item.revision)
                    self.onMutation?()
                    self.reloadCards()
                } catch { self.showError(error) }
            }
        })
        present(alert, animated: true)
    }

    override func tableView(_ tableView: UITableView,
        trailingSwipeActionsConfigurationForRowAt indexPath: IndexPath
    ) -> UISwipeActionsConfiguration? {
        guard cards.indices.contains(indexPath.row) else { return nil }
        let item = cards[indexPath.row]
        let delete = UIContextualAction(style: .destructive, title: V3L("删除")) {
            [weak self] _, _, finish in
            self?.confirmDelete(item)
            finish(false)
        }
        let pause = UIContextualAction(style: .normal,
            title: item.isSuspended ? V3L("恢复") : V3L("暂停")) {
            [weak self] _, _, finish in
            self?.changeSuspension(item)
            finish(true)
        }
        let result = UISwipeActionsConfiguration(actions: [delete, pause])
        result.performsFirstActionWithFullSwipe = false
        return result
    }

    private func showError(_ error: Error) {
        let alert = UIAlertController(title: V3L("操作未完成"),
            message: error.localizedDescription, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: V3L("确定"), style: .default))
        if presentedViewController == nil { present(alert, animated: true) }
    }
}
