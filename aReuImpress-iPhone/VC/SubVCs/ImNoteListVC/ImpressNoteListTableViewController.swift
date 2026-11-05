//
//  ImpressNoteListTableViewController.swift
//  aReuImpress-iPhone
//
//  Created by aReu on 12/8/22.
//  fix 20230129合拼四大页面到Notes页,去掉侧滑(理由:耗时)
//  fix 20230131整合鸡汤页面(激励以适量为好)
//  fix 20230923整合Review页面+大量删减非刚需代码 (少即多),另外采取强制推送方案,即已设置了就不能取消,但可以重置
//  fix 20250110再次精简,只保留核心业务(显示+搜索),其余影响效率的逻辑去掉

import UIKit
import Combine
import ImpressReviewCore

enum ImVaultListPresentation {
    static let pageSize = 120

    static func folders(in notes: [ImVaultIndexNote]) -> [String] {
        var paths = Set<String>()
        for note in notes {
            let components = note.identity.relativePath.split(separator: "/")
            guard components.count > 1 else { continue }
            for length in 1..<components.count {
                paths.insert(components.prefix(length).joined(separator: "/"))
            }
        }
        return paths.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    static func matched(_ notes: [ImVaultIndexNote],
                        query: String, folder: String?) -> [ImVaultIndexNote] {
        let searched = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return notes.filter { note in
            let path = note.identity.relativePath
            if let folder, !path.hasPrefix(folder + "/") { return false }
            return searched.isEmpty || note.title.localizedCaseInsensitiveContains(searched) ||
                path.localizedCaseInsensitiveContains(searched)
        }
    }

    static func page<T>(_ values: [T], limit: Int) -> [T] {
        Array(values.prefix(max(0, limit)))
    }

    /// Read-only tree projection; the index's full Vault identity is retained.
    struct OutlineRow {
        enum Item {
            case folder(String)
            case document(ImVaultIndexNote)
        }
        let item: Item
        let title: String
        let depth: Int
        var folderPath: String? {
            if case let .folder(path) = item { return path }
            return nil
        }
        var note: ImVaultIndexNote? {
            if case let .document(value) = item { return value }
            return nil
        }
        var stableID: String {
            switch item {
            case .folder(let path): return "folder:" + path
            case .document(let doc):
                return "document:" + doc.identity.vaultID + "/" + doc.identity.relativePath
            }
        }
    }

    private enum OutlineNode {
        case folder(String)
        case document(ImVaultIndexNote)
        var path: String {
            switch self {
            case let .folder(path): return path
            case let .document(note): return note.identity.relativePath
            }
        }
        var title: String {
            switch self {
            case let .folder(path): return String(path.split(separator: "/").last ?? "")
            case let .document(note): return note.title
            }
        }
        var folder: Bool {
            if case .folder = self { return true }
            return false
        }
    }

    static func outlineRows(in notes: [ImVaultIndexNote], query: String,
                            expandedFolders: Set<String>) -> [OutlineRow] {
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let matching = term.isEmpty ? notes : matched(notes, query: term, folder: nil)
        var seen = Set<ImVaultFileIdentity>()
        let unique = matching.filter { seen.insert($0.identity).inserted }
        var children: [String: [OutlineNode]] = [:]
        for folder in folders(in: unique) {
            let parent = folder.split(separator: "/").dropLast().joined(separator: "/")
            children[parent, default: []].append(.folder(folder))
        }
        for note in unique {
            let parent = note.identity.relativePath.split(separator: "/")
                .dropLast().joined(separator: "/")
            children[parent, default: []].append(.document(note))
        }
        var result: [OutlineRow] = []
        func visit(_ parent: String, _ depth: Int) {
            let siblings = (children[parent] ?? []).sorted { lhs, rhs in
                if lhs.folder != rhs.folder { return lhs.folder }
                let order = lhs.title.localizedStandardCompare(rhs.title)
                return order == .orderedSame ? lhs.path < rhs.path : order == .orderedAscending
            }
            for node in siblings {
                switch node {
                case let .folder(path):
                    result.append(OutlineRow(item: .folder(path),
                        title: node.title, depth: depth))
                    if !term.isEmpty || expandedFolders.contains(path) {
                        visit(path, depth + 1)
                    }
                case let .document(note):
                    result.append(OutlineRow(item: .document(note),
                        title: note.title, depth: depth))
                }
            }
        }
        visit("", 0)
        return result
    }
}

class ImpressNoteListTableViewController: ImBaseViewController
{
    private var cancellables = Set<AnyCancellable>()
    
    let tableView = UITableView(frame: .zero, style: .insetGrouped)
    ///
    private var viewModel: ImNotesViewModelProtocol! = ImpressNotesViewModel()
    
    private let reuseID = "impress-note-native-cell"
    // External Vault never merges into the legacy Note WCDB table.
    private var externalMode = true
    private var externalNotes: [ImVaultIndexNote] = []
    private var externalSearchText = ""
    private var visibleExternalRows: [ImVaultListPresentation.OutlineRow] = []
    private var expandedExternalFolders = Set<String>()
    private var totalExternalRowCount = 0
    private var matchedExternalCount = 0
    private var externalVisibleLimit = ImVaultListPresentation.pageSize
    private var externalLoading = false
    private var showingCachedIndex = false
    private var showingPartialIndex = false
    private var externalReadGate = ImVaultAsyncReadGate()
    private var externalError: String?
    private var lastSilentRefreshRequest = Date.distantPast
    // One visible, bounded source navigation at a time. The source content is
    // still read ONLY through the scoped NSFileCoordinator gate.
    private var pendingExternalSourceOpen: UUID?

    private var hasMoreExternalRows: Bool {
        visibleExternalRows.count < totalExternalRowCount
    }

    private func rebuildExternalRows() {
        matchedExternalCount = ImVaultListPresentation.matched(
            externalNotes, query: externalSearchText, folder: nil).count
        let rows = ImVaultListPresentation.outlineRows(
            in: externalNotes, query: externalSearchText,
            expandedFolders: expandedExternalFolders)
        totalExternalRowCount = rows.count
        visibleExternalRows = ImVaultListPresentation.page(
            rows, limit: externalVisibleLimit)
    }

    /// UIKit-managed row transitions instead of a flashing full-table reload.
    /// Also handles the bounded load-more sentinel without losing source IDs.
    private func animateOutlineChange(_ change: () -> Void) {
        let before = visibleExternalRows.map(\.stableID) +
            (hasMoreExternalRows ? ["more"] : [])
        change()
        rebuildExternalRows()
        let after = visibleExternalRows.map(\.stableID) +
            (hasMoreExternalRows ? ["more"] : [])
        let beforeSet = Set(before), afterSet = Set(after)
        guard beforeSet.count == before.count, afterSet.count == after.count,
              before.filter({ afterSet.contains($0) }) ==
                  after.filter({ beforeSet.contains($0) }) else {
            tableView.reloadData()
            updateVaultEmptyState()
            return
        }
        let removed = before.enumerated().compactMap { index, id in
            afterSet.contains(id) ? nil : IndexPath(row: index, section: 0)
        }
        let added = after.enumerated().compactMap { index, id in
            beforeSet.contains(id) ? nil : IndexPath(row: index, section: 0)
        }
        tableView.performBatchUpdates({
            tableView.deleteRows(at: removed, with: .automatic)
            tableView.insertRows(at: added, with: .automatic)
        }, completion: { [weak self] _ in
            guard let self else { return }
            let visibleFolders = self.visibleExternalRows.enumerated().compactMap { i, row in
                row.folderPath == nil ? nil : IndexPath(row: i, section: 0)
            }
            if !visibleFolders.isEmpty {
                UIView.performWithoutAnimation {
                    self.tableView.reloadRows(at: visibleFolders, with: .none)
                }
            }
            self.updateVaultEmptyState()
        })
    }

    private func setAllFoldersExpanded(_ expanded: Bool) {
        animateOutlineChange {
            expandedExternalFolders = expanded
                ? Set(ImVaultListPresentation.folders(in: externalNotes)) : []
            externalVisibleLimit = ImVaultListPresentation.pageSize
        }
    }

    private var selectedNoteID : Int?
    
    /// 默认为不可自动滑动到指定位置
    private var canScrollToSelect: Bool = false
    
    
    
    convenience init(noteID: Int)
    {
        self.init()
        self.selectedNoteID  = noteID
        // 允许自动滑动到指定位置
        self.canScrollToSelect = true
    }
    
    // MARK: - Function
    override func viewDidLoad()
    {
        super.viewDidLoad()
        initUISetting()
        NotificationCenter.default.addObserver(self,
             selector: #selector(handleVaultForeground(_:)),
             name: UIApplication.didBecomeActiveNotification, object: nil)
        setupBindings()
        // 底层两步实现,先从数据库获取原有笔记集,然后从obsidian文件夹批量获取笔记进行校验,最后更新数据并刷新页面
        // TODO: 更改路径读取即可
        refreshNotes()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        title = V3L("笔记")
        navigationItem.searchController?.searchBar.placeholder = V3L("搜索笔记或文件夹")
        setupNavigationBarItems()
        navigationItem.largeTitleDisplayMode = .always
        if ImVaultReadOnlyProbe.shared.hasAuthorizedBookmark && !externalLoading {
            requestSilentRefresh()
        }
    }
    
    /// 初始化UI
    private func initUISetting()
    {
        title = V3L("笔记")
        view.backgroundColor = ImpressV3Appearance.page
        searchControllerSetting()
        tableViewSetting()
        setupNavigationBarItems()
    }
    
    /// 设置导航栏按钮
    private func setupNavigationBarItems()
    {
        // R04.2: No legacy database-ID viewer in the V3 Notes tab.
        navigationItem.leftBarButtonItem = nil

        // P0-1: explicit read-only external Vault probe. The old importer
        // is still available only as a first-time, NON-overwriting local copy.
        let expandFolders = UIAction(title: V3L("全部展开"),
            image: UIImage(systemName: "chevron.down")) { [weak self] _ in
                self?.setAllFoldersExpanded(true)
            }
        let collapseFolders = UIAction(title: V3L("全部折叠"),
            image: UIImage(systemName: "chevron.right")) { [weak self] _ in
                self?.setAllFoldersExpanded(false)
            }
        let connectVault = UIAction(title: V3L("选择 Obsidian Vault（只读）"),
                                    image: UIImage(systemName: "folder.badge.plus")) { [weak self] _ in
            self?.chooseReadOnlyVault()
        }
        let inspectSaved = UIAction(title: V3L("验证已授权 Vault（只读）"),
                                    image: UIImage(systemName: "checkmark.shield")) { [weak self] _ in
            self?.inspectSavedVault()
        }
        let disconnectVault = UIAction(title: V3L("断开 Vault 授权（不删除文件）"),
                                       image: UIImage(systemName: "xmark.shield")) { [weak self] _ in
            self?.confirmVaultDisconnect()
        }
        let vaultItem = UIBarButtonItem(image: UIImage(systemName: "folder"),
                                         style: .plain, target: nil, action: nil)
        vaultItem.menu = UIMenu(title: V3L("Vault · 只读"), children: [
            expandFolders, collapseFolders, connectVault, inspectSaved, disconnectVault
        ])
        vaultItem.accessibilityLabel = V3L("Vault · 只读")
        vaultItem.tintColor = ImpressV3Appearance.navigationActionInk
        navigationItem.rightBarButtonItem = vaultItem
    }
    
    // The picker grants scoped access; all file probes run off the main
    // thread. Both methods are READ-ONLY with respect to Obsidian.
    private func chooseReadOnlyVault() {
        ImVaultReadOnlyProbe.shared.chooseFolder(from: self) { [weak self] result in
            self?.showReadOnlyVaultResult(result)
        }
    }

    private func inspectSavedVault() {
        ImVaultReadOnlyProbe.shared.inspectSavedPermission { [weak self] result in
            self?.showReadOnlyVaultResult(result)
        }
    }

    private func confirmVaultDisconnect() {
        let alert = UIAlertController(
            title: V3L("断开 Obsidian Vault 授权？"),
            message: V3L("只清除 Impress 保存的访问书签，不会删除、修改或移动任何 Obsidian 文件，也不会删除本地笔记镜像。"),
            preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: V3L("取消"), style: .cancel))
        alert.addAction(UIAlertAction(title: V3L("断开"), style: .destructive) { _ in
            ImVaultReadOnlyProbe.shared.disconnectSavedPermission()
            self.externalMode = true
            self.externalNotes = []
            self.externalSearchText = ""
            self.expandedExternalFolders.removeAll()
            self.externalVisibleLimit = ImVaultListPresentation.pageSize
            self.showingCachedIndex = false
            self.showingPartialIndex = false
            self.externalError = nil
            self.rebuildExternalRows()
            self.refreshNotes()
        })
        present(alert, animated: true)
    }

    private func showReadOnlyVaultResult(_ result: Result<ImVaultReadOnlyReport, Error>) {
        let alert: UIAlertController
        switch result {
        case let .success(report):
            self.externalMode = true
            self.refreshNotes()
            let sample = report.sampleRelativePaths.isEmpty
                ? "无 Markdown 样本。请确认所选目录。"
                : report.sampleRelativePaths.joined(separator: "\n")
            let text = "Vault: \(report.name)\nMarkdown: \(report.markdownCount) 篇\(report.wasTruncated ? "（扫描上限）" : "")\n样本读取: \(report.sampleBytesRead) bytes\n授权恢复: \(report.restoredFromBookmark ? "已验证" : "首次连接")\n\n\(sample)\n\n仅校验授权和读取，未写入任何 Obsidian 文件。真实双向同步尚未启用。"
            alert = UIAlertController(title: V3L("Vault 只读验证完成"),
                                      message: text, preferredStyle: .alert)
        case let .failure(error):
            if let vaultError = error as? ImVaultReadOnlyError, case .noFolder = vaultError { return }
            alert = UIAlertController(title: V3L("Vault 只读验证未通过"),
                                      message: error.localizedDescription,
                                      preferredStyle: .alert)
        }
        alert.addAction(UIAlertAction(title: V3L("确定"), style: .default))
        present(alert, animated: true)
    }

    /// 从iCloud Drive导入
    @objc private func importFromiCloudDrive()
    {
        // 显示确认提示
        ImAlertController.alert(
            message: "只会在 ImpressVault 不存在时首次复制。不会覆盖已有笔记，也不是双向同步。是否继续？",
            buttons: alertDescription) { [weak self] result in
            if case .ok = result {
                self?.performiCloudImport()
            }
        }
    }
    
    /// 执行iCloud导入
    private func performiCloudImport()
    {
        loadShare.show()
        ImiCloudImportManager.shared.performManualImport(from: self) { [weak self] error in
            DispatchQueue.main.async {
                loadShare.hide()
                if let error = error {
                    ImAlertController.warningAlert(error.localizedDescription)
                } else {
                    // 导入成功，刷新笔记列表
                    self?.refreshNotes()
                    ImAlertController.alert(message: "笔记导入成功")
                }
            }
        }
    }
    
    @objc private func handleVaultForeground(_ notification: Notification) {
        // A covered/hidden Notes view should not perform a large Vault scan.
        guard view.window != nil else { return }
        requestSilentRefresh()
    }

    /// Coalesce foreground and navigation re-entry without a visible
    /// pull-to-refresh affordance or redundant table invalidation.
    private func requestSilentRefresh() {
        guard Date().timeIntervalSince(lastSilentRefreshRequest) >= 0.8 else { return }
        lastSilentRefreshRequest = Date()
        refreshNotes()
    }

    /// 刷新笔记列表
    @objc func refreshNotes()
    {
        if let vaultID = ImVaultReadOnlyProbe.shared.authorizedVaultID {
            externalMode = true
            if externalReadGate.changeSource(to: vaultID) {
                externalLoading = false
                externalNotes = []
                expandedExternalFolders.removeAll()
                externalVisibleLimit = ImVaultListPresentation.pageSize
                showingCachedIndex = false
                showingPartialIndex = false
                externalError = nil
                rebuildExternalRows()
            }
            guard !externalLoading else { return }
            let token = externalReadGate.begin(for: vaultID)
            externalLoading = true
            if externalNotes.isEmpty {
                ImVaultReadSync.shared.cachedIndex { [weak self] result in
                    guard let self, self.externalLoading, self.externalNotes.isEmpty,
                          ImVaultReadOnlyProbe.shared.authorizedVaultID == vaultID,
                          self.externalReadGate.accepts(token) else { return }
                    if case let .success(cached) = result, !cached.isEmpty {
                        self.externalNotes = cached
                        self.showingCachedIndex = true
                        self.rebuildExternalRows()
                        self.tableView.reloadData()
                        self.updateVaultEmptyState()
                    }
                }
            }
            ImVaultReadSync.shared.refresh(progress: { [weak self] batch in
                guard let self, self.externalLoading, !self.showingCachedIndex,
                      ImVaultReadOnlyProbe.shared.authorizedVaultID == vaultID,
                      self.externalReadGate.accepts(token) else { return }
                guard self.externalNotes.isEmpty || self.showingPartialIndex else { return }
                let remaining = max(0, 600 - self.externalNotes.count)
                guard remaining > 0 else { return }
                // A bounded, explicitly provisional preview; the full index
                // is published only when provider enumeration fully succeeds.
                self.externalNotes.append(contentsOf: batch.prefix(remaining))
                self.showingPartialIndex = true
                self.rebuildExternalRows()
                self.tableView.reloadData()
                self.updateVaultEmptyState()
            }) { [weak self] result in
                guard let self, self.externalMode,
                      ImVaultReadOnlyProbe.shared.authorizedVaultID == vaultID,
                      self.externalReadGate.accepts(token) else { return }
                self.externalLoading = false
                let wasProvisional = self.showingCachedIndex || self.showingPartialIndex
                self.showingCachedIndex = false
                self.showingPartialIndex = false
                switch result {
                case let .success(index):
                    self.externalError = nil
                    if self.externalNotes != index.notes {
                        self.animateOutlineChange { self.externalNotes = index.notes }
                    } else if wasProvisional {
                        UIView.performWithoutAnimation {
                            self.tableView.reloadSections(IndexSet(integer: 0), with: .none)
                        }
                        self.updateVaultEmptyState()
                    }
                    // Same identity/mtime/size: zero table invalidation.
                case let .failure(error):
                    // Keep the previously verified same-Vault index on
                    // transient provider failures. Never expose old Vaults.
                    self.externalError = error.localizedDescription
                    if self.externalNotes.isEmpty { self.updateVaultEmptyState() }
                }
            }
        } else {
            externalReadGate.changeSource(to: nil)
            externalLoading = false
            externalMode = true
            externalNotes = []
            expandedExternalFolders.removeAll()
            showingCachedIndex = false
            showingPartialIndex = false
            externalVisibleLimit = ImVaultListPresentation.pageSize
            externalError = nil
            rebuildExternalRows()
            updateVaultEmptyState()
            tableView.reloadData()
        }
    }

    private func updateVaultEmptyState() {
        guard externalMode else { tableView.backgroundView = nil; return }
        if !visibleExternalRows.isEmpty { tableView.backgroundView = nil; return }
        let container = UIView()
        let contents = UIStackView()
        contents.axis = .vertical
        contents.alignment = .center
        contents.spacing = 16
        contents.translatesAutoresizingMaskIntoConstraints = false
        let message = UILabel()
        message.text = externalError ??
            (externalLoading ? V3L("正在分批读取 Obsidian 文档…") :
             !externalSearchText.isEmpty ? V3L("没有符合搜索条件的笔记") :
             ImVaultReadOnlyProbe.shared.hasAuthorizedBookmark
                ? V3L("此位置没有可读取的文档")
                : V3L("连接 Obsidian Vault 后查看笔记"))
        message.numberOfLines = 0
        message.textColor = ImpressV3Appearance.secondaryText
        message.textAlignment = .center
        message.font = ImpressV3Appearance.Typography.supporting
        message.adjustsFontForContentSizeCategory = true
        contents.addArrangedSubview(message)
        if !ImVaultReadOnlyProbe.shared.hasAuthorizedBookmark {
            let connect = UIButton(type: .system)
            connect.setTitle(V3L("连接 Obsidian Vault"), for: .normal)
            connect.accessibilityIdentifier = "impress.notes.connect-vault"
            connect.addTarget(self, action: #selector(connectVaultFromEmptyState),
                              for: .touchUpInside)
            contents.addArrangedSubview(connect)
        }
        container.addSubview(contents)
        NSLayoutConstraint.activate([
            contents.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            contents.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            contents.leadingAnchor.constraint(greaterThanOrEqualTo: container.leadingAnchor, constant: 24),
            contents.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor, constant: -24)
        ])
        tableView.backgroundView = container

    }

    @objc private func connectVaultFromEmptyState() {
        chooseReadOnlyVault()
    }
}


// MARK: - seachBarConfig
extension ImpressNoteListTableViewController: UISearchBarDelegate
{
    private func searchControllerSetting()
    {
        let controller = UISearchController.init(searchResultsController: nil)
        controller.searchBar.placeholder = V3L("搜索笔记或文件夹")
        controller.searchBar.delegate = self
        controller.searchBar.tintColor = ImpressV3Appearance.navigationActionInk
        controller.obscuresBackgroundDuringPresentation = false
        navigationItem.searchController = controller
        navigationItem.hidesSearchBarWhenScrolling = false
    }
    
    /// 筛选搜索Action
    private func searchDBByText(_ text:String? = nil)
    {
        if externalMode {
            externalSearchText = text ?? ""
            externalVisibleLimit = ImVaultListPresentation.pageSize
            rebuildExternalRows()
            tableView.reloadData()
            updateVaultEmptyState()
            return
        }
        guard let t = text, t.count > 0 else {
            viewModel.updateStatusInFliter()
            return
        }
        viewModel.predicateNoteSeriesDatas(filtterText: t)
    }
    
    func searchBar(_ searchBar: UISearchBar,
                   textDidChange searchText: String)
    {
        guard let text = searchBar.text else { return }
        searchDBByText(text)
    }
    
    func searchBarCancelButtonClicked(_ searchBar: UISearchBar)
    {
        searchDBByText()
    }
}

// MARK: - TableView + UITableViewDelegate
extension ImpressNoteListTableViewController:UITableViewDataSource,UITableViewDelegate
{
    private func scrollToSelectedNoteIfApplicable()
    {
        guard let selectedID = selectedNoteID ,
              let indexPath = viewModel.indexPath(for: selectedID) else {
            return
        }
        tableView.scrollToRow(at: indexPath, at: .middle, animated: true)
        
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self = self else { return }
            self.tableView.selectRow(at: indexPath, animated: true, scrollPosition: .none)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) { [weak self] in
                self?.tableView.deselectRow(at: indexPath, animated: true)
            }
        }
    }
    
    private func tableViewSetting()
    {
        view.addSubview(tableView)
        ImpressV3Appearance.styleGroupedTable(tableView)
        tableView.contentInsetAdjustmentBehavior = .automatic
        tableView.translatesAutoresizingMaskIntoConstraints = false
        tableView.showsVerticalScrollIndicator = true
        let safeArea = view.safeAreaLayoutGuide
        NSLayoutConstraint.activate([
            tableView.topAnchor.constraint(equalTo: safeArea.topAnchor),
            tableView.leftAnchor.constraint(equalTo: safeArea.leftAnchor),
            tableView.bottomAnchor.constraint(equalTo: safeArea.bottomAnchor),
            tableView.rightAnchor.constraint(equalTo: safeArea.rightAnchor)
        ])
        tableView.delegate = self
        tableView.dataSource = self
        tableView.tableFooterView = UIView(frame: .zero)
        tableView.refreshControl = nil
    }
    
    func numberOfSections(in tableView: UITableView) -> Int {
        // External Vault is one continuous list, not one giant rounded
        // section for every Markdown file. Legacy section identities remain.
        externalMode ? 1 : viewModel.currentNotesCount
    }

    func tableView(_ tableView: UITableView,
                   numberOfRowsInSection section: Int) -> Int {
        externalMode ? visibleExternalRows.count + (hasMoreExternalRows ? 1 : 0) : 1
    }

    func tableView(_ tableView: UITableView,
                   titleForHeaderInSection section: Int) -> String? {
        externalMode && (showingCachedIndex || showingPartialIndex)
            ? V3L("Vault 索引预览 · 正在验证") : nil
    }

    func tableView(_ tableView: UITableView,
                   cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        if externalMode {
            if hasMoreExternalRows && indexPath.row == visibleExternalRows.count {
                let cell = tableView.dequeueReusableCell(withIdentifier: "vault-more")
                    ?? UITableViewCell(style: .default, reuseIdentifier: "vault-more")
                var content = UIListContentConfiguration.cell()
                content.text = V3L("加载更多") + " · " + String(visibleExternalRows.count)
                    + " / " + String(totalExternalRowCount)
                content.textProperties.color = ImpressV3Appearance.accent
                content.textProperties.font = ImpressV3Appearance.Typography.supporting
                cell.contentConfiguration = content
                ImpressV3Appearance.styleGroupedCell(cell)
                cell.accessibilityIdentifier = "impress.notes.load-more"
                return cell
            }
            guard visibleExternalRows.indices.contains(indexPath.row) else {
                return UITableViewCell()
            }
            let row = visibleExternalRows[indexPath.row]
            let folder = row.folderPath
            let expanded = folder.map { expandedExternalFolders.contains($0) } ?? false
            let cell = tableView.dequeueReusableCell(withIdentifier: "vault-outline")
                ?? UITableViewCell(style: .default, reuseIdentifier: "vault-outline")
            var content = UIListContentConfiguration.cell()
            content.text = row.title
            // The only symbol is the necessary expand/collapse disclosure.
            let chevron = (expanded || !externalSearchText.isEmpty)
                ? "chevron.down" : "chevron.right"
            content.image = folder == nil ? nil : UIImage(
                systemName: chevron,
                withConfiguration: UIImage.SymbolConfiguration(
                    pointSize: ImpressV3Appearance.outlineChevronPointSize,
                    weight: .medium))
            content.imageProperties.tintColor = ImpressV3Appearance.listIconTint
            content.imageProperties.maximumSize = CGSize(width: 12, height: 12)
            content.imageToTextPadding = 8
            content.axesPreservingSuperviewLayoutMargins = []
            content.directionalLayoutMargins = NSDirectionalEdgeInsets(
                top: 9, leading: 12 + CGFloat(row.depth) * 19 +
                    (folder == nil ? 22 : 0),
                bottom: 9, trailing: 12)
            content.textProperties.font = ImpressV3Appearance.Typography.body
            content.textProperties.numberOfLines = 1
            cell.contentConfiguration = content
            ImpressV3Appearance.styleGroupedCell(cell)
            cell.accessoryType = .none
            cell.selectionStyle = folder == nil ? .default : .none
            cell.accessibilityLabel = row.title
            cell.accessibilityIdentifier = folder == nil
                ? "impress.notes.file-row" : "impress.notes.folder-row"
            cell.accessibilityValue = folder == nil ? nil :
                ((expanded || !externalSearchText.isEmpty)
                    ? V3L("已展开") : V3L("已折叠"))
            return cell
        }
        let cell = tableView.dequeueReusableCell(withIdentifier: reuseID)
            ?? UITableViewCell(style: .subtitle, reuseIdentifier: reuseID)
        if let note = viewModel.getCurrentNote(indexPath: indexPath) {
            var content = UIListContentConfiguration.cell()
            content.text = note.mainTitle ?? V3L("无标题")
            content.textProperties.font = ImpressV3Appearance.Typography.body
            cell.contentConfiguration = content
            cell.accessoryType = .disclosureIndicator
            if ImpressV3ReviewEnvironment.pilotEnabled {
                ImpressV3Appearance.styleGroupedCell(cell)
            }
        }
        return cell
    }
    
        func tableView(_ tableView: UITableView,
                   didSelectRowAt indexPath: IndexPath)
    {
        tableView.deselectRow(at: indexPath, animated: false)
        if externalMode {
            if hasMoreExternalRows && indexPath.row == visibleExternalRows.count {
                externalVisibleLimit += ImVaultListPresentation.pageSize
                rebuildExternalRows()
                tableView.reloadData()
                return
            }
            guard visibleExternalRows.indices.contains(indexPath.row) else { return }
            let row = visibleExternalRows[indexPath.row]
            if let path = row.folderPath {
                // Search is an expanded projection, not a mutation of normal fold state.
                guard externalSearchText.isEmpty else { return }
                animateOutlineChange {
                    if !expandedExternalFolders.insert(path).inserted {
                        expandedExternalFolders.remove(path)
                    }
                }
                return
            }
            guard let item = row.note else { return }
            // A delayed File Provider read must never load a different note,
            // and the user must see bounded progress rather than a silent tap.
            guard pendingExternalSourceOpen == nil else { return }
            let request = UUID()
            pendingExternalSourceOpen = request
            navigationItem.prompt = V3L("正在核实原始笔记…")
            #if DEBUG
            if ImpressV11UITestFixture.enabled {
                NSLog("IMPRESS_V11_NOTE_OPEN_REQUESTED")
            }
            #endif
            ImVaultReadSync.shared.read(item.identity) { [weak self] result in
                guard let self, self.pendingExternalSourceOpen == request else { return }
                self.pendingExternalSourceOpen = nil
                self.navigationItem.prompt = nil
                guard self.externalMode,
                      ImVaultReadOnlyProbe.shared.authorizedVaultID ==
                          item.identity.vaultID else { return }
                switch result {
                case let .success(source):
                    #if DEBUG
                    if ImpressV11UITestFixture.enabled {
                        NSLog("IMPRESS_V11_NOTE_OPEN_VERIFIED")
                    }
                    #endif
                    self.navigationController?.pushViewController(
                        ImVaultDocumentController(document: source), animated: true)
                case let .failure(error):
                    #if DEBUG
                    if ImpressV11UITestFixture.enabled {
                        NSLog("IMPRESS_V11_NOTE_OPEN_REJECTED")
                    }
                    #endif
                    let alert = UIAlertController(title: V3L("无法读取源笔记"),
                        message: error.localizedDescription, preferredStyle: .alert)
                    alert.addAction(UIAlertAction(title: V3L("确定"), style: .default))
                    self.present(alert, animated: true)
                }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 45) { [weak self] in
                guard let self, self.pendingExternalSourceOpen == request else { return }
                // A stalled File Provider operation cannot authorize cached
                // text. Reject this request; any later callback is ignored.
                self.pendingExternalSourceOpen = nil
                self.navigationItem.prompt = nil
                #if DEBUG
                if ImpressV11UITestFixture.enabled {
                    NSLog("IMPRESS_V11_NOTE_OPEN_TIMEOUT")
                }
                #endif
                guard self.view.window != nil else { return }
                let alert = UIAlertController(title: V3L("源笔记读取超时"),
                    message: V3L("来源文件暂未完成授权读取，请稍后重试。未修改任何原始内容。"),
                    preferredStyle: .alert)
                alert.addAction(UIAlertAction(title: V3L("确定"), style: .default))
                self.present(alert, animated: true)
            }
            return
        }
        let note = viewModel.getCurrentNote(indexPath: indexPath)
        let mdVC = ImMarkdownViewController.init(note: note)
        navigationController?.pushViewController(mdVC, animated: true)
    }
    
    func tableView(_ tableView: UITableView,
                   trailingSwipeActionsConfigurationForRowAt indexPath: IndexPath) -> UISwipeActionsConfiguration?
    {
        // P0-0: a swipe must NEVER delete the shared-note index or source file.
        // Future deletion requires a separate backed-up and confirmed workflow.
        return nil
    }


}

// MARK: - 绑定事件逻辑业务
extension ImpressNoteListTableViewController
{
    private func setupBindings()
    {
        // 订阅数据源和过滤状态的变化，用于刷新列表
        viewModel.notesPublisher
            .combineLatest(viewModel.filteredNotesPublisher, viewModel.isFilteringPublisher)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _, _, _ in
                guard let self = self else { return }
                if !self.externalMode { self.tableView.reloadData() }
                // 确保自动滚动逻辑只在需要时执行一次
                if self.canScrollToSelect {
                    self.canScrollToSelect = false
                    self.scrollToSelectedNoteIfApplicable()
                }
            }
            .store(in: &cancellables)

        // 订阅一次性动作事件，如加载、提示、删除等
        viewModel.actionPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] result in
                guard let self = self else { return }
                switch result {
                case .isLoading(let isLoading):
                    isLoading ? loadShare.show() : loadShare.hide()
                case .success(let content):
                    ImAlertController.alert(message: content)
                case .errorOccurred(let error):
                    ImAlertController.warningAlert(error.localizedDescription)
                case .protocolSpecific(.note(.delete(let indexPath))):
                    self.tableView.deleteSections(IndexSet(integer: indexPath.section), with: .fade)
                default:
                    break
                }
            }
            .store(in: &cancellables)
    }
}
