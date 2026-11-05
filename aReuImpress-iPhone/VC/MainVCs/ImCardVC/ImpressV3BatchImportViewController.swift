import UIKit
import UniformTypeIdentifiers
import ImpressReviewCore

// R04.2-C authoring remains local until explicit confirmation. Candidate
// editors do not touch WCDB; only the batch coordinator owns the final commit.
@MainActor
struct ImpressV3BatchCandidate {
    let line: Int
    let raw: String
    var issues: [String]
    var draft: ImpressV3CardDraft
    var reviewed = false

    init(parsed: ImpressBatchParsedRow, sourceKey: String?) {
        line = parsed.line
        raw = parsed.raw
        issues = parsed.issues
        var value = ImpressV3CardDraft()
        value.question = parsed.question
        value.answer = parsed.answer
        value.sourceNotePath = sourceKey
        if parsed.isChoice {
            value.kind = .multipleChoice
            value.allowsMultipleCorrect = parsed.correctIndices.count > 1
            value.choices = parsed.choices.enumerated().map {
                ImpressV3CardDraft.Choice(text: $0.element,
                    isCorrect: parsed.correctIndices.contains($0.offset))
            }
        }
        draft = value
    }

    var problem: String? {
        if !reviewed, let sourceIssue = issues.first { return sourceIssue }
        do {
            _ = try draft.validatedInput()
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    static func fromValidated(_ input: WCDBV3CardInput, old: ImpressV3BatchCandidate) -> Self {
        var candidate = old
        candidate.reviewed = true
        var draft = ImpressV3CardDraft()
        draft.kind = CardType(rawValue: input.cardType) ?? .standard
        draft.question = input.question
        draft.answer = input.answerText ?? ""
        draft.imageData = input.imageData
        draft.sourceNotePath = input.sourceNotePath
        if input.cardType == CardType.multipleChoice.rawValue {
            let selections = Set((input.correctIndices ?? "").split(separator: ",")
                .compactMap { Int($0) })
            draft.allowsMultipleCorrect = selections.count > 1
            draft.choices = (input.choices ?? "").components(separatedBy: "\n")
                .enumerated().map { index, text in
                    ImpressV3CardDraft.Choice(text: text, isCorrect: selections.contains(index))
                }
        }
        candidate.draft = draft
        return candidate
    }
}

@MainActor
final class ImpressV3BatchImportViewController: UIViewController, UIDocumentPickerDelegate,
                                                UITextViewDelegate {
    var onCommit: (([WCDBV3CardInput]) async throws -> Void)?

    private let formatPicker = UISegmentedControl(items: [V3L("文本"), "CSV", "TSV", "MD"])
    private let editor = UITextView()
    private let sourceLabel = UILabel()
    private var authorizedIdentity: ImVaultFileIdentity?
    private var reading = false

    override func viewDidLoad() {
        super.viewDidLoad()
        title = V3L("批量导入")
        navigationItem.largeTitleDisplayMode = .never
        view.backgroundColor = ImpressV3Appearance.page
        navigationItem.leftBarButtonItem = UIBarButtonItem(
            barButtonSystemItem: .cancel, target: self, action: #selector(cancel))
        navigationItem.leftBarButtonItem?.tintColor = ImpressV3Appearance.navigationActionInk
        navigationItem.rightBarButtonItem = ImpressV3Appearance.navigationAction(
            symbol: "doc.text.magnifyingglass", label: V3L("预览"),
            target: self, action: #selector(preview))
        let scroll = UIScrollView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.keyboardDismissMode = .interactive
        let stack = UIStackView()
        stack.axis = .vertical
        stack.spacing = ImpressV3Appearance.Metrics.sectionSpacing
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(scroll)
        scroll.addSubview(stack)
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            scroll.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor),
            stack.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor, constant: ImpressV3Appearance.Metrics.screenInset),
            stack.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor, constant: ImpressV3Appearance.Metrics.screenInset),
            stack.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor, constant: -ImpressV3Appearance.Metrics.screenInset),
            stack.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor, constant: -20),
            stack.widthAnchor.constraint(equalTo: scroll.frameLayoutGuide.widthAnchor, constant: -2 * ImpressV3Appearance.Metrics.screenInset)
        ])
        if #available(iOS 15.0, *) {
            scroll.bottomAnchor.constraint(equalTo: view.keyboardLayoutGuide.topAnchor).isActive = true
        } else {
            scroll.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor).isActive = true
        }

        let intro = UILabel()
        intro.text = V3L("选择输入格式，在本机解析。预览和逐题校验通过后才会写入闪卡数据库。")
        intro.numberOfLines = 0
        intro.font = ImpressV3Appearance.Typography.supporting
        intro.adjustsFontForContentSizeCategory = true
        intro.textColor = ImpressV3Appearance.secondaryText
        stack.addArrangedSubview(intro)
        formatPicker.selectedSegmentIndex = 0
        ImpressV3Appearance.styleSegmentedControl(formatPicker, prominent: false)
        formatPicker.accessibilityLabel = V3L("导入格式")
        formatPicker.accessibilityHint = V3L("MD 表示 Markdown；选择一种格式后，输入文本并预览。")
        stack.addArrangedSubview(ImpressV3Appearance.segmentedRow(formatPicker))
        let buttons = UIStackView()
        buttons.axis = .horizontal
        buttons.spacing = ImpressV3Appearance.Metrics.rowSpacing
        buttons.distribution = .fillEqually
        buttons.addArrangedSubview(actionButton(V3L("选择文件"), icon: "doc", selector: #selector(chooseFile)))
        buttons.addArrangedSubview(actionButton(V3L("Obsidian 笔记"), icon: "folder", selector: #selector(chooseVault)))
        stack.addArrangedSubview(buttons)
        sourceLabel.numberOfLines = 0
        sourceLabel.font = ImpressV3Appearance.Typography.caption
        sourceLabel.adjustsFontForContentSizeCategory = true
        sourceLabel.textColor = ImpressV3Appearance.secondaryText
        sourceLabel.text = V3L("粘贴文本，或选择 CSV / TSV / Markdown 文件。")
        stack.addArrangedSubview(sourceLabel)
        editor.font = ImpressV3Appearance.Typography.body
        editor.adjustsFontForContentSizeCategory = true
        editor.backgroundColor = ImpressV3Appearance.surface
        editor.textColor = ImpressV3Appearance.primaryText
        editor.layer.cornerRadius = ImpressV3Appearance.Radius.field
        editor.textContainerInset = UIEdgeInsets(top: ImpressV3Appearance.Metrics.fieldPadding, left: ImpressV3Appearance.Metrics.fieldPadding,
                                                  bottom: ImpressV3Appearance.Metrics.fieldPadding, right: ImpressV3Appearance.Metrics.fieldPadding)
        editor.accessibilityLabel = V3L("本地批量导入原始文本")
        editor.delegate = self
        ImpressSpeechAccessory.install(on: editor)
        stack.addArrangedSubview(editor)
        editor.heightAnchor.constraint(greaterThanOrEqualToConstant: ImpressV3Appearance.Metrics.batchEditorMinHeight).isActive = true
        let hint = UILabel()
        hint.numberOfLines = 0
        hint.font = ImpressV3Appearance.Typography.footnote
        hint.adjustsFontForContentSizeCategory = true
        hint.textColor = ImpressV3Appearance.secondaryText
        hint.text = V3L("文本/Markdown：Q: 问题、A: 答案。CSV/TSV：question、answer；选择题另提供 type=choice、options=A|B|C、correct=1,3（从 1 起）。无法识别的内容保留原文供修正。")
        stack.addArrangedSubview(hint)
    }

    private func actionButton(_ title: String, icon: String, selector: Selector) -> UIButton {
        let button = UIButton(type: .system)
        ImpressV3Appearance.styleQuietButton(button, title: title, symbol: icon)
        button.addTarget(self, action: selector, for: .touchUpInside)
        button.titleLabel?.adjustsFontForContentSizeCategory = true
        return button
    }

    func textViewDidChange(_ textView: UITextView) {
        if authorizedIdentity != nil {
            authorizedIdentity = nil
            sourceLabel.text = V3L("已修改输入文本，解除原 Obsidian 来源关联，避免来源错配。")
        }
    }

    @objc private func chooseFile() {
        let formats: [UTType] = [.plainText, .commaSeparatedText,
            UTType(filenameExtension: "tsv") ?? .plainText,
            UTType(filenameExtension: "md") ?? .plainText]
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: formats, asCopy: true)
        picker.allowsMultipleSelection = false
        picker.delegate = self
        present(picker, animated: true)
    }

    func documentPicker(_ controller: UIDocumentPickerViewController,
                        didPickDocumentsAt urls: [URL]) {
        guard let url = urls.first else { return }
        let scope = url.startAccessingSecurityScopedResource()
        defer { if scope { url.stopAccessingSecurityScopedResource() } }
        do {
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            guard ((attributes[.size] as? NSNumber)?.intValue ?? 0) <= ImpressBatchParser.maximumBytes
            else { throw CocoaError(.fileReadTooLarge) }
            let bytes = try Data(contentsOf: url)
            guard bytes.count <= ImpressBatchParser.maximumBytes,
                  let text = String(data: bytes, encoding: .utf8) else {
                throw CocoaError(.fileReadInapplicableStringEncoding)
            }
            authorizedIdentity = nil
            editor.text = text
            sourceLabel.text = "本机文件 · " + url.lastPathComponent
            switch url.pathExtension.lowercased() {
            case "csv": formatPicker.selectedSegmentIndex = 1
            case "tsv": formatPicker.selectedSegmentIndex = 2
            case "md", "markdown": formatPicker.selectedSegmentIndex = 3
            default: formatPicker.selectedSegmentIndex = 0
            }
        } catch { showError(V3L("无法读取文件"), error.localizedDescription) }
    }

    @objc private func chooseVault() {
        let picker = ImpressV3BatchVaultPickerViewController(style: .plain)
        picker.onChoose = { [weak self] identity in
            guard let self else { return }
            self.reading = true
            self.navigationItem.rightBarButtonItem?.isEnabled = false
            ImVaultReadSync.shared.read(identity) { [weak self] result in
                guard let self else { return }
                self.reading = false
                self.navigationItem.rightBarButtonItem?.isEnabled = true
                switch result {
                case .success(let document):
                    guard document.identity == identity else {
                        self.showError(V3L("来源不一致"), V3L("授权笔记的身份发生变化。"))
                        return
                    }
                    guard document.sourceBytes.count <= ImpressBatchParser.maximumBytes else {
                        self.showError(V3L("文本过长"), V3L("导入文本不能超过 2MB。"))
                        return
                    }
                    self.editor.text = document.markdown
                    self.authorizedIdentity = identity
                    self.formatPicker.selectedSegmentIndex = 3
                    self.sourceLabel.text = identity.relativePath + " · 授权 Vault（仅读）"
                case .failure(let error):
                    self.showError(V3L("无法读取笔记"), error.localizedDescription)
                }
            }
        }
        let nav = UINavigationController(rootViewController: picker)
        present(nav, animated: true)
    }

    @objc private func preview() {
        guard !reading else { return }
        let formats: [ImpressBatchFormat] = [.text, .csv, .tsv, .markdown]
        let format = formats[formats.indices.contains(formatPicker.selectedSegmentIndex)
                             ? formatPicker.selectedSegmentIndex : 0]
        let parsed = ImpressBatchParser.parse(editor.text, as: format)
        guard !parsed.isEmpty else {
            showError(V3L("没有候选卡片"), V3L("先粘贴或选择包含问题和答案的文本。"))
            return
        }
        do {
            let source = try authorizedIdentity.map { try ImpressBatchSourceKey.encode($0) }
            let rows = parsed.map { ImpressV3BatchCandidate(parsed: $0, sourceKey: source) }
            let preview = ImpressV3BatchPreviewViewController(rows: rows)
            preview.onCommit = onCommit
            navigationController?.pushViewController(preview, animated: true)
        } catch { showError(V3L("来源身份无效"), error.localizedDescription) }
    }

    @objc private func cancel() {
        guard editor.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            let alert = UIAlertController(title: V3L("放弃这次导入？"),
                message: V3L("未确认的候选不会写入数据库，也不会修改来源笔记。"), preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: V3L("继续编辑"), style: .cancel))
            alert.addAction(UIAlertAction(title: V3L("放弃"), style: .destructive) { [weak self] _ in
                self?.dismiss(animated: true)
            })
            present(alert, animated: true)
            return
        }
        dismiss(animated: true)
    }

    private func showError(_ title: String, _ message: String) {
        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: V3L("确定"), style: .default))
        present(alert, animated: true)
    }
}

@MainActor
final class ImpressV3BatchVaultPickerViewController: UITableViewController {
    var onChoose: ((ImVaultFileIdentity) -> Void)?
    private var notes: [ImVaultIndexNote] = []
    private var filtered: [ImVaultIndexNote] = []
    private let search = UISearchController(searchResultsController: nil)

    override func viewDidLoad() {
        super.viewDidLoad()
        title = V3L("选择已授权笔记")
        navigationItem.leftBarButtonItem = UIBarButtonItem(
            barButtonSystemItem: .cancel, target: self, action: #selector(cancel))
        search.obscuresBackgroundDuringPresentation = false
        search.searchResultsUpdater = self
        search.searchBar.tintColor = ImpressV3Appearance.navigationActionInk
        navigationItem.leftBarButtonItem?.tintColor = ImpressV3Appearance.navigationActionInk
        navigationItem.searchController = search
        ImVaultReadSync.shared.refresh { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let index):
                self.notes = index.notes
                self.filterNotes()
            case .failure(let error):
                let alert = UIAlertController(title: V3L("Vault 未授权或无法读取"),
                    message: error.localizedDescription, preferredStyle: .alert)
                alert.addAction(UIAlertAction(title: V3L("确定"), style: .default))
                self.present(alert, animated: true)
            }
        }
    }

    private func filterNotes() {
        let q = search.searchBar.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        filtered = q.isEmpty ? notes : notes.filter {
            $0.identity.relativePath.localizedCaseInsensitiveContains(q)
        }
        tableView.reloadData()
    }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        filtered.count
    }

    override func tableView(_ tableView: UITableView,
                            cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let identifier = "note"
        let cell = tableView.dequeueReusableCell(withIdentifier: identifier)
            ?? UITableViewCell(style: .subtitle, reuseIdentifier: identifier)
        var content = UIListContentConfiguration.subtitleCell()
        content.text = filtered[indexPath.row].title
        content.secondaryText = filtered[indexPath.row].identity.relativePath
        content.image = UIImage(systemName: "doc.text")
        cell.contentConfiguration = content
        cell.accessoryType = .disclosureIndicator
        return cell
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        let identity = filtered[indexPath.row].identity
        let callback = onChoose
        dismiss(animated: true) { callback?(identity) }
    }

    @objc private func cancel() { dismiss(animated: true) }
}

extension ImpressV3BatchVaultPickerViewController: UISearchResultsUpdating {
    func updateSearchResults(for searchController: UISearchController) { filterNotes() }
}

@MainActor
final class ImpressV3BatchPreviewViewController: UITableViewController {
    var onCommit: (([WCDBV3CardInput]) async throws -> Void)?
    private(set) var rows: [ImpressV3BatchCandidate]
    private var saving = false
    private var commitButton: UIBarButtonItem?

    init(rows: [ImpressV3BatchCandidate]) {
        self.rows = rows
        super.init(style: .insetGrouped)
    }

    required init?(coder: NSCoder) { fatalError("init(rows:) required") }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = V3L("导入预览")
        navigationItem.largeTitleDisplayMode = .never
        tableView.backgroundColor = ImpressV3Appearance.page
        tableView.rowHeight = UITableView.automaticDimension
        tableView.estimatedRowHeight = 78
        let commit = UIBarButtonItem(title: V3L("全部导入"), style: .plain,
                                     target: self, action: #selector(commitBatch))
        commit.tintColor = ImpressV3Appearance.navigationActionInk
        commitButton = commit
        navigationItem.rightBarButtonItem = commit
        refreshValidation()
    }

    private func key(for candidate: ImpressV3BatchCandidate) -> String {
        let q = candidate.draft.question.trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.caseInsensitive, .diacriticInsensitive],
                     locale: Locale(identifier: "en_US_POSIX"))
        return (candidate.draft.sourceNotePath ?? "") + "\u{001F}" + q
    }

    private func problems() -> [String?] {
        var seen = Set<String>()
        return rows.map { candidate in
            if let error = candidate.problem { return error }
            if !seen.insert(key(for: candidate)).inserted { return V3L("与另一条候选问题重复。") }
            return nil
        }
    }

    private func refreshValidation() {
        let errors = problems()
        let good = errors.filter { $0 == nil }.count
        commitButton?.isEnabled = !saving && !rows.isEmpty && good == rows.count
        commitButton?.title = "导入 \(good)/\(rows.count)"
        tableView.reloadData()
    }

    override func numberOfSections(in tableView: UITableView) -> Int { 1 }
    override func tableView(_ tableView: UITableView,
                            numberOfRowsInSection section: Int) -> Int { rows.count }

    override func tableView(_ tableView: UITableView,
                            titleForHeaderInSection section: Int) -> String? {
        let valid = problems().filter { $0 == nil }.count
        return "可导入 \(valid) / \(rows.count) · 点选编辑 · 详情可查看原文"
    }

    override func tableView(_ tableView: UITableView,
                            cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "candidate")
            ?? UITableViewCell(style: .subtitle, reuseIdentifier: "candidate")
        let value = rows[indexPath.row]
        let issue = problems()[indexPath.row]
        var cfg = UIListContentConfiguration.subtitleCell()
        cfg.text = value.draft.question.isEmpty
            ? "第 \(value.line) 行 · 待填写问题"
            : value.draft.question
        cfg.secondaryText = issue.map { "第 \(value.line) 行 · " + $0 }
            ?? "第 \(value.line) 行 · 校验通过"
        cfg.secondaryTextProperties.color = issue == nil ? ImpressV3Appearance.secondaryText : ImpressV3Appearance.caution
        cfg.textProperties.numberOfLines = 2
        cfg.secondaryTextProperties.numberOfLines = 2
        cfg.image = UIImage(systemName: issue == nil ? "checkmark.circle" : "exclamationmark.circle")
        cfg.imageProperties.tintColor = issue == nil ? ImpressV3Appearance.positive : ImpressV3Appearance.caution
        cell.contentConfiguration = cfg
        ImpressV3Appearance.styleGroupedCell(cell)
        cell.accessoryType = .detailDisclosureButton
        cell.accessibilityHint = V3L("点按编辑本题，详情按钮查看原文与原始错误，左滑移除。")
        return cell
    }

    override func tableView(_ tableView: UITableView,
                            accessoryButtonTappedForRowWith indexPath: IndexPath) {
        showRawCandidate(at: indexPath.row)
    }

    private func showRawCandidate(at index: Int) {
        guard !saving, rows.indices.contains(index) else { return }
        let record = rows[index]
        let detail = UIViewController()
        detail.title = "原始记录 · 第 \(record.line) 行"
        detail.navigationItem.largeTitleDisplayMode = .never
        detail.view.backgroundColor = ImpressV3Appearance.page
        let body = UITextView()
        body.isEditable = false
        body.isSelectable = true
        body.isScrollEnabled = true
        body.font = ImpressV3Appearance.Typography.body
        body.adjustsFontForContentSizeCategory = true
        body.textColor = ImpressV3Appearance.primaryText
        body.backgroundColor = ImpressV3Appearance.surface
        body.layer.cornerRadius = ImpressV3Appearance.Radius.compactField
        body.textContainerInset = UIEdgeInsets(top: ImpressV3Appearance.Metrics.fieldPadding, left: ImpressV3Appearance.Metrics.fieldPadding,
                                              bottom: ImpressV3Appearance.Metrics.fieldPadding, right: ImpressV3Appearance.Metrics.fieldPadding)
        body.accessibilityLabel = V3L("原始导入文本及解析问题")
        let diagnostics = record.issues.isEmpty
            ? V3L("原始解析没有错误。")
            : record.issues.map { "• " + $0 }.joined(separator: "\n")
        body.text = "原始解析信息\n" + diagnostics + "\n\n原始文本（只读）\n" + record.raw
        body.translatesAutoresizingMaskIntoConstraints = false
        detail.view.addSubview(body)
        NSLayoutConstraint.activate([
            body.topAnchor.constraint(equalTo: detail.view.safeAreaLayoutGuide.topAnchor, constant: 12),
            body.leadingAnchor.constraint(equalTo: detail.view.safeAreaLayoutGuide.leadingAnchor, constant: 16),
            body.trailingAnchor.constraint(equalTo: detail.view.safeAreaLayoutGuide.trailingAnchor, constant: -16),
            body.bottomAnchor.constraint(equalTo: detail.view.safeAreaLayoutGuide.bottomAnchor, constant: -12)
        ])
        navigationController?.pushViewController(detail, animated: true)
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        guard !saving else { return }
        let candidate = rows[indexPath.row]
        let composer = ImpressV3CardComposerViewController(draft: candidate.draft)
        composer.onSave = { [weak self] input in
            // This is preview editing, NOT a database write.
            guard let self, self.rows.indices.contains(indexPath.row) else {
                throw CocoaError(.userCancelled)
            }
            self.rows[indexPath.row] = .fromValidated(input, old: self.rows[indexPath.row])
            self.refreshValidation()
        }
        let nav = UINavigationController(rootViewController: composer)
        nav.modalPresentationStyle = .pageSheet
        if #available(iOS 15.0, *) {
            nav.sheetPresentationController?.detents = [.large()]
        }
        present(nav, animated: true)
    }

    override func tableView(_ tableView: UITableView, commit editingStyle: UITableViewCell.EditingStyle,
                            forRowAt indexPath: IndexPath) {
        guard !saving, editingStyle == .delete else { return }
        rows.remove(at: indexPath.row)
        refreshValidation()
    }

    @objc private func commitBatch() {
        guard !saving, !rows.isEmpty, problems().allSatisfy({ $0 == nil }),
              onCommit != nil else { return }
        let alert = UIAlertController(title: "确认导入 \(rows.count) 张卡片？",
            message: V3L("先确保所有候选正确。本次操作使用一次 WCDB 事务，源文件不会改变。"),
            preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: V3L("返回预览"), style: .cancel))
        alert.addAction(UIAlertAction(title: V3L("确认导入"), style: .default) { [weak self] _ in
            self?.performBatchCommit()
        })
        present(alert, animated: true)
    }

    private func performBatchCommit() {
        guard !saving, !rows.isEmpty, problems().allSatisfy({ $0 == nil }),
              let commit = onCommit else { return }
        let inputs: [WCDBV3CardInput]
        do { inputs = try rows.map { try $0.draft.validatedInput() } }
        catch {
            showError(V3L("预览校验失败"), error.localizedDescription)
            return
        }
        saving = true
        refreshValidation()
        Task { [weak self] in
            guard let self else { return }
            do {
                try await commit(inputs)
                let choices = inputs.filter { $0.cardType == CardType.multipleChoice.rawValue }.count
                let images = inputs.filter { $0.cardType == CardType.image.rawValue }.count
                let qa = inputs.count - choices - images
                let alert = UIAlertController(title: "成功导入 \(inputs.count) 张卡片",
                    message: "问答 \(qa) 张 · 选择题 \(choices) 张 · 图片 \(images) 张。\n当前复习队列未重置；原始文件未修改。",
                    preferredStyle: .alert)
                alert.addAction(UIAlertAction(title: V3L("完成"), style: .default) { [weak self] _ in
                    self?.dismiss(animated: true)
                })
                self.present(alert, animated: true)
            } catch {
                self.saving = false
                self.refreshValidation()
                self.showError(V3L("导入未确认完成"), "请先核对卡片列表，再决定是否重试。整批事务不会持久化部分记录。\n" + error.localizedDescription)
            }
        }
    }

    private func showError(_ title: String, _ message: String) {
        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: V3L("确定"), style: .default))
        present(alert, animated: true)
    }
}
