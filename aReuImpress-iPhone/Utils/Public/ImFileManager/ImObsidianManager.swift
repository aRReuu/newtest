//
//  ImObsidianManager.swift
//  aReuImpress-iPhone
//
//  Created by aReu on 9/18/25.
//  实现本地Obsidian数据库的文件管理业务

import UIKit
import MobileCoreServices
import UniformTypeIdentifiers
import ImpressReviewCore
import ImageIO

final class ImObsidianManager: NSObject
{
    static let shared = ImObsidianManager()
  
    // 默认要跳过的目录
    private let ignoreDirectory: Set<String> = [".obsidian", "attachments"]

    // MARK: - 1. 获取本地Vault URL
    /// 直接返回本地Documents/ImpressDB目录的URL
    /// - Parameters:
    ///   - presenter: 用于呈现错误提示的视图控制器
    ///   - body: 处理URL的闭包，包含结束访问回调
    ///   - onError: 错误回调
    func withVaultURL(from presenter: UIViewController,
                      body: @escaping (_ url: URL, _ endAccess: @escaping () -> Void) -> Void,
                      onError: ((Error) -> Void)? = nil)
    {
        // 获取Documents目录
        guard let documentsURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else {
            let err = NSError(domain: "ImObsidianManager", code: -1, userInfo: [NSLocalizedDescriptionKey: "无法获取Documents目录"])
            onError?(err)
            return
        }
        
        let vaultURL = documentsURL.appendingPathComponent(ObsidianFolderName)
        
        // P0-0: read-only browsing must not silently create an empty
        // ImpressVault directory. Otherwise a safe first-time importer would
        // always see a pre-existing target and refuse to initialize.
        // Missing mirror is a valid empty state until explicit import.
        // 直接调用body，无需安全域访问
        body(vaultURL, {
            // 空操作，本地目录无需停止访问
        })
    }

    
    // MARK: - 2. 文件读写
    /// 读取指定文件内容并返回字符串
    func readMarkdownFile(from presenter: UIViewController,
                          at relativePath: String,
                          completion: @escaping (String?) -> Void)
    {
        withVaultURL(from: presenter, body: { vaultURL, _ in
            let fileURL = vaultURL.appendingPathComponent(relativePath)
            
            do {
                let content = try String(contentsOf: fileURL, encoding: .utf8)
                completion(content)
            } catch {
                zcLog("读取文件失败: \(error)")
                completion(nil)
            }
        }, onError: { error in
            zcLog("withVaultURL error: \(error)")
            completion(nil)
        })
    }

    // P0-0: The legacy write API could overwrite Markdown rendered by UITextView,
    // losing Obsidian frontmatter, wikilinks and other source syntax. Fail closed.
    // A future write gate must own source-version verification, backup, user
    // confirmation, file coordination and post-write readback.
    @available(*, deprecated, message: "Use the future verified Vault write coordinator after P0-4")
    func writeMarkdownFile(from presenter: UIViewController,
                           at relativePath: String,
                           content: String,
                           completion: ((Error?) -> Void)? = nil)
    {
        let error = NSError(
            domain: "ImObsidianManager", code: -10,
            userInfo: [NSLocalizedDescriptionKey:
                "为保护 Obsidian 原始 Markdown，旧版覆盖写回已停用；请使用只读查看或保存独立草稿。"])
        completion?(error)
    }
}



#if DEBUG
/// One disposable, repeatable Simulator fixture. Never consult a real Vault
/// bookmark when BOTH the explicit test flag and UUID environment ID exist.
enum ImpressV11UITestFixture {
    // Distinguish an explicit but malformed Debug fixture request from a
    // normal production launch. The former must NEVER fall through to the
    // live application restore/database paths.
    static var requested: Bool {
        ProcessInfo.processInfo.arguments.contains("-ImpressV11SyntheticVault")
    }
    static func validatedID(arguments: [String], environment: [String: String]) -> UUID? {
        guard arguments.contains("-ImpressV11SyntheticVault"),
              let raw = environment["IMPRESS_V11_FIXTURE_ID"]
        else { return nil }
        return UUID(uuidString: raw)
    }
    static var id: UUID? {
        validatedID(arguments: ProcessInfo.processInfo.arguments,
                    environment: ProcessInfo.processInfo.environment)
    }
    static var enabled: Bool { id != nil }
    static var vaultID: String? { id.map { "impress-v11-test-" + $0.uuidString } }
    static var sessionRoot: URL? {
        id.map { FileManager.default.temporaryDirectory.appendingPathComponent(
            "ImpressV11-" + $0.uuidString, isDirectory: true) }
    }
    /// All cold-restore targets are strictly under a UUID-scoped, disposable
    /// Simulator directory. The production backup transaction uses the same
    /// relative Documents/ImpressV3 database layout as this test repository.
    /// Never derive these paths from user-supplied Vault identity or bookmarks.
    static func coldRestorePaths(for fixtureID: UUID) -> (
        support: URL, documents: URL, calibration: URL,
        database: URL, promptsSuiteName: String
    ) {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(
            "ImpressV11-" + fixtureID.uuidString, isDirectory: true)
        let documents = base.appendingPathComponent("Documents", isDirectory: true)
        return (
            support: base.appendingPathComponent("Support", isDirectory: true),
            documents: documents,
            calibration: base.appendingPathComponent("Calibration/checkins-v1.json"),
            database: documents.appendingPathComponent("ImpressV3/ReviewV3.sqlite"),
            promptsSuiteName: "ImpressV11Restore-" + fixtureID.uuidString
        )
    }
    static var coldRestorePaths: (
        support: URL, documents: URL, calibration: URL,
        database: URL, promptsSuiteName: String
    )? {
        guard let id else { return nil }
        return coldRestorePaths(for: id)
    }
    static var databaseURL: URL? { coldRestorePaths?.database }
    static func root() throws -> URL {
        guard let path = sessionRoot?.appendingPathComponent(
            "Impress-Write-Test-Vault", isDirectory: true) else {
            throw ImVaultReadOnlyError.notAuthorized
        }
        let root = path.standardizedFileURL.resolvingSymlinksInPath()
        let tmp = FileManager.default.temporaryDirectory.standardizedFileURL
            .resolvingSymlinksInPath().path + "/"
        guard root.path.hasPrefix(tmp),
              root.lastPathComponent == "Impress-Write-Test-Vault" else {
            throw ImVaultReadOnlyError.notAuthorized
        }
        let fence = String(repeating: String(Character(UnicodeScalar(96)!)), count: 3)
        let files: [String: String] = [
            "Study/Impress_E2E_Proof.md":
                "# 来源与证据\n## 观察\n所有解释必须能反向核查原始证据。\n" +
                "## 假设\n需要可证伪的前提。\n## 反例\n无关段落不被隐式上传。\n",
            "Study/Graph.md":
                "# 本地图形\n## Mermaid\n" + fence +
                "mermaid\nflowchart LR\nA[观察] --> B[验证]\nC[不可上传]\n" +
                fence + "\n## Markmap\n### 机制\n### 反例\n" +
                "- 证据主分支\n  - 经过审核的子节点\n  - 未获批准的兄弟分支\n",
            "Study/Reader-Properties.md":
                "---\nmindmap-plugin: basic\ntags:\n  - focus\n  - review\n" +
                "Date: 2026-01-31\nStatus:\nActive: false\nCount: 3\n" +
                "Next: \"[[Graph|图形笔记]]\"\n---\n" +
                "# Reader-Properties\n## 正文说明\n本段不是属性。\n",
            "Study/Reader-Nested.md":
                "#### 多层结构\n- 第一层\n  - 第二层说明\n    - 第三层\n" +
                "      1. 嵌套有序项目\n      2. 长文本自动折行，不应暴露源码标记\n" +
                "- [ ] 待办\n- [x] 已完成\n> [!NOTE] 提示\n> 延续上下文\n",
            "Study/Reader-Embedded.md":
                "# Reader-Embedded\n下面是范围核查后的源文档：\n" +
                "![[Study/Reader-Child.md#事实]]\n" +
                "错误依赖：![[Study/Missing.md]]\n",
            "Study/Reader-Child.md":
                "# 背景\n省略的背景。\n## 事实\n只保留所选章节。\n" +
                "## 细节\n该子节应归属事实。\n# 其他\n不应出现在选定范围。\n",
            "Study/Reader-Markmap.md":
                "# Reader-Markmap\n## 结构阅读\n~~~markmap\n# 主题\n" +
                "## 方向 A\n- 基本概念\n## 方向 B\n- 复习节点\n~~~\n",
            "Study/Reader-Math.md":
                "# Reader-Math\n公式：$E=mc^2$\n\n$$\na+b=c\n$$\n",
            "Study/Reader-Composite.md":
                "# Reader-Composite\n## 内嵌 Canvas\n![[Study/Diagram.canvas]]\n" +
                "## 内嵌 Excalidraw\n![[Study/Drawing.excalidraw]]\n" +
                "## 源码不应投影\n" +
                "```md\n![[Study/Missing.canvas]]\n```\n",
            "Study/Diagram.canvas":
                "{\"nodes\":[{\"id\":\"a\",\"type\":\"text\",\"x\":0,\"y\":0,\"width\":150,\"height\":85,\"text\":\"图形范围\"}],\"edges\":[]}",
            "Study/Drawing.excalidraw":
                "{\"type\":\"excalidraw\",\"elements\":[{\"id\":\"a\",\"type\":\"rectangle\",\"x\":0,\"y\":0,\"width\":150,\"height\":90,\"strokeColor\":\"#4f93b3\"},{\"id\":\"private\",\"type\":\"text\",\"x\":200,\"y\":0,\"width\":160,\"height\":90,\"text\":\"Unapproved\"}]}",
            "Study/Legacy-Drawing.md":
                "---\nexcalidraw-plugin: parsed\ntags: [excalidraw]\n---\n" +
                "# Text Elements\nOnly a text index\n# Drawing\n" +
                fence + "json\n" +
                "{\"type\":\"excalidraw\",\"elements\":[{\"id\":\"a\",\"type\":\"rectangle\",\"x\":0,\"y\":0,\"width\":150,\"height\":90,\"strokeColor\":\"#4f93b3\"}]}" +
                "\n" + fence + "\n"
        ]
        for (name, contents) in files {
            let destination = root.appendingPathComponent(name)
            try FileManager.default.createDirectory(
                at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            if !FileManager.default.fileExists(atPath: destination.path) {
                try Data(contents.utf8).write(to: destination, options: .atomic)
            }
        }
        return root
    }
}
#endif

// MARK: - P0-1: Authorized external Obsidian Vault READ-ONLY probe
//
// This is intentionally separate from the legacy sandbox mirror. A successful
// picker/bookmark test must never redirect existing read/write APIs or modify
// Obsidian files. Actual two-way writes require the P0-3/P0-4 gate.
struct ImVaultReadOnlyReport {
    let name: String
    let markdownCount: Int
    let sampleRelativePaths: [String]
    let sampleBytesRead: Int
    let restoredFromBookmark: Bool
    let wasTruncated: Bool
}

enum ImVaultReadOnlyError: LocalizedError {
    case busy
    case noFolder
    case notAuthorized
    case missingBookmark
    case staleBookmark
    case notDirectory
    case unableToEnumerate

    var errorDescription: String? {
        switch self {
        case .busy: return "正在处理另一项 Vault 授权检查。"
        case .noFolder: return "没有选择文件夹。"
        case .notAuthorized: return "系统未授予此 Vault 的安全访问权限；原始笔记未修改。"
        case .missingBookmark: return "尚未保存 Vault 目录授权，请先选择文件夹。"
        case .staleBookmark: return "目录授权已失效或文件夹已移动，请重新选择；不会自动新建或修改文件。"
        case .notDirectory: return "选中资源不是可读取的 Vault 文件夹。"
        case .unableToEnumerate: return "无法枚举此 Vault，请检查 Files 中的访问与 iCloud 下载状态。"
        }
    }
}

final class ImVaultReadOnlyProbe: NSObject, UIDocumentPickerDelegate {
    static let shared = ImVaultReadOnlyProbe()

    private static let bookmarkKey = "ImpressV3P0VaultReadOnlyBookmark"
    private static let vaultIDKey = "ImpressV3P0VaultID"
    private var awaitingPicker: ((Result<ImVaultReadOnlyReport, Error>) -> Void)?

    private override init() { super.init() }

    /// Revokes the app's persisted capability reference only. Never touches
    /// the provider's directory or any note and does not revoke iOS-wide grants.
    func disconnectSavedPermission() {
        UserDefaults.standard.removeObject(forKey: Self.bookmarkKey)
        UserDefaults.standard.removeObject(forKey: Self.vaultIDKey)
    }

    func chooseFolder(from presenter: UIViewController,
                      completion: @escaping (Result<ImVaultReadOnlyReport, Error>) -> Void) {
        guard awaitingPicker == nil else {
            completion(.failure(ImVaultReadOnlyError.busy))
            return
        }
        awaitingPicker = completion
        // iOS 14+: open the actual provider URL, never copy the Vault.
        let picker = UIDocumentPickerViewController(
            forOpeningContentTypes: [UTType.folder], asCopy: false)
        picker.allowsMultipleSelection = false
        picker.delegate = self
        presenter.present(picker, animated: true)
    }

    func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
        // Cancelling only dismisses the picker; does not change the saved grant.
        let callback = awaitingPicker
        awaitingPicker = nil
        callback?(.failure(ImVaultReadOnlyError.noFolder))
    }

    func documentPicker(_ controller: UIDocumentPickerViewController,
                        didPickDocumentsAt urls: [URL]) {
        guard let url = urls.first else {
            let callback = awaitingPicker
            awaitingPicker = nil
            callback?(.failure(ImVaultReadOnlyError.noFolder))
            return
        }
        DispatchQueue.global(qos: .utility).async {
            let result: Result<(ImVaultReadOnlyReport, Data), Error> = Result {
                guard url.startAccessingSecurityScopedResource() else {
                    throw ImVaultReadOnlyError.notAuthorized
                }
                defer { url.stopAccessingSecurityScopedResource() }

                let report = try Self.inspectAccessibleFolder(url, restored: false)
                // On iOS an ordinary bookmark made from a picker scoped URL
                // can be resolved to a scoped URL on a future launch.
                let bookmark = try url.bookmarkData(
                    options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
                return (report, bookmark)
            }
            DispatchQueue.main.async {
                let callback = self.awaitingPicker
                self.awaitingPicker = nil
                switch result {
                case let .success((report, bookmark)):
                    // Only the URL authorization is persisted. No file content
                    // or test files are written to Obsidian.
                    // Re-selecting the very same authorized folder must
                    // retain stable draft/index identity across sessions.
                    var persistentID = UUID().uuidString
                    if let oldBookmark = UserDefaults.standard.data(forKey: Self.bookmarkKey),
                       let oldID = UserDefaults.standard.string(forKey: Self.vaultIDKey) {
                        var wasStale = false
                        if let oldURL = try? URL(resolvingBookmarkData: oldBookmark, options: [],
                                                 relativeTo: nil, bookmarkDataIsStale: &wasStale),
                           !wasStale && oldURL.standardizedFileURL.path == url.standardizedFileURL.path {
                            persistentID = oldID
                        }
                    }
                    UserDefaults.standard.set(bookmark, forKey: Self.bookmarkKey)
                    UserDefaults.standard.set(persistentID, forKey: Self.vaultIDKey)
                    callback?(.success(report))
                case let .failure(error):
                    callback?(.failure(error))
                }
            }
        }
    }

    func inspectSavedPermission(
        completion: @escaping (Result<ImVaultReadOnlyReport, Error>) -> Void
    ) {
        guard let bookmark = UserDefaults.standard.data(forKey: Self.bookmarkKey) else {
            completion(.failure(ImVaultReadOnlyError.missingBookmark))
            return
        }
        DispatchQueue.global(qos: .utility).async {
            let result: Result<ImVaultReadOnlyReport, Error> = Result {
                var isStale = false
                let url = try URL(
                    resolvingBookmarkData: bookmark, options: [],
                    relativeTo: nil, bookmarkDataIsStale: &isStale)
                guard !isStale else { throw ImVaultReadOnlyError.staleBookmark }
                guard url.startAccessingSecurityScopedResource() else {
                    throw ImVaultReadOnlyError.notAuthorized
                }
                defer { url.stopAccessingSecurityScopedResource() }
                return try Self.inspectAccessibleFolder(url, restored: true)
            }
            DispatchQueue.main.async { completion(result) }
        }
    }

    /// Pure read probe. No FileManager create/remove/move/copy/write calls.
    private static func inspectAccessibleFolder(_ scopedURL: URL,
                                                 restored: Bool) throws -> ImVaultReadOnlyReport {
        let fileManager = FileManager.default
        let coordinator = NSFileCoordinator(filePresenter: nil)
        var coordinationError: NSError?
        var inspectionError: Error?
        var count = 0
        var samples = [String]()
        var firstNote: URL?
        coordinator.coordinate(readingItemAt: scopedURL, options: [],
                               error: &coordinationError) { folder in
            do {
                var isDirectory: ObjCBool = false
                guard fileManager.fileExists(atPath: folder.path, isDirectory: &isDirectory),
                      isDirectory.boolValue else { throw ImVaultReadOnlyError.notDirectory }
                let prefix = folder.standardizedFileURL.path + "/"
                guard let files = fileManager.enumerator(
                    at: folder,
                    includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
                    options: [.skipsHiddenFiles],
                    errorHandler: { _, error in
                        inspectionError = error
                        return false
                    }) else { throw ImVaultReadOnlyError.unableToEnumerate }

                while let file = files.nextObject() as? URL {
                    if file.lastPathComponent == ".obsidian" {
                        files.skipDescendants()
                        continue
                    }
                    guard file.pathExtension.lowercased() == "md" else { continue }
                    let values = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
                    guard values.isRegularFile == true,
                          values.isSymbolicLink != true,
                          file.standardizedFileURL.path.hasPrefix(prefix) else { continue }
                    count += 1
                    if firstNote == nil { firstNote = file }
                    if samples.count < 3 {
                        samples.append(String(file.standardizedFileURL.path.dropFirst(prefix.count)))
                    }
                }
            } catch { inspectionError = error }
        }
        if let error = coordinationError { throw error }
        if let error = inspectionError { throw error }

        // Verify real read permission on a sample Markdown file (max 4 KiB).
        // No parsing, caching, upload, automatic deletion or modification.
        var bytesRead = 0
        if let firstNote = firstNote {
            var fileCoordinationError: NSError?
            var openError: Error?
            coordinator.coordinate(readingItemAt: firstNote, options: [],
                                   error: &fileCoordinationError) { file in
                do {
                    let handle = try FileHandle(forReadingFrom: file)
                    defer { handle.closeFile() }
                    bytesRead = handle.readData(ofLength: 4096).count
                } catch { openError = error }
            }
            if let error = fileCoordinationError { throw error }
            if let error = openError { throw error }
        }
        return ImVaultReadOnlyReport(
            name: scopedURL.lastPathComponent,
            markdownCount: count,
            sampleRelativePaths: samples,
            sampleBytesRead: bytesRead,
            restoredFromBookmark: restored,
            wasTruncated: false)
    }
}


// MARK: - P0-2 / authorized source-of-truth read-only index and raw Markdown

enum ImVaultSyncFailure: LocalizedError {
    case wrongVault, unsafePath, unavailable, notDownloaded, tooLarge, notUTF8, incompleteIndex
    case conflict, previewTruncated, approvalMissing, writesLocked, verificationFailed, deviceTestVaultRequired
    case unsupportedComplexWrite
    var errorDescription: String? {
        switch self {
        case .wrongVault: return "Vault 与草稿身份不匹配，拒绝操作。"
        case .unsafePath: return "路径不安全；禁止访问或写回。"
        case .unavailable: return "源文件丢失、移动或不可读取，原内容未改变。"
        case .notDownloaded: return "这份笔记尚未从 iCloud 下载到本机。请先在「文件」App 中下载原件后重新打开。"
        case .tooLarge: return "文件超过 8MB 安全读取或编辑上限。"
        case .notUTF8: return "该文件不是有效 UTF-8，原文件保持不变。"
        case .incompleteIndex: return "Vault 索引扫描未完成，不能覆盖已有索引。"
        case .conflict: return "Obsidian 已更新源文件，Impress 草稿保留，禁止自动覆盖。"
        case .previewTruncated: return "Diff 未完整显示，禁止提交。"
        case .approvalMissing: return "未确认本次修改，禁止提交。"
        case .writesLocked: return "真实 Vault 写回尚未通过设备安全 Gate；草稿已保留。"
        case .deviceTestVaultRequired: return "只允许在 Debug QA 中操作通过「文件」选定、名称为 Impress-Write-Test-Vault 的独立测试副本。真实 Vault 保持只读；草稿已保留。"
        case .verificationFailed: return "备份或写后回读验证失败，保留草稿以供恢复。"
        case .unsupportedComplexWrite: return "Excalidraw 与 Canvas 只允许阅读和选材，不可由通用 Markdown 写入器覆盖。"
        }
    }
}

struct ImVaultIndexNote: Codable, Equatable {
    let identity: ImVaultFileIdentity
    let bytes: Int
    let modified: Date?
    var title: String {
        URL(fileURLWithPath: identity.relativePath).deletingPathExtension().lastPathComponent
    }
}
struct ImVaultIndexResult {
    let notes: [ImVaultIndexNote]
    let added: Int
    let modified: Int
    let removed: Int
}
struct ImVaultRawDocument {
    let identity: ImVaultFileIdentity
    let sourceBytes: Data
    let markdown: String
    let digest: String
}

extension ImVaultReadOnlyProbe {
    var authorizedVaultID: String? {
        #if DEBUG
        if let synthetic = ImpressV11UITestFixture.vaultID { return synthetic }
        #endif
        guard UserDefaults.standard.data(forKey: Self.bookmarkKey) != nil else {
            return nil
        }
        return UserDefaults.standard.string(forKey: Self.vaultIDKey)
    }

    var hasAuthorizedBookmark: Bool { authorizedVaultID != nil }

    // Each callback owns exactly one scoped-access lease, then releases it.
    func withAuthorizedRoot<T>(
        _ operation: @escaping (URL, String) throws -> T,
        qos: DispatchQoS.QoSClass = .utility,
        completion: @escaping (Result<T, Error>) -> Void
    ) {
        #if DEBUG
        if let id = ImpressV11UITestFixture.vaultID {
            DispatchQueue.global(qos: qos).async {
                let outcome: Result<T, Error> = Result {
                    try operation(ImpressV11UITestFixture.root(), id)
                }
                DispatchQueue.main.async { completion(outcome) }
            }
            return
        }
        #endif
        guard let bookmark = UserDefaults.standard.data(forKey: Self.bookmarkKey),
              let id = UserDefaults.standard.string(forKey: Self.vaultIDKey) else {
            completion(.failure(ImVaultReadOnlyError.missingBookmark)); return
        }
        DispatchQueue.global(qos: qos).async {
            let result: Result<T, Error> = Result {
                var stale = false
                let root = try URL(resolvingBookmarkData: bookmark, options: [],
                                   relativeTo: nil, bookmarkDataIsStale: &stale)
                guard !stale else { throw ImVaultReadOnlyError.staleBookmark }
                guard root.startAccessingSecurityScopedResource() else {
                    throw ImVaultReadOnlyError.notAuthorized
                }
                defer { root.stopAccessingSecurityScopedResource() }
                return try operation(root, id)
            }
            DispatchQueue.main.async { completion(result) }
        }
    }
}

final class ImVaultReadSync {
    static let shared = ImVaultReadSync()
    private init() {}

    func cachedIndex(_ completion: @escaping (Result<[ImVaultIndexNote], Error>) -> Void) {
        // The saved index is provisional and scoped to a validated Vault ID.
        ImVaultReadOnlyProbe.shared.withAuthorizedRoot({ _, id in
            try ImVaultPrivateStore.loadIndex(vaultID: id)
        }, completion: completion)
    }

    func refresh(progress: (([ImVaultIndexNote]) -> Void)? = nil,
                 _ completion: @escaping (Result<ImVaultIndexResult, Error>) -> Void) {
        ImVaultReadOnlyProbe.shared.withAuthorizedRoot({ root, id in
            let next = try Self.list(root: root, vaultID: id, onBatch: { batch in
                DispatchQueue.main.async { progress?(batch) }
            })
            let previous = (try? ImVaultPrivateStore.loadIndex(vaultID: id)) ?? []
            let old = Dictionary(uniqueKeysWithValues: previous.map { ($0.identity, $0) })
            let current = Set(next.map { $0.identity })
            let added = next.filter { old[$0.identity] == nil }.count
            let changed = next.filter { old[$0.identity] != nil && old[$0.identity] != $0 }.count
            let removed = previous.filter { !current.contains($0.identity) }.count
            // A full successful scan is required before updating private cache.
            try ImVaultPrivateStore.saveIndex(next, vaultID: id)
            return ImVaultIndexResult(notes: next, added: added,
                                      modified: changed, removed: removed)
        }, completion: completion)
    }

    func read(_ identity: ImVaultFileIdentity,
              completion: @escaping (Result<ImVaultRawDocument, Error>) -> Void) {
        ImVaultReadOnlyProbe.shared.withAuthorizedRoot({ root, vaultID in
            guard identity.vaultID == vaultID else { throw ImVaultSyncFailure.wrongVault }
            return try Self.load(root: root, identity: identity)
        }, qos: .userInitiated, completion: completion)
    }

    static func enforceContainment(_ file: URL, root: URL) throws {
        let parent = root.standardizedFileURL.resolvingSymlinksInPath().path + "/"
        let child = file.standardizedFileURL.resolvingSymlinksInPath().path
        guard child.hasPrefix(parent) else { throw ImVaultSyncFailure.unsafePath }
    }

    static func fileURL(root: URL, identity: ImVaultFileIdentity) throws -> URL {
        // Revalidating decoded identity also rejects traversal from forged JSON.
        _ = try ImVaultFileIdentity(vaultID: identity.vaultID,
                                    relativePath: identity.relativePath)
        let path = root.appendingPathComponent(identity.relativePath, isDirectory: false)
        try enforceContainment(path, root: root)
        return path
    }

    static func list(root: URL, vaultID: String,
                     onBatch: (([ImVaultIndexNote]) -> Void)? = nil) throws -> [ImVaultIndexNote] {
        let coordinator = NSFileCoordinator(filePresenter: nil)
        var coordinationError: NSError?
        var operationError: Error?
        var notes = [ImVaultIndexNote]()
        coordinator.coordinate(readingItemAt: root, options: [],
                               error: &coordinationError) { folder in
            do {
                let prefix = folder.standardizedFileURL.resolvingSymlinksInPath().path + "/"
                guard let enumerator = FileManager.default.enumerator(
                    at: folder, includingPropertiesForKeys: [
                        .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey,
                        .contentModificationDateKey],
                    options: [.skipsHiddenFiles],
                    errorHandler: { _, error in operationError = error; return false }
                ) else { throw ImVaultSyncFailure.incompleteIndex }
                var batch = [ImVaultIndexNote]()
                while let url = enumerator.nextObject() as? URL {
                    guard ["md", "canvas", "excalidraw"].contains(
                        url.pathExtension.lowercased()) else { continue }
                    let resolved = url.standardizedFileURL.resolvingSymlinksInPath()
                    guard resolved.path.hasPrefix(prefix) else { continue }
                    let v = try url.resourceValues(forKeys: [
                        .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey,
                        .contentModificationDateKey])
                    guard v.isRegularFile == true && v.isSymbolicLink != true else { continue }
                    let relative = String(resolved.path.dropFirst(prefix.count))
                    let id = try ImVaultFileIdentity(vaultID: vaultID, relativePath: relative)
                    let note = ImVaultIndexNote(identity: id, bytes: v.fileSize ?? 0,
                                                modified: v.contentModificationDate)
                    notes.append(note)
                    batch.append(note)
                    if batch.count == 128 {
                        onBatch?(batch)
                        batch.removeAll(keepingCapacity: true)
                    }
                }
                if !batch.isEmpty { onBatch?(batch) }
            } catch { operationError = error }
        }
        if let error = coordinationError { throw error }
        if let error = operationError { throw error }
        return notes.sorted { $0.identity.relativePath < $1.identity.relativePath }
    }

    static func load(root: URL, identity: ImVaultFileIdentity) throws -> ImVaultRawDocument {
        let source = try fileURL(root: root, identity: identity)
        var coordinationError: NSError?
        var operationError: Error?
        var content: Data?
        let coordinator = NSFileCoordinator(filePresenter: nil)
        coordinator.coordinate(readingItemAt: source, options: [],
                               error: &coordinationError) { file in
            do {
                try enforceContainment(file, root: root)
                let v = try file.resourceValues(forKeys: [
                    .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey,
                    .isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey])
                if v.isUbiquitousItem == true &&
                   v.ubiquitousItemDownloadingStatus == .notDownloaded {
                    throw ImVaultSyncFailure.notDownloaded
                }
                guard v.isRegularFile == true && v.isSymbolicLink != true else {
                    throw ImVaultSyncFailure.unsafePath
                }
                guard (v.fileSize ?? 0) <= 8 * 1024 * 1024 else {
                    throw ImVaultSyncFailure.tooLarge
                }
                let bytes = try Data(contentsOf: file)
                guard bytes.count <= 8 * 1024 * 1024 else { throw ImVaultSyncFailure.tooLarge }
                content = bytes
            } catch { operationError = error }
        }
        if let error = coordinationError { throw error }
        if let error = operationError { throw error }
        guard let bytes = content else { throw ImVaultSyncFailure.unavailable }
        guard let text = String(data: bytes, encoding: .utf8) else {
            throw ImVaultSyncFailure.notUTF8
        }
        return ImVaultRawDocument(identity: identity, sourceBytes: bytes,
                                  markdown: text, digest: ImVaultDigest.sha256(bytes))
    }
}


// MARK: - P0-3 private drafts and retained recovery backups
//
// This service MUST NOT resolve any private path by the user's relativePath;
// paths are SHA-256 names inside the Impress Application Support sandbox.
enum ImVaultPrivateStore {
    private static let draftLock = NSLock()
    private static func protectPrivateFile(_ url: URL) {
        try? FileManager.default.setAttributes(
            [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
            ofItemAtPath: url.path)
    }
    private static func directory(_ part: String) throws -> URL {
        let root = try FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: true)
        let target = root.appendingPathComponent("ImpressVaultSync", isDirectory: true)
            .appendingPathComponent(part, isDirectory: true)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        return target
    }

    private static func opaqueKey(_ identity: ImVaultFileIdentity) -> String {
        ImVaultDigest.sha256(Data((identity.vaultID + "\n" + identity.relativePath).utf8))
    }

    static func saveIndex(_ list: [ImVaultIndexNote], vaultID: String) throws {
        let key = ImVaultDigest.sha256(Data(vaultID.utf8))
        let url = try directory("Index").appendingPathComponent(key + ".json")
        try JSONEncoder().encode(list).write(to: url, options: .atomic)
        protectPrivateFile(url)
    }

    static func loadIndex(vaultID: String) throws -> [ImVaultIndexNote] {
        let key = ImVaultDigest.sha256(Data(vaultID.utf8))
        let url = try directory("Index").appendingPathComponent(key + ".json")
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        return try JSONDecoder().decode([ImVaultIndexNote].self,
                                        from: Data(contentsOf: url))
    }

    static func saveDraft(_ draft: ImVaultDraft) throws {
        try draft.validate()
        draftLock.lock()
        defer { draftLock.unlock() }
        let url = try directory("Draft").appendingPathComponent(
            opaqueKey(draft.identity) + ".json")
        // A queued older autosave must never overwrite a newer explicit save.
        if let newer = try loadDraft(identity: draft.identity),
           newer.updatedAt > draft.updatedAt {
            return
        }
        try JSONEncoder().encode(draft).write(to: url, options: .atomic)
        protectPrivateFile(url)
        let checked = try loadDraft(identity: draft.identity)
        guard checked?.identity == draft.identity,
              checked?.baseDigest == draft.baseDigest,
              checked?.baseRawData == draft.baseRawData,
              checked?.editedText == draft.editedText else {
            throw ImVaultSyncFailure.verificationFailed
        }
    }

    static func loadDraft(identity: ImVaultFileIdentity) throws -> ImVaultDraft? {
        let url = try directory("Draft").appendingPathComponent(opaqueKey(identity) + ".json")
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let draft = try JSONDecoder().decode(ImVaultDraft.self, from: Data(contentsOf: url))
        guard draft.identity == identity else { throw ImVaultCoreError.invalidDraft }
        try draft.validate()
        return draft
    }


    // Immutable private approval snapshots. The per-note editable draft may be
    // replaced by a new revision; an older Chat receipt still needs its exact
    // preimage bytes and approved edit to support verification/undo.
    private static func approvedURL(identity: ImVaultFileIdentity,
                                    baseDigest: String,
                                    editedDigest: String) throws -> URL {
        let hex = "^[0-9a-f]{64}$"
        guard baseDigest.range(of: hex, options: .regularExpression) != nil,
              editedDigest.range(of: hex, options: .regularExpression) != nil,
              baseDigest != editedDigest else { throw ImVaultCoreError.invalidDraft }
        let scope = opaqueKey(identity) + ":" + baseDigest + ":" + editedDigest
        return try directory("ApprovedDraft").appendingPathComponent(
            ImVaultDigest.sha256(Data(scope.utf8)) + ".json")
    }

    private static func verifyApproved(_ draft: ImVaultDraft,
                                       identity: ImVaultFileIdentity,
                                       baseDigest: String,
                                       editedDigest: String) throws {
        try draft.validate()
        guard draft.identity == identity, draft.hasChanges,
              draft.baseDigest == baseDigest,
              ImVaultDigest.sha256(draft.proposedBytes) == editedDigest else {
            throw ImVaultCoreError.invalidDraft
        }
    }

    /// Idempotent and immutable: never replace an existing mismatched record.
    /// This keeps personal Markdown only in protected Application Support.
    static func archiveApprovedDraft(_ draft: ImVaultDraft) throws {
        let edited = ImVaultDigest.sha256(draft.proposedBytes)
        try verifyApproved(draft, identity: draft.identity,
                           baseDigest: draft.baseDigest, editedDigest: edited)
        let url = try approvedURL(identity: draft.identity,
                                  baseDigest: draft.baseDigest, editedDigest: edited)
        draftLock.lock()
        defer { draftLock.unlock() }
        if FileManager.default.fileExists(atPath: url.path) {
            let saved = try JSONDecoder().decode(ImVaultDraft.self,
                from: Data(contentsOf: url))
            try verifyApproved(saved, identity: draft.identity,
                               baseDigest: draft.baseDigest, editedDigest: edited)
            guard saved.baseRawData == draft.baseRawData,
                  saved.proposedBytes == draft.proposedBytes else {
                throw ImVaultCoreError.invalidDraft
            }
            return
        }
        try JSONEncoder().encode(draft).write(to: url, options: [
            .atomic, .completeFileProtectionUntilFirstUserAuthentication
        ])
        protectPrivateFile(url)
        let loaded = try JSONDecoder().decode(ImVaultDraft.self,
            from: Data(contentsOf: url))
        try verifyApproved(loaded, identity: draft.identity,
                           baseDigest: draft.baseDigest, editedDigest: edited)
        guard loaded.baseRawData == draft.baseRawData,
              loaded.proposedBytes == draft.proposedBytes else {
            throw ImVaultSyncFailure.verificationFailed
        }
    }

    /// Only exact SHA-paired snapshots are usable. Historical records from
    /// before this fix may use the active draft if it still matches exactly.
    static func approvedDraft(identity: ImVaultFileIdentity,
                              baseDigest: String?,
                              editedDigest: String?) throws -> ImVaultDraft? {
        guard let baseDigest, let editedDigest else { return nil }
        let path = try approvedURL(identity: identity, baseDigest: baseDigest,
                                   editedDigest: editedDigest)
        if FileManager.default.fileExists(atPath: path.path) {
            let saved = try JSONDecoder().decode(ImVaultDraft.self,
                from: Data(contentsOf: path))
            try verifyApproved(saved, identity: identity,
                               baseDigest: baseDigest, editedDigest: editedDigest)
            return saved
        }
        guard let legacy = try loadDraft(identity: identity),
              legacy.baseDigest == baseDigest,
              ImVaultDigest.sha256(legacy.proposedBytes) == editedDigest else {
            return nil
        }
        try verifyApproved(legacy, identity: identity,
                           baseDigest: baseDigest, editedDigest: editedDigest)
        return legacy
    }

    /// New editable base ONLY after the previous proposed bytes have really
    /// become the coordinated source. Preserve the old snapshot before the
    /// active draft changes. A changed external source fails closed.
    static func startFreshDraft(afterApplied old: ImVaultDraft,
                                live: ImVaultRawDocument) throws -> ImVaultDraft {
        try old.validate()
        guard old.identity == live.identity, old.hasChanges,
              old.baseDigest != live.digest,
              ImVaultDigest.sha256(live.sourceBytes) == live.digest,
              ImVaultDigest.sha256(old.proposedBytes) == live.digest else {
            throw ImVaultSyncFailure.conflict
        }
        try archiveApprovedDraft(old)
        let next = try ImVaultDraft(identity: live.identity,
            baseText: live.markdown, baseRawData: live.sourceBytes)
        try saveDraft(next)
        guard let stored = try loadDraft(identity: live.identity),
              stored.baseDigest == live.digest,
              stored.baseRawData == live.sourceBytes else {
            throw ImVaultSyncFailure.verificationFailed
        }
        return stored
    }

    // Pending question candidates share the existing Vault private store.
    // This snapshot is NOT a second card database or a source Markdown backup.
    private static func questionPoolURL(_ identity: ImVaultFileIdentity) throws -> URL {
        try directory("AIQuestionPool").appendingPathComponent(opaqueKey(identity) + ".json")
    }

    static func saveQuestionPool(_ pool: ImpressAIQuestionPool) throws {
        let identity = try ImVaultFileIdentity(vaultID: pool.source.vaultID,
                                               relativePath: pool.source.relativePath)
        guard (1...20).contains(pool.requestedCount),
              pool.candidates.count <= 20, !pool.excerpts.isEmpty,
              pool.excerpts.allSatisfy({ $0.source == pool.source }) else {
            throw ImpressAIContractError.invalidRequest
        }
        let encoded = try JSONEncoder().encode(pool)
        guard encoded.count <= 256_000 else { throw ImVaultSyncFailure.tooLarge }
        let url = try questionPoolURL(identity)
        try encoded.write(to: url, options: [
            .atomic, .completeFileProtectionUntilFirstUserAuthentication
        ])
        protectPrivateFile(url)
        let restored = try loadQuestionPool(identity: identity)
        guard restored?.id == pool.id,
              restored?.source == pool.source,
              restored?.candidates.count == pool.candidates.count else {
            throw ImVaultSyncFailure.verificationFailed
        }
    }

    static func loadQuestionPool(identity: ImVaultFileIdentity) throws -> ImpressAIQuestionPool? {
        let url = try questionPoolURL(identity)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let data = try Data(contentsOf: url)
        guard data.count <= 256_000 else { throw ImVaultSyncFailure.tooLarge }
        let pool = try JSONDecoder().decode(ImpressAIQuestionPool.self, from: data)
        guard pool.source.vaultID == identity.vaultID,
              pool.source.relativePath == identity.relativePath,
              pool.excerpts.allSatisfy({ $0.source == pool.source }),
              (1...20).contains(pool.requestedCount) else {
            throw ImVaultSyncFailure.wrongVault
        }
        return pool
    }

    static func deleteQuestionPool(identity: ImVaultFileIdentity) throws {
        let url = try questionPoolURL(identity)
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
    }

    /// The only source pre-write backup location: private Application Support.
    /// Recovery files are unique, verified and never automatically removed.
    static func backupBeforeWrite(identity: ImVaultFileIdentity, data: Data) throws -> URL {
        let path = try directory("Recovery").appendingPathComponent(
            opaqueKey(identity) + "-" + UUID().uuidString + ".md")
        try data.write(to: path, options: .atomic)
        protectPrivateFile(path)
        guard try Data(contentsOf: path) == data else {
            throw ImVaultSyncFailure.verificationFailed
        }
        return path
    }
}

enum ImVaultCommitOutcome {
    case unchanged
    case alreadyApplied
    case written(recoveryURL: URL)
}

/// Source writes are blocked in production until physical File Provider /
/// iCloud validation succeeds. The DEBUG-only QA flow is deliberately separate:
/// only a user-selected disposable folder with an exact sentinel *folder name*
/// can be changed, and only following a complete diff and explicit confirmation.
enum ImVaultGuardedWrite {
    static let productionWriteEnabled = false
    private static let mutex = NSLock()

    #if DEBUG
    static let deviceQAFolderName = "Impress-Write-Test-Vault"

    /// Resolving symlinks before comparing the *entire last folder component*
    /// prevents accepting a folder named e.g. "Impress-Write-Test-Vault-Old".
    static func isExplicitQAVault(_ root: URL) -> Bool {
        let resolved = root.standardizedFileURL.resolvingSymlinksInPath()
        return resolved.lastPathComponent == deviceQAFolderName
    }
    #endif

    /// An eligibility probe is read-only. The check is repeated inside the
    /// security-scoped coordinated write transaction, not trusted at UI time.
    static func checkQAVaultEligibility(
        for identity: ImVaultFileIdentity,
        completion: @escaping (Result<Bool, Error>) -> Void
    ) {
        #if DEBUG
        ImVaultReadOnlyProbe.shared.withAuthorizedRoot({ root, vaultID in
            guard identity.vaultID == vaultID else {
                throw ImVaultSyncFailure.wrongVault
            }
            return isExplicitQAVault(root)
        }, completion: completion)
        #else
        completion(.success(false))
        #endif
    }

    static func commitAuthorized(
        draft: ImVaultDraft, userConfirmedDiff: Bool,
        deviceQATestCopyConfirmed: Bool = false,
        completion: @escaping (Result<ImVaultCommitOutcome, Error>) -> Void
    ) {
        #if DEBUG
        let canTryQACopy = deviceQATestCopyConfirmed
        #else
        let canTryQACopy = false
        #endif
        guard productionWriteEnabled || canTryQACopy else {
            completion(.failure(ImVaultSyncFailure.writesLocked))
            return
        }
        ImVaultReadOnlyProbe.shared.withAuthorizedRoot({ root, vaultID in
            guard draft.identity.vaultID == vaultID else {
                throw ImVaultSyncFailure.wrongVault
            }
            #if DEBUG
            if !productionWriteEnabled && !Self.isExplicitQAVault(root) {
                throw ImVaultSyncFailure.deviceTestVaultRequired
            }
            #endif
            return try commitVerified(root: root, draft: draft,
                                      userConfirmedDiff: userConfirmedDiff)
        }, completion: completion)
    }

    // XCTest ONLY: callers must provide a temporary disposable test Vault.
    // Release builds may not exercise the fixture write implementation.
    static func commitFixture(root: URL, draft: ImVaultDraft,
                              userConfirmedDiff: Bool) throws -> ImVaultCommitOutcome {
        #if !DEBUG
        throw ImVaultSyncFailure.writesLocked
        #else
        let testRoot = FileManager.default.temporaryDirectory
            .standardizedFileURL.resolvingSymlinksInPath().path
        let fixtureRoot = root.standardizedFileURL.resolvingSymlinksInPath().path
        guard fixtureRoot.hasPrefix(testRoot + "/") else {
            throw ImVaultSyncFailure.writesLocked
        }
        return try commitVerified(root: root, draft: draft,
                                  userConfirmedDiff: userConfirmedDiff)
        #endif
    }

    /// The only authorized common write mechanism for fixtures and a
    /// deliberately selected QA-only test Vault. Production remains locked.
    private static func commitVerified(root: URL, draft: ImVaultDraft,
                              userConfirmedDiff: Bool) throws -> ImVaultCommitOutcome {
        try draft.validate()
        // A .excalidraw.md document contains structured drawing data. Protect
        // both temporary QA and any future production path from generic edits.
        guard draft.identity.documentFormat.allowsGenericMarkdownDraft else {
            throw ImVaultSyncFailure.unsupportedComplexWrite
        }
        guard userConfirmedDiff else { throw ImVaultSyncFailure.approvalMissing }
        let preview = ImVaultDiff.summary(base: draft.byteFaithfulBaseText,
                                          edited: draft.byteFaithfulEditedText, maximumLines: 200)
        guard preview.complete else { throw ImVaultSyncFailure.previewTruncated }
        guard draft.hasChanges else { return .unchanged }

        mutex.lock()
        defer { mutex.unlock() }

        let url = try ImVaultReadSync.fileURL(root: root, identity: draft.identity)
        let coordinator = NSFileCoordinator(filePresenter: nil)
        var coordinatorError: NSError?
        var operationError: Error?
        var result: ImVaultCommitOutcome?
        coordinator.coordinate(writingItemAt: url, options: .forReplacing,
                               error: &coordinatorError) { coordinatedFile in
            do {
                try ImVaultReadSync.enforceContainment(coordinatedFile, root: root)
                let v = try coordinatedFile.resourceValues(forKeys: [
                    .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
                guard v.isRegularFile == true, v.isSymbolicLink != true else {
                    throw ImVaultSyncFailure.unsafePath
                }
                guard (v.fileSize ?? 0) <= 8 * 1024 * 1024 else {
                    throw ImVaultSyncFailure.tooLarge
                }
                let current = try Data(contentsOf: coordinatedFile)
                guard current.count <= 8 * 1024 * 1024 else {
                    throw ImVaultSyncFailure.tooLarge
                }
                switch draft.decision(against: current) {
                case .unchanged:
                    result = .unchanged
                case .alreadyApplied:
                    result = .alreadyApplied
                case .conflict:
                    throw ImVaultSyncFailure.conflict
                case .safeToWrite:
                    // A failure to persist the complete recovery byte copy
                    // ABORTS before the first attempt to write source content.
                    let backup = try ImVaultPrivateStore.backupBeforeWrite(
                        identity: draft.identity, data: current)
                    let bytes = draft.proposedBytes
                    try bytes.write(to: coordinatedFile, options: .atomic)
                    guard try Data(contentsOf: coordinatedFile) == bytes else {
                        throw ImVaultSyncFailure.verificationFailed
                    }
                    result = .written(recoveryURL: backup)
                }
            } catch { operationError = error }
        }
        if let e = coordinatorError { throw e }
        if let e = operationError { throw e }
        return result ?? .unchanged
    }
}


// MARK: - P2 · private Markdown reading projection (inline local attachments)
//
// This projection deliberately cannot modify source Markdown. Images are
// embedded as bounded in-memory data: URIs. Raw HTML and network images are
// disabled to avoid accidentally contacting third-party servers when reading
// personal Obsidian notes.
extension ImVaultReadSync {
    func prepareAuthorizedPreview(_ document: ImVaultRawDocument,
                                  completion: @escaping (Result<String, Error>) -> Void) {
        ImVaultReadOnlyProbe.shared.withAuthorizedRoot({ root, vaultID in
            guard document.identity.vaultID == vaultID else {
                throw ImVaultSyncFailure.wrongVault
            }
            return try Self.safeMarkdownProjection(root: root,
                identity: document.identity, source: document.markdown)
        }, qos: .userInitiated, completion: completion)
    }

    /// Render-only, one-hop Vault dependency. Graphics are projected to bounded
    /// geometry, while a small referenced Markdown note may be read inline.
    /// Neither projection can authorize Chat, link another Vault, or write a file.
    private static func safeDocumentEmbed(root: URL,
                                          source: ImVaultFileIdentity,
                                          name: String) -> (String, Int)? {
        guard !name.isEmpty, !name.contains("\\"), !name.contains(":"),
              !name.hasPrefix("/") else { return nil }
        let parts = name.split(separator: "#", maxSplits: 1,
                               omittingEmptySubsequences: false)
        guard let rawBase = parts.first, !rawBase.isEmpty else { return nil }
        let fragment = parts.count == 2 ? String(parts[1]) : nil
        // Block locators need their own precise AST mapping. Never select a
        // vaguely similar text line as though it were an authenticated block.
        guard fragment?.hasPrefix("^") != true else { return nil }
        let baseName = String(rawBase)
        let normalized: String = ImVaultDocumentFormat.detect(relativePath: baseName) == nil
            ? baseName + ".md" : baseName
        let target: ImVaultFileIdentity
        if normalized.contains("/") {
            guard let id = try? ImVaultFileIdentity(
                vaultID: source.vaultID, relativePath: normalized) else { return nil }
            target = id
        } else {
            // Reuse the existing private Vault index. Never scan every file
            // merely to display a Markdown note or resolve ambiguous names.
            guard let matches = try? ImVaultPrivateStore.loadIndex(vaultID: source.vaultID)
                .filter({ $0.identity.relativePath.split(separator: "/").last
                    .map { String($0).caseInsensitiveCompare(normalized) == .orderedSame } == true }),
                  matches.count == 1 else { return nil }
            target = matches[0].identity
        }
        guard target != source else { return nil } // Direct self-embed is cyclic.
        let format = target.documentFormat
        guard [.markdown, .jsonCanvas, .excalidrawJSON,
               .excalidrawMarkdown].contains(format) else { return nil }
        guard fragment == nil || format == .markdown else { return nil }
        do {
            let url = try fileURL(root: root, identity: target)
            let metadata = try url.resourceValues(forKeys: [
                .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
            guard metadata.isRegularFile == true && metadata.isSymbolicLink != true,
                  (metadata.fileSize ?? Int.max) <= 512 * 1024 else { return nil }
            let document = try load(root: root, identity: target)
            guard document.sourceBytes.count <= 512 * 1024 else { return nil }
            var queryCharacters = CharacterSet.urlQueryAllowed
            queryCharacters.remove(charactersIn: "&=+#")
            guard let encodedPath = target.relativePath.addingPercentEncoding(
                withAllowedCharacters: queryCharacters) else { return nil }
            let openOriginal = "\n[打开来源文件并独立选材](https://impress.invalid/wiki?target=" +
                encodedPath + ")\n"
            let isPluginDrawing = format == .markdown &&
                ImpressObsidianDrawingEnvelope.isSupportedDrawing(document.sourceBytes)
            if isPluginDrawing && fragment != nil { return nil }
            if format == .markdown && !isPluginDrawing {
                let text: String
                if let fragment, !fragment.isEmpty {
                    let sections = ImpressMarkdownStructure.sections(in: document.markdown)
                    let found = sections.filter { $0.heading == fragment }
                    guard found.count == 1, let section = found.first else { return nil }
                    text = section.rawUTF8
                } else {
                    text = ImpressFrontmatterReader.parse(document.markdown).body
                }
                guard text.utf8.count <= 20_000 else { return nil }
                // Never recursively resolve second-level embeds: a nested
                // dependency is deliberately inert until opened explicitly.
                var nested = Array(text.utf8)
                for item in ImpressVaultEmbedLocator.references(in: text).reversed() {
                    nested.replaceSubrange(item.startUTF8..<item.endUTF8,
                        with: Array("（嵌入深度限制：打开来源文件查看）".utf8))
                }
                let flattened = String(decoding: nested, as: UTF8.self)
                let secure = ImVaultSafetyProjection.withoutUntrustedImages(
                    ImVaultSafetyProjection.withCalloutHeadings(
                        ImVaultSafetyProjection.withWikiLinks(flattened)))
                let quoted = secure.components(separatedBy: .newlines)
                    .map { "> " + $0 }.joined(separator: "\n")
                return ("\n> **只读嵌入 · 来源需独立核查**\n>\n" +
                    quoted + "\n" + openOriginal, document.sourceBytes.count)
            }
            let kind: String
            let packed: Data
            switch format {
            case .jsonCanvas:
                _ = try ImpressCanvasDocument.parse(document.sourceBytes)
                packed = document.sourceBytes
                kind = "impress-canvas"
            case .excalidrawJSON, .excalidrawMarkdown, .markdown:
                guard format != .markdown || isPluginDrawing else { return nil }
                let scene = try ImpressExcalidrawScene.parse(document.sourceBytes,
                    format: isPluginDrawing ? .excalidrawMarkdown : format)
                // A Markdown embed previously forwarded geometry but dropped
                // scene.files, so every Excalidraw image became an empty box.
                // This is a strictly local, display-only raster projection.
                // Only active image fileIds may cross into the isolated reader;
                // Chat selections never receive any raster bytes.
                struct InlineRaster: Encodable {
                    let mimeType: String
                    let dataURL: String
                }
                struct Geometry: Encodable {
                    let elements: [ImpressExcalidrawElement]
                    let files: [String: InlineRaster]
                }
                let active = scene.elements.filter(\.isActive)
                var rasters: [String: InlineRaster] = [:]
                var encodedCharacters = 0
                for element in active where element.type == "image" {
                    guard rasters.count < 12, let fileID = element.fileId,
                          !fileID.isEmpty, rasters[fileID] == nil,
                          let file = scene.files?[fileID],
                          let url = file.dataURL,
                          url.utf8.count <= 650_000 else { continue }
                    let mime: String
                    let prefix: String
                    if url.hasPrefix("data:image/png;base64,") {
                        mime = "image/png"
                        prefix = "data:image/png;base64,"
                    } else if url.hasPrefix("data:image/jpeg;base64,") {
                        mime = "image/jpeg"
                        prefix = "data:image/jpeg;base64,"
                    } else { continue } // No remote, SVG, HTML or local paths.
                    guard file.mimeType == nil || file.mimeType == mime,
                          encodedCharacters + url.utf8.count <= 750_000,
                          let decoded = Data(base64Encoded:
                            String(url.dropFirst(prefix.count))),
                          !decoded.isEmpty,
                          let source = CGImageSourceCreateWithData(
                            decoded as CFData, nil),
                          let metadata = CGImageSourceCopyPropertiesAtIndex(
                            source, 0, nil) as NSDictionary?,
                          let width = metadata.object(
                            forKey: kCGImagePropertyPixelWidth) as? Int,
                          let height = metadata.object(
                            forKey: kCGImagePropertyPixelHeight) as? Int,
                          width > 0, height > 0, width <= 8192, height <= 8192,
                          Double(width) * Double(height) <= 12_000_000
                    else { continue }
                    rasters[fileID] = InlineRaster(mimeType: mime, dataURL: url)
                    encodedCharacters += url.utf8.count
                }
                packed = try JSONEncoder().encode(Geometry(
                    elements: active, files: rasters))
                kind = "impress-excalidraw"
            default: return nil
            }
            guard packed.count <= 640 * 1024 else { return nil }
            let rendered = "~~~" + kind + "\n" + packed.base64EncodedString() +
                "\n~~~\n" + openOriginal
            return (rendered, packed.count)
        } catch {
            // Broken, moved, permission-revoked, or too-large dependency must
            // never hide or corrupt the remainder of the host note.
            return nil
        }
    }

    static func safeMarkdownProjection(root: URL,
                                       identity: ImVaultFileIdentity,
                                       source: String) throws -> String {
        // Inert raw HTML; full unmodified source remains available in Src mode.
        // Remove unsafe Markdown image syntax without affecting raw bytes;
        // only Obsidian ![[local]] embeds are resolved below under Vault scope.
        let properties = ImpressFrontmatterReader.parse(source)
        let readableBody = properties.body
        // Malformed or advanced YAML stays visible for diagnosis. Do not
        // infer attached resources from its untrusted property declarations.
        if properties.state == .invalid || properties.state == .unsupported {
            return ImVaultSafetyProjection.withoutUntrustedImages(readableBody)
        }
        let formatted = ImVaultSafetyProjection.withCalloutHeadings(
            ImVaultSafetyProjection.withWikiLinks(readableBody))
        var preview = ImVaultSafetyProjection.withoutUntrustedImages(formatted)
        let allMatches = ImpressVaultEmbedLocator.references(in: preview)
        guard !allMatches.isEmpty else { return preview }

        // Scan only if needed, at most 4000 assets and max 6 images embedded.
        let fm = FileManager.default
        let imageTypes: [String: String] = [
            "png": "image/png", "jpg": "image/jpeg", "jpeg": "image/jpeg",
            "heic": "image/jpeg", "webp": "image/jpeg"
        ]
        var candidates: [String: [URL]] = [:]
        let hasUnqualifiedImages = allMatches.contains {
            let name = $0.target.components(separatedBy: "|").first ?? ""
            return !name.contains("/") &&
                imageTypes[(name as NSString).pathExtension.lowercased()] != nil
        }
        if hasUnqualifiedImages, let enumerator = fm.enumerator(at: root,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles]) {
            var examined = 0
            while let path = enumerator.nextObject() as? URL {
                examined += 1
                if examined > 4000 { break }
                guard imageTypes[path.pathExtension.lowercased()] != nil else { continue }
                let info = try path.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
                guard info.isRegularFile == true, info.isSymbolicLink != true else { continue }
                // A malicious/broken symlink or File Provider alias must be
                // isolated to this attachment. It must not make the entire
                // Markdown reader fail or cause any out-of-Vault traversal.
                do { try enforceContainment(path, root: root) }
                catch { continue }
                candidates[path.lastPathComponent, default: []].append(path)
            }
        }

        var total = 0
        var embedded = 0
        // Reverse byte replacements preserve the lexical ranges of the
        // safe display projection, never interpreted as source-selection spans.
        var projected = Array(preview.utf8)
        var composites = 0
        var compositeBytes = 0
        for match in allMatches.reversed() {
            let named = match.target.components(separatedBy: "|").first ?? ""
            let name = named.trimmingCharacters(in: .whitespacesAndNewlines)
            let comps = name.split(separator: "/", omittingEmptySubsequences: false)
            var replacement = "（本地附件暂不可读：\(name)）"
            let actualName = name.components(separatedBy: "#").first ?? name
            let ext = (actualName as NSString).pathExtension.lowercased()
            let isImage = imageTypes[ext] != nil
            if !isImage {
                if composites < 3 && compositeBytes < 1_200_000,
                   let item = safeDocumentEmbed(root: root, source: identity, name: name),
                   compositeBytes + item.1 <= 1_200_000 {
                    replacement = item.0
                    composites += 1
                    compositeBytes += item.1
                } else {
                    replacement = "（嵌入缺失、引用不明确、过深或超出限制：\(name)）"
                }
            } else if embedded < 6 && total < 4 * 1024 * 1024,
               comps.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }),
               imageTypes[(name as NSString).pathExtension.lowercased()] != nil {
                var file: URL?
                if name.contains("/") {
                    let candidate = root.appendingPathComponent(name, isDirectory: false)
                    if fm.fileExists(atPath: candidate.path) {
                        file = candidate
                    }
                } else if let matches = candidates[name], matches.count == 1 {
                    file = matches[0]
                }
                if let sourceFile = file {
                    do {
                        try enforceContainment(sourceFile, root: root)
                        let coordinator = NSFileCoordinator(filePresenter: nil)
                        var fileCoordinationError: NSError?
                        var fileError: Error?
                        var bytes: Data?
                        coordinator.coordinate(readingItemAt: sourceFile, options: [],
                                               error: &fileCoordinationError) { safeFile in
                            do {
                                try enforceContainment(safeFile, root: root)
                                let attr = try safeFile.resourceValues(forKeys: [
                                    .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
                                guard attr.isRegularFile == true,
                                      attr.isSymbolicLink != true,
                                      (attr.fileSize ?? 0) < 6 * 1024 * 1024 else {
                                    throw ImVaultSyncFailure.unsafePath
                                }
                                let handle = try FileHandle(forReadingFrom: safeFile)
                                defer { handle.closeFile() }
                                // Bound the read even when File Provider cannot
                                // report its true size before hydration.
                                bytes = handle.readData(ofLength: 6 * 1024 * 1024 + 1)
                            } catch { fileError = error }
                        }
                        if let error = fileCoordinationError { throw error }
                        if let error = fileError { throw error }
                        guard let imageBytes = bytes, imageBytes.count < 6 * 1024 * 1024,
                              let source = CGImageSourceCreateWithData(imageBytes as CFData, nil) else {
                            throw ImpressImageOptimizationError.invalidImage
                        }
                        let thumbnailOptions: [CFString: Any] = [
                            kCGImageSourceCreateThumbnailFromImageAlways: true,
                            kCGImageSourceCreateThumbnailWithTransform: true,
                            kCGImageSourceThumbnailMaxPixelSize: 2000
                        ]
                        guard let thumbnail = CGImageSourceCreateThumbnailAtIndex(
                            source, 0, thumbnailOptions as CFDictionary) else {
                            throw ImpressImageOptimizationError.invalidImage
                        }
                        let compressed = try ImpressImageOptimizer.optimize(
                            UIImage(cgImage: thumbnail), kind: .document,
                            maxBytes: 480 * 1024)
                        total += compressed.count
                        replacement = "![本地图片](data:image/jpeg;base64," +
                            compressed.base64EncodedString() + ")"
                        embedded += 1
                    } catch {
                        // A bad attachment must never break the Markdown note
                        // or cause access outside the authorized Vault.
                        replacement = "（本地图片暂不可读：\(name)）"
                    }
                }
            }
            projected.replaceSubrange(match.startUTF8..<match.endUTF8,
                                      with: Array(replacement.utf8))
        }
        return String(decoding: projected, as: UTF8.self)
    }
}
