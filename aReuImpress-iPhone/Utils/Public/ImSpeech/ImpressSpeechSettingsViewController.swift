import UIKit
import AVFoundation

/// App-scoped speech settings; independent of the interface language.
/// This controller never opens the microphone until an explicit user action.
@MainActor
final class ImpressSpeechSettingsViewController: UITableViewController {
    private let service = ImpressSpeechService.shared
    private var choice = ImpressSpeechLocale.selected()
    private var status: ImpressSpeechService.Availability?
    private var checking = false
    private var installing = false

    init() { super.init(style: .insetGrouped) }
    required init?(coder: NSCoder) { fatalError("init(coder:) unsupported") }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = V3L("语音输入")
        navigationItem.largeTitleDisplayMode = .never
        ImpressV3Appearance.styleGroupedTable(tableView)
        tableView.accessibilityIdentifier = "impress.settings.speech"
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        title = V3L("语音输入")
        refreshAvailability()
    }

    private func refreshAvailability() {
        checking = true
        tableView.reloadData()
        let selected = choice
        Task { [weak self] in
            guard let self else { return }
            let result = await service.availability(for: selected)
            guard selected == self.choice else { return }
            self.status = result
            self.checking = false
            self.tableView.reloadData()
        }
    }

    override func numberOfSections(in tableView: UITableView) -> Int { 3 }

    override func tableView(_ tableView: UITableView,
                            numberOfRowsInSection section: Int) -> Int {
        switch section {
        case 0: return ImpressSpeechLocale.allCases.count
        case 1: return 2
        default: return 2
        }
    }

    override func tableView(_ tableView: UITableView,
                            titleForHeaderInSection section: Int) -> String? {
        switch section {
        case 0: return V3L("识别语言")
        case 1: return V3L("Apple 端侧模型")
        default: return V3L("权限与隐私")
        }
    }

    override func tableView(_ tableView: UITableView,
                            titleForFooterInSection section: Int) -> String? {
        switch section {
        case 0: return V3L("听写语言与 App 的显示语言互不影响。")
        case 1: return V3L("Apple 按设备和语言提供模型；首次下载需联网，识别过程不上传音频。")
        default: return V3L("仅在点击麦克风后录音，不保存音频；取消时不修改编辑器文本。")
        }
    }

    override func tableView(_ tableView: UITableView,
                            cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "speech.settings")
            ?? UITableViewCell(style: .subtitle, reuseIdentifier: "speech.settings")
        var content = UIListContentConfiguration.subtitleCell()
        content.textProperties.font = ImpressV3Appearance.Typography.body
        content.secondaryTextProperties.font = ImpressV3Appearance.Typography.supporting
        content.secondaryTextProperties.color = ImpressV3Appearance.secondaryText
        content.secondaryTextProperties.numberOfLines = 2
        cell.accessoryType = .none
        cell.selectionStyle = .default
        if indexPath.section == 0 {
            let item = ImpressSpeechLocale.allCases[indexPath.row]
            content.text = item.name
            content.secondaryText = item.rawValue
            cell.accessoryType = item == choice ? .checkmark : .none
            cell.accessibilityIdentifier = "impress.speech.locale." + item.rawValue
        } else if indexPath.section == 1 {
            if indexPath.row == 0 {
                content.text = V3L("识别引擎")
                content.secondaryText = checking ? V3L("检查中…") :
                    (status?.engine?.rawValue ?? V3L("当前设备不支持"))
                cell.selectionStyle = .none
            } else {
                content.text = V3L("识别模型")
                content.secondaryText = installing ? V3L("正在下载模型…") :
                    (status?.installed == true ? V3L("已安装，可离线识别") :
                     status?.engine == nil ? V3L("不可用") : V3L("未安装 · 点击下载"))
                cell.accessibilityIdentifier = "impress.speech.download-model"
                cell.accessoryType = status?.installed == true ? .checkmark : .disclosureIndicator
            }
        } else if indexPath.row == 0 {
            content.text = V3L("麦克风权限")
            switch AVAudioApplication.shared.recordPermission {
            case .granted: content.secondaryText = V3L("已授权")
            case .denied: content.secondaryText = V3L("未授权 · 点击打开系统设置")
            default: content.secondaryText = V3L("首次开始录音时请求授权")
            }
            cell.accessibilityIdentifier = "impress.speech.microphone-permission"
        } else {
            content.text = V3L("音频隐私")
            content.secondaryText = V3L("录音只在设备端识别，取消后不会保存音频或文字。")
            cell.selectionStyle = .none
        }
        cell.contentConfiguration = content
        ImpressV3Appearance.styleGroupedCell(cell)
        return cell
    }

    override func tableView(_ tableView: UITableView,
                            didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        if indexPath.section == 0 {
            choice = ImpressSpeechLocale.allCases[indexPath.row]
            UserDefaults.standard.set(choice.rawValue, forKey: ImpressSpeechLocale.storageKey)
            status = nil
            refreshAvailability()
        } else if indexPath.section == 1 && indexPath.row == 1 {
            guard !checking, !installing, status?.engine != nil,
                  status?.installed == false else { return }
            let alert = UIAlertController(title: V3L("下载 Apple 识别模型？"),
                message: V3L("仅首次需要联网下载；录音和转文字在设备端处理。"),
                preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: V3L("取消"), style: .cancel))
            alert.addAction(UIAlertAction(title: V3L("下载"), style: .default) {
                [weak self] _ in self?.downloadSelectedModel()
            })
            present(alert, animated: true)
        } else if indexPath.section == 2 && indexPath.row == 0 {
            guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
            UIApplication.shared.open(url)
        }
    }

    private func downloadSelectedModel() {
        guard !installing else { return }
        installing = true
        tableView.reloadData()
        let selected = choice
        Task { [weak self] in
            guard let self else { return }
            do {
                try await service.downloadModel(for: selected)
                self.installing = false
                self.refreshAvailability()
            } catch {
                self.installing = false
                self.refreshAvailability()
                let alert = UIAlertController(title: V3L("模型下载失败"),
                    message: error.localizedDescription, preferredStyle: .alert)
                alert.addAction(UIAlertAction(title: V3L("确定"), style: .default))
                self.present(alert, animated: true)
            }
        }
    }
}
