import UIKit
import UniformTypeIdentifiers

/// One native Settings destination. Manual export and restore always require
/// direct user actions; periodic local snapshots are deliberately silent.
/// Manual Files export uses the same system folder authorization as the
/// established cloud-folder picker. Only a completed, verified ZIP may be
/// copied; no destination is inferred, auto-selected, or overwritten.
enum ImpressV3ManualFileExport {
    static func save(_ verifiedZIP: URL, intoSelectedFolder folder: URL) throws -> URL {
        let fm = FileManager.default
        let scoped = folder.startAccessingSecurityScopedResource()
        let ownDocuments = fm.urls(for: .documentDirectory, in: .userDomainMask)[0]
        guard scoped || folder.standardizedFileURL == ownDocuments.standardizedFileURL else {
            throw ImpressV3BackupFailure.notAuthorized
        }
        defer { if scoped { folder.stopAccessingSecurityScopedResource() } }
        return try copyAndVerify(verifiedZIP, into: folder)
    }

    #if DEBUG
    /// The test-only entry never grants external Files access. It proves
    /// byte-for-byte and no-overwrite behavior in a disposable local folder.
    static func testCopyAndVerify(_ zip: URL, into folder: URL) throws -> URL {
        try copyAndVerify(zip, into: folder)
    }
    #endif

    private static func copyAndVerify(_ zip: URL, into folder: URL) throws -> URL {
        guard zip.pathExtension.lowercased() == "zip" else {
            throw ImpressV3BackupFailure.invalidArchive
        }
        let fm = FileManager.default
        let original = try ImpressV3BackupArchive.inspectFile(
            zip, name: zip.lastPathComponent).0
        let target = folder.appendingPathComponent(zip.lastPathComponent)
        // Never overwrite an existing user file, even when names collide.
        guard !fm.fileExists(atPath: target.path) else {
            throw CocoaError(.fileWriteFileExists)
        }
        let coordinator = NSFileCoordinator(filePresenter: nil)
        var coordinatorError: NSError?
        var operationError: Error?
        var createdByThisExport = false
        coordinator.coordinate(writingItemAt: target, options: [],
                               error: &coordinatorError) { destination in
            do {
                guard !fm.fileExists(atPath: destination.path) else {
                    throw CocoaError(.fileWriteFileExists)
                }
                try fm.copyItem(at: zip, to: destination)
                createdByThisExport = true
                let written = try ImpressV3BackupArchive.inspectFile(
                    destination, name: zip.lastPathComponent).0
                guard original.sha256 == written.sha256,
                      original.size == written.size else {
                    throw ImpressV3BackupFailure.invalidChecksum
                }
            } catch {
                if createdByThisExport {
                    try? fm.removeItem(at: destination)
                }
                operationError = error
            }
        }
        if let coordinatorError { throw coordinatorError }
        if let operationError { throw operationError }
        return target
    }
}

@MainActor
final class ImpressV3BackupSettingsViewController: UITableViewController,
                                                    UIDocumentPickerDelegate {
    private enum PickerPurpose {
        case cloudFolder, restoreArchive, exportArchive, restoreLegacyDatabase
    }
    private var pendingPurpose: PickerPurpose?
    private var pendingExportArchive: URL?
    private var working = false
    #if DEBUG
    // QA-only accessibility phase: remote Files UI can run outside the app's
    // AX tree; expose *state*, never archive bytes or private file paths.
    private var syntheticExportPhase = "IDLE"
    private var syntheticExportFixtureEnabled: Bool {
        ImpressV11UITestFixture.enabled &&
            ProcessInfo.processInfo.arguments.contains("-ImpressV11RestorePickerE2E")
    }
    #endif

    init() { super.init(style: .insetGrouped) }
    required init?(coder: NSCoder) { fatalError("init(coder:) unsupported") }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = V3L("数据与备份")
        navigationItem.largeTitleDisplayMode = .never
        tableView.backgroundColor = ImpressV3Appearance.page
        tableView.rowHeight = UITableView.automaticDimension
        tableView.estimatedRowHeight = 70
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        title = V3L("数据与备份")
        tableView.reloadData()
    }

    override func numberOfSections(in tableView: UITableView) -> Int { 3 }
    override func tableView(_ tableView: UITableView,
                            numberOfRowsInSection section: Int) -> Int {
        if section == 1 && ImpressV3BackupCoordinator.cloudFolderSelected { return 2 }
        return section == 2 ? 2 : 1
    }

    override func tableView(_ tableView: UITableView,
                            titleForHeaderInSection section: Int) -> String? {
        V3L(["本地自动备份", "iCloud Drive 副本", "恢复"][section])
    }

    override func tableView(_ tableView: UITableView,
                            titleForFooterInSection section: Int) -> String? {
        switch section {
        case 0:
            let timestamp = UserDefaults.standard.object(
                forKey: ImpressV3BackupCoordinator.localDateKey) as? Date
            let last = timestamp.map { Self.dateFormatter.string(from: $0) } ?? V3L("尚无成功备份")
            let recoveryError = UserDefaults.standard.string(
                forKey: "ImpressLegacyRecoveryError")
            return String(format: V3L("V3 数据变化后自动生成一致性快照。最近成功：%@。"), last) +
                V3L("旧版卡片和旧版笔记恢复后已包含在 V3 ZIP；原始旧数据库保持只读，不纳入备份。") +
                V3L("不包含外部 Obsidian 原件、API Key 或 Vault 授权。") +
                V3L("当前 ZIP 未加密，获取文件者可读取其中学习数据。") +
                (recoveryError.map { "\n" + $0 } ?? "")
        case 1:
            let last = UserDefaults.standard.object(
                forKey: ImpressV3BackupCoordinator.cloudDateKey) as? Date
            let copied = last.map { Self.dateFormatter.string(from: $0) } ?? V3L("尚未写入")
            return String(format: V3L("首次手动授权文件夹，此后尝试静默复制。最近写入文件提供者：%@。"), copied) +
                V3L("同一授权文件夹固定替换 ImpressV3-latest.zip，不再生成新的历史命名云端副本。") +
                V3L("副本为未加密 ZIP，请只授权个人可信目录。系统 iCloud 上传可能延迟；") +
                V3L("此状态不代表云端服务器已完成同步。")
        default:
            return V3L("恢复前验证归档，并创建当前数据的回滚备份。") +
                V3L("确认后仅暂存，新数据在下次完全退出并重新启动 App 时载入。")
        }
    }

    private static let dateFormatter: DateFormatter = {
        let value = DateFormatter()
        value.dateStyle = .medium
        value.timeStyle = .short
        return value
    }()

    override func tableView(_ tableView: UITableView,
                            cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = UITableViewCell(style: .subtitle, reuseIdentifier: nil)
        var config = UIListContentConfiguration.subtitleCell()
        let symbol: String
        switch (indexPath.section, indexPath.row) {
        case (0, _):
            config.text = V3L("立即备份并导出")
            config.secondaryText = V3L("同时生成本地备份；可保存到文件 App")
            symbol = "square.and.arrow.up"
        case (1, 0):
            config.text = ImpressV3BackupCoordinator.cloudFolderSelected
                ? V3L("重新选择备份文件夹") : V3L("连接 iCloud Drive 文件夹")
            config.secondaryText = V3L("仅在手动授权后自动写入副本")
            symbol = "cloud"
        case (1, 1):
            config.text = V3L("断开自动云盘备份")
            config.secondaryText = V3L("只清除本 App 的授权，不删除云盘文件")
            symbol = "xmark.icloud"
        case (2, 0):
            config.text = V3L("从备份恢复")
            config.secondaryText = V3L("先验证 ZIP，再确认；不会直接覆盖当前数据库")
            symbol = "arrow.uturn.backward"
        default:
            config.text = V3L("导入旧版数据库")
            config.secondaryText = V3L("从文件 App 选择旧的 impressdata.db，只读迁入卡片与笔记")
            symbol = "externaldrive.badge.plus"
        }
        config.image = UIImage(systemName: symbol)
        config.imageProperties.tintColor = ImpressV3Appearance.secondaryText
        config.secondaryTextProperties.numberOfLines = 2
        cell.contentConfiguration = config
        cell.accessoryType = .disclosureIndicator
        if indexPath.section == 0 {
            cell.accessibilityIdentifier = "impress.backup.export"
            #if DEBUG
            if syntheticExportFixtureEnabled {
                cell.accessibilityValue = syntheticExportPhase
            }
            #endif
        } else if indexPath.section == 2 {
            cell.accessibilityIdentifier = indexPath.row == 0
                ? "impress.backup.restore" : "impress.backup.restore-legacy"
        }
        cell.isUserInteractionEnabled = !working
        ImpressV3Appearance.styleGroupedCell(cell)
        return cell
    }

    override func tableView(_ tableView: UITableView,
                            didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        guard !working else { return }
        switch (indexPath.section, indexPath.row) {
        case (0, _): exportNow()
        case (1, 0): chooseCloudFolder()
        case (1, 1):
            ImpressV3BackupCoordinator.disconnectCloudFolder()
            tableView.reloadData()
        case (2, 0): chooseRestoreArchive()
        case (2, 1): chooseLegacyDatabase()
        default: return
        }
    }

    private func exportNow() {
        working = true
        #if DEBUG
        if syntheticExportFixtureEnabled { syntheticExportPhase = "PREPARING" }
        #endif
        tableView.reloadData()
        Task { [weak self] in
            guard let self else { return }
            do {
                let local = try await ImpressV3BackupCoordinator.shared.createBackup(force: true)
                // Independently expose a recovery-only fixture ZIP so even a
                // broken remote export UI can be diagnosed without pretending
                // that an actual Files export succeeded. The user-export ZIP
                // gets a DIFFERENT UUID-scoped filename and is only created in
                // the selected Files folder after real user consent.
                #if DEBUG
                _ = try exposeSyntheticRestoreArchiveToSystemFiles(local)
                let forExport = try prepareSyntheticUserExportArchive(local) ?? local
                if syntheticExportFixtureEnabled { syntheticExportPhase = "VERIFIED" }
                #else
                let forExport = local
                #endif
                pendingExportArchive = forExport
                working = true
                tableView.reloadData()
                #if DEBUG
                if ImpressV11UITestFixture.enabled &&
                   ProcessInfo.processInfo.arguments.contains("-ImpressV11RestorePickerE2E") {
                    // Only a validated, disposable UUID fixture is logged;
                    // never log ZIP contents, private paths or live Vault data.
                    NSLog("Impress F12 synthetic export ZIP verified; presenting real Files dialog")
                }
                #endif
                // The forExporting: remote destination sheet repeatedly
                // attached a UIKit window without rendering accessible Files
                // controls on hosted iOS 27. Use the SAME genuine Files folder
                // picker already used for explicit cloud-folder authorization.
                // A selected folder grants one-time manual export, verified
                // with SHA-256. No silent copy or background destination guess.
                let picker = UIDocumentPickerViewController(
                    forOpeningContentTypes: [UTType.folder], asCopy: false)
                picker.allowsMultipleSelection = false
                picker.delegate = self
                pendingPurpose = .exportArchive
                #if DEBUG
                if syntheticExportFixtureEnabled { syntheticExportPhase = "PRESENTING" }
                #endif
                present(picker, animated: true) { [weak self] in
                    guard let self else { return }
                    #if DEBUG
                    if self.syntheticExportFixtureEnabled {
                        // A window attachment is not proof of a remotely
                        // interactive picker or completed user-authorized copy.
                        if self.presentedViewController !== picker {
                            self.syntheticExportPhase = "PRESENTATION_MISSING"
                        } else if picker.viewIfLoaded?.window == nil {
                            self.syntheticExportPhase = "PICKER_WINDOW_MISSING"
                        } else {
                            self.syntheticExportPhase = "PICKER_WINDOW_ATTACHED"
                        }
                        self.tableView.reloadData()
                    }
                    #endif
                }
            } catch {
                pendingExportArchive = nil
                pendingPurpose = nil
                working = false
                #if DEBUG
                if syntheticExportFixtureEnabled { syntheticExportPhase = "FAILED" }
                #endif
                tableView.reloadData()
                #if DEBUG
                if ImpressV11UITestFixture.enabled &&
                   ProcessInfo.processInfo.arguments.contains("-ImpressV11RestorePickerE2E") {
                    NSLog("Impress F12 synthetic Settings export failed: %@",
                          String(describing: error))
                }
                #endif
                report(error)
            }
        }
    }

    #if DEBUG
    /// An explicit synthetic XCUITest can select its own verified ZIP through
    /// the genuine system Files picker. Only disposable WCDB/fixture bytes are
    /// exported here, into this app's document-sharing root (never real Vault).
    /// No alternative recovery approval, staging or startup path is provided.
    private func exposeSyntheticRestoreArchiveToSystemFiles(_ archive: URL) throws -> URL? {
        guard ProcessInfo.processInfo.arguments.contains("-ImpressV11RestorePickerE2E"),
              let fixture = ImpressV11UITestFixture.coldRestorePaths else { return nil }
        let manager = FileManager.default
        // Fail closed if a later code change returns a non-fixture archive:
        // shared Documents must NEVER receive ordinary App Support bytes.
        let scopedPath = fixture.support.standardizedFileURL.path + "/"
        guard archive.standardizedFileURL.path.hasPrefix(scopedPath) else {
            throw ImpressV3BackupFailure.notAuthorized
        }
        let identifier = fixture.support.deletingLastPathComponent().lastPathComponent
        let documents = manager.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let target = documents.appendingPathComponent(identifier + "-restorable.zip")
        // The SAME synthetic UUID can retry export after an inaccessible
        // system Files scene. Keep its first verified diagnostic ZIP rather
        // than fail on our own file-exists collision after process relaunch.
        // Never overwrite or delete a user-visible Files document.
        if manager.fileExists(atPath: target.path) {
            _ = try ImpressV3BackupArchive.inspectFile(
                target, name: target.lastPathComponent).0
            return target
        }
        try manager.copyItem(at: archive, to: target)
        do {
            let before = try ImpressV3BackupArchive.inspectFile(
                archive, name: archive.lastPathComponent).0
            let after = try ImpressV3BackupArchive.inspectFile(
                target, name: target.lastPathComponent).0
            guard before.sha256 == after.sha256, before.size == after.size else {
                throw ImpressV3BackupFailure.invalidChecksum
            }
        } catch {
            try? manager.removeItem(at: target)
            throw error
        }
        return target
    }

    /// A distinct in-scope source name proves a real folder-picker export:
    /// the separate "-restorable.zip" exists only for partial-E2E diagnosis.
    private func prepareSyntheticUserExportArchive(_ archive: URL) throws -> URL? {
        guard syntheticExportFixtureEnabled,
              let fixture = ImpressV11UITestFixture.coldRestorePaths else { return nil }
        let root = fixture.support.standardizedFileURL.path + "/"
        guard archive.standardizedFileURL.path.hasPrefix(root) else {
            throw ImpressV3BackupFailure.notAuthorized
        }
        let identifier = fixture.support.deletingLastPathComponent().lastPathComponent
        let target = fixture.support.appendingPathComponent(
            identifier + "-user-export.zip")
        let fm = FileManager.default
        // The previously prepared ZIP belongs to this isolated UUID fixture.
        // On a real Files picker retry, reuse only its verified original bytes:
        // a new forced backup has a new timestamp even if WCDB is unchanged.
        // Never overwrite a prepared archive or let a corrupt file pass.
        if fm.fileExists(atPath: target.path) {
            _ = try ImpressV3BackupArchive.inspectFile(
                target, name: target.lastPathComponent).0
            return target
        }
        try fm.copyItem(at: archive, to: target)
        do {
            let expected = try ImpressV3BackupArchive.inspectFile(
                archive, name: archive.lastPathComponent).0
            let actual = try ImpressV3BackupArchive.inspectFile(
                target, name: target.lastPathComponent).0
            guard expected.sha256 == actual.sha256,
                  expected.size == actual.size else {
                throw ImpressV3BackupFailure.invalidChecksum
            }
        } catch {
            try? fm.removeItem(at: target)
            throw error
        }
        return target
    }
    #endif

    private func chooseCloudFolder() {
        let warning = UIAlertController(
            title: V3L("确认备份隐私范围"),
            message: V3L("Impress 备份 ZIP 当前没有密码加密，任何获得该文件的人都可能读取卡片、复习历史、理解记录与提示词。请选择仅自己可以访问的 iCloud Drive 文件夹。授权后将尝试静默复制，上传到 iCloud 服务器是否完成由系统决定。"),
            preferredStyle: .alert)
        warning.addAction(UIAlertAction(title: V3L("取消"), style: .cancel))
        warning.addAction(UIAlertAction(title: V3L("继续选择文件夹"), style: .default) {
            [weak self] _ in self?.presentCloudFolderPicker()
        })
        present(warning, animated: true)
    }

    private func presentCloudFolderPicker() {
        pendingPurpose = .cloudFolder
        let picker = UIDocumentPickerViewController(
            forOpeningContentTypes: [UTType.folder], asCopy: false)
        picker.delegate = self
        picker.allowsMultipleSelection = false
        present(picker, animated: true)
    }

    private func chooseLegacyDatabase() {
        working = true
        tableView.reloadData()
        pendingPurpose = .restoreLegacyDatabase
        let sourceType = UTType(filenameExtension: "db") ?? .data
        let picker = UIDocumentPickerViewController(
            forOpeningContentTypes: [sourceType, .data], asCopy: true)
        picker.delegate = self
        picker.allowsMultipleSelection = false
        present(picker, animated: true)
    }

    private func chooseRestoreArchive() {
        // Busy starts at the picker, not after the archive has been selected.
        // Otherwise multiple pending recoveries can be queued before consent.
        working = true
        tableView.reloadData()
        pendingPurpose = .restoreArchive
        let picker = UIDocumentPickerViewController(
            forOpeningContentTypes: [UTType.zip], asCopy: true)
        picker.delegate = self
        picker.allowsMultipleSelection = false
        present(picker, animated: true)
    }

    func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
        if pendingPurpose == .restoreArchive || pendingPurpose == .exportArchive ||
           pendingPurpose == .restoreLegacyDatabase {
            pendingExportArchive = nil
            working = false
            #if DEBUG
            if syntheticExportFixtureEnabled { syntheticExportPhase = "CANCELLED" }
            #endif
            tableView.reloadData()
        }
        pendingPurpose = nil
    }

    func documentPicker(_ controller: UIDocumentPickerViewController,
                        didPickDocumentsAt urls: [URL]) {
        defer { pendingPurpose = nil }
        guard let url = urls.first, let purpose = pendingPurpose else {
            if pendingPurpose == .restoreArchive ||
               pendingPurpose == .exportArchive ||
               pendingPurpose == .restoreLegacyDatabase {
                pendingExportArchive = nil
                working = false
                tableView.reloadData()
            }
            return
        }
        switch purpose {
        case .restoreLegacyDatabase:
            let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(
                "ImpressLegacyImport-" + UUID().uuidString + ".db")
            do {
                // The user-selected File Provider object is copied; never open
                // or mutate the provider's source database in-place.
                try FileManager.default.copyItem(at: url, to: temporary)
                Task { [weak self] in
                    guard let self else {
                        try? FileManager.default.removeItem(at: temporary)
                        return
                    }
                    defer {
                        try? FileManager.default.removeItem(at: temporary)
                        working = false
                        tableView.reloadData()
                    }
                    do {
                        let repository = try ImpressV3ReviewEnvironment.repository()
                        let imported = try await repository.importApprovedLegacyDatabase(
                            at: temporary)
                        let alert = UIAlertController(
                            title: imported ? V3L("旧版数据导入完成") :
                                V3L("没有可新增的旧版数据"),
                            message: imported
                                ? V3L("旧数据库已完整读取并事务导入。原文件不变；请返回闪卡刷新复习队列。")
                                : V3L("这个来源已导入过，或所选数据库不含卡片和笔记。没有重复创建数据。"),
                            preferredStyle: .alert)
                        alert.addAction(UIAlertAction(title: V3L("确定"), style: .default))
                        present(alert, animated: true)
                    } catch { report(error) }
                }
            } catch {
                try? FileManager.default.removeItem(at: temporary)
                working = false
                tableView.reloadData()
                report(error)
            }
        case .exportArchive:
            guard let approvedSource = pendingExportArchive else {
                working = false
                tableView.reloadData()
                report(ImpressV3BackupFailure.notAuthorized)
                break
            }
            pendingExportArchive = nil
            // Only the URL explicitly picked by the user is writable. The
            // coordinator rejects name collisions and verifies actual bytes.
            Task { [weak self] in
                guard let self else { return }
                do {
                    _ = try await Task.detached(priority: .userInitiated) {
                        try ImpressV3ManualFileExport.save(
                            approvedSource, intoSelectedFolder: url)
                    }.value
                    self.working = false
                    #if DEBUG
                    if self.syntheticExportFixtureEnabled {
                        self.syntheticExportPhase = "COPIED_VERIFIED"
                    }
                    #endif
                    self.tableView.reloadData()
                    let alert = UIAlertController(
                        title: V3L("备份已导出"),
                        message: V3L("ZIP 已写入您选择的系统文件夹并完成校验。备份未加密；iCloud 远端上传可能延迟。"),
                        preferredStyle: .alert)
                    alert.addAction(UIAlertAction(title: V3L("确定"), style: .default))
                    self.present(alert, animated: true)
                } catch {
                    self.working = false
                    #if DEBUG
                    if self.syntheticExportFixtureEnabled {
                        self.syntheticExportPhase = "COPY_FAILED"
                    }
                    #endif
                    self.tableView.reloadData()
                    self.report(error)
                }
            }
        case .cloudFolder:
            do {
                try ImpressV3BackupCoordinator.connectCloudFolder(url)
                tableView.reloadData()
                // Existing local data is mirrored on the next backup check;
                // first connect also creates an authorized verified snapshot.
                Task {
                    do {
                        _ = try await ImpressV3BackupCoordinator.shared.createBackup(force: true)
                        self.tableView.reloadData()
                    } catch { self.report(error) }
                }
            } catch { report(error) }
        case .restoreArchive:
            // Keep the picker-provided temporary file while an explicit
            // recovery confirmation is displayed.
            let copy = FileManager.default.temporaryDirectory
                .appendingPathComponent("ImpressRestore-" + UUID().uuidString + ".zip")
            do {
                try FileManager.default.copyItem(at: url, to: copy)
                validateRestore(copy)
            } catch {
                working = false
                tableView.reloadData()
                report(error)
            }
        }
    }

    private func validateRestore(_ archive: URL) {
        working = true
        tableView.reloadData()
        Task { [weak self] in
            guard let self else {
                try? FileManager.default.removeItem(at: archive)
                return
            }
            // Keep all Settings rows disabled across the human consent sheet;
            // cancelling or completing staging alone releases the gate.
            do {
                let preview = try await ImpressV3BackupCoordinator.shared.inspectRecovery(archive)
                let info = "日期：\(Self.dateFormatter.string(from: preview.manifest.createdAt))\n" +
                    "卡片：\(preview.cardCount) 张\n" +
                    "复习历史：\(preview.reviewCount) 条\n" +
                    "理解记录：\(preview.learningCount) 条\n" +
                    (preview.calibrationCount.map { "校准历史：\($0) 天（V3.2）\n" }
                     ?? "旧版备份不含校准历史；保留本机现有校准数据。\n") +
                    "提示词模板：已验证\n" +
                    "Obsidian 外部原件不会被修改。\n\n" +
                    "当前数据会先创建回滚备份，恢复在下次重新启动时生效。"
                let alert = UIAlertController(
                    title: V3L("确认恢复 Impress 数据？"),
                    message: info, preferredStyle: .alert)
                alert.addAction(UIAlertAction(title: V3L("取消"), style: .cancel) {
                    [weak self] _ in
                    try? FileManager.default.removeItem(at: archive)
                    self?.working = false
                    self?.tableView.reloadData()
                })
                alert.addAction(UIAlertAction(title: V3L("确认恢复"), style: .destructive) {
                    [weak self] _ in
                    guard let self else { return }
                    self.stageRestore(archive)
                })
                present(alert, animated: true)
            } catch {
                try? FileManager.default.removeItem(at: archive)
                working = false
                tableView.reloadData()
                report(error)
            }
        }
    }

    private func stageRestore(_ archive: URL) {
        working = true
        tableView.reloadData()
        Task { [weak self] in
            guard let self else { return }
            defer {
                try? FileManager.default.removeItem(at: archive)
                working = false
                tableView.reloadData()
            }
            do {
                try await ImpressV3BackupCoordinator.shared.stageRecovery(archive)
                let alert = UIAlertController(
                    title: V3L("恢复文件已安全暂存"),
                    message: V3L("请完全退出 Impress，再重新打开。恢复前的数据库备份已保留；不会触碰 Obsidian 源文件。"),
                    preferredStyle: .alert)
                alert.addAction(UIAlertAction(title: V3L("确定"), style: .default))
                present(alert, animated: true)
            } catch { report(error) }
        }
    }

    private func report(_ error: Error) {
        let alert = UIAlertController(title: V3L("操作未完成"),
            message: error.localizedDescription, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: V3L("确定"), style: .default))
        if presentedViewController == nil { present(alert, animated: true) }
    }
}
