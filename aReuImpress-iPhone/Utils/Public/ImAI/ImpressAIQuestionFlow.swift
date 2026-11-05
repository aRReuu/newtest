import UIKit
import ImpressReviewCore

struct ImpressAISectionItem {
    let id: String
    let heading: String
    let text: String
    /// Exact original file offsets; the rendered text is only a projection.
    let startUTF8: Int
    let endUTF8: Int
    let level: Int
    let parentID: String?
}

/// Exactly one structural parser is shared by Notes and Chat. Older
/// section-N IDs remain valid for ordinary flat ATX documents. Never infer
/// a changed/moved section from an identical title.
enum ImpressAISectionExtractor {
    static func sections(in markdown: String) -> [ImpressAISectionItem] {
        ImpressMarkdownStructure.sections(in: markdown).map { section in
            ImpressAISectionItem(id: section.id, heading: section.heading,
                text: section.text, startUTF8: section.startUTF8,
                endUTF8: section.endUTF8, level: section.level,
                parentID: section.parentID)
        }
    }

    /// Deduplicate overlapping parent/child spans *before* computing the
    /// outbound payload size. Explicit child-only selection remains narrow.
    static func effectiveSelection(_ sections: [ImpressAISectionItem],
                                   selectedIDs: Set<String>) -> [ImpressAISectionItem] {
        let selected = sections.filter { selectedIDs.contains($0.id) }.sorted {
            if $0.startUTF8 != $1.startUTF8 { return $0.startUTF8 < $1.startUTF8 }
            return $0.endUTF8 > $1.endUTF8
        }
        var effective: [ImpressAISectionItem] = []
        for section in selected {
            if effective.contains(where: {
                $0.startUTF8 <= section.startUTF8 && section.endUTF8 <= $0.endUTF8
            }) { continue }
            effective.append(section)
        }
        return effective
    }
}

/// Small, deterministic source-linking adapter for the EXISTING question
/// candidate pool and its original WCDB card. One unambiguous reviewed
/// section receives a v3 content anchor; multi-section or ambiguous evidence
/// deliberately retains the earlier file-level v2 identity.
enum ImpressAINoteCardLink {
    static func sourceKey(identity: ImVaultFileIdentity,
                          documentDigest: String,
                          candidateEvidenceIDs: [String],
                          excerpts: [ImpressAIExcerpt],
                          sourceMarkdown: String) throws -> String {
        let fallback = try ImpressBatchSourceKey.encode(
            identity, documentDigest: documentDigest)
        guard candidateEvidenceIDs.count == 1,
              let referenced = candidateEvidenceIDs.first else { return fallback }
        let selected = excerpts.filter { $0.id == referenced }
        guard selected.count == 1 else { return fallback }
        let matching = ImpressAISectionExtractor.sections(in: sourceMarkdown).filter {
            $0.text == selected[0].text
        }
        guard matching.count == 1 else { return fallback }
        return try ImpressBatchSourceKey.encode(
            identity, documentDigest: documentDigest,
            anchoredSection: matching[0].text)
    }

    /// This means only that exactly one original source section still has
    /// identical verified content. It does NOT certify the card's answer.
    /// Legacy v1/v2 links have no section anchor and require manual review.
    static func verifiedSectionUnchanged(sourceKey: String,
                                         currentMarkdown: String) -> Bool {
        guard let digest = try? ImpressBatchSourceKey.sectionDigest(for: sourceKey)
        else { return false }
        let matches = ImpressAISectionExtractor.sections(in: currentMarkdown).filter {
            ImVaultDigest.sha256(Data($0.text.utf8)) == digest
        }
        return matches.count == 1
    }
}

/// Must run after the user confirms the exact material range but before
/// the HTTP request. Selection UI is not authorization to upload a stale
/// source snapshot from an Obsidian File Provider.
enum ImpressAIQuestionSendGate {
    static func validate(source: ImpressAISource,
                         excerpts: [ImpressAIExcerpt],
                         live: ImVaultRawDocument) throws {
        guard live.identity.vaultID == source.vaultID,
              live.identity.relativePath == source.relativePath,
              live.digest == source.documentSHA256,
              !excerpts.isEmpty else {
            throw ImVaultSyncFailure.conflict
        }
        let sections = ImpressAISectionExtractor.sections(in: live.markdown)
        guard excerpts.allSatisfy({ reference in
            reference.source == source &&
                sections.contains(where: { $0.id == reference.id &&
                    $0.heading == (reference.sectionHeading ?? "") &&
                    $0.text == reference.text })
        }) else {
            throw ImVaultSyncFailure.conflict
        }
    }
}

@MainActor
final class ImpressAIQuestionGenerationViewController: UITableViewController {
    private let document: ImVaultRawDocument
    private let sections: [ImpressAISectionItem]
    private var selected: Set<String>
    private let quantityLabel = UILabel()
    private let stepper = UIStepper()
    private var running = false
    private var checkedSavedPool = false

    init(document: ImVaultRawDocument) {
        self.document = document
        sections = ImpressAISectionExtractor.sections(in: document.markdown)
        let total = document.markdown.utf8.count
        selected = total <= 24_000 ? Set(sections.map(\.id)) : Set(sections.prefix(1).map(\.id))
        super.init(style: .insetGrouped)
    }
    required init?(coder: NSCoder) { fatalError("init(document:)") }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = V3L("生成综合问题")
        tableView.backgroundColor = ImpressV3Appearance.page
        tableView.allowsMultipleSelection = false
        navigationItem.rightBarButtonItem = UIBarButtonItem(
            title: V3L("生成"), style: .plain, target: self, action: #selector(startGeneration))
        stepper.minimumValue = 1
        stepper.maximumValue = 20
        stepper.value = 5
        stepper.addTarget(self, action: #selector(updateCount), for: .valueChanged)
        quantityLabel.font = ImpressV3Appearance.Typography.body
        quantityLabel.textColor = ImpressV3Appearance.primaryText
        updateCount()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        guard !checkedSavedPool else { return }
        checkedSavedPool = true
        do {
            guard let saved = try ImVaultPrivateStore.loadQuestionPool(
                identity: document.identity) else { return }
            guard saved.source.documentSHA256 == document.digest else {
                let alert = UIAlertController(title: V3L("源笔记已发生变化"),
                    message: V3L("旧候选池已保留，但来源版本不一致，禁止直接导入。请重新生成问题。"),
                    preferredStyle: .alert)
                alert.addAction(UIAlertAction(title: V3L("确定"), style: .default))
                present(alert, animated: true)
                return
            }
            let alert = UIAlertController(title: V3L("恢复未完成的候选池？"),
                message: "\(saved.candidates.count) \(V3L("道候选题已在本机安全保存；恢复不会修改 Obsidian 或 FSRS。"))",
                preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: V3L("重新生成"), style: .cancel))
            alert.addAction(UIAlertAction(title: V3L("恢复候选池"), style: .default) { [weak self] _ in
                guard let self else { return }
                let audited = ImpressAIQuestionValidator.audit(saved)
                self.navigationController?.pushViewController(
                    ImpressAIQuestionPoolViewController(document: self.document, pool: audited),
                    animated: true)
            })
            present(alert, animated: true)
        } catch { showFailure(error) }
    }

    @objc private func updateCount() {
        quantityLabel.text = "\(Int(stepper.value)) \(V3L("道综合题"))"
    }
    override func numberOfSections(in tableView: UITableView) -> Int { 2 }
    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        section == 0 ? 1 : sections.count
    }
    override func tableView(_ tableView: UITableView,
                            titleForHeaderInSection section: Int) -> String? {
        section == 0 ? V3L("出题数量") : V3L("选择要分析的笔记章节")
    }
    override func tableView(_ tableView: UITableView,
                            titleForFooterInSection section: Int) -> String? {
        section == 0
            ? V3L("默认5道综合理解与应用题，不要求AI为凑数量编造内容。")
            : V3L("只上传勾选章节及其文本，原始 Obsidian 文件保持只读。")
    }
    override func tableView(_ tableView: UITableView,
                            cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = UITableViewCell(style: .subtitle, reuseIdentifier: nil)
        ImpressV3Appearance.styleGroupedCell(cell)
        if indexPath.section == 0 {
            cell.selectionStyle = .none
            let row = UIStackView(arrangedSubviews: [quantityLabel, stepper])
            row.axis = .horizontal
            row.spacing = 12
            row.distribution = .equalSpacing
            cell.contentView.addSubview(row)
            row.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                row.leadingAnchor.constraint(equalTo: cell.contentView.leadingAnchor, constant: 16),
                row.trailingAnchor.constraint(equalTo: cell.contentView.trailingAnchor, constant: -16),
                row.topAnchor.constraint(equalTo: cell.contentView.topAnchor, constant: 12),
                row.bottomAnchor.constraint(equalTo: cell.contentView.bottomAnchor, constant: -12)
            ])
        } else {
            let item = sections[indexPath.row]
            var ui = UIListContentConfiguration.subtitleCell()
            ui.text = String(repeating: "  ", count: max(0, item.level - 1)) +
                (item.heading.isEmpty ? V3L("未命名章节") : item.heading)
            ui.secondaryText = "\(item.text.count) \(V3L("字符"))"
            ui.textProperties.font = ImpressV3Appearance.Typography.body
            cell.contentConfiguration = ui
            cell.accessoryType = selected.contains(item.id) ? .checkmark : .none
        }
        return cell
    }
    override func tableView(_ tableView: UITableView,
                            didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        guard indexPath.section == 1 else { return }
        let item = sections[indexPath.row]
        if selected.contains(item.id) { selected.remove(item.id) }
        else { selected.insert(item.id) }
        tableView.reloadRows(at: [indexPath], with: .none)
    }

    @objc private func startGeneration() {
        guard !running else { return }
        #if DEBUG
        if ImpressV11UITestFixture.enabled &&
           document.identity.vaultID == ImpressV11UITestFixture.vaultID {
            startSyntheticGeneration()
            return
        }
        #endif
        let config = ImpressAIConfigStore.shared.registry
        let resolved: ImpressAIResolvedRoute
        do { resolved = try config.resolve(.questionGeneration) }
        catch { showFailure(error); return }
        let chosen = ImpressAISectionExtractor.effectiveSelection(
            sections, selectedIDs: selected)
        guard !chosen.isEmpty else { showFailure(ImpressAIContractError.invalidRequest); return }
        let source = ImpressAISource(vaultID: document.identity.vaultID,
                relativePath: document.identity.relativePath,
                documentSHA256: document.digest, heading: chosen.count == 1 ? chosen[0].heading : "多章节")
        let excerpts = chosen.map { item in
            ImpressAIExcerpt(id: item.id, source: source, text: item.text, sectionHeading: item.heading)
        }
        do { _ = try ImpressAIQuestionPrompt.input(excerpts) }
        catch { showFailure(ImpressAIServiceError.tooLarge); return }
        let alert = UIAlertController(title: V3L("确认发送所选笔记？"),
            message: "\(resolved.connection.title) / \(resolved.model.identifier)\n\n" +
                V3L("只发送已勾选章节给该云端 API 服务商，不会上传整个 Vault；原文不会被修改。"),
            preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: V3L("取消"), style: .cancel))
        alert.addAction(UIAlertAction(title: V3L("生成"), style: .default) { [weak self] _ in
            self?.performGeneration(source: source, excerpts: excerpts, route: resolved)
        })
        present(alert, animated: true)
    }

    #if DEBUG
    /// Replaces the cloud model ONLY in the explicitly opted-in isolated
    /// Simulator fixture. The real section picker, consent sheet, audited
    /// candidate pool, WCDB transaction and Source SHA gates remain intact.
    private func startSyntheticGeneration() {
        let selectedSections = ImpressAISectionExtractor.effectiveSelection(
            sections, selectedIDs: selected)
        guard let first = selectedSections.first else {
            showFailure(ImpressAIContractError.invalidRequest)
            return
        }
        let source = ImpressAISource(vaultID: document.identity.vaultID,
            relativePath: document.identity.relativePath,
            documentSHA256: document.digest, heading: first.heading)
        let excerpts = selectedSections.map {
            ImpressAIExcerpt(id: $0.id, source: source, text: $0.text,
                sectionHeading: $0.heading)
        }
        let notice = UIAlertController(title: V3L("模拟器合成出题"),
            message: V3L("不会访问任何模型或网络；需要逐条审核后才允许入库。"),
            preferredStyle: .alert)
        notice.addAction(UIAlertAction(title: V3L("取消"), style: .cancel))
        notice.addAction(UIAlertAction(title: V3L("生成"), style: .default) {
            [weak self] _ in self?.performSyntheticGeneration(source: source, excerpts: excerpts)
        })
        present(notice, animated: true)
    }

    private func performSyntheticGeneration(source: ImpressAISource,
                                            excerpts: [ImpressAIExcerpt]) {
        guard !running, let evidence = excerpts.first else { return }
        running = true
        navigationItem.rightBarButtonItem?.isEnabled = false
        Task {
            defer {
                running = false
                navigationItem.rightBarButtonItem?.isEnabled = true
            }
            do {
                let live: ImVaultRawDocument = try await withCheckedThrowingContinuation {
                    (continuation: CheckedContinuation<ImVaultRawDocument, Error>) in
                    ImVaultReadSync.shared.read(document.identity) {
                        continuation.resume(with: $0)
                    }
                }
                try ImpressAIQuestionSendGate.validate(source: source,
                    excerpts: excerpts, live: live)
                let questions = [
                    ImpressAIQuestionCandidate(
                        question: "如何将一项观察转化为可验证的假设？",
                        answer: "固定来源与边界，提出可证伪的机制并验证。",
                        dimension: .mechanism, evidenceIDs: [evidence.id]),
                    ImpressAIQuestionCandidate(
                        question: "什么反例能够推翻这一解释？",
                        answer: "寻找独立反例，并重新核查原始来源和版本。",
                        dimension: .counterexample, evidenceIDs: [evidence.id])
                ]
                let profile = UUID(uuidString: "00000000-0000-4000-8000-000000000001")!
                let pool = ImpressAIQuestionPool(source: source, excerpts: excerpts,
                    requestedCount: max(2, Int(stepper.value)),
                    modelProfileID: profile, candidates: questions)
                let verified = ImpressAIQuestionValidator.audit(pool)
                try ImVaultPrivateStore.saveQuestionPool(verified)
                navigationController?.pushViewController(
                    ImpressAIQuestionPoolViewController(document: document, pool: verified),
                    animated: true)
            } catch { showFailure(error) }
        }
    }
    #endif

    private func performGeneration(source: ImpressAISource, excerpts: [ImpressAIExcerpt],
                                   route: ImpressAIResolvedRoute) {
        guard !running else { return }
        running = true
        navigationItem.rightBarButtonItem?.isEnabled = false
        title = V3L("生成中…")
        Task {
            defer {
                running = false
                navigationItem.rightBarButtonItem?.isEnabled = true
                title = V3L("生成综合问题")
            }
            do {
                // A stale note, lost File Provider authorization or changed
                // selected section MUST NOT be sent to a remote model.
                guard ImVaultReadOnlyProbe.shared.authorizedVaultID ==
                      document.identity.vaultID else {
                    throw ImVaultSyncFailure.wrongVault
                }
                let live: ImVaultRawDocument = try await withCheckedThrowingContinuation {
                    (continuation: CheckedContinuation<ImVaultRawDocument, Error>) in
                    ImVaultReadSync.shared.read(document.identity) { read in
                        continuation.resume(with: read)
                    }
                }
                guard ImVaultReadOnlyProbe.shared.authorizedVaultID ==
                      document.identity.vaultID else {
                    throw ImVaultSyncFailure.wrongVault
                }
                try ImpressAIQuestionSendGate.validate(
                    source: source, excerpts: excerpts, live: live)
                let prompt = ImpressAIQuestionPrompt.system(count: Int(stepper.value))
                let content = try ImpressAIQuestionPrompt.input(excerpts)
                let response = try await ImpressAIHTTPClient.shared.complete(
                    route: route, system: prompt, user: content)
                let questions = try ImpressAIQuestionPrompt.decode(response)
                let candidates = questions.map {
                    ImpressAIQuestionCandidate(question: $0.question, answer: $0.answer,
                        dimension: $0.dimension, evidenceIDs: $0.evidenceIDs)
                }
                let pool = ImpressAIQuestionPool(source: source, excerpts: excerpts,
                    requestedCount: Int(stepper.value), modelProfileID: route.model.id,
                    candidates: candidates)
                let audited = ImpressAIQuestionValidator.audit(pool)
                try ImVaultPrivateStore.saveQuestionPool(audited)
                let next = ImpressAIQuestionPoolViewController(document: document, pool: audited)
                navigationController?.pushViewController(next, animated: true)
            } catch { showFailure(error) }
        }
    }

    private func showFailure(_ error: Error) {
        let detail: String
        switch error as? ImpressAIContractError {
        case .unverifiedModel:
            detail = V3L("出题模型尚未通过 JSON 验证，请在 AI 服务中测试该模型后重试。")
        case .missingCredential:
            detail = V3L("出题模型未保存 API Key，请先在 AI 服务中配置凭据。")
        case .invalidRoute:
            detail = V3L("请先在 AI 服务 → 业务默认模型中选择出题模型。")
        case .disabled:
            detail = V3L("当前出题模型或连接已停用，请重新选择。")
        default:
            detail = error.localizedDescription
        }
        let alert = UIAlertController(title: V3L("无法生成问题"),
             message: detail, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: V3L("确定"), style: .default))
        present(alert, animated: true)
    }
}

@MainActor
final class ImpressAIQuestionPoolViewController: UITableViewController {
    private let document: ImVaultRawDocument
    private var pool: ImpressAIQuestionPool
    private var committing = false
    // ACCEPT-01: presenting an import authorization is already a pending
    // operation. Lock at first touch, before the user accepts or WCDB writes.
    private var importConsentPending = false

    init(document: ImVaultRawDocument, pool: ImpressAIQuestionPool) {
        self.document = document
        self.pool = pool
        super.init(style: .insetGrouped)
    }
    required init?(coder: NSCoder) { fatalError("init(document:pool:)") }
    override func viewDidLoad() {
        super.viewDidLoad()
        title = V3L("问题候选池")
        tableView.backgroundColor = ImpressV3Appearance.page
        navigationItem.rightBarButtonItem = UIBarButtonItem(
            title: V3L("加入卡片集"), style: .plain, target: self, action: #selector(confirmImport))
        updateImportButton()
    }

    private func persistCandidateEdits() {
        do { try ImVaultPrivateStore.saveQuestionPool(pool) }
        catch { showFailure(error) }
    }

    private func updateImportButton() {
        let count = pool.candidates.filter { $0.selected && $0.issues.isEmpty }.count
        navigationItem.rightBarButtonItem?.title = "\(V3L("加入")) \(count) \(V3L("张"))"
        navigationItem.rightBarButtonItem?.isEnabled =
            count > 0 && !committing && !importConsentPending
    }
    override func numberOfSections(in tableView: UITableView) -> Int { 1 }
    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        pool.candidates.count
    }
    override func tableView(_ tableView: UITableView,
                            titleForHeaderInSection section: Int) -> String? {
        "\(pool.candidates.count)/\(pool.requestedCount) \(V3L("道候选 · 点选勾选，点信息按钮编辑"))"
    }
    override func tableView(_ tableView: UITableView,
                            titleForFooterInSection section: Int) -> String? {
        V3L("来源引用仅供核对，不能单独证明答案正确。加入前请确认内容。")
    }
    override func tableView(_ tableView: UITableView,
                            cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let item = pool.candidates[indexPath.row]
        let cell = UITableViewCell(style: .subtitle, reuseIdentifier: nil)
        var content = UIListContentConfiguration.subtitleCell()
        content.text = item.question
        content.secondaryText = item.issues.isEmpty
            ? item.dimension.rawValue + " · " + pool.source.relativePath
            : item.issues.joined(separator: "、")
        content.textProperties.font = ImpressV3Appearance.Typography.body
        content.textProperties.numberOfLines = 3
        content.secondaryTextProperties.numberOfLines = 2
        cell.contentConfiguration = content
        cell.accessoryType = .detailButton
        cell.imageView?.image = nil
        cell.accessoryView = nil
        cell.tintColor = ImpressV3Appearance.accent
        // Selection state is conveyed in the question title rather than mixing
        // a checkmark accessory with the editable detail button.
        if item.selected {
            content.text = "✓ " + item.question
            cell.contentConfiguration = content
        }
        ImpressV3Appearance.styleGroupedCell(cell)
        return cell
    }
    override func tableView(_ tableView: UITableView,
                            didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        pool.candidates[indexPath.row].selected.toggle()
        persistCandidateEdits()
        tableView.reloadRows(at: [indexPath], with: .none)
        updateImportButton()
    }
    override func tableView(_ tableView: UITableView,
                            accessoryButtonTappedForRowWith indexPath: IndexPath) {
        let row = pool.candidates[indexPath.row]
        let sourceEvidence = pool.excerpts
            .filter { row.evidenceIDs.contains($0.id) }
            .map { "[" + $0.id + "] " + $0.text }
            .joined(separator: "\n\n")
        let editor = ImpressAIQuestionEditor(
            question: row.question, answer: row.answer, sourceEvidence: sourceEvidence
        ) { [weak self] question, answer in
            guard let self else { return }
            self.pool.candidates[indexPath.row].question = question
            self.pool.candidates[indexPath.row].answer = answer
            self.pool = ImpressAIQuestionValidator.audit(self.pool)
            self.persistCandidateEdits()
            self.tableView.reloadRows(at: [indexPath], with: .none)
            self.updateImportButton()
        }
        navigationController?.pushViewController(editor, animated: true)
    }
    override func tableView(_ tableView: UITableView,
                            trailingSwipeActionsConfigurationForRowAt indexPath: IndexPath)
    -> UISwipeActionsConfiguration? {
        let action = UIContextualAction(style: .destructive, title: V3L("删除")) { [weak self] _, _, finish in
            guard let self else { finish(false); return }
            self.pool.candidates.remove(at: indexPath.row)
            self.pool = ImpressAIQuestionValidator.audit(self.pool)
            self.persistCandidateEdits()
            self.tableView.deleteRows(at: [indexPath], with: .automatic)
            self.updateImportButton()
            finish(true)
        }
        return UISwipeActionsConfiguration(actions: [action])
    }
    @objc private func confirmImport() {
        guard !committing, !importConsentPending else { return }
        pool = ImpressAIQuestionValidator.audit(pool)
        tableView.reloadData()
        do { _ = try ImpressAIQuestionValidator.validatedSelection(pool) }
        catch { showFailure(error); return }
        let count = pool.candidates.filter { $0.selected }.count
        importConsentPending = true
        updateImportButton()
        let alert = UIAlertController(title: V3L("加入卡片集？"),
           message: "\(count) \(V3L("张问答卡片将进入 FSRS 复习。Obsidian 原文不会修改。"))",
           preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: V3L("取消"), style: .cancel) { [weak self] _ in
            self?.importConsentPending = false
            self?.updateImportButton()
        })
        alert.addAction(UIAlertAction(title: V3L("确认加入"), style: .default) { [weak self] _ in
            guard let self else { return }
            self.importConsentPending = false
            // performImport synchronously acquires the durable-write gate.
            self.performImport()
        })
        present(alert, animated: true)
    }

    private func readLatest() async throws -> ImVaultRawDocument {
        try await withCheckedThrowingContinuation { continuation in
            ImVaultReadSync.shared.read(document.identity) { result in
                continuation.resume(with: result)
            }
        }
    }
    private func performImport() {
        guard !committing else { return }
        committing = true
        updateImportButton()
        Task {
            defer { committing = false; updateImportButton() }
            do {
                // Fail closed if Obsidian was edited since generation.
                let live = try await readLatest()
                guard live.digest == pool.source.documentSHA256,
                      live.identity == document.identity else {
                    throw ImVaultSyncFailure.conflict
                }
                let repo = try ImpressV3ReviewEnvironment.repository()
                var existing: [String] = []
                var offset = 0
                while offset < 20_000 {
                    let batch = try await repo.listManagedCards(matching: "", offset: offset, limit: 200)
                    existing += batch.map(\.question)
                    if batch.count < 200 { break }
                    offset += batch.count
                }
                // Database transaction remains the final duplicate authority.
                let checked = ImpressAIQuestionValidator.audit(pool, existingQuestions: existing)
                let selected = try ImpressAIQuestionValidator.validatedSelection(checked, existingQuestions: existing)
                let now = Date()
                let calc = FSRS6ReviewCalculator()
                let entries = try selected.map { candidate -> (input: WCDBV3CardInput, initial: ReviewScheduleSnapshot) in
                    let sourceKey = try ImpressAINoteCardLink.sourceKey(
                        identity: live.identity, documentDigest: live.digest,
                        candidateEvidenceIDs: candidate.evidenceIDs,
                        excerpts: pool.excerpts, sourceMarkdown: live.markdown)
                    let input = WCDBV3CardInput(question: candidate.question,
                         answerText: candidate.answer, cardType: CardType.standard.rawValue,
                         sourceNotePath: sourceKey)
                    return (input: input, initial: try calc.newCardSnapshot(id: input.cardID, now: now))
                }
                try await repo.insertBatchCards(entries, now: now)
                // WCDB is already committed; cleanup failure must not misreport
                // the cards as unsaved. Any retained draft is still local only.
                try? ImVaultPrivateStore.deleteQuestionPool(identity: document.identity)
                let alert = UIAlertController(title: V3L("卡片已添加"),
                   message: "\(selected.count) \(V3L("张卡片已保存到 V3 卡片集。"))",
                   preferredStyle: .alert)
                alert.addAction(UIAlertAction(title: V3L("完成"), style: .default) { [weak self] _ in
                    self?.navigationController?.popToRootViewController(animated: true)
                })
                present(alert, animated: true)
            } catch { showFailure(error) }
        }
    }
    private func showFailure(_ error: Error) {
        let alert = UIAlertController(title: V3L("无法保存卡片"),
            message: error.localizedDescription, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: V3L("确定"), style: .default))
        present(alert, animated: true)
    }
}

@MainActor
private final class ImpressAIQuestionEditor: UIViewController {
    private let question = UITextView()
    private let answer = UITextView()
    private let evidence = UITextView()
    private let onSave: (String, String) -> Void
    init(question: String, answer: String, sourceEvidence: String,
         onSave: @escaping (String, String) -> Void) {
        self.onSave = onSave
        super.init(nibName: nil, bundle: nil)
        self.question.text = question
        self.answer.text = answer
        self.evidence.text = sourceEvidence
    }
    required init?(coder: NSCoder) { fatalError("init(coder:)") }
    override func viewDidLoad() {
        super.viewDidLoad()
        title = V3L("编辑候选题")
        view.backgroundColor = ImpressV3Appearance.page
        let title1 = UILabel()
        title1.text = V3L("问题")
        let title2 = UILabel()
        title2.text = V3L("参考答案")
        let title3 = UILabel()
        title3.text = V3L("来源依据（只读）")
        for field in [question, answer] {
            field.font = ImpressV3Appearance.Typography.body
            field.backgroundColor = ImpressV3Appearance.surface
            field.textColor = ImpressV3Appearance.primaryText
            field.layer.cornerRadius = ImpressV3Appearance.Radius.field
            field.isScrollEnabled = true
            ImpressSpeechAccessory.install(on: field)
        }
        evidence.isEditable = false
        evidence.isSelectable = true
        evidence.font = ImpressV3Appearance.Typography.supporting
        evidence.textColor = ImpressV3Appearance.secondaryText
        evidence.backgroundColor = ImpressV3Appearance.surface
        evidence.layer.cornerRadius = ImpressV3Appearance.Radius.field
        let stack = UIStackView(arrangedSubviews: [title1, question, title2, answer, title3, evidence])
        stack.axis = .vertical
        stack.spacing = ImpressV3Appearance.Metrics.rowSpacing
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 16),
            stack.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -16),
            stack.bottomAnchor.constraint(equalTo: view.keyboardLayoutGuide.topAnchor, constant: -12),
            question.heightAnchor.constraint(equalTo: answer.heightAnchor, multiplier: 0.55),
            evidence.heightAnchor.constraint(equalToConstant: 110)
        ])
        navigationItem.rightBarButtonItem = UIBarButtonItem(
            title: V3L("保存"), style: .plain, target: self, action: #selector(save))
    }
    @objc private func save() {
        onSave(question.text ?? "", answer.text ?? "")
        navigationController?.popViewController(animated: true)
    }
}
