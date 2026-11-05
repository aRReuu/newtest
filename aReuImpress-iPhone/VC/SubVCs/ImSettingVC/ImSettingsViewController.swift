import UIKit

// The old settings controller is retained for historical navigation only.
// Obsolete mock data, wallpaper, pilot and interval UI/actions are removed.
// Persisted user values and unrelated services are not modified or migrated.
enum SettingsSection { case systemPrompt }

struct SettingsConfiguration {
    let displaySections: [SettingsSection] = [.systemPrompt]
    static let `default` = SettingsConfiguration()
}

@MainActor
final class ImSettingsViewController: UITableViewController {
    init() { super.init(style: .insetGrouped) }
    required init?(coder: NSCoder) { fatalError("init(coder:) unsupported") }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "设置"
        navigationItem.largeTitleDisplayMode = .never
        tableView.backgroundColor = ImpressV3Appearance.page
    }

    override func tableView(_ tableView: UITableView,
                            numberOfRowsInSection section: Int) -> Int { 1 }

    override func tableView(_ tableView: UITableView,
                            titleForHeaderInSection section: Int) -> String? {
        "内容工具"
    }

    override func tableView(_ tableView: UITableView,
                            cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = UITableViewCell(style: .subtitle, reuseIdentifier: nil)
        var display = UIListContentConfiguration.subtitleCell()
        display.text = "提示词"
        display.secondaryText = "管理费曼总结、生成选择题和问答等本地模板"
        display.secondaryTextProperties.numberOfLines = 2
        display.image = UIImage(systemName: "text.book.closed")
        cell.contentConfiguration = display
        cell.accessoryType = .disclosureIndicator
        return cell
    }

    override func tableView(_ tableView: UITableView,
                            didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        navigationController?.pushViewController(
            ImpressV3PromptLibraryViewController(), animated: true)
    }
}
