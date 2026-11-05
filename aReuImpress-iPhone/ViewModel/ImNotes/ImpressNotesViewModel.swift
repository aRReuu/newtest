//
//  ImpressNotesViewModel.swift
//  aReuImpress-iPhone
//
//  Created by aReu on 12/28/22.
//

import WCDBSwift
import Combine

/// Identity for the legacy single-Vault sandbox mirror. P0-2 will add a
/// stable vaultID for multiple externally authorized Obsidian Vaults.
struct ImVaultNoteIdentity: Hashable {
    let title: String
    let relativeDirectory: String

    init(title: String, directory: String?) {
        self.title = title
        relativeDirectory = (directory ?? "")
            .split(separator: "/")
            .filter { $0 != "." && $0 != ".." }
            .joined(separator: "/")
    }
}

class ImpressNotesViewModel: ImBaseViewModel, ImNotesViewModelProtocol
{
    var onDataUpdate: ((BaseActionResult) -> Void)?
    
    // MARK: - ImNotesCombineProtocol
    var notesPublisher: AnyPublisher<[ImNoteModel], Never> {
        $notes.eraseToAnyPublisher()
    }
    
    var filteredNotesPublisher: AnyPublisher<[ImNoteModel], Never> {
        $filterNotes.eraseToAnyPublisher()
    }
    
    var isFilteringPublisher: AnyPublisher<Bool, Never> {
        $isFilter.eraseToAnyPublisher()
    }
    
    var actionPublisher: AnyPublisher<BaseActionResult, Never> {
        action.eraseToAnyPublisher()
    }
    
    let action = PassthroughSubject<BaseActionResult, Never>()
    
    @Published private(set) var filterNotes: [ImNoteModel] = []
    
    @Published private(set) var notes: [ImNoteModel] = []
    ///
    @Published private(set) var isFilter: Bool = false
    
    private let noteTable = ImDBTableType.notes.description
}


// MARK: - NotesViewModelDatesProtocol
extension ImpressNotesViewModel
{
    var currentNotesCount:Int
    {
        return isFilter ? filterNotes.count : notes.count
    }
    
    func getCurrentNote(indexPath:IndexPath) -> ImNoteModel?
    {
        let section = indexPath.section
        guard (isFilter ? filterNotes : notes).indices.contains(section) else { return nil}
        return isFilter ? filterNotes[section] : notes[section]
    }
    
    func indexPath(for selectedNoteID: Int) -> IndexPath?
    {
        let currentNotes = isFilter ? filterNotes : notes
        if let index = currentNotes.firstIndex(where: { $0.identifier == selectedNoteID }) {
            return IndexPath(row: 0, section: index)
        }
        return nil
    }

    /// 获取随机笔记
    func getRandomNote() -> ImNoteModel?
    {
        let currentNotes = isFilter ? filterNotes : notes
        guard !currentNotes.isEmpty else { return nil }

        let randomIndex = Int(arc4random_uniform(UInt32(currentNotes.count)))
        return currentNotes[randomIndex]
    }

}


// MARK: - NotesViewModelLogicProtocol
extension ImpressNotesViewModel
{
    func updateStatusInFliter()
    {
        isFilter = false
    }
    
    /// R 查找数据 默认获取所有notes表的数据
    func fetchNotes(by vc:ImBaseViewController)
    {
        // 从本地ImpressDB目录获取笔记数据
        ImObsidianManager.shared.withVaultURL(from: vc) {[weak self] (impressVaultURL, endAccess) in
            guard let self = self else { return }
            zcLog("当前获取到的本地ImpressDB URL: \(impressVaultURL.absoluteString)")
            
            self.action.send(.isLoading())
            // 先获取所有笔记
            dbShare.queryFromDB(table: self.noteTable,
                                cls: ImNoteModel.self) { (result) in
                switch result {
                case .success(let notes):
                    self.notes = notes
                    // 扫描本地文件系统并同步数据
                    self.scanAndUpdateMarkdownFiles(impressVaultURL, endAccess)
                case .failure(let error):
                    endAccess()
                    self.action.send(.isLoading(false))
                    self.action.send(.errorOccurred(error))
                }
            }
        } onError: { (error) in
            self.action.send(.errorOccurred(error))
        }
    }
   
    /// notesDatas数据筛选
    /// - Parameters:
    ///   - filtterText: <#filtterText description#>    
    func predicateNoteSeriesDatas(filtterText: String)
    {
        isFilter = true
        filterNotes = notes.filter { note in
            guard let title = note.mainTitle, let content = note.markdownText else {return false}
            let titleMatch = title.range(of: filtterText, options: .caseInsensitive) != nil
            let markdownMatch = content.range(of: filtterText, options: .caseInsensitive) != nil
            return titleMatch || markdownMatch
        }
    }
    
    func deleteNote(at indexPath: IndexPath)
    {
        // P0-0: deleting an index row without an explicit Vault/file policy
        // is misleading and may later erase user data during synchronization.
        // Fail closed until backup/trash/recovery are separately implemented.
        let error = NSError(domain: "ImpressVaultSafety", code: -40,
                            userInfo: [NSLocalizedDescriptionKey:
                                "笔记删除暂未开放，原始 Obsidian 文件和本地索引均未修改。"])
        action.send(.errorOccurred(error))
    }
}

// MARK: - 扫描文件夹业务
extension ImpressNotesViewModel
{
    func scanAndUpdateMarkdownFiles(_ impressVaultURL: URL,_ endAccecc: @escaping ()->Void)
    {
        self.action.send(.isLoading())
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self = self else { return }
            //
            let fileManager = FileManager.default
            var newNotes = [ImNoteModel]()
            var updatedNotes = [ImNoteModel]()
            //
            if let enumerator = fileManager.enumerator(at: impressVaultURL,
                                                     includingPropertiesForKeys: [.contentModificationDateKey],
                                                     options: [.skipsHiddenFiles]) {
                for case let fileURL as URL in enumerator {
                    
                    // 获取当前项目的类型，以确定是文件还是目录
                    guard let fileAttributes = try? fileURL.resourceValues(forKeys: [.isDirectoryKey]),
                          let isDirectory = fileAttributes.isDirectory else { continue }
                    // 如果是目录并且是我们要跳过的目录，则调用 skipDescendants()
                    if isDirectory && ignoreDirectory.contains(fileURL.lastPathComponent) {
                        enumerator.skipDescendants()
                        continue
                    }
                    // 只有当是文件且扩展名是"md"时才继续处理
                    guard !isDirectory, fileURL.pathExtension == "md" else { continue }
                    do {
                        let attributes = try fileManager.attributesOfItem(atPath: fileURL.path)
                        guard let modificationDate = attributes[.modificationDate] as? Date else { continue }
                        
                        let fileName = fileURL.deletingPathExtension().lastPathComponent
                        let fileContent = try String(contentsOf: fileURL, encoding: .utf8)
                        
                        // Relative folder path must be rooted under this mirror:
                        // string-wide replacement can confuse similarly named roots.
                        let rootPath = impressVaultURL.standardizedFileURL.path
                        let parentPath = fileURL.deletingLastPathComponent().standardizedFileURL.path
                        guard parentPath == rootPath || parentPath.hasPrefix(rootPath + "/") else { continue }
                        let relativePath = String(parentPath.dropFirst(rootPath.count))
                        let sourceIdentity = ImVaultNoteIdentity(title: fileName, directory: relativePath)
                        // Never merge two different Markdown files just because
                        // their filenames/titles are the same.
                        if let existingNote = self.notes.first(where: { candidate in
                            guard let title = candidate.mainTitle else { return false }
                            return ImVaultNoteIdentity(title: title, directory: candidate.directoryPath) == sourceIdentity
                        }) {
                            if existingNote.modificationDate == nil ||
                               trimToSecond(modificationDate) > trimToSecond(existingNote.modificationDate!) ||
                               existingNote.markdownText != fileContent {
                                var e = existingNote
                                e.markdownText = fileContent
                                e.modificationDate = modificationDate
                                e.directoryPath = relativePath // 更新目录路径
                                updatedNotes.append(e)
                            }
                        } else {
                            // 创建新记录
                            var newNote = ImNoteModel()
                            newNote.mainTitle = fileName
                            newNote.markdownText = fileContent
                            newNote.modificationDate = modificationDate
                            newNote.directoryPath = relativePath // 新增目录路径
                            newNotes.append(newNote)
                        }
                    } catch {
                        let error = NSError(domain: ObsidianFolderName,
                                            code: -3,
                                            userInfo: [NSLocalizedDescriptionKey:"处理文件出错: \(fileURL.lastPathComponent), 错误: \(error.localizedDescription)"])
                        self.action.send(.errorOccurred(error))
                    }
                }
            }
            DispatchQueue.main.async {[weak self] in
                // 关闭
                endAccecc()
                self?.processUpdates(updatedNotes, newNotes)
            }
        }
    }
    
    
    /// 批量处理更新和插入
    /// - Parameters:
    ///   - updatedNotes: <#updatedNotes description#>
    ///   - newNotes: <#newNotes description#>
    private func processUpdates(_ updatedNotes: [ImNoteModel],
                                _ newNotes: [ImNoteModel])
    {
        let group = DispatchGroup()
        if !updatedNotes.isEmpty {
            group.enter()
            var updateCount = 0
            for note in updatedNotes {
                dbShare.updateToDB(
                    table: noteTable,
                    on: [
                        ImNoteModel.Properties.markdownText,
                        ImNoteModel.Properties.modificationDate
                    ],
                    with: note,
                    where: ImNoteModel.Properties.identifier == note.identifier!
                ) { [weak self] result in
                    
                    guard let self = self else {
                        updateCount += 1
                        if updateCount == updatedNotes.count {
                            group.leave()
                        }
                        return
                    }

                    switch result {
                    case .success():
                        if let index = self.notes.firstIndex(where: { $0.identifier == note.identifier }) {
                            self.notes[index] = note
                        }
                    case .failure(let error):
                        self.action.send(.errorOccurred(error))
                    }
                    updateCount += 1
                    if updateCount == updatedNotes.count {
                        group.leave()
                    }
                }
            }
        }
        
        // 插入新笔记
        if !newNotes.isEmpty {
            group.enter()
            dbShare.insertToDB(intoTable: noteTable,
                               with: newNotes) { [weak self] result in
                switch result {
                case .success():
                    self?.notes.append(contentsOf: newNotes)
                    break
                case .failure(let error):
                    self?.action.send(.errorOccurred(error))
                    break
                }
                group.leave()
            }
        }
        
        group.notify(queue: .main) { [weak self] in
            self?.action.send(.isLoading(false))
            guard newNotes.count > 0 || updatedNotes.count > 0 else {return}
            self?.action.send(.success("同步完成 \n 新笔记数量:\(newNotes.count) \n 更新笔记数量:\(updatedNotes.count)"))
        }
    }
}
