import UIKit
import ImpressReviewCore

// A local-only filter shared by model catalogs and task selection.
@MainActor
private enum ImpressAIModelSearchFilter {
    static func apply(_ models: [ImpressAIModel], query: String) -> [ImpressAIModel] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return models }
        let connections = ImpressAIConfigStore.shared.registry.connections
        return models.filter { model in
            model.identifier.localizedStandardContains(needle) ||
            connections.first(where: { $0.id == model.connectionID })?
                .title.localizedStandardContains(needle) == true
        }
    }
}


// Native settings: one provider may have many independent connections/keys and
// each connection may have several models. No API secret goes into a cell subtitle.
@MainActor
final class ImpressAISettingsViewController: UITableViewController {
    private let tasks: [ImpressAITask] = [.questionGeneration, .knowledgeSynthesis, .conversation]

    init() { super.init(style: .insetGrouped) }
    required init?(coder: NSCoder) { fatalError("init(coder:)") }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = V3L("AI 服务")
        tableView.backgroundColor = ImpressV3Appearance.page
        tableView.rowHeight = UITableView.automaticDimension
        navigationItem.rightBarButtonItem = ImpressV3Appearance.navigationAction(
            symbol: "plus", label: V3L("添加 API 连接"),
            target: self, action: #selector(addConnection))
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        tableView.reloadData()
    }

    override func numberOfSections(in tableView: UITableView) -> Int { 3 }
    override func tableView(_ tableView: UITableView,
                            numberOfRowsInSection section: Int) -> Int {
        switch section {
        case 0:
            let count = ImpressAIConfigStore.shared.registry.connections.count
            return count + (count > 0 ? 1 : 0) // Explicit remove-all row
        case 1: return tasks.count
        default: return 3
        }
    }
    override func tableView(_ tableView: UITableView,
                            titleForHeaderInSection section: Int) -> String? {
        [V3L("API 连接"), V3L("业务默认模型"), V3L("隐私与数据边界")][section]
    }
    override func tableView(_ tableView: UITableView,
                            titleForFooterInSection section: Int) -> String? {
        switch section {
        case 0: return V3L("每个连接独立保存 API Key，可添加多个服务商和模型。")
        case 1: return V3L("指定笔记出题需要先测试模型 JSON 能力。不会自动跨服务商发送笔记。")
        default: return V3L("仅在你明确确认生成时发送选定的笔记内容；API Key 留在本机 Keychain。")
        }
    }

    private func taskTitle(_ task: ImpressAITask) -> String {
        switch task {
        case .questionGeneration: return V3L("指定笔记出题")
        case .knowledgeSynthesis: return V3L("知识重构（尚未启用）")
        case .conversation: return V3L("原生对话")
        }
    }

    override func tableView(_ tableView: UITableView,
                            cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = UITableViewCell(style: .subtitle, reuseIdentifier: nil)
        var content = UIListContentConfiguration.subtitleCell()
        let config = ImpressAIConfigStore.shared.registry
        switch indexPath.section {
        case 0:
            if indexPath.row == config.connections.count {
                content.text = V3L("删除全部 API 连接")
                content.secondaryText = V3L("同时删除对应模型、业务选择及本机密钥")
                content.image = UIImage(systemName: "trash")
            } else {
                let c = config.connections[indexPath.row]
                let count = config.models.filter { $0.connectionID == c.id }.count
                content.text = c.title
                content.secondaryText = c.effectiveAuthentication == .noAuthentication
                    ? "\(count) \(V3L("个模型")) · \(V3L("无需密钥"))"
                    : "\(c.provider.rawValue) · \(count) \(V3L("个模型"))"
                content.image = UIImage(systemName: "server.rack")
            }
        case 1:
            let task = tasks[indexPath.row]
            content.text = taskTitle(task)
            if let route = config.routes.first(where: { $0.task == task }),
               let model = config.models.first(where: { $0.id == route.primaryModelID }),
               let connection = config.connections.first(where: { $0.id == model.connectionID }) {
                content.secondaryText = connection.title + " · " + model.identifier
            } else { content.secondaryText = V3L("未配置") }
            content.image = UIImage(systemName: "arrow.triangle.branch")
        default:
            if indexPath.row == 0 {
                content.text = V3L("数据上传规则")
                content.secondaryText = V3L("按需授权、仅上传选定文档、不会修改原始 Vault")
                content.image = UIImage(systemName: "lock.shield")
            } else if indexPath.row == 1 {
                content.text = V3L("AI 讨论")
                content.secondaryText = V3L("使用对话模型进行原生多轮讨论")
                content.image = UIImage(systemName: "bubble.left.and.bubble.right")
            } else {
                content.text = V3L("默认对话提示词")
                content.secondaryText = ImpressAIChatPromptSelection.selectedTemplate()?.title ??
                    V3L("第一性原理 + 奥卡姆剃刀")
                content.image = UIImage(systemName: "text.alignleft")
            }
        }
        content.textProperties.font = ImpressV3Appearance.Typography.body
        content.secondaryTextProperties.font = ImpressV3Appearance.Typography.supporting
        content.secondaryTextProperties.numberOfLines = 3
        content.imageProperties.tintColor = ImpressV3Appearance.listIconTint
        content.imageProperties.maximumSize = CGSize(width: 20, height: 20)
        cell.contentConfiguration = content
        ImpressV3Appearance.styleGroupedCell(cell)
        cell.accessoryType = indexPath.section == 0 &&
            indexPath.row == config.connections.count ? .none : .disclosureIndicator
        return cell
    }

    override func tableView(_ tableView: UITableView,
                            didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        switch indexPath.section {
        case 0:
            let all = ImpressAIConfigStore.shared.registry.connections
            if indexPath.row == all.count {
                confirmRemoveAll()
                return
            }
            guard all.indices.contains(indexPath.row) else { return }
            navigationController?.pushViewController(
                ImpressAIConnectionEditor(connectionID: all[indexPath.row].id), animated: true)
        case 1:
            navigationController?.pushViewController(
                ImpressAIModelChooser(task: tasks[indexPath.row]), animated: true)
        default:
            if indexPath.row == 1 {
                navigationController?.pushViewController(
                    ImpressAINativeChatViewController(), animated: true)
                return
            }
            if indexPath.row == 2 {
                chooseDefaultChatPrompt()
                return
            }
            let alert = UIAlertController(title: V3L("数据上传规则"),
                message: V3L("云端模型会接收你明确选择的笔记片段。服务商可能根据各自政策处理请求；不会默认上传整个 Obsidian Vault。所有自动写回仍被生产安全门禁关闭。"),
                preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: V3L("知道了"), style: .default))
            present(alert, animated: true)
        }
    }

    override func tableView(_ tableView: UITableView,
                            trailingSwipeActionsConfigurationForRowAt indexPath: IndexPath)
    -> UISwipeActionsConfiguration? {
        let connections = ImpressAIConfigStore.shared.registry.connections
        guard indexPath.section == 0, connections.indices.contains(indexPath.row) else {
            return nil
        }
        let id = connections[indexPath.row].id
        let remove = UIContextualAction(style: .destructive, title: V3L("删除")) {
            [weak self] _, _, done in
            done(false) // The source row remains until the user confirms.
            self?.confirmRemoveConnection(id)
        }
        return UISwipeActionsConfiguration(actions: [remove])
    }

    private func confirmRemoveConnection(_ id: UUID) {
        guard let item = ImpressAIConfigStore.shared.registry.connections.first(where: { $0.id == id })
        else { return }
        let alert = UIAlertController(title: V3L("删除 API 连接？"),
            message: item.title + "\n" +
                V3L("这将删除当前连接、关联模型、业务选择及未被其他连接使用的 Keychain 密钥。"),
            preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: V3L("取消"), style: .cancel))
        alert.addAction(UIAlertAction(title: V3L("删除"), style: .destructive) { [weak self] _ in
            do {
                try ImpressAIConfigStore.shared.deleteConnection(id: id)
                self?.tableView.reloadData()
            } catch { self?.showFailure(error) }
        })
        present(alert, animated: true)
    }

    private func confirmRemoveAll() {
        let count = ImpressAIConfigStore.shared.registry.connections.count
        guard count > 0 else { return }
        let alert = UIAlertController(title: V3L("删除全部 API 连接？"),
            message: "\(count) " + V3L("个连接及其模型、业务默认选择和凭据将被清除，不会删除已有卡片与笔记。"),
            preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: V3L("取消"), style: .cancel))
        alert.addAction(UIAlertAction(title: V3L("确认全部删除"),
            style: .destructive) { [weak self] _ in
                do {
                    try ImpressAIConfigStore.shared.deleteAllConnections()
                    self?.tableView.reloadData()
                } catch { self?.showFailure(error) }
            })
        present(alert, animated: true)
    }

    private func chooseDefaultChatPrompt() {
        let alert = UIAlertController(title: V3L("默认对话提示词"),
            message: V3L("默认使用第一性原理与奥卡姆剃刀，也可选用「提示词」中编辑过的模板。仅在你点击发送时传给当前模型。"),
            preferredStyle: .actionSheet)
        alert.addAction(UIAlertAction(title: V3L("第一性原理 + 奥卡姆剃刀"),
            style: .default) { _ in
                ImpressAIChatPromptSelection.choose(nil)
                self.tableView.reloadData()
            })
        for template in ImpressV3PromptLibrary.load() {
            alert.addAction(UIAlertAction(title: template.title, style: .default) { _ in
                ImpressAIChatPromptSelection.choose(template.id)
                self.tableView.reloadData()
            })
        }
        alert.addAction(UIAlertAction(title: V3L("打开提示词库编辑"),
            style: .default) { _ in
                self.navigationController?.pushViewController(
                    ImpressV3PromptLibraryViewController(), animated: true)
            })
        alert.addAction(UIAlertAction(title: V3L("取消"), style: .cancel))
        present(alert, animated: true)
    }

    @objc private func addConnection() {
        let sheet = UIAlertController(title: V3L("选择服务商"), message: nil, preferredStyle: .actionSheet)
        // Presets are convenience only. "Custom API" always accepts arbitrary
        // HTTPS providers and manual model IDs. Gateways may offer mixed wire
        // protocols and retain independent user API keys.
        let presets: [(String, ImpressAIProvider, ImpressAIProtocol, String)] = [
            ("Claude", .anthropic, .anthropicMessages, "https://api.anthropic.com/v1"),
            ("OpenAI", .openAI, .responses, "https://api.openai.com/v1"),
            ("Gemini", .gemini, .geminiGenerateContent, "https://generativelanguage.googleapis.com/v1beta"),
            ("DeepSeek", .deepSeek, .chatCompletions, "https://api.deepseek.com"),
            (V3L("自定义 API"), .custom, .chatCompletions, "https://api.example.com/v1")
        ]
        for (label, provider, wire, url) in presets {
            sheet.addAction(UIAlertAction(title: label, style: .default) { [weak self] _ in
                guard let self, let endpoint = URL(string: url) else { return }
                let profile = ImpressAIConnection(title: label, provider: provider,
                    apiProtocol: wire, baseURL: endpoint)
                do {
                    try ImpressAIConfigStore.shared.update { $0.connections.append(profile) }
                    self.navigationController?.pushViewController(
                        ImpressAIConnectionEditor(connectionID: profile.id), animated: true)
                } catch { self.showFailure(error) }
            })
        }
        sheet.addAction(UIAlertAction(title: V3L("取消"), style: .cancel))
        sheet.popoverPresentationController?.barButtonItem = navigationItem.rightBarButtonItem
        present(sheet, animated: true)
    }

    private func showFailure(_ error: Error) {
        let alert = UIAlertController(title: V3L("操作失败"),
              message: error.localizedDescription, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: V3L("确定"), style: .default))
        present(alert, animated: true)
    }
}

@MainActor
final class ImpressAIConnectionEditor: UITableViewController {
    private let connectionID: UUID
    init(connectionID: UUID) {
        self.connectionID = connectionID
        super.init(style: .insetGrouped)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:)") }
    private var connection: ImpressAIConnection? {
        ImpressAIConfigStore.shared.registry.connections.first(where: { $0.id == connectionID })
    }
    override func viewDidLoad() {
        super.viewDidLoad()
        title = V3L("API 连接")
        tableView.backgroundColor = ImpressV3Appearance.page
    }
    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        tableView.reloadData()
    }
    override func numberOfSections(in tableView: UITableView) -> Int { 2 }
    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        section == 0 ? 8 : 1
    }
    override func tableView(_ tableView: UITableView,
                            cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = UITableViewCell(style: .value1, reuseIdentifier: nil)
        let c = connection
        let labels = [V3L("连接名称"), V3L("服务商 / 协议"),
                      "Base URL", "API Key", V3L("认证方式"),
                      V3L("自定义 Header 名称"), V3L("模型列表"),
                      V3L("API 接口路径")]
        cell.textLabel?.text = indexPath.section == 0 ? labels[indexPath.row] : V3L("删除连接")
        cell.textLabel?.font = ImpressV3Appearance.Typography.body
        cell.textLabel?.textColor = indexPath.section == 1
            ? ImpressV3Appearance.secondaryText : ImpressV3Appearance.primaryText
        if indexPath.section == 0 {
            let models = ImpressAIConfigStore.shared.registry.models
            let values = [c?.title ?? "", (c?.provider.rawValue ?? "") + " / " + (c?.apiProtocol.rawValue ?? ""),
                          c?.baseURL.host ?? "",
                          c?.effectiveAuthentication == .noAuthentication
                              ? V3L("无需密钥") :
                              (c?.credentialID == nil ? V3L("未保存") : V3L("已保存")),
                          c?.effectiveAuthentication.rawValue ?? "",
                          c?.customHeaderName ?? "—",
                          "\(models.filter { $0.connectionID == connectionID }.count)",
                          c?.effectiveEndpoints.modelsPath ?? "models"]
            cell.detailTextLabel?.text = values[indexPath.row]
            cell.accessoryType = .disclosureIndicator
        }
        ImpressV3Appearance.styleGroupedCell(cell)
        return cell
    }
    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        if indexPath.section == 1 { confirmDelete(); return }
        switch indexPath.row {
        case 0: editText(title: V3L("连接名称"), secure: false, value: connection?.title ?? "") { [weak self] value in
            self?.edit { $0.title = value }
        }
        case 1: chooseProtocol()
        case 2: editText(title: "Base URL", secure: false,
                         value: connection?.baseURL.absoluteString ?? "") { [weak self] value in
            guard let url = URL(string: value) else { self?.showError(ImpressAIServiceError.invalidURL); return }
            self?.edit { $0.baseURL = url }
        }
        case 3: editKeychainCredential()
        case 4: chooseAuthentication()
        case 5: editText(title: V3L("自定义 Header 名称"), secure: false,
                         value: connection?.customHeaderName ?? "") { [weak self] value in
            self?.edit { $0.customHeaderName = value.trimmingCharacters(in: .whitespacesAndNewlines) }
        }
        case 6:
            navigationController?.pushViewController(
                ImpressAIModelsViewController(connectionID: connectionID), animated: true)
        case 7: chooseEndpointPath()
        default: break
        }
    }
    private func editKeychainCredential() {
        guard let current = connection else { return }
        guard current.credentialID != nil else {
            promptForNewKey()
            return
        }
        let sheet = UIAlertController(title: "API Key", message: nil, preferredStyle: .actionSheet)
        sheet.addAction(UIAlertAction(title: V3L("更新 API Key"), style: .default) {
            [weak self] _ in self?.promptForNewKey()
        })
        sheet.addAction(UIAlertAction(title: V3L("删除已保存 API Key"), style: .destructive) {
            [weak self] _ in self?.confirmRemoveKey()
        })
        sheet.addAction(UIAlertAction(title: V3L("取消"), style: .cancel))
        sheet.popoverPresentationController?.sourceView = tableView
        sheet.popoverPresentationController?.sourceRect = tableView.bounds
        present(sheet, animated: true)
    }

    private func confirmRemoveKey() {
        let alert = UIAlertController(title: V3L("删除已保存 API Key？"),
            message: V3L("只移除当前连接的本机密钥并撤销模型验证状态，不会删除现有卡片或笔记。"),
            preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: V3L("取消"), style: .cancel))
        alert.addAction(UIAlertAction(title: V3L("删除"), style: .destructive) { [weak self] _ in
            guard let self else { return }
            do {
                try ImpressAIConfigStore.shared.clearCredential(connectionID: self.connectionID)
                self.tableView.reloadData()
            } catch { self.showError(error) }
        })
        present(alert, animated: true)
    }

    private func promptForNewKey() {
        editText(title: "API Key", secure: true, value: "") { [weak self] value in
            guard let self else { return }
            do {
                guard let current = self.connection else { throw ImpressAIServiceError.configuration }
                let id = current.credentialID ?? UUID()
                // Roll back the previous Keychain value if persisting the
                // connection metadata fails. Never log or serialize raw tokens.
                let oldValue = try? ImpressAIKeychain.read(id: current.credentialID)
                try ImpressAIKeychain.write(value, id: id)
                do {
                    try ImpressAIConfigStore.shared.update { reg in
                        guard let index = reg.connections.firstIndex(where: { $0.id == self.connectionID })
                        else { throw ImpressAIServiceError.configuration }
                        reg.connections[index].credentialID = id
                        if ImpressAIOpenCodeFreeQA.isQAProfile(reg.connections[index]) {
                            reg.connections[index].freeQAOnly = true
                            reg.connections[index].authentication = .bearer
                        }
                        for i in reg.models.indices where reg.models[i].connectionID == self.connectionID {
                            reg.models[i].jsonVerified = false
                            reg.models[i].toolsVerified = false
                            reg.models[i].supportsImageInput = nil
                        }
                    }
                } catch {
                    if let oldValue {
                        try? ImpressAIKeychain.write(oldValue, id: id)
                    } else {
                        ImpressAIKeychain.delete(id: id)
                    }
                    throw error
                }
                self.tableView.reloadData()
            } catch { self.showError(error) }
        }
    }

    private func edit(_ modify: (inout ImpressAIConnection) -> Void) {
        do {
            try ImpressAIConfigStore.shared.update { reg in
                guard let index = reg.connections.firstIndex(where: { $0.id == self.connectionID }) else {
                    throw ImpressAIServiceError.configuration
                }
                let previous = reg.connections[index]
                // Upgrading an old unflagged QA profile before a rename avoids
                // accidentally turning its free-only credentials into a
                // unrestricted account profile.
                if ImpressAIOpenCodeFreeQA.isQAProfile(previous) {
                    reg.connections[index].freeQAOnly = true
                }
                modify(&reg.connections[index])
                let updated = reg.connections[index]
                // A model probe is bound to its endpoint and auth settings.
                // Do not keep JSON verified after switching a destination.
                if previous.baseURL != updated.baseURL ||
                   previous.apiProtocol != updated.apiProtocol ||
                   previous.authentication != updated.authentication ||
                   previous.customHeaderName != updated.customHeaderName ||
                   previous.endpoints != updated.endpoints {
                    for i in reg.models.indices
                        where reg.models[i].connectionID == self.connectionID {
                        reg.models[i].jsonVerified = false
                        reg.models[i].toolsVerified = false
                        reg.models[i].supportsImageInput = nil
                    }
                }
            }
            tableView.reloadData()
        } catch { showError(error) }
    }
    private func editText(title: String, secure: Bool, value: String,
                          onSave: @escaping (String) -> Void) {
        let alert = UIAlertController(title: title, message: nil, preferredStyle: .alert)
        alert.addTextField {
            $0.text = value
            $0.isSecureTextEntry = secure
            $0.autocapitalizationType = .none
            $0.autocorrectionType = .no
        }
        alert.addAction(UIAlertAction(title: V3L("取消"), style: .cancel))
        alert.addAction(UIAlertAction(title: V3L("保存"), style: .default) { _ in
            onSave(alert.textFields?.first?.text ?? "")
        })
        present(alert, animated: true)
    }
    private func chooseProtocol() {
        guard let c = connection else { return }
        let sheet = UIAlertController(title: V3L("协议类型"), message: nil, preferredStyle: .actionSheet)
        for wire in ImpressAIProtocol.allCases
            where ImpressAIRegistry.supported(wire, for: c.provider) {
            sheet.addAction(UIAlertAction(title: wire.rawValue, style: .default) { [weak self] _ in
                self?.edit { $0.apiProtocol = wire }
            })
        }
        sheet.addAction(UIAlertAction(title: V3L("取消"), style: .cancel))
        sheet.popoverPresentationController?.sourceView = tableView
        sheet.popoverPresentationController?.sourceRect = tableView.bounds
        present(sheet, animated: true)
    }

    private func chooseAuthentication() {
        let sheet = UIAlertController(title: V3L("认证方式"), message: nil, preferredStyle: .actionSheet)
        for option in ImpressAIAuthentication.allCases {
            sheet.addAction(UIAlertAction(title: option.rawValue, style: .default) { [weak self] _ in
                guard let self else { return }
                if option == .customHeader {
                    self.editText(title: V3L("自定义 Header 名称"), secure: false,
                                  value: self.connection?.customHeaderName ?? "") { [weak self] name in
                        self?.edit {
                            $0.customHeaderName = name.trimmingCharacters(in: .whitespacesAndNewlines)
                            $0.authentication = .customHeader
                        }
                    }
                } else {
                    self.edit { $0.authentication = option }
                }
            })
        }
        sheet.addAction(UIAlertAction(title: V3L("取消"), style: .cancel))
        sheet.popoverPresentationController?.sourceView = tableView
        sheet.popoverPresentationController?.sourceRect = tableView.bounds
        present(sheet, animated: true)
    }

    private func chooseEndpointPath() {
        guard let c = connection else { return }
        let routes = c.effectiveEndpoints
        let sheet = UIAlertController(title: V3L("API 接口路径"), message: nil,
                                      preferredStyle: .actionSheet)
        let choices: [(String, WritableKeyPath<ImpressAIEndpointPaths, String>)] = [
            ("Models GET", \.modelsPath),
            ("Chat Completions", \.chatPath),
            ("Responses", \.responsesPath),
            ("Messages", \.messagesPath)
        ]
        for (name, key) in choices {
            sheet.addAction(UIAlertAction(title: name + " · " + routes[keyPath: key],
                                           style: .default) { [weak self] _ in
                self?.editText(title: name, secure: false, value: routes[keyPath: key]) { value in
                    self?.edit { connection in
                        var paths = connection.effectiveEndpoints
                        paths[keyPath: key] = value.trimmingCharacters(in: .whitespacesAndNewlines)
                        connection.endpoints = paths
                    }
                }
            })
        }
        sheet.addAction(UIAlertAction(title: V3L("取消"), style: .cancel))
        sheet.popoverPresentationController?.sourceView = tableView
        sheet.popoverPresentationController?.sourceRect = tableView.bounds
        present(sheet, animated: true)
    }
    private func confirmDelete() {
        let a = UIAlertController(title: V3L("删除 API 连接？"),
                      message: V3L("连接、其模型和业务路由将被移除；Keychain 密钥也会删除。"),
                      preferredStyle: .alert)
        a.addAction(UIAlertAction(title: V3L("取消"), style: .cancel))
        a.addAction(UIAlertAction(title: V3L("删除"), style: .destructive) { [weak self] _ in
            guard let self, self.connection != nil else { return }
            do {
                try ImpressAIConfigStore.shared.deleteConnection(id: self.connectionID)
                self.navigationController?.popViewController(animated: true)
            } catch { self.showError(error) }
        })
        present(a, animated: true)
    }
    private func showError(_ error: Error) {
        let a = UIAlertController(title: V3L("操作失败"), message: error.localizedDescription,
                                  preferredStyle: .alert)
        a.addAction(UIAlertAction(title: V3L("确定"), style: .default))
        present(a, animated: true)
    }
}

@MainActor
final class ImpressAIModelsViewController: UITableViewController, UISearchResultsUpdating {
    private let modelSearch = UISearchController(searchResultsController: nil)
    private let connectionID: UUID
    init(connectionID: UUID) { self.connectionID = connectionID; super.init(style: .insetGrouped) }
    required init?(coder: NSCoder) { fatalError("init(coder:)") }
    private var connection: ImpressAIConnection? {
        ImpressAIConfigStore.shared.registry.connections.first { $0.id == connectionID }
    }
    private var models: [ImpressAIModel] {
        ImpressAIConfigStore.shared.registry.models.filter { $0.connectionID == connectionID }
    }
    private var visibleModels: [ImpressAIModel] {
        ImpressAIModelSearchFilter.apply(models, query: modelSearch.searchBar.text ?? "")
    }
    func updateSearchResults(for searchController: UISearchController) {
        refreshEmptyState()
        tableView.reloadData()
    }
    override func viewDidLoad() {
        super.viewDidLoad()
        title = V3L("模型列表")
        tableView.backgroundColor = ImpressV3Appearance.page
        modelSearch.searchResultsUpdater = self
        modelSearch.searchBar.placeholder = V3L("搜索模型 ID 或服务商")
        modelSearch.obscuresBackgroundDuringPresentation = false
        navigationItem.searchController = modelSearch
        definesPresentationContext = true
        navigationItem.rightBarButtonItems = [
            ImpressV3Appearance.navigationAction(symbol: "plus",
                label: V3L("添加模型"), target: self, action: #selector(addManual)),
            ImpressV3Appearance.navigationAction(symbol: "arrow.clockwise",
                label: V3L("刷新模型"), target: self, action: #selector(refreshModels))
        ]
    }
    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        refreshEmptyState()
        tableView.reloadData()
    }

    private func refreshEmptyState() {
        let empty = UILabel()
        empty.text = models.isEmpty
            ? V3L("尚无模型。点击右上角 + 手动输入模型 ID，或点击刷新尝试获取目录。")
            : V3L("没有匹配的模型（仅搜索已取得的列表）。")
        empty.textColor = ImpressV3Appearance.secondaryText
        empty.font = ImpressV3Appearance.Typography.body
        empty.textAlignment = .center
        empty.numberOfLines = 0
        tableView.backgroundView = visibleModels.isEmpty ? empty : nil
    }

    override func numberOfSections(in tableView: UITableView) -> Int { 1 }
    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { visibleModels.count }
    override func tableView(_ tableView: UITableView,
                            cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let m = visibleModels[indexPath.row]
        let cell = UITableViewCell(style: .subtitle, reuseIdentifier: nil)
        var ui = UIListContentConfiguration.subtitleCell()
        ui.text = m.identifier
        let wire = (m.protocolOverride ?? connection?.apiProtocol)?.rawValue ?? ""
        let mode = (m.jsonMode ?? .native).rawValue
        ui.secondaryText = wire + " · " + mode + " · " +
            (m.jsonVerified ? V3L("JSON 测试已通过") : V3L("尚未验证 JSON 输出")) +
            (m.supportsImageInput == true ? V3L(" · 图片输入已手动启用") : "")
        ui.image = UIImage(systemName: m.jsonVerified ? "checkmark.shield" : "questionmark.circle")
        ui.imageProperties.tintColor = ImpressV3Appearance.listIconTint
        ui.imageProperties.maximumSize = CGSize(width: 20, height: 20)
        cell.contentConfiguration = ui
        ImpressV3Appearance.styleGroupedCell(cell)
        cell.accessoryType = .disclosureIndicator
        return cell
    }
    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        let model = visibleModels[indexPath.row]
        let qaOnly = connection.map(ImpressAIOpenCodeFreeQA.isQAProfile) ?? false
        let a = UIAlertController(title: model.identifier, message: nil, preferredStyle: .actionSheet)
        a.addAction(UIAlertAction(title: qaOnly ? V3L("测试免费对话") : V3L("测试对话连接"),
                                  style: .default) { [weak self] _ in
            self?.confirmConversationProbe(model)
        })
        if qaOnly {
            a.addAction(UIAlertAction(title: V3L("免费 API 全链路验收"), style: .default) { [weak self] _ in
                self?.confirmFreeWorkflow(model)
            })
        }
        a.addAction(UIAlertAction(title: V3L("测试 JSON 输出"), style: .default) { [weak self] _ in
            self?.confirmJSONProbe(model)
        })
        a.addAction(UIAlertAction(title: V3L("模型协议"), style: .default) { [weak self] _ in
            self?.chooseModelProtocol(model)
        })
        a.addAction(UIAlertAction(title: V3L("JSON 输出模式"), style: .default) { [weak self] _ in
            self?.chooseJSONMode(model)
        })
        a.addAction(UIAlertAction(title: model.supportsImageInput == true
            ? V3L("关闭图片输入") : V3L("确认此模型支持图片输入"),
            style: .default) { [weak self] _ in
                self?.changeImageCapability(model)
            })
        a.addAction(UIAlertAction(title: V3L("作为出题模型"), style: .default) { [weak self] _ in
            self?.setRoute(.questionGeneration, modelID: model.id)
        })
        a.addAction(UIAlertAction(title: V3L("作为对话模型"), style: .default) { [weak self] _ in
            self?.setRoute(.conversation, modelID: model.id)
        })
        a.addAction(UIAlertAction(title: V3L("删除模型"), style: .destructive) { [weak self] _ in
            guard let self else { return }
            do {
                try ImpressAIConfigStore.shared.update { try $0.removeModel(model.id) }
                self.tableView.reloadData()
                self.refreshEmptyState()
            } catch { self.showError(error) }
        })
        a.addAction(UIAlertAction(title: V3L("取消"), style: .cancel))
        a.popoverPresentationController?.sourceView = tableView
        a.popoverPresentationController?.sourceRect = tableView.rectForRow(at: indexPath)
        present(a, animated: true)
    }
    private func changeImageCapability(_ model: ImpressAIModel) {
        guard let c = connection else { return }
        if model.supportsImageInput == true {
            applyModelChange(model.id) { $0.supportsImageInput = nil }
            return
        }
        guard !ImpressAIOpenCodeFreeQA.isQAProfile(c) else {
            showError(ImpressAIServiceError.unsupportedImageInput)
            return
        }
        let alert = UIAlertController(
            title: V3L("为模型启用图片输入？"),
            message: V3L("仅在确认该模型和当前协议支持图片后启用。每次发送仍需批准所选图片。未知文件类型不上传；此设置不能证明模型已理解图像。"),
            preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: V3L("取消"), style: .cancel))
        alert.addAction(UIAlertAction(title: V3L("我已确认模型能力"),
                                      style: .default) { [weak self] _ in
            self?.applyModelChange(model.id) { $0.supportsImageInput = true }
        })
        present(alert, animated: true)
    }

    private func chooseModelProtocol(_ model: ImpressAIModel) {
        guard let c = connection else { return }
        let sheet = UIAlertController(title: V3L("模型协议"), message: nil,
                                      preferredStyle: .actionSheet)
        let defaultAction = UIAlertAction(title: V3L("沿用连接协议"), style: .default) { [weak self] _ in
            self?.applyModelChange(model.id) {
                $0.protocolOverride = nil
                $0.supportsImageInput = nil
                $0.jsonVerified = false
                $0.toolsVerified = false
            }
        }
        sheet.addAction(defaultAction)
        for wire in ImpressAIProtocol.allCases
            where ImpressAIRegistry.supported(wire, for: c.provider) {
            sheet.addAction(UIAlertAction(title: wire.rawValue, style: .default) { [weak self] _ in
                self?.applyModelChange(model.id) {
                    $0.protocolOverride = wire
                    $0.supportsImageInput = nil
                    $0.jsonVerified = false
                    $0.toolsVerified = false
                }
            })
        }
        sheet.addAction(UIAlertAction(title: V3L("取消"), style: .cancel))
        sheet.popoverPresentationController?.sourceView = tableView
        sheet.popoverPresentationController?.sourceRect = tableView.bounds
        present(sheet, animated: true)
    }

    private func chooseJSONMode(_ model: ImpressAIModel) {
        let sheet = UIAlertController(title: V3L("JSON 输出模式"), message: nil,
                                      preferredStyle: .actionSheet)
        for value in ImpressAIJSONMode.allCases {
            sheet.addAction(UIAlertAction(title: value.rawValue, style: .default) { [weak self] _ in
                self?.applyModelChange(model.id) {
                    $0.jsonMode = value
                    $0.jsonVerified = false
                }
            })
        }
        sheet.addAction(UIAlertAction(title: V3L("取消"), style: .cancel))
        sheet.popoverPresentationController?.sourceView = tableView
        sheet.popoverPresentationController?.sourceRect = tableView.bounds
        present(sheet, animated: true)
    }

    private func applyModelChange(_ id: UUID,
                                  edit: (inout ImpressAIModel) -> Void) {
        do {
            try ImpressAIConfigStore.shared.update { registry in
                guard let index = registry.models.firstIndex(where: { $0.id == id }) else {
                    throw ImpressAIServiceError.configuration
                }
                edit(&registry.models[index])
            }
            tableView.reloadData()
        } catch { showError(error) }
    }

    @objc private func addManual() {
        let a = UIAlertController(title: V3L("添加模型 ID"), message: nil, preferredStyle: .alert)
        a.addTextField { $0.autocapitalizationType = .none; $0.autocorrectionType = .no }
        a.addAction(UIAlertAction(title: V3L("取消"), style: .cancel))
        a.addAction(UIAlertAction(title: V3L("添加"), style: .default) { [weak self] _ in
            self?.addModelID(a.textFields?.first?.text ?? "")
        })
        present(a, animated: true)
    }
    private func addModelID(_ id: String) {
        if let c = connection, ImpressAIOpenCodeFreeQA.isQAProfile(c),
           !ImpressAIOpenCodeFreeQA.allowedForCatalog(id) {
            showError(ImpressAIServiceError.freeModelOnly)
            return
        }
        do {
            let model = ImpressAIModel(connectionID: connectionID,
                    identifier: id.trimmingCharacters(in: .whitespacesAndNewlines))
            try ImpressAIConfigStore.shared.update { $0.models.append(model) }
            tableView.reloadData()
            refreshEmptyState()
        } catch { showError(error) }
    }
    @objc private func refreshModels() {
        guard let c = connection else { return }
        navigationItem.rightBarButtonItems?.forEach { $0.isEnabled = false }
        Task {
            do {
                let names = try await ImpressAIHTTPClient.shared.listModels(connection: c)
                try ImpressAIConfigStore.shared.update { registry in
                    guard registry.connections.contains(where: { $0.id == self.connectionID }) else {
                        throw ImpressAIServiceError.configuration
                    }
                    let existing = Set(registry.models.filter { $0.connectionID == self.connectionID }
                        .map { $0.identifier.lowercased() })
                    for id in names where !existing.contains(id.lowercased()) {
                        registry.models.append(ImpressAIModel(connectionID: self.connectionID, identifier: id))
                    }
                }
                tableView.reloadData()
                refreshEmptyState()
            } catch { showError(error) }
            navigationItem.rightBarButtonItems?.forEach { $0.isEnabled = true }
        }
    }
    /// All requests use the actual configured Keychain credential, if any,
    /// and the exact same inference service as production Chat and AI question
    /// generation. The test input is synthetic: no user card or Vault bytes.
    private func confirmFreeWorkflow(_ model: ImpressAIModel) {
        guard let connection else { return }
        let selected = ImpressAIResolvedRoute(connection: connection, model: model)
        do { try ImpressAIOpenCodeFreeQA.validate(selected) }
        catch { showError(error); return }
        let alert = UIAlertController(title: V3L("免费 API 全链路验收"),
            message: V3L("将向当前 OpenCode 免费模型发送四个不含私人信息的测试请求：首次 Chat、连续追问、JSON 与综合出题。不会上传真实笔记或保存卡片，也不会调用付费模型。"),
            preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: V3L("取消"), style: .cancel))
        alert.addAction(UIAlertAction(title: V3L("开始测试"), style: .default) { [weak self] _ in
            self?.runFreeWorkflow(model: model, connection: connection)
        })
        present(alert, animated: true)
    }

    private func runFreeWorkflow(model: ImpressAIModel, connection: ImpressAIConnection) {
        let route = ImpressAIResolvedRoute(connection: connection, model: model)
        let identity = connection.title + "\n" + model.identifier +
            "\nChat Completions · " +
            (connection.effectiveAuthentication == .bearer ? "Bearer / Keychain" : "Anonymous")
        tableView.isUserInteractionEnabled = false
        navigationItem.prompt = V3L("正在验证免费 API…")
        Task {
            var lines: [String] = [identity]
            do {
                try ImpressAIOpenCodeFreeQA.validate(route)
                if connection.effectiveAuthentication == .bearer {
                    // Read-check only. Never log, display or cache the secret.
                    _ = try ImpressAIKeychain.read(id: connection.credentialID)
                    lines.append("Keychain: " + V3L("凭据可读取"))
                    let keyStatus = try await ImpressAIHTTPClient.shared
                        .probeOpenCodeServiceAccount(connection: connection)
                    lines.append("Console Key: HTTP \(keyStatus) · PASS")
                }
                let firstTurn = ImpressAIChatTurn(role: .user, text: "Reply only with OK.")
                let first = try await ImpressAIHTTPClient.shared.converseDetailed(
                    route: route, system: "Brief neutral test, no user data.",
                    turns: [firstTurn])
                lines.append("Chat 1: HTTP \(first.statusCode) · PASS")
                let followup = try await ImpressAIHTTPClient.shared.converseDetailed(
                    route: route, system: "Brief neutral test, no user data.",
                    turns: [
                        firstTurn,
                        ImpressAIChatTurn(role: .assistant, text: first.text),
                        ImpressAIChatTurn(role: .user, text: "Second turn: reply only with TWO.")
                    ])
                lines.append("Chat 2: HTTP \(followup.statusCode) · PASS")
                let jsonProbe = try await ImpressAIHTTPClient.shared.completeDetailed(
                    route: route,
                    system: "Return a single JSON object with boolean ok true and nothing else.",
                    user: "Respond with exactly the JSON object {\"ok\":true}.")
                guard let parsed = try? JSONSerialization.jsonObject(
                    with: Data(jsonProbe.text.utf8)) as? [String: Any],
                    parsed.count == 1, parsed["ok"] as? Bool == true else {
                    throw ImpressAIServiceError.response
                }
                lines.append("JSON: HTTP \(jsonProbe.statusCode) · PASS")
                let source = ImpressAISource(
                    vaultID: "qa-synthetic-only",
                    relativePath: "Impress_QA_Synthetic.md",
                    documentSHA256: String(repeating: "a", count: 64),
                    heading: "Synthetic test")
                let excerpt = ImpressAIExcerpt(id: "qa-evidence-1",
                    source: source,
                    text: "Active recall means trying to retrieve information without " +
                          "looking at the answer. Rereading exposes the answer before retrieval.",
                    sectionHeading: "Retrieval practice")
                let generated = try await ImpressAIHTTPClient.shared.completeDetailed(
                    route: route, system: ImpressAIQuestionPrompt.system(count: 1),
                    user: try ImpressAIQuestionPrompt.input([excerpt]))
                let questions = try ImpressAIQuestionPrompt.decode(generated.text)
                let pool = ImpressAIQuestionPool(source: source, excerpts: [excerpt],
                    requestedCount: 1, modelProfileID: model.id,
                    candidates: questions.map {
                        ImpressAIQuestionCandidate(question: $0.question,
                            answer: $0.answer, dimension: $0.dimension,
                            evidenceIDs: $0.evidenceIDs)
                    })
                let valid = try ImpressAIQuestionValidator.validatedSelection(pool)
                guard valid.count == 1 else { throw ImpressAIServiceError.response }
                lines.append("AI Question: HTTP \(generated.statusCode) · PASS")
                // Write only capability/route metadata after all *real* API
                // requests and local validators pass. No synthetic card is saved.
                try ImpressAIConfigStore.shared.update { reg in
                    guard reg.connections.contains(connection),
                          let index = reg.models.firstIndex(where: { $0.id == model.id }),
                          reg.models[index].identifier == model.identifier,
                          reg.models[index].connectionID == connection.id,
                          reg.models[index].jsonMode == model.jsonMode,
                          reg.models[index].protocolOverride == model.protocolOverride else {
                        throw ImpressAIServiceError.configuration
                    }
                    reg.models[index].jsonVerified = true
                    for task in [ImpressAITask.conversation, .questionGeneration] {
                        reg.routes.removeAll { $0.task == task }
                        reg.routes.append(ImpressAIRoute(task: task, primaryModelID: model.id))
                    }
                }
                lines.append(V3L("对话与出题模型已启用；未修改真实 Vault 或卡片库。"))
                showFreeWorkflowReport(title: V3L("免费 API 验收通过"),
                                       message: lines.joined(separator: "\n"))
            } catch {
                lines.append("FAILED: " + error.localizedDescription)
                showFreeWorkflowReport(title: V3L("免费 API 验收未通过"),
                                       message: lines.joined(separator: "\n"))
            }
            tableView.isUserInteractionEnabled = true
            navigationItem.prompt = nil
            tableView.reloadData()
        }
    }

    private func showFreeWorkflowReport(title: String, message: String) {
        let report = UIAlertController(title: title, message: message, preferredStyle: .alert)
        report.addAction(UIAlertAction(title: V3L("确定"), style: .default))
        present(report, animated: true)
    }

    private func confirmConversationProbe(_ model: ImpressAIModel) {
        guard let c = connection else { return }
        let isQA = ImpressAIOpenCodeFreeQA.isQAProfile(c)
        let alert = UIAlertController(title: V3L("测试对话连接"),
            message: c.title + " · " + model.identifier + "\n" +
                (isQA
                 ? V3L("仅发送无私人数据的测试文本，限 OpenCode Free QA 模型。")
                 : V3L("本次将向选定厂商发送一条测试消息，可能产生该厂商的 API 费用。")),
            preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: V3L("取消"), style: .cancel))
        alert.addAction(UIAlertAction(title: V3L("开始测试"), style: .default) { [weak self] _ in
            self?.testFreeConversation(model)
        })
        present(alert, animated: true)
    }

    private func confirmJSONProbe(_ model: ImpressAIModel) {
        guard let c = connection else { return }
        let alert = UIAlertController(title: V3L("测试 JSON 输出"),
            message: c.title + " · " + model.identifier + "\n" +
                V3L("发送一条无私人内容的 JSON 测试请求，可能产生该服务商的调用费用。成功后才能用于私人笔记出题。"),
            preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: V3L("取消"), style: .cancel))
        alert.addAction(UIAlertAction(title: V3L("开始测试"), style: .default) { [weak self] _ in
            self?.testModel(model)
        })
        present(alert, animated: true)
    }

    private func testFreeConversation(_ model: ImpressAIModel) {
        guard let connection else { return }
        let selected = ImpressAIResolvedRoute(connection: connection, model: model)
        Task {
            do {
                // Zero Vault bytes; the only content is this harmless probe.
                let result = try await ImpressAIHTTPClient.shared.converseDetailed(
                    route: selected, system: "Respond with only OK.",
                    turns: [ImpressAIChatTurn(role: .user, text: "ping")])
                guard !result.text.isEmpty else { throw ImpressAIServiceError.response }
                let report = connection.title + "\n" + model.identifier +
                    "\n" + selected.effectiveProtocol.rawValue +
                    " · HTTP " + String(result.statusCode) + "\n" +
                    V3L("测试成功：已收到模型回复，没有发送私人笔记。")
                let alert = UIAlertController(title: V3L("对话模型连接成功"),
                    message: report,
                    preferredStyle: .alert)
                alert.addAction(UIAlertAction(title: V3L("确定"), style: .default))
                present(alert, animated: true)
            } catch {
                let details = connection.title + "\n" + model.identifier +
                    "\n" + selected.effectiveProtocol.rawValue +
                    "\n" + error.localizedDescription
                let alert = UIAlertController(title: V3L("对话模型连接失败"),
                    message: details, preferredStyle: .alert)
                alert.addAction(UIAlertAction(title: V3L("确定"), style: .default))
                present(alert, animated: true)
            }
        }
    }

    private func testModel(_ model: ImpressAIModel) {
        guard let c = connection else { return }
        Task {
            do {
                guard try await ImpressAIHTTPClient.shared.probeJSON(connection: c, model: model) else {
                    throw ImpressAIServiceError.response
                }
                try ImpressAIConfigStore.shared.update { reg in
                    guard let i = reg.models.firstIndex(where: { $0.id == model.id }) else { return }
                    reg.models[i].jsonVerified = true
                }
                tableView.reloadData()
            } catch { showError(error) }
        }
    }
    private func setRoute(_ task: ImpressAITask, modelID: UUID) {
        do {
            try ImpressAIConfigStore.shared.update {
                try $0.setDefaultModel(modelID, for: task)
            }
            let a = UIAlertController(title: V3L("已选择默认模型"), message: nil, preferredStyle: .alert)
            a.addAction(UIAlertAction(title: V3L("确定"), style: .default))
            present(a, animated: true)
        } catch { showError(error) }
    }
    private func showError(_ error: Error) {
        let a = UIAlertController(title: V3L("操作失败"), message: error.localizedDescription,
                                  preferredStyle: .alert)
        a.addAction(UIAlertAction(title: V3L("确定"), style: .default))
        present(a, animated: true)
    }
}

@MainActor
final class ImpressAIModelChooser: UITableViewController, UISearchResultsUpdating {
    private let modelSearch = UISearchController(searchResultsController: nil)
    private let task: ImpressAITask
    private let onPick: ((UUID?) -> Void)?
    private let selectedOverrideID: UUID?
    init(task: ImpressAITask, selectedOverrideID: UUID? = nil,
         onPick: ((UUID?) -> Void)? = nil) {
        self.task = task
        self.selectedOverrideID = selectedOverrideID
        self.onPick = onPick
        super.init(style: .insetGrouped)
    }
    private var hasDefaultRow: Bool {
        onPick != nil && (modelSearch.searchBar.text ?? "").isEmpty
    }
    required init?(coder: NSCoder) { fatalError("init(coder:)") }
    private var models: [ImpressAIModel] {
        ImpressAIModelSearchFilter.apply(
            ImpressAIConfigStore.shared.registry.selectableModels(for: task),
            query: modelSearch.searchBar.text ?? "")
    }
    func updateSearchResults(for searchController: UISearchController) {
        tableView.reloadData()
    }
    override func viewDidLoad() {
        super.viewDidLoad()
        title = V3L("选择业务模型")
        tableView.backgroundColor = ImpressV3Appearance.page
        modelSearch.searchResultsUpdater = self
        modelSearch.searchBar.placeholder = V3L("搜索模型 ID 或服务商")
        modelSearch.obscuresBackgroundDuringPresentation = false
        navigationItem.searchController = modelSearch
        definesPresentationContext = true
    }
    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        tableView.reloadData()
    }
    override func numberOfSections(in tableView: UITableView) -> Int { 1 }
    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        max(1, models.count + (hasDefaultRow ? 1 : 0))
    }
    override func tableView(_ tableView: UITableView,
                            cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        if hasDefaultRow && indexPath.row == 0 {
            let cell = UITableViewCell(style: .default, reuseIdentifier: nil)
            var ui = UIListContentConfiguration.cell()
            ui.text = V3L("使用业务默认模型")
            ui.image = UIImage(systemName: "arrow.uturn.backward")
            ui.imageProperties.tintColor = ImpressV3Appearance.listIconTint
        ui.imageProperties.maximumSize = CGSize(width: 20, height: 20)
        cell.contentConfiguration = ui
            cell.accessoryType = selectedOverrideID == nil ? .checkmark : .none
            ImpressV3Appearance.styleGroupedCell(cell)
            return cell
        }
        if models.isEmpty {
            let cell = UITableViewCell(style: .subtitle, reuseIdentifier: nil)
            var empty = UIListContentConfiguration.subtitleCell()
            empty.text = !(modelSearch.searchBar.text ?? "").isEmpty
                ? V3L("没有匹配的业务模型")
                : (task == .knowledgeSynthesis
                    ? V3L("知识重构功能尚未启用")
                    : V3L("暂无可选择的业务模型"))
            empty.secondaryText = task == .knowledgeSynthesis
                ? V3L("该业务需独立完成安全验收")
                : V3L("返回 AI 服务，先添加连接和模型，然后重新选择。")
            cell.contentConfiguration = empty
            cell.accessoryType = .none
            ImpressV3Appearance.styleGroupedCell(cell)
            return cell
        }
        let m = models[indexPath.row - (hasDefaultRow ? 1 : 0)]
        let registry = ImpressAIConfigStore.shared.registry
        let c = registry.connections.first { $0.id == m.connectionID }
        let cell = UITableViewCell(style: .subtitle, reuseIdentifier: nil)
        var ui = UIListContentConfiguration.subtitleCell()
        ui.text = m.identifier
        let state = task == .conversation
            ? V3L("对话可选，建议先测试连接")
            : (m.jsonVerified ? V3L("JSON 已验证") : V3L("JSON 尚未验证，不能上传笔记"))
        ui.secondaryText = (c?.title ?? "") + " · " + state
        ui.imageProperties.tintColor = ImpressV3Appearance.listIconTint
        ui.imageProperties.maximumSize = CGSize(width: 20, height: 20)
        cell.contentConfiguration = ui
        cell.accessoryType = (onPick != nil
            ? selectedOverrideID == m.id
            : registry.routes.first { $0.task == task }?.primaryModelID == m.id)
            ? .checkmark : .none
        ImpressV3Appearance.styleGroupedCell(cell)
        return cell
    }
    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        if hasDefaultRow && indexPath.row == 0 {
            onPick?(nil)
            navigationController?.popViewController(animated: true)
            return
        }
        guard !models.isEmpty else { return }
        let m = models[indexPath.row - (hasDefaultRow ? 1 : 0)]
        if let onPick {
            onPick(m.id)
            navigationController?.popViewController(animated: true)
            return
        }
        if task == .knowledgeSynthesis && !m.toolsVerified {
            let alert = UIAlertController(title: V3L("该功能尚未开放"),
                   message: V3L("知识重构需要单独的工具调用及 Vault 写回安全验收。"),
                   preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: V3L("确定"), style: .default))
            present(alert, animated: true)
            return
        }
        do {
            try ImpressAIConfigStore.shared.update {
                try $0.setDefaultModel(m.id, for: self.task)
            }
            navigationController?.popViewController(animated: true)
        } catch {
            let alert = UIAlertController(title: V3L("选择失败"),
                       message: error.localizedDescription, preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: V3L("确定"), style: .default))
            present(alert, animated: true)
        }
    }
}
